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

// --- where a request comes from -------------------------------------------------
// Whether a frame may use MIDI under the Permissions Policy: the tab's
// frames are asked which of them holds it, and that one reads its <iframe>'s
// allow attribute (content.js).  Remembered per frame and document URL,
// since a container policy applies from the frame's navigation on.
var policies = new Map();
function policyOf(sender) {
    if (!sender.frameId) return Promise.resolve(true);
    if (!sender.tab) return Promise.resolve(false);
    var key = sender.tab.id + ':' + sender.frameId + ':' + sender.url;
    if (!policies.has(key)) {
        if (policies.size > 500) policies.clear();
        var origin;
        try { origin = new URL(sender.url).origin; } catch (e) { return Promise.resolve(false); }
        policies.set(key, browser.tabs.sendMessage(sender.tab.id, { type: 'policy', frameId: sender.frameId, origin: origin })
            .then(function (r) { return r === true; }, function () { return false; }));
    }
    return policies.get(key);
}

// Whose permission a request uses.  A frame's request uses the top-level
// site's, as Chrome delegates it, and the question names that site.
function originOf(sender) {
    var own;
    try { own = new URL(sender.url); } catch (e) { return Promise.resolve({ error: POLICY }); }
    if (own.origin === 'null') return Promise.resolve({ error: POLICY });
    var incognito = !!(sender.tab && sender.tab.incognito);
    if (!sender.frameId) return Promise.resolve({ origin: own.origin, host: own.host, incognito: incognito });
    return policyOf(sender).then(function (allowed) {
        if (!allowed) return { error: POLICY };
        var top = new URL(sender.tab.url);
        return { origin: top.origin, host: top.host, incognito: incognito };
    });
}

// --- asking the person -------------------------------------------------------
// The question is asked in the extension's own toolbar popup, never in the
// page: a page can restyle, hide or cover anything drawn in its own DOM, so a
// prompt there proved only that someone clicked, not what they saw.  A
// pending question puts a badge on the button and opens the popup; the page
// shows a notice pointing at the button, which can say no but never yes.
var pending = new Map();     // tabId -> { site, origin, sysex, incognito, answer, resolve }
function askUser(tabId, from, sysex) {
    var p = pending.get(tabId);
    if (p && p.origin === from.origin && p.sysex === sysex) return p.answer;
    if (p) p.resolve('dismiss');
    var entry = { site: from.host, origin: from.origin, sysex: sysex, incognito: from.incognito };
    entry.answer = new Promise(function (resolve) { entry.resolve = resolve; });
    pending.set(tabId, entry);
    entry.answer.then(function () {
        if (pending.get(tabId) === entry) pending.delete(tabId);
        showBadge(tabId, false);
        browser.tabs.sendMessage(tabId, { type: 'notice', show: false }, { frameId: 0 }).catch(function () {});
    });
    showBadge(tabId, true);
    browser.tabs.sendMessage(tabId, { type: 'notice', show: true, site: from.host, sysex: sysex }, { frameId: 0 })
        .catch(function () {});
    Promise.resolve().then(function () { return browser.action.openPopup(); }).catch(function () {});
    return entry.answer;
}
function showBadge(tabId, on) {
    try {
        browser.action.setBadgeText({ tabId: tabId, text: on ? '1' : '' });
        if (on) browser.action.setBadgeBackgroundColor({ tabId: tabId, color: '#FFDA6C' });
    } catch (e) {}
}
browser.tabs.onRemoved.addListener(function (tabId) {
    var p = pending.get(tabId);
    if (p) p.resolve('dismiss');
    floors.forEach(function (v, k) { if (k.indexOf(tabId + ':') === 0) floors.delete(k); });
});

