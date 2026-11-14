// Render Capy's editable SVG artwork into small animated WebP files.
// Run from tizen/: node scripts/capy-animations.mjs
// Requires Playwright Core (already a Tizen dev dependency), Chrome, and Python with Pillow.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const art = path.join(root, 'app/assets/branding');
const framesDir = path.join(root, 'app/build/capy-animation-frames');
const chrome = process.env.CHROME_PATH || (process.platform === 'win32'
  ? 'C:/Program Files/Google/Chrome/Application/chrome.exe'
  : '/usr/bin/chromium');
fs.mkdirSync(framesDir, { recursive: true });
const browser = await chromium.launch({ executablePath: chrome, headless: true, args: ['--no-sandbox'] });
try {
  const page = await browser.newPage({ viewport: { width: 256, height: 256 }, deviceScaleFactor: 1 });
  for (const name of ['icon', 'offline', 'account', 'error', 'empty', 'video']) {
    const svg = fs.readFileSync(path.join(art, `capy-${name}.svg`), 'utf8');
    await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:256px;height:256px}</style>${svg}`);
    await page.evaluate(() => {
      const svg = document.querySelector('svg');
      const nodes = [...svg.children];
      const face = document.createElementNS('http://www.w3.org/2000/svg', 'g');
      svg.insertBefore(face, nodes[1]);
      for (const node of nodes.slice(1, 6)) face.appendChild(node);
      face.id = 'face';
      const badge = document.createElementNS('http://www.w3.org/2000/svg', 'g');
      for (const node of nodes.slice(6)) badge.appendChild(node);
      badge.id = 'badge';
      svg.appendChild(badge);
    });
    for (let i = 0; i < 24; i++) {
      await page.evaluate(({ i, name }) => {
        const phase = i * Math.PI * 2 / 24;
        const breathing = Math.sin(phase);
        const angle = (name === 'icon' ? 1.8 : 1.1) * breathing;
        const y = (name === 'icon' ? -1.8 : -0.8) * (1 - Math.cos(phase));
        document.querySelector('#face').setAttribute('transform', `translate(0 ${y}) rotate(${angle} 78 88)`);
        document.querySelector('#badge').setAttribute('transform', `rotate(${-angle * 1.8} 122 123)`);
        // Briefly open the relaxed eyes, then return to Capy's familiar closed-eye smile.
        const eyes = document.querySelector('#face path:nth-child(2)');
        eyes.setAttribute('d', i >= 14 && i <= 16
          ? 'M52 75v3m53-3v3'
          : 'M44 77q8 8 16 0m37 0q8 8 16 0');
      }, { i, name });
      await page.screenshot({ path: path.join(framesDir, `${name}-${String(i).padStart(2, '0')}.png`), omitBackground: true });
    }
    const encoder = `from PIL import Image\nfrom pathlib import Path\nimport sys\np=Path(sys.argv[1]); name=sys.argv[2]; dest=Path(sys.argv[3])\nframes=[Image.open(p / f'{name}-{i:02d}.png').convert('RGBA') for i in range(24)]\nframes[0].save(dest, format='WEBP', save_all=True, append_images=frames[1:], duration=100, loop=0, lossless=True, method=6)\n`;
    execFileSync(process.env.PYTHON || 'python', ['-c', encoder, framesDir, name, path.join(art, `capy-${name}.webp`)], { stdio: 'inherit' });
    console.log(`capy-${name}.webp`);
  }
} finally {
  await browser.close();
}
