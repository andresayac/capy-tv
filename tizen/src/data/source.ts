// What the UI needs from any provider (app/lib/data/source.dart, models.dart).
import { t } from '../i18n';
import type { EpgGuide } from './epg';
import type { Episode, Movie, Series, SeriesDetail } from './models';

export { asInt, asStr } from './values';

export interface Category {
  id: string;
  name: string;
}

export interface LiveChannel {
  id: string;
  name: string;
  number?: number;
  icon?: string;
  epgId?: string;
  categoryId?: string;
  archiveDays: number;
  url?: string; // M3U only: the playlist carries the URL
}

export interface EpgEntry {
  title: string;
  description: string;
  start: Date;
  end: Date;
}

export interface AccountInfo {
  status: string;
  expires?: Date;
  maxConnections?: number; // none when the provider states no limit (0)
  activeConnections?: number;
  isTrial: boolean;
  formats: string[];
  /** As the panel names it ("Europe/Madrid"). */
  serverTimezone?: string;
  /** The server's UTC offset in minutes: catch-up addresses are in server time. */
  serverUtcOffset?: number;
  /** What the panel says to its users (user_info.message), when it says anything. */
  message?: string;
}

export interface ContentSource {
  /** After "Update list": something could not be had anew, and what shows is the copy there was. */
  notUpdated?: boolean;
  liveCategories(): Promise<Category[]>;
  liveChannels(categoryId?: string): Promise<LiveChannel[]>;
  movieCategories(): Promise<Category[]>;
  movies(categoryId?: string): Promise<Movie[]>;
  seriesCategories(): Promise<Category[]>;
  series(categoryId?: string): Promise<Series[]>;
  seriesDetail(s: Series): Promise<SeriesDetail>;
  /** The full record of a movie (synopsis, cast, backdrop...), when the source has one. */
  movieDetail?(m: Movie): Promise<Movie>;
  shortEpg(c: LiveChannel, limit?: number): Promise<EpgEntry[]>;
  /** The full XMLTV guide; empty when the source has none, or when [stop] says it is no longer wanted. */
  /** [early]: a copy kept from earlier, to show while the new one downloads (see loadXmltv). */
  guide(stop?: AbortSignal, early?: (kept: EpgGuide) => void): Promise<EpgGuide>;
  /** Its playlist was left: what it still downloads stops. Nothing is asked of it after this. */
  close?(): void;
  liveUrl(c: LiveChannel): string;
  /** Catch-up of what [c] aired at [start] for [minutes]; null without an archive. */
  catchupUrl(c: LiveChannel, start: Date, minutes: number): string | null;
  movieUrl(m: Movie): string;
  episodeUrl(e: Episode): string;
  /**
   * The User-Agent the stream at [url] must be asked with (an M3U entry's #EXTVLCOPT
   * http-user-agent); usually none. Flutter's headersFor, of which AVPlay can send only this one.
   */
  userAgentFor(url: string): string | undefined;
  /** Leaves adult content out of every category and list. */
  hideAdult: boolean;
  /** Lists only what a kids profile may see (see kids.ts). */
  kidsOnly: boolean;
}

const adultName = /(^|[^a-z])(xxx|adult(?:[oa]|e)?s?|porn\w*|er[oó]ti[ck][oa]?s?|hentai|sexo?|sexy|playboy|brazzers|erwachsene|x-?rated|mayores de 18(?!\d)|r-?18(?!\d))(?![a-z])|\+ ?18(?!\d)|(^|\D)18 ?\+|🔞/i;

/** Whether a category's name says it is for adults ("XXX", "Adultos", "+18", ...). */
export function isAdultCategory(name: string): boolean {
  return adultName.test(name);
}

export type SourceError =
  | 'unreachable'
  | 'timeout'
  | 'unauthorized'
  | 'inactiveAccount'
  | 'httpStatus'
  | 'badResponse'
  | 'notFound'
  | 'emptyPlaylist'
  | 'badAddress' // the server's address cannot be one
  | 'wrongServer' // a 404 to a login: an unknown login, or an address that is not a panel's
  | 'providerBusy'; // a 429 or 5xx

