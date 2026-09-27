// The extension's background: the permission decisions, and the only way
// to the native CoreMIDI handler.  Everything a page asks for comes through
// here, and here is where it is checked, as Chromium checks in the browser
// process (content/browser/media/midi_host.cc) and not in the renderer.
//
// The checks follow Chromium's midi_host.cc, and the error messages are
// Chromium's.  Copyright The Chromium Authors; use of that code is governed
// by a BSD-style license that can be found in third_party/chromium/LICENSE.
'use strict';

var NATIVE_APP = 'application.id';     // Safari ignores it: always our own app

// --- decisions ---------------------------------------------------------------
// Grants by origin: { midi, sysex: 'granted' | 'denied', dismissed: n,
// embargo: ms }.  Private Browsing tabs decide into `privateGrants`, which is
// never written to storage and goes when the extension's background does.
var privateGrants = {};
function grants(incognito) {
    if (incognito) return Promise.resolve(privateGrants);
    return browser.storage.local.get('grants').then(function (r) { return r.grants || {}; });
}
// One write at a time: two decisions at once each read, changed and wrote
// the whole record, and the second write lost the first.
var writing = Promise.resolve();
function setGrant(origin, kind, value, incognito) {
    var run = writing.then(function () {
        return grants(incognito).then(function (g) {
            var o = g[origin] || {};
            if (value === null) delete o[kind]; else o[kind] = value;
            if (Object.keys(o).length) g[origin] = o; else delete g[origin];
            return incognito ? null : browser.storage.local.set({ grants: g });
        });
    });
    writing = run.catch(function () {});
    return run.then(function () {
        // PermissionStatus objects in open pages fire "change".
        return browser.tabs.query({}).then(function (tabs) {
            tabs.forEach(function (t) { browser.tabs.sendMessage(t.id, { type: 'grants-changed' }).catch(function () {}); });
        }, function () {});
    });
}
function granted(g, origin, sysex) {
    var o = g[origin] || {};
    return sysex ? o.sysex === 'granted' : (o.midi === 'granted' || o.sysex === 'granted');
}
// Chrome's embargo: three dismissals block the site for a week.
var EMBARGO_AFTER = 3, EMBARGO_FOR = 7 * 24 * 3600 * 1000;
function embargoed(o) { return !!(o && o.embargo && o.embargo > Date.now()); }
function refused(g, origin, sysex) {
    var o = g[origin] || {};
    return o.midi === 'denied' || (sysex && o.sysex === 'denied') || embargoed(o);
}

function error(name, message) { return { name: name, message: message }; }
var NOT_ALLOWED = error('NotAllowedError', 'Permission to use Web MIDI API was not granted.');
var POLICY = error('SecurityError', 'Midi has been disabled in this document by permissions policy.');
var INSECURE = error('SecurityError', 'Web MIDI is only available in secure contexts.');

// --- where a request comes from -------------------------------------------------
// `doc` is the id content.js makes for its document, sent with every
// message: a frame keeps its frameId, and often its URL, when it navigates
// or reloads, so neither tells one document from the next.
//
// Whether a frame may use MIDI under the Permissions Policy: the tab's
// frames are asked which of them holds it, and that one reads its <iframe>'s
// allow attribute (content.js).  Remembered per document, since a container
// policy applies from the frame's navigation on: keyed by frame and URL, a
// frame reloaded at the same URL under a new allow="midi 'none'" kept the
// allow it had before (the audit, 2026-09-27).  A frame's own document is
// new whenever any frame above it navigates, so no descendant outlives its
// ancestors' answers.
var policies = new Map();
function policyOf(sender, doc) {
    if (!sender.frameId) return Promise.resolve(true);
    if (!sender.tab) return Promise.resolve(false);
    var origin;
    try { origin = new URL(sender.url).origin; } catch (e) { return Promise.resolve(false); }
    function query() {
        return browser.tabs.sendMessage(sender.tab.id, { type: 'policy', frameId: sender.frameId, origin: origin })
            .then(function (r) { return r === true; }, function () { return false; });
    }
    if (!doc) return query();
    var key = sender.tab.id + ':' + sender.frameId + ':' + doc;
    if (!policies.has(key)) {
        if (policies.size > 500) policies.clear();
        policies.set(key, query());
    }
    return policies.get(key);
}

