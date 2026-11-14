// The provider's lists on their way (app/lib/data/source.dart): how far those someone waits for
// have got, for the loading screens, and the new copies brought in the background.
import { Gunzip } from 'fflate';
import { nowPlaying } from '../remote/now';
import { Notifier } from '../ui/components';
import { writeCache } from './cache';
import { SourceException, statusError } from './source';

/** The least time between two changes (ms): a TV redraws for each one. */
const EVERY = 300;

/** How far a download of a list got: the bytes so far, and in all when the server said. */
export interface DownloadProgress {
  received: number;
  total: number | null;
}

/**
 * The lists downloading that someone waits for, all of them together; null while there are none.
 * The total comes once all of them have answered, and one done still counts until the last one
 * ends, so the share does not fall as lists join or leave.
 */
class ListDownloads extends Notifier {
  value: DownloadProgress | null = null;
  running = 0;
  private unanswered = 0;
  private received = 0;
  private total = 0;
  private sized = true; // each download so far said how big it is
  private shownAt = 0;

  begin(): void {
    this.running++;
    this.unanswered++;
    this.show();
  }

  answered(total: number | null): void {
    this.unanswered--;
    if (total === null) this.sized = false;
    else this.total += total;
    this.show();
  }

  add(bytes: number): void {
    this.received += bytes;
    if (Date.now() - this.shownAt >= EVERY) this.show();
  }

  end(answered: boolean): void {
    if (!answered) this.unanswered--;
    if (--this.running > 0) {
      this.show();
      return;
    }
    this.received = this.total = 0;
    this.sized = true;
    this.value = null;
    this.notify();
  }

  private show(): void {
    this.shownAt = Date.now();
    this.value = { received: this.received, total: this.sized && !this.unanswered ? this.total : null };
    this.notify();
  }
}

export const listDownloads = new ListDownloads();

/** What a list being brought holds. */
export type ImportKind = 'live' | 'movies' | 'series' | 'playlist';

const IMPORT_KINDS: ImportKind[] = ['live', 'movies', 'series', 'playlist'];

/** How far the lists of a kind have got: read is null while they still download. */
export interface ImportRow {
  kind: ImportKind;
  items: number;
  read: number | null;
  done: boolean;
}

/** One list someone waits for, from asking for it until it can be used. */
export class ListImport {
  items = 0;
  read: number | null = null;
  done = false;

  constructor(readonly kind: ImportKind) {}

  /** This many have come so far. Never fewer than before: read again, a list starts from none. */
  counted(items: number): void {
    if (items <= this.items) return;
    this.items = items;
    listImports.changed();
  }

  /** This many have been read, [share] of the list. */
  reading(items: number, share: number): void {
    this.read = share;
    if (items > this.items) this.items = items;
    listImports.changed();
  }

  /** It is here, with [items] in it. */
  finish(items: number): void {
    this.items = items;
    this.read = 1;
    this.done = true;
    listImports.ended();
  }

  /** It did not come: it says nothing any more. */
  fail(): void {
    listImports.drop(this);
  }
}

/** How long lists that have all come are still shown: what is made of them takes a while more. */
const LINGER = 30000;

/** The lists someone waits for, by kind, as the loading screens show them. */
class ListImports extends Notifier {
  value: ImportRow[] = [];
  private imports: ListImport[] = [];
  private shownAt = 0;
  private endedAt: number | null = null;

  /** The rows to show now: none once they have been done for a while. */
  get current(): ImportRow[] {
    return this.endedAt !== null && Date.now() - this.endedAt >= LINGER ? [] : this.value;
  }

  /** All the items so far. */
  get items(): number {
    return this.current.reduce((sum, row) => sum + row.items, 0);
  }

  /** Some list someone waits for is still being read, or is still to come. */
  get pending(): boolean {
    return this.imports.some((i) => !i.done);
  }

  start(kind: ImportKind): ListImport {
    if (this.endedAt !== null) this.imports = []; // the ones before are over: this is another load
    this.endedAt = null;
    const item = new ListImport(kind);
    this.imports.push(item);
    this.publish();
    return item;
  }

  changed(): void {
    if (Date.now() - this.shownAt >= EVERY) this.publish();
  }

  ended(): void {
    if (this.imports.every((i) => i.done)) this.endedAt = Date.now();
    this.publish();
  }

