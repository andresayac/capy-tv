// Favorites and history carried from one playlist to another of a different provider, where every
// id is different (app/lib/data/matching.dart, LibraryMigration; app/lib/ui/account_screen.dart).
import { CatalogData } from './catalog';
import { channelRef, episodeRef, HistoryEntry, Library, MediaRef, movieRef, refKey, seriesRef } from './library';
import { looseChannel, looseTitle, yearInTitle } from './matching';
import { Episode, Movie, Series, SeriesDetail } from './models';
import { mergeInto } from './open_library';
import { profileStore } from './profiles';
import { ContentSource, LiveChannel } from './source';

export interface MigrationResult {
  moved: number;
  missing: string[]; // titles the new provider does not seem to have
}

function group<T>(items: T[], key: (x: T) => string): Map<string, T[]> {
  const map = new Map<string, T[]>();
  for (const x of items) {
    const k = key(x);
    const list = map.get(k);
    if (list) list.push(x);
    else map.set(k, [x]);
  }
  return map;
}

const sameYear = (a?: number, b?: number) => a === undefined || b === undefined || Math.abs(a - b) <= 1;

/**
 * Looks for each item in [catalog], the new provider's: movies and series by title and year (the
 * TMDB id settles look-alikes such as remakes), episodes by TMDB id or number within the series,
 * channels by guide id or name. Positions, dates and the order of favorites are kept.
 */
export class LibraryMigration {
  private movies: Map<string, Movie[]>;
  private series: Map<string, Series[]>;
  private liveByEpg = new Map<string, LiveChannel>();
  private liveByName = new Map<string, LiveChannel>();
  private tmdbOfMovie = new Map<string, Promise<string | undefined>>();
  private seriesDetail = new Map<string, Promise<SeriesDetail | null>>();

  constructor(private source: ContentSource, catalog: CatalogData) {
    // In any script, or every Korean or Cyrillic title would share one key, the empty one
    this.movies = group(catalog.movies, (m) => looseTitle(m.name, true));
    this.series = group(catalog.series, (s) => looseTitle(s.name, true));
    // From the end, so the first channel of a guide id or name is the one kept
    for (let i = catalog.live.length - 1; i >= 0; i--) {
      const c = catalog.live[i];
      if (c.epgId) {
        // A combined list's "1~101" is found by the "101" of a list on its own too (partEpgId)
        this.liveByEpg.set(c.epgId.toLowerCase().replace(/^\d+~/, ''), c);
        this.liveByEpg.set(c.epgId.toLowerCase(), c);
      }
      const name = looseChannel(c.name, true);
      if (name) this.liveByName.set(name, c);
    }
  }

  /** The same item in the new catalog, or null. */
  find(r: MediaRef): Promise<MediaRef | null> {
    switch (r.kind) {
      case 'movie':
        return this.movie(r);
      case 'series': {
        const s = this.findSeries(r.title, r.year)[0];
        return Promise.resolve(s ? seriesRef(s) : null);
      }
      case 'episode':
        return this.episode(r);
      default:
        return Promise.resolve(this.channel(r));
    }
  }

  private async movie(r: MediaRef): Promise<MediaRef | null> {
    const year = r.year !== undefined ? r.year : yearInTitle(r.title);
    const candidates = (this.movies.get(looseTitle(r.title, true)) || [])
      .filter((m) => sameYear(year, m.year !== undefined ? m.year : yearInTitle(m.name)))
      .slice(0, 4);
    if (!candidates.length) return null;
    const source = this.source;
    if (!r.tmdb || !source.movieDetail) return movieRef(candidates[0]);
    // Same title is not always the same film: where the provider knows the TMDB id, it decides
    let unknown: MediaRef | null = null;
    for (const m of candidates) {
      let lookup = this.tmdbOfMovie.get(m.id);
      if (!lookup) {
        lookup = source.movieDetail(m).then(
          (d) => d.tmdbId,
          () => undefined,
        );
        this.tmdbOfMovie.set(m.id, lookup);
      }
      const tmdb = await lookup;
      if (tmdb && String(tmdb) === String(r.tmdb)) return movieRef({ ...m, tmdbId: tmdb });
      if (!tmdb && !unknown) unknown = movieRef(m);
    }
    return unknown;
  }

