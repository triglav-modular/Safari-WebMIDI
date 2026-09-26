// MIDI byte streams and Universal MIDI Packets, ported from Chromium:
//   media/midi/message_util.cc       GetMessageLength, IsValidWebMIDIData
//   media/midi/midi_message_queue.cc MidiMessageQueue
//   media/midi/ump_message_util.cc   ParseMidiMessages, TranslateMidiToUmpWords,
//                                    DispatchMidiFromUmpWords, GetUmpLengthInWords
// Copyright 2013 The Chromium Authors.  Use of this source code is governed
// by a BSD-style license that can be found in third_party/chromium/LICENSE.
// The port keeps Chromium's structure and behaviour, so a site sees the
// messages Chrome would give it.

import Foundation

enum MIDIBytes {
    static let sysEx: UInt8 = 0xf0
    static let endOfSysEx: UInt8 = 0xf7

    static func messageLength(_ status: UInt8) -> Int {
        if status < 0x80 { return 0 }
        if status <= 0xbf { return 3 }
        if status <= 0xdf { return 2 }
        if status <= 0xef { return 3 }
        switch status {
        case 0xf0: return 0
        case 0xf1: return 2
        case 0xf2: return 3
        case 0xf3: return 2
        case 0xf4, 0xf5: return 0   // reserved
        case 0xf6: return 1
        case 0xf7: return 0
        default: return 1           // 0xf8...0xff
        }
    }
    static func isDataByte(_ b: UInt8) -> Bool { b & 0x80 == 0 }
    static func isSystemRealTime(_ b: UInt8) -> Bool { b >= 0xf8 }
    static func isSystemMessage(_ b: UInt8) -> Bool { b >= 0xf0 }

    // What the browser process accepts from a page before sending.
    static func isValidWebMIDIData(_ data: [UInt8]) -> Bool {
        var inSysex = false
        var waiting = 0
        for current in data {
            if isSystemRealTime(current) { continue }
            if waiting > 0 {
                if !isDataByte(current) { return false }
                waiting -= 1
                continue
            }
            if inSysex {
                if current == endOfSysEx { inSysex = false }
                else if !isDataByte(current) { return false }
                continue
            }
            if current == sysEx { inSysex = true; continue }
            waiting = messageLength(current)
            if waiting == 0 { return false }
            waiting -= 1
        }
        return waiting == 0 && !inSysex
    }
}

// Splits a received byte stream into whole messages.  Real-time bytes are
// taken out ahead of the message they interrupt; running status is allowed
// on input.
final class MIDIMessageQueue {
    private var queue: [UInt8] = []
    private var head = 0
    private var next: [UInt8] = []
    private let allowRunningStatus: Bool

    init(allowRunningStatus: Bool) { self.allowRunningStatus = allowRunningStatus }

    func add(_ data: [UInt8]) {
        if head > 4096 { queue.removeFirst(head); head = 0 }
        queue.append(contentsOf: data)
    }

    // The next whole message, or [] when there is none yet.
    func get() -> [UInt8] {
        while true {
            if let status = next.first {
                let target = MIDIBytes.messageLength(status)
                if target == 0 {
                    if next.last == MIDIBytes.endOfSysEx && next.count > 1 {
                        defer { next = [] }
                        return next
                    }
                } else if next.count == target {
                    let message = next
                    next = []
                    if allowRunningStatus && !MIDIBytes.isSystemMessage(status) {
                        // Speculatively keep the status in case of running status.
                        next.append(status)
                    }
                    return message
                }
            }
            if head >= queue.count { return [] }
            let byte = queue[head]
            if MIDIBytes.isSystemRealTime(byte) {
                head += 1
                return [byte]
            }
            if next.isEmpty {
                if MIDIBytes.messageLength(byte) > 0 || byte == MIDIBytes.sysEx { next.append(byte) }
                head += 1
                continue
            }
            let status = next[0]
            // A new status byte before the pending message is complete drops
            // the pending one (and any speculative running status).
            if !MIDIBytes.isDataByte(byte) && !(status == MIDIBytes.sysEx && byte == MIDIBytes.endOfSysEx) {
                next = []
                continue
            }
            next.append(byte)
            head += 1
        }
    }
}

