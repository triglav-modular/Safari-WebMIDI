// The Cloudflare worker behind triglavmodular.hu/mods/safari-webmidi.
//
// Deployed with `npx wrangler deploy` from the repository root; wrangler.toml
// there carries the name and the route.  It maps the public path onto the
// GitHub Pages site, as the 218e Rewired worker does for its page, and sets
// the cache headers Pages cannot.  It counts nothing.
const PUBLIC = '/mods/safari-webmidi';
const ORIGIN = 'https://triglav-modular.github.io/Safari-WebMIDI';
// The disk image is a GitHub release asset, not a file of the site; its old
// address here sends the newest release's.
const DOWNLOAD = 'https://github.com/triglav-modular/Safari-WebMIDI/releases/latest/download/Web-MIDI.dmg';

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
    // Not kept: "latest" moves with each release.
    if (rest === '/Web-MIDI.dmg') {
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
