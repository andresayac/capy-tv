// Favorites and watch history of one playlist for one profile (app/lib/data/library.dart), stored
// the same way and merged by the same rules, so sync moves them between the two apps unchanged.
//
// Two devices can change the same library apart and merge later, so every change carries a time:
// favorites keep when they were added, and removing a favorite, forgetting an item or clearing
// the history leave a dated marker instead of just vanishing. For each item the latest event
// wins, which makes merging give the same result in any order.
import { t } from '../i18n';
import { toast } from '../ui/router';
import { deviceName, isThisDevice } from '../platform/tv';
import { Notifier } from '../ui/components';
import { keepsOver } from './keeps_over';
import { cleanEpisodeTitle, Episode, Movie, Series } from './models';
import { LiveChannel } from './source';

let storageTold = false;

export type MediaKind = 'live' | 'movie' | 'series' | 'episode';

/** The profile whose libraries are the ones from before there were profiles. */
export const mainProfileId = 'main';

/**
 * Just enough about an item to show it again and rebuild its stream URL later. Ids belong to the
 * provider; tmdb, year and epg find the same title or channel with another one.
 */
export interface MediaRef {
  kind: MediaKind;
  id: string;
  title: string;
  image?: string;
  ext?: string;
  url?: string;
  seriesId?: string; // episodes only
  seriesTitle?: string;
  season?: number;
  number?: number;
  tmdb?: string;
  year?: number;
  epg?: string;
}

export const refKey = (r: MediaRef) => `${r.kind}:${r.id}`;

/** A ref as the Flutter app encodes it: these keys, in this order, the empty ones left out. */
function refJson(r: MediaRef): MediaRef {
  const out: Record<string, unknown> = { kind: r.kind, id: r.id, title: r.title };
  for (const k of ['image', 'ext', 'url', 'seriesId', 'seriesTitle', 'season', 'number', 'tmdb', 'year', 'epg'] as const) {
    if (r[k] !== undefined && r[k] !== null) out[k] = r[k];
  }
  return out as unknown as MediaRef;
}

export function channelRef(c: LiveChannel): MediaRef {
  return refJson({ kind: 'live', id: c.id, title: c.name, image: c.icon, url: c.url, epg: c.epgId });
}

export function movieRef(m: Movie): MediaRef {
  return refJson({ kind: 'movie', id: m.id, title: m.name, image: m.poster, ext: m.extension, url: m.url, tmdb: m.tmdbId, year: m.year });
}

export function seriesRef(s: Series): MediaRef {
  return refJson({ kind: 'series', id: s.id, title: s.name, image: s.cover, tmdb: s.tmdbId, year: s.year });
}

export function episodeRef(s: Series, e: Episode): MediaRef {
  return refJson({
    kind: 'episode',
    id: e.id,
    title: cleanEpisodeTitle(e, s.name),
    image: e.image || s.backdrop || s.cover,
    ext: e.extension,
    seriesId: s.id,
    seriesTitle: s.name,
    season: e.season,
    number: e.number,
    tmdb: e.tmdbId,
    year: s.year, // the series' year, to find the series again
  });
}

export const refToChannel = (r: MediaRef): LiveChannel => ({ id: r.id, name: r.title, icon: r.image, url: r.url, epgId: r.epg, archiveDays: 0 });
export const refToMovie = (r: MediaRef): Movie => ({ id: r.id, name: r.title, poster: r.image, extension: r.ext || 'mp4', url: r.url, tmdbId: r.tmdb, year: r.year });
export const refToSeries = (r: MediaRef): Series => ({ id: r.seriesId || r.id, name: r.seriesTitle || r.title, cover: r.kind === 'series' ? r.image : undefined, year: r.year });
export const refToEpisode = (r: MediaRef): Episode => ({ id: r.id, season: r.season || 0, number: r.number || 0, title: r.title, extension: r.ext || 'mp4' });

export interface HistoryEntry {
  ref: MediaRef;
  pos: number; // ms
  dur: number; // ms
  at: number; // when, ms since the epoch
  dev?: string; // the device it was watched on
}

export const progressOf = (h: HistoryEntry) => (h.dur <= 0 ? 0 : Math.min(1, Math.max(0, h.pos / h.dur)));

/** Seen for real, not only opened: a fifth of it, or ten minutes. A channel never is. */
export const watchedFor = (h: HistoryEntry) => h.ref.kind !== 'live' && (progressOf(h) >= 0.2 || h.pos >= 10 * 60 * 1000);

/** Worth offering "continue": started for real and not (almost) finished. */
export const resumable = (h: HistoryEntry) => h.ref.kind !== 'live' && h.pos >= 30000 && progressOf(h) < 0.95;

