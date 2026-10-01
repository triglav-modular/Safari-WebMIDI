// deploy/worker.js in Node, with KV and GitHub faked: what is counted as a
// download, what is written for one, and that the download goes on whatever
// happens to the count.  Then the worker against the page and wrangler.toml,
// which is where it drifts without an error: a Download that links around the
// worker, or a binding named differently from the one the worker reads, both
// leave every download going through and none of them counted.
//   node tests/deploy/test-worker.js
'use strict';
const fs = require('fs'), os = require('os'), path = require('path');
process.exitCode = 1;
let failed = 0;
function check(name, ok, detail) {
    console.log((ok ? 'ok    ' : 'FAIL  ') + name + (ok || detail === undefined ? '' : '  - ' + JSON.stringify(detail)));
    if (!ok) failed++;
}
const ROOT = path.join(__dirname, '../..');
const source = fs.readFileSync(path.join(ROOT, 'deploy/worker.js'), 'utf8');
const PUBLIC = /const PUBLIC = '([^']+)'/.exec(source)[1];
const SITE = 'https://triglavmodular.hu';
const DMG = SITE + PUBLIC + '/Web-MIDI.dmg';
const LATEST = 'https://github.com/triglav-modular/Safari-WebMIDI/releases/latest/download/Web-MIDI.dmg';

// GitHub's answer for the newest release, as the worker asks for it.
let github = () => new Response(null, { status: 302, headers: { location: 'https://github.com/triglav-modular/Safari-WebMIDI/releases/tag/v0.1.9' } });
const asked = [];
globalThis.fetch = async (url, init) => { asked.push(String(url)); return github(url, init); };

function kv(o = {}) {
    const k = { puts: [] };
    k.put = async (key, value, options) => {
        if (o.fail) throw new Error('KV is down');
        k.puts.push({ key, value, options });
    };
    return k;
}
// One request through the worker, with everything it left running finished.
async function get(worker, env, headers = {}, method = 'GET') {
    const pending = [];
    const res = await worker.fetch(new Request(DMG, { method, headers }), env, { waitUntil: p => pending.push(p) });
    await Promise.all(pending);
    return res;
}
// A click on the page's Download, with the headers Safari 27 sent for one
// (measured 2026-09-27): no Sec-Fetch-User, even for a trusted click.
const CLICK = { 'sec-fetch-site': 'same-origin', 'sec-fetch-mode': 'navigate', 'sec-fetch-dest': 'document',
                'user-agent': 'Safari', 'cf-connecting-ip': '192.0.2.1' };

