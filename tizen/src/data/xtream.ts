// Xtream Codes API client (player_api.php), as app/lib/data/xtream.dart.
import { cacheAge, readCache, writeCache } from './cache';
import { EpgGuide, GuideChannel, loadXmltv } from './epg';
import { afterPhpNotice, JsonItemCounter, jsonItems } from './json_items';
import { isKidsCategory, kidsMaySee } from './kids';
import { buildListing, FROM_JSON, Listing, ListingData, ListKind } from './listing';
import { downloadList, DownloadStopped, holdRefresh, ListImport, listImports, refreshInBackground, releaseRefresh } from './lists';
import { Episode, Movie, movieFromJson, movieWithDetail, Series, SeriesDetail, seriesDetailFromJson } from './models';
import { BIG, offThread } from './parsing';
import {
  AccountInfo,
  asInt,
  asStr,
  Category,
  ContentSource,
  fetchText,
  EpgEntry,
  isAdultCategory,
  LiveChannel,
  SourceException,
  stableHash,
} from './source';
import { fromUnix, parseDate } from './values';

/** Accepts "host", "host:8080", "http://host:8080/" or a full player_api.php URL. */
export function normalizeServer(server: string): string {
  let s = server.trim();
  if (s.indexOf('://') < 0) s = 'http://' + s;
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    throw new SourceException('badAddress');
  }
  if (!u.hostname || s.indexOf(' ') >= 0 || (u.protocol !== 'http:' && u.protocol !== 'https:')) throw new SourceException('badAddress');
  const path = u.pathname.replace(/\/(player_api|get)\.php$/, '').replace(/\/+$/, '');
  return `${u.protocol}//${u.host}${path}`;
}

interface Kind<T> {
  categories: string;
  streams: string;
  /** What the items are made with, by the name the parsing worker knows them. */
  parse: ListKind;
  /** Never set: it only says what the items are. */
  item?: T;
}

const LIVE: Kind<LiveChannel> = { categories: 'get_live_categories', streams: 'get_live_streams', parse: 'live' };
const MOVIES: Kind<Movie> = { categories: 'get_vod_categories', streams: 'get_vod_streams', parse: 'movie' };
const SERIES: Kind<Series> = { categories: 'get_series_categories', streams: 'get_series', parse: 'series' };

/** Full lists younger than this are read from the cache instead of the panel. */
const LISTS_FRESH = 6 * 60 * 60 * 1000;

/** How long the panel may take to answer, and to send each piece of a list. */
const LIST_WAIT = 30000;

/** The key the items of [action]'s list have. */
const idOf = (action: string) => (action === SERIES.streams ? 'series_id' : /_categories$/.test(action) ? 'category_id' : 'stream_id');

/**
 * A new copy of the list at [url] for [key] in the background, written for the next load and never
 * parsed here (see refreshInBackground). Given only what it needs: waiting its turn it must not
 * hold on to the source, and the catalog in it.
 */
function refreshLater(url: string, key: string, id: string): void {
  refreshInBackground(key, async (giveWay) => {
    const counter = new JsonItemCounter();
    const text = await downloadList(url, LIST_WAIT, { giveWay, onPiece: (piece) => counter.add(piece) });
    // Neither an error the panel answers with ({"user_info": {"auth": 0}}, whose values look like
    // items), nor an empty list, nor one cut short, may take the place of a good copy
    return counter.closed && counter.count > 0 && text.indexOf(`"${id}"`) >= 0 ? text : null;
  });
}

/** allowed_output_formats: a list, or what PHP makes of one with gaps ({"0": "ts", "2": "m3u8"}), or "m3u8,ts". */
function formatsOf(f: unknown): string[] {
  if (Array.isArray(f)) return f.map(String);
  if (typeof f === 'string') return f.split(/[,\s]+/).filter((x) => x);
  if (f && typeof f === 'object') return Object.keys(f).map((k) => String((f as Record<string, unknown>)[k]));
  return [];
}

