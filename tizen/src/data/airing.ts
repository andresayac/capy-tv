// What is on now on a live channel, for the screens that say it: the full guide's programme, or,
// when the guide has none for the channel at this time, what the provider says when asked about that
// channel alone (Xtream's short guide), as the Flutter app's Airing (app/lib/data/airing.dart).
//
// Why: providers leave out of their full guide (XMLTV) channels their short guide does have, and
// while a full guide fails the app keeps the last good copy, which runs out. Asked one channel at a
// time and only for those on screen: PARALLEL at a time, the latest shown first, each answer kept
// until its programme ends (half an hour when there is none, ten minutes when asking failed). Never
// for a channel with no guide id: the provider has nothing for those either.
//
// Only types are imported besides the Notifier, so scripts/airing-test.mjs checks it alone in Node.
import { Notifier } from '../ui/notifier';
import type { EpgGuide } from './epg';
import type { EpgEntry, LiveChannel } from './source';

export const PARALLEL = 3;
const WAITING = 48; // channels scrolled past are dropped, the oldest first
const NOTHING_FOR = 30 * 60 * 1000;
const FAILED_FOR = 10 * 60 * 1000;
const REMEMBERED = 1000;

type Guide = Pick<EpgGuide, 'nowOn' | 'upcoming'>;

const isOn = (e: EpgEntry, t: number) => e.start.getTime() <= t && t < e.end.getTime();

export class Airing extends Notifier {
  private known = new Map<string, { entries: EpgEntry[]; until: number }>();
  private queue: LiveChannel[] = [];
  private asking = new Set<string>();
  private running = 0;
  private tell: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly ask: (c: LiveChannel) => Promise<EpgEntry[]>,
    private readonly clock: () => number = Date.now,
  ) {
    super();
  }

  /** What is on now on [c]: the guide's, else the provider's once known. Listeners hear when an answer comes. */
  nowOn(c: LiveChannel | undefined, guide: Guide | undefined): EpgEntry | undefined {
    if (!c) return undefined;
    const t = this.clock();
    return (guide && guide.nowOn(c.epgId, t)) || this.fromProvider(c, t).filter((e) => isOn(e, t))[0];
  }

  /** What is on now and what comes next on [c], [count] at most: the guide's when it has the one on now, else the provider's. */
  upcoming(c: LiveChannel | undefined, guide: Guide | undefined, count = 2): EpgEntry[] {
    if (!c) return [];
    const t = this.clock();
    if (guide && guide.nowOn(c.epgId, t)) return guide.upcoming(c.epgId, count, t);
    return this.fromProvider(c, t)
      .filter((e) => e.end.getTime() > t)
      .slice(0, count);
  }

  private fromProvider(c: LiveChannel, t: number): EpgEntry[] {
    if (!c.epgId) return [];
    const known = this.known.get(c.id);
    if (!known || known.until <= t) this.want(c);
    return known ? known.entries : [];
  }

  private want(c: LiveChannel): void {
    if (this.asking.has(c.id)) return;
    this.queue = this.queue.filter((q) => q.id !== c.id);
    this.queue.push(c);
    if (this.queue.length > WAITING) this.queue.shift();
    this.next();
  }

  private next(): void {
    while (this.running < PARALLEL && this.queue.length) {
      const c = this.queue.pop() as LiveChannel; // the latest shown first: what is on screen now
      this.asking.add(c.id);
      this.running++;
      this.ask(c).then(
        (got) => this.done(c, got),
        () => this.done(c, null),
      );
    }
  }

  private done(c: LiveChannel, got: EpgEntry[] | null): void {
    const t = this.clock();
    const entries = (got || []).slice().sort((a, b) => a.start.getTime() - b.start.getTime());
    const on = entries.filter((e) => isOn(e, t))[0];
    const next = entries.filter((e) => e.start.getTime() > t)[0];
    const until = !got
      ? t + FAILED_FOR
      : on
        ? on.end.getTime()
        : next && next.start.getTime() < t + NOTHING_FOR
          ? next.start.getTime()
          : t + NOTHING_FOR;
    this.known.delete(c.id);
    this.known.set(c.id, { entries, until });
    if (this.known.size > REMEMBERED) this.known.delete(this.known.keys().next().value as string);
    this.asking.delete(c.id);
    this.running--;
    // Answers come a few at a time: the screens are told once for them
    if (!this.tell) {
      this.tell = setTimeout(() => {
        this.tell = null;
        this.notify();
      }, 150);
    }
    this.next();
  }
}
