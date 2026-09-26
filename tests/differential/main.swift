import Foundation

// Differential test: the Swift port against Chromium's own code, compiled
// from the pinned commit, on the same random inputs.  Any difference fails.
//   ./tools/test-differential.sh [iterations]
var rng = SystemRandomNumberGenerator()
let iterations = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 100_000
var failures = 0, shown = 0
func differ(_ what: String, _ input: String, _ a: String, _ b: String) {
    failures += 1
    if shown < 8 { shown += 1; print("DIFF  \(what)\n  input    \(input)\n  chromium \(a)\n  port     \(b)") }
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func hexw(_ w: [UInt32]) -> String { w.map { String(format: "%08X", $0) }.joined(separator: " ") }

// Bytes shaped like MIDI: statuses, data, sysex runs, real-time interruptions,
// reserved and stray bytes, and cut-off messages.
func randomStream() -> [UInt8] {
    var out: [UInt8] = []
    let parts = Int.random(in: 0...8, using: &rng)
    for _ in 0..<parts {
        switch Int.random(in: 0..<10, using: &rng) {
        case 0...3:
            let s = UInt8.random(in: 0x80...0xef, using: &rng)
            out.append(s)
            for _ in 0..<Int.random(in: 0...4, using: &rng) { out.append(UInt8.random(in: 0...0x7f, using: &rng)) }
        case 4:
            out.append(0xf0)
            for _ in 0..<Int.random(in: 0...20, using: &rng) {
                out.append(Int.random(in: 0..<12, using: &rng) == 0 ? UInt8.random(in: 0xf8...0xff, using: &rng)
                                                                     : UInt8.random(in: 0...0x7f, using: &rng))
            }
            if Int.random(in: 0..<4, using: &rng) > 0 { out.append(0xf7) }
        case 5: out.append(UInt8.random(in: 0xf8...0xff, using: &rng))
        case 6:
            out.append(UInt8.random(in: 0xf1...0xf7, using: &rng))
            for _ in 0..<Int.random(in: 0...2, using: &rng) { out.append(UInt8.random(in: 0...0x7f, using: &rng)) }
        case 7: out.append(UInt8.random(in: 0...0xff, using: &rng))
        case 8: // A real-time byte dropped inside the last message.
            if !out.isEmpty { out.insert(UInt8.random(in: 0xf8...0xff, using: &rng), at: Int.random(in: 0..<out.count, using: &rng)) }
        default:
            for _ in 0..<Int.random(in: 1...3, using: &rng) { out.append(UInt8.random(in: 0...0x7f, using: &rng)) }
        }
    }
    return out
}
func randomWords() -> [UInt32] {
    (0..<Int.random(in: 0...12, using: &rng)).map { _ in
        let type = UInt32([0, 1, 1, 2, 2, 2, 3, 3, 3, 4, 5, 6, 0xd, 0xf].randomElement(using: &rng)!)
        return type << 28 | UInt32.random(in: 0..<(1 << 28), using: &rng)
    }
}

func chromiumMessages(_ buf: [UInt8], _ used: Int) -> [[UInt8]] {
    var out: [[UInt8]] = [], at = 0
    while at + 3 <= used {
        let n = Int(buf[at + 1]) | Int(buf[at + 2]) << 8
        out.append([buf[at]] + Array(buf[(at + 3)..<(at + 3 + n)]))
        at += 3 + n
    }
    return out
}
var buf = [UInt8](repeating: 0, count: 1 << 16)
var wbuf = [UInt32](repeating: 0, count: 1 << 14)

for s in 0...255 where cr_length(UInt8(s)) != MIDIBytes.messageLength(UInt8(s)) {
    differ("GetMessageLength", String(format: "%02X", s), "\(cr_length(UInt8(s)))", "\(MIDIBytes.messageLength(UInt8(s)))")
}

var counts = [String: Int]()
for _ in 0..<iterations {
    let data = randomStream()
    let n = data.count

    let v1 = data.withUnsafeBufferPointer { cr_valid($0.baseAddress, n) } != 0
    if v1 != MIDIBytes.isValidWebMIDIData(data) { differ("IsValidWebMIDIData", hex(data), "\(v1)", "\(!v1)") }
    if v1 { counts["valid", default: 0] += 1 }

    let used = data.withUnsafeBufferPointer { cr_parse($0.baseAddress, n, &buf, buf.count) }
    let cp = chromiumMessages(buf, used)
    let sp = UMP.parseMidiMessages(data).map { [$0.isSysex ? 1 : 0] + $0.data }
    if cp != sp { differ("ParseMidiMessages", hex(data), "\(cp.map(hex))", "\(sp.map(hex))") }

    let wn = data.withUnsafeBufferPointer { cr_translate($0.baseAddress, n, &wbuf, wbuf.count) }
    let cw = Array(wbuf[0..<wn]), sw = UMP.translateMidiToUmpWords(data)
    if cw != sw { differ("TranslateMidiToUmpWords", hex(data), hexw(cw), hexw(sw)) }

    for words in [cw, randomWords()] {
        let du = words.withUnsafeBufferPointer { cr_dispatch($0.baseAddress, words.count, &buf, buf.count) }
        let cd = chromiumMessages(buf, du).map { Array($0.dropFirst()) }
        var sd: [[UInt8]] = []
        words.withUnsafeBufferPointer { UMP.dispatchMidiFromUmpWords($0) { sd.append($0) } }
        if cd != sd { differ("DispatchMidiFromUmpWords", hexw(words), "\(cd.map(hex))", "\(sd.map(hex))") }
    }

    let cuts = (0..<Int.random(in: 0...3, using: &rng)).map { _ in Int.random(in: 0...n, using: &rng) }.sorted()
    for running in [false, true] {
        let qu = data.withUnsafeBufferPointer { d in
            cuts.withUnsafeBufferPointer { c in cr_queue(running ? 1 : 0, d.baseAddress, n, c.baseAddress, c.count, &buf, buf.count) }
        }
        let cq = chromiumMessages(buf, qu).map { Array($0.dropFirst()) }
        let q = MIDIMessageQueue(allowRunningStatus: running)
        var sq: [[UInt8]] = [], from = 0
        for to in cuts + [n] {
            q.add(Array(data[from..<to])); from = to
            // A queue that keeps answering is a failure, not a hang: no
            // input here holds more messages than it has bytes.
            var drained = 0
            while true {
                let m = q.get(); if m.isEmpty { break }; sq.append(m)
                drained += 1
                if drained > n + 1 { sq.append([0xde, 0xad]); break }
            }
        }
        if cq != sq { differ("MidiMessageQueue(running: \(running))", hex(data) + " cut at \(cuts)", "\(cq.map(hex))", "\(sq.map(hex))") }
        counts["queued messages", default: 0] += sq.count
    }
}
print("\(iterations) random streams; \(counts["valid"] ?? 0) of them valid Web MIDI data; \(counts["queued messages"] ?? 0) messages out of the queues")
print(failures == 0 ? "PORT MATCHES CHROMIUM" : "\(failures) DIFFERENCES")
exit(failures == 0 ? 0 : 1)
