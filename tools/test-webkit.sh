#!/bin/bash
# The extension end to end in WebKit against CoreMIDI (tests/webkit), on the
# conformance page, and with --wpt on the web-platform-tests IDL test.
#   ./tools/test-webkit.sh [--wpt]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build"
CONTENT="$B/Triglav Modular.app/Contents/PlugIns/Web MIDI Extension.appex/Contents/Resources/content.js"
[ -f "$CONTENT" ] || { echo "Build first: ./tools/build.sh" >&2; exit 1; }
mkdir -p "$B/obj"
swiftc -O "$ROOT/native/MIDIMessages.swift" "$ROOT/native/MIDIHub.swift" "$ROOT/tests/webkit/main.swift" -o "$B/obj/webkit"

WEB="$ROOT/tests/web"; PAGE="conformance.html"; GRANTS='{}'
if [ "${1:-}" = "--wpt" ]; then
    "$ROOT/tests/wpt/fetch.sh"
    WEB="$B/wpt"; PAGE="webmidi/idlharness.https.window.html"
fi
PORT=$((20000 + RANDOM % 20000))
[ "${1:-}" = "--wpt" ] && GRANTS="{\"http://localhost:$PORT\":{\"midi\":\"granted\",\"sysex\":\"granted\"}}"
/usr/bin/python3 -m http.server "$PORT" --bind 127.0.0.1 -d "$WEB" >/dev/null 2>&1 &
S1=$!
/usr/bin/python3 -m http.server $((PORT + 1)) --bind 127.0.0.1 -d "$WEB" >/dev/null 2>&1 &
S2=$!
trap 'kill $S1 $S2 2>/dev/null' EXIT
sleep 0.5
"$B/obj/webkit" "$CONTENT" "$ROOT/extension/background.js" "http://localhost:$PORT/$PAGE" "$GRANTS"
