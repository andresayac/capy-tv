// Search over a playlist's whole catalog (app/lib/data/search.dart), forgiving the way people
// type: words in any order, without accents or punctuation, a word cut short counts ("bre bad"),
// and a slip of one letter in a word of five letters or more.
import { CatalogData } from './catalog';
import { EpgGuide, isNow } from './epg';
import { looseTitle, searchWords, versionKey, yearInTitle } from './matching';
import { Movie, Series } from './models';
import { EpgEntry, LiveChannel } from './source';

export class SearchQuery {
  readonly words: string[];
  readonly phrase: string;

  constructor(text: string) {
    this.words = searchWords(text);
    this.phrase = this.words.join(' ');
  }

  /** Too short to look for: fewer than two letters in all. */
  get isEmpty(): boolean {
    return this.phrase.replace(/ /g, '').length < 2;
  }

  /**
   * Whether every word searched is a word of [title] or its start ("ana" is not in "mañana"): the
   * guide's programme names are short and many, and a match inside a word would bring half of them.
   */
  wholeWords(title: string[]): boolean {
    return this.words.every((q) => OPTIONAL.indexOf(q) >= 0 || title.some((t) => t.indexOf(q) === 0));
  }

  /**
   * How well a title with these words matches: null when it does not, higher when it matches
   * better. The whole title, then its start, then every word whole, then the rest.
   */
  score(title: string[]): number | null {
    if (!this.words.length) return null;
    let total = 0;
    let matched = 0;
    for (const q of this.words) {
      let best = 0;
      for (const w of title) {
        const s =
          w === q ? 30 : w.indexOf(q) === 0 ? 20 : q.length >= 3 && w.indexOf(q) >= 0 ? 8 : q.length >= 5 && w.length >= 4 && nearly(q, w) ? 6 : 0;
        if (s > best) best = s;
      }
      // Written as one word what the title splits: "spiderman" for "Spider-Man", "xmen"
      if (!best && q.length >= 4) {
        for (let i = 0; i < title.length - 1 && !best; i++) if (title.slice(i).join('').indexOf(q) === 0) best = 20;
      }
      // A number written the other way: "rocky 2" for "Rocky II"
      if (!best && SAME_NUMBER[q] && title.indexOf(SAME_NUMBER[q]) >= 0) best = 30;
      if (!best) {
        if (OPTIONAL.indexOf(q) >= 0) continue; // an article the title does not carry: "the matrix"
        return null; // every other word must be there
      }
      matched++;
      total += best;
    }
    if (!matched) return null;
    const joined = title.join(' ');
    if (joined === this.phrase) total += 200;
    else if (joined.indexOf(this.phrase) === 0) total += 80;
    else if (joined.indexOf(this.phrase) >= 0) total += 30;
    return total - Math.min(20, Math.max(0, title.length - this.words.length)); // fewer other words, closer
  }
}

/** Articles a search may carry and a title may not. */
const OPTIONAL = ['the', 'a', 'an', 'el', 'la', 'los', 'las', 'un', 'una', 'le', 'les', 'der', 'die', 'das', 'il'];

/** Numbers 2 to 10 in Roman numerals and digits, each to the other. */
const SAME_NUMBER: Record<string, string> = {};
['ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x'].forEach((r, i) => {
  SAME_NUMBER[r] = String(i + 2);
  SAME_NUMBER[String(i + 2)] = r;
});

/** One letter changed, added or missing; or [q] so typed at the start of a longer [t]. */
function nearly(q: string, t: string): boolean {
  const oneEdit = (a: string, b: string) => {
    if (Math.abs(a.length - b.length) > 1) return false;
    let i = 0;
    let j = 0;
    let edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] === b[j]) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return false;
      if (a.length > b.length) i++;
      else if (b.length > a.length) j++;
      else {
        i++;
        j++;
      }
    }
    return edits + (a.length - i) + (b.length - j) <= 1;
  };
  if (oneEdit(q, t)) return true;
  // A word cut short with a slip in it: "spidr" for "spiderman"
  return q.length >= 5 && t.length > q.length && oneEdit(q, t.slice(0, q.length));
}

export interface SearchResults {
  movies: Movie[][]; // each title with its versions, the best match first
  series: Series[][];
  channels: LiveChannel[];
}

/** A catalog made searchable: every title's words, worked out once without holding the remote up. */
export class SearchIndex {
  private static built = new WeakMap<CatalogData, Promise<SearchIndex>>();

  private constructor(
    readonly data: CatalogData,
    private movies: string[][],
    private series: string[][],
    private live: string[][],
  ) {}

  /**
   * The index of [data], built the first time it is asked for. Flutter builds it in an isolate;
   * here it goes a slice at a time, so keys and the TV's keyboard keep answering meanwhile.
   */
  static of(data: CatalogData): Promise<SearchIndex> {
    let index = SearchIndex.built.get(data);
    if (!index) {
      index = (async () => {
        const movies = await inSlices(data.movies, (m) => searchWords(m.name));
        const series = await inSlices(data.series, (s) => searchWords(s.name));
        const live = await inSlices(data.live, (c) => searchWords(c.name));
        return new SearchIndex(data, movies, series, live);
      })();
      SearchIndex.built.set(data, index);
      // A build that failed is not kept, so Retry builds it again
      index.catch(() => SearchIndex.built.delete(data));
    }
    return index;
  }

