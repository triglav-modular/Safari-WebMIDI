#!/bin/bash
# Builds "Web MIDI.app" and the Safari web extension inside it, signs both
# with the Developer ID, and with --notarize notarises and staples the app.
#
#   ./tools/build.sh              build and sign   -> build/Web MIDI.app
#   ./tools/build.sh --notarize   ...then notarise  -> build/Web-MIDI.zip
#
# No Xcode project: the extension is a handful of files and two small Swift
# programs, and a script says exactly what goes into the bundle.
# Notarisation uses a notarytool keychain profile stored once, by you:
#   xcrun notarytool store-credentials <profile> --apple-id ... --team-id LRU7FPHFVM
# The profile name comes from WEBMIDI_NOTARY_PROFILE (default rewired-notary).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build"
NAME="Web MIDI"
APP="$B/$NAME.app"
APPEX="$APP/Contents/PlugIns/$NAME Extension.appex"
APP_ID="hu.triglavmodular.webmidi"
EXT_ID="$APP_ID.Extension"
MIN_MACOS="13.5"
PROFILE="${WEBMIDI_NOTARY_PROFILE:-rewired-notary}"
VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/extension/manifest.json")"
NOTARIZE=0
[ "${1:-}" = "--notarize" ] && NOTARIZE=1

# Sign by SHA-1, the Developer ID certificate with the latest expiry (two
# share one name after a renewal).  WEBMIDI_SIGN_ID overrides it.
IDENTITY="${WEBMIDI_SIGN_ID:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Developer ID Application/ {print $2}' \
        | while read -r h; do
              end=$(security find-certificate -a -Z -p -c "Developer ID Application" 2>/dev/null \
                    | awk -v h="$h" '/SHA-1 hash:/ { want = ($3 == h) } /BEGIN CERT/,/END CERT/ { if (want) print }' \
                    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
              [ -n "$end" ] && printf '%s\t%s\n' "$(date -j -f '%b %e %T %Y %Z' "$end" +%s 2>/dev/null || echo 0)" "$h"
          done | sort -rn | head -1 | cut -f2)"
fi
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' certificate in the keychain." >&2; exit 1; }

echo "== icons"
mkdir -p "$B/obj"
swiftc -O "$ROOT/tools/make-icons.swift" -o "$B/obj/make-icons"
rm -rf "$B/icons"
"$B/obj/make-icons" "$ROOT/icon.ai" "$B/icons"
mkdir -p "$B/icons/car"
xcrun actool "$B/icons/AppIcon.icon" --compile "$B/icons/car" --platform macosx \
    --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon \
    --output-partial-info-plist "$B/icons/partial.plist" >/dev/null

echo "== bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources/icons"

# The extension's files.  content.js carries shim.js and the prompt's icon
# inline (see the placeholders in it).
R="$APPEX/Contents/Resources"
cp "$ROOT/extension/"{manifest.json,background.js,shim.js,popup.html,popup.js} "$R/"
cp "$B/icons/"toolbar-{16,19,32,38}.png "$B/icons/"icon-{48,64,96,128,256,512}.png "$R/icons/"
/usr/bin/python3 - "$ROOT/extension/content.js" "$ROOT/extension/shim.js" "$B/icons/icon-64.png" "$R/content.js" <<'EOF'
import base64, json, sys
content, shim, icon, out = sys.argv[1:5]
s = open(content).read()
s = s.replace('__SHIM_SOURCE__', json.dumps(open(shim).read()))
s = s.replace('__ICON_DATA_URL__', json.dumps('data:image/png;base64,' + base64.b64encode(open(icon, 'rb').read()).decode()))
assert '__SHIM_SOURCE__' not in s and '__ICON_DATA_URL__' not in s
open(out, 'w').write(s)
EOF
cp "$ROOT/third_party/chromium/LICENSE" "$APP/Contents/Resources/Chromium-LICENSE.txt"
cp "$B/icons/car/Assets.car" "$B/icons/car/AppIcon.icns" "$APP/Contents/Resources/"