// A potentially trustworthy URL (Secure Contexts 3.1): https, or http to
// this machine.  Web MIDI is [SecureContext]; content.js serves nothing in
// an insecure document, and this refuses one whatever reaches it.  The top
// document is checked as well as the frame: a frame under an insecure page
// is not a secure context whatever its own scheme.  Frames between the two
// answer the policy question only if they are secure themselves (content.js).
function trustworthy(url) {
    var u;
    try { u = new URL(url); } catch (e) { return false; }
    if (u.protocol === 'https:') return true;
    if (u.protocol !== 'http:') return false;
    var h = u.hostname;
    return h === 'localhost' || /\.localhost$/.test(h) || h === '[::1]' || /^127(\.\d{1,3}){3}$/.test(h);
}

// Whose permission a request uses.  A frame's request uses the top-level
// site's, as Chrome delegates it, and the question names that site.
function originOf(sender, doc) {
    var own;
    try { own = new URL(sender.url); } catch (e) { return Promise.resolve({ error: POLICY }); }
    if (own.origin === 'null') return Promise.resolve({ error: POLICY });
    if (!trustworthy(sender.url)) return Promise.resolve({ error: INSECURE });
    var incognito = !!(sender.tab && sender.tab.incognito);
    if (!sender.frameId) return Promise.resolve({ origin: own.origin, host: own.host, incognito: incognito });
    if (!sender.tab || !trustworthy(sender.tab.url)) return Promise.resolve({ error: INSECURE });
    return policyOf(sender, doc).then(function (allowed) {
        if (!allowed) return { error: POLICY };
        var top = new URL(sender.tab.url);
        return { origin: top.origin, host: top.host, incognito: incognito };
    });
}

