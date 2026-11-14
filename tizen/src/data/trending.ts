// What is trending this week in movies and series, from TMDB (app/lib/data/trending.dart): asked
// at most once a day and kept on the TV; nothing about the user goes with the request but the
// language. Needs a TMDB key at build time (TMDB_API_KEY in the repo's .env).
import { Notifier } from '../ui/components';
import { CatalogData } from './catalog';
import { bareTitle, looseTitle, yearInTitle } from './matching';
import { Movie, Series } from './models';

declare const __TMDB_KEY__: string;
export const API_KEY = typeof __TMDB_KEY__ === 'string' ? __TMDB_KEY__ : '';

export interface Trend {
  series: boolean; // else a movie
  tmdbId: number;
  title: string; // in the app's language
  originalTitle: string;
  year?: number;
  rating?: number;
  poster?: string;
  backdrop?: string;
  overview?: string;
  /** Its title in other languages, to find it in a catalog in another language. */
  otherTitles?: string[];
  /** Rated for adults only: never on the screens the whole family sees. Unset when TMDB could not tell: treated as if it were, and asked again. */
  mature?: boolean;
  /** Rated for children (G, PG, TV-Y, TV-Y7, TV-G, TV-PG): all that a kids profile is offered. */
  kidsSafe?: boolean;
}

const trendKey = (t: Trend) => `${t.series ? 'tv' : 'movie'}/${t.tmdbId}`;

function fromTmdb(r: Record<string, unknown>, series: boolean): Trend {
  const image = (size: string, path: unknown) => (typeof path === 'string' && path[0] === '/' ? `https://image.tmdb.org/t/p/${size}${path}` : undefined);
  const title = String((series ? r.name : r.title) || '');
  const date = String((series ? r.first_air_date : r.release_date) || '');
  const year = parseInt(date.split('-')[0], 10);
  const overview = typeof r.overview === 'string' && r.overview.trim() ? r.overview.trim() : undefined;
  return {
    series,
    tmdbId: Number(r.id),
    title,
    originalTitle: String((series ? r.original_name : r.original_title) || title),
    year: isNaN(year) ? undefined : year,
    rating: typeof r.vote_average === 'number' ? r.vote_average : undefined,
    poster: image('w342', r.poster_path),
    backdrop: image('w1280', r.backdrop_path),
    overview,
  };
}

const MAX_AGE = 24 * 60 * 60 * 1000;

/** Saved at [at], less than MAX_AGE ago and not in the future: one saved while the clock was ahead would never be renewed. */
function fresh(at: number): boolean {
  const age = Date.now() - at;
  return age >= 0 && age < MAX_AGE;
}
const HORROR = 27; // TMDB genre of movies: anyone in the family sees these screens. Series: matureSeries
const PREF = 'trending';
const ALT = 'trending.otherTitles';

export async function tmdb(path: string, query: Record<string, string>): Promise<Record<string, unknown>> {
  let url = `https://api.themoviedb.org/3/${path}?api_key=${API_KEY}`;
  for (const k of Object.keys(query)) url += `&${k}=${encodeURIComponent(query[k])}`;
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 15000);
  try {
    const res = await fetch(url, { signal: abort.signal });
    if (res.status !== 200) throw new Error(`TMDB ${res.status}`);
    return await res.json(); // its body within the time limit too, not only its headers
  } finally {
    clearTimeout(timer);
  }
}

function readJson(key: string): Record<string, unknown> {
  try {
    return JSON.parse(localStorage.getItem(key) || '{}');
  } catch {
    return {};
  }
}

class TrendingStore extends Notifier {
  /** Movies and series in turns, most trending first. Empty without a key or before the first answer. */
  items: Trend[] = [];
  /** The language TMDB was last asked in ("es-ES"). */
  language = 'en-US';
  private otherTitles: Record<string, string> = {};
  private indexes = new WeakMap<CatalogData, Index>();

  private withOtherTitles(list: Trend[]): Trend[] {
    return list.map((t) => {
      const other = this.otherTitles[trendKey(t)];
      return other && other !== t.title && other !== t.originalTitle ? { ...t, otherTitles: [other] } : t;
    });
  }

  /** What was fetched last time. */
  load(): void {
    const j = readJson(PREF);
    if (!Array.isArray(j.items)) return;
    this.language = (j.language as string) || this.language;
    this.otherTitles = (readJson(ALT).titles as Record<string, string>) || {};
    this.items = this.withOtherTitles(j.items as Trend[]);
    this.notify();
  }

  /** Asks TMDB again when what is kept is a day old or in another language. */
  async refresh(language: string): Promise<void> {
    if (!API_KEY) return;
    this.language = language;
    const saved = readJson(PREF);
    if (saved.language === language && fresh(Number(saved.at || 0)) && this.items.length) return;
    try {
      const page = async (kind: string, n: number) =>
        ((await tmdb(`trending/${kind}/week`, { language, page: String(n) })).results as Record<string, unknown>[]) || [];
      const r = await Promise.all([page('movie', 1), page('movie', 2), page('tv', 1), page('tv', 2)]);
      const unrated = pick(r[0].concat(r[1]), r[2].concat(r[3]));
      if (!unrated.length) return;
      const picked = await this.rate(unrated);
      this.items = this.withOtherTitles(picked);
      localStorage.setItem(PREF, JSON.stringify({ at: Date.now(), language, items: picked }));
      this.notify();
    } catch {
      // The last answer stays
    }
  }

