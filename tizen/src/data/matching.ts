// How titles compare across names and providers (app/lib/data/matching.dart).
import { Library, MediaRef, refKey, refToMovie } from './library';
import { ContentSource } from './source';
// The pure title functions live in titles.ts, which the parsing worker can import
import { looseTitle, yearInTitle } from './titles';
export { bareTitle, fold, looseTitle, searchWords, versionKey, yearInTitle } from './titles';

/** A channel name as compared across providers: separators, quality and backup tags do not count. */
export function looseChannel(s: string, anyScript = false): string {
  return looseTitle(s, anyScript).replace(/\b(backup|alt|\d+fps)\b/g, ' ').replace(/\s+/g, ' ').trim();
}

/** What identifies an item whatever the provider (provider ids differ from one to the next). */
export function universalKey(r: MediaRef): string {
  switch (r.kind) {
    case 'movie':
    case 'series':
      if (r.tmdb) return `${r.kind}/tmdb/${r.tmdb}`;
      return `${r.kind}/${looseTitle(r.title)}/${r.year !== undefined ? r.year : yearInTitle(r.title) || ''}`;
    case 'episode':
      if (r.tmdb) return `episode/tmdb/${r.tmdb}`;
      return `episode/${looseTitle(r.seriesTitle || '')}/${r.season}x${r.number}`;
    default:
      if (r.epg) return `live/epg/${r.epg.toLowerCase()}`;
      return `live/${looseChannel(r.title)}`;
  }
}

/**
 * Fills in the TMDB id of the movies a library refers to: listings rarely carry it, the full
 * record does, and it is what finds them again with another provider. At most [max] lookups, one
 * at a time, each title once. It stops as soon as [open] says the library was put away, so a copy
 * left behind never saves over the one in use.
 */
export async function addTmdbIds(library: Library, source: ContentSource, max = 30, open: () => boolean = () => true): Promise<number> {
  if (!source.movieDetail) return 0; // M3U has no full record
  // The movies the provider answered for without an id, and when: left alone a month, so the turn
  // reaches those after them (always the same first 30 otherwise)
  const key = `tmdbMisses.${library.playlistId}`;
  let misses: Record<string, number> = {};
  try {
    misses = JSON.parse(localStorage.getItem(key) || '{}') || {};
  } catch {
    // Unreadable: asked again, that is all
  }
  const now = Date.now();
  for (const id of Object.keys(misses)) if (now - misses[id] > 30 * 24 * 3600 * 1000) delete misses[id];
  let done = 0;
  let missed = false;
  const seen: Record<string, true> = {};
  for (const r of library.refs) {
    if (r.kind !== 'movie' || r.tmdb || seen[refKey(r)] || misses[r.id]) continue;
    seen[refKey(r)] = true;
    if (done >= max || !open()) break;
    done++;
    try {
      const tmdb = (await source.movieDetail(refToMovie(r))).tmdbId;
      if (!open()) continue;
      if (tmdb) library.updateRef({ ...r, tmdb });
      else {
        misses[r.id] = now;
        missed = true;
      }
    } catch {
      // Unreachable or gone: maybe next time
    }
  }
  if (missed) {
    try {
      localStorage.setItem(key, JSON.stringify(misses));
    } catch {
      // Full: asked again next time
    }
  }
  return done;
}
