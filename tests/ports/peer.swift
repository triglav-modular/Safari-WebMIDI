import CoreMIDI
import Foundation

// Another process's ports, for the hub test: one source streams MIDI clock
// while others come and go one after another, as an instrument does while
// it is reflashed or replugged and the rest of a rig keeps playing.
//   hub-peer STREAM_NAME PREFIX COUNT ALIVE_S GAP_S
// streams on STREAM_NAME, then COUNT times creates PREFIX1, PREFIX2, ...,
// keeps each ALIVE_S seconds, starts the next GAP_S after the one before,
// and exits a second after the last is gone.
let a = CommandLine.arguments
guard a.count == 6, let count = Int(a[3]), let alive = Double(a[4]), let gap = Double(a[5]) else {
    FileHandle.standardError.write("usage: hub-peer STREAM_NAME PREFIX COUNT ALIVE_S GAP_S\n".data(using: .utf8)!)
    exit(2)
}
var client = MIDIClientRef(), stream = MIDIEndpointRef()
MIDIClientCreateWithBlock("hub peer" as CFString, &client, nil)
MIDISourceCreateWithProtocol(client, a[1] as CFString, ._1_0, &stream)
Thread {
    var list = MIDIEventList()
    var clock: UInt32 = 0x10F8_0000
    while true {
        let p = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, p, 0, 1, &clock)
        MIDIReceivedEventList(stream, &list)
        usleep(1000)
    }
}.start()
for k in 1...count {
    var src = MIDIEndpointRef()
    MIDISourceCreateWithProtocol(client, "\(a[2])\(k)" as CFString, ._1_0, &src)
    Thread.sleep(forTimeInterval: alive)
    MIDIEndpointDispose(src)
    Thread.sleep(forTimeInterval: max(0, gap - alive))
}
Thread.sleep(forTimeInterval: 1)
exit(0)
