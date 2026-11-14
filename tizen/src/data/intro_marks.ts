// Where a series' opening titles start and end, as marked once on one of its episodes: its other
// episodes then offer to skip them (app/lib/data/intro_marks.dart). Kept on this TV under the same
// keys, by the series' title, so another provider's copy of the series has them too.
import { looseTitle } from './titles';

export interface Intro {
  start: number | null; // ms
  end: number | null;
}

const key = (seriesTitle: string) => `intro/${looseTitle(seriesTitle)}`;

export const introMarks = {
  of(seriesTitle: string): Intro | null {
    try {
      const raw = localStorage.getItem(key(seriesTitle));
      if (!raw) return null;
      const j = JSON.parse(raw);
      const at = (v: unknown) => (typeof v === 'number' ? v : null);
      return { start: at(j.start), end: at(j.end) };
    } catch {
      return null;
    }
  },

  save(seriesTitle: string, intro: Intro): void {
    try {
      if (intro.start === null && intro.end === null) return localStorage.removeItem(key(seriesTitle));
      const j: Record<string, number> = {};
      if (intro.start !== null) j.start = intro.start;
      if (intro.end !== null) j.end = intro.end;
      localStorage.setItem(key(seriesTitle), JSON.stringify(j));
    } catch {
      // No storage: it is not kept
    }
  },

  /** Whether [intro] is marked whole: a start, and an end after it. */
  complete(intro: Intro | null): boolean {
    return !!intro && intro.start !== null && intro.end !== null && intro.end > intro.start;
  },
};
