// The extension's background: the permission decisions, and the only way
// to the native CoreMIDI handler.  Everything a page asks for comes through
// here, and here is where it is checked, as Chromium checks in the browser
// process (content/browser/media/midi_host.cc) and not in the renderer.
'use strict';

var NATIVE_APP = 'application.id';     // Safari ignores it: always our own app

// Grants by origin: { midi: 'granted' | 'denied', sysex: 'granted' | 'denied' }.
function grants() {
    return browser.storage.local.get('grants').then(function (r) { return r.grants || {}; });
}
function setGrant(origin, kind, value) {
    return grants().then(function (g) {
        var o = g[origin] || {};
        if (value === null) delete o[kind]; else o[kind] = value;
        if (Object.keys(o).length) g[origin] = o; else delete g[origin];
        return browser.storage.local.set({ grants: g });
    }).then(function () {
        // PermissionStatus objects in open pages fire "change".
        return browser.tabs.query({}).then(function (tabs) {
            tabs.forEach(function (t) { browser.tabs.sendMessage(t.id, { type: 'grants-changed' }).catch(function () {}); });
        }, function () {});
    });
}
// The Permissions API state for {name: "midi", sysex}.
function permissionState(sender, sysex) {
    return Promise.all([originOf(sender), grants()]).then(function (r) {
        var from = r[0], g = r[1];
        if (from.error) return 'denied';
        var o = g[from.origin] || {};
        if (granted(g, from.origin, sysex)) return 'granted';
        if (o.midi === 'denied' || (sysex && o.sysex === 'denied')) return 'denied';
        return 'prompt';
    });
}
function granted(g, origin, sysex) {
    var o = g[origin] || {};
    return sysex ? o.sysex === 'granted' : (o.midi === 'granted' || o.sysex === 'granted');
}

function error(name, message) { return { name: name, message: message }; }
var NOT_ALLOWED = error('NotAllowedError', 'Permission to use Web MIDI API was not granted.');
var POLICY = error('SecurityError', 'Midi has been disabled in this document by permissions policy.');

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

// Where a request comes from, and whose permission it uses.  A frame's
// request uses the permission of the top-level site, as Chrome delegates
// it, and the prompt names that site.
function originOf(sender) {
    var own;
    try { own = new URL(sender.url); } catch (e) { return Promise.resolve({ error: POLICY }); }
    if (own.origin === 'null') return Promise.resolve({ error: POLICY });
    if (!sender.frameId) return Promise.resolve({ origin: own.origin, host: own.host });
    return policyOf(sender).then(function (allowed) {
        if (!allowed) return { error: POLICY };
        var top = new URL(sender.tab.url);
        return { origin: top.origin, host: top.host };
    });
}

// One prompt at a time per tab; a second request waits for the first answer.
var prompts = new Map();
function askUser(tabId, site, sysex) {
    var key = tabId + (sysex ? ':sysex' : ':midi');
    if (!prompts.has(key)) {
        prompts.set(key, browser.tabs.sendMessage(tabId, { type: 'prompt', site: site, sysex: sysex }, { frameId: 0 })
            .catch(function () { return 'dismiss'; })
            .finally(function () { prompts.delete(key); }));
    }
    return prompts.get(key);
}

function request(sender, sysex) {
    return Promise.all([originOf(sender), grants()]).then(function (r) {
        var from = r[0], g = r[1];
        if (from.error) return { ok: false, error: from.error };
        if (granted(g, from.origin, sysex)) return { ok: true };
        var o = g[from.origin] || {};
        if (o.midi === 'denied' || (sysex && o.sysex === 'denied')) return { ok: false, error: NOT_ALLOWED };
        if (!sender.tab) return { ok: false, error: NOT_ALLOWED };
        return askUser(sender.tab.id, from.host, sysex).then(function (answer) {
            // Dismissing decides nothing: the next request asks again.
            if (answer === 'dismiss') return { ok: false, error: NOT_ALLOWED };
            var value = answer === 'allow' ? 'granted' : 'denied';
            return setGrant(from.origin, sysex ? 'sysex' : 'midi', value).then(function () {
                return value === 'granted' ? { ok: true } : { ok: false, error: NOT_ALLOWED };
            });
        });
    });
}

function native(sender, req) {
    return Promise.all([originOf(sender), grants()]).then(function (r) {
        var from = r[0], g = r[1];
        if (from.error) return { error: from.error };
        if (!granted(g, from.origin, false)) return { error: NOT_ALLOWED };
        var cmd = { cmd: req.cmd };
        var sysex = granted(g, from.origin, true);
        switch (req.cmd) {
        case 'ports': break;
        case 'send': cmd.msgs = req.msgs; cmd.sysex = sysex; break;
        case 'clear': cmd.port = String(req.port); break;
        case 'recv':
            cmd.since = req.since; cmd.gen = req.gen; cmd.sysex = sysex;
            cmd.wait = Math.max(0, Math.min(Number(req.wait) || 0, 5000));
            break;
        default: return { error: error('NotSupportedError', 'Unknown request') };
        }
        return browser.runtime.sendNativeMessage(NATIVE_APP, cmd).then(function (r) {
            if (!r) return { error: error('AbortError', 'The MIDI system failed to start.') };
            if (r.error) return { error: error('InvalidStateError', 'Platform dependent initialization failed.') };
            return { value: r };
        }, function () {
            return { error: error('AbortError', 'The MIDI system failed to start.') };
        });
    });
}

browser.runtime.onMessage.addListener(function (msg, sender) {
    if (!msg) return undefined;
    switch (msg.type) {
    case 'request': return request(sender, !!msg.sysex);
    case 'native': return native(sender, msg.req || {});
    case 'permission': return permissionState(sender, !!msg.sysex);
    case 'policy-self': return policyOf(sender);
    // From the toolbar popup, which is the extension's own page.
    case 'grants':
        if (sender.url && sender.url.indexOf(browser.runtime.getURL('')) !== 0) return undefined;
        return grants();
    case 'forget':
        if (sender.url && sender.url.indexOf(browser.runtime.getURL('')) !== 0) return undefined;
        return setGrant(msg.origin, 'midi', null).then(function () { return setGrant(msg.origin, 'sysex', null); })
            .then(function () { return { ok: true }; });
    }
    return undefined;
});