  private findSeries(title: string, year?: number): Series[] {
    const y = year !== undefined ? year : yearInTitle(title);
    return (this.series.get(looseTitle(title, true)) || []).filter((s) => sameYear(y, s.year !== undefined ? s.year : yearInTitle(s.name)));
  }

  private async episode(r: MediaRef): Promise<MediaRef | null> {
    const series = this.findSeries(r.seriesTitle || '', r.year)[0];
    if (!series) return null;
    let lookup = this.seriesDetail.get(series.id);
    if (!lookup) {
      lookup = this.source.seriesDetail(series).then(
        (d): SeriesDetail | null => d,
        () => null,
      );
      this.seriesDetail.set(series.id, lookup);
    }
    const detail = await lookup;
    if (!detail) return null;
    const episodes = ([] as Episode[]).concat(...detail.seasons.map((s) => s.episodes));
    const episode =
      (r.tmdb ? episodes.filter((e) => !!e.tmdbId && String(e.tmdbId) === String(r.tmdb))[0] : undefined) ||
      episodes.filter((e) => e.season === r.season && e.number === r.number)[0];
    return episode ? episodeRef(detail.series, episode) : null;
  }

  private channel(r: MediaRef): MediaRef | null {
    const c = (r.epg ? this.liveByEpg.get(r.epg.toLowerCase()) : undefined) || this.liveByName.get(looseChannel(r.title));
    return c ? channelRef(c) : null;
  }

  /**
   * Finds everything in [from] (a library as Library.stored returns it) and adds what was found to
   * the library of [targetPlaylistId] and [profileId], live if it is the open one.
   */
  async run(from: Record<string, unknown>, targetPlaylistId: string, profileId: string): Promise<MigrationResult> {
    const favorites: MediaRef[] = [];
    const history: HistoryEntry[] = [];
    const missing: string[] = [];
    const list = (x: unknown) => (Array.isArray(x) ? (x as unknown[]) : []);
    for (const f of list(from.favorites)) {
      const ref = f as MediaRef;
      if (!ref || typeof ref !== 'object' || !ref.kind) continue;
      const found = await this.find(ref);
      if (found) favorites.push(found);
      else missing.push(ref.title);
    }
    for (const h of list(from.history)) {
      const entry = h as HistoryEntry;
      if (!entry || typeof entry !== 'object' || !entry.ref || !entry.ref.kind) continue;
      const found = await this.find(entry.ref);
      if (!found) {
        missing.push(entry.ref.seriesTitle || entry.ref.title);
        continue;
      }
      history.push({ ref: found, pos: entry.pos, dur: entry.dur, at: entry.at, dev: entry.dev });
    }
    // Favorites count as added now to this list, in the order they had
    const now = Date.now();
    const favAt: Record<string, number> = {};
    favorites.forEach((f, i) => {
      favAt[refKey(f)] = now - i;
    });
    mergeInto(targetPlaylistId, profileId, { favorites, favAt, history });
    const unique: string[] = [];
    for (const m of missing) if (unique.indexOf(m) < 0) unique.push(m);
    return { moved: favorites.length + history.length, missing: unique };
  }
}

/**
 * Every profile's favorites and history of the playlist [fromId], looked for in [catalog] (of
 * [source], the open playlist [toId]) and added there. The titles missing are counted once.
 */
export async function moveHistory(fromId: string, toId: string, source: ContentSource, catalog: CatalogData): Promise<{ moved: number; missing: number }> {
  const migration = new LibraryMigration(source, catalog);
  let moved = 0;
  const missing: string[] = [];
  for (const profile of profileStore.profiles) {
    const stored = Library.stored(fromId, profile.id);
    if (!stored) continue;
    const result = await migration.run(stored, toId, profile.id);
    moved += result.moved;
    for (const m of result.missing) if (missing.indexOf(m) < 0) missing.push(m);
  }
  return { moved, missing: missing.length };
}
