#!/bin/bash
# Makes a committed disk image a GitHub release: tag v<version> on the commit
# that shipped it, titled "Web MIDI <version>", with the disk image attached
# as Web-MIDI.dmg (so releases/latest/download/Web-MIDI.dmg is the newest).
#
#   ./tools/release.sh [COMMIT] [--draft] [--dry-run]
#
# COMMIT is a commit that changed site/Web-MIDI.dmg; by default the last one.
# .github/workflows/release.yml runs this on every push of a new disk image,
# and by hand with a commit, for one that shipped before it existed.
#
# The version is read from the app inside the image, not from the source,
# and the release is refused unless extension/manifest.json and the page's
# version line agree with it and the image and the app are both stapled.
# A version already released is left alone if its asset is these bytes, and
# refused if not: a released version is not rebuilt under the same number.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DMG_PATH="site/Web-MIDI.dmg"
PAGE="https://triglavmodular.hu/mods/safari-webmidi/"
COMMIT="" DRAFT=0 DRY=0
for a in "$@"; do
    case "$a" in
        --draft) DRAFT=1 ;;
        --dry-run) DRY=1 ;;
        -*) echo "unknown option $a" >&2; exit 2 ;;
        *) COMMIT="$a" ;;
    esac
done
fail() { echo "release: $*" >&2; exit 1; }

[ -n "$COMMIT" ] || COMMIT="$(git log -1 --format=%H -- "$DMG_PATH")"
SHA="$(git rev-parse --verify -q "$COMMIT^{commit}")" || fail "no such commit: $COMMIT"
COMMIT="$SHA"
git cat-file -e "$COMMIT:$DMG_PATH" 2>/dev/null || fail "$COMMIT has no $DMG_PATH"

T="$(mktemp -d)"
MNT="$T/mnt" MOUNTED=0
cleanup() { [ "$MOUNTED" = 0 ] || hdiutil detach -quiet -force "$MNT" || true; rm -rf "$T"; }
trap cleanup EXIT
git show "$COMMIT:$DMG_PATH" > "$T/Web-MIDI.dmg"
git show "$COMMIT:extension/manifest.json" > "$T/manifest.json"
git show "$COMMIT:site/index.html" > "$T/index.html"

echo "== disk image at ${COMMIT:0:7}"
mkdir "$MNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$T/Web-MIDI.dmg"
MOUNTED=1
APP="$MNT/Web MIDI.app"
[ -d "$APP" ] || fail "the disk image holds no Web MIDI.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
SOURCE="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$T/manifest.json")"
[ "$VERSION" = "$SOURCE" ] || fail "the app is $VERSION, extension/manifest.json says $SOURCE"
REQUIRES="$(sed -n "s:.*<p class=\"meta\">Version $VERSION · \(.*\)</p>.*:\1:p" "$T/index.html")"
[ -n "$REQUIRES" ] || fail "site/index.html does not say Version $VERSION"
# Stapled means notarised, and stapler checks the ticket itself rather than
# asking Gatekeeper, which a CI runner may not be running as a Mac does.
xcrun stapler validate -q "$T/Web-MIDI.dmg" || fail "the disk image is not stapled"
xcrun stapler validate -q "$APP" || fail "the app is not stapled"
codesign --verify --strict --deep "$APP" || fail "the app's signature does not verify"
SIG="$(codesign -dvv "$APP" 2>&1)"
grep -q '^Authority=Developer ID Application' <<< "$SIG" || fail "the app is not signed with a Developer ID"
hdiutil detach -quiet "$MNT"
MOUNTED=0
echo "Web MIDI $VERSION: stapled, signed, and the source agrees"

TAG="v$VERSION"
if gh release view "$TAG" --json tagName >/dev/null 2>&1; then
    gh release download "$TAG" --pattern Web-MIDI.dmg --dir "$T/released" 2>/dev/null \
        || fail "$TAG is released without Web-MIDI.dmg"
    cmp -s "$T/Web-MIDI.dmg" "$T/released/Web-MIDI.dmg" \
        || fail "$TAG is already released with a different disk image; a new build needs a new version"
    echo "$TAG is already released with this disk image"
    exit 0
fi
AT="$(git ls-remote --tags origin "refs/tags/$TAG" | cut -f1)"
[ -z "$AT" ] || [ "$AT" = "$COMMIT" ] || fail "tag $TAG exists at ${AT:0:7}, not ${COMMIT:0:7}"

# The notes are the release commit's message, without its trailers and
# without a leading "Release <version>: ", then the page's line of what it
# needs.
{
    git show -s --format=%B "$COMMIT" | /usr/bin/python3 -c '
import re, sys
lines = [l for l in sys.stdin.read().splitlines()
         if not re.match(r"(Co-Authored-By|Signed-off-by):", l, re.I)]
s = re.sub(r"^Release " + re.escape(sys.argv[1]) + r": *", "", "\n".join(lines).strip())
print(s[:1].upper() + s[1:])' "$VERSION"
    echo
    echo "$REQUIRES"
    echo
    echo "Download page: $PAGE"
} > "$T/notes.md"

# Only the newest disk image on main is marked latest, so a release made
# afterwards for an older one does not take its place.
NEWEST="$(git log -1 --format=%H origin/main -- "$DMG_PATH" 2>/dev/null || true)"
LATEST=false; [ "$COMMIT" = "$NEWEST" ] && LATEST=true

echo "== $TAG at ${COMMIT:0:7} (latest: $LATEST$([ "$DRAFT" = 1 ] && echo ', draft'))"
cat "$T/notes.md"
[ "$DRY" = 0 ] || { echo "(dry run: nothing released)"; exit 0; }
FLAGS=(--target "$COMMIT" --title "Web MIDI $VERSION" --notes-file "$T/notes.md")
# A draft cannot be marked latest; it is decided when the draft is published.
if [ "$DRAFT" = 1 ]; then FLAGS+=(--draft); else FLAGS+=(--latest="$LATEST"); fi
gh release create "$TAG" "$T/Web-MIDI.dmg" "${FLAGS[@]}"
