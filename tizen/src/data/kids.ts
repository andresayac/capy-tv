// What a kids profile is offered (app/lib/data/kids.dart): a list of what may be seen, not of what
// may not, as most panels send no genre nor age in their lists and what nobody vouches for stays out.
import type { CatalogData } from './catalog';
import type { MediaRef } from './library';
import { splitGenres } from './models';
import type { ContentSource } from './source';
import { looseTitle } from './titles';

// Not animation nor a studio: real panels file adult cartoons and superheroes under those
const CATEGORY_WORDS = [
  'infantil', 'infantiles', 'kid', 'kids', 'nino', 'ninos', 'nina', 'ninas', 'children', 'familia', 'familiar',
  'family', 'dibujos', 'cartoon', 'cartoons', 'nickelodeon',
];
const NEVER_CATEGORY_WORDS = ['anime', 'animes'];
const OLDER_AGE = /\+\s?(1[3-9]|[2-9]\d)/; // "Animadas +16"
// Not animation: series for adults have it too
const GENRES = ['familia', 'family', 'infantil', 'kids', 'ninos', 'children'];
const NEVER_GENRES = ['terror', 'horror', 'erot', 'thriller', 'crimen', 'crime', 'belic', 'gore', 'slasher'];

/** Whether a category's name says it is for children ("Infantiles", "Kids", "Dibujos animados"...). */
export function isKidsCategory(name: string): boolean {
  const words = looseTitle(name).split(' ');
  return !OLDER_AGE.test(name) && words.some((w) => CATEGORY_WORDS.indexOf(w) >= 0) && !words.some((w) => NEVER_CATEGORY_WORDS.indexOf(w) >= 0);
}

function anyOf(genres: string[], words: string[]): boolean {
  return genres.some((g) => {
    const f = looseTitle(g);
    return words.some((w) => f.indexOf(w) >= 0);
  });
}

/** Whether an age rating, where a provider gives one, is for adults. */
export function isAdultRating(rating?: string): boolean {
  const r = (rating || '').trim().toUpperCase();
  return r === 'R' || r === 'NC-17' || r === 'TV-MA' || r.indexOf('18') >= 0;
}

const listed = new WeakMap<CatalogData, Record<string, Set<string>>>();

/**
 * Whether [source]'s profile may still see [r] of its library, which remembers what it saw when it
 * was allowed more: only what its lists have now. [data] is those lists, unset until they are in
 * or when they failed: a kids profile waits, anyone else keeps their rows.
 */
export function libraryShows(r: MediaRef, data: CatalogData | undefined, source: ContentSource): boolean {
  if (!source.hideAdult) return true;
  if (!data) return !source.kidsOnly;
  let ids = listed.get(data);
  if (!ids) {
    ids = { live: new Set(data.live.map((x) => x.id)), movie: new Set(data.movies.map((x) => x.id)), series: new Set(data.series.map((x) => x.id)) };
    listed.set(data, ids);
  }
  const known = ids[r.kind === 'episode' ? 'series' : r.kind];
  // An empty list may be one that failed; to a kids profile it can as well be all it may see
  return known.has(r.kind === 'episode' ? r.seriesId || '' : r.id) || (known.size === 0 && !source.kidsOnly);
}

/**
 * Whether a kids profile may see [item], a channel, movie or series: from a category for children
 * or of a genre for them, and in neither case of a genre or age rating that rules it out.
 */
export function kidsMaySee(item: unknown, inKidsCategory: boolean): boolean {
  const { genre, ageRating } = item as { genre?: string; ageRating?: string };
  const genres = splitGenres(genre);
  if (anyOf(genres, NEVER_GENRES) || isAdultRating(ageRating)) return false;
  return inKidsCategory || anyOf(genres, GENRES);
}
