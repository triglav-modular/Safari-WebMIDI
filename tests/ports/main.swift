import CoreMIDI
import Foundation

// MIDIHub against another process's ports, in a process where the hub is
// the only CoreMIDI client and requests come on worker threads, as in the
// extension.  The hub test cannot show what this does: its own ports are in
// its own process, which always sees them, and its main-thread client let
// the hub see other processes' ports too.
//   ./tools/test-hub.sh
//
// One source in the other process streams while others come and go, as when
// an instrument is reflashed and the rest of a rig plays on.  The extension
// locked up for good (2026-10-07): CoreMIDI's notification thread,
// connecting the new source under the hub's lock, waited for the input
// thread, which waited for the lock.  And a client made on a worker thread
// often never saw another process's ports change.
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    let d = ok ? "" : detail()
    print((ok ? "ok    " : "FAIL  ") + name + (d.isEmpty ? "" : "  - " + d)); fflush(stdout)
    if !ok { failures += 1 }
}
func finish() -> Never {
    print(failures == 0 ? "ALL PORT CHECKS PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
// A request on a worker thread; nil if it has no answer in 3 s.
func ask(_ req: [String: Any]) -> [String: Any]? {
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var out: [String: Any]?
    DispatchQueue.global().async {
        MIDIHub.shared.handle(req) { r in lock.lock(); out = r; lock.unlock(); done.signal() }
    }
    guard done.wait(timeout: .now() + 3) == .success else { return nil }
    lock.lock(); defer { lock.unlock() }
    return out
}
func names(_ r: [String: Any]?) -> [String] {
    (r?["inputs"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
}
let blink = (1...8).map { "WM Blink \($0)" }
func theirs(_ n: [String]) -> [String] { n.filter { $0.hasPrefix("WM Blink") || $0 == "WM Stream" } }

DispatchQueue.global().async {
    // The hub first, as the extension's first request makes it.
    guard ask(["cmd": "ports"]) != nil else { check("the hub answers", false); finish() }
    let peer = Process()
    peer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("hub-peer")
    peer.arguments = ["WM Stream", "WM Blink ", "8", "1.2", "1.5"]
    try! peer.run()
    var listed = Set<String>(), asked = 0, hung = false
    while peer.isRunning {
        asked += 1
        let r = ask(asked % 2 == 0 ? ["cmd": "ports"] : ["cmd": "recv", "since": -1, "wait": 0])
        if r == nil { hung = true; break }
        listed.formUnion(names(r).filter(blink.contains))
        Thread.sleep(forTimeInterval: 0.05)
    }
    check("no request locks up while another process's ports come and go", !hung, "request \(asked) had no answer in 3 s")
    // A hub that locked up answers nothing more.
    if hung { peer.terminate(); finish() }
    check("ports another process adds are listed", listed == Set(blink), "saw \(listed.sorted())")
    var left = theirs(names(ask(["cmd": "ports"])))
    let gone = Date().addingTimeInterval(2)
    while !left.isEmpty && Date() < gone {
        Thread.sleep(forTimeInterval: 0.1)
        left = theirs(names(ask(["cmd": "ports"])))
    }
    check("and are no longer listed once that process is gone", left.isEmpty, "\(left)")
    finish()
}
RunLoop.main.run()
