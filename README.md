# Web MIDI for Safari

Safari has no Web MIDI API, and WebKit has said it will not ship one. This is
a Safari web extension that supplies it: `navigator.requestMIDIAccess()` and
the rest of the API, backed by CoreMIDI, behind a per-site permission prompt.

It is a port of **Chromium's** implementation, so a site gets what it gets
in Chrome:

| Part | Ported from (Chromium `08da355f`) | Here |
|---|---|---|
| The API in the page | `third_party/blink/renderer/modules/webmidi/*` | `extension/shim.js` |
| Permission and checks | `content/browser/media/midi_host.cc` | `extension/background.js` |
| Byte streams and UMP | `media/midi/{message_util,midi_message_queue,ump_message_util}.cc` | `native/MIDIMessages.swift` |
| CoreMIDI | `media/midi/midi_manager_mac.cc` | `native/MIDIHub.swift` |

## Licence

This project's own files are released under the Unlicense (`UNLICENSE`), as
218e Rewired is. The files ported from Chromium (`extension/shim.js`,
`native/MIDIMessages.swift`, and the parts of `native/MIDIHub.swift` and
`extension/background.js` that follow Chromium) stay under Chromium's BSD
licence, which is in `third_party/chromium/LICENSE` and ships in the app.

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
- **background.js** holds the permission decisions and is the only way to
  CoreMIDI; every request is checked there, as Chrome checks in the browser
  process.
- **MIDIHub** receives by long poll (it answers when a message arrives) and
  schedules timestamped sends itself.

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
- **Cross-origin frames of `about:blank` or `srcdoc`** are refused.

## Building

```bash
./tools/build.sh
```

Builds and signs `build/Web MIDI.app` with the Developer ID; `--notarize` also
notarises and staples it. No Xcode project: the bundle is laid out by the
script. Requires macOS 13.5+ and Safari 18.4+ (the first Safari that accepts
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

MIDIHub against a virtual CoreMIDI loop: order, sysex up to 10 kB, timestamps,
`clear()`, port changes.

```bash
./tools/test-webkit.sh
```

The built extension end to end in WebKit: shim and content script injected as
Safari injects them, background in its own view, real clicks on the prompt.
`--wpt` runs the web-platform-tests Web MIDI IDL test instead.

What these cannot reach is Safari's own plumbing (the extension store,
`sendNativeMessage`); that is checked by hand in Safari.

## Publishing

`site/` is the download page, published to GitHub Pages by
`.github/workflows/pages.yml`, and served at
<https://triglavmodular.hu/mods/safari-webmidi/> by the worker in `deploy/`
(`npx wrangler deploy`). `./tools/build.sh --notarize` puts the notarised zip
at `site/Web-MIDI.zip`, and a commit of it publishes the new version.