function entryJson(h: HistoryEntry): HistoryEntry {
  const out: HistoryEntry = { ref: refJson(h.ref), pos: h.pos, dur: h.dur, at: h.at };
  if (h.dev) out.dev = h.dev;
  return out;
}

/** Movies and episodes kept in the history. */
const MAX_HISTORY = 80;
const EPISODES_KEPT = 5;
/** Channels kept in the history, apart: zapping does not push titles out. */
const MAX_LIVE = 30;
/** Markers this much older than the library's latest event are dropped. */
const MARKER_AGE = 180 * 24 * 60 * 60 * 1000;

const prefKey = (playlistId: string, profileId: string) =>
  profileId === mainProfileId ? `library.${playlistId}` : `library.${playlistId}@${profileId}`;

type Times = Record<string, number>;

export class Library extends Notifier {
  /** Fires whenever a library is saved, so sync can send it. Progress noted during playback is quiet: it can wait a while. */
  static readonly saved = new Set<(e: { playlistId: string; profileId: string; quiet: boolean }) => void>();

  private favs: MediaRef[] = []; // newest first
  private favAt: Times = {}; // key → when it was added
  private unfav: Times = {}; // key → when it stopped being a favorite
  private hist: HistoryEntry[] = []; // most recent first
  private forgot: Times = {}; // key → when it was removed from the history
  private cleared = 0; // when the whole history was cleared

  private constructor(readonly playlistId: string, readonly profileId: string, j: Record<string, unknown>) {
    super();
    this.absorb(j);
  }

  static load(playlistId: string, profileId: string): Library {
    return new Library(playlistId, profileId, Library.stored(playlistId, profileId) || {});
  }

