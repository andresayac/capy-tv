// Packages, installs and drives the app on a Samsung TV in developer mode, from afar: the page is
// reached over the web inspector (sdb's debug mode), where its log is read and keys are pressed.
//
//   node scripts/tv.mjs package      build/CapyTV.wgt from build/www, signed (security profile $TIZEN_PROFILE)
//   node scripts/tv.mjs install      connects to $TV (the TV's address) and installs it
//   node scripts/tv.mjs start        launches it in debug mode and forwards the inspector port
//   node scripts/tv.mjs deploy       package + install + start
//   node scripts/tv.mjs seed [n]     adds the .env's provider n (default: unnumbered) as a playlist
//   node scripts/tv.mjs logs         the app's log (errors and what it chose to say)
//   node scripts/tv.mjs key <k>...   presses keys: left right up down enter back, keyCodes, or
//                                    focus:<text> to put the focus on the element showing that text
//   node scripts/tv.mjs eval <js>    evaluates JavaScript in the app
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const WWW = path.join(ROOT, 'build', 'www');
const WGT = path.join(ROOT, 'build', 'CapyTV.wgt');
const PORT_FILE = path.join(ROOT, 'build', 'inspector-port');
const TIZEN_HOME = process.env.TIZEN_SDK ?? path.join(process.env.USERPROFILE ?? process.env.HOME, 'tizen-studio');
const SDB = path.join(TIZEN_HOME, 'tools', process.platform === 'win32' ? 'sdb.exe' : 'sdb');
const TIZEN = path.join(TIZEN_HOME, 'tools', 'ide', 'bin', process.platform === 'win32' ? 'tizen.bat' : 'tizen');
const PROFILE = process.env.TIZEN_PROFILE ?? 'capy-tv';
const TV = process.env.TV ?? '';
const SERIAL = `${TV}:26101`;
const APP_ID = 'CapyTvApp1.CapyTV';
const KEYS = { left: 37, up: 38, right: 39, down: 40, enter: 13, back: 10009 };

function run(cmd, args) {
  // .bat files need a shell on Windows, which joins the arguments as they are: quote them
  if (cmd.endsWith('.bat')) {
    return execFileSync(`"${cmd}"`, args.map((a) => (/[\s=]/.test(a) ? `"${a}"` : a)), { encoding: 'utf8', shell: true });
  }
  return execFileSync(cmd, args, { encoding: 'utf8' });
}

function packageApp() {
  const stage = path.join(ROOT, 'build', 'package');
  fs.rmSync(stage, { recursive: true, force: true });
  // Source maps stay home: they only make the package bigger
  fs.cpSync(WWW, stage, { recursive: true, filter: (f) => !f.endsWith('.map') });
  run(TIZEN, ['cli-config', `profiles.path=${path.join(TIZEN_HOME + '-data', 'profile', 'profiles.xml')}`]);
  run(TIZEN, ['package', '-t', 'wgt', '-s', PROFILE, '--', stage]);
  const wgt = fs.readdirSync(stage).find((f) => f.endsWith('.wgt'));
  if (!wgt) throw new Error('no .wgt was produced');
  fs.renameSync(path.join(stage, wgt), WGT);
  console.log(`build/CapyTV.wgt (${Math.round(fs.statSync(WGT).size / 1024)} KB)`);
  // Beside the other releases (git-ignored): release/app/ for the apps, release/sync/ the server
  const release = path.join(ROOT, '..', 'release', 'tv');
  fs.mkdirSync(release, { recursive: true });
  fs.copyFileSync(WGT, path.join(release, 'CapyTV.wgt'));
  console.log('release/tv/CapyTV.wgt');
}

function connect() {
  if (!TV) throw new Error("Set TV to the TV's address (on the TV: Settings, Network), e.g. TV=192.168.1.20");
  run(SDB, ['connect', TV]);
}

function install() {
  connect();
  // `tizen install` wants the model name `sdb devices` lists, not the address
  const line = run(SDB, ['devices']).split(/\r?\n/).find((l) => l.startsWith(SERIAL));
  if (!line) throw new Error(`${SERIAL} is not connected`);
  const out = run(TIZEN, ['install', '-n', WGT, '-t', line.trim().split(/\s+/).pop()]);
  console.log(out.split(/\r?\n/).filter((l) => /install completed|error|fail/i.test(l)).join('\n'));
}

