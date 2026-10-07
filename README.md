# Web MIDI for Safari

Safari has no Web MIDI API, and WebKit has said it will not ship one. This is
a Safari web extension that supplies it: `navigator.requestMIDIAccess()` and
the rest of the API, backed by CoreMIDI, behind a per-site permission prompt.

**Download and install:** <https://triglavmodular.hu/mods/safari-webmidi/>

It is a port of **Chromium's** implementation, so a site gets what it gets
in Chrome:

| Part | Ported from (Chromium `08da355f`) | Here |
|---|---|---|
| The API in the page | `third_party/blink/renderer/modules/webmidi/*` | `extension/shim.js` |
| Permission and checks | `content/browser/media/midi_host.cc` | `extension/background.js` |
| Byte streams and UMP | `media/midi/{message_util,midi_message_queue,ump_message_util}.cc` | `native/MIDIMessages.swift` |
| CoreMIDI | `media/midi/midi_manager_mac.cc` | `native/MIDIHub.swift` |

## Licence

This project's own work is released under the Unlicense. The files ported
from Chromium stay under Chromium's BSD licence (`third_party/chromium/LICENSE`,
shipped in the app), and the artwork is not dedicated. `UNLICENSE` lists what
is which.

## How it fits together

```
page ── shim.js (page world) ──MessageChannel── content.js (isolated world)
        ── runtime.sendMessage ── background.js ── sendNativeMessage ──
        SafariWebExtensionHandler (app extension) ── MIDIHub ── CoreMIDI
```

- **shim.js** is put into the page inline at document start, so a site that
  looks for `requestMIDIAccess` while loading finds it. Safari does not
  support `"world": "MAIN"`; a page whose CSP refuses inline script gets the
  file instead, a moment later.
- **Secure contexts only.** An insecure document (plain http, or anything
  under an http page) gets neither the shim nor the channel to the
  extension, and the background refuses such URLs as well. http to this
  machine (`localhost`, `127.0.0.1`, `[::1]`) is secure, as Safari counts it.
- **background.js** holds the permission decisions and is the only way to
  CoreMIDI; every request is checked there, as Chrome checks in the browser
  process. The question is asked in a notice in the page, with a badge on
  the extension's toolbar button, whose popup asks it too; the popup does
  not open by itself, so one prompt is on screen. A page can restyle,
  hide or cover anything drawn in its own DOM, so the notice can allow
  basic MIDI only, and only for a real click at least half a second after it
  appears, while it sits in the top layer with its own style and nothing
  else of the page's is there. Otherwise its Allow opens the popup instead.
  A page can still hide the notice with a top-layer element of its own in a
  closed shadow root; that is accepted for basic MIDI, not for sysex,
  which can rewrite a device's settings and firmware. For sysex the
  notice's Allow… only opens the popup, or, where Safari's toolbar has no
  Web MIDI button (no popup has asked for the question within a second),
  the same question in a window of the extension's own. As in Chrome, three
  dismissals block a site for a week. Every question has an id, and an
  answer counts only for the question it names: if the page asks something
  else while the popup is open, the popup redraws, and a question just
  shown takes no click for half a second. A question goes, deciding
  nothing, when the documents that asked it go or the tab leaves the site.
- **The toolbar button** looks like Safari's own buttons, and takes the
  accent colour on a tab whose page is using Web MIDI (a document there has
  access and has not gone). Safari draws a grey extension icon in the
  accent colour on every page the extension may read, which for this one is
  every page, and an icon in colour as it is. So the button is Safari's
  `labelColor` (black or white at 85%, as the manifest's `icon_variants` for
  light and dark), with 5% of its pixels a little off in blue so that it
  counts as colour, and a tab using MIDI gets the grey glyph instead
  (`tools/make-icons.swift`).
