// The TV guide from XMLTV (app/lib/data/epg.dart): programmes per channel id, sorted by start.
// The XML (tens or hundreds of MB, often gzipped) streams into a worker (src/workers/xmltv.ts) as
// it downloads, which keeps only the window around now; that compact form is what the TV keeps,
// not the XML, so a stale copy costs little to hold and to read back. It is the provider's guide,
// whatever playlist reads it: what a playlist makes of it (channels found by name, times moved) is
// worked out as it is read (EpgGuide.matched), so a guideShift changed on the phone counts without
// downloading the guide again, and two playlists with one guide each read it their way.
import { language } from '../i18n';
import { log } from '../log';
import { Notifier } from '../ui/components';
import { cacheAge, pruneCache, readCacheParts, writeCache } from './cache';
import { EpgEntry } from './source';
import { guideName } from './titles';

const key = (id: string) => id.trim().toLowerCase();

/** One programme as the worker sends it: [start ms, end ms, title, description]. */
export type Programme = [number, number, string, string];

/**
 * A playlist's channel as its guide is read (app/lib/data/epg.dart GuideChannels): the guide id it
 * goes by; its names, by which the guide's own names for its channels find it when the guide does
 * not have that id; and how far its times move.
 */
export interface GuideChannel {
  /** Its tvg-id or epg_channel_id; with none, its name (as its LiveChannel.epgId). */
  id: string;
  /** Its names: the list's, and an M3U's tvg-name. */
  names: string[];
  /** Minutes its times move: M3U's tvg-shift. */
  shift?: number;
}

/**
 * M3U's tvg-shift (app/lib/data/epg.dart parseTvgShift): hours, maybe with a fraction ("-5",
 * "+1.5", "5,5"), as minutes; 0 when it is not one.
 */
export function parseTvgShift(raw?: string): number {
  const s = (raw || '').trim().replace(',', '.').replace(/^\+/, '');
  if (!/^[-+]?(\d+\.?\d*|\.\d+)(e[-+]?\d+)?$/i.test(s)) return 0;
  const hours = parseFloat(s);
  if (Math.abs(hours) > 24) return 0;
  // Halves away from zero, as Dart rounds; never a -0
  return Math.round(Math.abs(hours) * 60) * (hours < 0 ? -1 : 1) || 0;
}

/**
 * A channel's guide id in a combined list's provider [part]: one that is only a number is that
 * provider's own, and is told apart from another's ("1~101"); one in words is shared
 * (app/lib/data/epg.dart, partEpgId).
 */
export function partEpgId(part: number, id: string | undefined): string | undefined {
  return id === undefined || !/^\s*\d+\s*$/.test(id) ? id : `${part}~${id.trim()}`;
}

export class EpgGuide {
  static empty = new EpgGuide({}, {});

  /**
   * What there is when the guide could not be downloaded and no copy was kept: as [empty], but a
   * screen can say so, and offer to try again, rather than "this channel has no guide".
   */
  static failed = new EpgGuide({}, {});

  /** This guide with its ids that are only a number as [part]'s own, as a combined list's channels say them. */
  numbersOf(part: number): EpgGuide {
    const programmes: Record<string, Programme[]> = {};
    const icons: Record<string, string> = {};
    const shifts: Record<string, number> = {};
    for (const k of Object.keys(this.programmes)) programmes[partEpgId(part, k) as string] = this.programmes[k];
    for (const k of Object.keys(this.icons)) icons[partEpgId(part, k) as string] = this.icons[k];
    for (const k of Object.keys(this.shifts)) shifts[partEpgId(part, k) as string] = this.shifts[k];
    return new EpgGuide(programmes, icons, null, shifts, this.shift);
  }

  /** Programmes made into entries, per channel, as they are asked for: most channels never are. */
  private entries: Record<string, EpgEntry[]> = {};

  /**
   * [named]: the guide's channels in its order, each [id, its names as guideName makes them]; null
   * in a copy kept by a version from before they were. [shifts]: how far each channel's times move,
   * in ms, by its id; [shift] for any other.
   */
  constructor(
    private programmes: Record<string, Programme[]>,
    readonly icons: Record<string, string>,
    private named: string[][] | null = null,
    private shifts: Record<string, number> = {},
    private shift = 0,
  ) {}

