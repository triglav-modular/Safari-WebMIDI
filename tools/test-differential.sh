#!/bin/bash
# Compares native/MIDIMessages.swift with the Chromium code it was ported
# from, compiled from the pinned commit, on random MIDI streams.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/tests/differential"; B="$ROOT/build/differential"
"$D/fetch.sh"
mkdir -p "$B"
for f in message_util midi_message_queue ump_message_util; do
    clang++ -std=c++20 -O1 -include build/build_config.h -I "$D/shim" -I "$ROOT/build/chromium" \
        -c "$ROOT/build/chromium/media/midi/$f.cc" -o "$B/$f.o"
done
clang++ -std=c++20 -O1 -include build/build_config.h -I "$D/shim" -I "$ROOT/build/chromium" \
    -c "$D/chromium_c.cc" -o "$B/chromium_c.o"
swiftc -O -import-objc-header "$D/chromium_c.h" "$ROOT/native/MIDIMessages.swift" "$D/main.swift" \
    "$B"/*.o -lc++ -o "$B/differential"
"$B/differential" "$@"
