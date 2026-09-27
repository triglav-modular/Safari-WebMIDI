#!/bin/bash
# Publishes the notarised disk image as a GitHub release: tag v<version> on
# a pushed commit, titled "Web MIDI <version>", with the image attached as
# Web-MIDI.dmg.  The download page links, by way of the worker, to
# releases/latest/download/Web-MIDI.dmg, so the newest release is the download.
#
#   ./tools/build.sh --notarize      -> build/Web-MIDI.dmg
#   (commit the version, push)
#   ./tools/release.sh [COMMIT] [--dry-run]
#
# COMMIT is the commit the image was built from, on origin/main; by default
# HEAD.  The version is read from the app inside the image, not from the
# source, and the release is refused unless the commit's
# extension/manifest.json and the page's version line say the same, the
# extension's files in the image are the ones the commit lays out, and the
# image and the app are stapled and signed with the Developer ID.  A version
# already released is left alone if its asset is these bytes, and refused if
# not: a released version is not rebuilt under the same number.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DMG="$ROOT/build/Web-MIDI.dmg"
PAGE="https://triglavmodular.hu/mods/safari-webmidi/"
REPO="triglav-modular/Safari-WebMIDI"
# The page's Download.  curl does not count there (deploy/worker.js), but
# GitHub counts the fetch.
LATEST_URL="${PAGE}Web-MIDI.dmg"
COMMIT=HEAD DRY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        -*) echo "unknown option $a" >&2; exit 2 ;;
        *) COMMIT="$a" ;;
    esac
done
fail() { echo "release: $*" >&2; exit 1; }

[ -f "$DMG" ] || fail "no $DMG: ./tools/build.sh --notarize first"
SHA="$(git rev-parse --verify -q "$COMMIT^{commit}")" || fail "no such commit: $COMMIT"
COMMIT="$SHA"
git fetch -q origin main
git merge-base --is-ancestor "$COMMIT" origin/main || fail "${COMMIT:0:7} is not on origin/main: push it first"

T="$(mktemp -d)"
MNT="$T/mnt" MOUNTED=0 TREE=""
cleanup() {
    [ "$MOUNTED" = 0 ] || hdiutil detach -quiet -force "$MNT" || true
    [ -z "$TREE" ] || git worktree remove --force "$TREE" || true
    rm -rf "$T"
}
trap cleanup EXIT

echo "== $DMG against ${COMMIT:0:7}"
mkdir "$MNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG"
MOUNTED=1
APP="$MNT/Web MIDI.app"
[ -d "$APP" ] || fail "the disk image holds no Web MIDI.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
SOURCE="$(git show "$COMMIT:extension/manifest.json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
[ "$VERSION" = "$SOURCE" ] || fail "the app is $VERSION, extension/manifest.json says $SOURCE"
REQUIRES="$(git show "$COMMIT:site/index.html" | sed -n "s:.*<p class=\"meta\">Version $VERSION · \(.*\)</p>.*:\1:p")"
[ -n "$REQUIRES" ] || fail "site/index.html does not say Version $VERSION"
# Stapled means notarised, and stapler checks the ticket itself rather than
# asking Gatekeeper.
xcrun stapler validate -q "$DMG" || fail "the disk image is not stapled"
xcrun stapler validate -q "$APP" || fail "the app is not stapled"
codesign --verify --strict --deep "$APP" || fail "the app's signature does not verify"
SIG="$(codesign -dvv "$APP" 2>&1)"
grep -q '^Authority=Developer ID Application' <<< "$SIG" || fail "the app is not signed with a Developer ID"
# The extension's files (scripts, manifest, popup, icons) as the commit lays
# them out.  The compiled Swift cannot be compared this way; they are the
# commit's only if the image was built from a clean tree.
TREE="$T/tree"
git worktree add -q --detach "$TREE" "$COMMIT"
"$TREE/tools/assemble-extension.sh" "$T/ext" >/dev/null
diff -r "$T/ext" "$APP/Contents/PlugIns/Web MIDI Extension.appex/Contents/Resources" >&2 \
    || fail "the extension in the disk image is not the one ${COMMIT:0:7} lays out"
hdiutil detach -quiet "$MNT"
MOUNTED=0
echo "Web MIDI $VERSION: stapled, signed, and the extension is ${COMMIT:0:7}'s"

TAG="v$VERSION"
if gh release view "$TAG" --repo "$REPO" --json tagName >/dev/null 2>&1; then
    gh release download "$TAG" --repo "$REPO" --pattern Web-MIDI.dmg --dir "$T/released" 2>/dev/null \
        || fail "$TAG is released without Web-MIDI.dmg"
    cmp -s "$DMG" "$T/released/Web-MIDI.dmg" \
        || fail "$TAG is already released with a different disk image; a new build needs a new version"
    echo "$TAG is already released with this disk image"
    exit 0
fi
AT="$(git ls-remote --tags origin "refs/tags/$TAG" | cut -f1)"
[ -z "$AT" ] || [ "$AT" = "$COMMIT" ] || fail "tag $TAG exists at ${AT:0:7}, not ${COMMIT:0:7}"

# The notes are the commit's message, without its trailers and without a
# leading "Release <version>: ", then the page's line of what it needs.
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

# Latest (the page's download) unless a higher version is already released.
TOP="$( { gh release list --repo "$REPO" --json tagName --jq '.[].tagName'; echo "$TAG"; } | sort -V | tail -1)"
LATEST=false; [ "$TOP" = "$TAG" ] && LATEST=true

echo "== $TAG at ${COMMIT:0:7} (latest: $LATEST)"
cat "$T/notes.md"
[ "$DRY" = 0 ] || { echo "(dry run: nothing released)"; exit 0; }
gh release create "$TAG" "$DMG" --repo "$REPO" --target "$COMMIT" --title "Web MIDI $VERSION" \
    --notes-file "$T/notes.md" --latest="$LATEST"

# Check the address the page links to, not gh's word for it.
[ "$LATEST" = true ] || exit 0
curl -fsSL -o "$T/latest.dmg" "$LATEST_URL" || fail "$LATEST_URL does not answer"
cmp -s "$DMG" "$T/latest.dmg" || fail "$LATEST_URL is not this disk image"
echo "$LATEST_URL serves Web MIDI $VERSION"