  /** [guides] as one; where two describe the same channel, the first one's, moved as that one moves it. */
  static merge(guides: EpgGuide[]): EpgGuide {
    if (guides.length === 1) return guides[0];
    if (guides.length && guides.every((g) => g === EpgGuide.failed)) return EpgGuide.failed;
    const programmes: Record<string, Programme[]> = {};
    const icons: Record<string, string> = {};
    const shifts: Record<string, number> = {};
    for (const g of guides) {
      for (const k of Object.keys(g.programmes)) {
        if (programmes[k]) continue;
        programmes[k] = g.programmes[k];
        const shift = g.shiftOf(k);
        if (shift) shifts[k] = shift;
      }
      for (const k of Object.keys(g.icons)) if (!icons[k]) icons[k] = g.icons[k];
    }
    return new EpgGuide(programmes, icons, null, shifts);
  }

  /** Whether it has the guide's names for its channels: a copy kept by an older version has not. */
  get withNames(): boolean {
    return this.named !== null;
  }

  /** How far [k]'s times move, in ms. */
  private shiftOf(k: string): number {
    const s = this.shifts[k];
    return typeof s === 'number' ? s : this.shift;
  }

  /**
   * This guide as a playlist with [channels] reads it (app/lib/data/epg.dart GuideChannels and its
   * scanner). A channel whose id the guide does not have (or that has none, and goes by its name)
   * takes the programmes and logo of the first channel of the guide that the guide gives one of its
   * names, alike only in case, accents and marks such as HD. Each channel's times move by its own
   * shift on top of [shift], the playlist's, in minutes. Without [channels] (they could not be had)
   * only [shift] counts. Names are made alike a thousand at a time, the remote's keys getting
   * through in between.
   */
  async matched(channels: GuideChannel[] | null, shift = 0): Promise<EpgGuide> {
    if (this === EpgGuide.empty || this === EpgGuide.failed) return this;
    const shifts: Record<string, number> = {};
    // Each id once, with the names of every channel that goes by it
    const namesOf = new Map<string, string[]>();
    for (const c of channels || []) {
      const k = key(c.id);
      if (!k) continue;
      if (c.shift) shifts[k] = (shift + c.shift) * 60000;
      const names = namesOf.get(k) || [];
      namesOf.set(k, names);
      for (const n of c.names) if (names.indexOf(n) < 0) names.push(n);
    }
    const named = this.named || [];
    const declared = new Set<string>();
    const first = new Map<string, number>(); // a name: where the first channel of the guide so named is
    named.forEach((c, at) => {
      declared.add(c[0]);
      for (let i = 1; i < c.length; i++) if (!first.has(c[i])) first.set(c[i], at);
    });
    // Without the guide's names (a copy kept by an older version) none is found by them
    if (!first.size) namesOf.clear();
    let programmes = this.programmes;
    let icons = this.icons;
    let made = 0;
    for (const [k, names] of namesOf) {
      if (this.programmes[k] || this.icons[k] || declared.has(k)) continue; // the guide has it
      let best = -1;
      for (const n of names) {
        if (++made % 1000 === 0) await new Promise((r) => setTimeout(r, 0));
        const at = first.get(guideName(n));
        if (at !== undefined && (best < 0 || at < best)) best = at;
      }
      if (best < 0) continue;
      const found = named[best][0];
      if (programmes === this.programmes) {
        programmes = Object.assign({}, this.programmes);
        icons = Object.assign({}, this.icons);
      }
      if (this.programmes[found]) programmes[k] = this.programmes[found];
      if (this.icons[found]) icons[k] = this.icons[found];
    }
    return new EpgGuide(programmes, icons, null, shifts, shift * 60000);
  }

  get isEmpty(): boolean {
    return !Object.keys(this.programmes).length;
  }

  /** Logo the guide declares for a channel; useful when the provider sends none. */
  iconOf(channelId?: string): string | undefined {
    return channelId ? this.icons[key(channelId)] : undefined;
  }

  has(channelId?: string): boolean {
    return !!channelId && !!(this.programmes[key(channelId)] || []).length;
  }

