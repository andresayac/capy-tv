// The series a profile has been watching whose provider added episodes since
// (app/lib/data/new_episodes.dart): those the listing says changed after the profile's last
// episode, then their episodes after that one. Each series is asked about once a session.
import { CatalogData } from './catalog';
import { HistoryEntry, Library, progressOf, resumable } from './library';
import { Episode, Series, SeriesDetail } from './models';
import { ContentSource } from './source';
import { versionKey } from './titles';

export interface NewEpisodes {
  series: Series;
  next: Episode;
  count: number;
}

export class NewEpisodeFinder {
  private details: Record<string, Promise<SeriesDetail | null>> = {};

  constructor(readonly source: ContentSource) {}

  /**
   * With [upNext], instead: the series whose last episode watched was seen to the end, whatever the
   * provider changed, for the next one waiting ("Up next").
   */
  async find(library: Library, data: CatalogData, max = 8, upNext = false): Promise<NewEpisodes[]> {
    const series: Record<string, Series> = {};
    for (const s of data.series) series[s.id] = s;
    // The latest episode watched of each series, newest first
    const last: Record<string, HistoryEntry> = {};
    const order: string[] = [];
    // By title: two copies of a series (4K, another provider) are one, at the latest episode in either
    for (const h of library.history) {
      const key = versionKey(h.ref.seriesTitle || '', h.ref.year);
      // For what comes next, one only opened (the next episode starting by itself, left within
      // seconds) is passed over: the one seen to the end before it still says what is next
      if (upNext && !resumable(h) && progressOf(h) < 0.95) continue;
      if (h.ref.kind === 'episode' && h.ref.seriesId && !last[key]) {
        last[key] = h;
        order.push(key);
      }
    }
    const changed = order
      .map((key) => ({ s: series[last[key].ref.seriesId || ''], h: last[key] }))
      // Still in the middle of the last one: that is "Continue watching", not news
      .filter(({ s, h }) => {
        if (!s || resumable(h)) return false;
        const changed = !!s.updated && s.updated.getTime() > h.at;
        return upNext ? progressOf(h) >= 0.95 && !changed : changed;
      })
      .slice(0, max);
    const found: NewEpisodes[] = [];
    for (const { s, h } of changed) {
      const d = await (this.details[s.id] || (this.details[s.id] = this.source.seriesDetail(s).catch(() => null)));
      if (!d) continue;
      const season = h.ref.season || 0;
      const number = h.ref.number || 0;
      const after = ([] as Episode[])
        .concat(...d.seasons.map((x) => x.episodes))
        .filter((e) => e.season > season || (e.season === season && e.number > number));
      if (after.length) found.push({ series: s, next: after[0], count: after.length });
    }
    return found;
  }
}
