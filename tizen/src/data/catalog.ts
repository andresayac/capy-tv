// The whole catalog of a playlist, loaded once per session (Xtream has no search or sort
// endpoints), with the views the screens are built from (app/lib/data/catalog.dart).
import { versionKey } from './matching';
import { fold } from './titles';
import { Movie, Series, splitGenres } from './models';
import { offThread } from './parsing';
import { ContentSource, LiveChannel } from './source';

/** Over this many titles, telling versions apart is worked out in the parsing worker, as Flutter does. */
const MANY = 2000;

/** The version key of every movie and every series: in the worker when there are many. */
async function versionKeys(movies: Movie[], series: Series[]): Promise<[string[], string[]] | undefined> {
  if (movies.length + series.length < MANY) return undefined;
  const names = [movies.map((m) => [m.name, m.year]), series.map((s) => [s.name, s.year])];
  const reply = await offThread<{ keys?: string[][] }>({ op: 'keys', names }).catch(() => null);
  const keys = reply && reply.keys;
  return keys && keys.length === 2 && keys[0].length === movies.length && keys[1].length === series.length ? [keys[0], keys[1]] : undefined;
}

export class Catalog {
  private data: Promise<CatalogData> | null = null;
  /** The catalog once loaded, for what cannot wait for it. */
  loaded: CatalogData | null = null;

  constructor(readonly source: ContentSource) {}

  load(): Promise<CatalogData> {
    if (this.data) return this.data;
    // One failing list (a panel without series) must not break the others, but it is not kept
    // either: the next load asks for it again
    let error: unknown = null;
    const safe = <T,>(p: Promise<T[]>) =>
      p.catch((e) => {
        if (error === null) error = e;
        return [] as T[];
      });
    const loading = Promise.all([safe(this.source.liveChannels()), safe(this.source.movies()), safe(this.source.series())]).then(
      async ([live, movies, series]) => {
        if (error !== null && this.data === loading) this.data = null;
        if (!live.length && !movies.length && !series.length && error !== null) throw error;
        return (this.loaded = new CatalogData(live, movies, series, new Date(), await versionKeys(movies, series)));
      },
    );
    this.data = loading;
    loading.catch(() => {
      if (this.data === loading) this.data = null;
    });
    return loading;
  }
}

const byDateDesc = (a?: Date, b?: Date) => (b ? b.getTime() : 0) - (a ? a.getTime() : 0);

export class CatalogData {
  private movieKey = new Map<Movie, string>();
  private seriesKey = new Map<Series, string>();
  private movieVersions: Record<string, Movie[]> = {};
  private seriesVersions: Record<string, Series[]> = {};
  private memo: Record<string, unknown> = {};

  /** [keys]: the version key of each movie and each series, when worked out already. */
  constructor(readonly live: LiveChannel[], readonly movies: Movie[], readonly series: Series[], private now = new Date(), keys?: [string[], string[]]) {
    // Versions: a provider may list a title once per language or quality, and two providers
    // combined list it twice. Rows show it once; its page lists them all.
    movies.forEach((m, i) => {
      const k = keys ? keys[0][i] : versionKey(m.name, m.year);
      this.movieKey.set(m, k);
      (this.movieVersions[k] || (this.movieVersions[k] = [])).push(m);
    });
    series.forEach((s, i) => {
      const k = keys ? keys[1][i] : versionKey(s.name, s.year);
      this.seriesKey.set(s, k);
      (this.seriesVersions[k] || (this.seriesVersions[k] = [])).push(s);
    });
  }

  private once<T>(name: string, make: () => T): T {
    if (!(name in this.memo)) this.memo[name] = make();
    return this.memo[name] as T;
  }

  /** Every version of [m]'s title, [m] among them. */
  versionsOf(m: Movie): Movie[] {
    return this.movieVersions[this.movieKey.get(m) || versionKey(m.name, m.year)] || [m];
  }

  seriesVersionsOf(s: Series): Series[] {
    return this.seriesVersions[this.seriesKey.get(s) || versionKey(s.name, s.year)] || [s];
  }

  /** [items] with each title once: its first version. */
  private oneEach(items: Movie[]): Movie[] {
    const seen: Record<string, true> = {};
    return items.filter((m) => {
      const k = this.movieKey.get(m) || versionKey(m.name, m.year);
      return seen[k] ? false : (seen[k] = true);
    });
  }

  private oneEachSeries(items: Series[]): Series[] {
    const seen: Record<string, true> = {};
    return items.filter((s) => {
      const k = this.seriesKey.get(s) || versionKey(s.name, s.year);
      return seen[k] ? false : (seen[k] = true);
    });
  }

  // Movies

