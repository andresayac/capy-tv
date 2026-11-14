// M3U playlists (app/lib/data/m3u.dart): live channels grouped by group-title.
import { cacheAge, readCache, writeCache } from './cache';
import { EpgGuide, GuideChannel, loadXmltv, parseTvgShift } from './epg';
import { downloadList, holdRefresh, ListImport, listImports, refreshInBackground, releaseRefresh } from './lists';
import { isPlaylist, m3uGuideUrls, M3uEntry, M3uEntryCounter, parseM3u } from './m3u_parse';
import { isKidsCategory } from './kids';
import { Episode, isAdultTitle, Movie, Series, SeriesDetail, ungrouped } from './models';
import { BIG, offThread } from './parsing';
import { Category, ContentSource, EpgEntry, isAdultCategory, LiveChannel, SourceException, stableHash } from './source';

export { m3uGuideUrl, m3uGuideUrls, parseM3u } from './m3u_parse';
export type { M3uEntry } from './m3u_parse';

const group = (e: M3uEntry) => (e.attrs['group-title'] || '').trim() || ungrouped;

/** An M3U says nothing about age: its group, its names and an adult="1" are all there is. */
const isAdultEntry = (e: M3uEntry) =>
  isAdultCategory(group(e)) || isAdultTitle(e.name) || isAdultTitle(e.attrs['tvg-name'] || '') || e.attrs.adult === '1';

/** The groups of [list] in their first order, as categories. */
function groups(list: M3uEntry[]): Category[] {
  const seen: Record<string, true> = {};
  const out: Category[] = [];
  for (const e of list) {
    const g = group(e);
    if (!seen[g]) {
      seen[g] = true;
      out.push({ id: g, name: g });
    }
  }
  return out;
}
/** The path of [url], without parsing it whole: lists have tens of thousands of entries. */
function pathOf(url: string): string {
  const scheme = url.indexOf('://');
  const start = scheme < 0 ? 0 : url.indexOf('/', scheme + 3);
  if (start < 0) return '';
  let end = url.length;
  for (const c of ['?', '#', '|']) {
    const i = url.indexOf(c, start);
    if (i >= 0 && i < end) end = i;
  }
  return url.slice(start, end);
}

/**
 * On demand, by its address: panels put the type in the path, and elsewhere a video file is one.
 * A list has no episode lists, so a series' entries go with the movies rather than nowhere.
 */
const isMovie = (e: M3uEntry) => {
  const path = pathOf(e.url).toLowerCase();
  return path.indexOf('/movie/') >= 0 || path.indexOf('/series/') >= 0 || /\.(mp4|mkv|avi|mov)$/.test(path);
};

/**
 * The guide id [e] goes by: its tvg-id; with none, its name, by which the guide's own names for its
 * channels are matched (see EpgGuide.matched).
 */
const guideIdOf = (e: M3uEntry) => e.attrs['tvg-id'] || e.attrs['tvg-name'] || e.name;

/** Xtream panels' stream URLs: /[live|movie|series/]user/password/id[.ext]. */
const xtreamPath = /^\/(?:(?:live|movie|series)\/)?[^/]+\/[^/]+\/(\d+)(?:\.\w+)?$/;

/** An id that stays when the provider reorders the list: the panel's stream id, else the URL hashed. */
export function m3uId(url: string): string {
  let path = '';
  try {
    path = new URL(url).pathname;
  } catch {
    // Not a URL: hashed whole
  }
  const m = xtreamPath.exec(path);
  return m ? m[1] : stableHash(url);
}

/** Playlists younger than this are read from the cache instead of downloaded again. */
const FRESH = 6 * 60 * 60 * 1000;

/** How long the server may take to answer, and to send each piece of the playlist. */
const WAIT = 60000;

/** A new copy of the playlist at [url] for [key], [before] long now, in the background (see refreshInBackground). */
function refreshLater(url: string, key: string, before: number): void {
  refreshInBackground(key, async (giveWay) => {
    const text = await downloadList(url, WAIT, { giveWay });
    // A playlist has no end to look for: sent with no size and cut short, or an "account expired"
    // of one entry, it reads as a whole one. Much less than there was waits for an update
    return text.length >= before / 2 && isPlaylist(text) ? text : null;
  });
}

export class M3uSource implements ContentSource {
  hideAdult = true; // whoever forgets to say hides too much, not too little
  kidsOnly = false;
  private userAgents: Record<string, string> | null = null;

  /** Its guides downloaded whatever the copies on the TV ("Update list"). */
  refetchGuide = false;
  notUpdated = false;
  /**
   * Minutes its guides' times move besides each channel's tvg-shift: the playlist's guideShift, set
   * on the phone for a guide on the wrong clock.
   */
  guideShift = 0;

  constructor(readonly entries: M3uEntry[], readonly guideUrls: string[] = []) {}

