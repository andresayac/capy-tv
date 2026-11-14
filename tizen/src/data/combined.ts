// Several providers as one (app/lib/data/combined.dart). Ids carry the provider: "1~2045" is
// item 2045 of the second one, as in the Flutter app, so synced history matches. Categories are
// named after their provider ("Provider A · Movies 4K"); a provider that cannot be reached leaves
// the others working.
import { EpgGuide, partEpgId } from './epg';
import { displayCategoryName } from './names';
import { Episode, Movie, Series, SeriesDetail } from './models';
import { Category, ContentSource, EpgEntry, LiveChannel, SourceException } from './source';

export interface CombinedPart {
  name: string;
  source: ContentSource;
}

const SEP = '~';

export class CombinedSource implements ContentSource {
  /** The providers there are. */
  readonly parts: CombinedPart[];

  /** Those that did not open, by name ("Update list" says so). */
  failed: string[] = [];

  /**
   * [slots]: its providers in the places the playlist has them, null where one is missing (deleted,
   * or it did not open). The others keep their places, so the ids saved in favorites and history
   * (and synced) still point where they did, and not at another provider's.
   */
  constructor(readonly slots: (CombinedPart | null)[]) {
    this.parts = slots.filter((p): p is CombinedPart => !!p);
  }

  get hideAdult(): boolean {
    return this.parts[0].source.hideAdult;
  }

  set hideAdult(v: boolean) {
    for (const p of this.parts) p.source.hideAdult = v;
  }

  get kidsOnly(): boolean {
    return this.parts[0].source.kidsOnly;
  }

  set kidsOnly(v: boolean) {
    for (const p of this.parts) p.source.kidsOnly = v;
  }

  static wrap(part: number, id: string): string {
    return `${part}${SEP}${id}`;
  }

  private wrapOrNot(part: number, id?: string): string | undefined {
    return id === undefined ? undefined : CombinedSource.wrap(part, id);
  }

  /** The provider an id is from, and the id there. */
  private unwrap(id: string): [ContentSource, string, number] {
    const i = id.indexOf(SEP);
    const part = i < 0 ? NaN : parseInt(id.slice(0, i), 10);
    const p = isNaN(part) ? null : this.slots[part];
    if (!p) throw new SourceException('notFound');
    return [p.source, id.slice(i + 1), part];
  }

  private raw(id?: string): string | undefined {
    return id === undefined ? undefined : this.unwrap(id)[1];
  }

  /** [ask] of every provider, in their order; one that fails is left out, unless all do. */
  private async all<T>(ask: (part: number, s: ContentSource) => Promise<T[]>): Promise<T[]> {
    let error: unknown = null;
    const lists = await Promise.all(
      this.slots.map((p, i) =>
        !p
          ? ([] as T[])
          : ask(i, p.source).catch((e) => {
              if (error === null) error = e;
              return [] as T[];
            }),
      ),
    );
    if (error !== null && lists.every((l) => !l.length)) throw error;
    return ([] as T[]).concat(...lists);
  }

  private named(part: number, cats: Category[]): Category[] {
    return cats.map((c) => ({
      id: CombinedSource.wrap(part, c.id),
      name: this.slots.length > 1 ? `${(this.slots[part] as CombinedPart).name} · ${displayCategoryName(c.name)}` : c.name,
    }));
  }

  /** A category's items, from its provider; or every provider's. */
  private async list<T extends { id: string; categoryId?: string }>(
    categoryId: string | undefined,
    ask: (s: ContentSource, category?: string) => Promise<T[]>,
  ): Promise<T[]> {
    const rewrap = (i: number, x: T): T => ({ ...x, id: CombinedSource.wrap(i, x.id), categoryId: this.wrapOrNot(i, x.categoryId) });
    if (categoryId === undefined) return this.all(async (i, s) => (await ask(s)).map((x) => rewrap(i, x)));
    const i = parseInt(categoryId.split(SEP)[0], 10);
    const p = isNaN(i) ? null : this.slots[i];
    if (!p) return [];
    return (await ask(p.source, this.raw(categoryId))).map((x) => rewrap(i, x));
  }

