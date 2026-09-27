// background.js, popup.js and content.js in Node, against a fake Safari,
// for what the WebKit harness cannot stage: a question swapped under the
// popup, an insecure page, a send Safari refuses with a clear() behind it,
// and the native process starting again.  Each section is one of the
// audit's findings (2026-09-27), and each failed on the code it audited.
//   node tests/extension/test-extension.js
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
process.exitCode = 1;
let failed = 0;
function check(name, ok, detail) {
    console.log((ok ? 'ok    ' : 'FAIL  ') + name + (ok || detail === undefined ? '' : '  - ' + JSON.stringify(detail)));
    if (!ok) failed++;
}
const read = f => fs.readFileSync(path.join(__dirname, '../../extension', f), 'utf8');
const turn = () => new Promise(setImmediate);
const sleep = ms => new Promise(r => setTimeout(r, ms));
// One finding's checks: one that throws or stalls fails, and the next runs.
async function section(name, fn) {
    let timer;
    const stalled = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('stalled for 10 s')), 10000); });
    try { await Promise.race([fn(), stalled]); }
    catch (e) { check(name + ': ran to the end', false, String(e && e.message || e)); }
    clearTimeout(timer);
}

const POPUP = { url: 'safari-web-extension://ext/popup.html' };
const SITE = 'https://music.example';
const page = { url: SITE + '/', frameId: 0, tab: { id: 1, url: SITE + '/' } };
const PORTS = () => ({ gen: 'g', inputs: [], outputs: [] });

// The real background.js with Safari's APIs faked.  `native(cmd)` answers
// sendNativeMessage; `policy(msg)` answers a frame policy question.
function background(o = {}) {
    let listener;
    const b = { store: { grants: o.grants || {} }, toPopup: [], toTab: [], onUpdated: [], nativeCalls: 0, popup: null, drop: false,
                popupOpens: 0, windows: [], removed: [] };
    const browser = {
        runtime: {
            onMessage: { addListener(fn) { listener = fn; } },
            getURL: p => 'safari-web-extension://ext/' + (p || ''),
            sendNativeMessage: async (app, cmd) => { b.nativeCalls++; return o.native ? o.native(JSON.parse(JSON.stringify(cmd))) : {}; },
            sendMessage: async msg => {
                b.toPopup.push(msg);
                if (!b.popup || b.drop) throw new Error('Could not establish connection. Receiving end does not exist.');
                return b.popup(msg);
            }
        },
        storage: { local: {
            get: async () => JSON.parse(JSON.stringify(b.store)),
            set: async v => { Object.assign(b.store, JSON.parse(JSON.stringify(v))); }
        } },
        tabs: {
            query: async () => [],
            sendMessage: async (tabId, msg) => { b.toTab.push(msg); return msg.type === 'policy' && o.policy ? o.policy(msg) : undefined; },
            onRemoved: { addListener() {} },
            onUpdated: { addListener(fn) { b.onUpdated.push(fn); } }
        },
        // openPopup does what `o.openPopup` says: by default nothing, as if
        // the popup opened and asked nothing.
        action: { openPopup: async () => { b.popupOpens++; if (o.openPopup) return o.openPopup(b); }, setBadgeText() {}, setBadgeBackgroundColor() {} },
        windows: {
            create: async w => { b.windows.push(w); return { id: 100 + b.windows.length }; },
            update: async id => { if (b.removed.includes(id)) throw new Error('No window with id: ' + id); },
            remove: async id => { b.removed.push(id); }
        }
    };
    vm.runInNewContext(read('background.js'), { browser, URL, Date, setTimeout, clearTimeout });
    b.call = (msg, sender = page) => Promise.resolve(listener(msg, sender));
    b.pending = () => b.call({ type: 'pending', tabId: 1 }, POPUP);
    return b;
}

