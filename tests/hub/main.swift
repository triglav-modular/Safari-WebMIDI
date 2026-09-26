import CoreMIDI
import Foundation

// MIDIHub against a virtual instrument in this process: whatever reaches
// its destination comes back out of its source of the same name.
//   ./tools/test-hub.sh
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    let d = ok ? "" : detail()
    print((ok ? "ok    " : "FAIL  ") + name + (d.isEmpty ? "" : "  - " + d)); fflush(stdout)
    if !ok { failures += 1 }
}
func ask(_ req: [String: Any]) -> [String: Any] {
    let sem = DispatchSemaphore(value: 0)
    var out: [String: Any] = [:]
    MIDIHub.shared.handle(req) { out = $0; sem.signal() }
    sem.wait()
    return out
}
func b64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }
func unb64(_ s: Any) -> [UInt8] { [UInt8](Data(base64Encoded: s as? String ?? "") ?? Data()) }
func now() -> Double { Date().timeIntervalSince1970 * 1000 }

var client = MIDIClientRef(), src = MIDIEndpointRef(), dst = MIDIEndpointRef()
var arrivals: [(Double, Int)] = []   // wall ms and word count at the destination
let arrivalsLock = NSLock()
MIDIClientCreateWithBlock("loop" as CFString, &client, nil)
MIDISourceCreateWithProtocol(client, "WM Loop" as CFString, ._1_0, &src)
MIDIDestinationCreateWithProtocol(client, "WM Loop" as CFString, ._1_0, &dst) { list, _ in
    arrivalsLock.lock(); arrivals.append((now(), Int(list.pointee.packet.wordCount))); arrivalsLock.unlock()
    MIDIReceivedEventList(src, list)
}

// Collects events from a cursor until `count` arrive or `ms` pass.
func collect(from cursor: inout Int, count: Int, ms: Int, sysex: Bool = true) -> [[Any]] {
    var got: [[Any]] = []
    let deadline = Date().addingTimeInterval(Double(ms) / 1000)
    while got.count < count && Date() < deadline {
        let r = ask(["cmd": "recv", "since": cursor, "wait": 300, "sysex": sysex])
        got += r["events"] as? [[Any]] ?? []
        cursor = r["seq"] as? Int ?? cursor
    }
    return got
}

