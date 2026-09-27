// The toolbar popup: what this site may do, and every site decided so far.
'use strict';
var TEXT = {
    sysex: 'Can control and reprogram your MIDI devices',
    midi: 'Can use your MIDI devices',
    blocked: 'Blocked from your MIDI devices',
    notAsked: 'Has not asked to use MIDI',
    unanswered: 'Asked, not yet answered',
    forget: 'Reset',
    all: 'Sites',
    none: 'No site has been allowed or blocked yet.',
    askMidi: 'Allow \u201c{site}\u201d to use your MIDI devices?',
    askSysex: 'Allow \u201c{site}\u201d to control and reprogram your MIDI devices?',
    askSysexDetail: 'This lets the site change your devices\u2019 settings and firmware.',
    allow: 'Allow',
    block: 'Don\u2019t Allow'
};
// A site that may use MIDI but refused sysex can still use MIDI.  One kept
// only for its dismissals asked, and had no answer.
function decided(o) { return !!(o && (o.midi || o.sysex)); }
function stateOf(o) {
    if (o && o.embargo && o.embargo > Date.now()) return TEXT.blocked;
    if (!o) return TEXT.notAsked;
    if (!decided(o)) return TEXT.unanswered;
    if (o.sysex === 'granted') return TEXT.sysex;
    if (o.midi === 'granted') return TEXT.midi;
    return TEXT.blocked;
}
// The question a page is waiting on, asked here where the page cannot
// reach it (background.js).  An answer names the question on show, and the
// background takes it for that question only; the page can ask something
// else at any moment, and the popup then shows that instead.  A question
// that has just come on show takes no click for READY_AFTER ms, so a click
// aimed at the one before it, or at the page under a popup that has just
// opened, cannot answer it.
var READY_AFTER = 500;
var shownTab = null, shownId = null, readyAt = 0, readyTimer = null;
function ask(tab) {
    if (!tab) return Promise.resolve();
    shownTab = tab;
    return browser.runtime.sendMessage({ type: 'pending', tabId: tab.id }).then(function (p) {
        var box = document.getElementById('ask');
        box.hidden = !p;
        if (!p) { shownId = null; return null; }
        document.getElementById('askQuestion').textContent = (p.sysex ? TEXT.askSysex : TEXT.askMidi).replace('{site}', p.site);
        var detail = document.getElementById('askDetail');
        detail.hidden = !p.sysex;
        detail.textContent = TEXT.askSysexDetail;
        var yes = document.getElementById('askAllow'), no = document.getElementById('askBlock');
        yes.textContent = TEXT.allow; no.textContent = TEXT.block;
        if (p.id !== shownId) {
            shownId = p.id;
            readyAt = Date.now() + READY_AFTER;
            yes.disabled = no.disabled = true;
            clearTimeout(readyTimer);
            readyTimer = setTimeout(function () { yes.disabled = no.disabled = false; }, READY_AFTER);
        }
        function decide(answer) {
            if (Date.now() < readyAt || p.id !== shownId) return;
            browser.runtime.sendMessage({ type: 'decide', tabId: tab.id, id: p.id, answer: answer }).then(function (taken) {
                if (!taken) { draw(); return; }
                box.hidden = true;
                setTimeout(draw, 100);
            });
        }
        yes.onclick = function () { decide('allow'); };
        no.onclick = function () { decide('block'); };
        return p;
    });
}
// The background says when the question changes (asked, replaced, answered
// or gone).
browser.runtime.onMessage.addListener(function (msg) {
    if (msg && msg.type === 'asked' && shownTab && msg.tabId === shownTab.id) draw();
    return undefined;
});
function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text) e.textContent = text; return e; }

var privateTab = false;
function draw() {
    browser.tabs.query({ active: true, currentWindow: true }).then(function (tabs) {
        var tab = tabs && tabs[0];
        privateTab = !!(tab && tab.incognito);
        return Promise.all([browser.runtime.sendMessage({ type: 'grants', incognito: privateTab }), tab, ask(tab)]);
    }).then(function (r) {
        var grants = r[0] || {}, tab = r[1], asking = r[2];
        var here = null;
        try { here = tab && tab.url ? new URL(tab.url) : null; } catch (e) {}
        var box = document.getElementById('here');
        // A site asking now with nothing decided is the question above; a
        // line under it saying the site had not asked was wrong.
        var askingHere = !!(asking && here && asking.origin === here.origin && !decided(grants[here.origin]));
        box.hidden = !(here && /^https?:$/.test(here.protocol)) || askingHere;
        if (!box.hidden) {
            document.getElementById('hereSite').textContent = here.host;
            document.getElementById('hereState').textContent = stateOf(grants[here.origin]);
            var b = document.getElementById('hereForget');
            b.textContent = TEXT.forget;
            b.hidden = !grants[here.origin];
            b.onclick = function () { forget(here.origin); };
        }
        document.getElementById('allTitle').textContent = TEXT.all;
        var all = document.getElementById('all');
        all.textContent = '';
        var origins = Object.keys(grants).sort();
        if (!origins.length) all.append(el('p', 'empty', TEXT.none));
        origins.forEach(function (o) {
            var row = el('div', 'row');
            var left = el('div');
            left.append(el('div', 'site', new URL(o).host), el('div', 'state', stateOf(grants[o])));
            var b = el('button', '', TEXT.forget);
            b.onclick = function () { forget(o); };
            row.append(left, b);
            all.append(row);
        });
    });
}
function forget(origin) {
    browser.runtime.sendMessage({ type: 'forget', origin: origin, incognito: privateTab }).then(draw);
}
draw();
