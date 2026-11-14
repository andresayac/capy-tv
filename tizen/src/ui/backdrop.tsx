// The background of the screens outside a playlist (app/lib/ui/backdrop.dart): a wall of posters
// drifting slowly upwards (data/poster_wall.ts) under a dark veil that keeps text legible. In hero
// mode, the welcome screen and the screensaver, this week's trending backdrops follow one another
// instead, each slowly coming closer; with none, the wall. Plain black until there is anything to
// show. The screen given as children goes over it, see-through.
import { ComponentChildren } from 'preact';
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks';
import { posterWall } from '../data/poster_wall';
import { Trend, trending } from '../data/trending';
import { t } from '../i18n';
import { useNotifier } from './components';
import { useOnTop } from './router';

/** Dark enough for muted text on the brightest posters, light enough to tell them apart (0xC7). */
const VEIL = 'rgba(0,0,0,0.78)';
/** The backdrops are larger and calmer than a wall of posters, and the welcome screen has less on it (0xB0). */
export const HERO_VEIL = 'rgba(0,0,0,0.69)';

const fill = { position: 'absolute', left: 0, top: 0, right: 0, bottom: 0 } as const;

/**
 * [children] over the poster wall; with [hero], over the trending slides (the wall when there are
 * none) under [slideVeil].
 */
export function PosterBackdrop({ children, hero = false, slideVeil = HERO_VEIL }: { children: ComponentChildren; hero?: boolean; slideVeil?: string }) {
  useNotifier(posterWall); // the trends and the provider's posters
  const slides = hero ? trending.items.filter((x) => x.backdrop && x.mature === false) : [];
  const posters = slides.length ? [] : posterWall.wall;
  return (
    <div style={{ position: 'relative', width: '100%', height: '100%', background: 'var(--black)' }}>
      {slides.length > 0 && <Slides trends={slides} veil={slideVeil} />}
      {posters.length > 0 && <Wall urls={posters} />}
      {posters.length > 0 && <div style={{ ...fill, background: VEIL }} />}
      <div style={fill}>{children}</div>
    </div>
  );
}

/** The welcome screen's and the screensaver's: the trending slides under [veil], else the wall. */
export function Backdrop({ children, veil = HERO_VEIL }: { children: ComponentChildren; veil?: string }) {
  return (
    <PosterBackdrop hero slideVeil={veil}>
      {children}
    </PosterBackdrop>
  );
}

// ---- wall ------------------------------------------------------------------------------------

const GAP = 6; // dp

