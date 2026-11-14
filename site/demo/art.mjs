// Draws the demo catalog's artwork: posters (kept with the site, whose hero uses them), backdrops
// and channel logos (only for the demo provider). Needs Microsoft Edge and, for the poster fonts,
// a connection to Google Fonts.
//
//   npm run demo:art
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';
import { channels, movies, palettes, shows } from './catalog.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const POSTERS = path.join(HERE, '..', 'src', 'assets', 'posters');
const BACKDROPS = path.join(HERE, 'art', 'backdrops');
const LOGOS = path.join(HERE, 'art', 'logos');
for (const dir of [POSTERS, BACKDROPS, LOGOS]) fs.mkdirSync(dir, { recursive: true });

const FONTS = {
  anton: "'Anton'",
  abril: "'Abril Fatface'",
  archivo: "'Archivo Black'",
  bebas: "'Bebas Neue'",
  dmserif: "'DM Serif Display'",
  playfair: "'Playfair Display'",
  righteous: "'Righteous'",
  bungee: "'Bungee'",
  syne: "'Syne'",
};
const FONT_CSS =
  'https://fonts.googleapis.com/css2?family=Anton&family=Abril+Fatface&family=Archivo+Black&family=Bebas+Neue' +
  '&family=DM+Serif+Display&family=Playfair+Display:wght@800&family=Righteous&family=Bungee&family=Syne:wght@800&display=block';