echo "== compile"
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos$MIN_MACOS" -parse-as-library -application-extension \
        -module-name WebMIDIExtension \
        "$ROOT/native/MIDIMessages.swift" "$ROOT/native/MIDIHub.swift" "$ROOT/native/Handler.swift" \
        -Xlinker -e -Xlinker _NSExtensionMain -o "$B/obj/ext-$arch"
    swiftc -O -target "$arch-apple-macos$MIN_MACOS" -module-name WebMIDI \
        "$ROOT/app/App.swift" -o "$B/obj/app-$arch"
done
lipo -create "$B/obj/ext-arm64" "$B/obj/ext-x86_64" -output "$APPEX/Contents/MacOS/$NAME Extension"
lipo -create "$B/obj/app-arm64" "$B/obj/app-x86_64" -output "$APP/Contents/MacOS/$NAME"

plist() { /usr/bin/plutil -create xml1 "$1"; shift; }
set_key() { /usr/bin/plutil -insert "$2" "-$3" "$4" "$1"; }

P="$APPEX/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$P"
set_key "$P" CFBundleIdentifier string "$EXT_ID"
set_key "$P" CFBundleExecutable string "$NAME Extension"
set_key "$P" CFBundleName string "$NAME Extension"
set_key "$P" CFBundleDisplayName string "$NAME"
set_key "$P" CFBundlePackageType string 'XPC!'
set_key "$P" CFBundleShortVersionString string "$VERSION"
set_key "$P" CFBundleVersion string "$VERSION"
set_key "$P" CFBundleInfoDictionaryVersion string "6.0"
set_key "$P" LSMinimumSystemVersion string "$MIN_MACOS"
set_key "$P" NSExtension json '{"NSExtensionPointIdentifier":"com.apple.Safari.web-extension","NSExtensionPrincipalClass":"SafariWebExtensionHandler"}'

P="$APP/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$P"
set_key "$P" CFBundleIdentifier string "$APP_ID"
set_key "$P" CFBundleExecutable string "$NAME"
set_key "$P" CFBundleName string "$NAME"
# Safari's extension list says "<extension> from <this>".  For an App Store
# app it names the seller; for a Developer ID app it falls back to the
# containing app's display name, which LaunchServices, the Dock and Finder do
# not use (they show the bundle name), so this names the maker there alone.
set_key "$P" CFBundleDisplayName string "Triglav Modular"
set_key "$P" NSHumanReadableCopyright string "Triglav Modular"
set_key "$P" CFBundlePackageType string APPL
set_key "$P" CFBundleShortVersionString string "$VERSION"
set_key "$P" CFBundleVersion string "$VERSION"
set_key "$P" CFBundleInfoDictionaryVersion string "6.0"
set_key "$P" CFBundleIconFile string AppIcon
set_key "$P" CFBundleIconName string AppIcon
set_key "$P" LSMinimumSystemVersion string "$MIN_MACOS"
set_key "$P" LSApplicationCategoryType string public.app-category.utilities
set_key "$P" NSPrincipalClass string NSApplication
set_key "$P" NSHighResolutionCapable bool true

echo "== sign"
ENT="$B/obj/sandbox.entitlements"
cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
EOF
# Safari refuses an extension that is not sandboxed ("plug-ins must be
# sandboxed"), and notarisation refuses get-task-allow, so the entitlements
# are exactly the sandbox.
codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$IDENTITY" "$APPEX"
codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
echo "signed: $APP"

[ "$NOTARIZE" = 1 ] || exit 0

echo "== notarise"
ZIP="$B/Web-MIDI.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
# "No Keychain password item found" is sometimes transient: ask the
# profile whether it answers before believing it.
for attempt in 1 2 3 4 5; do
    if out="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1)"; then
        printf '%s\n' "$out"; break
    fi
    printf '%s\n' "$out"
    case "$out" in *"No Keychain password item found"*) ;; *) exit 1 ;; esac
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || exit 1
    sleep 20
done
printf '%s\n' "$out" | grep -q "status: Accepted" || { echo "Not accepted." >&2; exit 1; }
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$ZIP" "$ROOT/site/Web-MIDI.zip"
echo "notarised: $ZIP (and site/Web-MIDI.zip)"