/** What an answer with [status] (not 200) is: a refused account, a provider overloaded, or else the status. */
export function statusError(status: number): SourceException {
  if (status === 401 || status === 403) return new SourceException('unauthorized', String(status));
  if (status === 429 || status >= 500) return new SourceException('providerBusy', String(status));
  return new SourceException('httpStatus', String(status));
}

/** A failure the UI can translate: [error] picks the message, [detail] fills it in. */
/**
 * Whether [e] is the panel itself saying the account is no good (the auth in its answer, or an
 * account not active), rather than a server that would not let its API be asked (401, 403, 404).
 */
export function accountRefused(e: unknown): boolean {
  return e instanceof SourceException && ((e.error === 'unauthorized' && !e.detail) || e.error === 'inactiveAccount');
}

export class SourceException extends Error {
  constructor(readonly error: SourceError, readonly detail?: string) {
    super(detail ? `${error}: ${detail}` : error);
  }
}

/** An account's status as the panel sends it ("Expired"), in the app's language; one it does not know, as sent. */
export function accountStatusText(raw: string): string {
  switch (raw.trim().toLowerCase()) {
    case 'active': return t('statusActive');
    case 'expired': return t('statusExpired');
    case 'banned': return t('statusBanned');
    case 'disabled': return t('statusDisabled');
    case 'trial': return t('statusTrial');
    case '': case 'unknown': return t('statusUnknown');
    default: return raw;
  }
}

export function errorText(e: unknown): string {
  if (!(e instanceof SourceException)) return t('errorUnknown');
  switch (e.error) {
    case 'unreachable': return t('errorUnreachable');
    case 'timeout': return t('errorTimeout');
    case 'unauthorized': return t('errorUnauthorized');
    case 'inactiveAccount': return t('errorInactive', { status: accountStatusText(e.detail || '') });
    case 'httpStatus': return t('errorHttp', { code: e.detail || '' });
    case 'badAddress': return t('errorBadAddress');
    case 'wrongServer': return t('errorWrongServer');
    case 'providerBusy': return t('errorProviderBusy');
    case 'badResponse': return t('errorBadResponse');
    case 'notFound': return t('errorNotFound');
    case 'emptyPlaylist': return t('errorEmptyPlaylist');
  }
}

/**
 * The text at [url], all of it within [timeoutMs]: a panel that sends its headers and then nothing
 * gives up too, rather than loading for ever. Failures as SourceExceptions. [stop]: its playlist
 * was left, and the request stops.
 */
export async function fetchText(url: string, timeoutMs: number, stop?: AbortSignal): Promise<string> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  const halt = () => abort.abort();
  if (stop) {
    if (stop.aborted) abort.abort();
    else stop.addEventListener('abort', halt);
  }
  try {
    const res = await download(url, timeoutMs, abort);
    try {
      return await res.text();
    } catch (e) {
      throw (e as Error).name === 'AbortError'
        ? new SourceException('timeout')
        : new SourceException('unreachable', String(e));
    }
  } finally {
    clearTimeout(timer);
    if (stop) stop.removeEventListener('abort', halt);
  }
}

/** A GET with a timeout, its failures as SourceExceptions. */
export async function download(url: string, timeoutMs: number, given?: AbortController): Promise<Response> {
  const abort = given || new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  let res: Response;
  try {
    res = await fetch(url, { signal: abort.signal });
  } catch (e) {
    throw (e as Error).name === 'AbortError'
      ? new SourceException('timeout')
      : new SourceException('unreachable', String(e));
  } finally {
    clearTimeout(timer);
  }
  if (res.status !== 200) throw statusError(res.status);
  return res;
}

/**
 * A short hash of [s] that is the same on every device, as the Flutter app makes it: 64-bit
 * FNV-1a over UTF-8, in hex. Ids made from it match between the two apps.
 */
export function stableHash(s: string): string {
  let h = BigInt('0xcbf29ce484222325');
  const prime = BigInt('0x100000001b3');
  const mask = BigInt('0xffffffffffffffff');
  for (const b of new TextEncoder().encode(s)) {
    h = ((h ^ BigInt(b)) * prime) & mask;
  }
  return h.toString(16).padStart(16, '0');
}
