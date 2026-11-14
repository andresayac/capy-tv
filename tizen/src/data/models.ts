// Movies, series and episodes as the Flutter app reads them (app/lib/data/models.dart).
import { asDate, asDouble, asInt, asStr, fromUnix } from './values';

export { asDouble, fromUnix } from './values';

/** A marker, not a text: the screens say it in the app's language (categoryLabel, episodeName). */
export const untitled = 'Untitled';

/**
 * The name of a channel, movie or series that came without one, in the app's language: set as the
 * app starts (main.tsx), and sent along to the parsing worker (parsing.ts).
 */
export let untitledName = untitled;
export function setUntitledName(name: string): void {
  untitledName = name;
}
/** An M3U entry's group when it has none; also its category's id, so it never changes. */
export const ungrouped = 'Ungrouped';
/** An episode's title when the panel sends none. */
export const untitledEpisode = 'Episode';

/**
 * Whether the name of a channel or title itself says it is for adults. Stricter than a category's
 * name: it applies to every profile without adult content, and "Young Adult" or "xXx" are not.
 */
export function isAdultTitle(name: string): boolean {
  return /(^|[^A-Za-z])XXX(?![A-Za-z])/.test(name) || /(^|[^a-z])(porn\w*|hentai|brazzers|playboy)(?![a-z])/i.test(name);
}

/** The TMDB id: the one id a title keeps with every provider. */
function tmdbOf(j: Record<string, unknown>): string | undefined {
  const t = asStr(j.tmdb_id) || asStr(j.tmdb);
  return !t || t === '0' ? undefined : t;
}

function firstOf(v: unknown): string | undefined {
  return Array.isArray(v) ? (v.length ? asStr(v[0]) : undefined) : asStr(v);
}

/** Splits "Acción, Comedia / Drama" into ["Acción", "Comedia", "Drama"]. */
export function splitGenres(genre?: string): string[] {
  return genre ? genre.split(/[,/|]/).map((g) => g.trim()).filter(Boolean) : [];
}

export interface Movie {
  id: string;
  name: string;
  tmdbId?: string; // in the full record; listings rarely carry it
  poster?: string;
  backdrop?: string;
  originalName?: string;
  rating?: number; // out of 10
  year?: number;
  plot?: string;
  genre?: string;
  cast?: string;
  director?: string;
  country?: string;
  ageRating?: string;
  trailer?: string;
  durationSecs?: number;
  releaseDate?: Date;
  bitrateKbps?: number; // in the full record: what the Quality fact shows
  sizeBytes?: number;
  extension: string;
  categoryId?: string;
  added?: Date;
  url?: string; // M3U only
}

/** Reads both the catalog listing (get_vod_streams) and the full record (get_vod_info "info"). */
export function movieFromJson(j: Record<string, unknown>): Movie {
  const secs = asInt(j.duration_secs) || 0;
  const minutes = asInt(j.episode_run_time) || 0;
  const release = asDate(j.release_date || j.releasedate);
  return {
    id: asStr(j.stream_id) || '',
    name: asStr(j.title) || asStr(j.name) || untitledName,
    poster: asStr(j.stream_icon) || asStr(j.cover_big) || asStr(j.movie_image),
    backdrop: firstOf(j.backdrop_path),
    originalName: asStr(j.o_name),
    rating: asDouble(j.rating),
    year: asInt(j.year) || (release && release.getFullYear()),
    plot: asStr(j.plot) || asStr(j.description),
    genre: asStr(j.genre),
    cast: asStr(j.cast) || asStr(j.actors),
    director: asStr(j.director),
    country: asStr(j.country),
    ageRating: asStr(j.mpaa_rating) || asStr(j.age),
    trailer: asStr(j.youtube_trailer),
    durationSecs: secs > 0 ? secs : minutes > 0 ? minutes * 60 : undefined,
    releaseDate: asDate(j.releasedate || j.release_date),
    bitrateKbps: asInt(j.bitrate),
    sizeBytes: asInt(j.source_size),
    extension: asStr(j.container_extension) || 'mp4',
    categoryId: asStr(j.category_id),
    added: fromUnix(j.added),
    tmdbId: tmdbOf(j),
  };
}

