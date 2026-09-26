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

    // --- putting the shim in the page -----------------------------------------
    // Inline first: it runs at once, before any of the page's scripts, so a
    // site that looks for requestMIDIAccess while loading finds it.  A page
    // whose Content-Security-Policy refuses inline script gets the file
    // instead, which runs a moment later.  (Safari does not support
    // "world": "MAIN" in the manifest.)
    var SHIM_SOURCE = __SHIM_SOURCE__;
    function inject() {
        var parent = document.head || document.documentElement;
        if (!parent || !window.isSecureContext) return;
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
        var frame = Array.prototype.find.call(document.querySelectorAll('iframe, frame'), function (f) {
            try { return browser.runtime.getFrameId(f) === msg.frameId; } catch (e) { return false; }
        });
        if (!frame) return undefined;          // not ours: the frame that holds it answers
        if (!allows(frame, msg.origin)) return Promise.resolve(false);
        // And this document must be allowed itself.
        return window === window.top ? Promise.resolve(true)
            : browser.runtime.sendMessage({ type: 'policy-self' }).then(function (r) { return r === true; });
    });

    function ask(msg) { return browser.runtime.sendMessage(msg); }
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
                ask({ type: 'request', sysex: !!args.sysex }).then(function (r) {
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
                native({ cmd: 'send', msgs: (args.msgs || []).map(function (q) { return [q[0], toBase64(q[1]), q[2] || 0]; }) })
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

    // --- the permission prompt (top frame only) ------------------------------
    if (window !== window.top) return;

    var TEXT = {
        midi: 'Allow “{site}” to use your MIDI devices?',
        sysex: 'Allow “{site}” to control and reprogram your MIDI devices?',
        sysexDetail: 'This lets the site change your devices’ settings and firmware.',
        allow: 'Allow',
        block: 'Don’t Allow',
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
        '.b{display:flex;gap:8px;justify-content:flex-end;margin-top:14px;grid-column:2}',
        'button{font:inherit;font-weight:500;padding:6px 16px;border-radius:999px;border:0;cursor:pointer;',
        'transition:transform .12s ease,opacity .2s}',
        'button:active{transform:scale(.97)}button:disabled{opacity:.45;cursor:default}',
        '.no{color:#1d1d1f;background:rgba(255,255,255,.55);',
        'box-shadow:inset 0 1px 0 rgba(255,255,255,.9),inset 0 0 0 .5px rgba(0,0,0,.12)}',
        '.yes{color:#fff;background:#000;box-shadow:inset 0 1px 0 rgba(255,255,255,.28),0 1px 3px rgba(0,0,0,.25)}',
        '@media (prefers-color-scheme:dark){.wrap{color:#f5f5f7;background:rgba(40,40,44,.55);border-color:rgba(255,255,255,.18);',
        'box-shadow:inset 0 1px 0 rgba(255,255,255,.22),0 12px 40px rgba(0,0,0,.5)}',
        '.from{color:rgba(235,235,245,.6)}.d{color:rgba(235,235,245,.8)}',
        '.no{color:#f5f5f7;background:rgba(255,255,255,.12);box-shadow:inset 0 1px 0 rgba(255,255,255,.2),inset 0 0 0 .5px rgba(255,255,255,.12)}',
        '.yes{color:#000;background:#fff}}'
    ].join('');

    var showing = null;
    function prompt(site, sysex) {
        if (showing) return showing;
        showing = new Promise(function (resolve) {
            var host = document.createElement('webmidi-prompt');
            host.setAttribute('style', 'all:initial !important;display:block !important;position:fixed !important;' +
                'inset:0 auto auto 0 !important;z-index:2147483647 !important;opacity:1 !important;visibility:visible !important');
            var shadow = host.attachShadow({ mode: 'closed' });
            var style = document.createElement('style');
            style.textContent = CSS;
            var box = document.createElement('div');
            box.className = 'wrap';
            box.setAttribute('role', 'alertdialog');
            var img = document.createElement('img'); img.className = 'icon'; img.src = ICON; img.alt = '';
            var from = document.createElement('p'); from.className = 'from'; from.textContent = TEXT.from;
            var q = document.createElement('p'); q.className = 'q';
            q.textContent = (sysex ? TEXT.sysex : TEXT.midi).replace('{site}', site);
            box.append(img, from, q);
            if (sysex) { var d = document.createElement('p'); d.className = 'd'; d.textContent = TEXT.sysexDetail; box.append(d); }
            var bar = document.createElement('div'); bar.className = 'b';
            var no = document.createElement('button'); no.className = 'no'; no.textContent = TEXT.block;
            var yes = document.createElement('button'); yes.className = 'yes'; yes.textContent = TEXT.allow;
            bar.append(no, yes); box.append(bar);
            shadow.append(style, box);
            // Buttons wake after a moment, so a click aimed at the page as the
            // prompt appears cannot land on Allow.
            no.disabled = yes.disabled = true;
            setTimeout(function () { no.disabled = yes.disabled = false; }, 500);

            var watcher = new MutationObserver(function () {
                if (!host.isConnected) document.documentElement.appendChild(host);
            });
            function finish(answer) {
                watcher.disconnect();
                document.removeEventListener('keydown', onKey, true);
                host.remove();
                showing = null;
                resolve(answer);
            }
            // Only a real click decides: a page can dispatch clicks, but they
            // are not trusted.
            no.addEventListener('click', function (e) { if (e.isTrusted && !no.disabled) finish('block'); });
            yes.addEventListener('click', function (e) { if (e.isTrusted && !yes.disabled) finish('allow'); });
            function onKey(e) { if (e.isTrusted && e.key === 'Escape') finish('dismiss'); }
            document.addEventListener('keydown', onKey, true);
            (document.body || document.documentElement).appendChild(host);
            watcher.observe(document.documentElement, { childList: true, subtree: true });
        });
        return showing;
    }

    browser.runtime.onMessage.addListener(function (msg) {
        if (msg && msg.type === 'prompt') return prompt(msg.site, !!msg.sysex);
        return undefined;
    });
})();
