// Which trailer a title has (app/lib/ui/trailer.dart, app/lib/data/trending.dart): the provider's
// own, else TMDB's, in the app's language when there is one, else in English.
import { bareTitle, looseTitle, yearInTitle } from './matching';
import { Movie, Series } from './models';
import { fullMovie } from './movie_details';
import { ContentSource } from './source';
import { API_KEY, tmdb, Trend, trending } from './trending';

/** The YouTube id in what a provider gives as a trailer: an id, or a YouTube address. */
export function youtubeId(v?: string): string | null {
  const t = (v || '').trim();
  if (/^[\w-]{11}$/.test(t)) return t;
  const m = /(?:v=|youtu\.be\/|embed\/|shorts\/)([\w-]{11})/.exec(t);
  return m ? m[1] : null;
}

/** The best of TMDB's videos: a trailer before a teaser, official ones first; only YouTube. */
function pickTrailer(videos: Record<string, unknown>[]): string | null {
  const ranked: [number, string][] = [];
  videos.forEach((v, i) => {
    if (v.site !== 'YouTube' || typeof v.key !== 'string') return;
    const type = v.type === 'Trailer' ? 0 : v.type === 'Teaser' ? 2 : null;
    if (type === null) return;
    ranked.push([(type + (v.official === true ? 0 : 1)) * 1000 + i, v.key]);
  });
  ranked.sort((a, b) => a[0] - b[0]);
  return ranked.length ? ranked[0][1] : null;
}

const found: Record<string, Promise<string | null>> = {};

/**
 * The trailer of a title: by its TMDB id when known, else found on TMDB by [title] (or
 * [originalTitle]) and [year]. Only a search result with the same title counts, so a namesake
 * does not lend its trailer. Asked once per session.
 */
export function findTrailer(p: { series: boolean; tmdbId?: string; title: string; originalTitle?: string; year?: number }): Promise<string | null> {
  const id = p.tmdbId ? `${p.series}/${p.tmdbId}` : `${p.series}/${looseTitle(p.title)}/${p.year || ''}`;
  if (id in found) return found[id];
  const kind = p.series ? 'tv' : 'movie';
  const lookup = (async () => {
    if (!API_KEY) return null;
    let tmdbId = p.tmdbId || null;
    for (const name of [p.title, p.originalTitle].filter(Boolean) as string[]) {
      if (tmdbId) break;
      const wanted = bareTitle(name);
      if (!wanted) continue;
      // TMDB's year is exact; when the provider's is one off, asked again without it, and only a
      // result a year apart at most counts
      for (const withYear of p.year ? [true, false] : [false]) {
        if (tmdbId) break;
        const query: Record<string, string> = { query: wanted, language: trending.language };
        if (withYear) query[p.series ? 'first_air_date_year' : 'year'] = String(p.year);
        const results = ((await tmdb(`search/${kind}`, query)).results as Record<string, unknown>[]) || [];
        const hit = results.filter((r) => {
          const same = [r[p.series ? 'name' : 'title'], r[p.series ? 'original_name' : 'original_title']].some(
            (x) => typeof x === 'string' && bareTitle(x) === wanted,
          );
          if (!same || withYear || !p.year) return same;
          const y = parseInt(String(r[p.series ? 'first_air_date' : 'release_date'] || '').split('-')[0], 10);
          return !isNaN(y) && Math.abs(y - p.year) <= 1;
        })[0];
        if (hit) tmdbId = String(hit.id);
      }
    }
    if (!tmdbId) return null;
    for (const lang of [trending.language, 'en-US'].filter((x, i, all) => all.indexOf(x) === i)) {
      const videos = ((await tmdb(`${kind}/${tmdbId}/videos`, { language: lang })).results as Record<string, unknown>[]) || [];
      const key = pickTrailer(videos);
      if (key) return key;
    }
    return null;
  })().catch(() => {
    delete found[id]; // asked again next time
    return null;
  });
  return (found[id] = lookup);
}

export function trendTrailer(t: Trend): Promise<string | null> {
  return findTrailer({ series: t.series, tmdbId: String(t.tmdbId), title: t.title });
}

const movieTrailers: Record<string, Promise<string | null>> = {};

/**
 * A provider's movie: its own trailer from the full record, else TMDB's; once per movie. The record
 * is the one the hero's backdrop came from, when it did: a TV asks the provider once.
 */
export function movieTrailer(source: ContentSource, movie: Movie): Promise<string | null> {
  if (movie.id in movieTrailers) return movieTrailers[movie.id];
  // Without the full record, the listing's name and year will do
  return (movieTrailers[movie.id] = fullMovie(source, movie).then(
    (m) => youtubeId(m.trailer) || findTrailer({ series: false, tmdbId: m.tmdbId, title: m.name, originalTitle: m.originalName, year: m.year || yearInTitle(m.name) }),
  ));
}

/** A provider's series: its own trailer, else TMDB's (by name and year: series rarely carry a TMDB id). */
export function seriesTrailer(s: Series): Promise<string | null> {
  return Promise.resolve(youtubeId(s.trailer) || findTrailer({ series: true, tmdbId: s.tmdbId, title: s.name, year: s.year || yearInTitle(s.name) }));
}