export class XtreamSource implements ContentSource {
  readonly base: string;
  hideAdult = true; // whoever forgets to say hides too much, not too little
  /** Its lists and guide asked of the panel whatever the copies on the TV ("Update list"). */
  refetch = false;
  notUpdated = false;
  kidsOnly = false;
  /** Learned at login. */
  serverUtcOffset?: number;
  /**
   * Minutes its guide's times move: the playlist's guideShift, set on the phone for a panel whose
   * guide is on the wrong clock.
   */
  guideShift = 0;

  constructor(server: string, readonly username: string, readonly password: string, public liveFormat = 'ts') {
    this.base = normalizeServer(server);
  }

  private get u() {
    return encodeURIComponent(this.username);
  }

  private get p() {
    return encodeURIComponent(this.password);
  }

  private url(action?: string, params: Record<string, string> = {}): string {
    let url = `${this.base}/player_api.php?username=${this.u}&password=${this.p}`;
    if (action) url += `&action=${action}`;
    for (const k of Object.keys(params)) url += `&${k}=${encodeURIComponent(params[k])}`;
    return url;
  }

  private async text(action?: string, params: Record<string, string> = {}): Promise<string> {
    return fetchText(this.url(action, params), 30000, this.closed.signal);
  }

  private async api(action?: string, params: Record<string, string> = {}): Promise<unknown> {
    return parse(await this.text(action, params));
  }

  /**
   * The account status, as login; undefined when the panel cannot be reached for it now but its
   * lists are on the TV to open with. Wrong credentials or an account no longer active still throw.
   */
  async loginOrSaved(): Promise<AccountInfo | undefined> {
    try {
      return await this.login();
    } catch (e) {
      // A 404 to a login is a login it does not know, or no panel at all: not a panel that is down
      if (!(e instanceof SourceException) || e.error === 'unauthorized' || e.error === 'inactiveAccount' || e.error === 'wrongServer') throw e;
      for (const action of [LIVE.streams, MOVIES.streams, SERIES.streams]) {
        if ((await cacheAge(`catalog-${stableHash(`${this.base}|${this.username}`)}-${action}`)) !== null) {
          // Again in the background, for its clock and formats, once the panel is back
          this.login().catch(() => {});
          return undefined;
        }
      }
      throw e;
    }
  }

  /** Checks the credentials and returns the account status. */
  async login(): Promise<AccountInfo> {
    let data: unknown;
    try {
      data = await this.api();
    } catch (e) {
      // Some panels (XUI) answer a login they do not know with 404, as if the page did not exist
      if (e instanceof SourceException && e.error === 'httpStatus' && e.detail === '404') {
        throw new SourceException('wrongServer'); // or an address that is not a panel's
      }
      throw e;
    }
    const j = data as { user_info?: Record<string, unknown> } | null;
    if (!j || typeof j !== 'object' || !j.user_info || typeof j.user_info !== 'object') {
      throw new SourceException('badResponse');
    }
    const u = j.user_info;
    const si = (j as { server_info?: unknown }).server_info;
    const server = si && typeof si === 'object' ? (si as Record<string, unknown>) : undefined;
    if (asInt(u.auth) !== 1) throw new SourceException('unauthorized');
    const max = asInt(u.max_connections);
    const exp = asInt(u.exp_date);
    const info: AccountInfo = {
      status: asStr(u.status) || 'Unknown',
      expires: exp ? new Date(exp * 1000) : undefined,
      maxConnections: max && max > 0 ? max : undefined,
      activeConnections: asInt(u.active_cons),
      isTrial: asInt(u.is_trial) === 1,
      formats: formatsOf(u.allowed_output_formats),
      serverTimezone: server ? asStr(server.timezone) : undefined,
      serverUtcOffset: serverOffset(server),
      message: asStr(u.message),
    };
    this.serverUtcOffset = info.serverUtcOffset;
    this.allowedFormats = info.formats;
    // Only a status the panel sent: some compatible ones send none for an account that works
    const status = asStr(u.status);
    if (status && status.toLowerCase() !== 'active') throw new SourceException('inactiveAccount', status);
    return info;
  }