function seeded(text) {
  let h = 2166136261;
  for (const c of text) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
  return () => {
    h += 0x6d2b79f5;
    let t = h;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const rect = (x, y, w, h, fill, extra = '') => `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${fill}" ${extra}/>`;
const circle = (x, y, r, fill, extra = '') => `<circle cx="${x}" cy="${y}" r="${r}" fill="${fill}" ${extra}/>`;

const capyFace = `
  <path d="M32 65c-3-15 7-24 20-18 15-9 38-9 53-1 14-7 25 3 21 18 8 12 10 27 6 42-4 21-23 32-54 32s-50-11-54-32c-4-15-1-29 8-41Z" fill="#D6A16F"/>
  <path d="M44 77q8 8 16 0m37 0q8 8 16 0" fill="none" stroke="#283A31" stroke-width="5" stroke-linecap="round"/>
  <ellipse cx="78" cy="101" rx="31" ry="21" fill="#EFCAA3"/>
  <ellipse cx="78" cy="94" rx="7" ry="5" fill="#283A31"/>
  <path d="M69 105q9 8 18 0" fill="none" stroke="#815B43" stroke-width="3" stroke-linecap="round"/>`;

// Each draws a W x H scene with a palette p and a seeded random r
const MOTIFS = {
  sun(W, H, p, r) {
    const cx = W * (0.35 + 0.3 * r());
    const horizon = H * 0.72;
    const R = Math.min(W, H) * 0.38;
    let s = rect(0, 0, W, H, p.bg) + circle(cx, horizon - R * 0.2, R, p.a);
    for (let i = 0; i < 6; i++) s += rect(0, horizon - R * 0.5 + i * R * 0.17, W, 3 + i * 3, p.bg);
    return s + rect(0, horizon, W, H - horizon, p.c);
  },
  hills(W, H, p, r) {
    let s = rect(0, 0, W, H, p.bg) + circle(W * (0.6 + r() * 0.2), H * 0.26, Math.min(W, H) * 0.13, p.b);
    const fills = [p.c, p.a, p.c, p.a];
    for (let l = 0; l < 4; l++) {
      const base = H * (0.46 + l * 0.14);
      const amp = H * (0.08 - l * 0.012);
      const f = 1.5 + r() * 2;
      const shift = r() * 6;
      let d = `M0 ${H}`;
      for (let x = 0; x <= W; x += W / 40) d += `L${x} ${base + Math.sin((x / W) * f * 3.14 + shift) * amp}`;
      s += `<path d="${d}L${W} ${H}Z" fill="${fills[l]}" opacity="${0.75 + l * 0.08}"/>`;
    }
    return s;
  },
  burst(W, H, p, r) {
    const cx = W * 0.5;
    const cy = H * (0.6 + r() * 0.15);
    const D = Math.hypot(W, H);
    let s = rect(0, 0, W, H, p.bg);
    for (let i = 0; i < 18; i++) {
      const a = (i / 18) * Math.PI * 2;
      const b = ((i + 0.5) / 18) * Math.PI * 2;
      s += `<path d="M${cx} ${cy}L${cx + Math.cos(a) * D} ${cy + Math.sin(a) * D}L${cx + Math.cos(b) * D} ${cy + Math.sin(b) * D}Z" fill="${p.a}"/>`;
    }
    return s + circle(cx, cy, Math.min(W, H) * 0.2, p.b) + circle(cx, cy, Math.min(W, H) * 0.09, p.c);
  },
  rings(W, H, p, r) {
    const cx = W * (0.3 + r() * 0.4);
    const cy = H * (0.35 + r() * 0.3);
    const step = Math.min(W, H) * 0.1;
    let s = rect(0, 0, W, H, p.bg);
    for (let i = 9; i >= 1; i--) s += circle(cx, cy, step * i, i % 2 ? p.a : p.c);
    return s + circle(cx, cy, step * 0.55, p.b);
  },
  bars(W, H, p, r) {
    let s = rect(0, 0, W, H, p.bg);
    const fills = [p.a, p.b, p.c];
    const n = 7;
    const w = (W + H) / n;
    for (let i = 0; i < n; i++) {
      if (r() < 0.2) continue;
      const x = i * w - H * 0.5;
      s += `<path d="M${x} ${H}L${x + H * 0.7} 0L${x + H * 0.7 + w * 0.62} 0L${x + w * 0.62} ${H}Z" fill="${fills[i % 3]}"/>`;
    }
    return s;
  },
  skyline(W, H, p, r) {
    let s = rect(0, 0, W, H, p.bg) + circle(W * 0.72, H * 0.24, Math.min(W, H) * 0.12, p.b);
    for (const [fill, base, lit] of [[p.c, 0.34, 0.3], [p.a, 0.5, 0.45]]) {
      for (let x = -10; x < W; ) {
        const w = W * (0.09 + r() * 0.1);
        const y = H * (base + r() * 0.25);
        s += rect(x, y, w, H - y, fill);
        for (let wy = y + 14; wy < H - 10; wy += 22) {
          for (let wx = x + 9; wx < x + w - 12; wx += 18) if (r() < lit) s += rect(wx, wy, 8, 12, p.b);
        }
        x += w + 3;
      }
    }
    return s;
  },
  waves(W, H, p, r) {
    let s = rect(0, 0, W, H, p.bg) + circle(W * (0.25 + r() * 0.5), H * 0.27, Math.min(W, H) * 0.16, p.b);
    const fills = [p.c, p.a];
    for (let l = 0; l < 7; l++) {
      const base = H * (0.42 + l * 0.085);
      const amp = H * 0.028;
      const phase = r() * 6;
      let d = `M0 ${H}`;
      for (let x = 0; x <= W; x += W / 60) d += `L${x} ${base + Math.sin((x / W) * 14 + phase) * amp}`;
      s += `<path d="${d}L${W} ${H}Z" fill="${fills[l % 2]}"/>`;
    }
    return s;
  },
  eye(W, H, p) {
    const cx = W / 2;
    const cy = H * 0.5;
    const a = Math.min(W * 0.46, H * 0.62);
    const b = a * 0.52;
    let s = rect(0, 0, W, H, p.bg);
    for (let i = -6; i <= 6; i++) {
      const t = (i / 6) * 0.9;
      s += `<line x1="${cx + a * 1.02 * t}" y1="${cy - b * (1 - t * t) - 8}" x2="${cx + a * 1.32 * t}" y2="${cy - b * 1.75 * (1 - t * t) - 18}" stroke="${p.a}" stroke-width="6" stroke-linecap="round"/>`;
    }
    s += `<path d="M${cx - a} ${cy}Q${cx} ${cy - b * 2} ${cx + a} ${cy}Q${cx} ${cy + b * 2} ${cx - a} ${cy}Z" fill="${p.b}"/>`;
    return s + circle(cx, cy, b * 0.86, p.a) + circle(cx, cy, b * 0.42, p.bg) + circle(cx + b * 0.2, cy - b * 0.2, b * 0.12, p.b);
  },
  figure(W, H, p, r) {
    const cx = W * (0.4 + r() * 0.2);
    const ground = H * 0.78;
    let s = rect(0, 0, W, H, p.bg) + circle(cx, ground - H * 0.14, Math.min(W, H) * 0.4, p.a) + rect(0, ground, W, H - ground, p.c);
    const u = Math.min(W, H) * 0.028;
    s += `<path d="M${cx - u} ${ground}L${cx + u * 2} ${ground}L${cx + W * 0.34} ${H}L${cx + W * 0.1} ${H}Z" fill="${p.bg}" opacity=".55"/>`;
    return s + circle(cx, ground - u * 6.4, u * 1.1, p.ink) + `<path d="M${cx - u * 1.3} ${ground - u * 5}h${u * 2.6}l${u * 0.5} ${u * 5}h-${u * 3.6}Z" fill="${p.ink}"/>`;
  },
  door(W, H, p) {
    let s = rect(0, 0, W, H, p.bg);
    const n = 6;
    for (let i = 0; i < n; i++) {
      const k = 1 - i * 0.135;
      const w = W * 0.86 * k * (W > H ? 0.55 : 1);
      const h = H * 0.9 * k;
      s += rect((W - w) / 2, H - h, w, h, i % 2 ? p.c : p.a);
    }
    const w = W * 0.2 * (W > H ? 0.55 : 1);
    const h = H * 0.38;
    return s + rect((W - w) / 2, H - h, w, h, p.b) + circle((W + w) / 2 - 12, H - h / 2, 6, p.bg);
  },
  road(W, H, p, r) {
    const horizon = H * 0.46;
    const vx = W * (0.42 + r() * 0.16);
    let s = rect(0, 0, W, horizon, p.bg) + circle(vx, horizon, Math.min(W, H) * 0.24, p.a) + rect(0, horizon, W, H - horizon, p.c);
    s += `<path d="M${vx - 4} ${horizon}L${vx + 4} ${horizon}L${W * 0.86} ${H}L${W * 0.14} ${H}Z" fill="${p.b}"/>`;
    for (let i = 0; i < 6; i++) {
      const t = (i + 0.4) / 6;
      const y = horizon + (H - horizon) * t * t;
      const h = 6 + 44 * t * t;
      const w = 1.5 + 8 * t;
      s += rect(vx + (W * 0.5 - vx) * t - w, y, w * 2, h, p.a);
    }
    return s;
  },
  planet(W, H, p, r) {
    let s = rect(0, 0, W, H, p.bg);
    for (let i = 0; i < 70; i++) s += circle(r() * W, r() * H, 0.8 + r() * 1.8, p.b, `opacity="${0.4 + r() * 0.6}"`);
    const cx = W * (0.42 + r() * 0.16);
    const cy = H * 0.5;
    const R = Math.min(W, H) * 0.27;
    const tilt = -18 - r() * 16;
    s += `<g transform="rotate(${tilt} ${cx} ${cy})"><ellipse cx="${cx}" cy="${cy}" rx="${R * 1.85}" ry="${R * 0.46}" fill="none" stroke="${p.c}" stroke-width="${R * 0.15}"/></g>`;
    s += circle(cx, cy, R, p.a);
    s += `<g transform="rotate(${tilt} ${cx} ${cy})"><path d="M${cx - R * 1.85} ${cy}A${R * 1.85} ${R * 0.46} 0 0 0 ${cx + R * 1.85} ${cy}" fill="none" stroke="${p.b}" stroke-width="${R * 0.15}"/></g>`;
    return s + circle(cx + R * 1.65, cy - R * 1.35, R * 0.15, p.b);
  },
  bloom(W, H, p, r) {
    const cx = W / 2;
    const cy = H * 0.5;
    const L = Math.min(W, H) * 0.4;
    let s = rect(0, 0, W, H, p.bg);
    for (let i = 0; i < 180; i++) s += rect(r() * W, r() * H, 3, 3, p.c, 'opacity=".55"');
    for (const [n, scale, fill] of [[14, 1, p.c], [12, 0.82, p.a], [10, 0.56, p.b]]) {
      for (let i = 0; i < n; i++) {
        s += `<ellipse cx="${cx}" cy="${cy - L * 0.56 * scale}" rx="${L * 0.15 * scale}" ry="${L * 0.5 * scale}" fill="${fill}" transform="rotate(${(i * 360) / n} ${cx} ${cy})"/>`;
      }
    }
    return s + circle(cx, cy, L * 0.15, p.bg);
  },
  boat(W, H, p, r) {
    const cx = W * (0.42 + r() * 0.16);
    const y = H * 0.62;
    const u = Math.min(W, H) * 0.2;
    let s = rect(0, 0, W, H, p.bg) + circle(W * 0.74, H * 0.2, Math.min(W, H) * 0.1, p.a);
    s += `<path d="M${cx - u * 1.5} ${y}L${cx + u * 1.5} ${y}L${cx + u} ${y + u * 0.7}L${cx - u} ${y + u * 0.7}Z" fill="${p.b}"/>`;
    s += `<path d="M${cx} ${y - u * 1.5}L${cx} ${y}L${cx + u * 1.05} ${y}Z" fill="${p.a}"/><path d="M${cx} ${y - u * 1.5}L${cx} ${y}L${cx - u * 1.05} ${y}Z" fill="${p.c}"/>`;
    for (let l = 0; l < 4; l++) {
      const base = H * (0.72 + l * 0.08);
      let d = `M0 ${H}`;
      for (let x = 0; x <= W; x += W / 60) d += `L${x} ${base + Math.sin((x / W) * 16 + l * 2) * H * 0.016}`;
      s += `<path d="${d}L${W} ${H}Z" fill="${l % 2 ? p.c : p.b}"/>`;
    }
    return s;
  },
  rain(W, H, p, r) {
    let s = rect(0, 0, W, H, p.bg);
    const cols = W > H ? 7 : 3;
    const rows = 3;
    const gap = Math.min(W, H) * 0.035;
    const w = (W - gap * (cols + 1)) / cols;
    const h = (H - gap * (rows + 1)) / rows;
    const lit = Math.floor(r() * cols * rows);
    for (let y = 0; y < rows; y++) {
      for (let x = 0; x < cols; x++) s += rect(gap + x * (w + gap), gap + y * (h + gap), w, h, x + y * cols === lit ? p.b : p.c);
    }
    for (let i = 0; i < 90; i++) {
      const x = r() * W;
      const y = r() * H;
      const l = 20 + r() * 34;
      s += `<line x1="${x}" y1="${y}" x2="${x - l * 0.3}" y2="${y + l}" stroke="${p.a}" stroke-width="2.4"/>`;
    }
    return s;
  },
  capy(W, H, p, r) {
    const scale = (Math.min(W, H) * 0.82) / 156;
    let s = rect(0, 0, W, H, p.bg) + circle(W / 2, H * 0.5, Math.min(W, H) * 0.42, p.a);
    for (let i = 0; i < 14; i++) s += circle(r() * W, r() * H * 0.9, 8 + r() * 14, p.c, 'opacity=".6"');
    return s + `<g transform="translate(${W / 2 - 78 * scale} ${H * 0.5 - 90 * scale}) scale(${scale})">${capyFace}</g>`;
  },
  capyspace(W, H, p, r) {
    const R = Math.min(W, H);
    const scale = (R * 0.6) / 156;
    return MOTIFS.planet(W, H, { ...p, a: p.c }, r) +
      `<g transform="translate(${W / 2 - 78 * scale} ${H * 0.52 - 92 * scale}) scale(${scale})">${capyFace}</g>`;
  },
};

const pageFor = (width, height, body) => `<!doctype html><html><head><link rel="stylesheet" href="${FONT_CSS}">
<style>html,body{margin:0;background:transparent}#a{position:relative;overflow:hidden;width:${width}px;height:${height}px}
svg{position:absolute;display:block}.t{position:absolute;display:flex;box-sizing:border-box;padding:0 30px;line-height:1}
.t span{display:block;text-wrap:balance}</style></head><body><div id="a">${body}</div></body></html>`;

function poster(item) {
  const W = 500;
  const H = 750;
  const p = palettes[item.palette];
  const r = seeded(item.title);
  const bandAtTop = r() < 0.3;
  const band = 232;
  const scene = H - band;
  const centered = ['bungee', 'righteous', 'bebas', 'anton'].includes(item.font);
  const svg = `<svg style="left:0;top:${bandAtTop ? band : 0}px" width="${W}" height="${scene}" viewBox="0 0 ${W} ${scene}">${MOTIFS[item.motif](W, scene, p, r)}</svg>`;
  const justify = centered ? 'justify-content:center;text-align:center' : 'justify-content:flex-start;text-align:left';
  const text = `<div class="t" id="t" style="left:0;top:${bandAtTop ? 0 : scene}px;width:${W}px;height:${band}px;background:${p.bg};color:${p.ink};align-items:center;${justify};font-family:${FONTS[item.font]};font-weight:800"><span id="s">${item.title}</span></div>`;
  return pageFor(W, H, svg + text);
}

const backdrop = (item) =>
  pageFor(1280, 720, `<svg style="left:0;top:0" width="1280" height="720" viewBox="0 0 1280 720">${MOTIFS[item.motif](1280, 720, palettes[item.palette], seeded(`${item.title}/wide`))}</svg>`);

const logo = (c) => {
  const p = palettes[c.palette];
  return pageFor(300, 300, `<div class="t" id="t" style="inset:0;background:${p.bg};color:${p.ink};align-items:center;justify-content:center;font-family:'Archivo Black';border-radius:48px;font-size:150px"><span>${c.code}</span></div>`);
};

const browser = await chromium.launch({ channel: 'msedge' });
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });

