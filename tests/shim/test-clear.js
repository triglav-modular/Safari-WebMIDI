// The real shim.js in Node, against a fake content script, for what the
// WebKit harness cannot stage: sends queued behind one that has not come
// back yet.  clear() must give back what it took out of the queue, or the
// 10 MB allowance fills with cancelled sends and every later send is
// dropped (the audit, 2026-09-26).
//   node tests/shim/test-clear.js
'use strict';
const fs = require('fs'), path = require('path');
process.exitCode = 1;
let failed = 0;
function check(name, ok, detail) {
    console.log((ok ? 'ok    ' : 'FAIL  ') + name + (ok || !detail ? '' : '  - ' + detail));
    if (!ok) failed++;
}

// A browser just big enough for the shim.
class Navigator {}
globalThis.Navigator = Navigator;
Object.defineProperty(globalThis, 'navigator', { value: new Navigator(), configurable: true, writable: true });
globalThis.window = globalThis;
globalThis.isSecureContext = true;
globalThis.document = { currentScript: null, documentElement: { setAttribute() {} } };

// The content script: grants everything, lists one output, answers sends
// only when told to, and keeps the receive loop idle.
const sends = [];
let holdSends = true, heldReplies = [];
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
        case 'send':
            sends.push(m.args.msgs.reduce((n, q) => n + q[1].length, 0));
            if (holdSends) heldReplies.push(() => answer({ ok: true })); else answer({ ok: true });
            return;
        case 'clear': return;
        }
    };
    port.start && port.start();
};

eval(fs.readFileSync(path.join(__dirname, '../../extension/shim.js'), 'utf8'));

const sleep = ms => new Promise(r => setTimeout(r, ms));
function sysex(n) { const b = new Uint8Array(n); b[0] = 0xf0; b[n - 1] = 0xf7; return b; }

(async () => {
    const access = await navigator.requestMIDIAccess({ sysex: true });
    const out = access.outputs.values().next().value;
    await out.open();
    const MB3 = 3 << 20;

    out.send(sysex(MB3));            // goes out and is not answered yet
    await sleep(20);
    out.send(sysex(MB3));            // queued behind it
    out.send(sysex(MB3));            // queued: 9 MB counted in all
    out.clear();                     // takes the two queued out
    out.send(sysex(MB3));            // must fit again
    out.send(sysex(MB3));
    await sleep(20);
    check('one batch went out while the rest waited', sends.length === 1, JSON.stringify(sends));

    holdSends = false;
    heldReplies.forEach(f => f()); heldReplies = [];
    await sleep(200);
    const after = sends.slice(1).reduce((a, b) => a + b, 0);
    check('the sends made after clear() go out', after === 2 * MB3, `${after} bytes after the first batch`);

    out.send([0x90, 60, 100]);
    await sleep(100);
    check('and a note after them too', sends[sends.length - 1] === 3, JSON.stringify(sends.slice(-2)));

    console.log(failed ? `${failed} FAILED` : 'ALL SHIM CHECKS PASSED');
    process.exit(failed ? 1 : 0);
})();