  private lists: Record<string, Promise<unknown>> = {};
  /** Aborted when its playlist is left: what it still downloads stops. */
  private readonly closed = new AbortController();

  close(): void {
    this.closed.abort();
  }

  /**
   * A full list, fetched once per session and shared by everything that shows it. Kept on the TV:
   * within LISTS_FRESH it is read from there, and an older copy does too, at once, while a new one
   * comes in the background for the next time (a big list on a slow line takes minutes).
   */
  private listing<T>(action: string, kind: ListKind): Promise<Listing<T>> {
    const loading = this.lists[action] || (this.lists[action] = this.loadListing(action, kind));
    loading.catch(() => {
      if (this.lists[action] === loading) delete this.lists[action]; // the next call tries again
    });
    return loading as Promise<Listing<T>>;
  }

  private async loadListing<T>(action: string, kind: ListKind): Promise<Listing<T>> {
    const item =
      action === LIVE.streams ? listImports.start('live') : action === MOVIES.streams ? listImports.start('movies') : action === SERIES.streams ? listImports.start('series') : null; // categories: a few, and in a moment
    try {
      const listing = await this.bring<T>(action, kind, item);
      if (item) item.finish(listing.items.length);
      return listing;
    } catch (e) {
      if (item) item.fail();
      throw e;
    }
  }

  private async bring<T>(action: string, kind: ListKind, item: ListImport | null): Promise<Listing<T>> {
    const key = `catalog-${stableHash(`${this.base}|${this.username}`)}-${action}`;
    const age = this.refetch ? null : await cacheAge(key);
    if (age !== null) {
      const listing = await savedListing<T>(key, kind, item);
      // A young copy of nothing may be what a panel down for a moment answered: asked again
      if (listing && listing.items.length && age < LISTS_FRESH) return listing;
      // An old copy of nothing is no copy to show: it would stay empty the whole session
      if (listing && listing.items.length) {
        refreshLater(this.url(action), key, idOf(action));
        return listing;
      }
    }
    try {
      return await this.fetchListing<T>(action, kind, key, item);
    } catch (e) {
      // Updating, not even an answer that is no list costs the copy there was. Otherwise a copy with
      // something in it was given above: one empty or damaged is no answer, what went wrong is said
      if (!(e instanceof SourceException) || !this.refetch) throw e;
      const listing = await savedListing<T>(key, kind, item);
      if (!listing) throw e;
      if (this.refetch) this.notUpdated = true; // only for a copy shown: a panel may have no series
      return listing; // the panel is down: the last copy will do
    }
  }

  /** [action]'s list from the panel, counted as it comes, and kept under [key]. */
  private async fetchListing<T>(action: string, kind: ListKind, key: string, item: ListImport | null): Promise<Listing<T>> {
    holdRefresh(key); // this one brings it, and someone waits for it
    try {
      const counter = new JsonItemCounter();
      const onPiece = item
        ? (piece: Uint8Array) => {
            counter.add(piece);
            item.counted(counter.count);
          }
        : undefined;
      const text = await downloadList(this.url(action), LIST_WAIT, { onPiece, stop: this.closed.signal });
      // Left as it came in: not read, nor kept, for nobody
      if (this.closed.signal.aborted) throw new DownloadStopped();
      const listing = await parseListing<T>(text, kind, item);
      // An error the panel answers with a 200 ({"user_info": {"auth": 0}}, whose values look like
      // items) is no list; an empty one does not take the place of a copy with items
      if (listing.items.length && text.indexOf(`"${idOf(action)}"`) < 0) throw new SourceException('badResponse');
      if (!listing.items.length) {
        const last = await savedListing<T>(key, kind, null).catch(() => null);
        if (last && last.items.length) {
          if (this.refetch) this.notUpdated = true;
          return last;
        }
      }
      writeCache(key, text);
      return listing;
    } finally {
      releaseRefresh(key);
    }
  }