// --- asking the person -------------------------------------------------------
// The question is asked in the extension's own toolbar popup, where the page
// cannot reach it, and in a notice in the page (content.js).  A page can
// restyle, hide or cover anything drawn in its own DOM, so a click on the
// notice proves less than one in the popup: the notice can say no, and yes
// only to basic MIDI, never to sysex, which can rewrite a device's settings
// and firmware.  A pending question puts a badge on the button.  The popup
// opens when the person opens it, or from the notice's Allow…, never by
// itself: opened as the question was asked, it put two prompts on screen at
// once.  Where Safari's toolbar has no Web MIDI button, Allow… opens the same
// question in a window of the extension's own.
//
// Each question has an id of its own, and an answer counts only for the
// question it names: the popup's Allow once carried just the tab, and a
// basic-MIDI question on show could be swapped for a sysex one under it, so
// the click granted sysex (the audit, 2026-09-27).  The popup is told when
// the question changes, and redraws.  A question goes when every document
// that asked it has gone, or the tab leaves the site it names, and that
// decides nothing.
var pending = new Map();     // tabId -> { id, site, origin, sysex, incognito, askers, answer, resolve, window }
var asked = 0;
function askUser(tabId, from, sysex, client) {
    var p = pending.get(tabId);
    if (p && p.origin === from.origin && p.sysex === sysex) { p.askers.add(client); return p.answer; }
    if (p) p.resolve('dismiss');
    var entry = { id: Date.now().toString(36) + '.' + (++asked), site: from.host, origin: from.origin, sysex: sysex,
                  incognito: from.incognito, askers: new Set([client]) };
    var settle;
    entry.answer = new Promise(function (resolve) { settle = resolve; });
    // Answered once, and gone from `pending` at once, so nothing can answer it again.
    entry.resolve = function (answer) {
        if (pending.get(tabId) !== entry) return;
        pending.delete(tabId);
        if (typeof entry.window === 'number') {
            Promise.resolve().then(function () { return browser.windows.remove(entry.window); }).catch(function () {});
        }
        showBadge(tabId, false);
        browser.tabs.sendMessage(tabId, { type: 'notice', show: false }, { frameId: 0 }).catch(function () {});
        questionChanged(tabId);
        settle(answer);
    };
    pending.set(tabId, entry);
    showBadge(tabId, true);
    browser.tabs.sendMessage(tabId, { type: 'notice', show: true, id: entry.id, site: from.host, sysex: sysex }, { frameId: 0 })
        .catch(function () {});
    questionChanged(tabId);
    return entry.answer;
}
// The question where the page cannot reach it: the toolbar popup, or where
// Safari's toolbar has no Web MIDI button to open it from, a window of the
// extension's own asking the same question, which goes with the question.
// A popup asks for the question as it opens (popup.js); none asking within
// POPUP_WAIT ms means none opened, whether openPopup failed or said nothing.
var POPUP_WAIT = 1000, popupOpened = 0;
function openQuestion(tabId, entry) {
    var since = Date.now();
    return Promise.resolve().then(function () { return browser.action.openPopup(); }).then(function () {
        return new Promise(function (r) { setTimeout(r, POPUP_WAIT); });
    }, function () {}).then(function () {
        if (popupOpened >= since || pending.get(tabId) !== entry) return undefined;
        return questionWindow(tabId, entry);
    }).catch(function () {});
}
function questionWindow(tabId, entry) {
    function create() {
        entry.window = null;
        return browser.windows.create({ url: browser.runtime.getURL('popup.html?tab=' + tabId), type: 'popup', width: 320, height: 260 })
            .then(function (w) {
                if (pending.get(tabId) === entry) entry.window = w.id;
                else return browser.windows.remove(w.id);
            });
    }
    if (entry.window === null) return Promise.resolve();       // on its way
    if (entry.window === undefined) return create();
    return browser.windows.update(entry.window, { focused: true }).then(function () {}, create);
}
// The question the page's notice showed, if it is still the one asked, and
// the notice is the tab's top document, on the site the question names.
function noticeQuestion(sender, id) {
    if (!sender.tab || sender.frameId) return null;
    var n = pending.get(sender.tab.id);
    if (!n || n.id !== id) return null;
    try { if (new URL(sender.url).origin !== n.origin) return null; } catch (e) { return null; }
    return n;
}
// To the popup, if it is open.
function questionChanged(tabId) {
    Promise.resolve().then(function () { return browser.runtime.sendMessage({ type: 'asked', tabId: tabId }); })
        .catch(function () {});
}
function showBadge(tabId, on) {
    try {
        browser.action.setBadgeText({ tabId: tabId, text: on ? '1' : '' });
        if (on) browser.action.setBadgeBackgroundColor({ tabId: tabId, color: '#FFDA6C' });
    } catch (e) {}
}
// --- the toolbar button --------------------------------------------------------
// Coloured like Safari's own buttons (the manifest's icon_variants), and in
// the accent colour on a tab whose page is using Web MIDI: a document there
// has access, and has not gone.  The accent is Safari's: it draws a grey
// icon in it wherever the extension may read the page (make-icons.swift).
// A document with access receives for as long as it lives (shim.js), and
// each receive marks it again, so a background unloaded and started again
// soon knows it.  That background knows nothing of a tab it drew before, so
// a document going always redraws its tab's button.
var ACCENT = { 16: 'icons/toolbar-16.png', 19: 'icons/toolbar-19.png', 32: 'icons/toolbar-32.png', 38: 'icons/toolbar-38.png' };
var using = new Map();     // tabId -> Map(client -> { origin, incognito })
function drawButton(tabId) {
    // No path: the tab's button goes back to the manifest's.
    Promise.resolve().then(function () { return browser.action.setIcon({ tabId: tabId, path: using.has(tabId) ? ACCENT : null }); })
        .catch(function () {});
}
function use(tabId, client, from) {
    var m = using.get(tabId);
    if (!m) { using.set(tabId, m = new Map()); drawButton(tabId); }
    m.set(client, { origin: from.origin, incognito: from.incognito });
}
function unuse(tabId, client) {
    var m = using.get(tabId);
    if (m && m.delete(client) && !m.size) using.delete(tabId);
    drawButton(tabId);
}
// A site reset in the popup has no access left, whatever it had.
function revoked(origin, incognito) {
    using.forEach(function (m, tabId) {
        m.forEach(function (u, client) { if (u.origin === origin && u.incognito === incognito) m.delete(client); });
        if (!m.size) { using.delete(tabId); drawButton(tabId); }
    });
}

