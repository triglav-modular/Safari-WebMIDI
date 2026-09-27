#!/bin/bash
# Builds "Web MIDI.app" and the Safari web extension inside it, signs both
# with the Developer ID, and with --notarize notarises and staples the app
# and ships it in a notarised disk image.
#
#   ./tools/build.sh              build and sign   -> build/Web MIDI.app
#   ./tools/build.sh --notarize   ...then notarise  -> build/Web-MIDI.dmg
#
# tools/release.sh then publishes the disk image as a GitHub release.
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
# Safari's extension list names the maker from this file name ("Web MIDI
# from Web MIDI"): for a Developer ID app it is LaunchServices' name for the
# app, which comes from the file, not from CFBundleDisplayName.  Naming the
# app after the maker was tried (0.1.1) and dropped: the app is Web MIDI.
APP_FILE="$NAME"
APP="$B/$APP_FILE.app"
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

echo "== extension"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
"$ROOT/tools/assemble-extension.sh" "$APPEX/Contents/Resources"

echo "== icons"
mkdir -p "$B/icons/car"
xcrun actool "$B/icons/AppIcon.icon" --compile "$B/icons/car" --platform macosx \
    --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon \
    --output-partial-info-plist "$B/icons/partial.plist" >/dev/null

cp "$ROOT/third_party/chromium/LICENSE" "$APP/Contents/Resources/Chromium-LICENSE.txt"
cp "$B/icons/car/Assets.car" "$B/icons/car/AppIcon.icns" "$APP/Contents/Resources/"
cp "$B/icons/"favicon-{16,32,96}.png "$B/icons/apple-touch-icon.png" "$ROOT/site/icons/"

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
set_key "$P" CFBundleDisplayName string "$NAME"
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
# The zip only carries the app to the notary service; the disk image ships.
ZIP="$B/obj/Web-MIDI.zip"
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

echo "== disk image"
# The stapled app beside a link to /Applications, on the owner's background
# (dmg-background.png: 1080 x 660, the 540 x 330 point window at 2x, arrow
# included), laid out by tools/dmg-settings.py.  dmgbuild writes the
# window's .DS_Store against the image it builds: the background is found
# through an alias to its file on that volume, which a .DS_Store copied from
# elsewhere cannot carry.  dmgbuild comes from PyPI into build/obj/dmgbuild,
# on Homebrew's Python (1.6.7 needs a newer one than macOS has), on the
# first run.
DMG="$B/Web-MIDI.dmg"
DMG_W=540; DMG_H=330; ICON=112; APP_X=140; APPS_X=400
# Centred by eye in Finder on macOS 27, with its toolbar, path bar and status
# bar showing (about 207 of the 330 points left for the icons): an icon and
# its name sit in the middle of that at ICON_Y, level with the arrow.
ICON_Y=86
VENV="$B/obj/dmgbuild"
[ -x "$VENV/bin/dmgbuild" ] || { /opt/homebrew/bin/python3 -m venv "$VENV" && "$VENV/bin/pip" install -q "dmgbuild==1.6.7"; }
cp "$ROOT/dmg-background.png" "$B/obj/dmg-background@2x.png"
sips -z "$DMG_H" "$DMG_W" "$ROOT/dmg-background.png" --out "$B/obj/dmg-background.png" >/dev/null
tiffutil -cathidpicheck "$B/obj/dmg-background.png" "$B/obj/dmg-background@2x.png" -out "$B/obj/dmg-background.tiff" >/dev/null
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$ROOT/tools/dmg-settings.py" -D app="$APP" -D background="$B/obj/dmg-background.tiff" \
    -D width="$DMG_W" -D height="$DMG_H" -D icon_size="$ICON" -D icon_y="$ICON_Y" -D app_x="$APP_X" -D apps_x="$APPS_X" \
    "$NAME" "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
out="$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1)" || true
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q "status: Accepted" || { echo "Disk image not accepted." >&2; exit 1; }
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"
echo "notarised: $DMG"