/** A listing entry completed with whatever the full record adds. */
export function movieWithDetail(m: Movie, d: Movie): Movie {
  return {
    ...m,
    poster: m.poster || d.poster,
    backdrop: m.backdrop || d.backdrop,
    originalName: m.originalName || d.originalName,
    rating: (m.rating || 0) > 0 ? m.rating : d.rating,
    year: m.year || d.year,
    plot: m.plot || d.plot,
    genre: m.genre || d.genre,
    cast: m.cast || d.cast,
    director: m.director || d.director,
    country: m.country || d.country,
    ageRating: m.ageRating || d.ageRating,
    trailer: m.trailer || d.trailer,
    durationSecs: d.durationSecs || m.durationSecs, // the full record measures the actual file
    releaseDate: m.releaseDate || d.releaseDate,
    bitrateKbps: m.bitrateKbps !== undefined ? m.bitrateKbps : d.bitrateKbps,
    sizeBytes: m.sizeBytes !== undefined ? m.sizeBytes : d.sizeBytes,
    tmdbId: m.tmdbId || d.tmdbId,
  };
}

export interface Series {
  id: string;
  name: string;
  tmdbId?: string;
  cover?: string;
  backdrop?: string;
  rating?: number;
  year?: number;
  plot?: string;
  genre?: string;
  cast?: string;
  director?: string;
  trailer?: string;
  episodeRuntimeMins?: number;
  updated?: Date; // last time the panel added episodes
  categoryId?: string;
}

export function seriesFromJson(j: Record<string, unknown>): Series {
  const minutes = asInt(j.episode_run_time) || 0;
  const release = asDate(j.release_date || j.releaseDate);
  return {
    id: asStr(j.series_id) || '',
    name: asStr(j.title) || asStr(j.name) || untitledName,
    cover: asStr(j.cover),
    backdrop: firstOf(j.backdrop_path),
    rating: asDouble(j.rating),
    year: asInt(j.year) || (release && release.getFullYear()),
    plot: asStr(j.plot),
    genre: asStr(j.genre),
    cast: asStr(j.cast),
    director: asStr(j.director),
    trailer: asStr(j.youtube_trailer),
    episodeRuntimeMins: minutes > 0 ? minutes : undefined,
    updated: fromUnix(j.last_modified),
    categoryId: asStr(j.category_id),
    tmdbId: tmdbOf(j),
  };
}

export interface SeasonInfo {
  number: number;
  name?: string;
  overview?: string;
  cover?: string;
  airDate?: Date;
  rating?: number;
}

export interface Episode {
  id: string;
  season: number;
  number: number;
  title: string;
  extension: string;
  plot?: string;
  image?: string;
  durationSecs?: number;
  rating?: number;
  releaseDate?: Date;
  tmdbId?: string;
}

function episodeFromJson(j: Record<string, unknown>, season: number): Episode {
  const info = (j.info && typeof j.info === 'object' ? j.info : {}) as Record<string, unknown>;
  const secs = asInt(info.duration_secs) || 0;
  return {
    id: asStr(j.id) || '',
    season: asInt(j.season) || season,
    number: asInt(j.episode_num) || 0,
    title: asStr(j.title) || untitledEpisode,
    extension: asStr(j.container_extension) || 'mp4',
    plot: asStr(info.plot),
    image: asStr(info.movie_image) || asStr(info.cover_big),
    durationSecs: secs > 0 ? secs : undefined,
    rating: asDouble(info.rating),
    releaseDate: asDate(info.release_date || info.releasedate),
    tmdbId: tmdbOf(info),
  };
}

/**
 * Panels often name episodes "Show (2021) - S01E01 - Chapter 1"; the UI already shows the series
 * and the episode number, so keep only "Chapter 1".
 */
/** What may follow a series' name in an episode's title for the name to come off: nothing, a separator or a year. */
const afterName = /^\s*($|[\-–—:|.]|\(\d{4}\))/;

/** A season and episode mark, after any separators: S01E05, T01E05 (Spanish), 1x05. */
const seasonMark = /^[\s\-–—:|.]*(?:[ST]\d{1,2}\s*E\d{1,4}|\d{1,2}x\d{1,4})\b/i;

export function cleanEpisodeTitle(e: Episode, seriesName: string): string {
  let t = e.title;
  const bare = seriesName.replace(/\s*\(\d{4}\)$/, '');
  for (const prefix of [seriesName, bare]) {
    if (!prefix || t.toLowerCase().indexOf(prefix.toLowerCase()) !== 0) continue;
    // "House Training" in House, "Showdown" in Show: a word that only begins like the name stays
    const rest = t.slice(prefix.length);
    if (afterName.test(rest) || seasonMark.test(rest)) t = rest;
  }
  t = t.replace(seasonMark, '');
  t = t.replace(/^[\s\-–—:|.]+/, '').trim();
  return t || e.title;
}