  /**
   * Downloads and parses the playlist at [url]. With [cached], a copy younger than FRESH is read
   * from the TV instead; an older one too, at once, while a new one comes in the background for
   * the next time, and it still does when the download fails. Without it the TV's copy is neither
   * read nor written. With [checking] (saving a playlist checks it for real) the download must
   * work, and what it brings is kept for when the playlist first opens.
   */
  static async load(url: string, cached = true, refetch = false, checking = false): Promise<M3uSource> {
    const item = listImports.start('playlist');
    try {
      const source = await M3uSource.bring(url.trim(), cached, item, refetch || checking, checking);
      source.refetchGuide = refetch;
      item.finish(source.entries.length);
      return source;
    } catch (e) {
      item.fail();
      throw e;
    }
  }

  private static async bring(url: string, cached: boolean, item: ListImport, refetch = false, checking = false): Promise<M3uSource> {
    const key = `m3u-${stableHash(url)}`;
    const age = cached && !refetch ? await cacheAge(key) : null;
    if (age !== null) {
      const saved = await readCache(key);
      const source = saved && (await M3uSource.parse(saved.text, item, url));
      if (saved && source) {
        if (age >= FRESH) refreshLater(url, key, saved.text.length);
        return source;
      }
    }
    try {
      const source = await M3uSource.fetch(url, key, cached, item);
      if (!source) throw new SourceException('emptyPlaylist');
      return source;
    } catch (e) {
      const saved = cached && !checking && e instanceof SourceException ? await readCache(key) : null;
      const last = saved && (await M3uSource.parse(saved.text, item, url));
      if (!last) throw e;
      last.notUpdated = refetch;
      return last; // unreachable now, or an answer that is no playlist: the last copy will do
    }
  }

  /** The playlist at [url], counted as it comes, and with [keep] kept under [key]. Null when there is nothing in it. */
  private static async fetch(url: string, key: string, keep: boolean, item: ListImport): Promise<M3uSource | null> {
    if (keep) holdRefresh(key); // this one brings it, and someone waits for it
    try {
      const counter = new M3uEntryCounter();
      const text = await downloadList(url, WAIT, {
        onPiece: (piece) => {
          counter.add(piece);
          item.counted(counter.count);
        },
      });
      const source = await M3uSource.parse(text, item, url);
      if (source && keep) writeCache(key, text);
      return source;
    } finally {
      if (keep) releaseRefresh(key);
    }
  }