function request(sender, sysex) {
    return originOf(sender).then(function (from) {
        if (from.error) return { ok: false, error: from.error };
        return grants(from.incognito).then(function (g) {
            if (granted(g, from.origin, sysex)) return { ok: true };
            if (refused(g, from.origin, sysex)) return { ok: false, error: NOT_ALLOWED };
            if (!sender.tab) return { ok: false, error: NOT_ALLOWED };
            return askUser(sender.tab.id, from, sysex).then(function (answer) {
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
function permissionState(sender, sysex) {
    return originOf(sender).then(function (from) {
        if (from.error) return 'denied';
        return grants(from.incognito).then(function (g) {
            if (granted(g, from.origin, sysex)) return 'granted';
            if (refused(g, from.origin, sysex)) return 'denied';
            return 'prompt';
        });
    });
}

// --- the native side -----------------------------------------------------------
// Each document is its own client (content.js makes the id): its scheduled
// sends are its own to clear, and it reads only what arrived after its first
// receive.  The hub keeps input from every tab for a while, and a page that
// asked from the start would otherwise read other sites' traffic.
var floors = new Map();     // client -> the first sequence number it may read
function clientOf(sender, doc) {
    return (sender.tab ? sender.tab.id : 'x') + ':' + (sender.frameId || 0) + ':' + String(doc || '');
}
function native(sender, req, doc) {
    return originOf(sender).then(function (from) {
        if (from.error) return { error: from.error };
        return grants(from.incognito).then(function (g) {
            if (!granted(g, from.origin, false)) return { error: NOT_ALLOWED };
            var client = clientOf(sender, doc);
            var cmd = { cmd: req.cmd };
            var sysex = granted(g, from.origin, true);
            switch (req.cmd) {
            case 'ports': break;
            case 'send': cmd.msgs = req.msgs; cmd.sysex = sysex; cmd.client = client; break;
            case 'clear': cmd.port = String(req.port); cmd.client = client; break;
            case 'recv':
                var floor = floors.get(client);
                cmd.since = floor === undefined ? -1 : Math.max(Number(req.since) || 0, floor);
                cmd.gen = req.gen; cmd.sysex = sysex;
                cmd.wait = Math.max(0, Math.min(Number(req.wait) || 0, 5000));
                break;
            default: return { error: error('NotSupportedError', 'Unknown request') };
            }
            return browser.runtime.sendNativeMessage(NATIVE_APP, cmd).then(function (r) {
                if (!r) return { error: error('AbortError', 'The MIDI system failed to start.') };
                if (r.error) return { error: error('InvalidStateError', 'Platform dependent initialization failed.') };
                if (req.cmd === 'recv' && !floors.has(client)) {
                    if (floors.size > 1000) floors.clear();
                    floors.set(client, r.seq);
                }
                return { value: r };
            }, function () {
                return { error: error('AbortError', 'The MIDI system failed to start.') };
            });
        });
    });
}

// --- messages --------------------------------------------------------------------
function fromExtensionPage(sender) {
    return !!sender.url && sender.url.indexOf(browser.runtime.getURL('')) === 0;
}
browser.runtime.onMessage.addListener(function (msg, sender) {
    if (!msg) return undefined;
    switch (msg.type) {
    case 'request': return request(sender, !!msg.sysex);
    case 'native': return native(sender, msg.req || {}, msg.doc);
    case 'permission': return permissionState(sender, !!msg.sysex);
    case 'policy-self': return policyOf(sender);
    // The page's notice can say no, never yes.
    case 'notice-dismissed':
        if (sender.tab && !sender.frameId && pending.has(sender.tab.id)) pending.get(sender.tab.id).resolve('dismiss');
        return Promise.resolve(true);
    }
    // From the toolbar popup, the extension's own page, only.
    if (!fromExtensionPage(sender)) return undefined;
    switch (msg.type) {
    case 'grants': return grants(!!msg.incognito);
    case 'pending': {
        var p = pending.get(msg.tabId);
        return Promise.resolve(p ? { site: p.site, sysex: p.sysex } : null);
    }
    case 'decide': {
        var q = pending.get(msg.tabId);
        if (q && (msg.answer === 'allow' || msg.answer === 'block')) q.resolve(msg.answer);
        return Promise.resolve(true);
    }
    case 'forget':
        return ['midi', 'sysex', 'dismissed', 'embargo'].reduce(function (chain, kind) {
            return chain.then(function () { return setGrant(msg.origin, kind, null, !!msg.incognito); });
        }, Promise.resolve()).then(function () { return { ok: true }; });
    }
    return undefined;
});