  forChannel(channelId?: string): EpgEntry[] {
    if (!channelId) return [];
    const k = key(channelId);
    const made = this.entries[k];
    if (made) return made;
    const raw = this.programmes[k];
    if (!raw) return [];
    const d = this.shiftOf(k);
    return (this.entries[k] = raw.map(([s, e, title, description]) => ({ title, description, start: new Date(s + d), end: new Date(e + d) })));
  }

  nowOn(channelId?: string, at = Date.now()): EpgEntry | undefined {
    return this.forChannel(channelId).filter((e) => isNow(e, at))[0];
  }

  /** What is on now followed by what comes next. */
  upcoming(channelId?: string, count = 6, at = Date.now()): EpgEntry[] {
    return this.forChannel(channelId)
      .filter((e) => e.end.getTime() > at)
      .slice(0, count);
  }

  /** Programmes overlapping [from, to). */
  between(channelId: string | undefined, from: number, to: number): EpgEntry[] {
    return this.forChannel(channelId).filter((e) => e.end.getTime() > from && e.start.getTime() < to);
  }
}

export function isNow(e: EpgEntry, at = Date.now()): boolean {
  return at >= e.start.getTime() && at < e.end.getTime();
}

/** How far into [e] we are, 0..1. */
export function epgProgress(e: EpgEntry, at = Date.now()): number {
  const total = e.end.getTime() - e.start.getTime();
  return total <= 0 ? 0 : Math.min(1, Math.max(0, (at - e.start.getTime()) / total));
}

// ---- the worker --------------------------------------------------------------------------------

/** What the worker made of a guide: its parts, and whether its end (</tv>) came. */
interface Parsed {
  parts: string[];
  complete: boolean;
}

interface Job {
  done: (parsed: Parsed) => void;
  fail: (e: Error) => void;
  /** Chunks sent and not yet read. */
  inflight: number;
  ended: boolean;
  /** Wakes the download once the worker caught up. */
  drained: (() => void) | null;
  watchdog: number;
}

/** Chunks sent ahead of the worker at most: the rest waits in the network, not in memory. */
const AHEAD = 4;
/** Silence from a worker that owes an answer this long means it is gone. */
const STUCK = 2 * 60 * 1000;

let worker: Worker | null = null;
let nextJob = 1;
const jobs: Record<number, Job> = {};

/**
 * The worker died, never loaded or stopped answering: the guides waiting on it fail (and end up
 * empty, or as their last copy) instead of waiting forever, and the next one starts a new worker.
 */
function lose(reason: string): void {
  log(`xmltv worker: ${reason}`);
  if (worker) worker.terminate();
  worker = null;
  for (const id of Object.keys(jobs)) {
    const job = jobs[Number(id)];
    delete jobs[Number(id)];
    clearTimeout(job.watchdog);
    job.fail(new Error(reason));
  }
}

/** Watches [job] while the worker owes it something. */
function watch(job: Job): void {
  clearTimeout(job.watchdog);
  if (job.inflight > 0 || job.ended) job.watchdog = window.setTimeout(() => lose('no answer'), STUCK);
}

function theWorker(): Worker {
  if (worker) return worker;
  const w = new Worker('xmltv-worker.js');
  w.onmessage = (e: MessageEvent) => {
    const m = e.data as { id: number; ack?: boolean; parts?: string[]; complete?: boolean; error?: string };
    const job = jobs[m.id];
    if (!job) return;
    if (m.ack) {
      job.inflight--;
      watch(job);
      const wake = job.drained;
      job.drained = null;
      if (wake) wake();
      return;
    }
    delete jobs[m.id];
    clearTimeout(job.watchdog);
    if (m.parts) job.done({ parts: m.parts, complete: !!m.complete });
    else job.fail(new Error(m.error || 'parse failed'));
  };
  w.onerror = (e: ErrorEvent) => {
    e.preventDefault();
    lose(e.message || 'failed to load');
  };
  w.onmessageerror = () => lose('unreadable answer');
  return (worker = w);
}