  drop(item: ListImport): void {
    this.imports = this.imports.filter((i) => i !== item);
    this.ended();
  }

  private publish(): void {
    this.shownAt = Date.now();
    this.value = [];
    for (const kind of IMPORT_KINDS) {
      const list = this.imports.filter((i) => i.kind === kind);
      if (!list.length) continue;
      this.value.push({
        kind,
        items: list.reduce((sum, i) => sum + i.items, 0),
        read: list.some((i) => i.read === null) ? null : list.reduce((sum, i) => sum + (i.read as number), 0) / list.length,
        done: list.every((i) => i.done),
      });
    }
    this.notify();
  }
}

export const listImports = new ListImports();

/** A background download that gave way (see [downloadList]). */
export class DownloadStopped extends Error {}

interface DownloadOptions {
  /** The download is in the background: once this aborts it stops, its connection closed. */
  giveWay?: AbortSignal;
  /** Its playlist was left: the download stops (DownloadStopped), one someone waited for too. */
  stop?: AbortSignal;
  /** Sees each piece of the body as it comes. */
  onPiece?: (piece: Uint8Array) => void;
}

/**
 * The text at [url], read as it arrives (Flutter's downloadTo). [wait] is how long the answer, and
 * then each piece of it, may take, so a big list on a slow line still gets there. One someone waits
 * for counts in listDownloads from the moment it is asked for; one in the background passes giveWay
 * instead. Throws a SourceException, or DownloadStopped.
 */
export async function downloadList(url: string, wait: number, opts: DownloadOptions = {}): Promise<string> {
  const { giveWay, onPiece } = opts;
  const halts = [giveWay, opts.stop].filter((s): s is AbortSignal => !!s);
  const shown = !giveWay;
  if (shown) listDownloads.begin();
  let answered = false;
  const abort = new AbortController();
  const stop = () => abort.abort();
  let expired = false;
  let timer = 0;
  const wind = () => {
    clearTimeout(timer);
    timer = window.setTimeout(() => {
      expired = true;
      abort.abort();
    }, wait);
  };
  const failure = (e: unknown): Error => {
    if (expired) return new SourceException('timeout');
    if (halts.some((s) => s.aborted)) return new DownloadStopped();
    return new SourceException('unreachable', String(e));
  };
  try {
    for (const s of halts) {
      if (s.aborted) throw new DownloadStopped();
      s.addEventListener('abort', stop);
    }
    wind();
    let res: Response;
    try {
      res = await fetch(url, { signal: abort.signal });
    } catch (e) {
      throw failure(e);
    }
    if (res.status !== 200) throw statusError(res.status);
    // The size the server sends: a compressed body grows past it once unpacked
    const encoding = res.headers.get('content-encoding');
    const total = encoding && encoding !== 'identity' ? null : Number(res.headers.get('content-length')) || null;
    if (shown) {
      listDownloads.answered(total);
      answered = true;
    }
    try {
      if (!res.body) {
        clearTimeout(timer);
        return await res.text();
      }
      const reader = res.body.getReader();
      // UTF-8, or Windows-1252 for a list whose start is no UTF-8 ("Espa\xf1a" would read "Espa�a")
      let decoder: TextDecoder | null = null;
      let text = '';
      let received = 0;
      const take = (data: Uint8Array) => {
        if (!decoder) decoder = new TextDecoder(isUtf8(data) ? 'utf-8' : 'windows-1252');
        text += decoder.decode(data, { stream: true });
        if (onPiece) onPiece(data);
      };
      // A .gz sent with no Content-Encoding comes packed: unpacked here, as the guide is (workers/xmltv.ts)
      let gunzip: Gunzip | null = null;
      for (;;) {
        wind();
        const piece = await reader.read();
        if (piece.done || !piece.value) break;
        if (received === 0 && piece.value[0] === 0x1f && piece.value[1] === 0x8b) gunzip = new Gunzip((data) => take(data));
        received += piece.value.length;
        if (gunzip) gunzip.push(piece.value);
        else take(piece.value);
        if (shown) listDownloads.add(piece.value.length);
      }
      // The line dropped before the end: a playlist cut short reads as a whole one
      if (total !== null && received < total) throw new SourceException('unreachable', 'cut short');
      if (gunzip) gunzip.push(new Uint8Array(0), true); // a packed one cut short throws here
      const done = decoder as TextDecoder | null; // set in take(), which the compiler does not follow
      return done ? text + done.decode() : text;
    } catch (e) {
      throw e instanceof SourceException ? e : failure(e);
    }
  } finally {
    clearTimeout(timer);
    for (const s of halts) s.removeEventListener('abort', stop);
    abort.abort(); // a download given up midway stops here; a finished one is not affected
    if (shown) listDownloads.end(answered);
  }
}

