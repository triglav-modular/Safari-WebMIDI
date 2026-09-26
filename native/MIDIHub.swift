import CoreMIDI
import Foundation

// CoreMIDI behind the extension.  One hub per extension process; every
// request from every tab lands here, and the state (the connections, the
// received messages) carries from one request to the next.
//
// Requests, as dictionaries from the background page:
//   ports                                          -> { gen, inputs: [port], outputs: [port] }
//   send   msgs: [[port, base64, t]], sysex, client -> { ok, failed: [port] }
//   clear  port, client                             -> { ok }
//   recv   since, gen, wait, sysex                  -> { seq, gen, events: [[port, base64, t]] }
// `client` is a page (one document); the background clamps each page's
// `since` to where it started.
// A port is { id, name, manufacturer, version }.  Times are milliseconds
// since 1970 (the page's performance.timeOrigin + performance.now()), so
// both sides share a clock without sharing a process; 0 means "now".
// `recv` is a long poll: it answers as soon as a message arrives after
// `since` or the port list differs from `gen`, or after `wait` ms.
//
// Port info, the byte handling and the send path follow Chromium's
// media/midi/midi_manager_mac.cc and midi_host.cc (see MIDIMessages.swift).
// Copyright The Chromium Authors; use of that code is governed by a
// BSD-style license that can be found in third_party/chromium/LICENSE.
// Scheduling does not: CoreMIDI hands a timestamped event to a virtual
// destination in another process at once and leaves the waiting to the
// receiver, and MIDIFlushOutput sends a System Reset rather than quietly
// unscheduling, so sends due later than `horizon` wait here and clear() can
// drop them, as Firefox does.
final class MIDIHub {
    static let shared = MIDIHub()

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var connected = Set<MIDIUniqueID>()
    private let lock = NSLock()

    struct Event { let port: String; let bytes: [UInt8]; let time: Double; let sysex: Bool }
    // Received messages, numbered; `base` is the number of events[0].
    private var events: [Event] = []
    private var base = 0
    private var queuedBytes = 0
    private var lastRecv = Date.distantPast
    private var waiters: [(token: UUID, since: Int, sysex: Bool, reply: ([String: Any]) -> Void)] = []
    private var cachedGen = ""
    // One Chromium MidiMessageQueue per source, as midi_host.cc keeps.
    private var queues: [UInt32: MIDIMessageQueue] = [:]
    // Sends waiting for their time: one queue in (due, submission) order, so
    // sends due at the same moment go out in the order they were made, and
    // one timer that releases them.  Filed by client (a page), so one page's
    // clear() cannot drop another's, and counted per client, so no page can
    // make this process hold more than `maxHeldPerClient` bytes.
    struct Held { let seq: Int; let client: String; let port: String; let words: [UInt32]; let host: UInt64; let bytes: Int }
    private var held: [Held] = []
    private var heldSeq = 0
    private var heldBytes: [String: Int] = [:]
    private var heldTotal = 0
    private let sendQueue = DispatchQueue(label: "webmidi.send", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    static let horizon = 0.020
    // Chromium's kMaxInFlightBytes, per page; and a ceiling for all of them.
    static let maxHeldPerClient = 10 << 20
    static let maxHeldTotal = 64 << 20

    static let keepEvents = 8192
    static let keepBytes = 4 << 20

    private(set) var setupError: String?

    private init() {
        var status = MIDIClientCreateWithBlock("Web MIDI for Safari" as CFString, &client) { [weak self] _ in
            self?.setupChanged()
        }
        if status == noErr {
            status = MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &inPort) { [weak self] list, ref in
                self?.received(list, UInt32(UInt(bitPattern: ref)))
            }
        }
        if status == noErr { status = MIDIOutputPortCreate(client, "out" as CFString, &outPort) }
        if status != noErr { setupError = "CoreMIDI refused the client (\(status))" }
        lock.lock(); connectSources(); cachedGen = generation(); lock.unlock()
    }

