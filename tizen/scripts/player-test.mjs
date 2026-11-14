// The TV app's player in this machine's Edge, with AVPlay played by a stand-in whose seeks take
// their time, as on a slow line, and a panel that needs no provider: what the bar shows while a
// skip is on its way, the next episode offered in an episode's last half minute, a film that goes
// quiet, a version picked by hand, a slow resume, the picture's fit, the subtitles' size and band,
// what is remembered about AVPlay's refusals, a live channel's list and My list, what another
// device sends here, a series' episodes and intro, and the stream info.
//
//   node scripts/build.mjs && node scripts/player-test.mjs        exits 1 when a check fails
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright-core';

const WWW = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'build', 'www');
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.ttf': 'font/ttf', '.svg': 'image/svg+xml', '.json': 'application/json' };
const DURATION = 120000;

// ---- a panel ------------------------------------------------------------------------------------

const now = Math.floor(Date.now() / 1000);
const auth = {
  user_info: { auth: 1, status: 'Active', exp_date: String(now + 86400 * 400), is_trial: '0', active_cons: '0', max_connections: '2', allowed_output_formats: ['ts', 'm3u8'] },
  server_info: { timezone: 'UTC', timestamp_now: now, time_now: new Date().toISOString().slice(0, 19).replace('T', ' ') },
};
const series = [1, 2, 3].map((i) => ({ num: i, name: `Show ${i}`, series_id: 2000 + i, cover: '', rating: '7', category_id: '1', last_modified: String(now - i * 3600), genre: 'Drama' }));
const episodes = [1, 2, 3].map((n) => ({ id: String(100 + n), episode_num: n, title: `Chapter ${n}`, season: 1, container_extension: 'mp4', info: { duration_secs: DURATION / 1000 } }));
// Only for the account called "live": the other scenarios start on a panel with no channels
const CHANNELS = 3000;
const GUIDED = 200; // the first channels have a guide, the others not
const channels = Array.from({ length: CHANNELS }, (_, i) => ({ num: i + 1, name: `Channel ${i + 1}`, stream_id: 5000 + i, stream_icon: '', epg_channel_id: `ch${i + 1}`, category_id: '1', tv_archive: 0 }));
const stamp = (ms) => new Date(ms).toISOString().replace(/[-:T]/g, '').slice(0, 14) + ' +0000';
const programmes = Array.from({ length: GUIDED }, (_, i) => `<programme start="${stamp(now * 1000 - 600000)}" stop="${stamp(now * 1000 + 3 * 3600000)}" channel="ch${i + 1}"><title>Programme ${i + 1}</title></programme>`);
const XMLTV = `<?xml version="1.0" encoding="UTF-8"?><tv>${programmes.join('')}</tv>`;

function api(q) {
  switch (q.get('action')) {
    case null:
      return auth;
    case 'get_live_categories':
      return q.get('username') === 'live' ? [{ category_id: '1', category_name: 'News', parent_id: 0 }] : [];
    case 'get_live_streams':
      return q.get('username') === 'live' ? channels : [];
    case 'get_series_categories':
      return [{ category_id: '1', category_name: 'Drama', parent_id: 0 }];
    case 'get_series':
      return series;
    case 'get_series_info':
      return { info: { name: 'Show 1', plot: 'A plot' }, episodes: { 1: episodes }, seasons: [] };
    default:
      return [];
  }
}

// One film in two languages, each on a server of its own (nothing is fetched from those)
const FILMS = '#EXTM3U\n#EXTINF:-1 group-title="Latino",Film One\nhttp://a.test:1/movie/u/p/1.mp4\n#EXTINF:-1 group-title="English",Film One\nhttp://b.test:2/movie/u/p/2.mp4\n';

// The account's server, for what it takes to receive something: the sealed items, the devices
const sync = { rev: 1, items: [], asked: 0 };

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname.startsWith('/sync/v1/')) {
    const send = (j, code = 200) => {
      res.writeHead(code, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(j));
    };
    const what = u.pathname.slice('/sync/v1/'.length);
    if (what === 'devices') return send({ devices: [{ id: 'tv1', device: 'TV', seen: new Date().toISOString(), current: true }] });
    if (what === 'items' && req.method === 'GET') {
      sync.asked++;
      const since = Number(u.searchParams.get('since'));
      return send({ rev: sync.rev, epoch: 1, items: sync.items.filter((i) => i.rev > since).map(({ id, payload }) => ({ id, payload })) });
    }
    if (what === 'items') {
      req.resume();
      return send({ rev: ++sync.rev });
    }
    return send({}, 404);
  }
  if (u.pathname === '/hang.mp4') return; // never answers: what the <video> does with it is not the point
  if (u.pathname === '/films.m3u') {
    res.writeHead(200, { 'Content-Type': 'audio/x-mpegurl' });
    return res.end(FILMS);
  }
  if (u.pathname === '/xmltv.php' && u.searchParams.get('username') === 'live') {
    res.writeHead(200, { 'Content-Type': 'application/xml' });
    return res.end(XMLTV);
  }
  if (u.pathname === '/player_api.php') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(api(u.searchParams)));
  }
  const file = path.join(WWW, u.pathname === '/' ? 'index.html' : decodeURIComponent(u.pathname));
  if (!file.startsWith(WWW) || !fs.existsSync(file)) {
    res.writeHead(404);
    return res.end();
  }
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] ?? 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const ORIGIN = `http://127.0.0.1:${server.address().port}`;

// ---- AVPlay, and the TV around it ---------------------------------------------------------------

function standIn({ duration, origin, films, live, account }) {
  if (account) localStorage.setItem('sync.account', JSON.stringify(account));
  localStorage.setItem('playlists', JSON.stringify([films ? { id: 'm1', name: 'Films', type: 'm3u', url: films, username: '', password: '', members: [] } : { id: 'p1', name: 'Test', type: 'xtream', url: origin, username: live ? 'live' : 'u', password: 'p', members: [] }]));
  if (films) localStorage.setItem('streamStats', JSON.stringify({ 'b.test:2': new Array(24).fill(800) })); // the second server is known to be quick
  const lab = (window.__av = { latency: 1500, offset: 0, inFlight: 0, maxInFlight: 0, seeks: [], url: '', opens: 0, frozen: false, refuse: '', refuseBy: 'callback', webOk: null, rects: [], modes: [], modeRefused: '', streams: [] });
  // hls.js's way out, without a stream: null plays for real, true starts, false refuses
  const realPlay = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    return lab.webOk === null ? realPlay.call(this) : lab.webOk ? Promise.resolve() : Promise.reject(new Error('refused'));
  };
  const av = {
    state: 'NONE',
    pos: 0,
    timer: 0,
    listener: null,
    gen: 0, // a seek under way does not outlive the stream it was for
    open(url) {
      lab.url = url;
      lab.opens++;
      lab.inFlight = 0;
      lab.rects = []; // since this open
      lab.modes = [];
      this.gen++;
      this.state = 'IDLE';
      this.pos = 0;
    },
    setDisplayRect(x, y, w, h) {
      lab.rects.push([x, y, w, h]);
    },
    setDisplayMethod(mode) {
      if (lab.modeRefused && mode.includes(lab.modeRefused)) throw new Error('InvalidValuesError');
      lab.modes.push(mode);
    },
    setStreamingProperty() {},
    setListener(l) {
      this.listener = l;
    },
    prepareAsync(ok, err) {
      this.state = 'READY';
      setTimeout(() => {
        if (!lab.refuse) ok();
        else if (lab.refuseBy === 'listener') this.listener.onerror(lab.refuse);
        else err({ name: lab.refuse, message: 'refused' });
      }, 30);
    },
    play() {
      this.state = 'PLAYING';
      clearInterval(this.timer);
      this.timer = setInterval(() => {
        if (this.state !== 'PLAYING' || lab.inFlight || lab.frozen) return;
        this.pos += 250;
        if (!live && this.pos >= duration) {
          this.pos = duration;
          this.state = 'READY';
          clearInterval(this.timer);
          this.listener.onstreamcompleted();
          return;
        }
        this.listener.oncurrentplaytime(this.pos);
      }, 250);
    },
    pause() {
      this.state = 'PAUSED';
    },
    stop() {
      clearInterval(this.timer);
      this.state = 'IDLE';
    },
    close() {
      clearInterval(this.timer);
      this.state = 'NONE';
      this.pos = 0;
    },
    seekTo(ms, ok) {
      lab.seeks.push(ms);
      lab.inFlight++;
      lab.maxInFlight = Math.max(lab.maxInFlight, lab.inFlight);
      const gen = this.gen;
      setTimeout(() => {
        if (gen !== this.gen) return;
        lab.inFlight--;
        this.pos = ms - lab.offset; // where a keyframe is
        ok();
        this.listener.oncurrentplaytime(this.pos);
      }, lab.latency);
    },
    getState() {
      return this.state;
    },
    getCurrentTime() {
      return this.pos;
    },
    getDuration() {
      return live || this.state === 'NONE' || this.state === 'IDLE' ? 0 : duration;
    },
    getTotalTrackInfo: () => [{ type: 'VIDEO', index: 0, extra_info: '{"Width":1920,"Height":1080}' }, { type: 'TEXT', index: 2, extra_info: '{"track_lang":"spa"}' }],
    getCurrentStreamInfo: () => lab.streams,
    setSpeed() {},
    setSelectTrack() {},
    setSilentSubtitle() {},
  };
  window.__avplay = av;
  window.tizen = {
    tvinputdevice: { registerKey() {}, getSupportedKeys: () => [] },
    application: { getCurrentApplication: () => ({ exit() {}, getRequestedAppControl: () => null }) },
  };
  window.webapis = { avplay: av, productinfo: { getRealModel: () => 'TEST', getDuid: () => 'test' } };
}

