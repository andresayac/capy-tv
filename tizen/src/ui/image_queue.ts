// Provider images, a few at a time (app/lib/data/image_store.dart, without its disk: on the TV the
// browser's own HTTP cache is the disk). A catalog's images are many, on hosts that are often slow
// or dead, and a TV cannot open dozens of connections at once: what has just come on screen goes
// first, and what was scrolled past stops waiting.

/** How many images come over the line at once: Flutter's for low-memory devices (app/lib/device.dart). */
const MAX_DOWNLOADS = 4;

/** How long an image keeps its place in line: past it, one that has not come lets others by, and may still come. */
const WAIT = 15000;

/** One screen's worth asked for together, in the order it was asked: top to bottom. */
const SAME_MOMENT = 200;

/** How long an image that failed is left alone. */
const LEFT_ALONE = 60000;

interface Waiting {
  moment: number;
  order: number;
  go: () => void;
}

const waiting: Waiting[] = [];
let running = 0;
let asked = 0;
const failed: Record<string, number> = {}; // until when each is left alone
let failures = 0;

/** What was asked for last goes first (it is what is on screen now), and each moment's in order. */
const goesBefore = (a: Waiting, b: Waiting) => (a.moment !== b.moment ? a.moment > b.moment : a.order < b.order);

function next(): void {
  while (running < MAX_DOWNLOADS && waiting.length) {
    let first = 0;
    for (let i = 1; i < waiting.length; i++) if (goesBefore(waiting[i], waiting[first])) first = i;
    running++;
    waiting.splice(first, 1)[0].go();
  }
}

/**
 * Something near the screen shows an image: [start] runs when its turn comes. What this returns
 * says it is over (it came, it broke, or it left the screen before its turn): one still waiting
 * leaves the line, and one on its way lets the next go.
 */
export function imageTurn(start: () => void): () => void {
  let started = false;
  let left = false;
  let timer = 0;
  const leave = () => {
    if (left) return;
    left = true;
    clearTimeout(timer);
    if (started) {
      running--;
      next();
    } else {
      waiting.splice(waiting.indexOf(me), 1);
    }
  };
  const me: Waiting = {
    moment: Math.floor(Date.now() / SAME_MOMENT),
    order: asked++,
    go: () => {
      started = true;
      timer = window.setTimeout(leave, WAIT);
      start();
    },
  };
  waiting.push(me);
  next();
  return leave;
}

/** [url]'s image failed: it is left alone for a while, not to take a place in line again. */
export function imageFailed(url: string): void {
  if (++failures > 4096) {
    for (const k of Object.keys(failed)) delete failed[k];
    failures = 1;
  }
  failed[url] = Date.now() + LEFT_ALONE;
}

/** Whether [url]'s image failed a moment ago. */
export function imageLeftAlone(url: string): boolean {
  return (failed[url] || 0) > Date.now();
}
