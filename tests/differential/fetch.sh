#!/bin/bash
# Fetches the Chromium files the port was made from, at the commit it was
# made from, into build/chromium (not committed: they are Chromium's).
set -euo pipefail
COMMIT=08da355f5163273673e9203114c3fbea92f87a1f
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/chromium/media/midi"
mkdir -p "$OUT"
for f in message_util.cc message_util.h midi_message_queue.cc midi_message_queue.h \
         ump_message_util.cc ump_message_util.h midi_export.h; do
    [ -s "$OUT/$f" ] || curl -sfL -o "$OUT/$f" \
        "https://raw.githubusercontent.com/chromium/chromium/$COMMIT/media/midi/$f"
done
[ -s "$ROOT/build/chromium/LICENSE" ] || curl -sfL -o "$ROOT/build/chromium/LICENSE" \
    "https://raw.githubusercontent.com/chromium/chromium/$COMMIT/LICENSE"
