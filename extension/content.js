// The isolated-world half of the extension, in every frame.
//
// It puts shim.js into the page's own world, carries the shim's requests to
// background.js and the answers back, and draws the permission prompt in
// the top frame.  Bytes cross to the background as base64: Safari's
// extension messaging is JSON, the page's side is Uint8Arrays.
'use strict';
(function () {
    if (window.__webmidiContent) return;
    window.__webmidiContent = true;
    // Web MIDI is [SecureContext], and an insecure document gets none of
    // this: no shim, no channel to the extension, no answers for it.  Only
    // the shim was held back once, and an http page could open the channel
    // itself and ask for devices (the audit, 2026-09-27).  This world's
    // isSecureContext is the browser's, which the page cannot redefine, and
    // it is false under an insecure ancestor too.  background.js checks the
    // URLs as well.
    if (!window.isSecureContext) return;

    // This document's id, sent with everything this asks the background: its
    // scheduled sends, its place in the input, its question and its frame's
    // policy are its own (background.js).  A frame keeps its frameId, and
    // often its URL, across a reload; this is new every time.
    var DOC = Math.random().toString(36).slice(2) + Date.now().toString(36);
    function ask(msg) { msg.doc = DOC; return browser.runtime.sendMessage(msg); }
    // Gone, or into the back-forward cache: the background drops its
    // question and forgets it.
    window.addEventListener('pagehide', function (e) {
        if (e.isTrusted) ask({ type: 'gone' }).catch(function () {});
    }, true);

    // --- putting the shim in the page -----------------------------------------
    // Inline first: it runs at once, before any of the page's scripts, so a
    // site that looks for requestMIDIAccess while loading finds it.  A page
    // whose Content-Security-Policy refuses inline script gets the file
    // instead, which runs a moment later.  (Safari does not support
    // "world": "MAIN" in the manifest.)
    var SHIM_SOURCE = __SHIM_SOURCE__;
    function inject() {
        var parent = document.head || document.documentElement;
        if (!parent) return;
        var s = document.createElement('script');
        s.textContent = SHIM_SOURCE + '\n//# sourceURL=webmidi-shim.js';
        parent.appendChild(s);
        s.remove();
        if (document.documentElement.hasAttribute('data-webmidi')) {
            document.documentElement.removeAttribute('data-webmidi');
            return;
        }
        var f = document.createElement('script');
        f.src = browser.runtime.getURL('shim.js');
        f.onload = f.onerror = function () { f.remove(); };
        parent.appendChild(f);
    }
    inject();

    // --- base64 ----------------------------------------------------------------
    function toBase64(bytes) {
        var s = '';
        for (var i = 0; i < bytes.length; i += 0x8000) {
            s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        return btoa(s);
    }
    function fromBase64(b64) {
        var s = atob(b64), out = new Uint8Array(s.length);
        for (var i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
        return out;
    }

    // --- Permissions Policy for frames ---------------------------------------
    // The "midi" feature's default allowlist is 'self' (spec 4.2): a frame
    // may use MIDI when its container allows it and every container above
    // it does too.  Only the parent document can read an <iframe>'s allow
    // attribute, so the background asks the tab's frames which one holds
    // the frame in question (runtime.getFrameId), and that one answers.
    // All of it goes through the extension; nothing is posted where the
    // page's own message listeners would see it.
    // Whether an <iframe>'s allow attribute lets `child` use MIDI, by the
    // Permissions Policy rules: "midi" alone means the frame's src origin.
    function allows(frame, child) {
        var self = location.origin, src = null, list = null;
        try { src = new URL(frame.getAttribute('src') || 'about:blank', location.href).origin; } catch (e) {}
        (frame.getAttribute('allow') || '').split(';').forEach(function (directive) {
            var t = directive.trim().split(/\s+/).filter(Boolean);
            if (t.length && t[0].toLowerCase() === 'midi') list = t.slice(1);
        });
        if (list === null) return child === self;
        if (!list.length) list = ["'src'"];
        return list.some(function (tok) {
            var k = tok.toLowerCase();
            if (k === '*') return true;
            if (k === "'none'") return false;
            if (k === "'self'") return child === self;
            if (k === "'src'") return child === src;
            try { return new URL(tok).origin === child; } catch (e) { return false; }
        });
    }
    browser.runtime.onMessage.addListener(function (msg) {
        if (!msg || msg.type !== 'policy') return undefined;
        // Frames in open shadow roots too; a closed root cannot be searched,
        // and a frame in one is refused.
        var frames = [];
        (function collect(root) {
            Array.prototype.push.apply(frames, root.querySelectorAll('iframe, frame'));
            root.querySelectorAll('*').forEach(function (el) { if (el.shadowRoot) collect(el.shadowRoot); });
        })(document);
        var frame = frames.find(function (f) {
            try { return browser.runtime.getFrameId(f) === msg.frameId; } catch (e) { return false; }
        });
        if (!frame) return undefined;          // not ours: the frame that holds it answers
        if (!allows(frame, msg.origin)) return Promise.resolve(false);
        // And this document must be allowed itself.
        return window === window.top ? Promise.resolve(true)
            : ask({ type: 'policy-self' }).then(function (r) { return r === true; });
    });

    // Safari unloads the extension's background 30 s after the last message
    // reached it, and a reply it still owes does not count (WebKit,
    // WebExtensionContext::unloadBackgroundContentIfPossible).  The question
    // waiting for the person lives there, so one left 30 s went with it: its
    // Allow did nothing and the page waited for ever.  So while a request
    // waits, this asks after it every WAITING ms, which keeps the background
    // loaded, and asks again if the background has lost it anyway.
    var WAITING = 10000;
    var waiting = new Set();     // this document's requests still waiting: { check, refuse }
    function requested(sysex) {
        return new Promise(function (resolve, reject) {
            var over = false, timer = setInterval(check, WAITING);
            var w = { check: check, refuse: function () {
                end(resolve, { ok: false, error: { name: 'NotAllowedError', message: 'Permission to use Web MIDI API was not granted.' } });
            } };
            waiting.add(w);
            function end(fn, v) {
                if (over) return;
                over = true; clearInterval(timer); waiting.delete(w); fn(v);
            }
            function send() {
                ask({ type: 'request', sysex: sysex }).then(function (r) { end(resolve, r); }, function () {});
            }
            function check() {
                ask({ type: 'waiting' }).then(function (known) { if (!over && known !== true) send(); },
                                              function (e) { end(reject, e); });
            }
            send();
        });
    }

    function native(req) {
        return ask({ type: 'native', req: req }).then(function (r) {
            if (!r || r.error) throw r && r.error ? r.error : { name: 'AbortError', message: 'The MIDI system failed to start.' };
            return r.value;
        });
    }

    // --- the shim's channel ----------------------------------------------------
    window.addEventListener('message', function (e) {
        if (e.source !== window || !e.data || !e.data.__webmidi_connect || !e.ports || !e.ports[0]) return;
        e.stopImmediatePropagation();
        serve(e.ports[0]);
    }, true);

    var ports = [];
    browser.runtime.onMessage.addListener(function (msg) {
        if (msg && msg.type === 'grants-changed') {
            ports.forEach(function (p) { p.postMessage({ event: 'permissionchange' }); });
        }
        return undefined;
    });

    function serve(port) {
        ports.push(port);
        // A page can open channels at will; the notices go to the latest few.
        if (ports.length > 16) ports.shift();
        function answer(id, ok, value, transfer) {
            if (id === undefined) return;
            try { port.postMessage(ok ? { id: id, ok: true, value: value } : { id: id, ok: false, error: value }, transfer || []); }
            catch (err) { port.postMessage({ id: id, ok: false, error: { name: 'AbortError', message: String(err) } }); }
        }
        port.onmessage = function (e) {
            var m = e.data || {}, args = m.args || {};
            var done = function (v, t) { answer(m.id, true, v, t); };
            var fail = function (err) {
                answer(m.id, false, { name: (err && err.name) || 'AbortError', message: (err && err.message) || String(err) });
            };
            switch (m.op) {
            case 'request':
                requested(!!args.sysex).then(function (r) {
                    if (r && r.ok) done(true); else fail(r && r.error);
                }, fail);
                break;
            case 'permission':
                ask({ type: 'permission', sysex: !!args.sysex }).then(done, fail);
                break;
            case 'ports':
                native({ cmd: 'ports' }).then(done, fail);
                break;
            case 'send':
                native({ cmd: 'send', msgs: (args.msgs || []).map(function (q) { return [q[0], toBase64(q[1]), q[2] || 0, q[3] || 0]; }) })
                    .then(done, fail);
                break;
            case 'clear':
                native({ cmd: 'clear', port: args.port }).then(done, fail);
                break;
            case 'recv':
                native({ cmd: 'recv', since: args.since, gen: args.gen, wait: args.wait }).then(function (r) {
                    var transfer = [];
                    r.events = (r.events || []).map(function (ev) {
                        var bytes = fromBase64(ev[1]);
                        transfer.push(bytes.buffer);
                        return [ev[0], bytes, ev[2]];
                    });
                    done(r, transfer);
                }, fail);
                break;
            default:
                fail({ name: 'NotSupportedError', message: 'Unknown request' });
            }
        };
    }

    // --- the notice (top frame only) --------------------------------------------
    // The question is asked here, and in the extension's toolbar popup, where
    // a page cannot reach it (background.js), when the person opens that.  A page can restyle, hide or cover what is drawn in its own DOM,
    // so a click here proves less than one in the popup.  The notice's Allow
    // is for basic MIDI only, and it takes a click only when:
    //   - the click is the person's (isTrusted), half a second or more after
    //     the notice came on show, so a click aimed at the page as the notice
    //     appeared cannot land on it;
    //   - the notice is in the top layer, over everything the page draws in
    //     the ordinary way, whatever its z-index;
    //   - its element keeps the style it was given, carries no drawing of
    //     the page's (::before, ::after), and nothing of the page's is in the
    //     top layer with it (a popover, a modal dialog, fullscreen).
    // Otherwise the click opens the question where the page cannot reach it.
    // A page can still hide the notice with a top-layer element of its own
    // in a closed shadow root.  That is accepted for basic MIDI, and not for
    // sysex, which can rewrite a device's settings and firmware: a sysex
    // question's Allow… only opens the popup, or where Safari's toolbar has
    // no Web MIDI button, a window of the extension's own.  Closing the
    // notice counts as dismissing the question.
    if (window !== window.top) return;

    var TEXT = {
        midi: '“{site}” is asking to use your MIDI devices.',
        sysex: '“{site}” is asking to control and reprogram your MIDI devices.',
        sysexDetail: 'This lets the site change your devices’ settings and firmware.',
        close: 'Not now',
        allow: 'Allow',
        allowElsewhere: 'Allow…',
        from: 'Web MIDI'
    };
    var ICON = __ICON_DATA_URL__;
    // Safari's Liquid Glass, as near as a page can draw it: a translucent,
    // blurred and saturated panel with a lit edge, and capsule buttons.
    var CSS = [
        ':host{all:initial}',
        '.wrap{position:fixed;top:14px;left:50%;transform:translateX(-50%);z-index:2147483647;',
        'width:max-content;max-width:min(440px,calc(100vw - 32px));box-sizing:border-box;padding:16px 18px 14px;',
        'border-radius:26px;display:grid;grid-template-columns:auto 1fr;column-gap:14px;',
        'font:13px/1.4 -apple-system,system-ui,sans-serif;color:#1d1d1f;',
        'background:rgba(255,255,255,.58);-webkit-backdrop-filter:blur(28px) saturate(190%);backdrop-filter:blur(28px) saturate(190%);',
        'border:.5px solid rgba(255,255,255,.7);',
        'box-shadow:inset 0 1px 0 rgba(255,255,255,.85),inset 0 -1px 1px rgba(255,255,255,.25),0 12px 40px rgba(0,0,0,.22),0 0 0 .5px rgba(0,0,0,.08)}',
        '.icon{width:40px;height:40px;grid-row:1 / span 4;margin-top:2px}',
        '.from{font-size:11px;font-weight:600;color:rgba(60,60,67,.7);margin:0 0 2px}',
        '.q{font-weight:600;font-size:14px;margin:0;overflow-wrap:anywhere}',
        '.d{margin:4px 0 0;color:rgba(60,60,67,.85)}',
        '.b{display:flex;justify-content:flex-end;gap:8px;margin-top:12px;grid-column:2}',
        'button{font:inherit;font-weight:500;padding:6px 16px;border-radius:999px;border:0;cursor:pointer;',
        'color:#1d1d1f;background:rgba(255,255,255,.55);box-shadow:inset 0 1px 0 rgba(255,255,255,.9),inset 0 0 0 .5px rgba(0,0,0,.12)}',
        'button.primary{color:#fff;background:#000;box-shadow:none}',
        'button:active{transform:scale(.97)}',
        'button:disabled{opacity:.45;cursor:default;transform:none}',
        '@media (prefers-color-scheme:dark){.wrap{color:#f5f5f7;background:rgba(40,40,44,.55);border-color:rgba(255,255,255,.18);',
        'box-shadow:inset 0 1px 0 rgba(255,255,255,.22),0 12px 40px rgba(0,0,0,.5)}',
        '.from{color:rgba(235,235,245,.6)}.d{color:rgba(235,235,245,.8)}',
        'button{color:#f5f5f7;background:rgba(255,255,255,.12);box-shadow:inset 0 1px 0 rgba(255,255,255,.2),inset 0 0 0 .5px rgba(255,255,255,.12)}',
        'button.primary{color:#000;background:#fff;box-shadow:none}}'
    ].join('');
    var STYLE = 'all:initial !important;display:block !important;position:fixed !important;' +
        'inset:0 auto auto 0 !important;z-index:2147483647 !important';
    var READY_AFTER = 500;

    // Whether the notice can be seen as it was drawn (above).
    function unobscured(host) {
        try {
            if (!host.isConnected || !host.matches(':popover-open')) return false;
            if (host.getAttribute('style') !== STYLE || host.getAttribute('popover') !== 'manual') return false;
            if (document.fullscreenElement || document.webkitFullscreenElement) return false;
            if (!host.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
            var drawn = ['::before', '::after'].some(function (pseudo) {
                var c = getComputedStyle(host, pseudo).content;
                return c && c !== 'none' && c !== 'normal';
            });
            if (drawn) return false;
            var above = document.querySelectorAll(':popover-open, :modal');
            for (var i = 0; i < above.length; i++) if (above[i] !== host) return false;
            return true;
        } catch (e) { return false; }
    }

    var notice = null;
    function hideNotice() {
        if (!notice) return;
        document.removeEventListener('keydown', notice.onKey, true);
        clearTimeout(notice.timer);
        notice.host.remove();
        notice = null;
    }
    function showNotice(id, site, sysex) {
        hideNotice();
        var host = document.createElement('webmidi-notice');
        host.setAttribute('style', STYLE);
        host.setAttribute('popover', 'manual');
        var shadow = host.attachShadow({ mode: 'closed' });
        var style = document.createElement('style');
        style.textContent = CSS;
        var box = document.createElement('div');
        box.className = 'wrap';
        box.setAttribute('role', 'alertdialog');
        box.setAttribute('aria-labelledby', 'q');
        var img = document.createElement('img'); img.className = 'icon'; img.src = ICON; img.alt = '';
        var from = document.createElement('p'); from.className = 'from'; from.textContent = TEXT.from;
        var q = document.createElement('p'); q.className = 'q'; q.id = 'q';
        q.textContent = (sysex ? TEXT.sysex : TEXT.midi).replace('{site}', site);
        box.append(img, from, q);
        if (sysex) {
            var d = document.createElement('p'); d.className = 'd'; d.textContent = TEXT.sysexDetail;
            box.append(d);
        }
        var bar = document.createElement('div'); bar.className = 'b';
        var close = document.createElement('button'); close.textContent = TEXT.close;
        var allow = document.createElement('button'); allow.className = 'primary';
        allow.textContent = sysex ? TEXT.allowElsewhere : TEXT.allow;
        bar.append(close, allow);
        box.append(bar);
        shadow.append(style, box);
        // A background that has lost the question (unloaded, above) takes no
        // answer: Not now then refuses this document's requests here, and
        // Allow asks again at once, so a new notice comes up.
        function dismiss(e) {
            if (!e.isTrusted) return;
            hideNotice();
            ask({ type: 'notice-dismissed', id: id }).then(function (taken) {
                if (taken !== true) waiting.forEach(function (w) { w.refuse(); });
            }, function () {});
        }
        close.addEventListener('click', dismiss);
        var onKey = function (e) { if (e.key === 'Escape') dismiss(e); };
        document.addEventListener('keydown', onKey, true);
        var shownAt = Date.now(), timer;
        if (!sysex) {
            allow.disabled = true;
            timer = setTimeout(function () { allow.disabled = false; }, READY_AFTER);
        }
        allow.addEventListener('click', function (e) {
            if (!e.isTrusted) return;
            var yes = !sysex && Date.now() - shownAt >= READY_AFTER && unobscured(host);
            ask({ type: yes ? 'notice-allow' : 'notice-open', id: id }).then(function (taken) {
                if (taken !== true) waiting.forEach(function (w) { w.check(); });
            }, function () {});
        });
        (document.body || document.documentElement).appendChild(host);
        try { host.showPopover(); } catch (e) {}
        notice = { host: host, onKey: onKey, timer: timer };
    }

    browser.runtime.onMessage.addListener(function (msg) {
        if (msg && msg.type === 'notice') {
            if (msg.show) showNotice(msg.id, msg.site, !!msg.sysex); else hideNotice();
        }
        return undefined;
    });
})();
