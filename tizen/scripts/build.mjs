// Builds the TV app into build/www: the bundle (for Chromium 69, Tizen 5.5's engine), the Flutter
// app's own strings (app/lib/l10n/*.arb), its Inter font, its profile avatars and the icons it uses.
//
//   node scripts/build.mjs          build/www
//   node scripts/build.mjs --watch  rebuild on every change
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

/**
 * The Flutter app's version (app/pubspec.yaml, "0.1.0+1" without the build number): the TV's goes
 * up with each release, which it needs to take an update over the app installed.
 */
function appVersion() {
  const pubspec = fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'app', 'pubspec.yaml'), 'utf8');
  const v = (/^version:\s*(\d+\.\d+\.\d+)/m.exec(pubspec) || [])[1];
  if (!v) throw new Error('app/pubspec.yaml has no version x.y.z');
  return v;
}

/** The version, and the commit when this is a git checkout. */
function build() {
  const version = appVersion();
  try {
    return `${version} · ${execSync('git rev-parse --short HEAD', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()}`;
  } catch {
    return version;
  }
}

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const REPO = path.join(ROOT, '..');
const OUT = path.join(ROOT, 'build', 'www');
const GEN = path.join(ROOT, 'src', 'gen');
const ICONS = path.join(ROOT, 'node_modules', '@material-symbols', 'svg-400', 'rounded');

/** Both languages of the Flutter app, without the ARB metadata. */
function strings() {
  const read = (lang) => {
    const arb = JSON.parse(fs.readFileSync(path.join(REPO, 'app', 'lib', 'l10n', `app_${lang}.arb`), 'utf8'));
    return Object.fromEntries(Object.entries(arb).filter(([k]) => !k.startsWith('@')));
  };
  return { en: read('en'), es: read('es') };
}

/**
 * The SVG path of every icon named in the sources: any string literal "name_rounded" or
 * "name_outlined", as Flutter names them ("_rounded" icons are the filled ones).
 */
/** Flutter's Material Icons names that Material Symbols calls otherwise. */
const RENAMED = { people: 'group', person_add_alt: 'person_add', expand_more: 'keyboard_arrow_down', phonelink: 'devices', emoji_events: 'trophy', auto_awesome: 'star_shine' };

function icons() {
  const used = new Set();
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (p !== GEN) walk(p);
      } else if (/\.tsx?$/.test(e.name)) {
        for (const m of fs.readFileSync(p, 'utf8').matchAll(/["']([a-z0-9_]+_(?:rounded|outlined))["']/g)) used.add(m[1]);
      }
    }
  };
  walk(path.join(ROOT, 'src'));
  const out = {};
  for (const name of [...used].sort()) {
    // Flutter's "x_border_rounded" is the outline of x; so is "x_outline_rounded" where Symbols has
    // no "x_outline" (delete_outline, people_outline)
    let outline = name.endsWith('_outlined') || /_border_rounded$/.test(name);
    let flutter = name.replace(/_(rounded|outlined)$/, '').replace(/_border$/, '');
    if (/_outline$/.test(flutter) && !fs.existsSync(path.join(ICONS, `${RENAMED[flutter] || flutter}.svg`))) {
      flutter = flutter.slice(0, -'_outline'.length);
      outline = true;
    }
    const base = RENAMED[flutter] || flutter;
    const file = path.join(ICONS, `${base}${outline ? '' : '-fill'}.svg`);
    const fallback = path.join(ICONS, `${base}.svg`);
    // A name Symbols lacks fails here, named, rather than as a bare ENOENT: add it to RENAMED
    if (!fs.existsSync(file) && !fs.existsSync(fallback)) throw new Error(`No Material Symbol for the icon "${name}" (${base}.svg): map it in RENAMED`);
    const svg = fs.readFileSync(fs.existsSync(file) ? file : fallback, 'utf8');
    out[name] = /<path d="([^"]+)"/.exec(svg)[1];
  }
  return out;
}

function generate() {
  fs.mkdirSync(GEN, { recursive: true });
  const write = (file, text) => {
    const p = path.join(GEN, file);
    if (!fs.existsSync(p) || fs.readFileSync(p, 'utf8') !== text) fs.writeFileSync(p, text);
  };
  write('strings.json', JSON.stringify(strings()));
  write('icons.json', JSON.stringify(icons()));
}

