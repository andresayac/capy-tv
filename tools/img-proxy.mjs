// A picture proxy for the web build, to run by hand while developing. It serves the built app too,
// so one tunnel (or one port) covers both the page and the pictures, which keeps them on the same
// origin and out of mixed content.
//
//   node tools/img-proxy.mjs        # http://127.0.0.1:8093/       the app (app/build/web)
//                                   # http://127.0.0.1:8093/i?u=… the pictures
//   PORT=8094 node tools/img-proxy.mjs
//   HOST=0.0.0.0 node tools/img-proxy.mjs    # so a tunnel or a phone can reach it
//
// A browser refuses to read an image from a server that does not allow it (CORS), and IPTV panels'
// picture hosts very often do not. This fetches the image server-side, where no such rule applies,
// and sends it on with the headers the page needs. Open the app with:
//
//   http://127.0.0.1:8093/?imgproxy=/i
//
// Through a tunnel, the same single port carries the page and the pictures, so they share an
// origin and nothing on the page is plain http under https:
//
//   devtunnel port create -p 8093 && devtunnel host -p 8093    (public: `devtunnel access create`)
//   https://<tunnel>/?imgproxy=/i
//
// It is a development aid, not part of the app: it holds a little in memory and forgets it, and it
// will fetch any address it is given, so do not expose it beyond this machine.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const PORT = Number(process.env.PORT ?? 8093);
const HOST = process.env.HOST ?? '127.0.0.1';

/** The built app to serve at /, or none when it is not there. */
const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'app', 'build', 'web');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff2': 'font/woff2',
  '.mjs': 'text/javascript; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
};

/** The most an image may weigh, and how many are kept. */
const MAX_BYTES = 12 << 20;
const MAX_CACHED = 400;

/** How long to wait for the picture's (or the stream's) host. */
const TIMEOUT_MS = 15000;

/** Some hosts answer 403 to anything that does not look like a browser. */
const BROWSER_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/** address → { body, type, at }, the oldest first when full. */
const cache = new Map();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
  'Access-Control-Allow-Headers': '*',
  'Access-Control-Max-Age': '86400',
};

function send(res, status, body, headers = {}, headOnly = false) {
  res.writeHead(status, { ...CORS, ...headers });
  if (headOnly) return res.end();
  res.end(body);
}

function put(url, entry) {
  if (cache.size >= MAX_CACHED) cache.delete(cache.keys().next().value);
  cache.set(url, { ...entry, at: Date.now() });
}