(async () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'worker-'));
    fs.writeFileSync(path.join(tmp, 'worker.mjs'), source);
    const worker = (await import(path.join(tmp, 'worker.mjs'))).default;

    // A click: counted once, as the day and the version, and nothing else.
    let COUNTS = kv(), res = await get(worker, { COUNTS }, CLICK);
    check('click: redirected to the newest release', res.status === 302 && res.headers.get('location') === LATEST, res.headers.get('location'));
    check('click: counted once', COUNTS.puts.length === 1, COUNTS.puts.length);
    const put = COUNTS.puts[0] || {};
    const day = new Date().toISOString().slice(0, 10);
    check('click: key is the day and a random id', new RegExp('^dl:' + day + ':[0-9a-f-]{36}$').test(put.key), put.key);
    check('click: metadata is the version only', JSON.stringify(put.options && put.options.metadata) === '{"version":"0.1.9"}', put.options);
    check('click: nothing of the request is written', !JSON.stringify(put).match(/Safari|192\.0\.2|navigate|same-origin|document/), put);
    check('click: kept without expiry', put.options && !('expiration' in put.options) && !('expirationTtl' in put.options), put.options);
    check('click: GitHub asked for the release page, never the asset', asked.length === 1 && asked[0].endsWith('/releases/latest'), asked);

    // Chrome's click, which adds Sec-Fetch-User, a link from another site,
    // and the address typed: each counted.
    for (const [name, headers] of [
        ['Chrome click', { ...CLICK, 'sec-fetch-user': '?1' }],
        ['link from another site', { ...CLICK, 'sec-fetch-site': 'cross-site' }],
        ['address typed', { ...CLICK, 'sec-fetch-site': 'none', 'sec-fetch-user': '?1' }],
    ]) {
        COUNTS = kv();
        res = await get(worker, { COUNTS }, headers);
        check(name + ': redirected, counted', res.status === 302 && COUNTS.puts.length === 1, COUNTS.puts.length);
    }

    // Two at once are two keys, not one counter written twice.
    COUNTS = kv();
    await Promise.all([get(worker, { COUNTS }, CLICK), get(worker, { COUNTS }, CLICK)]);
    check('two at once: two keys', COUNTS.puts.length === 2 && COUNTS.puts[0].key !== COUNTS.puts[1].key, COUNTS.puts.map(p => p.key));

    // Not a person: redirected, not counted.
    for (const [name, headers, method] of [
        ['no Sec-Fetch headers (crawler, link preview, curl)', { 'user-agent': 'Googlebot' }, 'GET'],
        ['fetch() from a script', { ...CLICK, 'sec-fetch-mode': 'cors', 'sec-fetch-dest': 'empty' }, 'GET'],
        ['in a frame', { ...CLICK, 'sec-fetch-dest': 'iframe' }, 'GET'],
        ['prefetch (Sec-Purpose)', { ...CLICK, 'sec-purpose': 'prefetch' }, 'GET'],
        ['prefetch (Purpose)', { ...CLICK, 'purpose': 'prefetch' }, 'GET'],
        ['HEAD', CLICK, 'HEAD'],
    ]) {
        COUNTS = kv();
        res = await get(worker, { COUNTS }, headers, method);
        check(name + ': redirected, not counted', res.status === 302 && res.headers.get('location') === LATEST && COUNTS.puts.length === 0,
              { status: res.status, puts: COUNTS.puts.length });
    }

    // Nothing that goes wrong with the count reaches the download.
    for (const [name, env] of [
        ['no binding', {}],
        ['binding set as a text variable', { COUNTS: 'COUNTS' }],
        ['no env at all', undefined],
        ['KV refuses the write', { COUNTS: kv({ fail: true }) }],
    ]) {
        try {
            res = await get(worker, env, CLICK);
            check(name + ': still redirected', res.status === 302 && res.headers.get('location') === LATEST, res.status);
        } catch (e) {
            check(name + ': still redirected', false, String(e));
        }
    }

    // GitHub unreachable or saying something else: counted, version unknown.
    for (const [name, answer] of [
        ['GitHub unreachable', () => { throw new TypeError('network'); }],
        ['GitHub answers 200', () => new Response('<html>')],
        ['GitHub names an odd tag', () => new Response(null, { status: 302, headers: { location: 'https://github.com/x/y/releases/tag/v1.2.3"><script>' } })],
    ]) {
        github = answer;
        COUNTS = kv();
        res = await get(worker, { COUNTS }, CLICK);
        const md = COUNTS.puts[0] && COUNTS.puts[0].options.metadata;
        check(name + ': redirected, counted, version empty', res.status === 302 && COUNTS.puts.length === 1 && md && md.version === '', md);
    }

    // The page and the deploy configuration, against the worker.
    const page = fs.readFileSync(path.join(ROOT, 'site/index.html'), 'utf8');
    const button = /<a class="button primary download" href="([^"]+)"/.exec(page);
    check('page: Download goes through the worker', button && button[1] === DMG, button && button[1]);
    const ld = /"downloadUrl": "([^"]+)"/.exec(page);
    check('page: downloadUrl goes through the worker', ld && ld[1] === DMG, ld && ld[1]);
    const toml = fs.readFileSync(path.join(ROOT, 'wrangler.toml'), 'utf8');
    check('wrangler.toml: routes the download to the worker', toml.includes(`pattern = "triglavmodular.hu${PUBLIC}*"`));
    const binding = /\[\[kv_namespaces\]\]\s*\nbinding = "([^"]+)"\s*\nid = "[0-9a-f]{32}"/.exec(toml);
    check('wrangler.toml: binds the namespace the worker writes', binding && source.includes('env.' + binding[1] + '.put'), binding && binding[1]);

    // Addresses other sites link to (the WEBMIDI.js docs, a Reddit reply, the
    // repository's homepage field, the site's sitemap), written out rather
    // than built from PUBLIC, so that moving the page fails here unless every
    // one still answers: the page, or a permanent redirect to it, and the old
    // download address the newest release.  When the page moves, add the new
    // address; remove an old one only once nothing links to it.
    const PUBLISHED = [
        'https://triglavmodular.hu/mods/safari-webmidi/',
        'https://triglavmodular.hu/mods/safari-webmidi',
        'https://triglavmodular.hu/mods/safari-webmidi/Web-MIDI.dmg',
    ];
    const routes = [...toml.matchAll(/pattern = "([^"]+)"/g)].map(m =>
        new RegExp('^' + m[1].replace(/[.?+^$()[\]{}|\\]/g, '\\$&').replace(/\*/g, '.*') + '$'));
    const canonical = /<link rel="canonical" href="([^"]+)">/.exec(page);
    const ogUrl = /<meta property="og:url" content="([^"]+)">/.exec(page);
    const ldUrl = /"url": "(https:\/\/triglavmodular\.hu\/mods\/[^"]+)"/.exec(page);
    check('page: canonical is a published address', canonical && PUBLISHED.includes(canonical[1]), canonical && canonical[1]);
    check('page: og:url and the structured data name the canonical',
          canonical && ogUrl && ldUrl && ogUrl[1] === canonical[1] && ldUrl[1] === canonical[1],
          [ogUrl && ogUrl[1], ldUrl && ldUrl[1]]);
    // The origin, faked: any page it is asked for is there.
    globalThis.fetch = async () => new Response('<!doctype html>', { status: 200, headers: { 'content-type': 'text/html' } });
    for (const address of PUBLISHED) {
        const hops = [];
        let url = address, res = null;
        try {
            for (let i = 0; i < 4; i++) {
                const u = new URL(url);
                if (!routes.some(r => r.test(u.host + u.pathname))) { hops.push('no route: ' + url); break; }
                res = await worker.fetch(new Request(url), {}, { waitUntil() {} });
                hops.push(res.status + ' ' + url);
                const to = res.headers.get('location');
                if (!to || to === LATEST || !to.startsWith(SITE + '/')) break;
                url = to;
            }
        } catch (e) { hops.push(String(e)); }
        const last = hops[hops.length - 1] || '';
        const end = res && res.headers.get('location');
        if (address.endsWith('.dmg')) {
            check('published: ' + address + ' goes to the newest release', res && res.status === 302 && end === LATEST, hops);
        } else {
            // Moved for good, never for now: a 302 would leave the old address
            // as the one search engines keep.
            const permanent = hops.slice(0, -1).every(h => /^30[18] /.test(h));
            check('published: ' + address + ' serves the page', last.startsWith('200 ') && permanent, hops);
        }
    }

    fs.rmSync(tmp, { recursive: true });
    console.log(failed ? `${failed} failed` : 'all passed');
    process.exitCode = failed ? 1 : 0;
})().catch(e => { console.error(e); process.exitCode = 1; });
