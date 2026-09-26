#!/bin/bash
# Builds and runs the CoreMIDI hub against a virtual instrument.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tests"
mkdir -p "$OUT"
swiftc -O "$ROOT/native/MIDIMessages.swift" "$ROOT/native/MIDIHub.swift" "$ROOT/tests/hub/main.swift" -o "$OUT/hub"
"$OUT/hub"
