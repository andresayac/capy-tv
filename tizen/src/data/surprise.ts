// "Surprise me" for an evening without a plan (app/lib/data/surprise.dart): a title picked at
// random for a mood among the provider's well rated ones that a profile has not watched.
import { CatalogData } from './catalog';
import { Library, watchedFor } from './library';
import { looseTitle, versionKey } from './matching';
import { Movie, Series, splitGenres } from './models';

/** What someone feels like watching, told by the genres providers write, in Spanish or English. */
export const MOODS: Record<string, string[]> = {
  laugh: ['comedia', 'comedy', 'humor'],
  action: ['accion', 'action', 'belic', 'guerra', 'war'], // not adventure alone: that is often a cartoon
  suspense: ['suspense', 'suspenso', 'thriller', 'crimen', 'crime', 'misterio', 'mystery', 'polici'],
  family: ['familia', 'family', 'animacion', 'animation', 'infantil', 'ninos', 'dibujos', 'kids', 'musical'],
  romance: ['romance', 'romantica', 'romantico'],
  scary: ['terror', 'horror'],
  different: ['documental', 'documentary', 'historia', 'history', 'ciencia ficcion', 'science fiction', 'sci fi', 'fantasia', 'fantasy', 'western'],
};

export type Mood = keyof typeof MOODS;

function fits(mood: Mood, genre?: string): boolean {
  const anyOf = (words: string[]) =>
    splitGenres(genre).some((g) => {
      const f = looseTitle(g);
      return words.some((w) => f.indexOf(w) >= 0);
    });
  // An animated horror is animation too
  return anyOf(MOODS[mood]) && !(mood === 'family' && anyOf(MOODS.scary));
}

/**
 * A catalog that says neither genres nor ratings (M3U lists, some panels) gets one at random,
 * except for a [kids] profile, where nothing says what suits it.
 */
export class Surprise {
  private shown: Record<string, true> = {}; // titles offered already, not offered again

  constructor(readonly data: CatalogData, readonly library: Library | null, readonly kids = false) {}

  /** Whether the provider says enough of its series or its movies to pick by mood: a genre and a rating on any of them. */
  picksByMood(series: boolean): boolean {
    const told = (x: Movie | Series) => (x.rating || 0) > 0 && splitGenres(x.genre).length > 0;
    return series ? this.data.recentSeries.some(told) : this.data.recentMovies.some(told);
  }

  private fitsMemo: Partial<Record<Mood, Record<string, boolean>>> = {};

  /** A movie or a series for [mood], or null when none is left. */
  next(mood: Mood, series: boolean): Movie | Series | null {
    const byMood = this.picksByMood(series);
    if (!byMood && this.kids) return null;
    // Worked out once per way the provider writes the genres: few such strings, many titles
    const memo = this.fitsMemo[mood] || (this.fitsMemo[mood] = {});
    const fitsMood = (genre?: string) => {
      const k = genre || '';
      if (!(k in memo)) memo[k] = fits(mood, genre);
      return memo[k];
    };
    const suits = (x: Movie | Series) => !byMood || ((x.rating || 0) >= 6.5 && fitsMood(x.genre));
    // By words only: an episode does not know its series' year
    const words = (key: string) => key.split('|')[0];
    const watched: Record<string, true> = {};
    // Opened for a few seconds, or one that failed to start, is still to be offered
    for (const h of this.library ? this.library.history : []) if (watchedFor(h)) watched[words(versionKey(h.ref.seriesTitle || h.ref.title))] = true;
    const fresh = (name: string, year?: number) => {
      const key = versionKey(name, year);
      return !this.shown[key] && !watched[words(key)];
    };
    const pool: (Movie | Series)[] = series
      ? this.data.recentSeries.filter((s) => s.cover && suits(s) && fresh(s.name, s.year))
      : this.data.recentMovies.filter((m) => m.poster && suits(m) && fresh(m.name, m.year));
    if (!pool.length) return null;
    // The best rated of the newest first, with a little chance for the rest
    const top = pool
      .slice(0, 400)
      .sort((a, b) => (b.rating || 0) - (a.rating || 0))
      .slice(0, 40);
    const pick = top[Math.floor(Math.random() * top.length)];
    this.shown[versionKey(pick.name, pick.year)] = true;
    return pick;
  }
}