  private async categories<T>(kind: Kind<T>): Promise<Category[]> {
    const all = (await this.listing<Category>(kind.categories, 'category')).items;
    const adult = this.hideAdult ? await this.adultCategories(kind) : {};
    const shown = all.filter((c) => !adult[c.id]);
    if (!this.kidsOnly) return shown;
    // Only those with something left for a child: most hold nothing once filtered
    const listing = await this.listing<T>(kind.streams, kind.parse);
    const kept = new Set(await this.itemsOf(kind));
    return shown.filter((c) => listing.only(c.id).some((x) => kept.has(x)));
  }

  private async itemsOf<T>(kind: Kind<T>, category?: string): Promise<T[]> {
    const listing = await this.listing<T>(kind.streams, kind.parse);
    let items: T[];
    if (this.hideAdult) {
      const adult = await this.adultCategories(kind);
      items = category !== undefined && adult[category] ? [] : listing.only(category, adult);
    } else {
      items = listing.only(category);
    }
    if (!this.kidsOnly) return items;
    const inKids = new Set<T>();
    for (const c of (await this.listing<Category>(kind.categories, 'category')).items) {
      if (isKidsCategory(c.name)) listing.only(c.id).forEach((x) => inKids.add(x));
    }
    return items.filter((x) => kidsMaySee(x, inKids.has(x)));
  }

  /** A kind's adult categories: named so, or holding mostly items the panel marks as adult. */
  private async adultCategories<T>(kind: Kind<T>): Promise<Record<string, true>> {
    const adult: Record<string, true> = {};
    // Without the names nothing can be hidden for sure: better a list that failed than one that shows them
    for (const c of (await this.listing<Category>(kind.categories, 'category')).items) if (isAdultCategory(c.name)) adult[c.id] = true;
    try {
      const marked = (await this.listing<T>(kind.streams, kind.parse)).adultCategories;
      for (const c of Object.keys(marked)) adult[c] = true;
    } catch {
      // The names still count
    }
    return adult;
  }

  liveCategories(): Promise<Category[]> {
    return this.categories(LIVE);
  }

  liveChannels(categoryId?: string): Promise<LiveChannel[]> {
    return this.itemsOf(LIVE, categoryId);
  }

  movieCategories(): Promise<Category[]> {
    return this.categories(MOVIES);
  }

  movies(categoryId?: string): Promise<Movie[]> {
    return this.itemsOf(MOVIES, categoryId);
  }

  seriesCategories(): Promise<Category[]> {
    return this.categories(SERIES);
  }

  series(categoryId?: string): Promise<Series[]> {
    return this.itemsOf(SERIES, categoryId);
  }

  async seriesDetail(s: Series): Promise<SeriesDetail> {
    const text = await this.text('get_series_info', { series_id: s.id });
    // A long series (hundreds of episodes) is read off the screen's thread, as the lists are; where
    // the worker cannot, here as before
    if (text.length > BIG) {
      const reply = await offThread<{ detail?: SeriesDetail }>({ op: 'series', base: s, text }).catch(() => null);
      if (reply && reply.detail) return reply.detail;
      if (reply && reply.error === 'notFound') throw new SourceException('notFound');
      if (reply && reply.error === 'badResponse') throw new SourceException('badResponse');
    }
    const data = parse(text);
    // Some panels answer [] for a series they no longer have
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new SourceException('notFound');
    return seriesDetailFromJson(s, data as Record<string, unknown>);
  }

  /** Full movie record (get_vod_info); fills in whatever the listing left out. */
  async movieDetail(m: Movie): Promise<Movie> {
    const data = (await this.api('get_vod_info', { vod_id: m.id })) as { info?: Record<string, unknown> } | null;
    const info = data && data.info && typeof data.info === 'object' ? data.info : {};
    return movieWithDetail(m, movieFromJson({ ...info, stream_id: m.id }));
  }