// The real popup.js, with just enough DOM, wired to a background; `search`
// is its address's query, as the window of its own has one.
function popup(b, search = '') {
    const els = {}, listeners = [];
    class El {
        constructor() { this.hidden = false; this.textContent = ''; this.disabled = false; this.onclick = null; }
        append() {}
    }
    const document = { getElementById: id => els[id] || (els[id] = new El()), createElement: () => new El() };
    const browser = {
        runtime: { sendMessage: msg => b.call(msg, POPUP), onMessage: { addListener(fn) { listeners.push(fn); } } },
        tabs: {
            query: async () => [{ id: 1, url: SITE + '/', incognito: false }],
            get: async id => ({ id, url: SITE + '/', incognito: false })
        }
    };
    b.popup = msg => { listeners.forEach(fn => fn(msg)); };
    vm.runInNewContext(read('popup.js'), { browser, document, setTimeout, clearTimeout, Date, URL, URLSearchParams, location: { search } });
    return els;
}

// The real content.js (placeholders filled) in a window that is or is not
// a secure context.
function content(secure) {
    const on = {}, runtime = [], sent = [];
    const win = { isSecureContext: secure, addEventListener(type, fn) { (on[type] = on[type] || []).push(fn); } };
    win.top = win;
    const document = {
        head: { appendChild() {} },
        documentElement: { hasAttribute: () => true, removeAttribute() {} },
        createElement: () => ({ remove() {} })
    };
    const browser = { runtime: {
        onMessage: { addListener(fn) { runtime.push(fn); } },
        sendMessage: async msg => { sent.push(msg); return { ok: true }; },
        getURL: p => p
    } };
    const src = read('content.js').replace('__SHIM_SOURCE__', '""').replace('__ICON_DATA_URL__', '""');
    vm.runInNewContext(src, { window: win, document, browser, location: { origin: SITE, href: SITE + '/' } });
    return { win, on, runtime, sent };
}