/** Feeds the worker what [next] reads, chunk by chunk, until null; resolves with the guide's parts. */
async function parseInWorker(next: () => Promise<Uint8Array | null>): Promise<Parsed> {
  const w = theWorker();
  const id = nextJob++;
  let failed: Error | null = null;
  const job: Job = { done: () => {}, fail: () => {}, inflight: 0, ended: false, drained: null, watchdog: 0 };
  const result = new Promise<Parsed>((resolve, reject) => {
    job.done = resolve;
    job.fail = (e) => {
      failed = e;
      reject(e);
      const wake = job.drained;
      job.drained = null;
      if (wake) wake();
    };
  });
  result.catch(() => {}); // thrown below, or returned
  jobs[id] = job;
  w.postMessage({ id, op: 'start', now: Date.now(), lang: language });
  try {
    for (;;) {
      const bytes = await next();
      if (failed) throw failed;
      if (!bytes) break;
      // Handed over, not copied: a chunk that shares its buffer is copied first
      const own = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength ? bytes : bytes.slice();
      job.inflight++;
      watch(job);
      w.postMessage({ id, op: 'chunk', bytes: own }, [own.buffer as ArrayBuffer]);
      if (job.inflight >= AHEAD) await new Promise<void>((wake) => (job.drained = wake));
      if (failed) throw failed;
    }
    job.ended = true;
    watch(job);
    w.postMessage({ id, op: 'end' });
  } catch (e) {
    if (jobs[id]) {
      delete jobs[id];
      clearTimeout(job.watchdog);
      w.postMessage({ id, op: 'cancel' });
    }
    throw e;
  }
  return result;
}

/** No answer for this long, before it starts or between two pieces of it, and the download is given up. */
const TIMEOUT = 60000;

/** Downloads [url] straight into the worker; null when the server answers other than 200. */
async function downloadGuide(url: string, stop?: AbortSignal): Promise<Parsed | null> {
  const abort = new AbortController();
  // Its playlist left: the download stops, and with it the parse in the worker
  const stopped = () => abort.abort();
  if (stop) stop.addEventListener('abort', stopped);
  let timer = 0;
  const wait = () => {
    clearTimeout(timer);
    timer = window.setTimeout(() => abort.abort(), TIMEOUT);
  };
  wait();
  try {
    const res = await fetch(url, { signal: abort.signal });
    if (res.status !== 200) return null;
    const reader = res.body ? res.body.getReader() : null;
    let whole: Uint8Array | null = reader ? null : new Uint8Array(await res.arrayBuffer());
    return await parseInWorker(async () => {
      if (!reader) {
        const all = whole;
        whole = null;
        return all;
      }
      wait();
      const r = await reader.read();
      return r.done || !r.value ? null : r.value;
    });
  } finally {
    clearTimeout(timer);
    if (stop) stop.removeEventListener('abort', stopped);
    abort.abort(); // a download given up midway stops here; a finished one is not affected
  }
}

/** The guide from the worker's parts, one per task: the remote's keys get through in between. */
async function fromParts(parts: string[]): Promise<EpgGuide> {
  const programmes: Record<string, Programme[]> = {};
  const icons: Record<string, string> = {};
  let named: string[][] | null = null;
  for (let i = 0; i < parts.length; i++) {
    if (i) await new Promise((r) => setTimeout(r, 0));
    const part = JSON.parse(parts[i]) as { p?: Record<string, Programme[]>; i?: Record<string, string>; n?: string[][] };
    if (part.p) for (const k of Object.keys(part.p)) programmes[k] = part.p[k];
    if (part.i) for (const k of Object.keys(part.i)) icons[k] = part.i[k];
    if (part.n) {
      if (!named) named = [];
      for (const c of part.n) named.push(c);
    }
  }
  return new EpgGuide(programmes, icons, named);
}

/** The copy kept under [cacheKey]; null without one (or one kept as XML by an older version). */
async function cachedGuide(cacheKey: string): Promise<EpgGuide | null> {
  const saved = await readCacheParts(cacheKey);
  if (!saved) return null;
  try {
    return await fromParts(saved.parts);
  } catch {
    return null;
  }
}

const MAX_AGE = 6 * 60 * 60 * 1000;

/** Older than [MAX_AGE] but not this, the copy kept is shown while the new one comes. */
const SHOWN_WHILE_RENEWED = 24 * 60 * 60 * 1000;

/**
 * Downloads (or reuses a fresh copy of) an XMLTV guide and parses it. Falls back to the stale
 * copy when the download fails, and to an empty guide when there is none. Never fails. [early]
 * gets a copy under a day old at once, to show while the new one downloads (as the app does).
 */
