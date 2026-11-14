// The remote's focus engine (src/ui/focus.ts) in this machine's Edge, on pages laid out as the TV
// lays out Home: a side rail over the content, rows that scroll sideways, a short row. Each case
// presses arrows and checks where the focus lands. No TV and no provider needed.
//
//   node scripts/focus-test.mjs [engine.ts]   exits 1 when a case fails; another engine to compare
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { chromium } from 'playwright-core';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

const engine = (
  await build({
    entryPoints: [process.argv[2] ? path.resolve(process.argv[2]) : path.join(ROOT, 'src/ui/focus.ts')],
    bundle: true,
    write: false,
    format: 'iife',
    globalName: 'focusEngine',
    target: 'chrome69',
  })
).outputFiles[0].text;

// 1rem = 20 px, as on the TV. The rail is 216 px wide and over the content, as Home's is
const PAGE = `<!doctype html><html><head><style>
  html { font-size: 20px; } body { margin: 0; width: 1920px; height: 1080px; overflow: hidden; background: #000; color: #fff; }
  .screen { position: absolute; inset: 0; }
  .f { display: block; outline: none; }
  .rail { position: absolute; left: 0; top: 0; bottom: 0; width: 216px; z-index: 1; }
  .rail .f { width: 188px; height: 138px; margin: 4px 14px; }
  .page { position: absolute; inset: 0; overflow-y: auto; }
  .hscroll { display: flex; overflow-x: auto; padding: 12px 48px 12px 264px; }
  .poster { width: 300px; height: 444px; flex: none; margin-right: 28px; background: #333; }
  .rank { display: flex; flex: none; margin-right: 24px; align-items: flex-end; }
  .rank .n { width: 150px; font-size: 200px; line-height: 1; }
  .rank .poster { margin-left: -28px; margin-right: 0; }
  .wide { width: 520px; height: 300px; flex: none; margin-right: 28px; background: #444; }
  .text { height: 900px; margin-left: 264px; }
  .head { display: flex; justify-content: flex-end; padding: 12px 48px; }
  .head .f { width: 120px; height: 48px; background: #555; }
</style></head><body><div class="screen"></div></body></html>`;

const cases = {
  // The report: a row scrolled along, Left goes back to the poster before even when the rail is nearer
  rankedLeft: {
    html: ranked(10) + plain('next', 20),
    run: async (k) => {
      await k.focusText('r1');
      for (let i = 0; i < 7; i++) await k.press('right');
      const out = [await k.at()];
      for (let i = 0; i < 6; i++) {
        await k.press('left');
        out.push(await k.at());
      }
      return out;
    },
    want: ['r8', 'r7', 'r6', 'r5', 'r4', 'r3', 'r2'],
  },
  // From the first item of a row, Left still reaches the side rail
  railFromFirst: {
    html: ranked(10) + plain('next', 20),
    run: async (k) => {
      await k.focusText('r1');
      await k.press('right');
      await k.press('left');
      await k.press('left');
      return [await k.at()];
    },
    want: ['Home'],
  },
  // A plain row scrolled far along, back to its start, one item at a time
  plainLeft: {
    html: plain('p', 30),
    run: async (k) => {
      await k.focusText('p1');
      for (let i = 0; i < 14; i++) await k.press('right');
      const out = [await k.at()];
      for (let i = 0; i < 14; i++) await k.press('left');
      out.push(await k.at());
      return out;
    },
    want: ['p15', 'p1'],
  },
  // The end of a short row: Right stays, not down onto another row
  shortRowEnd: {
    html: wide('c', 2) + plain('below', 20),
    run: async (k) => {
      await k.focusText('c1');
      await k.press('right');
      await k.press('right');
      return [await k.at()];
    },
    want: ['c2'],
  },
  // A row marked for it goes on to the button in its header; from there, Down comes back to it
  headerAtEnd: {
    html: '<div><div class="head"><div class="f" tabindex="-1">Clear</div></div><div class="hscroll" data-fgroup data-fheader>' +
      ['one', 'two'].map((x) => `<div class="wide f" tabindex="-1">${x}</div>`).join('') + '</div></div>',
    run: async (k) => {
      await k.focusText('one');
      await k.press('right');
      await k.press('right');
      const clear = await k.at();
      await k.press('down');
      return [clear, await k.at()];
    },
    want: ['Clear', 'two'],
  },
  // Down from the last row does not land on the rail's last item, and the page scrolls to show
  // what is under it
  downAtBottom: {
    html: plain('p', 6) + '<div class="text">text under the last row</div>',
    run: async (k) => {
      await k.focusText('p1');
      await k.press('down');
      return [await k.at(), String((await k.scrollTop()) > 0)];
    },
    want: ['p1', 'true'],
  },
  // Up and down between rows still work
  betweenRows: {
    html: plain('a', 10) + plain('b', 10),
    run: async (k) => {
      await k.focusText('a2');
      await k.press('down');
      const down = await k.at();
      await k.press('up');
      return [down, await k.at()];
    },
    want: ['b2', 'a2'],
  },
};

function plain(prefix, n) {
  const items = Array.from({ length: n }, (_, i) => `<div class="poster f" tabindex="-1">${prefix}${i + 1}</div>`).join('');
  return `<div class="hscroll" data-fgroup>${items}</div>`;
}

function ranked(n) {
  const items = Array.from({ length: n }, (_, i) => `<div class="rank"><div class="n">${i + 1}</div><div class="poster f" tabindex="-1">r${i + 1}</div></div>`).join('');
  return `<div class="hscroll" data-fgroup>${items}</div>`;
}

function wide(prefix, n) {
  const items = Array.from({ length: n }, (_, i) => `<div class="wide f" tabindex="-1">${prefix}${i + 1}</div>`).join('');
  return `<div class="hscroll" data-fgroup>${items}</div>`;
}

const RAIL = `<div class="rail" data-fgroup data-fyield data-rail>${['Home', 'Movies', 'Series', 'Live', 'Search', 'Settings']
  .map((x) => `<div class="f" tabindex="-1">${x}</div>`)
  .join('')}</div>`;

const browser = await chromium.launchPersistentContext(fs.mkdtempSync(path.join(os.tmpdir(), 'capytv-focus-')), {
  channel: 'msedge',
  headless: true,
  viewport: { width: 1920, height: 1080 },
});
const page = browser.pages()[0] || (await browser.newPage());
let failed = 0;
for (const [name, c] of Object.entries(cases)) {
  await page.setContent(PAGE);
  await page.addScriptTag({ content: engine });
  await page.evaluate((html) => {
    document.querySelector('.screen').innerHTML = `<div class="page">${html}</div>` + document.querySelector('.screen').innerHTML;
  }, c.html);
  await page.evaluate((rail) => document.querySelector('.screen').insertAdjacentHTML('beforeend', rail), RAIL);
  const k = {
    focusText: (text) =>
      page.evaluate((t) => {
        const el = Array.from(document.querySelectorAll('.f')).find((e) => e.textContent === t);
        window.focusEngine.focus(el);
      }, text),
    press: (dir) => page.evaluate((d) => window.focusEngine.move(d), dir),
    at: () => page.evaluate(() => (document.activeElement ? document.activeElement.textContent : '')),
    scrollTop: () => page.evaluate(() => document.querySelector('.page').scrollTop),
  };
  const got = await c.run(k);
  const ok = JSON.stringify(got) === JSON.stringify(c.want);
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : `: got ${JSON.stringify(got)}, want ${JSON.stringify(c.want)}`}`);
}
await browser.close();
process.exit(failed ? 1 : 0);
