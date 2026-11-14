// Big provider answers kept on the TV (IndexedDB: localStorage holds a few MB, a catalog is tens):
// within their freshness they are read from here, and an older copy still serves when the
// provider is down. Copies nobody wrote for a while are dropped, as the Flutter app drops its
// cache files (app/lib/data/source.dart dropStaleCache). A cache only: every failure here is
// ignored.

interface Entry {
  key: string;
  /** The text, or a guide's parts (src/data/epg.ts). */
  text: string | string[];
  at: number;
}

const DAY = 24 * 60 * 60 * 1000;

/** How long a copy of each kind outlives its last write: guides a week, the rest a month. */
const KEEP: [string, number][] = [
  ['epg-', 7 * DAY],
  ['catalog-', 30 * DAY],
  ['m3u-', 30 * DAY],
];

let db: Promise<IDBDatabase | null> | null = null;

function open(): Promise<IDBDatabase | null> {
  if (!db) {
    db = new Promise((resolve) => {
      try {
        // Version 2 indexes the write times: ages are read, and old copies found, without loading
        // values of tens of MB
        const req = indexedDB.open('capytv-cache', 2);
        req.onupgradeneeded = () => {
          const d = req.result;
          const store = d.objectStoreNames.contains('texts') ? req.transaction!.objectStore('texts') : d.createObjectStore('texts', { keyPath: 'key' });
          if (!store.indexNames.contains('at')) store.createIndex('at', 'at');
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => resolve(null);
        req.onblocked = () => resolve(null);
      } catch {
        resolve(null);
      }
    });
  }
  return db;
}

async function readEntry(key: string): Promise<Entry | null> {
  const d = await open();
  if (!d) return null;
  return new Promise((resolve) => {
    try {
      const req = d.transaction('texts').objectStore('texts').get(key);
      req.onsuccess = () => resolve((req.result as Entry | undefined) || null);
      req.onerror = () => resolve(null);
    } catch {
      resolve(null);
    }
  });
}

/** A text kept under [key], and how long ago it was written. */
export async function readCache(key: string): Promise<{ text: string; age: number } | null> {
  const e = await readEntry(key);
  return e && typeof e.text === 'string' ? { text: e.text, age: Date.now() - e.at } : null;
}

/** Parts kept under [key] (a guide), and how long ago they were written. */
export async function readCacheParts(key: string): Promise<{ parts: string[]; age: number } | null> {
  const e = await readEntry(key);
  return e && Array.isArray(e.text) ? { parts: e.text, age: Date.now() - e.at } : null;
}

/** How long ago [key] was written, without reading it; null when there is no copy. */
export async function cacheAge(key: string): Promise<number | null> {
  const d = await open();
  if (!d) return null;
  return new Promise((resolve) => {
    try {
      const req = d.transaction('texts').objectStore('texts').index('at').openKeyCursor();
      req.onsuccess = () => {
        const c = req.result;
        if (!c) return resolve(null);
        if (c.primaryKey === key) return resolve(Date.now() - Number(c.key));
        c.continue();
      };
      req.onerror = () => resolve(null);
    } catch {
      resolve(null);
    }
  });
}

/** Keeps [value] under [key], then drops the copies of its kind nobody wrote for long. */
export async function writeCache(key: string, value: string | string[]): Promise<void> {
  const d = await open();
  if (!d) return;
  try {
    d.transaction('texts', 'readwrite').objectStore('texts').put({ key, text: value, at: Date.now() } as Entry);
  } catch {
    // Full or gone: next time, then
  }
  pruneCache(key);
}

/**
 * Deletes the copies of [keep]'s kind (its prefix: "epg-", "catalog-", "m3u-") written longer ago
 * than that kind is kept, [keep] itself aside: playlists long gone, old passwords, old guides.
 */
export async function pruneCache(keep: string): Promise<void> {
  const rule = KEEP.filter(([prefix]) => keep.indexOf(prefix) === 0)[0];
  if (!rule) return;
  const d = await open();
  if (!d) return;
  try {
    const store = d.transaction('texts', 'readwrite').objectStore('texts');
    const req = store.index('at').openKeyCursor(IDBKeyRange.upperBound(Date.now() - rule[1]));
    req.onsuccess = () => {
      const c = req.result;
      if (!c) return;
      const k = String(c.primaryKey);
      if (k !== keep && k.indexOf(rule[0]) === 0) store.delete(c.primaryKey);
      c.continue();
    };
  } catch {
    // Not worth failing over
  }
}