- **Safari unloads the background** 30 s after the last message reaches it
  (WebKit's `WebExtensionContext::unloadBackgroundContentIfPossible`); a
  reply it still owes does not count. The question waiting for the person
  is held there, so while a request waits, its content script asks after it
  every 10 s, which keeps the background loaded, and asks again if the
  background has lost it anyway. The notice's Allow on a lost question asks
  again at once, and its Not now refuses the request.
- **MIDIHub** schedules timestamped sends itself, in (time, submission)
  order, with one fixed offset between the page's clock and CoreMIDI's.
- **Receiving.** Safari delivers the extension's native requests one at a
  time, so a receive left waiting holds every send behind it (a one-second
  long poll put note-ons up to a second late). While an input is open, a page
  that has sent in the last two seconds checks for input every 50 ms without
  waiting, and one that only listens waits up to 45 ms for it. With no input
  open, a check runs every 250 ms, to notice ports coming and going.
- **Safari's request limit.** Safari counts each native request for about
  five seconds and refuses more than 151 at once (`SFErrorDomain error 3`).
  Receiving every 15 ms kept the count near it, and notes sent on top were
  refused and lost. The background sends at most 20 requests a second, with
  25 in hand, sends first, and tries a refused one again. A page's sends
  and clears go in the order it made them, so a refused send tried again
  cannot land after a `clear()` made behind it.
- **The page's spacing.** At 20 requests a second, the sends a page makes
  while one request is in flight go together in the next. Sent back to
  back, they arrived in runs of up to 80, more than a 218e's 32-packet
  receive ring holds, where the page had paced them 16 at a time. Each send
  carries the time the page made it, and MIDIHub gives CoreMIDI each one the
  page's own gap after the send before it to that port. A gap over 20 ms may
  shrink to 20, which sheds a delay built up in a busy stretch.

## Where it follows the spec rather than Chrome

The W3C Working Draft (21 January 2025) has features Chrome lacks, and this
has them too:

- `navigator.permissions.query({name: "midi", sysex})`, with `change` events.
- The `software` option is read. macOS has no software synthesizer that
  appears as a MIDI port, so it changes nothing.
- The `"midi"` Permissions Policy for frames: a frame may use MIDI when its
  `<iframe allow="midi ...">` lets it in (default allowlist `'self'`), and
  then uses the top-level site's permission, as Chrome delegates it.
- `MIDIOutput.clear()` drops sends that have not gone yet.

Where Chrome and the spec disagree, this does what Chrome does:

| | Spec | Chrome, and this |
|---|---|---|
| Sysex without sysex access | `InvalidAccessError` | `NotAllowedError` |
| `send()` to a disconnected port | `InvalidStateError` | dropped quietly |
| `close()` on a disconnected port | rejects | resolves |
| `close()` on an output | drops future sends | leaves them |
| Permissions Policy refusal | `NotAllowedError` | `SecurityError` |

## What it cannot do

- **Workers.** The spec exposes the API in workers; an extension cannot reach
  them (Chrome does not expose it there either).
- **`isTrusted`.** The extension dispatches its events from script, so a
  `midimessage` or `statechange` event has `isTrusted === false`.
- **`clear()` inside 20 ms.** A send due within 20 ms has already gone to
  CoreMIDI and plays. `MIDIFlushOutput` cannot help: it delivers a System
  Reset to the destination.
- **Sends timed more than a century ahead** are dropped quietly, where
  Chrome would hold them. The Mac's host clock ends 584 years out, and a
  page's `1e100` once crashed the native process converting to it.
- **Cross-origin frames of `about:blank` or `srcdoc`** are refused, and so
  are frames inside a closed shadow root, whose `allow` attribute cannot be
  read.
- **The `Permissions-Policy` header** is not seen: an extension cannot read
  a document's policy, so `Permissions-Policy: midi=()` is not honoured.
  Frames are checked against their `<iframe allow>` attribute instead.
- **Private Browsing.** Decisions made in a private window are kept in
  memory only, and go when Safari stops the extension's background page.

## Building

```bash
./tools/build.sh
```

Builds and signs `build/Web MIDI.app` with the Developer ID; `--notarize` also
notarises and staples it, and puts it in a notarised disk image beside a link
to Applications (`build/Web-MIDI.dmg`), on `dmg-background.png`, laid out by
`tools/dmg-settings.py` with dmgbuild (installed from PyPI into `build/` on
Homebrew's Python on the first run). No Xcode project: the bundle is laid
out by the script. Requires macOS 13.5+ and Safari 18.4+ (the first Safari that accepts
Developer ID-signed web extensions).

## Testing

```bash
./tools/test-differential.sh
```

The Swift port against Chromium's own C++ (fetched at the pinned commit and
compiled with stand-ins for `//base`) on random MIDI streams; any difference
fails.

```bash
./tools/test-hub.sh
```

MIDIHub against a virtual CoreMIDI loop: order, sysex up to 10 kB, timestamps, the page's spacing,
`clear()`, port changes. Then against ports in another process, which come and go while one of
them streams: no request may lock up, and the port list must follow them.

```bash
./tools/test-webkit.sh
```

The built extension end to end in WebKit: shim and content script injected as
Safari injects them, background in its own view, real clicks on the prompt.
`--wpt` runs the web-platform-tests Web MIDI IDL test instead. The harness
delivers native requests one at a time and refuses them past Safari's limit,
as Safari does, and needs no signed build: `tools/assemble-extension.sh`
lays out the extension's files.

```bash
node tests/shim/test-clear.js
node tests/shim/test-clock.js
```

The page script in Node against a fake content script, for what the harness
cannot stage: sends queued behind one that has not come back, and a wall
clock corrected while a page is open.

```bash
node tests/extension/test-extension.js
```

The background, popup and content script in Node against a fake Safari:
a question swapped under the popup, an insecure page, a frame reloaded
under a new policy, a refused send with a `clear()` behind it, and the
native process starting again.

```bash
node tests/deploy/test-worker.js
```

The worker against fake KV and GitHub: a click with the headers Safari sends
is counted once, as the day and the version and nothing else; a crawler, a
prefetch, a HEAD or a missing binding is not, and the download goes on
regardless. It also holds the worker against the
page's Download link and the binding in `wrangler.toml`, the two ways the
downloads could stop being counted without an error.

`.github/workflows/tests.yml` runs all of these on every push.

What these cannot reach is Safari's own plumbing (the extension store,
`sendNativeMessage`); that is checked by hand in Safari.