  /** Also this week's trends in the language a provider's catalog is in, when it is not the app's. */
  async alsoIn(catalogLanguage: string | null): Promise<void> {
    if (!API_KEY || !catalogLanguage || this.language.split('-')[0] === catalogLanguage) return;
    const saved = readJson(ALT);
    if (saved.language === catalogLanguage && fresh(Number(saved.at || 0))) return;
    try {
      const page = async (kind: string, n: number) =>
        (((await tmdb(`trending/${kind}/week`, { language: catalogLanguage, page: String(n) })).results as Record<string, unknown>[]) || []).map(
          (x): [string, string] => [`${kind}/${x.id}`, String(x.title || x.name || '')],
        );
      const pages = await Promise.all([page('movie', 1), page('movie', 2), page('tv', 1), page('tv', 2)]);
      this.otherTitles = {};
      for (const list of pages) for (const [k, title] of list) if (title) this.otherTitles[k] = title;
      this.items = this.withOtherTitles(this.items);
      localStorage.setItem(ALT, JSON.stringify({ at: Date.now(), language: catalogLanguage, titles: this.otherTitles }));
      this.notify();
    } catch {
      // Asked again next time
    }
  }

  /** Trends with their age rating: from what was known already, else asked of TMDB, ten at a time. */
  private async rate(trends: Trend[]): Promise<Trend[]> {
    const known: Record<string, Trend> = {};
    for (const t of this.items) if (t.mature !== undefined && t.kidsSafe !== undefined) known[trendKey(t)] = t;
    const rate = async (t: Trend): Promise<Trend> => {
      const k = known[trendKey(t)];
      if (k) return { ...t, mature: k.mature, kidsSafe: k.kidsSafe };
      try {
        const j = t.series ? await tmdb(`tv/${t.tmdbId}`, { append_to_response: 'content_ratings,keywords' }) : await tmdb(`movie/${t.tmdbId}/release_dates`, {});
        const results = t.series ? part(j, 'content_ratings') : (j.results as Record<string, unknown>[]) || [];
        const mature = t.series ? matureSeries(j) : matureRating(results);
        return { ...t, mature, kidsSafe: mature !== true && kidsSafeRating(results) };
      } catch {
        return t;
      }
    };
    const rated: Trend[] = [];
    for (let i = 0; i < trends.length; i += 10) rated.push(...(await Promise.all(trends.slice(i, i + 10).map(rate))));
    return rated;
  }

  /** The trends a playlist's catalog has, with the movie or series that plays each. */
  available(data: CatalogData, forKids = false): { trend: Trend; item: Movie | Series }[] {
    let index = this.indexes.get(data);
    if (!index) this.indexes.set(data, (index = new Index(data)));
    const found: { trend: Trend; item: Movie | Series }[] = [];
    const seen = new Set<Movie | Series>();
    for (const t of this.items) {
      if (forKids && t.kidsSafe !== true) continue;
      const hit = t.series ? index.series(t) : index.movie(t);
      if (hit && !seen.has(hit)) {
        seen.add(hit);
        found.push({ trend: t, item: hit });
      }
    }
    return found;
  }

  /** The movies or series of [available], most trending first. */
  ofKind(data: CatalogData, series: boolean, forKids = false): (Movie | Series)[] {
    return this.available(data, forKids)
      .filter((x) => x.trend.series === series)
      .map((x) => x.item);
  }
}

/**
 * Whether TMDB's ratings say adults only: R, NC-17 or TV-MA in the US; without a real US rating
 * (none, NR or UR), 18 or more anywhere: Korea's top one is 19, Singapore's R21. Undefined when
 * no country has a real one.
 */
function matureRating(results: Record<string, unknown>[]): boolean | undefined {
  const ratings = countryRatings(results);
  const countries = Object.keys(ratings);
  if (countries.every((k) => !ratings[k].length)) return undefined;
  const us = ratings.US;
  if (us && us.length) return us.some((x) => x === 'R' || x === 'NC-17' || x === 'TV-MA');
  return countries.some((k) => ratings[k].some((x) => x.indexOf('18') >= 0 || x === '19' || x.indexOf('21') >= 0));
}

/** Whether the US ratings of a title are all for children; other countries' scales say too little. */
function kidsSafeRating(results: Record<string, unknown>[]): boolean {
  const us = countryRatings(results).US || [];
  return us.length > 0 && us.every((x) => ['G', 'PG', 'TV-Y', 'TV-Y7', 'TV-G', 'TV-PG'].indexOf(x) >= 0);
}