  /**
   * What matches [q], best first; at equal match, the most recent and best rated. Movies and series
   * listed once per language or quality come as one.
   */
  /** The channels that match [q], best first; at equal match by their number ("ESPN 1" before "ESPN 29"), and those with none by name. */
  private channels(q: SearchQuery): LiveChannel[] {
    const hits: { c: LiveChannel; s: number }[] = [];
    for (let i = 0; i < this.data.live.length; i++) {
      const s = q.score(this.live[i]);
      if (s !== null) hits.push({ c: this.data.live[i], s });
    }
    hits.sort((a, b) => {
      if (a.s !== b.s) return b.s - a.s;
      const an = a.c.number;
      const bn = b.c.number;
      if (an !== undefined && bn !== undefined && an !== bn) return an - bn;
      if ((an === undefined) !== (bn === undefined)) return an === undefined ? 1 : -1;
      return a.c.name < b.c.name ? -1 : a.c.name > b.c.name ? 1 : 0;
    });
    return hits.map((h) => h.c);
  }

  search(q: SearchQuery): SearchResults {
    const ranked = <T,>(items: T[], words: string[][], key: (x: T) => string, year: (x: T) => number | undefined, rating: (x: T) => number | undefined) => {
      const hits: { x: T; s: number }[] = [];
      for (let i = 0; i < items.length; i++) {
        const s = q.score(words[i]);
        if (s !== null) hits.push({ x: items[i], s });
      }
      const tie = (x: T) => (year(x) || 0) * 10 + (rating(x) || 0);
      hits.sort((a, b) => (a.s !== b.s ? b.s - a.s : tie(b.x) - tie(a.x)));
      const groups: Record<string, T[]> = {};
      const order: string[] = []; // in the order of their best version
      for (const { x } of hits) {
        const k = key(x);
        if (!groups[k]) {
          groups[k] = [];
          order.push(k);
        }
        groups[k].push(x);
      }
      return order.map((k) => groups[k]);
    };
    return {
      movies: ranked(this.data.movies, this.movies, (m) => versionKey(m.name, m.year), (m) => m.year || yearInTitle(m.name), (m) => m.rating),
      series: ranked(this.data.series, this.series, (s) => versionKey(s.name, s.year), (s) => s.year || yearInTitle(s.name), (s) => s.rating),
      channels: this.channels(q),
    };
  }
}

/** How long each slice may run: what is left of a frame stays for keys and drawing. */
const SLICE_MS = 8;

/** [f] of every item, a few milliseconds at a time with the UI let through in between. */
async function inSlices<T, R>(items: T[], f: (x: T) => R): Promise<R[]> {
  const out: R[] = [];
  let i = 0;
  while (i < items.length) {
    const until = Date.now() + SLICE_MS;
    do {
      for (const end = Math.min(items.length, i + 100); i < end; i++) out.push(f(items[i]));
    } while (i < items.length && Date.now() < until);
    if (i < items.length) await new Promise((resolve) => setTimeout(resolve, 0));
  }
  return out;
}

/** A programme of the guide that matches a search, with the channel that shows it. */
export interface OnAir {
  channel: LiveChannel;
  programme: EpgEntry;
}

/**
 * Programmes on [channels] whose title matches [q], on now or starting within 12 hours: what is on
 * now first, then by start. One per channel, the soonest.
 */
export function searchGuide(guide: EpgGuide, channels: LiveChannel[], q: SearchQuery, now = Date.now()): OnAir[] {
  const found: OnAir[] = [];
  const hits: Record<string, boolean> = {}; // the same programme name comes up on many channels
  for (const c of channels) {
    if (!guide.has(c.epgId)) continue;
    for (const e of guide.between(c.epgId, now, now + 12 * 60 * 60 * 1000)) {
      if (!(e.title in hits)) {
        const w = searchWords(e.title);
        hits[e.title] = q.score(w) !== null && q.wholeWords(w);
      }
      if (!hits[e.title]) continue;
      found.push({ channel: c, programme: e });
      break;
    }
  }
  return found.sort((a, b) => {
    const an = isNow(a.programme, now);
    const bn = isNow(b.programme, now);
    if (an !== bn) return an ? -1 : 1;
    return a.programme.start.getTime() - b.programme.start.getTime();
  });
}

/** The last searches of a profile, newest first, kept on the TV. */
export const recentSearches = {
  MAX: 8,
  key: (profileId: string) => `search.recent.${profileId}`,
  of(profileId: string): string[] {
    try {
      return JSON.parse(localStorage.getItem(this.key(profileId)) || '[]');
    } catch {
      return [];
    }
  },
  /** Notes [text] as searched, on top; the same search typed differently counts once. */
  add(profileId: string, text: string): void {
    const t = text.trim();
    if (new SearchQuery(t).isEmpty) return;
    const list = [t].concat(this.of(profileId).filter((s) => looseTitle(s, true) !== looseTitle(t, true))).slice(0, this.MAX);
    try {
      localStorage.setItem(this.key(profileId), JSON.stringify(list));
    } catch {
      // Storage full: not remembered, and the result it came with still opens
    }
  },
  clear(profileId: string): void {
    localStorage.removeItem(this.key(profileId));
  },
};