  liveCategories(): Promise<Category[]> {
    return this.all(async (i, s) => this.named(i, await s.liveCategories()));
  }

  movieCategories(): Promise<Category[]> {
    return this.all(async (i, s) => this.named(i, await s.movieCategories()));
  }

  seriesCategories(): Promise<Category[]> {
    return this.all(async (i, s) => this.named(i, await s.seriesCategories()));
  }

  async liveChannels(categoryId?: string): Promise<LiveChannel[]> {
    const live = await this.list(categoryId, (s, c) => s.liveChannels(c));
    // Each provider's own guide ids apart (partEpgId): the part is the first piece of the id
    return live.map((c) => ({ ...c, epgId: partEpgId(parseInt(c.id.split(SEP)[0], 10), c.epgId) }));
  }

  movies(categoryId?: string): Promise<Movie[]> {
    return this.list(categoryId, (s, c) => s.movies(c));
  }

  series(categoryId?: string): Promise<Series[]> {
    return this.list(categoryId, (s, c) => s.series(c));
  }

  async seriesDetail(s: Series): Promise<SeriesDetail> {
    const [source, raw, part] = this.unwrap(s.id);
    const d = await source.seriesDetail({ ...s, id: raw, categoryId: this.raw(s.categoryId) });
    return {
      series: { ...d.series, id: s.id, categoryId: s.categoryId },
      seasons: d.seasons.map((season) => ({
        number: season.number,
        episodes: season.episodes.map((e) => ({ ...e, id: CombinedSource.wrap(part, e.id) })),
      })),
      seasonInfo: d.seasonInfo,
    };
  }

  async movieDetail(m: Movie): Promise<Movie> {
    const [source, raw] = this.unwrap(m.id);
    if (!source.movieDetail) return m;
    const d = await source.movieDetail({ ...m, id: raw, categoryId: this.raw(m.categoryId) });
    return { ...d, id: m.id, categoryId: m.categoryId };
  }

  shortEpg(c: LiveChannel, limit?: number): Promise<EpgEntry[]> {
    const [source, raw] = this.unwrap(c.id);
    return source.shortEpg({ ...c, id: raw, categoryId: this.raw(c.categoryId) }, limit);
  }

  /** Every provider's guide as one; where two describe the same channel, the first one's. */
  async guide(stop?: AbortSignal): Promise<EpgGuide> {
    const guides: Promise<EpgGuide>[] = [];
    this.slots.forEach((p, i) => {
      if (p) guides.push(p.source.guide(stop).then((g) => (g === EpgGuide.failed ? g : g.numbersOf(i)), () => EpgGuide.failed));
    });
    return EpgGuide.merge(await Promise.all(guides));
  }

  close(): void {
    for (const p of this.parts) if (p.source.close) p.source.close();
  }

  catchupUrl(c: LiveChannel, start: Date, minutes: number): string | null {
    const [source, raw] = this.unwrap(c.id);
    return source.catchupUrl({ ...c, id: raw, categoryId: this.raw(c.categoryId) }, start, minutes);
  }

  liveUrl(c: LiveChannel): string {
    const [source, raw] = this.unwrap(c.id);
    return source.liveUrl({ ...c, id: raw, categoryId: this.raw(c.categoryId) });
  }

  movieUrl(m: Movie): string {
    const [source, raw] = this.unwrap(m.id);
    return source.movieUrl({ ...m, id: raw, categoryId: this.raw(m.categoryId) });
  }

  episodeUrl(e: Episode): string {
    const [source, raw] = this.unwrap(e.id);
    return source.episodeUrl({ ...e, id: raw });
  }

  /** Stream URLs are the providers' own: whichever knows [url] says. */
  userAgentFor(url: string): string | undefined {
    for (const p of this.parts) {
      const ua = p.source.userAgentFor(url);
      if (ua) return ua;
    }
    return undefined;
  }
}
