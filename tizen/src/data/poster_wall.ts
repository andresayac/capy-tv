// Posters for the screens outside a playlist (app/lib/data/poster_wall.dart), so they are not bare
// black: what is trending this week when the app has a TMDB key, else the best rated recent movies
// and series of the playlist opened last, from the provider itself. Never adult content, nor
// horror: anyone in the family sees these screens.
//
// Only the list of addresses is kept (localStorage); the TV's HTTP cache keeps the images, so the
// wall shows at once from the next start on.
import { Notifier } from '../ui/components';
import { CatalogData } from './catalog';
import { isAdultRating } from './kids';
import { Movie, Series } from './models';
import { trending } from './trending';

const SIZE = 40;
const PREF = 'posterWall'; // Flutter's key
const SCARY = /horror|terror|gore|slasher|thriller|suspens|crim|b[eé]lic|guerra|\bwar\b|er[oó]t|adult/i;

function saved(): string[] {
  try {
    const list = JSON.parse(localStorage.getItem(PREF) || '[]');
    return Array.isArray(list) ? list.filter((x): x is string => typeof x === 'string') : [];
  } catch {
    return [];
  }
}

class PosterWallStore extends Notifier {
  /** The provider's posters, best first; empty until a playlist has been opened. Read at startup. */
  posters: string[] = saved();

  constructor() {
    super();
    // The wall may change with the trends too
    trending.listen(() => this.notify());
  }

  /** The posters to show: the trending ones when there are enough, else the provider's. */
  get wall(): string[] {
    // Never one rated for adults only: anyone in the family sees these screens
    const trend: string[] = [];
    for (const t of trending.items) if (t.mature === false && t.poster) trend.push(t.poster);
    return trend.length >= 8 ? trend : this.posters;
  }

  /**
   * Notes the posters of [data], a playlist's catalog. Only from a catalog without adult content
   * ([adultHidden]): one that shows it could slip some in.
   */
  remember(data: CatalogData, adultHidden: boolean): void {
    if (!adultHidden) return;
    const picked = pick(data);
    if (picked.length < 8 || same(picked, this.posters)) return; // too few for a wall: keep the last
    this.posters = picked;
    try {
      localStorage.setItem(PREF, JSON.stringify(picked));
    } catch {
      // Shown this session; noted again next time
    }
    this.notify();
  }
}

function same(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/** The artwork of each list in turn, read only as far as needed (recentMovies sorts them all). */
function* art<T>(lists: (() => T[])[], url: (x: T) => string | undefined, genre: (x: T) => string | undefined, age?: (x: T) => string | undefined): Generator<string> {
  // Those with a genre first: one without it only makes up the numbers, as nothing vouches for it
  for (const known of [true, false]) {
    for (const list of lists) {
      for (const x of list()) {
        const u = url(x);
        const g = genre(x) || '';
        if (!!g !== known || !u || u.indexOf('http') !== 0) continue;
        if (!SCARY.test(g) && !isAdultRating(age && age(x))) yield u;
      }
    }
  }
}

/**
 * Up to [SIZE] posters of [data]: best rated recent movies and series, then the newest, two movies
 * for each series. With artwork, without horror, each once.
 */
export function pick(data: CatalogData): string[] {
  const movies = art<Movie>([() => data.topMovies, () => data.newReleases, () => data.recentMovies], (m) => m.poster, (m) => m.genre, (m) => m.ageRating);
  const series = art<Series>([() => data.topSeries, () => data.recentSeries], (s) => s.cover, (s) => s.genre);
  const picked: string[] = [];
  const seen: Record<string, true> = {};
  for (let turn = 0; picked.length < SIZE; turn++) {
    const [first, then] = turn % 3 === 2 ? [series, movies] : [movies, series];
    let next = first.next();
    if (next.done) next = then.next();
    if (next.done) break;
    if (!seen[next.value]) {
      seen[next.value] = true;
      picked.push(next.value);
    }
  }
  return picked;
}

export const posterWall = new PosterWallStore();