async function fetchImage(url) {
  const known = cache.get(url);
  if (known) {
    // Refreshed in place: the newest, so it is not what goes first
    cache.delete(url);
    cache.set(url, known);
    return known;
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      signal: controller.signal,
      redirect: 'follow',
      headers: {
        // Some hosts answer 403 to anything that does not look like a browser
        'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        Accept: 'image/avif,image/webp,image/*,*/*;q=0.8',
      },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const length = Number(res.headers.get('content-length') ?? 0);
    if (length > MAX_BYTES) throw new Error(`too big: ${length}`);
    const body = Buffer.from(await res.arrayBuffer());
    if (body.length === 0) throw new Error('empty');
    if (body.length > MAX_BYTES) throw new Error(`too big: ${body.length}`);
    const entry = {
      body,
      type: res.headers.get('content-type') ?? 'image/jpeg',
    };
    put(url, entry);
    return entry;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Streams a media file through, with CORS and Range, which is what a browser player needs to read
 * a file it wants to demux itself (movi-player does, to offer the stream's audio languages).
 *
 *   /v?u=<encoded media url>
 *
 * A panel's stream usually redirects to a node of its own that allows no other origin; here the
 * fetch is server-side, where that rule does not apply, and the answer is passed on with the
 * headers the page needs. Range requests go through as they come, so seeking and a player's
 * piece-by-piece reading work.
 */
async function proxyVideo(req, res, target) {
  const headers = { 'User-Agent': BROWSER_UA, Accept: '*/*' };
  // The player asks for pieces; passing its Range along is what lets it start before the end
  if (req.headers.range) headers.Range = req.headers.range;

  const controller = new AbortController();
  // Only until the first byte: a live stream would hold this open forever
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  let upstream;
  try {
    upstream = await fetch(target, { headers, redirect: 'follow', signal: controller.signal });
  } catch (e) {
    clearTimeout(timer);
    const why = e instanceof Error ? e.message : String(e);
    console.log(`FAIL video ${why}  ${target.slice(0, 90)}`);
    return send(res, 502, `Could not fetch: ${why}`, { 'Content-Type': 'text/plain' }, req.method === 'HEAD');
  }
  clearTimeout(timer);

  if (!upstream.ok && upstream.status !== 206) {
    console.log(`FAIL video HTTP ${upstream.status}  ${target.slice(0, 90)}`);
    return send(res, upstream.status, `Upstream said ${upstream.status}`, { 'Content-Type': 'text/plain' });
  }

  const out = {
    ...CORS,
    'Content-Type': upstream.headers.get('content-type') ?? 'application/octet-stream',
    // A player reads these to know how to cut the file up
    'Accept-Ranges': upstream.headers.get('accept-ranges') ?? 'bytes',
  };
  for (const name of ['content-length', 'content-range']) {
    const value = upstream.headers.get(name);
    if (value) out[name.replace(/(^|-)([a-z])/g, (m) => m.toUpperCase())] = value;
  }
  res.writeHead(upstream.status, out);
  if (req.method === 'HEAD') {
    upstream.body?.cancel().catch(() => {});
    return res.end();
  }

  // Piped as it arrives: a 500 MB episode is never held whole in memory
  let sent = 0;
  try {
    for await (const piece of upstream.body) {
      sent += piece.length;
      if (!res.write(piece)) await new Promise((r) => res.once('drain', r));
    }
  } catch (e) {
    // The player closed the tab, or the panel cut the stream: nothing left to say
  } finally {
    res.end();
    console.log(`OK   ${sent} B  ${req.headers.range ? `range ${req.headers.range} ` : ''}${target.slice(0, 80)}`);
  }
}

/** Serves the built app: a file under WEB, or its index.html for any path (Flutter routes itself). */
function serveApp(req, res, pathname, head) {
  let file = path.join(WEB, decodeURIComponent(pathname));
  // Nothing may climb out of the build directory
  if (!file.startsWith(WEB)) return send(res, 403, 'Forbidden', { 'Content-Type': 'text/plain' }, head);

  const statOr = (p) => {
    try {
      return fs.statSync(p);
    } catch {
      return null;
    }
  };

  let about = statOr(file);
  // A folder ("/" among them) is its index.html
  if (about?.isDirectory()) {
    file = path.join(file, 'index.html');
    about = statOr(file);
  }
  // Anything else that is not there is a route: Flutter's page, which routes itself
  if (!about?.isFile()) {
    file = path.join(WEB, 'index.html');
    about = statOr(file);
    if (!about?.isFile()) {
      return send(
        res,
        503,
        `No built app at ${WEB}. Build it first: cd app && flutter build web`,
        { 'Content-Type': 'text/plain; charset=utf-8' },
        head,
      );
    }
  }

  // A service worker or a stale main.dart.js is the usual "it stays loading" after a rebuild; the
  // app's code keeps its name from build to build (main.dart.js, movi/capy-movi.js), so kept for a
  // day the browser would go on running the last one
  const noChache = /flutter_service_worker|index\.html|flutter_bootstrap|main\.dart\.(js|mjs|wasm)|capy-movi\.js/.test(file);
  res.writeHead(200, {
    ...CORS,
    'Content-Type': MIME[path.extname(file)] ?? 'application/octet-stream',
    'Content-Length': String(about.size),
    'Cache-Control': noChache ? 'no-cache' : 'public, max-age=86400',
  });
  if (head) return res.end();
  fs.createReadStream(file).pipe(res);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const head = req.method === 'HEAD';
  if (req.method === 'OPTIONS') return send(res, 204, '', {}, true);

  // /v?u= : a media file streamed through (see proxyVideo)
  if (url.pathname === '/v') {
    const media = url.searchParams.get('u');
    if (!media) return send(res, 400, 'Missing ?u=', { 'Content-Type': 'text/plain' });
    if (!/^https?:\/\//i.test(media)) {
      return send(res, 400, 'Only http and https', { 'Content-Type': 'text/plain' });
    }
    return proxyVideo(req, res, media);
  }

  if (url.pathname !== '/i') {
    // The app itself, and everything it loads
    return serveApp(req, res, url.pathname, head);
  }

  const target = url.searchParams.get('u');
  if (!target) return send(res, 400, 'Missing ?u=', { 'Content-Type': 'text/plain' });
  if (!/^https?:\/\//i.test(target)) {
    return send(res, 400, 'Only http and https', { 'Content-Type': 'text/plain' });
  }

  try {
    const { body, type } = await fetchImage(target);
    send(
      res,
      200,
      body,
      {
        'Content-Type': type,
        'Content-Length': String(body.length),
        'Cache-Control': 'public, max-age=86400',
      },
      head,
    );
    if (!head) console.log(`OK   ${body.length} B  ${target.slice(0, 90)}`);
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    console.log(`FAIL ${why}  ${target.slice(0, 90)}`);
    send(res, 502, `Could not fetch: ${why}`, { 'Content-Type': 'text/plain' }, head);
  }
});

server.listen(PORT, HOST === '0.0.0.0' ? '0.0.0.0' : HOST, () => {
  const at = `http://${HOST === '0.0.0.0' ? '127.0.0.1' : HOST}:${PORT}`;
  console.log(`App and picture proxy: ${at}/?imgproxy=/i`);
  console.log(`Pictures alone:        ${at}/i?u=<encoded image url>`);
  console.log(`Serving the build at:  ${WEB}`);
});
