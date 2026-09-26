// The toolbar popup: what this site may do, and every site decided so far.
'use strict';
var TEXT = {
    sysex: 'Can control and reprogram your MIDI devices',
    midi: 'Can use your MIDI devices',
    blocked: 'Blocked from your MIDI devices',
    notAsked: 'Has not asked to use MIDI',
    forget: 'Reset',
    all: 'Sites',
    none: 'No site has asked yet.'
};
function stateOf(o) {
    if (!o) return TEXT.notAsked;
    if (o.sysex === 'granted') return TEXT.sysex;
    if (o.midi === 'granted') return TEXT.midi;
    return TEXT.blocked;
}
function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text) e.textContent = text; return e; }

function draw() {
    Promise.all([
        browser.runtime.sendMessage({ type: 'grants' }),
        browser.tabs.query({ active: true, currentWindow: true })
    ]).then(function (r) {
        var grants = r[0] || {}, tab = r[1] && r[1][0];
        var here = null;
        try { here = tab && tab.url ? new URL(tab.url) : null; } catch (e) {}
        var box = document.getElementById('here');
        if (here && /^https?:$/.test(here.protocol)) {
            box.hidden = false;
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
    browser.runtime.sendMessage({ type: 'forget', origin: origin }).then(draw);
}
draw();