  /** What is stored for the playlist and profile, as saved (for backups and sync). */
  static stored(playlistId: string, profileId: string): Record<string, unknown> | null {
    try {
      const raw = localStorage.getItem(prefKey(playlistId, profileId));
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  }

  /** Merges a library from elsewhere into this one and saves it if anything changed. */
  merge(data: Record<string, unknown>): void {
    const before = JSON.stringify(this.toJson());
    this.absorb(data);
    if (JSON.stringify(this.toJson()) !== before) this.save();
  }

  private absorb(j: Record<string, unknown>): void {
    const favorites = ((j.favorites as MediaRef[]) || []).map(refJson);
    const added = times(j.favAt);
    // Saved before favorites had times: keep their order, older than anything with a time
    favorites.forEach((f, i) => {
      if (added[refKey(f)] === undefined) added[refKey(f)] = favorites.length - i;
    });
    const pool: Record<string, MediaRef> = {};
    for (const f of this.favs) pool[refKey(f)] = f;
    for (const f of favorites) {
      const k = refKey(f);
      const theirs = added[k];
      const mine = this.favAt[k] === undefined ? -1 : this.favAt[k];
      if (theirs > mine || (theirs === mine && wins(f, pool[k]))) {
        pool[k] = f;
        this.favAt[k] = theirs;
      }
    }
    latest(this.unfav, times(j.unfav));
    latest(this.forgot, times(j.forgot));
    this.cleared = Math.max(this.cleared, Number(j.cleared) || 0);
    const byKey: Record<string, HistoryEntry> = {};
    for (const h of this.hist) byKey[refKey(h.ref)] = h;
    for (const x of (j.history as HistoryEntry[]) || []) {
      const h = entryJson({ ref: x.ref, pos: x.pos, dur: x.dur, at: x.at, dev: x.dev });
      const mine = byKey[refKey(h.ref)];
      if (!mine || newer(h, mine)) byKey[refKey(h.ref)] = h;
    }
    this.settle(values(pool), values(byKey));
  }

  /** Rebuilds what is shown from everything known: the latest event per item wins. */
  private settle(favorites: MediaRef[], history: HistoryEntry[]): void {
    this.favs = favorites.filter((f) => (this.favAt[refKey(f)] || 0) > (this.unfav[refKey(f)] === undefined ? -1 : this.unfav[refKey(f)]));
    const shown: Record<string, true> = {};
    for (const f of this.favs) shown[refKey(f)] = true;
    for (const k of Object.keys(this.favAt)) if (!shown[k]) delete this.favAt[k];
    for (const k of Object.keys(this.unfav)) if (shown[k]) delete this.unfav[k]; // added again since
    this.hist = history.filter((h) => h.at > Math.max(this.cleared, this.forgot[refKey(h.ref)] || 0));
    this.sort();
    this.trim();
    const watched: Record<string, true> = {};
    for (const h of this.hist) watched[refKey(h.ref)] = true;
    for (const k of Object.keys(this.forgot)) if (watched[k] || this.forgot[k] <= this.cleared) delete this.forgot[k];
    const oldest = this.latestEvent() - MARKER_AGE;
    for (const m of [this.unfav, this.forgot]) for (const k of Object.keys(m)) if (m[k] < oldest) delete m[k];
  }

  /** Keeps the newest titles and channels (the history is newest first). */
  /**
   * Keeps the newest MAX_HISTORY titles and MAX_LIVE channels. A series is one title, with its last
   * EPISODES_KEPT episodes; by series id, as Flutter does, or the two would trim differently and send
   * each other their histories without end.
   */
  private trim(): void {
    let titles = 0;
    let channels = 0;
    const kept: Record<string, number> = {}; // episodes kept of each series; 0 for a series left out
    this.hist = this.hist.filter((h) => {
      if (h.ref.kind === 'live') return channels++ < MAX_LIVE;
      const series = h.ref.kind === 'episode' ? h.ref.seriesId : undefined;
      if (series !== undefined && series in kept) {
        const n = kept[series];
        if (n === 0 || n >= EPISODES_KEPT) return false;
        kept[series] = n + 1;
        return true;
      }
      const ok = titles++ < MAX_HISTORY;
      if (series !== undefined) kept[series] = ok ? 1 : 0;
      return ok;
    });
  }

  private sort(): void {
    this.favs.sort((a, b) => latestFirst(this.favAt[refKey(a)], refKey(a), this.favAt[refKey(b)], refKey(b)));
    this.hist.sort((a, b) => latestFirst(a.at, refKey(a.ref), b.at, refKey(b.ref)));
  }

  private latestEvent(): number {
    return Math.max(this.cleared, ...values(this.favAt), ...values(this.unfav), ...values(this.forgot), ...this.hist.map((h) => h.at));
  }

  favorites(kind: MediaKind): MediaRef[] {
    return this.favs.filter((f) => f.kind === kind);
  }

  isFavorite(r: MediaRef): boolean {
    return this.favAt[refKey(r)] !== undefined;
  }

  toggleFavorite(r: MediaRef): void {
    const k = refKey(r);
    if (this.isFavorite(r)) {
      this.favs = this.favs.filter((f) => refKey(f) !== k);
      // After its own marker, which a device whose clock runs ahead may have put in the future
      this.unfav[k] = Math.max(Date.now(), (this.favAt[k] || 0) + 1);
      delete this.favAt[k];
    } else {
      // After any marker from another device whose clock runs ahead
      this.favAt[k] = Math.max(Date.now(), (this.unfav[k] || 0) + 1);
      delete this.unfav[k];
      this.favs.unshift(refJson(r));
    }
    this.save();
  }

  get history(): HistoryEntry[] {
    return this.hist.slice();
  }

  /** Everything this library refers to: favorites, then history. */
  get refs(): MediaRef[] {
    return this.favs.concat(this.hist.map((h) => h.ref));
  }

  /**
   * Swaps in a better described [r] (the same item, say now with its TMDB id) wherever it appears.
   * Its times move on by a millisecond, so this version wins over the old one when merging.
   */
  updateRef(r: MediaRef): void {
    const k = refKey(r);
    const ref = refJson(r);
    this.favs = this.favs.map((f) => {
      if (refKey(f) !== k) return f;
      this.favAt[k] = (this.favAt[k] || 0) + 1;
      return ref;
    });
    this.hist = this.hist.map((h) => (refKey(h.ref) === k ? entryJson({ ref, pos: h.pos, dur: h.dur, at: h.at + 1, dev: h.dev }) : h));
    this.save();
  }

  entry(r: MediaRef): HistoryEntry | undefined {
    const k = refKey(r);
    return this.hist.filter((h) => refKey(h.ref) === k)[0];
  }

  /** Most recent resumable item per title: a series appears once, with its latest episode. */
  get continueWatching(): HistoryEntry[] {
    const seen: Record<string, true> = {};
    return this.hist.filter((h) => {
      // A series by its latest episode: one finished after it was left means it was not left there
      const k = h.ref.seriesId || refKey(h.ref);
      if (seen[k]) return false;
      seen[k] = true;
      return resumable(h);
    });
  }

  /** What was left half watched on another device a short while ago, to go on with here. */
  leftElsewhere(within = 12 * 60 * 60 * 1000): HistoryEntry | undefined {
    const h = this.hist.filter((x) => x.ref.kind !== 'live')[0];
    if (!h || !resumable(h) || !h.dev || isThisDevice(h.dev)) return undefined;
    const ago = Date.now() - h.at;
    return ago > within || ago < -5 * 60 * 1000 ? undefined : h; // a clock a bit ahead is fine
  }

  /** Latest episode watched of a series, finished or not. */
  lastEpisodeOf(seriesId: string): HistoryEntry | undefined {
    return this.hist.filter((h) => h.ref.kind === 'episode' && h.ref.seriesId === seriesId)[0];
  }

  recent(kind: MediaKind): MediaRef[] {
    return this.hist.filter((h) => h.ref.kind === kind).map((h) => h.ref);
  }

  /** Records that [r] was watched up to [pos]; moves it to the top of the history. [quiet] for the progress noted every few seconds during playback. */
  record(r: MediaRef, pos = 0, dur = 0, quiet = false): void {
    const k = refKey(r);
    // Strictly after the latest entry and after any marker from a device whose clock runs ahead
    const latestAt = this.hist.length ? this.hist[0].at : 0;
    const at = Math.max(Date.now(), Math.max(latestAt, this.cleared, this.forgot[k] || 0) + 1);
    delete this.forgot[k];
    this.hist = this.hist.filter((h) => refKey(h.ref) !== k);
    this.hist.unshift(entryJson({ ref: r, pos: Math.round(pos), dur: Math.round(dur), at, dev: deviceName() }));
    this.trim();
    this.save(quiet);
  }

  /** Takes [r] off Continue watching; of a series, the episodes left half watched (the finished ones say where it is up to). */
  forget(r: MediaRef): void {
    const goes = (x: HistoryEntry) =>
      r.kind === 'episode' ? x.ref.kind === 'episode' && x.ref.seriesId === r.seriesId && resumable(x) : refKey(x.ref) === refKey(r);
    for (const x of this.hist.filter(goes)) this.forgot[refKey(x.ref)] = Math.max(Date.now(), x.at + 1);
    this.hist = this.hist.filter((x) => !goes(x));
    this.save();
  }

  /** When the whole history was last cleared (ms), here or on another device; 0 for never. */
  get clearedAt(): number {
    return this.cleared;
  }

  clearHistory(): void {
    const latestAt = this.hist.length ? this.hist[0].at : 0;
    this.hist = [];
    this.cleared = Math.max(Date.now(), latestAt + 1);
    this.forgot = {};
    this.save();
  }

  /**
   * Nothing left of it, here or on other devices: its profile's PIN was forgotten, and whoever
   * opens it next must not find what was watched.
   */
  forgetAll(): void {
    for (const f of this.favs) {
      const k = refKey(f);
      this.unfav[k] = Math.max(Date.now(), (this.favAt[k] || 0) + 1);
      delete this.favAt[k];
    }
    this.favs = [];
    this.clearHistory();
  }

  /** As stored. Maps are sorted so the same library always encodes the same way. */
  toJson(): Record<string, unknown> {
    return {
      favorites: this.favs.map(refJson),
      favAt: sorted(this.favAt),
      unfav: sorted(this.unfav),
      history: this.hist.map(entryJson),
      forgot: sorted(this.forgot),
      cleared: this.cleared,
    };
  }

  private save(quiet = false): void {
    this.sort();
    this.notify();
    try {
      localStorage.setItem(prefKey(this.playlistId, this.profileId), JSON.stringify(this.toJson()));
    } catch {
      // Storage full: kept in memory for this session
      if (!storageTold) {
        storageTold = true; // every ten seconds with a movie going, or it would never leave
        toast(t('storageFull'));
      }
    }
    Library.saved.forEach((l) => l({ playlistId: this.playlistId, profileId: this.profileId, quiet }));
  }
}

function newer(a: HistoryEntry, b: HistoryEntry): boolean {
  return a.at !== b.at ? a.at > b.at : wins(a, b);
}

/**
 * The same moment on two devices with different contents: settled the same way everywhere, the
 * fuller copy first, so a device on an older version cannot take fields away (see keepsOver).
 */
function wins(a: object, b?: object): boolean {
  return keepsOver(a as Record<string, unknown>, b as Record<string, unknown> | undefined);
}

function latestFirst(at1: number, k1: string, at2: number, k2: string): number {
  return at1 !== at2 ? at2 - at1 : k1 < k2 ? -1 : k1 > k2 ? 1 : 0;
}

function times(j: unknown): Times {
  const out: Times = {};
  if (j && typeof j === 'object') for (const k of Object.keys(j)) out[k] = Math.trunc(Number((j as Times)[k]));
  return out;
}

function latest(into: Times, from: Times): void {
  for (const k of Object.keys(from)) if (from[k] > (into[k] === undefined ? -1 : into[k])) into[k] = from[k];
}

function sorted(m: Times): Times {
  const out: Times = {};
  for (const k of Object.keys(m).sort()) out[k] = m[k];
  return out;
}

function values<T>(o: Record<string, T>): T[] {
  return Object.keys(o).map((k) => o[k]);
}
