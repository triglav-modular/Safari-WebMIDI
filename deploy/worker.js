// The Cloudflare worker behind triglavmodular.hu/mods/safari-webmidi.
//
// Deployed with `npx wrangler deploy` from the repository root; wrangler.toml
// there carries the name, the route and the COUNTS namespace.  It maps the
// public path onto the GitHub Pages site, as the 218e Rewired worker does for
// its page, sets the cache headers Pages cannot, and counts downloads.
const PUBLIC = '/mods/safari-webmidi';
const ORIGIN = 'https://triglav-modular.github.io/Safari-WebMIDI';
const RELEASES = 'https://github.com/triglav-modular/Safari-WebMIDI/releases';
// The disk image is a GitHub release asset, not a file of the site.  The
// page's Download comes here, to be counted, and goes on to the newest
// release's.
const DOWNLOAD = RELEASES + '/latest/download/Web-MIDI.dmg';

// Forwarded to the origin.  Host is deliberately absent: GitHub Pages routes
// on it.  The conditional headers turn a revalidation into a 304, and
// if-range keeps a resumed download from splicing two versions together.
const FORWARD = ['if-none-match', 'if-modified-since', 'accept', 'accept-encoding',
                 'user-agent', 'range', 'if-range'];

// One download, written as one key in COUNTS: the day, and in the metadata
// the version the newest release was at the time.  Nothing of the request
// itself is kept (no address, no user agent, no header), so nothing written
// can later be joined to a person.  One key per download rather than a
// counter: KV has no atomic increment, so two downloads at once would read
// the same number and write it back once.  The metadata comes back with
// `list`, so a thousand downloads cost one read.  No expiry: the count is the
// point.
async function count(env) {
  let version = '';
  try {
    // The release page, not the asset: GitHub counts a fetch of the asset as
    // a download of its own.
    const res = await fetch(RELEASES + '/latest', { redirect: 'manual', signal: AbortSignal.timeout(5000) });
    const tag = /\/releases\/tag\/v([0-9]{1,3}(?:\.[0-9]{1,3}){0,2})$/.exec(res.headers.get('location') || '');
    if (tag) version = tag[1];
  } catch (e) {}
  const day = new Date().toISOString().slice(0, 10);
  await env.COUNTS.put(`dl:${day}:${crypto.randomUUID()}`, '', { metadata: { version } });
}

export default {
  async fetch(request, env, context) {
    const url = new URL(request.url);

    // Without the trailing slash every relative asset resolves into /mods/.
    if (url.pathname === PUBLIC) {
      return Response.redirect(url.origin + PUBLIC + '/', 301);
    }
    const rest = url.pathname.slice(PUBLIC.length);
    // The route matches PUBLIC followed by anything, so "/mods/safari-webmidix"
    // arrives here too; passed on, it would ask Pages for a sibling project.
    if (!rest.startsWith('/')) {
      return new Response('Not found', { status: 404, headers: { 'cache-control': 'no-store' } });
    }
    // Not kept: "latest" moves with each release.
    if (rest === '/Web-MIDI.dmg') {
      // Counted when a browser went there as a page does, by a click, a link
      // from elsewhere or a typed address: Sec-Fetch-Mode navigate and
      // Sec-Fetch-Dest document.  Not Sec-Fetch-User, which says the person
      // did it: Safari does not send it, even for a trusted click (Safari 27,
      // 2026-09-27), and would never be counted.  Crawlers, link previews
      // and curl send none of these, and a prefetch says so in Sec-Purpose,
      // so what is counted is a floor.  Asked after the method, not the
      // name: a binding misconfigured as a text variable is no namespace, and
      // counts nothing.  The download never waits on the count and never
      // fails with it.
      const h = request.headers;
      if (request.method === 'GET' && h.get('sec-fetch-mode') === 'navigate'
          && h.get('sec-fetch-dest') === 'document' && !h.has('sec-purpose') && !h.has('purpose')
          && env && env.COUNTS && typeof env.COUNTS.put === 'function') {
        context.waitUntil(count(env).catch(() => {}));
      }
      return new Response(null, { status: 302, headers: { location: DOWNLOAD, 'cache-control': 'no-store' } });
    }

    const headers = new Headers();
    for (const name of FORWARD) {
      const value = request.headers.get(name);
      if (value) headers.set(name, value);
    }
    // Not through Cloudflare's cache: it kept GitHub Pages' ten minutes on a
    // subrequest, so a pushed stylesheet went out with the old one for up to
    // ten minutes after the page itself had changed.  Browsers still keep
    // everything and revalidate it (no-cache, below), which costs a 304.
    const res = await fetch(ORIGIN + rest + url.search,
                            { method: request.method, headers, redirect: 'follow', cache: 'no-store' });
    const out = new Response(res.status === 304 ? null : res.body, res);
    out.headers.set('x-served-by', 'safari-webmidi-proxy');
    if (!(res.ok || res.status === 304)) {
      // The origin dresses every 404 as a page; a failure is never kept.
      out.headers.set('cache-control', 'no-store');
    } else {
      // The page keeps its name across versions, so it is revalidated each
      // time: an unchanged file costs a 304, and a new version is never
      // hidden behind a cached old one.
      out.headers.set('cache-control', 'no-cache');
    }
    return out;
  }
};