    // --- clocks --------------------------------------------------------------
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()
    static func hostToNanos(_ h: UInt64) -> Double {
        Double(h) * Double(timebase.numer) / Double(timebase.denom)
    }
    static func nanosToHost(_ n: Double) -> UInt64 {
        UInt64(max(0, n) * Double(timebase.denom) / Double(timebase.numer))
    }
    static func wallMillis() -> Double { Date().timeIntervalSince1970 * 1000 }
    // Wall clock minus host clock, in nanoseconds, read once and reused:
    // reading both clocks for every message put equal times a few ticks
    // apart either way, and sends given the same time came out in either
    // order (the audit measured 52-69 of 120 pairs reversed).  Re-read on
    // every use but taken up only when the clocks have drifted more than a
    // millisecond, so equal times map to equal host times, and a wall clock
    // that is corrected (by about 40 ms in a CI run) is followed at once
    // rather than up to ten seconds later.
    private static let offsetLock = NSLock()
    private static var offsetNs: Double = measureOffset()
    // The hub test steps the wall clock, as the hub sees it, with this.
    static var wallStepNs: Double = 0
    private static func measureOffset() -> Double {
        Date().timeIntervalSince1970 * 1e9 + wallStepNs - hostToNanos(mach_absolute_time())
    }
    private static func offsetLocked() -> Double {
        let fresh = measureOffset()
        if abs(fresh - offsetNs) > 1e6 { offsetNs = fresh }
        return offsetNs
    }
    static func wallMinusHostNs() -> Double {
        offsetLock.lock(); defer { offsetLock.unlock() }
        return offsetLocked()
    }
    // A time that comes again gets the host time it got before, even when
    // the offset was taken up in between: otherwise a correction landing
    // between the two sends of a note-off and note-on given one time put
    // them more than a millisecond apart, reversed (1 of 120 pairs on a CI
    // runner whose clock is corrected often).  The last 1024 times are kept.
    private static var given: [Double: UInt64] = [:]
    private static var givenOrder: [Double] = []
    // The host time of a wall-clock instant, whether past or future: a past
    // time keeps its place in CoreMIDI's order instead of becoming "now".
    static func hostTime(atWallMillis ms: Double) -> UInt64 {
        offsetLock.lock(); defer { offsetLock.unlock() }
        if let h = given[ms] { return h }
        let h = nanosToHost(ms * 1e6 - offsetLocked())
        given[ms] = h
        givenOrder.append(ms)
        if givenOrder.count > 1024 { given.removeValue(forKey: givenOrder.removeFirst()) }
        return h
    }
    static func wallMillis(atHost h: UInt64) -> Double {
        if h == 0 { return wallMillis() }
        return (hostToNanos(h) + wallMinusHostNs()) / 1e6
    }