/** Each country's real ratings: an empty one, NR and UR say nothing. */
function countryRatings(results: Record<string, unknown>[]): Record<string, string[]> {
  const ratings: Record<string, string[]> = {};
  for (const r of results) {
    const found = [r.rating, ...((r.release_dates as Record<string, unknown>[]) || []).map((d) => d.certification)];
    ratings[String(r.iso_3166_1)] = found.filter((x): x is string => typeof x === 'string' && x !== '' && x !== 'NR' && x !== 'UR');
  }
  return ratings;
}

function part(details: Record<string, unknown>, name: string): Record<string, unknown>[] {
  return (((details[name] || {}) as Record<string, unknown>).results || []) as Record<string, unknown>[];
}

/** Adults only by [matureRating], or horror, which only a keyword tells: TMDB has no such genre for series. */
function matureSeries(details: Record<string, unknown>): boolean | undefined {
  if (part(details, 'keywords').some((k) => String(k.name).toLowerCase().indexOf('horror') >= 0)) return true;
  return matureRating(part(details, 'content_ratings'));
}

/** With artwork, never adult content nor horror, movies and series in turns. */
function pick(movies: Record<string, unknown>[], series: Record<string, unknown>[]): Trend[] {
  const fit = (r: Record<string, unknown>) =>
    r.adult !== true && ((r.genre_ids as number[]) || []).indexOf(HORROR) < 0 && typeof r.poster_path === 'string' && typeof r.backdrop_path === 'string';
  const m = movies.filter(fit).map((r) => fromTmdb(r, false));
  const s = series.filter(fit).map((r) => fromTmdb(r, true));
  const out: Trend[] = [];
  const seen: Record<string, true> = {};
  for (let i = 0; i < m.length || i < s.length; i++) {
    for (const t of [m[i], s[i]]) {
      if (t && !seen[trendKey(t)]) {
        seen[trendKey(t)] = true;
        out.push(t);
      }
    }
  }
  return out;
}

/** A catalog's movies and series by TMDB id and by loose title, built once per catalog. */
class Index {
  private moviesById: Record<string, Movie> = {};
  private seriesById: Record<string, Series> = {};
  private moviesByTitle: Record<string, Movie[]> = {};
  private seriesByTitle: Record<string, Series[]> = {};

  constructor(data: CatalogData) {
    for (const m of data.movies) {
      if (m.tmdbId) this.moviesById[m.tmdbId] = m;
      const k = bareTitle(m.name);
      (this.moviesByTitle[k] || (this.moviesByTitle[k] = [])).push(m);
    }
    for (const s of data.series) {
      if (s.tmdbId) this.seriesById[s.tmdbId] = s;
      const k = bareTitle(s.name);
      (this.seriesByTitle[k] || (this.seriesByTitle[k] = [])).push(s);
    }
  }

  movie(t: Trend): Movie | undefined {
    return this.moviesById[String(t.tmdbId)] || byTitle(t, this.moviesByTitle, (m) => m.year || yearInTitle(m.name));
  }

  series(t: Trend): Series | undefined {
    return this.seriesById[String(t.tmdbId)] || byTitle(t, this.seriesByTitle, (s) => s.year || yearInTitle(s.name));
  }
}

function byTitle<T>(t: Trend, index: Record<string, T[]>, year: (x: T) => number | undefined): T | undefined {
  const titles = [t.title, t.originalTitle].concat(t.otherTitles || []).map((x) => bareTitle(x));
  // A copy with no year may be it, but one with the right year is: that one first
  let undated: T | undefined;
  for (const title of titles) {
    if (!title) continue;
    for (const x of index[title] || []) {
      const y = year(x);
      if (t.year === undefined) return x;
      if (y === undefined) {
        if (undated === undefined) undated = x;
      } else if (Math.abs(y - t.year) <= 1) {
        // Same title, another film (a remake, an older series): the year tells them apart
        return x;
      }
    }
  }
  return undated;
}

/** The language most of a catalog's names are in, by their small words; null when unclear. */
export function guessLanguage(names: string[]): string | null {
  const markers: Record<string, string[]> = {
    es: ['el', 'los', 'las', 'del', 'y'],
    en: ['the', 'of', 'and'],
    pt: ['os', 'do', 'da', 'dos', 'das', 'uma'],
    fr: ['le', 'les', 'des', 'du', 'et'],
    de: ['der', 'die', 'das', 'und'],
    it: ['il', 'gli', 'della', 'dei', 'delle'],
  };
  const counts: Record<string, number> = {};
  for (const l of Object.keys(markers)) counts[l] = 0;
  for (const name of names.slice(0, 5000)) {
    for (const w of looseTitle(name).split(' ')) for (const l of Object.keys(markers)) if (markers[l].indexOf(w) >= 0) counts[l]++;
  }
  const ranked = Object.keys(counts).sort((a, b) => counts[b] - counts[a]);
  return counts[ranked[0]] >= 20 && counts[ranked[0]] > counts[ranked[1]] * 1.5 ? ranked[0] : null;
}

export const trending = new TrendingStore();
