// Movie night (app/lib/remote/movie_night.dart): a few titles, and everyone in the room says yes or
// no to each from their phone. The title most wanted wins; at a tie, the best rated. A phone that
// votes again on a title changes its vote, it does not count twice.
import { Notifier } from '../ui/components';

export interface NightTitle {
  id: string;
  title: string;
  year?: number;
  rating?: number;
  poster?: string;
  plot?: string;
}

export class MovieNight extends Notifier {
  // Title id → phone → yes (true) or no
  private votes: Record<string, Record<string, boolean>> = {};
  /** The posters the phones get, by title id, where they differ from the TV's (see forPhones). */
  private phonePosters: Record<string, string | undefined> | null = null;
  private preparing: Promise<void> = Promise.resolve();

  constructor(readonly titles: NightTitle[]) {
    super();
  }

  /** Notes [voter]'s yes or no to the title [id]; false when there is no such title. */
  vote(voter: string, id: string, yes: boolean): boolean {
    if (!voter || !this.titles.some((t) => t.id === id)) return false;
    (this.votes[id] || (this.votes[id] = {}))[voter] = yes;
    this.notify();
    return true;
  }

  yes(id: string): number {
    const v = this.votes[id] || {};
    return Object.keys(v).filter((k) => v[k]).length;
  }

  no(id: string): number {
    const v = this.votes[id] || {};
    return Object.keys(v).filter((k) => !v[k]).length;
  }

  /** How many phones have voted. */
  get voters(): number {
    const all: Record<string, true> = {};
    for (const id of Object.keys(this.votes)) for (const k of Object.keys(this.votes[id])) all[k] = true;
    return Object.keys(all).length;
  }

  /** The title most wanted (yes minus no), at a tie the best rated; null before any vote. */
  get winner(): NightTitle | null {
    if (!Object.keys(this.votes).length) return null;
    const score = (t: NightTitle) => this.yes(t.id) - this.no(t.id);
    return this.titles.slice().sort((a, b) => score(b) - score(a) || (b.rating || 0) - (a.rating || 0))[0];
  }

  /**
   * Makes the posters fit a page that comes over https (the sync server's): there, the plain http
   * artwork most providers have is blocked, or upgraded to an address that does not answer, and
   * the vote card shows a broken image. Those go as small JPEGs inside the answer instead (the
   * page takes data: images), or not at all. Flutter's page comes from the device over http.
   */
  forPhones(): void {
    const posters: Record<string, string | undefined> = {};
    this.phonePosters = posters; // until each is ready: none rather than a broken one
    this.preparing = Promise.all(this.titles.map((t) => securePoster(t.poster).then((p) => void (posters[t.id] = p)))).then(() => undefined);
  }

  /** What a phone is sent: toJson(), once the posters are ready for it, or a few seconds at most. */
  forPhone(): Promise<Record<string, unknown>> {
    const enough = new Promise<void>((resolve) => setTimeout(resolve, 8000));
    return Promise.race([this.preparing, enough]).then(() => this.toJson());
  }

  toJson(): Record<string, unknown> {
    return {
      open: true,
      titles: this.titles.map((t) => {
        const j: Record<string, unknown> = { id: t.id, title: t.title };
        if (t.year !== undefined) j.year = t.year;
        if (t.rating !== undefined) j.rating = t.rating;
        const poster = this.phonePosters ? this.phonePosters[t.id] : t.poster;
        if (poster) j.poster = poster;
        if (t.plot) j.plot = t.plot;
        return j;
      }),
    };
  }
}

/** [url] as an https page can show it: as it is, TMDB's over https, else a small JPEG of it. */
async function securePoster(url: string | undefined): Promise<string | undefined> {
  if (!url || /^(https|data):/i.test(url)) return url;
  if (!/^http:/i.test(url)) return undefined; // not an address a phone can load at all
  // The same address over https, when its host has it (TMDB's does): what phones would try anyway
  const secure = `https${url.slice(4)}`;
  if (/^http:\/\/image\.tmdb\.org\//i.test(url) || (await loads(secure))) return secure;
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 10000);
  try {
    const res = await fetch(url, { signal: abort.signal });
    return res.ok ? await thumbnail(await res.blob()) : undefined;
  } catch {
    return undefined; // no poster, rather than a broken one
  } finally {
    clearTimeout(timer);
  }
}

/** Whether the image at [url] loads, within a few seconds. */
function loads(url: string): Promise<boolean> {
  return new Promise((resolve) => {
    const img = new Image();
    const timer = setTimeout(() => finish(false), 5000);
    const finish = (ok: boolean) => {
      clearTimeout(timer);
      img.onload = img.onerror = null;
      resolve(ok);
    };
    img.onload = () => finish(true);
    img.onerror = () => finish(false);
    img.src = url;
  });
}

/** [image] cut to a 2:3 poster, as the vote card shows it (260 px wide, at the phone's density). */
function thumbnail(image: Blob): Promise<string | undefined> {
  return new Promise((resolve) => {
    // From a blob: of this page, so the canvas is not tainted as with the provider's address
    const src = URL.createObjectURL(image);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(src);
      const w = 320;
      const h = 480;
      const canvas = document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      const g = canvas.getContext('2d');
      if (!g || !img.naturalWidth || !img.naturalHeight) return resolve(undefined);
      const scale = Math.max(w / img.naturalWidth, h / img.naturalHeight);
      const sw = w / scale;
      const sh = h / scale;
      g.drawImage(img, (img.naturalWidth - sw) / 2, (img.naturalHeight - sh) / 2, sw, sh, 0, 0, w, h);
      try {
        resolve(canvas.toDataURL('image/jpeg', 0.8));
      } catch {
        resolve(undefined);
      }
    };
    img.onerror = () => {
      URL.revokeObjectURL(src);
      resolve(undefined);
    };
    img.src = src;
  });
}