## Publishing

`site/` is the download page, published to GitHub Pages by
`.github/workflows/pages.yml`, and served at
<https://triglavmodular.hu/mods/safari-webmidi/> by the worker in `deploy/`
(`npx wrangler deploy`).

**That address is published.** Other sites link to it, the WEBMIDI.js docs
among them, and so do this repository's homepage field and the site's
sitemap. It never changes without a permanent (301) redirect from the old
address, and the old `…/Web-MIDI.dmg` keeps going to the newest release.
`tests/deploy/test-worker.js` holds these addresses as written and fails
unless each still answers through the worker and the route. When the page
moves, add the new address there, and remove an old one only once nothing
links to it. Renaming this repository breaks the page as well: GitHub
redirects everything after a rename except a project's Pages address, so
`ORIGIN` in the worker has to change in the same commit.

The link preview, `site/images/og-card.png`, is drawn by
`python3 tools/make-og-card.py` (Pillow) and committed. Redraw it when the
app icon, the wave or the page's `--bg` changes, and put the stamp it prints
on `og:image`.

The download is the newest GitHub release's disk image: the page links to
`…/safari-webmidi/Web-MIDI.dmg`, where the worker counts it and sends it on
to `releases/latest/download/Web-MIDI.dmg`. To release a version,
bump it in `extension/manifest.json` and the page's version line,
`./tools/build.sh --notarize`, commit and push, then

```bash
./tools/release.sh
```

It opens `build/Web-MIDI.dmg`, takes the version from the app inside, and
refuses unless the commit's manifest and page say the same version, the
extension's files in the image are the ones the commit lays out, and the image
and app are stapled and Developer ID-signed. Then it tags `v<version>` on the
commit, attaches the image as `Web-MIDI.dmg`, and checks that the page's link
now downloads it. A version already released with other bytes is refused: a
new build needs a new version.

### Download counts

```bash
./tools/downloads.sh
```

The worker writes one key per download to the `COUNTS` KV namespace
(`wrangler.toml`): the day, and the version that was newest then. Nothing of
the request is kept: no address, no user agent, no header. It counts a
download when a browser went there as it goes to a page, by a click, a link
or a typed address (`Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`).
Not by `Sec-Fetch-User`, which Safari does not send even for a real click.
Crawlers, link previews, prefetches and curl are not counted, so the count is
a floor, and a download straight from GitHub is not in it.
The script prints it by day, month and version, beside GitHub's own count of
each release's asset, which takes every fetch from anywhere, bots and
`tools/release.sh`'s check of each release included.