/** Whether [head], the start of a text, is UTF-8: its last bytes may cut a letter short. */
function isUtf8(head: Uint8Array): boolean {
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(head.subarray(0, Math.max(0, Math.min(head.length, 64 << 10) - 3)));
    return true;
  } catch {
    return false;
  }
}

interface Refresh {
  bring: (giveWay: AbortSignal) => Promise<string | null>;
  dropped: boolean;
  stop: (() => void) | null; // while it downloads
}

/** What is being refreshed in the background, by cache key. */
const refreshing: Record<string, Refresh> = {};
let refreshes: Promise<void> = Promise.resolve();

/** The keys about to be replaced by a list someone waits for, and by how many. */
const held: Record<string, number> = {};

/**
 * Brings a new copy of what is kept under [key], an old one, for the next load, in the background:
 * [bring] gives its text, as downloadList gets it (giving way when told), and only when it came
 * whole and is what [key] holds is it written. It is never parsed here, and the copy already read
 * stays for this session: on a TV the old catalog and the new one do not fit at once.
 *
 * One at a time, the next once it is over: a slow line brings one list sooner alone. None while a
 * stream plays or a list someone waits for downloads; one under way then stops and starts again
 * once they are over. None starts either while lists someone waits for are still being read: at
 * that moment the TV has the old copies in memory, as text and as models. One per key, whatever
 * source asks, and none while a list someone waits for is replacing it (holdRefresh). Failing it
 * says nothing: the copy stays, and the next load tries again.
 */
export function refreshInBackground(key: string, bring: (giveWay: AbortSignal) => Promise<string | null>): void {
  if (refreshing[key] || held[key]) return; // on its way already
  const refresh: Refresh = { bring, dropped: false, stop: null };
  refreshing[key] = refresh;
  const done = () => {
    if (refreshing[key] === refresh) delete refreshing[key];
  };
  refreshes = refreshes.then(() => run(key, refresh)).then(done, done);
}

/**
 * A list someone waits for is about to replace [key]: its refresh, if any, is forgotten, and none
 * is asked for until releaseRefresh, once that list is in its place.
 */
export function holdRefresh(key: string): void {
  held[key] = (held[key] || 0) + 1;
  const refresh = refreshing[key];
  if (!refresh) return;
  delete refreshing[key];
  refresh.dropped = true;
  if (refresh.stop) refresh.stop();
}

export function releaseRefresh(key: string): void {
  if (--held[key] <= 0) delete held[key];
}

async function run(key: string, r: Refresh): Promise<void> {
  while (!r.dropped) {
    if (mustWait()) {
      await nextChange();
      continue;
    }
    const giveWay = new AbortController();
    r.stop = () => giveWay.abort();
    const yieldWhenBusy = () => {
      if (lineTaken()) giveWay.abort();
    };
    const unlisten = [nowPlaying.listen(yieldWhenBusy), listDownloads.listen(yieldWhenBusy)];
    try {
      const text = await r.bring(giveWay.signal);
      if (text !== null && !r.dropped) await writeCache(key, text);
      return;
    } catch (e) {
      if (!(e instanceof DownloadStopped)) return; // the copy there was stays; the next load tries again
    } finally {
      unlisten.forEach((off) => off());
      r.stop = null;
    }
  }
}

/** A stream plays, or a list someone waits for downloads: the line is theirs. */
const lineTaken = () => nowPlaying.value !== null || listDownloads.running > 0;

const mustWait = () => lineTaken() || listImports.pending;

/** Completes on the next change of what plays, downloads or is read. */
function nextChange(): Promise<void> {
  return new Promise((resolve) => {
    const off = [nowPlaying, listDownloads, listImports].map((n: Notifier) =>
      n.listen(() => {
        off.forEach((f) => f());
        resolve();
      }),
    );
  });
}