  async shortEpg(c: LiveChannel, limit = 4): Promise<EpgEntry[]> {
    const data = (await this.api('get_short_epg', { stream_id: c.id, limit: String(limit) })) as { epg_listings?: unknown[] } | null;
    const list = data && Array.isArray(data.epg_listings) ? data.epg_listings : [];
    const out: EpgEntry[] = [];
    for (const e of list.filter((e) => e && typeof e === 'object') as Record<string, unknown>[]) {
      // Panels without the timestamps still send the dates ("2026-11-05 20:30:00"), on the panel's
      // clock; one with no time at all is left
      const start = fromUnix(e.start_timestamp) || onPanelClock(e.start, this.serverUtcOffset);
      const end = fromUnix(e.stop_timestamp) || onPanelClock(e.end !== undefined && e.end !== null ? e.end : e.stop, this.serverUtcOffset);
      if (!start || !end) continue;
      out.push({ title: decodeBase64(asStr(e.title) || ''), description: decodeBase64(asStr(e.description) || ''), start, end });
    }
    return out;
  }

  /** The full guide, read for its channels and moved by its guideShift. */
  async guide(stop?: AbortSignal, early?: (kept: EpgGuide) => void): Promise<EpgGuide> {
    const url = `${this.base}/xmltv.php?username=${this.u}&password=${this.p}`;
    const channels = this.guideChannels(); // waited for only to read it: the guide downloads meanwhile
    const shift = this.guideShift;
    // A copy kept, shown early, is read for its channels too
    const shown = early && ((kept: EpgGuide) => void channels.then((c) => kept.matched(c, shift)).then(early, () => undefined));
    const guide = await loadXmltv(url, `epg-${stableHash(`${this.base}|${this.username}`)}`, this.refetch ? 0 : undefined, stop, shown);
    return guide === EpgGuide.empty || guide === EpgGuide.failed ? guide : guide.matched(await channels, shift);
  }

  /**
   * What the guide is read for: its channels, all of them (also those a profile hides: the guide is
   * the account's), by their guide id and name; null when they cannot be had, and only guideShift counts.
   */
  private async guideChannels(): Promise<GuideChannel[] | null> {
    try {
      const all = (await this.listing<LiveChannel>(LIVE.streams, LIVE.parse)).items;
      const out: GuideChannel[] = [];
      for (const c of all) if (c.epgId) out.push({ id: c.epgId, names: [c.name] });
      return out;
    } catch {
      return null;
    }
  }

  /** /timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts, in server time. */
  catchupUrl(c: LiveChannel, start: Date, minutes: number): string | null {
    if (!c.archiveDays) return null;
    const two = (n: number) => (n < 10 ? '0' : '') + n;
    // Wall-clock time on the server; without a known offset assume the server shares ours
    const offset = this.serverUtcOffset !== undefined ? this.serverUtcOffset : -start.getTimezoneOffset();
    const t = new Date(start.getTime() + offset * 60000);
    const s = `${t.getUTCFullYear()}-${two(t.getUTCMonth() + 1)}-${two(t.getUTCDate())}:${two(t.getUTCHours())}-${two(t.getUTCMinutes())}`;
    return `${this.base}/timeshift/${this.u}/${this.p}/${Math.round(minutes)}/${s}/${c.id}.ts`;
  }

  /** The outputs the account allows, learned at login: none known, any. */
  allowedFormats: string[] = [];

  liveUrl(c: LiveChannel): string {
    // The setting, or what the account allows instead (one that only allows HLS refuses .ts)
    let format = this.liveFormat;
    const allowed = this.allowedFormats;
    if (allowed.length && allowed.indexOf(format) < 0) format = ['ts', 'm3u8'].filter((f) => allowed.indexOf(f) >= 0)[0] || format;
    return `${this.base}/live/${this.u}/${this.p}/${c.id}.${format}`;
  }

  movieUrl(m: Movie): string {
    return `${this.base}/movie/${this.u}/${this.p}/${m.id}.${m.extension}`;
  }

