#!/bin/bash
# Lays out the web extension's files in a directory: the manifest, the
# scripts, the popup, the icons, and content.js with shim.js and the notice's
# icon inline (see the placeholders in content.js).  No signing: build.sh
# puts the result in the app extension, and the tests load it as it is.
#   ./tools/assemble-extension.sh <dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build"
R="$1"
mkdir -p "$B/obj" "$R/icons"
swiftc -O "$ROOT/tools/make-icons.swift" -o "$B/obj/make-icons"
rm -rf "$B/icons"
"$B/obj/make-icons" "$ROOT/icon.ai" "$B/icons"
cp "$ROOT/extension/"{manifest.json,background.js,shim.js,popup.html,popup.js} "$R/"
cp "$B/icons/"toolbar-{16,19,32,38}.png "$B/icons/"icon-{48,64,96,128,256,512}.png "$R/icons/"
/usr/bin/python3 - "$ROOT/extension/content.js" "$ROOT/extension/shim.js" "$B/icons/icon-64.png" "$R/content.js" <<'PY'
import base64, json, sys
content, shim, icon, out = sys.argv[1:5]
s = open(content).read()
s = s.replace('__SHIM_SOURCE__', json.dumps(open(shim).read()))
s = s.replace('__ICON_DATA_URL__', json.dumps('data:image/png;base64,' + base64.b64encode(open(icon, 'rb').read()).decode()))
assert '__SHIM_SOURCE__' not in s and '__ICON_DATA_URL__' not in s
open(out, 'w').write(s)
PY
