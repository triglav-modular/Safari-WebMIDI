// C entry points onto Chromium's own code, for comparing with the port.
#include <cstring>
#include <vector>
#include "media/midi/message_util.h"
#include "media/midi/midi_message_queue.h"
#include "media/midi/ump_message_util.h"

using namespace midi;

// Writes each message as a length (2 bytes) and its bytes; returns bytes used.
static size_t put(uint8_t* out, size_t cap, size_t at, const uint8_t* d, size_t n, uint8_t tag = 0) {
    if (at + 3 + n > cap) return at;
    out[at] = tag; out[at + 1] = n & 0xff; out[at + 2] = (n >> 8) & 0xff;
    std::memcpy(out + at + 3, d, n);
    return at + 3 + n;
}

extern "C" {
int cr_valid(const uint8_t* d, size_t n) { return IsValidWebMIDIData(std::vector<uint8_t>(d, d + n)); }
size_t cr_length(uint8_t status) { return GetMessageLength(status); }

size_t cr_parse(const uint8_t* d, size_t n, uint8_t* out, size_t cap) {
    size_t at = 0;
    for (const auto& m : ParseMidiMessages(base::span<const uint8_t>(d, n))) {
        auto data = m.GetData();
        at = put(out, cap, at, data.data(), data.size(), m.is_sysex ? 1 : 0);
    }
    return at;
}
size_t cr_translate(const uint8_t* d, size_t n, uint32_t* out, size_t cap) {
    std::vector<uint32_t> words;
    TranslateMidiToUmpWords(base::span<const uint8_t>(d, n), 0, words);
    size_t k = words.size() < cap ? words.size() : cap;
    std::memcpy(out, words.data(), k * 4);
    return words.size();
}
size_t cr_dispatch(const uint32_t* w, size_t n, uint8_t* out, size_t cap) {
    size_t at = 0;
    DispatchMidiFromUmpWords(base::span<const uint32_t>(w, n), base::TimeTicks(),
        [&](base::span<const uint8_t> data, base::TimeTicks) { at = put(out, cap, at, data.data(), data.size()); });
    return at;
}
// Feeds `d` in the chunks given by `cuts` (ascending offsets), draining the
// queue after each chunk, as midi_host.cc does.
size_t cr_queue(int running, const uint8_t* d, size_t n, const size_t* cuts, size_t ncuts, uint8_t* out, size_t cap) {
    MidiMessageQueue q(running != 0);
    size_t at = 0, from = 0;
    for (size_t c = 0; c <= ncuts; ++c) {
        size_t to = c < ncuts ? cuts[c] : n;
        q.Add(base::span<const uint8_t>(d + from, to - from));
        from = to;
        std::vector<uint8_t> m;
        while (true) { q.Get(&m); if (m.empty()) break; at = put(out, cap, at, m.data(), m.size()); }
    }
    return at;
}
}