  get recentMovies(): Movie[] {
    return this.once('recentMovies', () => this.oneEach(this.movies.slice().sort((a, b) => byDateDesc(a.added, b.added))));
  }

  /** Well rated and fairly recent, so the row is not all decades-old classics. */
  get topMovies(): Movie[] {
    const year = this.now.getFullYear();
    return this.once('topMovies', () =>
      this.oneEach(this.movies.filter((m) => (m.rating || 0) >= 7 && (m.year || 0) >= year - 6 && m.poster).sort((a, b) => (b.rating || 0) - (a.rating || 0))),
    );
  }

  /** This year's (and late last year's) releases, newest first. */
  get newReleases(): Movie[] {
    const from = this.now.getFullYear() - (this.now.getMonth() <= 1 ? 1 : 0);
    return this.once('newReleases', () =>
      this.oneEach(
        this.movies.filter((m) => (m.year || 0) >= from && m.poster).sort((a, b) => byDateDesc(a.releaseDate || a.added, b.releaseDate || b.added)),
      ),
    );
  }

  get movieGenres(): string[] {
    return this.once('movieGenres', () => genresByCount(this.movies.map((m) => splitGenres(m.genre))));
  }

  moviesIn(genre: string): Movie[] {
    const k = genreKey(genre);
    return this.recentMovies.filter((m) => splitGenres(m.genre).some((g) => genreKey(g) === k));
  }

  /** Picks for the hero: recent, rated, with artwork and a synopsis. */
  get featuredMovies(): Movie[] {
    return this.once('featuredMovies', () => this.recentMovies.filter((m) => (m.rating || 0) >= 6.5 && m.poster && m.plot).slice(0, 6));
  }

  /** Same main genre, best rated first, excluding [m] itself. */
  similarMovies(m: Movie, limit = 20): Movie[] {
    const g = splitGenres(m.genre)[0];
    if (!g) return [];
    const own = this.versionsOf(m);
    return this.oneEach(
      this.movies.filter((x) => own.indexOf(x) < 0 && x.poster && splitGenres(x.genre).indexOf(g) >= 0).sort((a, b) => (b.rating || 0) - (a.rating || 0)),
    ).slice(0, limit);
  }

  // Series

  get recentSeries(): Series[] {
    return this.once('recentSeries', () => this.oneEachSeries(this.series.slice().sort((a, b) => byDateDesc(a.updated, b.updated))));
  }

  get topSeries(): Series[] {
    const year = this.now.getFullYear();
    return this.once('topSeries', () =>
      this.oneEachSeries(
        this.series.filter((s) => (s.rating || 0) >= 7.5 && (s.year || 0) >= year - 8 && s.cover).sort((a, b) => (b.rating || 0) - (a.rating || 0)),
      ),
    );
  }

  get seriesGenres(): string[] {
    return this.once('seriesGenres', () => genresByCount(this.series.map((s) => splitGenres(s.genre))));
  }

  seriesIn(genre: string): Series[] {
    const k = genreKey(genre);
    return this.recentSeries.filter((s) => splitGenres(s.genre).some((g) => genreKey(g) === k));
  }

  get featuredSeries(): Series[] {
    return this.once('featuredSeries', () => this.recentSeries.filter((s) => (s.rating || 0) >= 6.5 && s.backdrop && s.plot).slice(0, 6));
  }

  similarSeries(s: Series, limit = 20): Series[] {
    const g = splitGenres(s.genre)[0];
    if (!g) return [];
    const own = this.seriesVersionsOf(s);
    return this.oneEachSeries(
      this.series.filter((x) => own.indexOf(x) < 0 && x.cover && splitGenres(x.genre).indexOf(g) >= 0).sort((a, b) => (b.rating || 0) - (a.rating || 0)),
    ).slice(0, limit);
  }
}

const genreKeys: Record<string, string> = {};

/** A genre however it is written: "Acción", "Accion" and "ACCIÓN" are one. Worked out once per spelling, as there are few. */
function genreKey(g: string): string {
  return genreKeys[g] || (genreKeys[g] = fold(g).trim());
}

/** The genres, most common first, each once as most of its titles write it. */
function genresByCount(all: string[][]): string[] {
  const counts: Record<string, number> = {};
  const spellings: Record<string, Record<string, number>> = {};
  for (const list of all) {
    for (const g of list) {
      const k = genreKey(g);
      counts[k] = (counts[k] || 0) + 1;
      const s = spellings[k] || (spellings[k] = {});
      s[g] = (s[g] || 0) + 1;
    }
  }
  const shown = (k: string) => Object.keys(spellings[k]).reduce((a, b) => (spellings[k][b] > spellings[k][a] ? b : a));
  return Object.keys(counts)
    .sort((a, b) => counts[b] - counts[a])
    .map(shown);
}