function start() {
  connect();
  try {
    run(SDB, ['-s', SERIAL, 'shell', '0', 'was_kill', APP_ID]);
  } catch {
    // Not running
  }
  const out = run(SDB, ['-s', SERIAL, 'shell', '0', 'debug', APP_ID]);
  const m = /port:\s*(\d+)/.exec(out);
  if (!m) throw new Error(`no inspector port in: ${out.trim()}`);
  run(SDB, ['-s', SERIAL, 'forward', `tcp:${m[1]}`, `tcp:${m[1]}`]);
  fs.writeFileSync(PORT_FILE, m[1]);
  console.log(`started; inspector on 127.0.0.1:${m[1]}`);
}

async function evaluate(expression) {
  const port = fs.readFileSync(PORT_FILE, 'utf8').trim();
  const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  const page = pages.find((p) => p.webSocketDebuggerUrl);
  if (!page) throw new Error('no inspectable page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((ok, fail) => {
    ws.onopen = ok;
    ws.onerror = () => fail(new Error('inspector connection failed'));
  });
  const reply = await new Promise((ok) => {
    ws.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      if (msg.id === 1) ok(msg);
    };
    ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true, awaitPromise: true } }));
  });
  ws.close();
  if (reply.result?.exceptionDetails) throw new Error(JSON.stringify(reply.result.exceptionDetails));
  return reply.result?.result?.value;
}

async function press(keys) {
  for (const k of keys) {
    if (k.startsWith('focus:')) {
      const found = await evaluate(`(function () {
        var text = ${JSON.stringify(k.slice(6))};
        var all = Array.prototype.slice.call(document.querySelectorAll('.screen:not(.hidden) .f, [data-layer] .f'));
        var el = all.filter(function (e) {
          return e.getAttribute('aria-label') === text || e.innerText.trim().split(String.fromCharCode(10))[0].trim() === text;
        })[0];
        if (el) el.focus();
        return !!el;
      })()`);
      if (!found) console.log(`nothing shows "${k.slice(6)}"`);
      continue;
    }
    const code = KEYS[k] ?? Number(k);
    // Chromium ignores keyCode in KeyboardEvent's init, so it is defined on the event itself
    await evaluate(`(function () {
      var e = new KeyboardEvent('keydown', { bubbles: true });
      Object.defineProperty(e, 'keyCode', { get: function () { return ${code}; } });
      // At what has the focus, as a remote's: at the document, listeners there would run out of
      // order on the TV's Chromium, and the side rail's own keys would never be seen
      (document.activeElement || document).dispatchEvent(e);
    })()`);
    await new Promise((ok) => setTimeout(ok, 350));
  }
}

/** The .env's provider n as a playlist, added on the TV without its password going through a shell. */
async function seed(n) {
  const env = {};
  for (const line of fs.readFileSync(path.join(ROOT, '..', '.env'), 'utf8').split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (m) env[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2');
  }
  const s = n ? `_${n}` : '';
  const playlist = {
    id: `env${(n || '0').padStart(29, '0')}`,
    name: `Provider ${n || ''}`.trim(),
    type: 'xtream',
    url: env[`XTREAM_CODE${s}`],
    username: env[`XTREAM_USERNAME${s}`],
    password: env[`XTREAM_PASSWORD${s}`],
    members: [],
  };
  if (!playlist.url || !playlist.username || !playlist.password) throw new Error(`provider${s} is incomplete in .env`);
  const json = JSON.stringify(JSON.stringify(playlist));
  await evaluate(`(function () {
    var list = JSON.parse(localStorage.getItem('playlists') || '[]');
    var p = JSON.parse(${json});
    list = list.filter(function (x) { return x.id !== p.id; }).concat([p]);
    localStorage.setItem('playlists', JSON.stringify(list));
    location.reload();
  })()`);
  console.log(`${playlist.name} added; the app reloads`);
}

const [cmd, ...rest] = process.argv.slice(2);
switch (cmd) {
  case 'package': packageApp(); break;
  case 'install': install(); break;
  case 'start': start(); break;
  case 'deploy': packageApp(); install(); start(); break;
  case 'seed': await seed(rest[0]); break;
  case 'logs': console.log(await evaluate("(window.capyLog || []).join('\\n')")); break;
  case 'key': await press(rest); break;
  case 'eval': console.log(await evaluate(rest.join(' '))); break;
  default:
    console.log('usage: node scripts/tv.mjs package | install | start | deploy | logs | key <k>... | eval <js>');
}