browser.tabs.onRemoved.addListener(function (tabId) {
    using.delete(tabId);
    var p = pending.get(tabId);
    if (p) p.resolve('dismiss');
    floors.forEach(function (v, k) { if (k.indexOf(tabId + ':') === 0) floors.delete(k); });
});
browser.tabs.onUpdated.addListener(function (tabId, change) {
    var p = pending.get(tabId);
    if (!p || !change || !change.url) return;
    var origin = null;
    try { origin = new URL(change.url).origin; } catch (e) {}
    if (origin !== p.origin) p.resolve('cancel');
});
// A document has gone (content.js, on pagehide): its question, its place in
// the input, its policy and its use of MIDI go with it.
function gone(sender, doc) {
    if (!sender.tab || !doc) return;
    var client = clientOf(sender, doc);
    unuse(sender.tab.id, client);
    var p = pending.get(sender.tab.id);
    if (p && p.askers.delete(client) && !p.askers.size) p.resolve('cancel');
    floors.delete(client);
    policies.delete(sender.tab.id + ':' + sender.frameId + ':' + doc);
}

function request(sender, sysex, doc) {
    return originOf(sender, doc).then(function (from) {
        if (from.error) return { ok: false, error: from.error };
        return grants(from.incognito).then(function (g) {
            if (granted(g, from.origin, sysex)) return { ok: true };
            if (refused(g, from.origin, sysex)) return { ok: false, error: NOT_ALLOWED };
            if (!sender.tab) return { ok: false, error: NOT_ALLOWED };
            return askUser(sender.tab.id, from, sysex, clientOf(sender, doc)).then(function (answer) {
                if (answer === 'cancel') return { ok: false, error: NOT_ALLOWED };
                if (answer === 'dismiss') {
                    // Decides nothing, but three in a row block the site for a week.
                    var n = ((g[from.origin] || {}).dismissed || 0) + 1;
                    return setGrant(from.origin, 'dismissed', n, from.incognito).then(function () {
                        if (n >= EMBARGO_AFTER) return setGrant(from.origin, 'embargo', Date.now() + EMBARGO_FOR, from.incognito);
                    }).then(function () { return { ok: false, error: NOT_ALLOWED }; });
                }
                var value = answer === 'allow' ? 'granted' : 'denied';
                return setGrant(from.origin, 'dismissed', null, from.incognito).then(function () {
                    return setGrant(from.origin, sysex ? 'sysex' : 'midi', value, from.incognito);
                }).then(function () {
                    return value === 'granted' ? { ok: true } : { ok: false, error: NOT_ALLOWED };
                });
            });
        });
    });
}

// The Permissions API state for {name: "midi", sysex}.
function permissionState(sender, sysex, doc) {
    return originOf(sender, doc).then(function (from) {
        if (from.error) return 'denied';
        return grants(from.incognito).then(function (g) {
            if (granted(g, from.origin, sysex)) return 'granted';
            if (refused(g, from.origin, sysex)) return 'denied';
            return 'prompt';
        });
    });
}

// --- Safari's limit on native requests ------------------------------------------
// Safari counts every sendNativeMessage against the extension for about five
// seconds after it is answered, and refuses the next one once the count
// reaches 151: "Invalid call to runtime.sendNativeMessage() ... (SFErrorDomain
// error 3.)".  Measured on Safari 27 (2026-09-26): 4.4 to 5.3 s a request,
// and a refusal every time the count reached 151.  Receiving every 15 ms kept
// it at 130 to 147, so notes sent on top were refused and lost: 18 of 65 in a
// 218e calibration sweep.  So requests go out at a steady RATE a second,
// with BURST in hand: however they bunch, no five or six seconds hold more
// than BURST + 6 * RATE = 145 of them.  Sends go first; a receive waits
// while fewer than RECV_RESERVE are in hand, so it never takes the last few
// a send might need.  One Safari refuses anyway never reached the native
// side, so it is tried again rather than lost.
var RATE = 20, BURST = 25, RECV_RESERVE = 6;
var tokens = BURST, filled = Date.now(), waiting = [], budgetTimer = null;
function pump() {
    var now = Date.now();
    tokens = Math.min(BURST, tokens + (now - filled) * RATE / 1000);
    filled = now;
    [true, false].forEach(function (send) {
        for (var i = 0; i < waiting.length;) {
            if (waiting[i].send !== send) { i++; continue; }
            if (tokens < (send ? 1 : 1 + RECV_RESERVE)) break;
            tokens -= 1;
            waiting.splice(i, 1)[0].go();
        }
    });
    if (waiting.length && !budgetTimer) {
        budgetTimer = setTimeout(function () { budgetTimer = null; pump(); }, Math.ceil(1000 / RATE));
    }
}
function admitted(send) {
    return new Promise(function (go) { waiting.push({ send: send, go: go }); pump(); });
}
function refusedBySafari(e) { return /SFErrorDomain error 3\b/.test(String(e && e.message || e)); }
// `slot` is a page's place in its order of sends and clears (below).
function sendNative(cmd, slot) {
    var tries = 0;
    function attempt() {
        return admitted(cmd.cmd !== 'recv').then(function () {
            if (slot && cmd.cmd === 'send') {
                cmd.msgs = cmd.msgs.filter(function (m) { return slot.wanted(m && m[0]); });
                if (!cmd.msgs.length) return { ok: true, failed: [] };
            }
            return browser.runtime.sendNativeMessage(NATIVE_APP, cmd);
        }).catch(function (e) {
            if (!refusedBySafari(e) || ++tries > 20) throw e;
            return new Promise(function (r) { setTimeout(r, 250); }).then(attempt);
        });
    }
    return attempt();
}

