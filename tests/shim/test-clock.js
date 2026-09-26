// The real shim.js in Node, for how it turns page times into the wall-clock
// times the native side schedules by.  performance.timeOrigin is fixed when
// the page loads; a wall clock corrected after that (by about 40 ms on a CI
// runner) must be followed, or timestamped sends go out that far off.  And
// equal page times must still give equal wall times, or CoreMIDI may play
// them in either order (the audit, 2026-09-26).
//   node tests/shim/test-clock.js
'use strict';
const fs = require('fs'), path = require('path');
process.exitCode = 1;
let failed = 0;
function check(name, ok, detail) {
    console.log((ok ? 'ok    ' : 'FAIL  ') + name + (ok || !detail ? '' : '  - ' + detail));
    if (!ok) failed++;
}

// A browser just big enough for the shim, with a wall clock that can be moved.
class Navigator {}
globalThis.Navigator = Navigator;
Object.defineProperty(globalThis, 'navigator', { value: new Navigator(), configurable: true, writable: true });
globalThis.window = globalThis;
globalThis.isSecureContext = true;
globalThis.document = { currentScript: null, documentElement: { setAttribute() {} } };
let correction = 0;
const realNow = Date.now;
Date.now = () => realNow() + correction;

// The content script: grants everything, lists one output, answers every
// send at once and keeps the wall time it was given.
const walls = [];
globalThis.postMessage = function (msg, target, transfer) {
    if (!msg || !msg.__webmidi_connect) return;
    const port = transfer[0];
    port.onmessage = e => {
        const m = e.data;
        const answer = value => port.postMessage({ id: m.id, ok: true, value });
        switch (m.op) {
        case 'request': return answer(true);
        case 'ports': return answer({ gen: 'g', inputs: [], outputs: [{ id: '7', name: 'Out', manufacturer: '', version: '' }] });
        case 'recv': return setTimeout(() => answer({ seq: 0, gen: 'g', events: [] }), 50);
        case 'send': m.args.msgs.forEach(q => walls.push(q[2])); return answer({ ok: true });
        case 'clear': return;
        }
    };
    port.start && port.start();
};

eval(fs.readFileSync(path.join(__dirname, '../../extension/shim.js'), 'utf8'));

const sleep = ms => new Promise(r => setTimeout(r, ms));
const wallOf = async (out, t) => { const n = walls.length; out.send([0x90, 60, 1], t); await sleep(20); return walls[n]; };

(async () => {
    const access = await navigator.requestMIDIAccess();
    const out = access.outputs.values().next().value;
    await out.open();

    let t = performance.now() + 100;
    let w = await wallOf(out, t);
    check('a page time goes over as the wall-clock time it names',
          Math.abs(w - (Date.now() - performance.now() + t)) <= 3, `${(w - (Date.now() - performance.now() + t)).toFixed(1)} ms off`);

    correction = 40;                  // the wall clock is put forward 40 ms
    t = performance.now() + 100;
    w = await wallOf(out, t);
    check('after the wall clock is corrected, it follows the correction',
          Math.abs(w - (Date.now() - performance.now() + t)) <= 3, `${(w - (Date.now() - performance.now() + t)).toFixed(1)} ms off`);

    t = performance.now() + 100;
    const n = walls.length;
    for (let i = 0; i < 50; i++) out.send([0x90, 60, 1], t);
    await sleep(50);
    const same = walls.slice(n);
    check('equal page times give equal wall times', same.length === 50 && same.every(x => x === same[0]),
          `${new Set(same).size} different of ${same.length}`);

    // A note-off and a note-on given one time, with the wall clock corrected
    // between the two sends: they must still go over as one time.
    t = performance.now() + 100;
    const before = await wallOf(out, t);
    correction += 40;
    const after = await wallOf(out, t);
    check('a time given again gets the same wall time across a correction', before === after,
          `${(after - before).toFixed(1)} ms apart`);

    console.log(failed ? `${failed} FAILED` : 'ALL CLOCK CHECKS PASSED');
    process.exit(failed ? 1 : 0);
})();
