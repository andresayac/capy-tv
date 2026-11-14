// How fast each server starts a stream, by the hour of the day (app/lib/data/stream_stats.dart),
// learnt from what plays: a provider may be quick in the morning and crawl at night. With several
// copies of a title (two providers, or one with several servers), the player tries the one likely
// fastest first.
//
// Kept on this TV under the Flutter app's key and shape; a server is its address's host and port,
// nothing else is noted. Read on first use: localStorage needs no load at startup.

const KEY = 'streamStats';

/** Taken for a stream that never started: worse than any that did. */
const FAILURE = 30000;

/** For a server nothing is known about yet: like a fairly slow one, so a fast one known wins. */
const UNKNOWN = 6000;

const MOST = 50; // servers kept

type Hours = (number | null)[];

// Server → milliseconds to start, per hour of the day; null where nothing is known
let ms: Record<string, Hours> | null = null;
let saveTimer = 0;

function table(): Record<string, Hours> {
  if (ms) return ms;
  ms = {};
  try {
    const raw = localStorage.getItem(KEY);
    const j = raw ? JSON.parse(raw) : {};
    for (const k of Object.keys(j)) {
      const v = j[k];
      // Earlier versions noted a whole path or address when they could not read the server
      if (!Array.isArray(v) || k.indexOf('/') >= 0 || k.indexOf('\\') >= 0) continue;
      const hours: Hours = [];
      for (let h = 0; h < 24; h++) hours.push(typeof v[h] === 'number' && isFinite(v[h]) ? v[h] : null);
      ms[k] = hours;
    }
  } catch {
    ms = {}; // learnt again
  }
  return ms;
}

/** "host:port", the port filled in as Dart's Uri does (80, 443); nothing for anything else. */
function server(url: string): string {
  try {
    const u = new URL(url);
    if (!u.hostname) return '';
    const port = u.port ? Number(u.port) : u.protocol === 'http:' ? 80 : u.protocol === 'https:' ? 443 : 0;
    return `${u.hostname.replace(/^\[|\]$/g, '')}:${port}`;
  } catch {
    return '';
  }
}

function note(url: string, took: number, at: Date): void {
  const all = table();
  const key = server(url);
  if (!key) return; // nothing that says where it is from
  const keys = Object.keys(all);
  if (!all[key] && keys.length >= MOST) delete all[keys[0]];
  const hours = all[key] || (all[key] = new Array<number | null>(24).fill(null));
  const h = at.getHours();
  const old = hours[h];
  // Recent viewings count more: a provider that got better (or worse) shows it soon
  hours[h] = old === null ? took : old * 0.6 + took * 0.4;
  clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    try {
      localStorage.setItem(KEY, JSON.stringify(all));
    } catch {
      // Storage full: learnt again next time
    }
  }, 2000);
}

export const StreamStats = {
  /** The stream at [url] started after [took] ms, at [at] (now). */
  started(url: string, took: number, at: Date = new Date()): void {
    note(url, Math.max(0, took), at);
  },

  /** The stream at [url] did not start, at [at] (now). */
  failed(url: string, at: Date = new Date()): void {
    note(url, FAILURE, at);
  },

  /**
   * How long the server of [url] is likely to take at [at] (now), in ms: that hour, else the hours
   * around it, else any hour, else UNKNOWN.
   */
  expected(url: string, at: Date = new Date()): number {
    const hours = table()[server(url)];
    if (!hours) return UNKNOWN;
    const h = at.getHours();
    for (const d of [0, 1, 23, 2, 22]) {
      const v = hours[(h + d) % 24];
      if (v !== null) return Math.round(v);
    }
    const known = hours.filter((v): v is number => v !== null);
    if (!known.length) return UNKNOWN;
    return Math.round(known.reduce((a, b) => a + b, 0) / known.length);
  },

  /** [items] by how fast their servers are likely to start at [at] (now), fastest first; equals keep their order. */
  fastestFirst<T>(items: T[], url: (x: T) => string, at: Date = new Date()): T[] {
    return items
      .map((x, i) => ({ x, i, ms: StreamStats.expected(url(x), at) }))
      .sort((a, b) => (a.ms !== b.ms ? a.ms - b.ms : a.i - b.i))
      .map((e) => e.x);
  },

  /** Forgets everything learnt. */
  reset(): void {
    ms = {};
  },
};