export async function loadXmltv(
  url: string,
  cacheKey: string,
  maxAge = MAX_AGE,
  stop?: AbortSignal,
  early?: (kept: EpgGuide) => void,
): Promise<EpgGuide> {
  if (stop && stop.aborted) return EpgGuide.empty;
  const age = await cacheAge(cacheKey);
  if (age !== null && age < maxAge) {
    pruneCache(cacheKey);
    const fresh = await cachedGuide(cacheKey);
    if (fresh && fresh.withNames) return fresh;
    // One kept by a version from before the guide's names were kept finds no channel by them: it is
    // downloaded again, and shown meanwhile
    if (fresh && early && !(stop && stop.aborted)) early(fresh);
  } else if (early && age !== null && age < SHOWN_WHILE_RENEWED) {
    const kept = await cachedGuide(cacheKey);
    if (kept && !(stop && stop.aborted)) early(kept);
  }
  let parsed: Parsed | null = null;
  try {
    parsed = await downloadGuide(url, stop);
  } catch (e) {
    log(`guide: ${(e as Error).message || e}`); // the last copy will do
  }
  if (stop && stop.aborted) return EpgGuide.empty; // nobody waits for it: not even the last copy is read
  // A web page, an empty answer or a guide with no programmes sent with a 200 (a panel rebuilding
  // its guide) is none: the copy there is stays, and the next load tries again
  if (parsed && parsed.parts.some((p) => p.indexOf('{"p"') === 0)) {
    // One cut short (no </tv>, a download that broke off) is not kept: shown only when there is no
    // copy, which otherwise stays, and the next load downloads it again
    if (parsed.complete) writeCache(cacheKey, parsed.parts);
    const kept = parsed.complete ? null : await cachedGuide(cacheKey);
    if (kept) {
      log('guide: cut short, the last copy stays');
      return kept;
    }
    try {
      return await fromParts(parsed.parts);
    } catch {
      // Cannot be, as the worker wrote them; the last copy, then
    }
  } else {
    pruneCache(cacheKey);
  }
  return (await cachedGuide(cacheKey)) || EpgGuide.failed;
}

/** The guide of the open playlist, loaded in the background; empty until then. */
export class GuideHolder extends Notifier {
  guide = EpgGuide.empty;
  /** Not yet in: a screen says "loading", not "this channel has no guide". */
  ready = false;
  private loading: Promise<void> | null = null;
  /** Stops the load under way, when its playlist is left. */
  private abort: AbortController | null = null;

  constructor(private load: (stop: AbortSignal, early: (kept: EpgGuide) => void) => Promise<EpgGuide>) {
    super();
  }

  /** Its playlist was left: the guide's download and parse stop, and nothing more is loaded. */
  stop(): void {
    if (this.abort) this.abort.abort();
    this.abort = null;
    this.stopped = true;
  }

  private stopped = false;

  private loadedAt = 0;

  /** Starts loading it, once. */
  start(): void {
    if (this.loading || this.stopped) return;
    this.loadedAt = Date.now();
    const abort = (this.abort = new AbortController());
    // A copy kept from earlier today shows while the new one comes: not an empty guide meanwhile
    const early = (kept: EpgGuide) => {
      if (abort.signal.aborted || this.ready) return;
      this.guide = kept;
      this.ready = true;
      this.notify();
    };
    this.loading = this.load(abort.signal, early).then(
      (g) => {
        if (abort.signal.aborted) return; // left meanwhile
        this.guide = g;
        this.ready = true;
        this.notify();
      },
      () => {
        if (abort.signal.aborted) return;
        this.loading = null; // asked again next time
        // A copy shown meanwhile stays: better than saying none came
        if (!this.ready || this.guide === EpgGuide.empty) this.guide = EpgGuide.failed;
        this.ready = true;
        this.notify();
      },
    );
  }

  /** Once more, after it could not be downloaded. */
  retry(): void {
    if (this.stopped) return;
    this.loading = null;
    this.ready = false;
    this.guide = EpgGuide.empty;
    this.notify();
    this.start();
  }

  /**
   * Loads it again when the one there is is older than [age] ms: back from standby after a night,
   * its programmes are over. The one there is stays on screen until the new one is in.
   */
  renewIfOlder(age: number): void {
    if (!this.loading || Date.now() - this.loadedAt < age) return;
    this.loading = null;
    this.start();
  }
}