(async () => {
    // --- 1. an answer counts for the question it names ------------------------------
    await section('the question', async () => {
        const b = background();
        const basic = b.call({ type: 'request', sysex: false, doc: 'd1' });
        await turn();
        const shown = await b.pending();
        check('the question on show has an id', shown && typeof shown.id === 'string' && shown.sysex === false, shown);
        const notice = b.toTab.find(m => m.type === 'notice' && m.show);
        check('and the page’s notice names it', notice && notice.id === shown.id, notice);
        const upgraded = b.call({ type: 'request', sysex: true, doc: 'd1' });
        await turn();
        const asked = await b.pending();
        const stale = await b.call({ type: 'decide', tabId: 1, id: shown.id, answer: 'allow' }, POPUP);
        const bare = await b.call({ type: 'decide', tabId: 1, answer: 'allow' }, POPUP);
        check('an Allow for a question since replaced is refused', stale === false && bare === false, [stale, bare]);
        check('and grants nothing', !b.store.grants[SITE] || (!b.store.grants[SITE].midi && !b.store.grants[SITE].sysex), b.store.grants);
        check('the question asked now is still asked', asked.sysex === true && (await b.pending()).id === asked.id);
        await b.call({ type: 'notice-dismissed', id: shown.id, doc: 'd1' });
        check('a notice for the replaced question cannot dismiss it', (await b.pending()) && (await b.pending()).id === asked.id);
        check('the popup is told each time the question changes', b.toPopup.filter(m => m.type === 'asked' && m.tabId === 1).length >= 2, b.toPopup);
        const taken = await b.call({ type: 'decide', tabId: 1, id: asked.id, answer: 'allow' }, POPUP);
        check('an Allow naming the question on show answers it', taken === true && (await upgraded).ok === true &&
              b.store.grants[SITE].sysex === 'granted', b.store.grants);
        check('the request it replaced was refused', (await basic).ok === false);
    });
    await section('a question gone', async () => {
        // A question goes with the documents that asked it, deciding nothing.
        const b = background();
        const first = b.call({ type: 'request', doc: 'd1' });
        await turn();
        const second = b.call({ type: 'request', doc: 'd2' });
        await turn();
        await b.call({ type: 'gone', doc: 'd1' });
        check('a question stays while a document that asked it is there', (await b.pending()) !== null);
        await b.call({ type: 'gone', doc: 'd2' });
        check('and goes when every one has gone', (await b.pending()) === null);
        check('refusing them', (await first).ok === false && (await second).ok === false);
        check('and recording no dismissal', !b.store.grants[SITE], b.store.grants);

        const third = b.call({ type: 'request', doc: 'd3' });
        await turn();
        b.onUpdated.forEach(fn => fn(1, { url: SITE + '/another-page' }));
        check('a question stays while its tab is on the site it names', (await b.pending()) !== null);
        b.onUpdated.forEach(fn => fn(1, { url: 'https://elsewhere.example/' }));
        check('and goes when the tab leaves it', (await b.pending()) === null && (await third).ok === false);
    });
    await section('the popup', async () => {
        // The popup: redraws when the question changes, takes no click for
        // half a second after one comes on show, and a click it sends for a
        // question since replaced grants nothing.
        const b = background();
        const basic = b.call({ type: 'request', doc: 'd1' });
        await turn();
        const els = popup(b);
        await sleep(50);
        const q = () => els.askQuestion.textContent;
        check('the popup shows the question', !els.ask.hidden && /to use your MIDI devices/.test(q()), q());
        check('its buttons wait at first', els.askAllow.disabled && els.askBlock.disabled);
        const line = e => e.hereState ? e.hereState.textContent : '';
        check('and no line under it says the site has not asked', els.here.hidden, line(els));
        els.askAllow.onclick();
        await sleep(50);
        check('and a click that comes anyway does nothing', (await b.pending()) !== null && !b.store.grants[SITE]);
        await sleep(500);
        check('then they take clicks', !els.askAllow.disabled);

        // The page swaps in a sysex question, and the popup is not told.
        b.drop = true;
        const upgraded = b.call({ type: 'request', sysex: true, doc: 'd1' });
        await sleep(50);
        check('(a popup not told still shows the old question)', /to use your MIDI devices/.test(q()), q());
        els.askAllow.onclick();
        await sleep(50);
        check('Allow on it grants nothing', !b.store.grants[SITE] || !b.store.grants[SITE].sysex, b.store.grants);
        check('and the popup shows the question asked now, waiting again',
              /control and reprogram/.test(q()) && els.askAllow.disabled && !els.askDetail.hidden, q());
        await sleep(550);
        els.askAllow.onclick();
        await sleep(50);
        check('Allow then answers it', (await upgraded).ok === true && b.store.grants[SITE].sysex === 'granted', b.store.grants);
        check('and the popup puts the question away', els.ask.hidden);
        await sleep(150);
        check('the site’s line then says what it may do', !els.here.hidden && /control and reprogram/.test(line(els)), line(els));

        // Told, it redraws at once.
        b.drop = false;
        await b.call({ type: 'forget', origin: SITE, incognito: false }, POPUP);
        b.call({ type: 'request', doc: 'd1' });
        await sleep(50);
        check('a popup that is told redraws with the new question', !els.ask.hidden && /to use your MIDI devices/.test(q()) &&
              els.askAllow.disabled, q());
        check('and hides the site’s line again', els.here.hidden, line(els));
        await basic;

        // A site asking for sysex that may already use MIDI keeps its line.
        const more = background({ grants: { [SITE]: { midi: 'granted' } } });
        more.call({ type: 'request', sysex: true, doc: 'd1' });
        await turn();
        const els2 = popup(more);
        await sleep(50);
        check('a site asking for more keeps the line saying what it may do now',
              !els2.ask.hidden && !els2.here.hidden && /^Can use/.test(line(els2)), line(els2));

        // One that asked and was dismissed, asking nothing now.
        const els3 = popup(background({ grants: { [SITE]: { dismissed: 1 } } }));
        await sleep(50);
        check('a site dismissed is not said to have not asked', !els3.here.hidden && /^Asked/.test(line(els3)), line(els3));
    });

    await section('the notice', async () => {
        // The page's notice: yes to basic MIDI for the question it showed,
        // from the tab's top document on that site only; for sysex it only
        // opens the question out of the page's reach.
        const b = background();
        const basic = b.call({ type: 'request', doc: 'd1' });
        await turn();
        const shown = await b.pending();
        const frame = { url: SITE + '/frame', frameId: 7, tab: page.tab };
        const elsewhere = { url: 'https://elsewhere.example/', frameId: 0, tab: page.tab };
        const refused = [
            await b.call({ type: 'notice-allow', id: shown.id, doc: 'f' }, frame),
            await b.call({ type: 'notice-allow', id: shown.id, doc: 'e' }, elsewhere),
            await b.call({ type: 'notice-allow', id: 'another', doc: 'd1' })
        ];
        check('Allow from a frame, another site, or for another question is refused', refused.every(r => r === false), refused);
        check('and grants nothing', !b.store.grants[SITE] && (await b.pending()) !== null, b.store.grants);
        const taken = await b.call({ type: 'notice-allow', id: shown.id, doc: 'd1' });
        check('Allow for the basic question on show answers it', taken === true && (await basic).ok === true &&
              b.store.grants[SITE].midi === 'granted' && (await b.pending()) === null, b.store.grants);

        const sysex = b.call({ type: 'request', sysex: true, doc: 'd1' });
        await turn();
        const asked = await b.pending();
        const opens = b.popupOpens;
        await b.call({ type: 'notice-allow', id: asked.id, doc: 'd1' });
        await turn();
        check('Allow for a sysex question grants nothing', !b.store.grants[SITE].sysex && (await b.pending()).id === asked.id, b.store.grants);
        check('and opens the popup instead', b.popupOpens === opens + 1, b.popupOpens);
        b.call({ type: 'pending', tabId: 1, opened: true }, POPUP);    // the popup opens
        await sleep(1100);
        check('a popup that opened gets no window beside it', b.windows.length === 0, b.windows);
        await b.call({ type: 'decide', tabId: 1, id: asked.id, answer: 'block' }, POPUP);
        await sysex;
    });
    await section('no toolbar button', async () => {
        // Where no popup opens, whether openPopup says so or not, the question
        // opens in a window of the extension's own, which goes with it.
        const b = background();
        const q = b.call({ type: 'request', sysex: true, doc: 'd1' });
        await turn();
        const asked = await b.pending();
        await b.call({ type: 'notice-open', id: asked.id, doc: 'd1' });
        await sleep(300);
        check('(no window while a popup may still open)', b.windows.length === 0, b.windows);
        await sleep(900);
        const w = b.windows[0];
        check('a popup that never asked gets a window with the question', b.windows.length === 1 &&
              w.url === 'safari-web-extension://ext/popup.html?tab=1' && w.type === 'popup', b.windows);
        await b.call({ type: 'notice-open', id: asked.id, doc: 'd1' });
        await sleep(1100);
        check('Allow… again brings that window forward, not a second', b.windows.length === 1, b.windows);

        const els = popup(b, '?tab=1');
        await sleep(50);
        check('the window asks the question of the tab its address names', !els.ask.hidden &&
              /control and reprogram/.test(els.askQuestion.textContent), els.askQuestion.textContent);
        await sleep(500);
        els.askAllow.onclick();
        await sleep(50);
        check('its Allow answers it', (await q).ok === true && b.store.grants[SITE].sysex === 'granted', b.store.grants);
        check('and the window goes with the question', b.removed.includes(101), b.removed);

        const failing = background({ openPopup: async () => { throw new Error('No toolbar item'); } });
        failing.call({ type: 'request', doc: 'd1' });
        await turn();
        await failing.call({ type: 'notice-open', id: (await failing.pending()).id, doc: 'd1' });
        await sleep(50);
        check('where openPopup fails, the window opens at once', failing.windows.length === 1, failing.windows);
        failing.onUpdated.forEach(fn => fn(1, { url: 'https://elsewhere.example/' }));
        await turn();
        check('and goes when the question does', failing.removed.includes(101), failing.removed);
    });

    // --- 2. insecure documents get nothing ------------------------------------------
    await section('secure contexts', async () => {
        const insecure = content(false);
        check('an insecure document gets no channel to the extension', !insecure.on.message && !insecure.runtime.length, Object.keys(insecure.on));
        const secure = content(true);
        check('a secure one does', !!secure.on.message && secure.runtime.length > 0);
        const port = { postMessage() {} };
        secure.on.message[0]({ source: secure.win, data: { __webmidi_connect: 1 }, ports: [port], stopImmediatePropagation() {} });
        port.onmessage({ data: { id: 1, op: 'request', args: {} } });
        await turn();
        check('and every message it sends names its document', secure.sent.length === 1 && typeof secure.sent[0].doc === 'string' &&
              secure.sent[0].doc.length > 4, secure.sent);

        const http = { url: 'http://insecure.example/', frameId: 0, tab: { id: 1, url: 'http://insecure.example/' } };
        const b = background({ grants: { 'http://insecure.example': { midi: 'granted' } }, native: PORTS, policy: () => true });
        const r = await b.call({ type: 'request', doc: 'd' }, http);
        check('the background refuses an http page’s request', r.ok === false && r.error.name === 'SecurityError' &&
              (await b.pending()) === null, r);
        const n = await b.call({ type: 'native', doc: 'd', req: { cmd: 'ports' } }, http);
        check('and its native requests, granted or not', !!n.error && b.nativeCalls === 0, n);
        check('and says "denied" when it asks', (await b.call({ type: 'permission', doc: 'd' }, http)) === 'denied');
        const under = { url: 'https://frame.example/', frameId: 5, tab: { id: 1, url: 'http://insecure.example/' } };
        check('and a secure frame under an http page', !!(await b.call({ type: 'native', doc: 'f', req: { cmd: 'ports' } }, under)).error);
        const local = ['http://localhost:8000/', 'http://127.0.0.1/', 'http://[::1]:3000/', 'http://app.localhost/'];
        const b2 = background({ grants: Object.fromEntries(local.map(u => [new URL(u).origin, { midi: 'granted' }])), native: PORTS });
        const ok = await Promise.all(local.map(u => b2.call({ type: 'native', doc: 'd', req: { cmd: 'ports' } },
                                                             { url: u, frameId: 0, tab: { id: 1, url: u } })));
        check('http to this machine counts as secure, as Safari counts it', ok.every(x => x.value), ok);
    });

    // --- 3. a frame's policy is its document's --------------------------------------
    await section('frame policy', async () => {
        let allow = true, queries = 0;
        const b = background({ grants: { [SITE]: { midi: 'granted' } }, native: PORTS, policy: () => { queries++; return allow; } });
        const child = { url: 'https://frame.example/', frameId: 7, tab: page.tab };
        const ports = doc => b.call({ type: 'native', doc, req: { cmd: 'ports' } }, child);
        check('an allowed frame is let in', !!(await ports('f1')).value);
        check('and its policy is remembered for its document', !!(await ports('f1')).value && queries === 1, queries);
        allow = false;           // its parent now says allow="midi 'none'", and reloads it at the same URL
        const again = await ports('f2');
        check('the frame reloaded at the same URL is asked about afresh', again.error && again.error.name === 'SecurityError' && queries === 2,
              [again, queries]);
        allow = true;            // and the other way
        check('so a frame newly allowed is let in', !!(await ports('f3')).value && queries === 3, queries);
        await b.call({ type: 'gone', doc: 'f3' }, child);
        await ports('f3');
        check('a document gone is forgotten', queries === 4, queries);
    });

    // --- 4. a page's sends and clears keep their order ------------------------------
    await section('sends and clears', async () => {
        const later = Date.now() + 10000;
        function run(refuse) {
            const seen = [];
            const b = background({ grants: { [SITE]: { midi: 'granted' } }, native: cmd => {
                if (refuse[cmd.cmd] > 0) {
                    refuse[cmd.cmd]--;
                    seen.push(cmd.cmd + ' refused');
                    throw new Error('Invalid call to runtime.sendNativeMessage(). (SFErrorDomain error 3.)');
                }
                seen.push(cmd.cmd + ' ' + (cmd.msgs ? cmd.msgs.map(m => m[0]).join('+') : cmd.port));
                return { ok: true, failed: [] };
            } });
            const send = (doc, ports) => b.call({ type: 'native', doc, req: { cmd: 'send', msgs: ports.map(p => [p, 'kDwB', later]) } });
            const clear = (doc, port) => b.call({ type: 'native', doc, req: { cmd: 'clear', port } });
            return { seen, send, clear };
        }
        // The audit's order: a send refused and waiting to go again, then a
        // clear() of its port, then another send.
        let t = run({ send: 1 });
        let first = t.send('d', ['A', 'B']);
        await turn();
        check('(the send is refused, and waits to go again)', t.seen.join(', ') === 'send refused', t.seen);
        await Promise.all([first, t.clear('d', 'A'), t.send('d', ['A'])]);
        check('a refused send goes again before a clear() made after it, without the cleared port',
              t.seen.join(', ') === 'send refused, send B, clear A, send A', t.seen);
        t = run({ send: 1 });
        first = t.send('d', ['A']);
        await turn();
        await Promise.all([first, t.clear('d', 'A')]);
        check('a refused send whose every port was cleared since never goes', t.seen.join(', ') === 'send refused, clear A', t.seen);
        t = run({});
        await Promise.all([t.send('d', ['A', 'B']), t.clear('d', 'A')]);
        check('a send not yet gone when its page clears a port leaves that port out', t.seen.join(', ') === 'send B, clear A', t.seen);
        t = run({ clear: 1 });
        first = t.send('d', ['A']);
        await turn();
        await Promise.all([first, t.clear('d', 'A'), t.send('d', ['A'])]);
        check('a refused clear() goes again before the sends made after it', t.seen.join(', ') === 'send A, clear refused, clear A, send A', t.seen);
        t = run({ send: 1 });
        first = t.send('d', ['A']);
        await turn();
        await Promise.all([first, t.clear('another page', 'A')]);
        check('another page\u2019s clear() leaves this page\u2019s send alone', t.seen.includes('send A'), t.seen);
    });

    // --- 5. the native process starting again ----------------------------------------
    await section('native restart', async () => {
        let session = 'S1', seq = 5000;
        const asked = [];
        const b = background({ grants: { [SITE]: { midi: 'granted' } }, native: cmd => {
            asked.push([cmd.since, cmd.session]);
            return { seq, session, gen: 'g', events: [] };
        } });
        const recv = (since, doc = 'd') => b.call({ type: 'native', doc, req: { cmd: 'recv', since, wait: 0 } });
        await recv(-1);                  // this page's floor: 5000, in S1
        await recv(0);
        check('a cursor below the page’s floor is raised to it', asked[1][0] === 5000 && asked[1][1] === 'S1', asked[1]);
        session = 'S2'; seq = 3;         // the native process starts again, numbering from 0
        const first = await recv(5000);
        check('a receive names the session its floor holds in', asked[2][1] === 'S1', asked[2]);
        await recv(first.value.seq);
        check('after a restart the floor is the new process’s start', asked[3][0] === 3 && asked[3][1] === 'S2', asked[3]);
        await recv(0, 'new since');
        check('a page new since then still reads only from now', asked[4][0] === -1, asked[4]);
    });

    console.log(failed ? `${failed} FAILED` : 'ALL EXTENSION CHECKS PASSED');
    process.exit(failed ? 1 : 0);
})();
