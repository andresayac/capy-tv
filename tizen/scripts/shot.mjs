// Screenshots of the app as the TV shows it (1920x1080), in this machine's Edge, for looking at
// screens without the TV at hand. Web security is off so it can reach providers as the TV does.
//
//   node scripts/shot.mjs <out.png> [--seed[=n]] [--keys=down,down,enter] [--wait=ms] [--each] [--eval=js]
//
// --seed puts the .env's provider n (default: unnumbered) in the playlists first; --keys presses
// remote keys in turn (left right up down enter back, or a keyCode); --each saves a shot per key;
// --eval prints what an expression gives at the end; a key "type:text" types into the field
// being edited, and "focus:text" puts the focus on the visible element with that text.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const WWW = path.join(ROOT, 'build', 'www');
const args = Object.fromEntries(
  process.argv.slice(3).map((a) => {
    const [k, ...v] = a.replace(/^--/, '').split('=');
    return [k, v.join('=')];
  }),
);
const out = process.argv[2];
if (!out) throw new Error('usage: node scripts/shot.mjs <out.png> [--seed[=n]] [--keys=a,b] [--wait=ms] [--each]');

const KEYS = { left: 37, up: 38, right: 39, down: 40, enter: 13, back: 27 };
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.ttf': 'font/ttf', '.png': 'image/png', '.svg': 'image/svg+xml', '.map': 'application/json' };

function serve() {
  const server = http.createServer((req, res) => {
    const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const file = path.join(WWW, rel === '/' ? 'index.html' : rel);
    if (!file.startsWith(WWW) || !fs.existsSync(file)) {
      res.writeHead(404);
      return res.end();
    }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] ?? 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((ok) => server.listen(0, '127.0.0.1', () => ok(server)));
}

function provider(n) {
  const env = {};
  for (const line of fs.readFileSync(path.join(ROOT, '..', '.env'), 'utf8').split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (m) env[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2');
  }
  const s = n ? `_${n}` : '';
  return { server: env[`XTREAM_CODE${s}`], username: env[`XTREAM_USERNAME${s}`], password: env[`XTREAM_PASSWORD${s}`] };
}

const server = await serve();
// A throwaway profile: web security can only be turned off in one of its own
const browser = await chromium.launchPersistentContext(fs.mkdtempSync(path.join(os.tmpdir(), 'capytv-shot-')), {
  channel: 'msedge',
  args: ['--disable-web-security'],
  viewport: { width: 1920, height: 1080 },
  locale: 'es-ES',
});
try {
  const page = browser.pages()[0] ?? (await browser.newPage());
  page.on('pageerror', (e) => console.log('page error:', e.message));
  const url = `http://127.0.0.1:${server.address().port}/`;
  if ('seed' in args) {
    const p = provider(args.seed);
    await page.goto(url);
    await page.evaluate((p) => {
      const playlist = { id: 'seed0000000000000000000000000001', name: 'Proveedor', type: 'xtream', url: p.server, username: p.username, password: p.password, members: [] };
      localStorage.setItem('playlists', JSON.stringify([playlist]));
    }, p);
  }
  await page.goto(url);
  // Windows' text scaling (Accessibility > Text size) reaches the stylesheet's root font size in
  // Edge, and with it every rem; the TV has none. An inline size escapes it
  await page.evaluate(() => {
    document.documentElement.style.fontSize = '20px';
  });
  await page.waitForTimeout(800);
  const wait = Number(args.wait || 600);
  const keys = (args.keys || '').split(',').filter(Boolean);
  const shot = async (file) => {
    await page.screenshot({ path: file });
    console.log('saved', file);
  };
  for (const [i, k] of keys.entries()) {
    if (k.startsWith('focus:')) {
      await page.evaluate((text) => {
        const all = Array.from(document.querySelectorAll('.screen:not(.hidden) .f'));
        const el = all.find((e) => e.getAttribute('aria-label') === text || e.innerText.trim().split(/\n/)[0].trim() === text);
        if (el) el.focus();
      }, k.slice(6));
      await page.waitForTimeout(200);
      continue;
    }
    if (k.startsWith('type:')) {
      await page.keyboard.type(k.slice(5), { delay: 40 });
      await page.waitForTimeout(wait);
      continue;
    }
    const code = KEYS[k] ?? Number(k);
    await page.evaluate((code) => {
      const e = new KeyboardEvent('keydown', { bubbles: true });
      Object.defineProperty(e, 'keyCode', { get: () => code });
      document.dispatchEvent(e);
    }, code);
    await page.waitForTimeout(wait);
    if ('each' in args) await shot(out.replace(/\.png$/, `-${i + 1}.png`));
  }
  await page.waitForTimeout(400);
  await shot(out);
  if (args.eval) console.log(await page.evaluate(args.eval));
} finally {
  await browser.close();
  server.close();
}
