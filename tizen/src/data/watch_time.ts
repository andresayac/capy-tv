// A kids profile's time per day (app/lib/data/watch_time.dart), counted on this TV under the same
// keys: what was watched today, and what a grown-up added with the PIN. The day never goes back,
// so moving the TV's date back and forth gives no time back.
import { Profile } from './profiles';

const day = (d: Date) => `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
const usedKey = (profile: string, d: Date) => `watch.${profile}.${day(d)}`;
const addedKey = (profile: string, d: Date) => `watch.more.${profile}.${day(d)}`;
const seenKey = (profile: string) => `watch.seen.${profile}`;

function num(key: string): number {
  try {
    return Number(localStorage.getItem(key)) || 0;
  } catch {
    return 0;
  }
}

function today(profile: string): Date {
  const now = Date.now();
  const seen = num(seenKey(profile));
  return new Date(seen > now ? seen : now);
}

/** The minutes a day [p] may watch, set on a phone or computer; undefined for no limit. */
export function dailyMinutes(p: Profile): number | undefined {
  const m = p.extra && p.extra.minutes;
  return typeof m === 'number' && m > 0 ? m : undefined;
}

export const watchTime = {
  /** Seconds [p] may still watch today; undefined when it has no limit. */
  left(p: Profile): number | undefined {
    const minutes = dailyMinutes(p);
    if (minutes === undefined) return undefined;
    const d = today(p.id);
    return (minutes + num(addedKey(p.id, d))) * 60 - num(usedKey(p.id, d));
  },

  /** Notes that [profile] watched [seconds] more today; other days' counts go. */
  add(profile: string, seconds: number): void {
    const d = today(profile);
    const key = usedKey(profile, d);
    try {
      localStorage.setItem(key, String(num(key) + seconds));
      localStorage.setItem(seenKey(profile), String(d.getTime()));
      const keep = [key, addedKey(profile, d), seenKey(profile)];
      for (const k of Object.keys(localStorage)) {
        if (k.indexOf('watch.') === 0 && k.indexOf(`.${profile}.`) > 0 && keep.indexOf(k) < 0) localStorage.removeItem(k);
      }
    } catch {
      // Storage full: counted in memory no more, but the limit is not lifted either
    }
  },

  /** [minutes] more for [profile] today, given with the PIN. */
  addTime(profile: string, minutes: number): void {
    const key = addedKey(profile, today(profile));
    try {
      localStorage.setItem(key, String(num(key) + minutes));
    } catch {
      // Then no more time: better than the limit gone
    }
  },
};