export interface SeriesDetail {
  series: Series;
  /** Seasons in order, each with its episodes in order. */
  seasons: { number: number; episodes: Episode[] }[];
  seasonInfo: Record<number, SeasonInfo>;
}

/** get_series_info: "episodes" is {"1": [...], "2": [...]}, or on some servers a list of lists. */
export function seriesDetailFromJson(base: Series, j: Record<string, unknown>): SeriesDetail {
  const seasons: Record<number, Episode[]> = {};
  // A season with no number of its own (a key that is none, a list with no "season") takes the
  // next one free, rather than 0 over the one before
  const numberFor = (key: unknown) => {
    const n = asInt(key);
    if (n !== undefined && !seasons[n]) return n;
    let free = 1;
    while (seasons[free]) free++;
    return free;
  };
  const add = (key: unknown, list: unknown) => {
    // A season sent as an object of its episodes, as PHP makes a list with gaps
    if (list && typeof list === 'object' && !Array.isArray(list)) list = Object.keys(list).map((k) => (list as Record<string, unknown>)[k]);
    if (!Array.isArray(list)) return;
    const n = numberFor(key);
    seasons[n] = list
      .filter((e) => e && typeof e === 'object')
      .map((e) => episodeFromJson(e as Record<string, unknown>, n))
      .sort((a, b) => a.number - b.number);
  };
  const eps = j.episodes;
  const isEpisode = (e: unknown) => !!e && typeof e === 'object' && !Array.isArray(e) && (e as Record<string, unknown>).episode_num != null;
  if (Array.isArray(eps) && eps.length && eps.every(isEpisode)) {
    // One flat list of episodes: grouped by their season
    const bySeason: Record<number, unknown[]> = {};
    for (const e of eps as Record<string, unknown>[]) (bySeason[asInt(e.season) || 1] = bySeason[asInt(e.season) || 1] || []).push(e);
    for (const k of Object.keys(bySeason)) add(k, bySeason[Number(k)]);
  } else if (Array.isArray(eps)) {
    for (const list of eps) {
      if (list && typeof list === 'object' && !Array.isArray(list)) add(undefined, list);
      else if (Array.isArray(list) && list.length && list[0] && typeof list[0] === 'object') add((list[0] as Record<string, unknown>).season, list);
    }
  } else if (eps && typeof eps === 'object') {
    const m = eps as Record<string, unknown>;
    for (const k of Object.keys(m)) add(k, m[k]);
  }
  const info = (j.info && typeof j.info === 'object' ? j.info : {}) as Record<string, unknown>;
  const merged = seriesFromJson({ ...info, series_id: base.id, category_id: base.categoryId });
  const seasonInfo: Record<number, SeasonInfo> = {};
  for (const s of Array.isArray(j.seasons) ? (j.seasons as Record<string, unknown>[]) : []) {
    if (!s || typeof s !== 'object') continue;
    const n = asInt(s.season_number) || 0;
    const air = asDate(s.air_date);
    seasonInfo[n] = {
      number: n,
      name: asStr(s.name),
      overview: asStr(s.overview),
      airDate: air,
      cover: asStr(s.cover_big) || asStr(s.cover),
      rating: asDouble(s.vote_average),
    };
  }
  return {
    series: {
      id: base.id,
      name: merged.name === untitled || merged.name === untitledName ? base.name : merged.name,
      cover: merged.cover || base.cover,
      backdrop: merged.backdrop || base.backdrop,
      rating: (merged.rating || 0) > 0 ? merged.rating : base.rating, // a 0 in the details is no rating
      year: merged.year || base.year,
      plot: merged.plot || base.plot,
      genre: merged.genre || base.genre,
      cast: merged.cast || base.cast,
      director: merged.director || base.director,
      trailer: merged.trailer || base.trailer,
      episodeRuntimeMins: merged.episodeRuntimeMins || base.episodeRuntimeMins,
      updated: merged.updated || base.updated,
      categoryId: base.categoryId,
      tmdbId: merged.tmdbId || base.tmdbId,
    },
    seasons: Object.keys(seasons)
      .map(Number)
      .sort((a, b) => a - b)
      .map((n) => ({ number: n, episodes: seasons[n] })),
    seasonInfo,
  };
}
