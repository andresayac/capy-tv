// Merging into a library that may be the one on screen (app/lib/data/library.dart, mergeInto): the
// open playlist's library is merged live, so the screens show what arrived and its next save (a
// progress tick, a favorite) keeps both instead of writing over it.
import { session } from '../session';
import { Library } from './library';

/** The library of [playlistId] and [profileId]: the open one if it is that one. */
export function openLibrary(playlistId: string, profileId: string): Library {
  let open: Library | null = null;
  try {
    open = session().library;
  } catch {
    // No playlist open
  }
  return open && open.playlistId === playlistId && open.profileId === profileId ? open : Library.load(playlistId, profileId);
}

/** Merges [data] (a library as Library.stored returns it) into that library, and saves it if anything changed. */
export function mergeInto(playlistId: string, profileId: string, data: Record<string, unknown>): void {
  openLibrary(playlistId, profileId).merge(data);
}