  episodeUrl(e: Episode): string {
    return `${this.base}/series/${this.u}/${this.p}/${e.id}.${e.extension}`;
  }

  /**
   * The User-Agent the playlist has for a panel that lets only some players in, for AVPlay; the
   * lists and the guide go without it (a web page cannot set it).
   */
  userAgent: string | undefined;

  userAgentFor(): string | undefined {
    return this.userAgent || undefined;
  }
}

/**
 * The panel reports its wall clock ("time_now") and the UTC epoch ("timestamp_now"); their
 * difference, rounded to 15 minutes, is the server's UTC offset.
 */
function serverOffset(s?: Record<string, unknown>): number | undefined {
  if (!s) return undefined;
  const wall = asStr(s.time_now);
  const epoch = asInt(s.timestamp_now);
  if (!wall || !epoch) return undefined;
  const local = Date.parse(wall.replace(' ', 'T') + 'Z');
  if (isNaN(local)) return undefined;
  return Math.round((local - epoch * 1000) / 60000 / 15) * 15;
}

/**
 * A time the panel wrote with no zone ("2026-11-05 20:30:00"), as the app's EpgEntry.fromXtream
 * reads it: on the panel's clock, [offset] minutes from UTC (learned at login); without it, or
 * written with a zone of its own, as parseDate takes it.
 */
function onPanelClock(v: unknown, offset?: number): Date | undefined {
  const s = asStr(v);
  if (!s) return undefined;
  if (offset === undefined) return parseDate(s);
  const utc = parseDate(`${s.replace(' ', 'T')}Z`);
  return utc ? new Date(utc.getTime() - offset * 60000) : parseDate(s);
}

/** The copy kept under [key] as a Listing; null when there is none or it is damaged. */
async function savedListing<T>(key: string, kind: ListKind, item: ListImport | null): Promise<Listing<T> | null> {
  const saved = await readCache(key);
  if (!saved) return null;
  try {
    return await parseListing<T>(saved.text, kind, item);
  } catch {
    return null;
  }
}

/** A list action's answer as a Listing: in the parsing worker when it is big, telling [item] how far it got. */
async function parseListing<T>(text: string, kind: ListKind, item?: ListImport | null): Promise<Listing<T>> {
  if (text.length > BIG) {
    const reading = item ? (items: number, share: number) => item.reading(items, share) : undefined;
    const reply = await offThread<{ listing?: ListingData<T> }>({ op: 'listing', kind, text }, reading).catch(() => null);
    if (reply && reply.error === 'badResponse') throw new SourceException('badResponse');
    if (reply && reply.listing) return new Listing(reply.listing);
  }
  // Item by item, as the worker reads a big one: one item that does not read is left out, not the
  // whole list with it
  try {
    const items = text.trim() ? jsonItems(text) : [];
    return new Listing(buildListing(items, FROM_JSON[kind] as unknown as (j: Record<string, unknown>) => T));
  } catch (e) {
    if (e instanceof SyntaxError) throw new SourceException('badResponse');
    throw e;
  }
}

function parse(text: string): unknown {
  if (!text) return null;
  try {
    return JSON.parse(text.slice(afterPhpNotice(text) || 0));
  } catch {
    throw new SourceException('badResponse');
  }
}

/** Xtream sends guide titles in base64 (UTF-8 inside, or Latin-1 from some panels); plain text passes through. */
export function decodeBase64(s: string): string {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(s) || s.length % 4 !== 0) return s;
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(s), (ch) => ch.charCodeAt(0));
  } catch {
    return s;
  }
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    // Latin-1 if it reads as text: plain words that only look like base64 ("News") give bytes that do not
    let readable = 0;
    for (let i = 0; i < bytes.length; i++) if (bytes[i] >= 0x20 && bytes[i] < 0x7f) readable++;
    return readable >= bytes.length * 0.8 ? String.fromCharCode.apply(null, Array.from(bytes)) : s;
  }
}