  /** Big playlists are tens of MB: parsed in the worker. Null when there is nothing in it. */
  private static async parse(text: string, item: ListImport, url: string): Promise<M3uSource | null> {
    let entries: M3uEntry[] | undefined;
    let guide: string[] = [];
    if (text.length > BIG) {
      const reply = await offThread<{ entries?: M3uEntry[]; guideUrls?: string[] }>({ op: 'm3u', text }, (n, share) => item.reading(n, share)).catch(() => null);
      if (reply && reply.entries) {
        entries = reply.entries;
        guide = reply.guideUrls || [];
      }
    }
    if (!entries) {
      entries = parseM3u(text);
      guide = m3uGuideUrls(text);
    }
    if (entries.length) return new M3uSource(entries, guide);
    // One channel's HLS address given as the list is that channel, named after its server: its
    // lines are its qualities or pieces
    if (!/^#EXT-X-(TARGETDURATION|STREAM-INF)/m.test(text.slice(0, 65536))) return null;
    const host = /^[a-z][a-z0-9+.-]*:\/\/([^/:?#]+)/i.exec(url);
    return new M3uSource([{ name: host ? host[1] : url, url, attrs: {} }], []);
  }

  private shown(e: M3uEntry): boolean {
    return (!this.kidsOnly || isKidsCategory(group(e))) && (!this.hideAdult || !isAdultEntry(e));
  }

  /**
   * The channels and movies shown, by group, worked out once: picking a category went through the
   * whole list each time. Again when what is hidden changes.
   */
  private lists: {
    hidden: string;
    live: M3uEntry[];
    movies: M3uEntry[];
    channels: LiveChannel[];
    channelsIn: Record<string, LiveChannel[]>;
    moviesIn: Record<string, Movie[]>;
    allMovies: Movie[];
  } | null = null;

  private get shownLists() {
    const hidden = `${this.hideAdult}|${this.kidsOnly}`;
    if (this.lists && this.lists.hidden === hidden) return this.lists;
    const live = this.entries.filter((e) => !isMovie(e) && this.shown(e));
    const movies = this.entries.filter((e) => isMovie(e) && this.shown(e));
    const channels: LiveChannel[] = [];
    const channelsIn: Record<string, LiveChannel[]> = {};
    // A channel's number is the list's (tvg-chno), else its place among all the list's channels,
    // whatever the profile hides
    const place = new Map<M3uEntry, number>();
    let n = 0;
    for (const e of this.entries) if (!isMovie(e)) place.set(e, ++n);
    live.forEach((e) => {
      const chno = parseInt((e.attrs['tvg-chno'] || '').trim(), 10);
      const c: LiveChannel = {
        id: m3uId(e.url),
        name: e.name,
        number: chno > 0 ? chno : place.get(e) || 0,
        icon: e.attrs['tvg-logo'],
        epgId: guideIdOf(e),
        categoryId: group(e),
        archiveDays: parseInt(e.attrs['catchup-days'] || e.attrs['tvg-rec'] || '0', 10) || 0,
        url: e.url,
      };
      channels.push(c);
      (channelsIn[c.categoryId!] || (channelsIn[c.categoryId!] = [])).push(c);
    });
    const allMovies: Movie[] = [];
    const moviesIn: Record<string, Movie[]> = {};
    for (const e of movies) {
      const m: Movie = { id: m3uId(e.url), name: e.name, poster: e.attrs['tvg-logo'], categoryId: group(e), url: e.url, extension: 'mp4' };
      allMovies.push(m);
      (moviesIn[group(e)] || (moviesIn[group(e)] = [])).push(m);
    }
    return (this.lists = { hidden, live, movies, channels, channelsIn, moviesIn, allMovies });
  }

  private get live(): M3uEntry[] {
    return this.shownLists.live;
  }

  private get movieEntries(): M3uEntry[] {
    return this.shownLists.movies;
  }

  liveCategories(): Promise<Category[]> {
    return Promise.resolve(groups(this.live));
  }

  movieCategories(): Promise<Category[]> {
    return Promise.resolve(groups(this.movieEntries));
  }

  async movies(categoryId?: string): Promise<Movie[]> {
    const l = this.shownLists;
    return (categoryId === undefined ? l.allMovies : l.moviesIn[categoryId] || []).slice();
  }

  // M3U playlists carry no season structure
  async seriesCategories(): Promise<Category[]> {
    return [];
  }

  async series(): Promise<Series[]> {
    return [];
  }

  async seriesDetail(s: Series): Promise<SeriesDetail> {
    return { series: s, seasons: [], seasonInfo: {} };
  }

  movieUrl(m: Movie): string {
    return this.current(m.id, m.url);
  }

  /**
   * Where the entry [id] is in the list as it is now: one from the library (Continue watching, My
   * list) keeps the address it had, whose token may have expired or whose password changed. An
   * address still in the list is kept, so of two entries that share an id each plays its own.
   */
  private current(id: string, saved?: string): string {
    if (!this.byId) {
      this.urls = {};
      this.byId = {};
      for (const e of this.entries) {
        this.urls[e.url] = true;
        const key = m3uId(e.url);
        if (!(key in this.byId)) this.byId[key] = e.url;
      }
    }
    if (saved && this.urls![saved]) return saved;
    return this.byId[id] || saved || '';
  }

  private urls: Record<string, true> | null = null;
  private byId: Record<string, string> | null = null;

  episodeUrl(_e: Episode): string {
    throw new Error('M3U playlists have no series');
  }

  async liveChannels(categoryId?: string): Promise<LiveChannel[]> {
    const l = this.shownLists;
    return (categoryId === undefined ? l.channels : l.channelsIn[categoryId] || []).slice();
  }

  /**
   * Its guides as one, each in turn (together they would not fit); where two describe a channel, the
   * first one's. Each read for its channels, and moved by their tvg-shift and its guideShift.
   */
  async guide(stop?: AbortSignal, early?: (kept: EpgGuide) => void): Promise<EpgGuide> {
    if (!this.guideUrls.length) return EpgGuide.empty;
    const guides: EpgGuide[] = [];
    const channels = this.guideChannels();
    // A copy kept shows early only where the list has one guide: of several, each would replace the
    // last. Read for its channels, as the one downloaded is
    const one =
      this.guideUrls.length === 1 && early
        ? (kept: EpgGuide) => void kept.matched(channels, this.guideShift).then(early, () => undefined)
        : undefined;
    for (const url of this.guideUrls) {
      if (stop && stop.aborted) return EpgGuide.empty;
      if (!/^https?:\/\//i.test(url)) continue;
      const guide = await loadXmltv(url, `epg-${stableHash(url)}`, this.refetchGuide ? 0 : undefined, stop, one);
      guides.push(await guide.matched(channels, this.guideShift));
    }
    return guides.length ? EpgGuide.merge(guides) : EpgGuide.empty;
  }

  /**
   * What its guides are read for: its channels, all of them (also those a profile hides: the guide
   * is the playlist's), by the guide id, the names and the tvg-shift of each.
   */
  private guideChannels(): GuideChannel[] {
    const out: GuideChannel[] = [];
    for (const e of this.entries) {
      if (isMovie(e)) continue;
      const names = [e.name];
      const tvgName = e.attrs['tvg-name'];
      if (tvgName && tvgName !== e.name) names.push(tvgName);
      out.push({ id: guideIdOf(e), names, shift: parseTvgShift(e.attrs['tvg-shift']) });
    }
    return out;
  }

  catchupUrl(): string | null {
    return null;
  }

  async shortEpg(): Promise<EpgEntry[]> {
    return [];
  }

  liveUrl(c: LiveChannel): string {
    return this.current(c.id, c.url);
  }

  /** The #EXTVLCOPT:http-user-agent the entry at [url] declares. */
  userAgentFor(url: string): string | undefined {
    if (!this.userAgents) {
      const map: Record<string, string> = {};
      for (const e of this.entries) if (e.userAgent) map[e.url] = e.userAgent;
      this.userAgents = map;
    }
    return this.userAgents[url];
  }
}