// ---- the checks ---------------------------------------------------------------------------------

const browser = await chromium.launchPersistentContext(fs.mkdtempSync(path.join(os.tmpdir(), 'capytv-player-')), {
  channel: 'msedge',
  headless: true,
  viewport: { width: 1920, height: 1080 },
  locale: 'en-US',
});
let page = browser.pages()[0] || (await browser.newPage());
await page.addInitScript(standIn, { duration: DURATION, origin: ORIGIN });

let failed = 0;
const check = (name, ok, detail = '') => {
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : `: ${detail}`}`);
};
const wait = (ms) => new Promise((ok) => setTimeout(ok, ms));
const until = async (what, test, ms = 15000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await test()) return true;
    await wait(100);
  }
  throw new Error(`timed out waiting for ${what}`);
};
const lab = () => page.evaluate(() => ({ ...window.__av, pos: window.__avplay.pos, state: window.__avplay.state }));
const clockMs = (text) => {
  const p = text.replace('−', '').split(':').map(Number);
  return p.reduce((a, b) => a * 60 + b, 0) * 1000;
};
const shownAt = async () => clockMs(await page.locator('.player-time').first().innerText());
const controlsUp = () => page.evaluate(() => getComputedStyle(document.querySelector('.player-overlay')).opacity !== '0');
const focusedClass = () => page.evaluate(() => document.activeElement.className);
const focusedText = () => page.evaluate(() => document.activeElement.textContent.trim());
const hidden = () => until('the controls to hide', async () => !(await controlsUp()), 20000);
const says = (...a) => JSON.stringify(a);
const cardText = () => page.evaluate(() => (document.body.innerText.match(/Next episode in \d+ s/) || [''])[0]);

/** From the series' page, its Play: the player, playing, with [episode]'s address. */
async function startPlaying() {
  await until('the player', () => page.locator('.pbar').count().then((n) => n > 0));
  await until('it to play', async () => (await lab()).pos >= 750);
}

await page.goto(`${ORIGIN}/index.html`);
await until('Home', () => page.getByRole('heading', { name: 'Home' }).count().then((n) => n > 0));

// The series tab, its first title, Play
await page.waitForTimeout(800);
for (let i = 0; i < 8; i++) {
  if (await page.evaluate(() => !!document.activeElement.closest('[data-rail]'))) break;
  await page.keyboard.press('ArrowLeft');
  await wait(120);
}
await page.keyboard.press('ArrowDown');
await wait(120);
await page.keyboard.press('ArrowDown');
await wait(120);
await page.keyboard.press('Enter');
await until('the series', () => page.evaluate(() => Array.from(document.querySelectorAll('.f')).some((e) => e.offsetParent && /^Show 1/.test(e.textContent))));
await page.evaluate(() => Array.from(document.querySelectorAll('.f')).find((e) => e.offsetParent && /^Show 1/.test(e.textContent)).focus());
await page.keyboard.press('Enter');
await until('its page', () => page.evaluate(() => /S1 · E1/.test(document.body.innerText)));
await until('Play', () => page.evaluate(() => /S1 · E1/.test(document.activeElement.textContent)));
await page.keyboard.press('Enter');
await startPlaying();
const untouched = await lab();
check('with no fit ever picked, AVPlay is left to draw the picture as before', untouched.modes.length === 0 && JSON.stringify(untouched.rects) === '[[0,0,1920,1080]]', says(untouched.modes, untouched.rects));

// ---- skipping --------------------------------------------------------------------------------

await hidden();
const before = (await lab()).pos;
await page.keyboard.press('ArrowRight');
await wait(60);
await page.keyboard.press('ArrowRight');
await wait(60);
await page.keyboard.press('ArrowRight');
await wait(60);
const seen = await shownAt();
check('the bar goes where three skips are going, before any has landed', Math.abs(seen - (before + 30000)) < 2500, `shows ${seen}, from ${before}`);
check('the player has not moved yet', (await lab()).pos === before, `at ${(await lab()).pos}`);
const flash = await page.locator('.player-center .panel').first().innerText();
check('the notice adds them up', flash.trim() === '+30', `"${flash}"`);
check('the arrows are on the bar now, so they go on skipping', /pbar/.test(await focusedClass()), await focusedClass());
await until('the skips to land', async () => { const l = await lab(); return l.inFlight === 0 && l.seeks.length >= 2 && Math.abs(l.pos - (before + 30000)) < 1000; });
const skipped = await lab();
check('one seek at a time', skipped.maxInFlight === 1, `${skipped.maxInFlight} at once`);
check('the middle one is dropped, the last one wins', skipped.seeks.length === 2 && Math.abs(skipped.seeks[1] - (before + 30000)) < 1000, JSON.stringify(skipped.seeks));
await wait(400);
check('the bar follows the player again', Math.abs((await shownAt()) - (await lab()).pos) < 1500);

// A stream that can only land on a keyframe, short of where it was asked
await page.evaluate(() => { window.__av.offset = 6000; window.__av.latency = 300; });
await page.keyboard.press('ArrowRight');
await until('it to land', async () => (await lab()).inFlight === 0 && (await lab()).seeks.length >= 3);
await wait(500);
const landed = await lab();
check('landing short of it, the bar shows where it landed', Math.abs((await shownAt()) - landed.pos) < 1500, `shows ${await shownAt()}, at ${landed.pos}`);
await page.evaluate(() => { window.__av.offset = 0; });

// With a subtitle on screen: clearing it tells the player screen before the seek has gone
await page.evaluate(() => { window.__av.latency = 1500; window.__avplay.listener.onsubtitlechange(9000, 'A line of text'); });
await wait(150);
const withLine = await lab();
await page.keyboard.press('ArrowRight');
await wait(100);
check('with a subtitle showing, the bar still goes where the skip is going', Math.abs((await shownAt()) - (withLine.pos + 10000)) < 2500, `shows ${await shownAt()}, from ${withLine.pos}`);
await until('it to land', async () => (await lab()).inFlight === 0 && (await lab()).seeks.length > withLine.seeks.length);

// The stream breaks and is opened again: a skip while its seek is on its way goes on from there
await page.evaluate(() => { window.__av.latency = 2500; });
await wait(400);
const broken = await lab();
await page.evaluate(() => window.__avplay.listener.onerror('PLAYER_ERROR_CONNECTION_FAILED'));
await wait(300);
check('broken off, the bar stays where it was, not at 0:00', Math.abs((await shownAt()) - broken.pos) < 3000, `shows ${await shownAt()}, at ${broken.pos}`);
await until('the seek back', async () => (await lab()).seeks.length > broken.seeks.length && (await lab()).inFlight === 1, 12000);
await page.keyboard.press('ArrowRight');
await wait(100);
await until('both to land', async () => (await lab()).inFlight === 0 && (await lab()).seeks.length === broken.seeks.length + 2, 12000);
const reopened = await lab();
check('a skip during that seek goes on from where it is going', Math.abs(reopened.pos - (broken.pos + 10000)) < 2000, `at ${reopened.pos}, was ${broken.pos}`);
await page.evaluate(() => { window.__av.latency = 300; });

// ---- the next episode ------------------------------------------------------------------------

check('no offer before the last half minute', (await cardText()) === '');

// Skipped into it, the controls are up: the offer waits for them to go to take the remote
await page.evaluate((d) => { window.__avplay.pos = d - 38000; }, DURATION);
await hidden();
await page.evaluate(() => document.querySelector('.pbar').focus());
await page.keyboard.press('ArrowRight');
await until('the offer', async () => (await cardText()) !== '');
check('with the controls up it leaves the remote where it is', /pbar/.test(await focusedClass()), await focusedClass());
await wait(600); // the controls are on their way up: not to be taken for gone
await hidden();
await until('the offer to take the remote', async () => (await focusedText()) === 'Play now', 3000).catch(() => {});
check('once they go it takes it', (await focusedText()) === 'Play now', await focusedText());
await page.evaluate((d) => { window.__avplay.pos = d - 45000; }, DURATION);
await until('the offer to go', async () => (await cardText()) === '');
await page.evaluate((d) => { window.__avplay.pos = d - 45000; }, DURATION);
await hidden();
await page.evaluate((d) => { window.__avplay.pos = d - 28000; }, DURATION);
await until('the offer', async () => (await cardText()) !== '');
check('the last half minute offers the next episode', /Next episode in \d+ s/.test(await cardText()));
await wait(200);
check('with the controls away it has the remote, on Play now', (await focusedText()) === 'Play now', await focusedText());
await page.keyboard.press('ArrowRight');
await wait(150);
check('Right goes to Cancel', (await focusedText()) === 'Cancel', await focusedText());
await page.keyboard.press('ArrowLeft');
await wait(150);
check('Left comes back', (await focusedText()) === 'Play now', await focusedText());
await page.keyboard.press('Enter');
await until('the next episode', async () => /\/102\./.test((await lab()).url));
check('OK on Play now plays the next episode', true);
await until('it to play', async () => (await lab()).pos >= 750);

// Cancel: the episode ends and nothing starts
await page.evaluate((d) => { window.__avplay.pos = d - 45000; }, DURATION);
await hidden();
await page.evaluate((d) => { window.__avplay.pos = d - 6000; }, DURATION);
await until('the offer', async () => (await cardText()) !== '');
await wait(200);
await page.keyboard.press('ArrowRight');
await wait(150);
await page.keyboard.press('Enter');
await until('it to go', async () => (await cardText()) === '');
check('Cancel takes it away', true);
await until('the end', async () => (await page.locator('.pbar').count()) === 0, 12000);
check('and with no next episode, the player closes at the end', !/\/103\./.test((await lab()).url), (await lab()).url);

await browser.close();

// ---- a list with one film on two servers, the page's clock jumped ahead to wait less -------------

const films = await chromium.launchPersistentContext(fs.mkdtempSync(path.join(os.tmpdir(), 'capytv-player-')), {
  channel: 'msedge',
  headless: true,
  viewport: { width: 1920, height: 1080 },
  locale: 'en-US',
});
await films.clock.install();
page = films.pages()[0] || (await films.newPage());
await page.addInitScript(standIn, { duration: DURATION, origin: ORIGIN, films: `${ORIGIN}/films.m3u` });

const ahead = (ms) => page.clock.fastForward(ms);
const setLab = (changes) => page.evaluate((c) => void Object.assign(window.__av, c), changes);
const onPlay = (label = 'Play') => until(`${label} to have the remote`, async () => (await focusedText()).startsWith(label));
const pickVersion = async (name) => {
  const find = (n) => Array.from(document.querySelectorAll('.screen:not(.hidden) .f')).find((e) => e.offsetParent && e.textContent.trim().startsWith(n));
  await until(name, () => page.evaluate(`!!(${find})(${JSON.stringify(name)})`));
  await page.evaluate(`(${find})(${JSON.stringify(name)}).focus()`);
  await page.keyboard.press('Enter');
};
const leavePlayer = async (label) => {
  await page.keyboard.press('Escape');
  await until('the film page', async () => (await page.locator('.pbar').count()) === 0);
  await onPlay(label);
};

await page.goto(`${ORIGIN}/index.html`);
await until('Home', () => page.getByRole('heading', { name: 'Home' }).count().then((n) => n > 0));
await page.waitForTimeout(800);
for (let i = 0; i < 8; i++) {
  if (await page.evaluate(() => !!document.activeElement.closest('[data-rail]'))) break;
  await page.keyboard.press('ArrowLeft');
  await wait(120);
}
await page.keyboard.press('ArrowDown');
await wait(120);
await page.keyboard.press('Enter');
await pickVersion('Film One');
await onPlay();

// ---- a version picked by hand ----------------------------------------------------------------

await page.keyboard.press('Enter');
await startPlaying();
check('Play goes to the copy on the quickest server', /b\.test/.test((await lab()).url), (await lab()).url);
await leavePlayer('Play');

await pickVersion('English ·');
await until('the other page', async () => !(await focusedText()).startsWith('English'));
await onPlay();
await pickVersion('Latino ·');
await until('the other page', async () => !(await focusedText()).startsWith('Latino'));
await onPlay();
await page.keyboard.press('Enter');
await startPlaying();
check('a version picked in Versions is the one that plays, though the other server is quicker', /a\.test/.test((await lab()).url), (await lab()).url);

// ---- a film that goes quiet ------------------------------------------------------------------

await page.evaluate(() => { window.__avplay.pos = 60000; });
await wait(600);
await hidden();
await setLab({ frozen: true });
await wait(300);
const quiet = await lab();

await ahead(30000);
await wait(2500);
check('30 s with no picture moving is not yet a stall', (await lab()).opens === quiet.opens, `${(await lab()).opens} opens, was ${quiet.opens}`);

await page.keyboard.press('Enter');
await until('it to pause', async () => (await lab()).state === 'PAUSED');
await ahead(60000);
await wait(2500);
check('paused for a minute is no stall', (await lab()).opens === quiet.opens, `${(await lab()).opens} opens, was ${quiet.opens}`);
await page.keyboard.press('Enter');
await until('it to play again', async () => (await lab()).state === 'PLAYING');
await wait(2500);
check('and the time paused does not count once it plays again', (await lab()).opens === quiet.opens, `${(await lab()).opens} opens, was ${quiet.opens}`);

await setLab({ latency: 20000 });
await ahead(46000);
await until('it to be opened again', async () => (await lab()).opens > quiet.opens, 10000);
await until('the seek back', async () => { const l = await lab(); return l.inFlight === 1 && l.seeks.length > quiet.seeks.length; }, 10000);
const back1 = await lab();
check('a film that went quiet is opened again by itself, where it was', back1.opens === quiet.opens + 1 && Math.abs(back1.seeks[back1.seeks.length - 1] - quiet.pos) < 2000, JSON.stringify(back1.seeks));

await ahead(13000);
await wait(2500);
check('a seek back on its way, slower than the stall limit, is no stall', (await lab()).opens === back1.opens, `${(await lab()).opens} opens, was ${back1.opens}`);
await setLab({ latency: 300 });
await ahead(8000);
await until('it to land', async () => (await lab()).inFlight === 0, 5000);

// Still no data: it is opened again once more, and then it says so. A minute after opening it is
// not "fine again" for having got there slowly: that would go on reopening for good
await ahead(40000);
await wait(2500);
await ahead(6000);
await until('the second reopening', async () => (await lab()).opens > back1.opens, 10000);
await until('the seek back', async () => { const l = await lab(); return l.inFlight === 0 && l.seeks.length > back1.seeks.length; }, 10000);
const back2 = await lab();
await ahead(46000);
await until('the panel', () => page.evaluate(() => /couldn.t be played/i.test(document.body.innerText)), 10000);
check('MAX_VOD_REOPENS stands: after two the film says unavailable', (await lab()).opens === back2.opens && back2.opens === quiet.opens + 2, `${(await lab()).opens} opens`);
const gaveUp = await lab();
check('given up on, nothing is left playing behind the panel', gaveUp.state === 'IDLE' || gaveUp.state === 'NONE', gaveUp.state);
await setLab({ frozen: false });
await onPlay('Retry');
await page.keyboard.press('Enter');
await until('Retry to play it', async () => { const l = await lab(); return l.opens > gaveUp.opens && l.state === 'PLAYING' && l.inFlight === 0 && l.pos > 2000; }, 10000);
check('and Retry takes it from where it was', Math.abs((await lab()).pos - quiet.pos) < 5000, `at ${(await lab()).pos}, was ${quiet.pos}`);

// OK on the frozen picture, while it waits to be opened again, does not switch the stall check off
await wait(600);
await hidden();
await setLab({ frozen: true });
await wait(300);
const pressed = await lab();
await ahead(46000);
await until('the note', () => page.evaluate(() => /Reconnecting/.test(document.body.innerText)), 10000);
await page.keyboard.press('Enter');
await until('it to be opened again', async () => (await lab()).opens > pressed.opens, 10000);
await until('the seek back', async () => { const l = await lab(); return l.inFlight === 0 && l.seeks.length > pressed.seeks.length; }, 10000);
await wait(300);
await ahead(46000);
await wait(2500);
await ahead(6000);
check('OK pressed while it waited does not stop it noticing the next freeze', await until('one more', async () => (await lab()).opens > pressed.opens + 1, 10000).catch(() => false), `${(await lab()).opens} opens, was ${pressed.opens}`);
await setLab({ frozen: false });

// ---- the seek to where it was left -----------------------------------------------------------

await leavePlayer('Continue');
await setLab({ latency: 12000 });
const resume = await lab();
await page.keyboard.press('Enter');
await until('the resume seek', async () => { const l = await lab(); return l.inFlight === 1 && l.seeks.length > resume.seeks.length; }, 10000);
await ahead(11000);
await wait(400);
const during = await lab();
check('a resume seek outlasting the start limit does not give up the copy', during.opens === resume.opens + 1 && /a\.test/.test(during.url), `${during.opens} opens, ${during.url}`);
await ahead(2000);
await until('it to land', async () => (await lab()).inFlight === 0, 5000);
await wait(300);
check('and it goes on from where it was', Math.abs((await lab()).pos - during.seeks[during.seeks.length - 1]) < 3000, `at ${(await lab()).pos}`);

await leavePlayer('Continue');
await setLab({ latency: 1e9 });
const never = await lab();
await page.keyboard.press('Enter');
await until('the resume seek', async () => { const l = await lab(); return l.inFlight === 1 && l.seeks.length > never.seeks.length; }, 10000);
await ahead(28000);
await wait(400);
const waiting = await lab();
check('a slow resume seek is waited for', waiting.opens === never.opens + 1 && /a\.test/.test(waiting.url), `${waiting.opens} opens, ${waiting.url}`);
await setLab({ latency: 300 });
await ahead(3000);
await until('the other copy', async () => /b\.test/.test((await lab()).url), 10000).catch(() => {});
check('one that never lands is given up, for the next copy', /b\.test/.test((await lab()).url), (await lab()).url);
await until('it to land', async () => (await lab()).inFlight === 0 && (await lab()).state === 'PLAYING', 10000);
await leavePlayer('Continue');

// ---- the picture's fit, with the remote --------------------------------------------------------

const focusedLabel = () => page.evaluate(() => document.activeElement.getAttribute('aria-label') || '');
const panelRows = () => page.evaluate(() => Array.from(document.querySelectorAll('.player-panel .f')).map((e) => e.innerText.replace(/\s+/g, ' ').trim()));
/** From wherever the remote is, along the dock to the button called [label]. */
const toDock = async (label) => {
  let way = 'ArrowRight';
  for (let i = 0; i < 40 && (await focusedLabel()) !== label; i++) {
    const at = await page.evaluate(() => {
      const el = document.activeElement;
      const stuck = window.__was === el;
      window.__was = el;
      return { dock: !!el.closest('.player-overlay .panel') && !el.classList.contains('pbar'), stuck };
    });
    if (at.dock && at.stuck) way = way === 'ArrowRight' ? 'ArrowLeft' : 'ArrowRight'; // the end of the row: the other way
    await page.keyboard.press(at.dock ? way : 'ArrowDown');
    await wait(90);
  }
  if ((await focusedLabel()) !== label) throw new Error(`no way to ${label}`);
};
/** Down the open panel to the row starting with [text]; OK on it if [press]. */
const toRow = async (text, press = true) => {
  for (let i = 0; i < 12 && !(await focusedText()).startsWith(text); i++) {
    await page.keyboard.press('ArrowDown');
    await wait(90);
  }
  if (!(await focusedText()).startsWith(text)) throw new Error(`no row ${text}`);
  if (press) await page.keyboard.press('Enter');
  await wait(90);
};
const reopened2 = async (from) => until('it to be opened again', async () => { const l = await lab(); return l.opens > from && l.state === 'PLAYING'; }, 10000);
const saved = (key) => page.evaluate((k) => localStorage.getItem(k), key);

await page.keyboard.press('Enter');
await startPlaying();
await toDock('Picture');
await page.keyboard.press('Enter');
await until('the panel', async () => (await panelRows()).length > 0);
await wait(200);
check('on AVPlay the panel offers what it can do, Fill not among them', says(await panelRows()) === says(['Fit', 'Stretch', '16:9', '4:3', '21:9']), says(await panelRows()));
check('with nothing picked it says Fit, with the remote on it', (await focusedText()) === 'Fit', await focusedText());
check('opening the panel changes nothing', (await lab()).modes.length === 0 && (await saved('videoFit')) === null, says((await lab()).modes));

await toRow('Stretch');
let fit = await lab();
check('Stretch is AVPlay\'s full screen, on the whole screen, and kept', fit.modes[fit.modes.length - 1] === 'PLAYER_DISPLAY_MODE_FULL_SCREEN' && JSON.stringify(fit.rects[fit.rects.length - 1]) === '[0,0,1920,1080]' && (await saved('videoFit')) === 'fill', says(fit.modes, fit.rects));

await toRow('4:3');
fit = await lab();
check('a shape of its own is a centred rectangle of that shape', JSON.stringify(fit.rects[fit.rects.length - 1]) === '[240,0,1440,1080]' && fit.modes[fit.modes.length - 1] === 'PLAYER_DISPLAY_MODE_FULL_SCREEN' && (await saved('videoFit')) === '4:3', says(fit.rects));

await toRow('21:9');
fit = await lab();
check('a wide one too', JSON.stringify(fit.rects[fit.rects.length - 1]) === '[0,128,1920,823]', says(fit.rects));
await page.keyboard.press('ArrowUp');
await wait(120);
await page.keyboard.press('Enter');
await wait(120);
check('the panel marks what is set and stays open to try the next', (await saved('videoFit')) === '4:3' && (await panelRows()).length === 5, says(await saved('videoFit')));

// A drop while it is set: the stream opened again keeps it
await page.evaluate(() => window.__avplay.listener.onerror('PLAYER_ERROR_CONNECTION_FAILED'));
await reopened2(fit.opens);
await wait(200);
fit = await lab();
check('whatever is set goes on again at each open, before and after prepare', fit.modes.length === 2 && fit.modes.every((m) => m === 'PLAYER_DISPLAY_MODE_FULL_SCREEN') && fit.rects.filter((r) => JSON.stringify(r) === '[240,0,1440,1080]').length === 2, says(fit.modes, fit.rects));

// The other way: Fit, with AVPlay refusing its mode
await setLab({ modeRefused: 'AUTO_ASPECT_RATIO' });
await page.keyboard.press('ArrowUp');
await wait(90);
await page.keyboard.press('ArrowUp');
await wait(90);
await page.keyboard.press('ArrowUp');
await wait(90);
await page.keyboard.press('Enter');
await wait(120);
fit = await lab();
check('Fit asks for the stream\'s own shape on the whole screen, letterbox where that is refused', fit.modes[fit.modes.length - 1] === 'PLAYER_DISPLAY_MODE_LETTER_BOX' && JSON.stringify(fit.rects[fit.rects.length - 1]) === '[0,0,1920,1080]' && (await saved('videoFit')) === 'contain', says(fit.modes, fit.rects, await focusedText()));

// Every mode refused, and a rectangle too: nothing of it stops the stream, or its next open
await setLab({ modeRefused: 'PLAYER_DISPLAY_MODE' });
await page.evaluate(() => { const av = window.__avplay; av.realRect = av.setDisplayRect; av.setDisplayRect = function (...a) { if (a[2] !== 1920 || a[3] !== 1080) throw new Error('InvalidStateError'); return av.realRect(...a); }; });
await toRow('Stretch');
await toRow('4:3');
await wait(300);
const refused = await lab();
await page.evaluate(() => window.__avplay.listener.onerror('PLAYER_ERROR_CONNECTION_FAILED'));
await reopened2(refused.opens);
await wait(400);
const a4 = await lab();
const moved4 = a4.pos;
await wait(800);
check('a refused mode or rectangle stops nothing, however it is set or opened', a4.state === 'PLAYING' && a4.modes.length === 0 && (await lab()).pos > moved4 && (await page.evaluate(() => window.capyPlayer.state)) === 'playing', says(a4.state, a4.modes));
await setLab({ modeRefused: '' });
await page.evaluate(() => { window.__avplay.setDisplayRect = window.__avplay.realRect; });

// What the <video> alone can do (the panel builds on the engine), kept apart from what plays now
await page.evaluate(() => { window.capyPlayer.engine = 'web'; });
await wait(150);
await page.keyboard.press('Escape');
await until('the panel to go', async () => (await panelRows()).length === 0);
check('Back closes the panel and the remote is back on its button', (await focusedLabel()) === 'Picture', await focusedLabel());
await page.keyboard.press('Enter');
await until('the panel', async () => (await panelRows()).length > 0);
check('the <video> offers Fill too', says(await panelRows()) === says(['Fit', 'Fill', 'Stretch', '16:9', '4:3', '21:9']), says(await panelRows()));
await page.keyboard.press('Escape');
await until('the panel to go', async () => (await panelRows()).length === 0);
await page.evaluate(() => { window.capyPlayer.engine = 'avplay'; });
await page.evaluate(() => localStorage.setItem('videoFit', 'cover'));
await page.keyboard.press('Enter');
await until('the panel', async () => (await panelRows()).length > 0);
await wait(200);
check('Fill kept from the <video> reads as Fit on AVPlay, what it plays as', (await focusedText()) === 'Fit', await focusedText());
await page.keyboard.press('Escape');
await until('the panel to go', async () => (await panelRows()).length === 0);

// ---- the subtitles' size and band --------------------------------------------------------------

const subStyle = () => page.evaluate(() => {
  const div = document.querySelector('.player-subtitle');
  const a = getComputedStyle(div);
  const b = getComputedStyle(div.querySelector('span'));
  return { size: parseFloat(a.fontSize), shadow: a.textShadow, band: b.backgroundColor };
});
const cueRule = (cls, prop) => page.evaluate(([c, p]) => {
  for (const sheet of Array.from(document.styleSheets)) for (const r of Array.from(sheet.cssRules || [])) {
    if (r.selectorText && r.selectorText.includes('video::cue') && r.selectorText.includes(c) && r.style[p]) return r.style[p];
  }
  return '';
}, [cls, prop]);
const bodyClasses = () => page.evaluate(() => document.body.className);

await page.evaluate(() => window.__avplay.listener.onsubtitlechange(600000, 'A line of text'));
await until('the line', () => page.locator('.player-subtitle').count().then((n) => n > 0));
await wait(100);
const plain = await subStyle();
check('as they were until told otherwise: 2.1rem, no band, a shadow', Math.abs(plain.size - 42) < 0.5 && plain.band === 'rgba(0, 0, 0, 0)' && plain.shadow !== 'none', says(plain));

await toDock('Audio & subtitles');
await page.keyboard.press('Enter');
await until('the panel', async () => (await panelRows()).length > 0);
await wait(200);
check('Size and band are rows under the tracks, with what is set', (await panelRows()).some((r) => r === 'Subtitle size 100 %') && (await panelRows()).some((r) => r === 'Subtitle background Off'), says(await panelRows()));
await toRow('Subtitle size');
await until('the size to change', async () => (await panelRows()).some((r) => r === 'Subtitle size 125 %'));
await wait(150); // the class goes on the body after the paint
const larger = await subStyle();
check('OK on the size makes the line on screen larger, and it is kept', Math.abs(larger.size - 52.5) < 0.5 && (await saved('subtitleScale')) === '125' && /subs-125/.test(await bodyClasses()), says(larger, await bodyClasses()));
check('and hls.js\'s lines take the same size', (await cueRule('.subs-125', 'fontSize')) === '2.625rem', await cueRule('.subs-125', 'fontSize'));
await toRow('Subtitle background');
await until('the band', async () => (await panelRows()).some((r) => r === 'Subtitle background On'));
await wait(150);
const banded = await subStyle();
check('OK on the band puts it behind the text, without the shadow, and it is kept', banded.band === 'rgba(0, 0, 0, 0.7)' && banded.shadow === 'none' && (await saved('subtitleBackground')) === 'true', says(banded));
// The rule's darkness is a variable Settings sets (0.7 when it is not): as written, not computed
check('on hls.js\'s lines too', /rgba\(0,\s*0,\s*0,\s*(0?\.7|var\(--subs-band,\s*0?\.7\))\)/.test(await cueRule('.subs-band', 'backgroundColor')), await cueRule('.subs-band', 'backgroundColor'));
await page.keyboard.press('ArrowUp');
await wait(90);
for (const value of ['150', '200', '75', '100']) {
  await page.keyboard.press('Enter');
  await until(`${value} %`, async () => (await panelRows()).some((r) => r === `Subtitle size ${value} %`));
}
await wait(150);
check('the sizes go round, back to the usual, which has no class of its own', (await saved('subtitleScale')) === '100' && !/subs-\d/.test((await bodyClasses()).replace('subs-100', '')), await bodyClasses());
await page.keyboard.press('Escape');
await until('the panel to go', async () => (await panelRows()).length === 0);
await page.evaluate(() => window.__avplay.listener.onsubtitlechange(0, ''));
await leavePlayer('Continue');

// ---- what AVPlay refuses ---------------------------------------------------------------------

const STREAM = `${ORIGIN}/hang.mp4`;
const NOT_SUPPORTED = 'PLAYER_ERROR_NOT_SUPPORTED_FILE';
const DAY = 86400000;
const tryOpen = (opts = {}) => page.evaluate(([u, o]) => window.capyPlayer.open(u, o).then(() => 'ok', (e) => `failed: ${e.message}`), [STREAM, opts]);
const marks = () => page.evaluate(() => JSON.parse(localStorage.getItem('player.webOnly') || '[]'));
const setMarks = (list) => page.evaluate((l) => localStorage.setItem('player.webOnly', JSON.stringify(l)), list);
const engine = () => page.evaluate(() => window.capyPlayer.engine);
const pageNow = () => page.evaluate(() => Date.now());
/** Opens it, and says what played it and how many times AVPlay was asked. */
const attempt = async (opts) => {
  const before = (await lab()).opens;
  const result = await tryOpen(opts);
  return { result, engine: await engine(), asked: (await lab()).opens - before };
};

await setLab({ refuse: 'PLAYER_ERROR_CONNECTION_FAILED', webOk: true });
let a = await attempt();
check('a passing failure of AVPlay plays on hls.js and marks nothing', a.result === 'ok' && a.engine === 'web' && (await marks()).length === 0, says(a));

await setLab({ refuse: NOT_SUPPORTED });
a = await attempt();
const [mark] = await marks();
check('what AVPlay cannot play is marked, with the date', a.result === 'ok' && !!mark && typeof mark.hash === 'string' && Math.abs(mark.at - (await pageNow())) < 60000, says({ a, mark }));

await setLab({ refuse: '' });
a = await attempt();
check('a marked stream goes straight to hls.js', a.result === 'ok' && a.engine === 'web' && a.asked === 0, says(a));

a = await attempt({ userAgent: 'Test/1' });
check('unless it needs its own User-Agent', a.result === 'ok' && a.engine === 'avplay' && a.asked === 1, says(a));

await setLab({ webOk: false });
a = await attempt();
check('hls.js failing on a marked stream takes the mark off and AVPlay plays it', a.result === 'ok' && a.engine === 'avplay' && a.asked === 1 && (await marks()).length === 0, says(a));

await setMarks([mark]);
await setLab({ refuse: 'PLAYER_ERROR_CONNECTION_FAILED' });
a = await attempt();
check('with both failing, AVPlay is asked once and it says so', a.result.startsWith('failed') && a.asked === 1 && (await marks()).length === 0, says(a));

await setLab({ refuse: '', webOk: true });
await setMarks([mark.hash, 'feedfeedfeedfeed']);
a = await attempt();
check('the plain hashes of earlier versions do no harm and hold nothing back', a.result === 'ok' && a.engine === 'avplay' && a.asked === 1, says(a));

await setMarks([{ hash: mark.hash, at: (await pageNow()) - 31 * DAY }]);
a = await attempt();
check('a mark over 30 days old has expired', a.result === 'ok' && a.engine === 'avplay' && a.asked === 1, says(a));

await setMarks([{ hash: mark.hash, at: (await pageNow()) - 29 * DAY }]);
a = await attempt();
check('one under 30 days still holds', a.result === 'ok' && a.engine === 'web' && a.asked === 0, says(a));

await setMarks([]);
await setLab({ refuse: NOT_SUPPORTED, refuseBy: 'listener' });
a = await attempt();
check('it is marked too when the refusal comes through the listener', a.result === 'ok' && a.engine === 'web' && (await marks()).length === 1, says(a));

// The fit on the <video>: straight after a change, and put back by every open
const box = () => page.evaluate(() => { const s = document.querySelector('video').style; return [s.objectFit, s.left, s.top, s.width, s.height].join(' ').trim(); });
const fitTo = (f) => page.evaluate((v) => window.capyPlayer.setFit(v), f);
await setLab({ refuse: '', refuseBy: 'callback', webOk: true });
await fitTo('cover');
check('Fill zooms the <video>', (await box()) === 'cover 0px 0px 1920px 1080px', await box());
await page.evaluate(() => { document.querySelector('video').style.objectFit = 'unset'; });
a = await attempt();
check('and every open puts the fit back', a.engine === 'web' && (await box()) === 'cover 0px 0px 1920px 1080px', says(a, await box()));
await fitTo('4:3');
check('a shape of its own is a box of that shape', (await box()) === 'fill 240px 0px 1440px 1080px', await box());
await fitTo('fill');
check('Stretch', (await box()) === 'fill 0px 0px 1920px 1080px', await box());
await fitTo('contain');
check('Fit is the <video>\'s own way', (await box()) === '0px 0px 1920px 1080px', await box());
await fitTo(null);
check('and so is nothing picked', (await box()) === '0px 0px 1920px 1080px', await box());
await page.evaluate(() => window.capyPlayer.stop());

await films.close();

// ---- a live channel: the list of the queue, and My list -----------------------------------------

const liveContext = await chromium.launchPersistentContext(fs.mkdtempSync(path.join(os.tmpdir(), 'capytv-player-')), {
  channel: 'msedge',
  headless: true,
  viewport: { width: 1920, height: 1080 },
  locale: 'en-US',
});
page = liveContext.pages()[0] || (await liveContext.newPage());
await page.addInitScript(standIn, { duration: DURATION, origin: ORIGIN, live: true });
await page.goto(`${ORIGIN}/index.html`);
await until('Home', () => page.getByRole('heading', { name: 'Home' }).count().then((n) => n > 0));
await page.waitForTimeout(800);
for (let i = 0; i < 8; i++) {
  if (await page.evaluate(() => !!document.activeElement.closest('[data-rail]'))) break;
  await page.keyboard.press('ArrowLeft');
  await wait(120);
}
for (let i = 0; i < 3; i++) {
  await page.keyboard.press('ArrowDown');
  await wait(120);
}
await page.keyboard.press('Enter');

// A channel of the Live TV tab, opened with OK as any other
const channelCard = (n) => `Array.from(document.querySelectorAll('.f')).find((e) => e.offsetParent && /Channel ${n}(?!\\d)/.test(e.textContent))`;
await until('the channels', () => page.evaluate(`!!${channelCard(1)}`));
await page.evaluate(`${channelCard(1)}.focus()`);
await page.keyboard.press('Enter');
await until('the channel to play', async () => { const l = await lab(); return /\/5000\./.test(l.url) && l.pos >= 750; });

const listRows = () => page.evaluate(() => document.querySelectorAll('.player-panel [data-row]').length);
const listRow = () => page.evaluate(() => { const r = document.activeElement.closest('[data-row]'); return r ? Number(r.getAttribute('data-row')) : -1; });
const rowMarked = () => page.evaluate(() => !!document.activeElement.querySelector('svg.icon'));
const listScroll = () => page.evaluate(() => { const b = document.querySelector('.player-panel .vscroll'); return { top: b.scrollTop, height: b.scrollHeight, box: b.clientHeight }; });
const press = async (key, times = 1, gap = 60) => {
  for (let i = 0; i < times; i++) {
    await page.keyboard.press(key);
    await wait(gap);
  }
};
const openList = async () => {
  if (!(await controlsUp())) await press('Enter', 1, 200); // live, OK brings them up
  await toDock('Channels');
  await page.keyboard.press('Enter');
  await until('the list', async () => (await listRows()) > 0);
  await wait(300);
};
const closeList = async () => {
  await page.keyboard.press('Escape');
  await until('the list to go', async () => (await listRows()) === 0);
  await wait(150);
};

await openList();
const firstOpen = await listScroll();
check('the dock opens the list of the queue with the remote, the whole queue laid out', firstOpen.height >= CHANNELS * 120 && firstOpen.height < CHANNELS * 120 + 100, says(firstOpen));
check('of thousands, only the rows near the view are built', (await listRows()) <= 30, `${await listRows()} rows`);
check('the channel playing has the remote and is marked', (await listRow()) === 0 && (await rowMarked()), says(await listRow(), await rowMarked()));
check('a row says its number and name', /^1\s*Channel 1/.test(await focusedText()), await focusedText());
await until('the guide', () => page.evaluate(() => /Programme 1\b/.test(document.querySelector('.player-panel').innerText)), 15000);
check('and what is on now, once the guide is in', /Programme 1\b/.test(await focusedText()), await focusedText());

await press('ArrowDown');
await wait(200);
check('Down goes to the next channel, and the one left is not marked as playing', (await listRow()) === 1 && !(await rowMarked()), says(await listRow(), await rowMarked()));
await press('ArrowUp');
await wait(200);
check('Up comes back to it', (await listRow()) === 0 && (await rowMarked()), says(await listRow()));

await press('ArrowDown', 60, 45); // a key held down, each row ready before the next press
await wait(400);
check('held down, the remote goes on along the rows being built', (await listRow()) === 60, `on row ${await listRow()}`);
check('still only those near the view', (await listRows()) <= 30, `${await listRows()} rows`);
const moved = await listScroll();
check('and the list has scrolled to it', moved.top > 40 * 120 && moved.top < 60 * 120, says(moved));

const before60 = await lab();
await page.keyboard.press('Enter');
await until('the channel', async () => /\/5060\./.test((await lab()).url), 3000);
await until('the list to go', async () => (await listRows()) === 0);
await wait(250);
check('OK switches to that channel, without leaving the player', (await page.locator('.player-overlay').count()) === 1 && (await lab()).opens === before60.opens + 1, says((await lab()).opens, before60.opens));
check('and the remote is back on the button', (await focusedLabel()) === 'Channels', await focusedLabel());

await openList();
check('opened again, down the list, it is on the one playing', (await listRow()) === 60 && (await rowMarked()), says(await listRow()));
const reopenedAt = await listScroll();
check('with two channels above it, as it opens', Math.abs(reopenedAt.top - 58 * 120) < 2, says(reopenedAt));
check('with no more rows than before', (await listRows()) <= 30, `${await listRows()} rows`);
const unchanged = (await lab()).opens;
await closeList();
check('Back closes it, nothing changed', (await lab()).opens === unchanged && /\/5060\./.test((await lab()).url), says((await lab()).url));
await openList();
await page.keyboard.press('Enter');
await until('the list to go', async () => (await listRows()) === 0);
await wait(600); // a zap waits a moment before it opens
check('OK on the one playing closes the list and does not open it again', (await lab()).opens === unchanged, `${(await lab()).opens} opens, was ${unchanged}`);

await openList();
await press('ArrowDown', 200, 45); // past the end of the guide
await wait(400);
const unguided = await focusedText();
check('a channel the guide does not know shows just its name', /^261\s*Channel 261$/.test(unguided), unguided);
await closeList();

// ---- My list
const favorites = () => page.evaluate(() => JSON.parse(localStorage.getItem('library.p1') || '{}').favorites || []);
if (!(await controlsUp())) await press('Enter', 1, 200);
await toDock('Favorites');
await page.keyboard.press('Enter');
await until('it to be saved', async () => (await favorites()).length === 1);
await wait(150);
const fav = (await favorites())[0];
check('the dock adds the channel playing to My list', fav.kind === 'live' && fav.id === '5060', says(fav));
check('and says it is in it, with the remote still there', (await focusedLabel()) === 'In favorites', await focusedLabel());
await openList();
await press('ArrowDown', 1);
await wait(200);
await page.keyboard.press('Enter');
await until('the channel', async () => /\/5061\./.test((await lab()).url), 3000);
await wait(300);
if (!(await controlsUp())) await press('Enter', 1, 200);
await toDock('Favorites');
check('another channel is not in it, by the button', (await focusedLabel()) === 'Favorites', await focusedLabel());
await page.keyboard.press('Enter');
await until('it to be saved', async () => (await favorites()).length === 2);
await wait(150);
await page.keyboard.press('Enter');
await until('it to come off', async () => (await favorites()).length === 1);
check('pressed again it comes off, and the other stays', (await favorites())[0].id === '5060', says(await favorites()));
await wait(150);
check('and the button says so', (await focusedLabel()) === 'Favorites', await focusedLabel());

// Both engines refuse the channel switched to: the quiet retry hides it, the first time
const panelSays = () => page.evaluate(() => /isn.t playing right now/i.test(document.body.innerText));
await setLab({ refuse: 'PLAYER_ERROR_CONNECTION_FAILED', webOk: false });
await openList();
await press('ArrowDown', 1);
await wait(200);
const refusedAt = await lab();
await page.keyboard.press('Enter');
let panelEarly = false;
// Both read at once: the second no comes a moment after the second ask
const askedAgain = await until('it to be asked again', async () => {
  const now = await page.evaluate(() => ({ opens: window.__av.opens, panel: /isn.t playing right now/i.test(document.body.innerText) }));
  panelEarly = panelEarly || (now.panel && now.opens < refusedAt.opens + 2);
  return now.opens >= refusedAt.opens + 2;
}, 6000).catch(() => false);
check('a channel both engines refuse is asked again before anything is said', askedAgain && !panelEarly, says(askedAgain, panelEarly, (await lab()).opens, refusedAt.opens));
await until('the panel, after the second no', panelSays, 6000);
await setLab({ refuse: '', webOk: null });
await onPlay('Retry');
await page.keyboard.press('Enter');
await until('Retry to play it', async () => (await lab()).state === 'PLAYING' && !(await panelSays()), 8000);
await wait(600);

// A channel picked and the player left at once: its zap, still waiting, does not open it behind
await openList();
await press('ArrowDown', 1);
await wait(200);
const leaving = await lab();
await page.keyboard.press('Enter');
await page.keyboard.press('Escape');
await until('the player to close', async () => (await page.locator('.player-overlay').count()) === 0);
await wait(700);
check('a channel picked just before leaving does not start after', (await lab()).opens === leaving.opens && (await page.evaluate(() => window.capyPlayer.state)) === 'idle', says((await lab()).opens, leaving.opens, await page.evaluate(() => window.capyPlayer.state)));

await liveContext.close();

// ---- sent from another device, and what a series has in the player ------------------------------

const cryptoFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'capytv-crypto-')), 'crypto.mjs');
(await import('esbuild')).buildSync({ entryPoints: [path.join(WWW, '..', '..', 'src', 'sync', 'crypto.ts')], bundle: true, format: 'esm', platform: 'browser', outfile: cryptoFile, logLevel: 'error' });
const { SyncKeys } = await import(pathToFileURL(cryptoFile).href);
const castKeys = SyncKeys.random();
const sendHere = (to, ref, position, ago = 0) => {
  const key = `cast/${to}`;
  const id = castKeys.itemId(key);
  sync.items.push({ rev: ++sync.rev, id, payload: castKeys.seal(id, { v: 'cast-1', key, at: Date.now() - ago, data: { playlist: 'p1', ref, position, from: 'Phone' } }) });
};
const syncNow = () => page.evaluate(() => void document.dispatchEvent(new Event('visibilitychange')));
const episodeSent = (n) => ({ kind: 'episode', id: String(100 + n), title: `Chapter ${n}`, seriesId: '2001', seriesTitle: 'Show 1', season: 1, number: n, ext: 'mp4' });
const setPos = (ms) => page.evaluate((x) => { window.__avplay.pos = x; }, ms);
const wake = async () => {
  if (!(await controlsUp())) await page.keyboard.press('ArrowUp');
  await until('the controls', controlsUp, 3000);
  await wait(300);
};
const inPlayer = () => page.locator('.player-overlay').count().then((n) => n > 0);

const castContext = await chromium.launchPersistentContext(fs.mkdtempSync(path.join(os.tmpdir(), 'capytv-player-')), {
  channel: 'msedge',
  headless: true,
  viewport: { width: 1920, height: 1080 },
  locale: 'en-US',
});
page = castContext.pages()[0] || (await castContext.newPage());
await page.addInitScript(standIn, { duration: DURATION, origin: ORIGIN, account: { server: `${ORIGIN}/sync/`, email: 'a@test', token: 't', keys: castKeys.toJson() } });
await page.goto(`${ORIGIN}/index.html`);
await until('Home', () => page.getByRole('heading', { name: 'Home' }).count().then((n) => n > 0));
await until('the first sync', () => sync.asked > 0);
await wait(800);

sendHere('other', episodeSent(2), 30000);
await syncNow();
await wait(1500);
check('sent to another device, nothing happens here', !(await inPlayer()));
sendHere('tv1', episodeSent(2), 30000, 3 * 60000);
await syncNow();
await wait(1500);
check('sent minutes ago, it is not played now', !(await inPlayer()));

sendHere('tv1', episodeSent(2), 30000);
await syncNow();
await until('it to play', async () => { const l = await lab(); return /\/102\./.test(l.url) && l.state === 'PLAYING'; });
await until('its seek', async () => (await lab()).seeks.length > 0);
check('sent here it plays, from where it was there', Math.abs((await lab()).seeks[0] - 30000) < 1, says((await lab()).seeks));
await until('it to land', async () => (await lab()).inFlight === 0 && (await lab()).pos >= 30000);

await wake();
await toDock('Episodes');
await page.keyboard.press('Enter');
await until('the list', async () => (await listRows()) > 0);
await wait(300);
check('the dock lists the series\' episodes', (await listRows()) === 3, `${await listRows()} rows`);
check('the one playing has the remote and is marked', (await listRow()) === 1 && (await rowMarked()), says(await listRow()));
check('a row says which episode it is', /S1 · E2\s+Chapter 2/.test(await focusedText()), await focusedText());
await press('ArrowDown');
await wait(150);
await page.keyboard.press('Enter');
await until('the other episode', async () => { const l = await lab(); return /\/103\./.test(l.url) && l.state === 'PLAYING' && l.pos >= 750; });
check('OK plays that one, without leaving the player', await inPlayer());

await setLab({ streams: [{ type: 'VIDEO', index: 0, extra_info: '{"fourCC":"H264","Width":"1920","Height":"1080","Bit_rate":"4500000"}' }, { type: 'AUDIO', index: 1, extra_info: '{"fourCC":"AACL","channels":"6","sample_rate":"48000","bit_rate":"192000"}' }] });
const statsText = () => page.evaluate(() => { const b = document.querySelector('.player-stream-info'); return b ? b.innerText.replace(/\s+/g, ' ') : ''; });
check('the stream info is off to begin with', (await statsText()) === '');
await wake();
await toDock('Player settings');
await page.keyboard.press('Enter');
await until('the panel', async () => (await panelRows()).length > 0);
await wait(300);
check('the settings say what can be set', /Stream info Off/.test((await panelRows())[0]) && (await panelRows()).length === 4, says(await panelRows()));
await page.keyboard.press('Enter');
await until('the stream info', async () => (await statsText()) !== '');
const stats = await statsText();
check('stream info says what the engine tells', /1920×1080 · H264/.test(stats) && /AACL · 5\.1 · 48 kHz/.test(stats) && /AVPlay/.test(stats) && /4\.5 Mb\/s · 192 kb\/s/.test(stats), stats);

await setPos(10000);
await wait(350);
await press('ArrowDown');
await wait(150);
await page.keyboard.press('Enter');
await setPos(60000);
await wait(350);
await press('ArrowDown');
await wait(150);
await page.keyboard.press('Enter');
await wait(250);
const introMarked = () => page.evaluate(() => { const k = Object.keys(localStorage).find((x) => x.startsWith('intro/')); return k ? [k, JSON.parse(localStorage.getItem(k))] : null; });
const marked = await introMarked();
check('the intro is marked where the picture is, under Flutter\'s key', marked && marked[0] === 'intro/show 1' && Math.abs(marked[1].start - 10000) < 1500 && Math.abs(marked[1].end - 60000) < 1500, says(marked));
check('and the panel says so', /Mark start 0:1\d/.test((await panelRows())[1]) && /Mark end 1:0\d/.test((await panelRows())[2]), says(await panelRows()));
await page.keyboard.press('Escape');
await until('the panel to go', async () => (await panelRows()).length === 0);

const skipShows = () => page.getByText('Skip intro').count().then((n) => n > 0);
await setPos(70000);
await wait(400);
await hidden();
check('no offer past the intro', !(await skipShows()));
await setPos(20000);
await until('the offer', skipShows, 3000);
await until('it to take the remote', async () => (await focusedText()) === 'Skip intro', 3000);
check('in the intro it offers to skip it, with the remote', true);
const beforeSkip = await lab();
await page.keyboard.press('Enter');
await until('the seek', async () => (await lab()).seeks.length > beforeSkip.seeks.length, 3000);
check('OK goes to where the intro ends', Math.abs((await lab()).seeks.at(-1) - marked[1].end) < 1, says((await lab()).seeks));
await until('it to land', async () => (await lab()).inFlight === 0);
await wait(300);
check('and it is no longer offered', !(await skipShows()));

await wake();
await toDock('Episodes');
await page.keyboard.press('Enter');
await until('the list', async () => (await listRows()) > 0);
await wait(300);
await press('ArrowUp', 2, 120);
await page.keyboard.press('Enter');
await until('the first episode', async () => { const l = await lab(); return /\/101\./.test(l.url) && l.state === 'PLAYING' && l.pos >= 750; });
await setPos(20000);
await until('the offer', skipShows, 3000).catch(() => {});
check('another episode of the series offers it too', await skipShows());

await wake();
await toDock('Player settings');
await page.keyboard.press('Enter');
await until('the panel', async () => (await panelRows()).length > 0);
await wait(300);
await press('ArrowDown', 3, 120);
await page.keyboard.press('Enter');
await wait(250);
check('Clear forgets the marks', (await introMarked()) === null, says(await introMarked()));
check('and with nothing to clear the remote still has somewhere to go', /Mark end/.test(await (await press('ArrowUp'), wait(150), focusedText())), await focusedText());
await page.keyboard.press('Escape');
await until('the panel to go', async () => (await panelRows()).length === 0);
await wait(300);
check('and it is no longer offered', !(await skipShows()));

const castWhilePlaying = await lab();
sendHere('tv1', episodeSent(3), 0);
await syncNow();
await until('the episode sent', async () => { const l = await lab(); return /\/103\./.test(l.url) && l.state === 'PLAYING' && l.pos >= 500; });
check('sent while another plays, that one goes and this one takes its place', (await page.locator('.player-overlay').count()) === 1 && (await lab()).opens === castWhilePlaying.opens + 1, says((await lab()).opens, castWhilePlaying.opens));
check('from the start, as it was there', (await lab()).seeks.length === 0 || (await lab()).seeks.at(-1) === castWhilePlaying.seeks.at(-1), says((await lab()).seeks));

await castContext.close();
server.close();
console.log(failed ? `${failed} failed` : 'all passed');
process.exit(failed ? 1 : 0);