enum UMP {
    static let utility: UInt32 = 0x0, system: UInt32 = 0x1, midi1ChannelVoice: UInt32 = 0x2
    static let sysEx7: UInt32 = 0x3, midi2ChannelVoice: UInt32 = 0x4, sysEx8: UInt32 = 0x5
    static let flexData: UInt32 = 0xd, stream: UInt32 = 0xf
    static let sysExComplete: UInt32 = 0, sysExStart: UInt32 = 1, sysExContinue: UInt32 = 2, sysExEnd: UInt32 = 3

    static func messageType(_ w: UInt32) -> UInt32 { (w >> 28) & 0xf }

    static func lengthInWords(_ first: UInt32) -> Int {
        switch messageType(first) {
        case utility, system, midi1ChannelVoice: return 1
        case sysEx7, midi2ChannelVoice: return 2
        case sysEx8, flexData, stream: return 4
        default: return 0
        }
    }

    struct Message { let isSysex: Bool; let data: [UInt8] }

    // Splits outgoing bytes into messages; a real-time byte inside a message
    // becomes its own message and the one it interrupted is rebuilt without it.
    static func parseMidiMessages(_ data: [UInt8]) -> [Message] {
        var messages: [Message] = []
        var index = 0
        var inSysex = false, sysexStart = 0, sysexHasRealtime = false
        var sysexRebuilt: [UInt8] = []
        var inChannel = false, channelStart = 0, channelHasRealtime = false
        var channelRebuilt: [UInt8] = []
        var expected = 0

        func endSysex(through end: Int) {
            if sysexHasRealtime { messages.append(Message(isSysex: true, data: sysexRebuilt)); sysexRebuilt = [] }
            else { messages.append(Message(isSysex: true, data: Array(data[sysexStart..<end]))) }
        }

        while index < data.count {
            let status = data[index]
            if status < 0x80 {
                if inSysex {
                    if sysexHasRealtime { sysexRebuilt.append(status) }
                } else if inChannel {
                    if channelHasRealtime { channelRebuilt.append(status) }
                    let len = channelHasRealtime ? channelRebuilt.count : index + 1 - channelStart
                    if len == expected {
                        if channelHasRealtime {
                            messages.append(Message(isSysex: false, data: channelRebuilt)); channelRebuilt = []
                        } else {
                            messages.append(Message(isSysex: false, data: Array(data[channelStart..<channelStart + expected])))
                        }
                        inChannel = false
                    }
                }
                index += 1
                continue
            }
            if status >= 0xf8 {
                messages.append(Message(isSysex: false, data: [status]))
                if inSysex {
                    if !sysexHasRealtime { sysexHasRealtime = true; sysexRebuilt = Array(data[sysexStart..<index]) }
                } else if inChannel {
                    if !channelHasRealtime { channelHasRealtime = true; channelRebuilt = Array(data[channelStart..<index]) }
                }
                index += 1
            } else if status == 0xf0 {
                if inSysex { endSysex(through: index) }
                if inChannel { channelRebuilt = []; inChannel = false }
                inSysex = true; sysexStart = index; sysexHasRealtime = false
                index += 1
            } else if status == 0xf7 {
                if inSysex {
                    if sysexHasRealtime { sysexRebuilt.append(status) }
                    endSysex(through: index + 1)
                    inSysex = false
                }
                if inChannel { channelRebuilt = []; inChannel = false }
                index += 1
            } else {
                if inSysex { endSysex(through: index); inSysex = false }
                if inChannel { channelRebuilt = []; inChannel = false }
                var len = 0
                let kind = status & 0xf0
                if kind == 0xc0 || kind == 0xd0 || status == 0xf1 || status == 0xf3 { len = 2 }
                else if (kind >= 0x80 && kind <= 0xe0) || status == 0xf2 { len = 3 }
                else if status == 0xf6 { len = 1 }
                if len == 1 {
                    messages.append(Message(isSysex: false, data: [status]))
                } else if len > 1 {
                    inChannel = true; channelStart = index; channelHasRealtime = false; expected = len
                }
                index += 1
            }
        }
        if inSysex {
            if sysexHasRealtime {
                if !sysexRebuilt.isEmpty { messages.append(Message(isSysex: true, data: sysexRebuilt)) }
            } else {
                messages.append(Message(isSysex: true, data: Array(data[sysexStart...])))
            }
        }
        return messages
    }