async function draw(html, file, width, height, fit) {
  await page.setViewportSize({ width, height });
  await page.setContent(html, { waitUntil: 'networkidle' });
  await page.evaluate(async (fit) => {
    await document.fonts.ready;
    if (!fit) return;
    // The largest size at which the title fills its band and no word overflows
    const box = document.getElementById('t');
    const span = document.getElementById('s');
    const room = box.clientWidth - 60;
    const tall = box.clientHeight - 36;
    for (let size = 118; size > 18; size -= 2) {
      span.style.fontSize = `${size}px`;
      if (span.scrollWidth <= room && span.offsetHeight <= tall) break;
    }
  }, fit);
  await page.locator('#a').screenshot({ path: file, omitBackground: true });
}

const unique = new Map([...movies, ...shows].filter((i) => !i.hidden).map((i) => [i.art, i]));
for (const [name, item] of unique) {
  await draw(poster(item), path.join(POSTERS, `${name}.png`), 500, 750, true);
  await draw(backdrop(item), path.join(BACKDROPS, `${name}.png`), 1280, 720, false);
}
for (const c of channels) await draw(logo(c), path.join(LOGOS, `${c.art}.png`), 300, 300, false);

// A contact sheet, for looking them all over at once
const images = [...unique.keys()].map((n) => `<img src="data:image/png;base64,${fs.readFileSync(path.join(POSTERS, `${n}.png`)).toString('base64')}" style="width:170px;display:block">`).join('');
await page.setViewportSize({ width: 1250, height: 900 });
await page.setContent(`<body style="margin:0;background:#000"><div style="display:grid;grid-template-columns:repeat(7,170px);gap:8px;padding:8px">${images}</div></body>`, { waitUntil: 'load' });
await page.screenshot({ path: path.join(HERE, 'art', 'sheet.png'), fullPage: true });

await browser.close();
console.log(`${unique.size} posters and backdrops, ${channels.length} logos`);
