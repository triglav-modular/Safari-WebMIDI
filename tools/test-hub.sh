#!/bin/bash
# Builds and runs the CoreMIDI hub against a virtual instrument, and
# against ports in another process.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tests"
mkdir -p "$OUT"
swiftc -O "$ROOT/native/MIDIMessages.swift" "$ROOT/native/MIDIHub.swift" "$ROOT/tests/hub/main.swift" -o "$OUT/hub"
"$OUT/hub"
# The hub against ports in another process (tests/ports/main.swift).
swiftc -O "$ROOT/native/MIDIMessages.swift" "$ROOT/native/MIDIHub.swift" "$ROOT/tests/ports/main.swift" -o "$OUT/hub-ports"
swiftc -O "$ROOT/tests/ports/peer.swift" -o "$OUT/hub-peer"
"$OUT/hub-ports"
