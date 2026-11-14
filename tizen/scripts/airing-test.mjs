// The TV app's Airing (src/data/airing.ts) alone, in Node, as app/test/airing_test.dart checks the
// Flutter app's: the guide first; a channel the guide leaves out asked of the provider once, the
// screens told, the answer kept while its programme lasts; a guide with nothing on now asks too; a
// channel with no guide id never; a failure, or nothing to say, asked again only after a while; and
// three at a time, the channel shown last first.
//
//   node scripts/airing-test.mjs        exits 1 when a check fails
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const built = await esbuild.build({
  entryPoints: [path.join(ROOT, 'src', 'data', 'airing.ts')],
  bundle: true,
  write: false,
  format: 'esm',
  platform: 'node',
  target: 'node20',
  logLevel: 'error',
});
const { Airing } = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

let failed = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : ` ${detail}`}`);
  if (!ok) failed++;
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const t0 = Date.UTC(2026, 10, 14, 17);
const minute = 60 * 1000;
const entry = (title, from, to) => ({ title, description: '', start: new Date(t0 + from * minute), end: new Date(t0 + to * minute) });
// A guide as the screens use it: its programmes by guide id
const guideOf = (byId) => ({
  nowOn: (id, at) => (byId[id] || []).filter((e) => e.start.getTime() <= at && at < e.end.getTime())[0],
  upcoming: (id, count, at) => (byId[id] || []).filter((e) => e.end.getTime() > at).slice(0, count),
});
const rcn = { id: '7', name: 'RCN', epgId: 'rcn.co', archiveDays: 0 };
const espn = { id: '8', name: 'ESPN', epgId: 'espn', archiveDays: 0 };
const lounge = { id: '9', name: 'Lounge', archiveDays: 0 }; // no guide id
// The screens are told a moment after the answers come
const told = () => new Promise((r) => setTimeout(r, 200));

{
  const asked = [];
  const airing = new Airing(async (c) => (asked.push(c.id), []), () => t0);
  const guide = guideOf({ espn: [entry('Football', -30, 30)] });
  const now = airing.nowOn(espn, guide);
  await told();
  check('the guide first: the provider is not asked about a channel the guide has on now', now && now.title === 'Football' && asked.length === 0);
}

{
  let at = t0;
  const asked = [];
  const airing = new Airing(async (c) => (asked.push(c.id), [entry('El Chavo', -10, 20), entry('Noticias', 20, 80)]), () => at);
  let tellings = 0;
  airing.listen(() => tellings++);
  const empty = guideOf({});
  const first = [airing.nowOn(rcn, empty), airing.nowOn(rcn, empty)];
  await told();
  check('a channel the guide leaves out: nothing until the provider says it, asked once', same(first, [undefined, undefined]) && same(asked, ['7']));
  check('the screens are told once when it comes', tellings === 1, `told ${tellings} times`);
  const now = airing.nowOn(rcn, empty);
  const next = airing.upcoming(rcn, undefined).map((e) => e.title);
  check("then it is the provider's", now && now.title === 'El Chavo' && same(next, ['El Chavo', 'Noticias']), JSON.stringify(next));
  at = t0 + 19 * minute;
  airing.nowOn(rcn, undefined);
  await told();
  check('not asked again while what is on goes on', same(asked, ['7']));
  at = t0 + 21 * minute;
  const later = airing.nowOn(rcn, undefined);
  await told();
  check('once it ended: the next one from what was said, and asked again', later && later.title === 'Noticias' && same(asked, ['7', '7']));
}

{
  const airing = new Airing(async () => [entry('Live now', -5, 55)], () => t0);
  const stale = guideOf({ espn: [entry('Two days ago', -2900, -2840)] });
  const before = airing.nowOn(espn, stale);
  await told();
  const after = airing.nowOn(espn, stale);
  check("a guide with nothing on now for the channel (a copy kept from before the provider's failed): the provider is asked", before === undefined && after && after.title === 'Live now');
}

{
  const asked = [];
  const airing = new Airing(async (c) => (asked.push(c.id), []), () => t0);
  airing.nowOn(lounge, guideOf({}));
  await told();
  check('a channel with no guide id is never asked about', asked.length === 0);
}

{
  let at = t0;
  let asks = 0;
  let fail = true;
  const airing = new Airing(async () => {
    asks++;
    if (fail) throw new Error('down');
    return [];
  }, () => at);
  airing.nowOn(rcn, undefined);
  await told();
  at = t0 + 9 * minute;
  airing.nowOn(rcn, undefined);
  await told();
  const afterFailure = asks;
  at = t0 + 11 * minute;
  fail = false;
  airing.nowOn(rcn, undefined);
  await told();
  const again = asks;
  at = t0 + 40 * minute;
  airing.nowOn(rcn, undefined);
  await told();
  check('a failure is kept ten minutes, nothing to say half an hour', afterFailure === 1 && again === 2 && asks === 2, `${afterFailure}, ${again}, ${asks}`);
}

{
  const pending = new Map();
  const airing = new Airing((c) => new Promise((resolve) => pending.set(c.id, resolve)), () => t0);
  for (let i = 0; i < 10; i++) airing.nowOn({ id: `${i}`, name: `Channel ${i}`, epgId: `g${i}`, archiveDays: 0 }, undefined);
  const firstThree = [...pending.keys()];
  pending.get('0')([]);
  await new Promise((r) => setTimeout(r, 0));
  const keys = [...pending.keys()];
  check('three at a time, the channel shown last asked first', same(firstThree, ['0', '1', '2']) && keys[keys.length - 1] === '9', JSON.stringify(keys));
  for (const resolve of pending.values()) resolve([]);
}

await told();
if (failed) {
  console.log(`${failed} failed`);
  process.exit(1);
}
console.log('all passed');