/** TMDB posters at the size a wall needs: the TV's memory holds forty of these, not of full ones. */
function small(url: string): string {
  return url.replace(/^(https?:\/\/image\.tmdb\.org\/t\/p\/)[^/]+\//, '$1w342/');
}

/** A shuffle that is the same all day: [seed] picks the order. */
function shuffled<T>(list: T[], seed: number): T[] {
  const out = list.slice();
  let s = seed >>> 0;
  const random = () => {
    // mulberry32
    s = (s + 0x6d2b79f5) >>> 0;
    let x = Math.imul(s ^ (s >>> 15), 1 | s);
    x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    const x = out[i];
    out[i] = out[j];
    out[j] = x;
  }
  return out;
}

/**
 * Posters about 150 dp wide in columns, each drifting upwards at its own pace and coming round
 * again, filling the space. The same ones come back when there are fewer than places; the order
 * changes once a day. Each column is painted once and moved by the compositor, and stops while
 * another screen covers this one.
 */
function Wall({ urls }: { urls: string[] }) {
  const box = useRef<HTMLDivElement>(null);
  const top = useOnTop();
  const animations = useRef<Animation[]>([]);
  const signature = urls.join('\n');
  // In dp, as Flutter lays it out: the screen this fills, the TV's 960x540 when it cannot be measured
  const [size, setSize] = useState<{ w: number; h: number; px: number } | null>(null);
  useLayoutEffect(() => {
    const px = parseFloat(getComputedStyle(document.documentElement).fontSize) / 10 || 2;
    const el = box.current;
    const w = el && el.offsetWidth ? el.offsetWidth / px : 960;
    const h = el && el.offsetHeight ? el.offsetHeight / px : 540;
    setSize({ w, h, px });
  }, []);

  const layout = useMemo(() => {
    if (!size) return null;
    const today = Math.floor((Date.now() - new Date(2020, 0, 1).getTime()) / 86400000);
    const posters = shuffled(urls.map(small), today);
    const columns = Math.max(4, Math.ceil(size.w / 150));
    const width = (size.w - GAP * (columns - 1)) / columns;
    const height = width * 1.5;
    // Enough per column to cover the screen while a whole round of them goes by
    const perColumn = Math.ceil(size.h / (height + GAP)) + 1;
    const round = perColumn * (height + GAP);
    const cols: { left: number; speed: number; start: number; posters: string[] }[] = [];
    for (let c = 0; c < columns; c++) {
      const list: string[] = [];
      // Twice, so the second round follows the first without a seam
      for (let r = 0; r < perColumn * 2; r++) list.push(posters[(c * perColumn + (r % perColumn)) % posters.length]);
      // Between 5 and 11 dp a second, the columns set off from each other
      cols.push({ left: c * (width + GAP), speed: 5 + ((c * 7) % 4) * 2, start: ((c % 3) * height) / 3 + c * 37, posters: list });
    }
    return { width, height, round, cols };
  }, [size, signature]);

  // Each column a whole round upwards, over and over, from where it sets off
  useLayoutEffect(() => {
    const el = box.current;
    if (!el || !layout || !size || typeof el.animate !== 'function') return;
    const columns = el.querySelectorAll<HTMLElement>('[data-column]');
    const list: Animation[] = [];
    layout.cols.forEach((c, i) => {
      const column = columns[i];
      if (!column) return;
      const ms = (layout.round / c.speed) * 1000;
      const a = column.animate([{ transform: 'translate3d(0,0,0)' }, { transform: `translate3d(0,${-layout.round * size.px}px,0)` }], {
        duration: ms,
        iterations: Infinity,
      });
      a.currentTime = ((c.start % layout.round) / c.speed) * 1000;
      list.push(a);
    });
    animations.current = list;
    return () => {
      list.forEach((a) => a.cancel());
      animations.current = [];
    };
  }, [layout]);

  // Still while covered, as Flutter's ticker
  useEffect(() => {
    animations.current.forEach((a) => (top ? a.play() : a.pause()));
  }, [top, layout]);

  return (
    <div ref={box} style={{ ...fill, overflow: 'hidden' }}>
      {layout &&
        layout.cols.map((c, i) => (
          <div key={i} data-column style={{ position: 'absolute', left: `${c.left / 10}rem`, top: 0, width: `${layout.width / 10}rem`, willChange: 'transform' }}>
            {c.posters.map((url, r) => (
              <div key={r} style={{ height: `${layout.height / 10}rem`, marginBottom: `${GAP / 10}rem`, borderRadius: '0.6rem', overflow: 'hidden', background: 'var(--surface)' }}>
                <img
                  src={url}
                  style={{ display: 'block', width: '100%', height: '100%', objectFit: 'cover', opacity: 0, transition: 'opacity 400ms' }}
                  // Painted by hand, not by props: re-renders keep what loaded (a new address reuses the img)
                  onLoad={(e) => {
                    const img = e.currentTarget as HTMLImageElement;
                    img.style.opacity = '1';
                    img.style.visibility = '';
                  }}
                  onError={(e) => ((e.currentTarget as HTMLImageElement).style.visibility = 'hidden')}
                />
              </div>
            ))}
          </div>
        ))}
    </div>
  );
}

// ---- slides ----------------------------------------------------------------------------------

const SHOWN = 8000;
const FADE = 1200;
const TIMEOUT = 20000;

// What each backdrop came to: on its way or fetched. One that could not be had is tried again
const loads: Record<string, Promise<boolean>> = {};

/** Fetches [url] into the HTTP cache; false when it cannot be had within [TIMEOUT]. */
function fetchImage(url: string): Promise<boolean> {
  const known = loads[url];
  if (known) return known;
  const p = new Promise<boolean>((resolve) => {
    const img = new Image();
    const done = (ok: boolean) => {
      clearTimeout(timer);
      img.onload = img.onerror = null;
      if (!ok) {
        img.src = '';
        delete loads[url];
      }
      resolve(ok);
    };
    const timer = window.setTimeout(() => done(false), TIMEOUT);
    img.onload = () => done(true);
    img.onerror = () => done(false);
    img.src = url;
  });
  return (loads[url] = p);
}

interface Shown {
  index: number; // grows past the list's length: the next is index + 1
  trend: Trend;
}

/**
 * The trending backdrops, one after another: each comes slowly closer for a few seconds, then fades
 * into the next, which is fetched before it is due. A slide shows only once its image is here, one
 * that cannot be fetched is skipped, and its seconds count from then, only while on top. A line in
 * a corner says what it is.
 */
function Slides({ trends, veil }: { trends: Trend[]; veil: string }) {
  const top = useOnTop();
  const list = useRef(trends);
  list.current = trends;
  const [want, setWant] = useState(0);
  const [slides, setSlides] = useState<{ cur: Shown | null; prev: Shown | null }>({ cur: null, prev: null });
  const cur = slides.cur;

  // Shows slide [want] once its image is here; one that cannot be fetched is skipped
  useEffect(() => {
    let live = true;
    (async () => {
      for (let tries = 0, i = want; tries < list.current.length; tries++, i++) {
        const all = list.current;
        const trend = all[i % all.length];
        const ok = await fetchImage(trend.backdrop!);
        if (!live) return;
        if (!ok) continue;
        setSlides((s) => ({ cur: { index: i, trend }, prev: s.cur }));
        return;
      }
    })();
    return () => {
      live = false;
    };
  }, [want]);

  // Its time, counted while this screen is on top; the next backdrop is fetched meanwhile
  const spent = useRef<{ of: Shown | null; ms: number }>({ of: null, ms: 0 });
  useEffect(() => {
    if (!top || !cur || list.current.length < 2) return;
    if (spent.current.of !== cur) spent.current = { of: cur, ms: 0 };
    const all = list.current;
    fetchImage(all[(cur.index + 1) % all.length].backdrop!);
    const started = Date.now();
    const timer = window.setTimeout(() => setWant(cur.index + 1), Math.max(0, SHOWN - spent.current.ms));
    return () => {
      clearTimeout(timer);
      if (spent.current.of === cur) spent.current.ms += Date.now() - started;
    };
  }, [top, cur]);

  const prev = slides.prev;
  const tr = cur && cur.trend;
  return (
    <div style={{ ...fill, overflow: 'hidden' }}>
      {/* The one fading out under the one coming in */}
      {prev && <Slide key={prev.index} url={prev.trend.backdrop!} toLeft={prev.index % 2 === 0} on={false} />}
      {cur && <Slide key={cur.index} url={cur.trend.backdrop!} toLeft={cur.index % 2 === 0} on />}
      {cur && <div style={{ ...fill, background: veil }} />}
      {cur && tr && (
        <div key={cur.index} class="fade-in" style={{ position: 'absolute', left: '4.8rem', right: '4.8rem', bottom: '2.8rem' }}>
          <div class="muted" style={{ fontSize: 'calc(1.1rem * var(--text-scale))', fontWeight: 700, letterSpacing: '0.12rem' }}>{(tr.series ? t('trendingSeries') : t('trendingMovie')).toUpperCase()}</div>
          <div class="ellipsis" style={{ fontWeight: 600, marginTop: '0.4rem' }}>
            {[tr.title, tr.year ? String(tr.year) : '', (tr.rating || 0) > 0 ? `★ ${tr.rating!.toFixed(1)}` : ''].filter(Boolean).join('  ·  ')}
          </div>
        </div>
      )}
    </div>
  );
}

/**
 * One backdrop, already fetched: fades in, and comes closer and sideways over 11 s, longer than it
 * shows, so it still moves while it fades out (when [on] goes).
 */
function Slide({ url, toLeft, on }: { url: string; toLeft: boolean; on: boolean }) {
  const img = useRef<HTMLImageElement>(null);
  const top = useOnTop();
  const moves = useRef<Animation[]>([]);
  // Before it is first painted, so it does not flash in whole
  useLayoutEffect(() => {
    const el = img.current;
    if (!el || typeof el.animate !== 'function') return;
    moves.current = [
      el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: FADE, easing: 'ease', fill: 'forwards' }),
      el.animate([{ transform: 'scale(1.04)' }, { transform: 'scale(1.14)' }], { duration: 11000, easing: 'cubic-bezier(0, 0, 0.58, 1)', fill: 'forwards' }),
    ];
  }, []);
  useEffect(() => {
    const el = img.current;
    if (on || !el || typeof el.animate !== 'function') return;
    const from = getComputedStyle(el).opacity;
    moves.current.push(el.animate([{ opacity: from }, { opacity: 0 }], { duration: FADE, easing: 'ease', fill: 'forwards' }));
  }, [on]);
  // Still while another screen covers this one, as Flutter's tickers: the zoom goes on from where
  // it was. Only the running ones: play() starts a finished one over
  useEffect(() => {
    moves.current.forEach((a) => {
      if (!top && a.playState === 'running') a.pause();
      else if (top && a.playState === 'paused') a.play();
    });
  }, [top]);
  return (
    <img
      ref={img}
      src={url}
      style={{ ...fill, width: '100%', height: '100%', objectFit: 'cover', transformOrigin: toLeft ? 'left center' : 'right center' }}
    />
  );
}
