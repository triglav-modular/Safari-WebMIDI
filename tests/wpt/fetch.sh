#!/bin/bash
# Assembles build/wpt: the web-platform-tests Web MIDI test and what it
# needs, at a pinned commit, laid out as the WPT server would serve it.
set -euo pipefail
COMMIT=bdadba91cf68adbfe90eaf264117218d02a3d94b
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/wpt"
get() { [ -s "$OUT/$1" ] || { mkdir -p "$(dirname "$OUT/$1")"; curl -sfL --retry 3 -o "$OUT/$1" "https://raw.githubusercontent.com/web-platform-tests/wpt/$COMMIT/$1"; }; }
for f in resources/testharness.js resources/testharnessreport.js resources/idlharness.js resources/webidl2/lib/webidl2.js \
         interfaces/webmidi.idl interfaces/html.idl interfaces/dom.idl interfaces/permissions.idl \
         webmidi/idlharness.https.window.js; do get "$f"; done
# The WPT server serves the vendored WebIDL parser under this name.
cp "$OUT/resources/webidl2/lib/webidl2.js" "$OUT/resources/WebIDLParser.js"
# testdriver: the permission is granted by the harness before the page loads.
cat > "$OUT/resources/testdriver.js" <<'JS'
window.test_driver = { set_permission: function () { return Promise.resolve(); } };
JS
: > "$OUT/resources/testdriver-vendor.js"
# The page the WPT server would generate for a .window.js test, reporting
# to the harness when done.
cat > "$OUT/webmidi/idlharness.https.window.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<script src="/resources/testharness.js"></script>
<script src="/resources/testharnessreport.js"></script>
<script>
  add_completion_callback(function (tests, status) {
    webkit.messageHandlers.done.postMessage(tests.map(function (t) {
      return [t.name, t.status === 0, t.message || ''];
    }).concat(status.status === 0 ? [] : [['harness status', false, status.message || String(status.status)]]));
  });
</script>
<script src="/resources/WebIDLParser.js"></script>
<script src="/resources/idlharness.js"></script>
<script src="/resources/testdriver.js"></script>
<script src="/resources/testdriver-vendor.js"></script>
<div id="log"></div>
<script src="/webmidi/idlharness.https.window.js"></script>
HTML
