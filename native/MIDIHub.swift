import CoreMIDI
import Foundation

// CoreMIDI behind the extension.  One hub per extension process; every
// request from every tab lands here, and the state (the connections, the
// received messages) carries from one request to the next.
//
// Requests, as dictionaries from the background page:
//   ports                                  -> { gen, inputs: [port], outputs: [port] }
//   send   msgs: [[port, base64, t]], sysex -> { ok, failed: [port] }
//   clear  port                            -> { ok }
//   recv   since, gen, wait, sysex         -> { seq, gen, events: [[port, base64, t]] }
// A port is { id, name, manufacturer, version }.  Times are milliseconds
// since 1970 (the page's performance.timeOrigin + performance.now()), so
// both sides share a clock without sharing a process; 0 means "now".
// `recv` is a long poll: it answers as soon as a message arrives after
// `since` or the port list differs from `gen`, or after `wait` ms.
//
// Port info, the byte handling and the send path follow Chromium's
// media/midi/midi_manager_mac.cc and midi_host.cc (see MIDIMessages.swift).
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
    // Sends waiting for their time, by destination id.
    private var held: [String: [DispatchWorkItem]] = [:]
    private let sendQueue = DispatchQueue(label: "webmidi.send", qos: .userInteractive)
    static let horizon = 0.020
    static let maxInFlight = 10 << 20

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
    // Host time of a wall-clock instant, and back, through "now" on both.
    static func hostTime(atWallMillis ms: Double) -> UInt64 {
        let now = mach_absolute_time(), wall = wallMillis()
        let ahead = (ms - wall) * 1e6
        return ahead <= 0 ? 0 : now + nanosToHost(ahead)
    }
    static func wallMillis(atHost h: UInt64) -> Double {
        let now = mach_absolute_time(), wall = wallMillis()
        if h == 0 { return wall }
        return wall - (hostToNanos(now) - hostToNanos(h)) / 1e6
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

    // Sends now, or holds the send until `horizon` before it is due and then
    // hands it to CoreMIDI with its exact time.
    private func schedule(_ words: [UInt32], to id: String, dest: MIDIEndpointRef, atWall ms: Double) -> Bool {
        let ahead = ms > 0 ? (ms - MIDIHub.wallMillis()) / 1000 : 0
        if ahead <= MIDIHub.horizon {
            return sendWords(words, to: dest, at: ms > 0 ? MIDIHub.hostTime(atWallMillis: ms) : 0)
        }
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [self] in
            lock.lock()
            held[id]?.removeAll { $0 === item }
            lock.unlock()
            if let d = destination(id) { _ = sendWords(words, to: d, at: MIDIHub.hostTime(atWallMillis: ms)) }
        }
        lock.lock(); held[id, default: []].append(item); lock.unlock()
        sendQueue.asyncAfter(deadline: .now() + ahead - MIDIHub.horizon, execute: item)
        return true
    }

    // clear(): what is still waiting here is dropped.  What is within
    // `horizon` of its time has gone to CoreMIDI and plays.  Not
    // MIDIFlushOutput: it delivers a System Reset (FF) to the destination
    // (measured on a virtual destination, 2026-09-26), which would reset the
    // instrument rather than cancel a note.
    private func clear(_ id: String) {
        lock.lock()
        let items = held.removeValue(forKey: id) ?? []
        lock.unlock()
        items.forEach { $0.cancel() }
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
            // be whole Web MIDI messages; anything else is dropped.
            let sysexAllowed = req["sysex"] as? Bool ?? false
            var failed: [String] = []
            for m in req["msgs"] as? [[Any]] ?? [] {
                guard m.count >= 2, let id = m[0] as? String, let b64 = m[1] as? String,
                      let data = Data(base64Encoded: b64) else { continue }
                let bytes = [UInt8](data)
                let at = m.count > 2 ? (m[2] as? NSNumber)?.doubleValue ?? 0 : 0
                guard !bytes.isEmpty, sysexAllowed || !bytes.contains(MIDIBytes.sysEx),
                      MIDIBytes.isValidWebMIDIData(bytes), let dest = destination(id),
                      schedule(UMP.translateMidiToUmpWords(bytes), to: id, dest: dest, atWall: at) else {
                    failed.append(id); continue
                }
            }
            reply(["ok": failed.isEmpty, "failed": failed])

        case "clear":
            if let id = req["port"] as? String { clear(id) }
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