    // --- endpoints -----------------------------------------------------------
    private static func string(_ obj: MIDIObjectRef, _ key: CFString) -> String {
        var s: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, key, &s) == noErr, let v = s else { return "" }
        return v.takeRetainedValue() as String
    }
    private static func integer(_ obj: MIDIObjectRef, _ key: CFString) -> Int32? {
        var v: Int32 = 0
        return MIDIObjectGetIntegerProperty(obj, key, &v) == noErr ? v : nil
    }
    static func uniqueID(_ obj: MIDIObjectRef) -> MIDIUniqueID { integer(obj, kMIDIPropertyUniqueID) ?? 0 }
    private static func endpoints(_ count: Int, _ get: (Int) -> MIDIEndpointRef) -> [MIDIEndpointRef] {
        (0..<count).map(get).filter { $0 != 0 && (integer($0, kMIDIPropertyOffline) ?? 0) == 0 }
    }
    static func sources() -> [MIDIEndpointRef] { endpoints(MIDIGetNumberOfSources(), MIDIGetSource) }
    static func destinations() -> [MIDIEndpointRef] { endpoints(MIDIGetNumberOfDestinations(), MIDIGetDestination) }
    static func portID(_ e: MIDIEndpointRef) -> String { String(uniqueID(e)) }

    private static func describe(_ e: MIDIEndpointRef) -> [String: Any] {
        let version = integer(e, kMIDIPropertyDriverVersion).map { String($0) } ?? ""
        return [
            "id": portID(e),
            "name": string(e, kMIDIPropertyDisplayName),
            "manufacturer": string(e, kMIDIPropertyManufacturer),
            "version": version,
        ]
    }

    // A fingerprint of the port list, so a change is noticed even when no
    // CoreMIDI notification reaches this process.
    private func generation() -> String {
        (MIDIHub.sources().map { "i" + MIDIHub.portID($0) } + MIDIHub.destinations().map { "o" + MIDIHub.portID($0) })
            .joined(separator: ",")
    }

    // Must hold the lock.
    private func connectSources() {
        let present = MIDIHub.sources()
        for src in present {
            let uid = MIDIHub.uniqueID(src)
            if connected.contains(uid) { continue }
            let ref = UnsafeMutableRawPointer(bitPattern: UInt(UInt32(bitPattern: uid)))
            if MIDIPortConnectSource(inPort, src, ref) == noErr { connected.insert(uid) }
        }
        connected.formIntersection(Set(present.map(MIDIHub.uniqueID)))
    }

    private func setupChanged() {
        lock.lock()
        connectSources()
        let gen = generation()
        let fire = gen != cachedGen ? takeWaiters() : []
        cachedGen = gen
        lock.unlock()
        fire.forEach { $0() }
    }

    // --- receiving -----------------------------------------------------------
    private func received(_ list: UnsafePointer<MIDIEventList>, _ uid: UInt32) {
        var got: [Event] = []
        let id = String(Int32(bitPattern: uid))
        lock.lock()
        let queue = queues[uid] ?? MIDIMessageQueue(allowRunningStatus: true)
        queues[uid] = queue
        let offset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
        for packet in list.unsafeSequence() {
            let time = MIDIHub.wallMillis(atHost: packet.pointee.timeStamp)
            let words = UnsafeBufferPointer(
                start: UnsafeRawPointer(packet).advanced(by: offset).assumingMemoryBound(to: UInt32.self),
                count: Int(packet.pointee.wordCount))
            UMP.dispatchMidiFromUmpWords(words) { queue.add($0) }
            while true {
                let m = queue.get()
                if m.isEmpty { break }
                got.append(Event(port: id, bytes: m, time: time, sysex: m[0] == MIDIBytes.sysEx))
            }
        }
        // Nobody asked for a while: no page is listening, so keep nothing.
        if got.isEmpty || Date().timeIntervalSince(lastRecv) > 10 { lock.unlock(); return }
        for g in got {
            events.append(g)
            queuedBytes += g.bytes.count
        }
        while events.count > MIDIHub.keepEvents || queuedBytes > MIDIHub.keepBytes {
            queuedBytes -= events.removeFirst().bytes.count
            base += 1
        }
        let fire = takeWaiters()
        lock.unlock()
        fire.forEach { $0() }
    }

    // Must hold the lock.  Returns the replies to make once it is released.
    private func takeWaiters() -> [() -> Void] {
        let ws = waiters
        waiters = []
        return ws.map { w in { [self] in w.reply(self.recvReply(since: w.since, sysex: w.sysex)) } }
    }

    private func recvReply(since: Int, sysex: Bool) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let end = base + events.count
        let from = since < 0 ? end : max(since, base)
        let slice = from < end ? events[(from - base)...] : []
        return [
            "seq": end,
            "gen": cachedGen,
            "lost": since >= 0 && since < base,
            "events": slice.filter { sysex || !$0.sysex }.map {
                [$0.port, Data($0.bytes).base64EncodedString(), $0.time] as [Any]
            },
        ]
    }

    // --- sending -------------------------------------------------------------
    private func destination(_ id: String) -> MIDIEndpointRef? {
        guard let uid = Int32(id) else { return nil }
        var obj = MIDIObjectRef()
        var kind = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(uid, &obj, &kind) == noErr,
              kind == .destination || kind == .externalDestination else { return nil }
        return obj
    }

    private static let maxListSize = 65536

    // UMP words to one destination at one host time, never splitting a UMP
    // packet across lists (Chromium's MidiManagerMac::SendMidiData).
    private func sendWords(_ words: [UInt32], to dest: MIDIEndpointRef, at time: MIDITimeStamp) -> Bool {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: MIDIHub.maxListSize, alignment: 8)
        defer { buffer.deallocate() }
        let list = buffer.bindMemory(to: MIDIEventList.self, capacity: 1)
        let overhead = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet)!
            + MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
        let maxWords = (MIDIHub.maxListSize - overhead) / 4
        var sent = 0
        while sent < words.count {
            var n = 0
            while sent + n < words.count {
                let len = UMP.lengthInWords(words[sent + n])
                if len == 0 || n + len > maxWords { break }
                n += len
            }
            if n == 0 { return false }
            let packet = MIDIEventListInit(list, ._1_0)
            let added = words[sent..<sent + n].withContiguousStorageIfAvailable {
                MIDIEventListAdd(list, MIDIHub.maxListSize, packet, time, n, $0.baseAddress!)
            } ?? nil
            if added == nil || MIDISendEventList(outPort, dest, list) != noErr { return false }
            sent += n
        }
        return true
    }

    // Holds a timestamped send until `horizon` before it is due, then hands
    // it to CoreMIDI with its exact time.  Returns false when the client is
    // already holding its share.
    private func hold(_ words: [UInt32], to port: String, client: String, atWall ms: Double, bytes: Int) -> Bool {
        let host = MIDIHub.hostTime(atWallMillis: ms)
        lock.lock()
        let mine = heldBytes[client, default: 0]
        guard mine + bytes <= MIDIHub.maxHeldPerClient, heldTotal + bytes <= MIDIHub.maxHeldTotal else {
            lock.unlock(); return false
        }
        heldSeq += 1
        let item = Held(seq: heldSeq, client: client, port: port, words: words, host: host, bytes: bytes)
        // Insert after everything due at or before it: (due, submission) order.
        let at = held.firstIndex { $0.host > host } ?? held.count
        held.insert(item, at: at)
        heldBytes[client] = mine + bytes
        heldTotal += bytes
        lock.unlock()
        release()
        return true
    }

    // Hands CoreMIDI everything within `horizon` of its time, in order, and
    // sets the timer for the next.
    private func release() {
        let horizonHost = MIDIHub.nanosToHost(MIDIHub.horizon * 1e9)
        lock.lock()
        let now = mach_absolute_time()
        var due: [Held] = []
        while let first = held.first, first.host <= now + horizonHost {
            due.append(held.removeFirst())
            heldBytes[first.client, default: 0] -= first.bytes
            if heldBytes[first.client] == 0 { heldBytes[first.client] = nil }
            heldTotal -= first.bytes
        }
        let next = held.first?.host
        lock.unlock()
        for item in due {
            if let d = destination(item.port) { _ = sendWords(item.words, to: d, at: item.host) }
        }
        sendQueue.async { [self] in
            timer?.cancel(); timer = nil
            guard let next = next else { return }
            let wait = max(0, MIDIHub.hostToNanos(next) - MIDIHub.hostToNanos(mach_absolute_time())) / 1e9 - MIDIHub.horizon
            let t = DispatchSource.makeTimerSource(queue: sendQueue)
            t.schedule(deadline: .now() + max(0, wait), leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.release() }
            t.resume()
            timer = t
        }
    }

    // clear(): this client's sends to this port that are still waiting here
    // are dropped.  What is within `horizon` of its time has gone to CoreMIDI
    // and plays.  Not MIDIFlushOutput: it delivers a System Reset (FF) to the
    // destination (measured on a virtual destination, 2026-09-26), which would
    // reset the instrument rather than cancel a note.
    private func clear(_ port: String, client: String) {
        lock.lock()
        held.removeAll { item in
            guard item.port == port && item.client == client else { return false }
            heldBytes[item.client, default: 0] -= item.bytes
            if heldBytes[item.client] == 0 { heldBytes[item.client] = nil }
            heldTotal -= item.bytes
            return true
        }
        lock.unlock()
    }

    // --- requests ------------------------------------------------------------
    func handle(_ req: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        if let err = setupError { reply(["error": err]); return }
        switch req["cmd"] as? String {
        case "ports":
            lock.lock()
            connectSources()
            cachedGen = generation()
            let gen = cachedGen
            lock.unlock()
            reply([
                "gen": gen,
                "inputs": MIDIHub.sources().map(MIDIHub.describe),
                "outputs": MIDIHub.destinations().map(MIDIHub.describe),
            ])

        case "send":
            // midi_host.cc's checks: sysex needs its grant, and the bytes must
            // be whole Web MIDI messages; anything else is dropped.  Sends
            // without a time go now, after anything already due.
            let sysexAllowed = req["sysex"] as? Bool ?? false
            let client = req["client"] as? String ?? ""
            var failed: [String] = []
            release()
            for m in req["msgs"] as? [[Any]] ?? [] {
                guard m.count >= 2, let id = m[0] as? String, let b64 = m[1] as? String,
                      let data = Data(base64Encoded: b64) else { continue }
                let bytes = [UInt8](data)
                let at = m.count > 2 ? (m[2] as? NSNumber)?.doubleValue ?? 0 : 0
                guard !bytes.isEmpty, sysexAllowed || !bytes.contains(MIDIBytes.sysEx),
                      MIDIBytes.isValidWebMIDIData(bytes), let dest = destination(id) else {
                    failed.append(id); continue
                }
                let words = UMP.translateMidiToUmpWords(bytes)
                let ok = at > 0 ? hold(words, to: id, client: client, atWall: at, bytes: bytes.count)
                                : sendWords(words, to: dest, at: 0)
                if !ok { failed.append(id) }
            }
            reply(["ok": failed.isEmpty, "failed": failed])

        case "clear":
            if let id = req["port"] as? String { clear(id, client: req["client"] as? String ?? "") }
            reply(["ok": true])

        case "recv":
            let since = (req["since"] as? NSNumber)?.intValue ?? -1
            let gen = req["gen"] as? String
            let sysex = req["sysex"] as? Bool ?? false
            let wait = min(max((req["wait"] as? NSNumber)?.intValue ?? 0, 0), 5000)
            lock.lock()
            lastRecv = Date()
            let end = base + events.count
            let ready = (since >= 0 && since < end) || (gen != nil && gen != cachedGen) || wait == 0
            if ready {
                lock.unlock()
                reply(recvReply(since: since, sysex: sysex))
                return
            }
            // A cursor of -1 means "from now": pin it.  Whichever comes first,
            // an arrival or the timeout, takes the waiter out under the lock
            // and answers; the other finds it gone.
            let pinned = since < 0 ? end : since
            let token = UUID()
            waiters.append((token, pinned, sysex, reply))
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(wait)) { [self] in
                lock.lock()
                connectSources()
                cachedGen = generation()
                let mine = waiters.firstIndex { $0.token == token }
                if let i = mine { waiters.remove(at: i) }
                lock.unlock()
                if mine != nil { reply(recvReply(since: pinned, sysex: sysex)) }
            }

        default:
            reply(["error": "unknown request"])
        }
    }
}
