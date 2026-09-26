// The Cloudflare worker behind triglavmodular.hu/mods/safari-webmidi.
//
// Deployed with `npx wrangler deploy` from the repository root; wrangler.toml
// there carries the name and the route.  It maps the public path onto the
// GitHub Pages site, as the 218e Rewired worker does for its page, and sets
// the cache headers Pages cannot.  It counts nothing.
const PUBLIC = '/mods/safari-webmidi';
const ORIGIN = 'https://triglav-modular.github.io/Safari-WebMIDI';

// Forwarded to the origin.  Host is deliberately absent: GitHub Pages routes
// on it.  The conditional headers turn a revalidation into a 304, and
// if-range keeps a resumed download from splicing two versions together.
const FORWARD = ['if-none-match', 'if-modified-since', 'accept', 'accept-encoding',
                 'user-agent', 'range', 'if-range'];

export default {
  async fetch(request) {
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

    const headers = new Headers();
    for (const name of FORWARD) {
      const value = request.headers.get(name);
      if (value) headers.set(name, value);
    }
    const res = await fetch(ORIGIN + rest + url.search, { method: request.method, headers, redirect: 'follow' });
    const out = new Response(res.status === 304 ? null : res.body, res);
    out.headers.set('x-served-by', 'safari-webmidi-proxy');
    if (!(res.ok || res.status === 304)) {
      // The origin dresses every 404 as a page; a failure is never kept.
      out.headers.set('cache-control', 'no-store');
    } else {
      // The page and the download keep their names across versions, so both
      // are revalidated each time: an unchanged file costs a 304, and a new
      // version is never hidden behind a cached old one.
      out.headers.set('cache-control', 'no-cache');
    }
    return out;
  }
};
