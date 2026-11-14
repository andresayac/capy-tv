// An Xtream list as it is kept (app/lib/data/xtream.dart _Listing): every channel, movie or series,
// or a kind's categories, indexed by category, with what the panel marks as adult. Built where it
// is parsed, which for big lists is the parsing worker (src/workers/catalog.ts): nothing here
// reaches beyond the models.
import { isAdultTitle, movieFromJson, seriesFromJson, untitled, untitledName } from './models';
import type { Category, LiveChannel } from './source';
import { asInt, asStr } from './values';

export function liveFromJson(j: Record<string, unknown>): LiveChannel {
  return {
    id: asStr(j.stream_id) || '',
    name: asStr(j.name) || untitledName,
    number: asInt(j.num),
    icon: asStr(j.stream_icon),
    // With none, its name: the guide's own names for its channels are matched by it (see EpgGuide.matched)
    epgId: asStr(j.epg_channel_id) || asStr(j.name),
    categoryId: asStr(j.category_id),
    archiveDays: asInt(j.tv_archive) === 1 ? asInt(j.tv_archive_duration) || 0 : 0,
  };
}

export function categoryFromJson(j: Record<string, unknown>): Category {
  return { id: asStr(j.category_id) || '', name: asStr(j.category_name) || untitled };
}

/** What each list holds, by the name the worker is told. */
export const FROM_JSON = {
  live: liveFromJson,
  movie: movieFromJson,
  series: seriesFromJson,
  category: categoryFromJson,
};

export type ListKind = keyof typeof FROM_JSON;

/** A list's items and indexes as plain data, which crosses to the page from the worker as it is. */
export interface ListingData<T> {
  items: T[];
  byCategory: Record<string, number[]>;
  categoriesOf: string[][];
  adult: Record<number, true>;
  /** Categories where most items are marked as adult. */
  adultCategories: Record<string, true>;
}

/**
 * A list's items as they are read (see jsonItems), each made into a model at once and indexed.
 * [each] hears how many there are every so many of them.
 */
export function buildListing<T>(raw: Iterable<Record<string, unknown>>, fromJson: (j: Record<string, unknown>) => T, each?: (items: number) => void): ListingData<T> {
  const out: ListingData<T> = { items: [], byCategory: {}, categoriesOf: [], adult: {}, adultCategories: {} };
  const adultIn: Record<string, number> = {};
  let i = -1;
  for (const j of raw) {
    i++;
    const cats: string[] = [];
    const first = asStr(j.category_id);
    if (first) cats.push(first);
    if (Array.isArray(j.category_ids)) {
      for (const x of j.category_ids) {
        const c = asStr(x);
        if (c && cats.indexOf(c) < 0) cats.push(c);
      }
    }
    out.categoriesOf.push(cats);
    const marked = asInt(j.is_adult) === 1 || isAdultTitle(asStr(j.title) || asStr(j.name) || '');
    if (marked) out.adult[i] = true;
    for (const c of cats) {
      (out.byCategory[c] || (out.byCategory[c] = [])).push(i);
      if (marked) adultIn[c] = (adultIn[c] || 0) + 1;
    }
    out.items.push(fromJson(j));
    if (each && i % 1024 === 1023) each(i + 1);
  }
  for (const c of Object.keys(adultIn)) if (adultIn[c] * 2 > out.byCategory[c].length) out.adultCategories[c] = true;
  return out;
}

export class Listing<T> {
  constructor(private readonly d: ListingData<T>) {}

  get items(): T[] {
    return this.d.items;
  }

  get adultCategories(): Record<string, true> {
    return this.d.adultCategories;
  }

  /** The items of [category] (all without one). With [hiding], neither adult items nor those in it. */
  only(category?: string, hiding?: Record<string, true>): T[] {
    const indices = category === undefined ? this.d.items.map((_, i) => i) : this.d.byCategory[category] || [];
    const out: T[] = [];
    for (const i of indices) {
      if (hiding && (this.d.adult[i] || this.d.categoriesOf[i].some((c) => hiding[c]))) continue;
      out.push(this.d.items[i]);
    }
    return out;
  }
}
