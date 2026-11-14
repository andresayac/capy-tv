// How provider values are read (app/lib/data/models.dart): Xtream servers mix types freely (ids
// as numbers or strings, "rating": 8 or "8", null or ""). Nothing else in here, so the parsing
// worker (src/workers/catalog.ts) can use it without the rest of the app.

/**
 * A text, or none: an empty one, a list or an object sent where a text goes (plot: []), or the
 * words panels write for nothing ("null", "N/A").
 */
export function asStr(v: unknown): string | undefined {
  if (v === null || v === undefined || typeof v === 'object') return undefined;
  const s = String(v).trim();
  return s && ['null', 'n/a'].indexOf(s.toLowerCase()) < 0 ? s : undefined;
}

export function asInt(v: unknown): number | undefined {
  if (typeof v === 'number') return Math.trunc(v);
  // A panel or bridge that sends auth, is_adult, tv_archive as true/false
  if (typeof v === 'boolean') return v ? 1 : 0;
  const word = String(v).trim().toLowerCase();
  if (word === 'true' || word === 'false') return word === 'true' ? 1 : 0;
  const n = parseInt(String(v), 10);
  return isNaN(n) ? undefined : n;
}

/** A rating as panels write it: 8, "8.2", "7,5" (a decimal comma), "8.2/10"; none for what is not a finite number. */
export function asDouble(v: unknown): number | undefined {
  if (v === null || v === undefined || typeof v === 'object') return undefined;
  const n = typeof v === 'number' ? v : parseFloat(String(v).trim().replace(',', '.'));
  return isFinite(n) ? n : undefined;
}

export function fromUnix(v: unknown): Date | undefined {
  const secs = asInt(v);
  return !secs ? undefined : new Date(secs * 1000);
}

/** What Dart's DateTime.tryParse takes: "2021-05-01", "20210501", "2021-05-01 20:30:00", "…T20:30Z", "…+01:00". */
const dartDate = /^([+-]?\d{4,6})-?(\d\d)-?(\d\d)(?:[ T](\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?( ?[zZ]| ?([-+])(\d\d)(?::?(\d\d))?)?)?$/;

/**
 * A date as the Flutter app reads it (DateTime.tryParse): without a zone it is local time, so
 * "2021-05-01" is that day here, not the evening before (JavaScript takes a bare date as UTC).
 */
export function parseDate(s: string): Date | undefined {
  const m = dartDate.exec(s.trim());
  if (!m) return undefined;
  const n = (i: number) => (m[i] ? parseInt(m[i], 10) : 0);
  const ms = m[7] ? Math.floor(parseFloat('0.' + m[7]) * 1000) : 0;
  let d: Date;
  if (m[8] === undefined) {
    d = new Date(2000, 0, 1, n(4), n(5), n(6), ms);
    d.setFullYear(n(1), n(2) - 1, n(3)); // years under 100 too
  } else {
    d = new Date(Date.UTC(2000, 0, 1, n(4), n(5), n(6), ms));
    d.setUTCFullYear(n(1), n(2) - 1, n(3));
    if (m[9]) d = new Date(d.getTime() - (m[9] === '-' ? -1 : 1) * (n(10) * 60 + n(11)) * 60000);
  }
  // MySQL's empty "0000-00-00", and anything before films were made, is no date
  return isNaN(d.getTime()) || d.getFullYear() < 1870 ? undefined : d;
}

export function asDate(v: unknown): Date | undefined {
  const s = asStr(v);
  return s ? parseDate(s) : undefined;
}