// --- a page's sends and clears, in order --------------------------------------------
// A send Safari refused was tried again 250 ms later, after a clear() the
// page had made meanwhile had reached the native side, so the note it was
// meant to cancel played (the audit, 2026-09-27).  So each page's sends and
// clears go to the native side one after another, in the order they arrived
// here, and a send still waiting to go leaves out its messages to a port
// the page has cleared since: it had not been sent.  Receives keep out of
// this, so a send never waits behind one.
var orders = new Map();     // client -> { tail, clears, cleared: port -> clears then }
function place(client, req) {
    var o = orders.get(client);
    if (!o) { o = { tail: Promise.resolve(), clears: 0, cleared: new Map() }; orders.set(client, o); }
    if (req.cmd === 'clear') o.cleared.set(String(req.port), ++o.clears);
    var since = o.clears, turn = o.tail, done;
    var tail = o.tail = new Promise(function (r) { done = r; });
    // Nothing left in order: nothing a clear could still reach.
    tail.then(function () { if (o.tail === tail && orders.get(client) === o) orders.delete(client); });
    return {
        turn: turn,
        done: done,
        wanted: function (port) { return !(o.cleared.get(String(port)) > since); }
    };
}

// --- the native side -----------------------------------------------------------
// Each document is its own client (content.js makes the id): its scheduled
// sends are its own to clear, and it reads only what arrived after its first
// receive.  The hub keeps input from every tab for a while, and a page that
// asked from the start would otherwise read other sites' traffic.
//
// The hub numbers input from 0 in each process, and names the process with
// a session.  A floor holds for its session only: kept across a restart, a
// floor of 5,000 silenced the page until the new process had counted that
// far (the audit, 2026-09-27).  Everything a new process holds arrived after
// the page's first receive, so the page may read it all.
var floors = new Map();     // client -> { session, seq: the first sequence number it may read }
function clientOf(sender, doc) {
    return (sender.tab ? sender.tab.id : 'x') + ':' + (sender.frameId || 0) + ':' + String(doc || '');
}
function native(sender, req, doc) {
    var client = clientOf(sender, doc);
    // A send or clear takes its place as it arrives, before the checks,
    // which take their own time.
    var slot = req.cmd === 'send' || req.cmd === 'clear' ? place(client, req) : null;
    var result = originOf(sender, doc).then(function (from) {
        if (from.error) return { error: from.error };
        return grants(from.incognito).then(function (g) {
            if (!granted(g, from.origin, false)) return { error: NOT_ALLOWED };
            if (sender.tab) use(sender.tab.id, client, from);
            var cmd = { cmd: req.cmd };
            var sysex = granted(g, from.origin, true);
            switch (req.cmd) {
            case 'ports': break;
            case 'send': cmd.msgs = Array.isArray(req.msgs) ? req.msgs : []; cmd.sysex = sysex; cmd.client = client; break;
            case 'clear': cmd.port = String(req.port); cmd.client = client; break;
            case 'recv':
                var floor = floors.get(client);
                if (floor === undefined) cmd.since = -1;
                else { cmd.since = Math.max(Number(req.since) || 0, floor.seq); cmd.session = floor.session; }
                cmd.gen = req.gen; cmd.sysex = sysex;
                cmd.wait = Math.max(0, Math.min(Number(req.wait) || 0, 5000));
                break;
            default: return { error: error('NotSupportedError', 'Unknown request') };
            }
            var go = slot ? slot.turn.then(function () { return sendNative(cmd, slot); }) : sendNative(cmd);
            return go.then(function (r) {
                if (!r) return { error: error('AbortError', 'The MIDI system failed to start.') };
                if (r.error) return { error: error('InvalidStateError', 'Platform dependent initialization failed.') };
                if (req.cmd === 'recv') {
                    var f = floors.get(client);
                    if (f === undefined) {
                        if (floors.size > 1000) floors.clear();
                        floors.set(client, { session: r.session, seq: r.seq });
                    } else if (f.session !== r.session) {
                        floors.set(client, { session: r.session, seq: 0 });
                    }
                }
                return { value: r };
            }, function () {
                return { error: error('AbortError', 'The MIDI system failed to start.') };
            });
        });
    });
    if (slot) result.then(slot.done, slot.done);
    return result;
}