/** A value of the repo's .env (git-ignored), or ''. Never printed. */
function env(name) {
  try {
    for (const line of fs.readFileSync(path.join(REPO, '.env'), 'utf8').split(/\r?\n/)) {
      const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
      if (m && m[1] === name) return m[2].replace(/^(['"])(.*)\1$/, '$2');
    }
  } catch {
    // No .env: built without
  }
  return '';
}

function copyStatic() {
  fs.mkdirSync(path.join(OUT, 'fonts'), { recursive: true });
  for (const w of [400, 500, 600, 700, 800]) {
    fs.copyFileSync(path.join(REPO, 'app', 'assets', 'fonts', `Inter-${w}.ttf`), path.join(OUT, 'fonts', `Inter-${w}.ttf`));
  }
  fs.copyFileSync(path.join(ROOT, 'static', 'index.html'), path.join(OUT, 'index.html'));
  // With the app's version in place of the one written there
  const xml = fs.readFileSync(path.join(ROOT, 'static', 'config.xml'), 'utf8');
  fs.writeFileSync(path.join(OUT, 'config.xml'), xml.replace(/(<widget[^>]*\sversion=")[^"]+"/, `$1${appVersion()}"`));
  for (const name of ['icon', 'offline', 'account', 'error', 'empty', 'video']) {
    fs.copyFileSync(path.join(REPO, 'app', 'assets', 'branding', `capy-${name}.svg`), path.join(OUT, `capy-${name}.svg`));
    fs.copyFileSync(path.join(REPO, 'app', 'assets', 'branding', `capy-${name}.webp`), path.join(OUT, `capy-${name}.webp`));
  }
  fs.copyFileSync(
    path.join(REPO, 'app', 'android', 'app', 'src', 'main', 'res', 'mipmap-xxxhdpi', 'ic_launcher.png'),
    path.join(OUT, 'icon.png'),
  );
  // The profile avatars (app/assets/avatars), drawn by screens/profiles.tsx as <img src="avatars/NAME.svg">
  const avatars = path.join(REPO, 'app', 'assets', 'avatars');
  fs.mkdirSync(path.join(OUT, 'avatars'), { recursive: true });
  for (const f of fs.readdirSync(avatars)) {
    if (f.endsWith('.svg')) fs.copyFileSync(path.join(avatars, f), path.join(OUT, 'avatars', f));
  }
}

const options = {
  // The app, and the workers that parse XMLTV guides and big catalogs off the page's thread
  entryPoints: {
    app: path.join(ROOT, 'src', 'main.tsx'),
    'xmltv-worker': path.join(ROOT, 'src', 'workers', 'xmltv.ts'),
    'catalog-worker': path.join(ROOT, 'src', 'workers', 'catalog.ts'),
  },
  bundle: true,
  outdir: OUT,
  target: 'chrome69',
  format: 'iife',
  jsx: 'automatic',
  jsxImportSource: 'preact',
  sourcemap: 'linked',
  minify: !process.argv.includes('--watch'),
  legalComments: 'none',
  // The TMDB key, as the Flutter app takes it with --dart-define (the user's own, free tier)
  // and the sync server the sign-in form starts with, as Flutter takes SYNC_SERVER
  define: {
    // "0.1.0 · 7a7963b": the app's version and the commit it was built from, for About
    __BUILD__: JSON.stringify(build()),
    __TMDB_KEY__: JSON.stringify(env('TMDB_API_KEY')),
    __SYNC_SERVER__: JSON.stringify(process.env.SYNC_SERVER || env('SYNC_SERVER')),
    // The language model built in, as Flutter takes AI_MODEL, AI_BASE_URL and AI_API_KEY (config.ts)
    __AI_MODEL__: JSON.stringify(process.env.AI_MODEL || env('AI_MODEL')),
    __AI_BASE_URL__: JSON.stringify(process.env.AI_BASE_URL || env('AI_BASE_URL')),
    __AI_API_KEY__: JSON.stringify(process.env.AI_API_KEY || env('AI_API_KEY')),
  },
  logLevel: 'info',
  plugins: [
    {
      name: 'generated',
      setup(build) {
        build.onStart(() => {
          generate();
          copyStatic();
        });
      },
    },
  ],
};

generate();
if (process.argv.includes('--watch')) {
  const ctx = await esbuild.context(options);
  await ctx.watch();
} else {
  await esbuild.build(options);
}