    // Outgoing bytes as UMP words (MIDI 1.0 protocol, one group).
    static func translateMidiToUmpWords(_ data: [UInt8], group: UInt32 = 0) -> [UInt32] {
        var words: [UInt32] = []
        for message in parseMidiMessages(data) {
            let d = message.data
            if !message.isSysex {
                guard let status = d.first else { continue }
                let type = status >= 0xf0 ? system : midi1ChannelVoice
                var w = type << 28 | (group & 0xf) << 24 | UInt32(status) << 16
                if d.count >= 2 { w |= UInt32(d[1]) << 8 }
                if d.count >= 3 { w |= UInt32(d[2]) }
                words.append(w)
                continue
            }
            guard d.count >= 2, d.first == 0xf0, d.last == 0xf7 else { continue }
            let body = Array(d[1..<d.count - 1])
            var offset = 0
            repeat {
                let n = min(body.count - offset, 6)
                let status: UInt32 = body.count <= 6 ? sysExComplete
                    : offset == 0 ? sysExStart
                    : offset + n == body.count ? sysExEnd : sysExContinue
                var b = [UInt8](repeating: 0, count: 6)
                for i in 0..<n { b[i] = body[offset + i] }
                words.append(sysEx7 << 28 | (group & 0xf) << 24 | status << 20 | UInt32(n) << 16
                             | UInt32(b[0]) << 8 | UInt32(b[1]))
                words.append(UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5]))
                offset += n
            } while offset < body.count
        }
        return words
    }

    // Incoming UMP words as byte fragments: whole short messages, and sysex
    // in pieces (F0 opens the first, F7 closes the last), for a
    // MIDIMessageQueue to put back together.
    static func dispatchMidiFromUmpWords(_ words: UnsafeBufferPointer<UInt32>, _ emit: ([UInt8]) -> Void) {
        var i = 0
        while i < words.count {
            let w0 = words[i]
            let len = lengthInWords(w0)
            if len == 0 || i + len > words.count { break }
            let type = messageType(w0)
            let status = UInt8((w0 >> 16) & 0xff), d1 = UInt8((w0 >> 8) & 0xff), d2 = UInt8(w0 & 0xff)
            if type == system {
                var n = 0
                if status == 0xf1 || status == 0xf3 { n = 2 }
                else if status == 0xf2 { n = 3 }
                else if status == 0xf6 || status >= 0xf8 { n = 1 }
                if n > 0 { emit(Array([status, d1, d2].prefix(n))) }
            } else if type == midi1ChannelVoice {
                let kind = status & 0xf0
                let n = (kind == 0xc0 || kind == 0xd0) ? 2 : (kind >= 0x80 && kind <= 0xe0) ? 3 : 0
                if n > 0 { emit(Array([status, d1, d2].prefix(n))) }
            } else if type == sysEx7 {
                let w1 = words[i + 1]
                let form = (w0 >> 20) & 0xf, count = Int((w0 >> 16) & 0xf)
                if form <= sysExEnd && count <= 6 {
                    let payload = [d1, d2, UInt8(w1 >> 24), UInt8((w1 >> 16) & 0xff), UInt8((w1 >> 8) & 0xff), UInt8(w1 & 0xff)]
                    var message: [UInt8] = []
                    if form == sysExComplete || form == sysExStart { message.append(0xf0) }
                    message.append(contentsOf: payload.prefix(count))
                    if form == sysExComplete || form == sysExEnd { message.append(0xf7) }
                    if !message.isEmpty { emit(message) }
                }
            }
            i += len
        }
    }
}