// Requests still owed a reply, by client.  A page's content script asks
// after its request while it waits, which keeps Safari from unloading this
// background, and asks again if the answer is no (content.js): a background
// unloaded anyway has lost the question with everything else in memory.
var inflight = new Map();    // client -> requests
function tracked(client, work) {
    inflight.set(client, (inflight.get(client) || 0) + 1);
    function done() {
        var n = inflight.get(client) - 1;
        if (n > 0) inflight.set(client, n); else inflight.delete(client);
    }
    work.then(done, done);
    return work;
}

// --- messages --------------------------------------------------------------------
function fromExtensionPage(sender) {
    return !!sender.url && sender.url.indexOf(browser.runtime.getURL('')) === 0;
}
browser.runtime.onMessage.addListener(function (msg, sender) {
    if (!msg) return undefined;
    switch (msg.type) {
    case 'request': return tracked(clientOf(sender, msg.doc), request(sender, !!msg.sysex, msg.doc));
    case 'waiting': return Promise.resolve(inflight.has(clientOf(sender, msg.doc)));
    case 'native': return native(sender, msg.req || {}, msg.doc);
    case 'permission': return permissionState(sender, !!msg.sysex, msg.doc);
    case 'policy-self': return policyOf(sender, msg.doc);
    case 'gone': gone(sender, msg.doc); return Promise.resolve(true);
    // The page's notice, only to the question it showed: it can say no, yes
    // only to basic MIDI, and otherwise open the question out of its reach.
    case 'notice-dismissed':
    case 'notice-allow':
    case 'notice-open': {
        var n = noticeQuestion(sender, msg.id);
        if (!n) return Promise.resolve(false);
        if (msg.type === 'notice-dismissed') n.resolve('dismiss');
        else if (msg.type === 'notice-allow' && !n.sysex) n.resolve('allow');
        else openQuestion(sender.tab.id, n);
        return Promise.resolve(true);
    }
    }
    // From the toolbar popup, the extension's own page, only.
    if (!fromExtensionPage(sender)) return undefined;
    switch (msg.type) {
    case 'grants': return grants(!!msg.incognito);
    case 'pending': {
        if (msg.opened) popupOpened = Date.now();
        var p = pending.get(msg.tabId);
        return Promise.resolve(p ? { id: p.id, site: p.site, origin: p.origin, sysex: p.sysex } : null);
    }
    // True if it answered the question it names; false if that question has
    // gone or been replaced, and the popup shows the one asked now.
    case 'decide': {
        var q = pending.get(msg.tabId);
        if (!q || q.id !== msg.id || (msg.answer !== 'allow' && msg.answer !== 'block')) return Promise.resolve(false);
        q.resolve(msg.answer);
        return Promise.resolve(true);
    }
    case 'forget':
        return ['midi', 'sysex', 'dismissed', 'embargo'].reduce(function (chain, kind) {
            return chain.then(function () { return setGrant(msg.origin, kind, null, !!msg.incognito); });
        }, Promise.resolve()).then(function () { revoked(msg.origin, !!msg.incognito); return { ok: true }; });
    }
    return undefined;
});