DispatchQueue.global().async {
    Thread.sleep(forTimeInterval: 0.3)
    let ports = ask(["cmd": "ports"])
    let outs = ports["outputs"] as? [[String: Any]] ?? [], ins = ports["inputs"] as? [[String: Any]] ?? []
    guard let out = outs.first(where: { $0["name"] as? String == "WM Loop" })?["id"] as? String,
          let inp = ins.first(where: { $0["name"] as? String == "WM Loop" })?["id"] as? String else {
        check("the loop is listed both ways", false, "\(ports)"); exit(1)
    }
    check("the loop is listed both ways", true)
    var cursor = ask(["cmd": "recv", "since": -1, "wait": 0])["seq"] as? Int ?? 0

    // Short messages, in order, from the input of the same name.
    let short: [[UInt8]] = [[0xb0, 99, 0x10], [0xb0, 98, 5], [0x90, 60, 100], [0x80, 60, 0], [0xc3, 7], [0xf8], [0xf2, 1, 2]]
    _ = ask(["cmd": "send", "msgs": [[out, b64(short.flatMap { $0 }), 0]]])
    let back = collect(from: &cursor, count: short.count, ms: 2000)
    check("short messages come back whole and in order", back.map { unb64($0[1]) } == short, "\(back)")
    check("from the input of the same name", back.allSatisfy { $0[0] as? String == inp })
    let t = back.first?[2] as? Double ?? 0
    check("a received message carries a wall-clock time", abs(t - now()) < 1000, "\(t) vs \(now())")

    // Sysex, short and long, with a clock byte inside one.
    let small: [UInt8] = [0xf0, 0x7e, 0x7f, 0x06, 0x01, 0xf7]
    var big: [UInt8] = [0xf0, 0x7d]
    for i in 0..<10_000 { big.append(UInt8(i % 128)) }
    big.append(0xf7)
    _ = ask(["cmd": "send", "sysex": true, "msgs": [[out, b64(small), 0], [out, b64(big), 0]]])
    let sx = collect(from: &cursor, count: 2, ms: 4000)
    check("a short sysex comes back whole", sx.count > 0 && unb64(sx[0][1]) == small, "\(sx.first.map { unb64($0[1]) } ?? [])")
    check("a 10 kB sysex comes back whole", sx.count > 1 && unb64(sx[1][1]) == big, "got \(sx.count > 1 ? unb64(sx[1][1]).count : 0) bytes")
    _ = ask(["cmd": "send", "sysex": true, "msgs": [[out, b64([0xf0, 1, 2, 0xf8, 3, 0xf7]), 0]]])
    let rt = collect(from: &cursor, count: 2, ms: 2000).map { unb64($0[1]) }
    check("a clock byte inside a sysex comes out on its own", Set(rt) == Set([[0xf8], [0xf0, 1, 2, 3, 0xf7]]), "\(rt)")

    // Sysex needs the grant, both ways.
    let refused = ask(["cmd": "send", "msgs": [[out, b64(small), 0]]])
    check("sysex without the grant is refused", (refused["failed"] as? [String]) == [out], "\(refused)")
    _ = ask(["cmd": "send", "sysex": true, "msgs": [[out, b64(small), 0], [out, b64([0x90, 1, 1]), 0]]])
    let filtered = collect(from: &cursor, count: 1, ms: 1000, sysex: false).map { unb64($0[1]) }
    check("a receive without the grant sees no sysex", filtered == [[0x90, 1, 1]], "\(filtered)")

    // Bytes that are not whole messages are refused.
    for bad: [UInt8] in [[0x90, 60], [0x3c], [0xf0, 1, 2], [0x90, 0x80, 1], [0xf4]] {
        let r = ask(["cmd": "send", "sysex": true, "msgs": [[out, b64(bad), 0]]])
        check("refuses \(bad.map { String(format: "%02X", $0) }.joined(separator: " "))", (r["failed"] as? [String]) == [out], "\(r)")
    }

    // A timestamp schedules the send: it reaches the destination then, not now.
    arrivalsLock.lock(); arrivals = []; arrivalsLock.unlock()
    let due = now() + 250
    _ = ask(["cmd": "send", "msgs": [[out, b64([0x90, 64, 1]), due]]])
    Thread.sleep(forTimeInterval: 0.4)
    arrivalsLock.lock(); let when = arrivals.first?.0; arrivalsLock.unlock()
    check("a timestamped send arrives on time", when.map { abs($0 - due) < 5 } ?? false, when.map { "\(String(format: "%.1f", $0 - due)) ms off" } ?? "never arrived")
    _ = collect(from: &cursor, count: 1, ms: 500)

    // clear() unschedules what has not played yet.
    arrivalsLock.lock(); arrivals = []; arrivalsLock.unlock()
    _ = ask(["cmd": "send", "msgs": [[out, b64([0x90, 65, 1]), now() + 300]]])
    _ = ask(["cmd": "clear", "port": out])
    let clearedAt = now()
    Thread.sleep(forTimeInterval: 0.5)
    arrivalsLock.lock(); let cleared = arrivals.isEmpty; let seen = arrivals; arrivalsLock.unlock()
    check("clear() cancels a scheduled send", cleared, "arrived: \(seen.map { String(format: "%.1f ms after the clear, %d words", $0.0 - clearedAt, $0.1) })")

    // Sends given the same time go out in the order they were made: a
    // note-off and the note-on that follows it, 120 pairs, on the held path
    // in one request, in separate requests, and inside the horizon.
    func pairsReversed(_ label: String, sameRequest: Bool, ahead: Double) -> Int {
        _ = collect(from: &cursor, count: 10_000, ms: 300)      // drain
        for i in 0..<120 {
            let due = now() + ahead + Double(i) * 2
            let off = b64([0x81, UInt8(i % 128), 0]), on = b64([0x91, UInt8(i % 128), 100])
            if sameRequest {
                _ = ask(["cmd": "send", "msgs": [[out, off, due], [out, on, due]]])
            } else {
                _ = ask(["cmd": "send", "msgs": [[out, off, due]]])
                _ = ask(["cmd": "send", "msgs": [[out, on, due]]])
            }
        }
        let got = collect(from: &cursor, count: 240, ms: 3000).map { unb64($0[1]) }.filter { $0[0] == 0x81 || $0[0] == 0x91 }
        var seenOff = Set<UInt8>(), reversed = 0
        for m in got {
            if m[0] == 0x81 { seenOff.insert(m[1]) } else if !seenOff.contains(m[1]) { reversed += 1 }
        }
        check("\(label): all 240 arrive", got.count == 240, "got \(got.count)")
        return reversed
    }
    for (label, same, ahead) in [("held, one request", true, 150.0), ("held, separate requests", false, 150.0),
                                  ("inside the horizon", false, 5.0)] {
        let r = pairsReversed(label, sameRequest: same, ahead: ahead)
        check("equal times keep their order (\(label))", r == 0, "\(r) of 120 pairs reversed")
    }

    // One page's clear() leaves another page's sends alone.
    arrivalsLock.lock(); arrivals = []; arrivalsLock.unlock()
    _ = ask(["cmd": "send", "client": "A", "msgs": [[out, b64([0x92, 1, 1]), now() + 300]]])
    _ = ask(["cmd": "send", "client": "B", "msgs": [[out, b64([0x92, 2, 1]), now() + 300]]])
    _ = ask(["cmd": "clear", "port": out, "client": "A"])
    Thread.sleep(forTimeInterval: 0.5)
    arrivalsLock.lock(); let afterClear = arrivals.count; arrivalsLock.unlock()
    check("clear() drops only its own page's sends", afterClear == 1, "\(afterClear) arrived")
    _ = collect(from: &cursor, count: 10, ms: 300)

    // No page can make the extension hold more than its share.
    var huge: [UInt8] = [0xf0]; huge += [UInt8](repeating: 0x11, count: 3 << 20); huge.append(0xf7)
    let far = now() + 60_000
    var capped = false
    for _ in 0..<5 {
        let r = ask(["cmd": "send", "client": "C", "sysex": true, "msgs": [[out, b64(huge), far]]])
        if (r["failed"] as? [String])?.isEmpty == false { capped = true; break }
    }
    check("a page cannot hold more than 10 MB of scheduled sends", capped)
    _ = ask(["cmd": "clear", "port": out, "client": "C"])

    // Long poll: idle holds, an arrival answers early, a port change wakes it.
    var t0 = Date()
    let idle = ask(["cmd": "recv", "since": cursor, "wait": 300])
    let held = Date().timeIntervalSince(t0)
    check("an idle receive waits and returns nothing", (idle["events"] as? [Any])?.isEmpty == true && held > 0.25 && held < 0.6, "\(held)s")
    let gen = ask(["cmd": "ports"])["gen"] as? String
    let sem = DispatchSemaphore(value: 0)
    var woke: [String: Any] = [:]
    t0 = Date()
    MIDIHub.shared.handle(["cmd": "recv", "since": cursor, "gen": gen as Any, "wait": 5000]) { woke = $0; sem.signal() }
    var extra = MIDIEndpointRef()
    DispatchQueue.main.async { MIDISourceCreateWithProtocol(client, "WM Extra" as CFString, ._1_0, &extra) }
    sem.wait()
    check("a new port wakes the receive with a new generation", woke["gen"] as? String != gen && Date().timeIntervalSince(t0) < 3.5,
          "\(Date().timeIntervalSince(t0)) s")

    let bad = ask(["cmd": "send", "msgs": [["12345", b64([0x90, 1, 1]), 0]]])
    check("a port that is gone reports failure", (bad["failed"] as? [String]) == ["12345"], "\(bad)")

    print(failures == 0 ? "ALL HUB CHECKS PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
