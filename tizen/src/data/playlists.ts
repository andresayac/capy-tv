// Playlists the user configured (app/lib/data/playlists.dart), in the same JSON shape, so sync
// and backups move them between the two apps unchanged.
import { Notifier } from '../ui/components';
import { CombinedPart, CombinedSource } from './combined';
import { M3uSource } from './m3u';
import { ContentSource, SourceException } from './source';
import { normalizeServer, XtreamSource } from './xtream';

export type PlaylistType = 'xtream' | 'm3u' | 'combined';

export interface Playlist {
  id: string;
  name: string;
  type: PlaylistType;
  url: string; // server (Xtream) or playlist URL (M3U)
  username: string;
  password: string;
  /** What an Xtream panel that lets only some players in is told this one is (set on Flutter). */
  userAgent?: string;
  members: string[]; // combined only: the playlists it joins, by id
  /**
   * What its JSON has that this TV does not edit (Flutter's guideShift, a newer version's): kept.
   * guideShift is read from here (see guideShiftOf), and only set on the phone.
   */
  extra?: Record<string, unknown>;
}

/**
 * Minutes its guide's times move (Flutter's Playlist.guideShift): a provider whose guide is on the
 * wrong clock, put right on the phone and synced. Added to M3U's own tvg-shift.
 */
export function guideShiftOf(p: Playlist): number {
  const shift = p.extra ? p.extra.guideShift : undefined;
  return typeof shift === 'number' && isFinite(shift) ? Math.trunc(shift) : 0;
}

/** The keys this TV reads; any other is kept as it came. */
const KNOWN = ['id', 'name', 'type', 'url', 'username', 'password', 'userAgent', 'members'];

/** What [j] has that this TV does not read, so saving here does not take it away; none when nothing. */
export function playlistExtra(j: Record<string, unknown>): Record<string, unknown> | undefined {
  const out: Record<string, unknown> = {};
  let any = false;
  for (const k of Object.keys(j)) {
    if (KNOWN.indexOf(k) >= 0) continue;
    out[k] = j[k];
    any = true;
  }
  return any ? out : undefined;
}

/**
 * Playlist.toJson() as Flutter writes it: what it does not know first, then its own keys in their
 * order, guideShift (a key of Flutter's own) last.
 */
export function playlistToJson(p: Playlist, withPassword = true): Record<string, unknown> {
  const extra = p.extra || {};
  const j: Record<string, unknown> = {};
  for (const k of Object.keys(extra)) if (k !== 'guideShift') j[k] = extra[k];
  j.id = p.id;
  j.name = p.name;
  j.type = p.type;
  j.url = p.url;
  j.username = p.username;
  if (withPassword) j.password = p.password;
  if (p.userAgent) j.userAgent = p.userAgent;
  if (p.members.length) j.members = p.members;
  if (extra.guideShift !== undefined && extra.guideShift !== 0) j.guideShift = extra.guideShift;
  return j;
}

/** The server as it is reached: "host:8080", "http://host:8080/" and the like are one. */
function serverOf(p: Playlist): string {
  if (p.type !== 'xtream') return p.url.trim();
  try {
    return normalizeServer(p.url);
  } catch {
    return p.url.trim();
  }
}

/** The same account: what decides whether a playlist from elsewhere is new or one already here. */
export function sameAccount(a: Playlist, b: Playlist): boolean {
  return (
    a.type === b.type &&
    serverOf(a) === serverOf(b) &&
    a.username === b.username &&
    a.members.length === b.members.length &&
    a.members.every((m, i) => m === b.members[i])
  );
}

/** A new id: random, so playlists made on different devices never share one. */
/** The server's address for the screens: a link may carry the account in its path or query. */
export function displayAddress(p: Playlist): string {
  try {
    return new URL(p.url).host;
  } catch {
    return '';
  }
}

export function newId(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.prototype.map.call(bytes, (b: number) => (b < 16 ? '0' : '') + b.toString(16)).join('');
}

/**
 * The Xtream account in a link providers hand out: "http://host:8080/get.php?username=…&password=…"
 * (or player_api.php, xmltv.php), or a stream's address ".../live/user/pass/1.ts". Null otherwise.
 */
export function xtreamLink(text: string): { server: string; username: string; password: string } | null {
  let u: URL;
  try {
    u = new URL(text.trim());
  } catch {
    return null;
  }
  if ((u.protocol !== 'http:' && u.protocol !== 'https:') || !u.hostname) return null;
  const server = `${u.protocol}//${u.host}`;
  const user = u.searchParams.get('username') || '';
  const pass = u.searchParams.get('password') || '';
  if (user && pass) return { server, username: user, password: pass };
  // A bare "%" (a password with one) is no escape: that segment stays as it is, as Dart's Uri does
  const decode = (x: string) => {
    try {
      return decodeURIComponent(x);
    } catch {
      return x;
    }
  };
  // A panel's stream ends in its numeric id: a CDN's /live/sports/us/playlist.m3u8 is no account
  const s = u.pathname.split('/').filter(Boolean).map(decode);
  if (s.length >= 4 && ['live', 'movie', 'series', 'timeshift'].indexOf(s[0]) >= 0 && /^\d+(\.\w+)?$/.test(s[s.length - 1])) {
    return { server, username: s[1], password: s[2] };
  }
  return null;
}

/** A new playlist from what the user typed: trimmed, named after the server when unnamed. */
export function createPlaylist(p: { type: PlaylistType; url: string; name?: string; username?: string; password?: string }): Playlist {
  const x = xtreamLink(p.url);
  if (x && !(p.username || '').trim()) {
    return createPlaylist({ type: 'xtream', url: x.server, name: p.name, username: x.username, password: x.password });
  }
  const url = p.url.trim();
  let host = url;
  try {
    host = new URL(url.indexOf('://') < 0 ? 'http://' + url : url).hostname;
  } catch {
    // The URL itself, then
  }
  return {
    id: newId(),
    name: (p.name || '').trim() || host,
    type: p.type,
    url,
    username: (p.username || '').trim(),
    password: (p.password || '').trim(), // pasted from a chat, it often carries a space at the end
    members: [],
  };
}

export function combinePlaylists(name: string, members: string[], id?: string): Playlist {
  return { id: id || newId(), name: name.trim(), type: 'combined', url: '', username: '', password: '', members: members.slice() };
}

/** With [refetch] ("Update list") its lists and guide come from the provider, not the TV's copies. */
export async function openPlaylist(p: Playlist, liveFormat = 'ts', refetch = false): Promise<ContentSource> {
  switch (p.type) {
    case 'xtream': {
      const x = new XtreamSource(p.url, p.username, p.password, liveFormat);
      x.refetch = refetch;
      x.userAgent = p.userAgent;
      x.guideShift = guideShiftOf(p);
      return x;
    }
    case 'm3u': {
      const m = await M3uSource.load(p.url, true, refetch);
      m.guideShift = guideShiftOf(p);
      return m;
    }
    case 'combined': {
      const all = playlistStore.playlists;
      // One missing, or that does not open, leaves its place empty: the ids of the others keep theirs
      const slots: (CombinedPart | null)[] = [];
      const failed: string[] = [];
      let error: unknown = null;
      for (const id of p.members) {
        const member = all.filter((x) => x.id === id && x.type !== 'combined')[0];
        let part: CombinedPart | null = null;
        if (member) {
          try {
            part = { name: member.name, source: await openPlaylist(member, liveFormat, refetch) };
          } catch (e) {
            if (error === null) error = e;
            failed.push(member.name);
          }
        }
        slots.push(part);
      }
      const source = new CombinedSource(slots);
      source.failed = failed;
      if (!source.parts.length) throw error || new SourceException('notFound');
      // Each panel's clock, for its catch-up: in the background, and one that fails only keeps the TV's
      for (const part of source.parts) if (part.source instanceof XtreamSource) part.source.login().catch(() => undefined);
      return source;
    }
  }
}

/**
 * Live streams of [source] as [format] ('ts' or 'm3u8') from the next channel on: an Xtream
 * account, or every Xtream one in a combined playlist (Flutter's HomeScreen does it on each build).
 */
export function applyLiveFormat(source: ContentSource, format: string): void {
  if (source instanceof XtreamSource) source.liveFormat = format;
  else if (source instanceof CombinedSource) for (const p of source.parts) applyLiveFormat(p.source, format);
}

/** Throws a SourceException unless the playlist loads (M3U) or the account logs in (Xtream). */
export async function verifyPlaylist(p: Playlist): Promise<void> {
  if (p.type === 'm3u') {
    await M3uSource.load(p.url, true, false, true); // for real, not a copy from before; kept for its first opening
    return;
  }
  const source = await openPlaylist(p);
  if (source instanceof XtreamSource) await source.login();
}

/**
 * Playlists saved on this TV. A web app has no keystore: they live in the app's own storage,
 * which no other app can read.
 */
class PlaylistStore extends Notifier {
  private static key = 'playlists';
  playlists: Playlist[] = read(PlaylistStore.key);

  private save(list: Playlist[]): void {
    this.playlists = list;
    localStorage.setItem(PlaylistStore.key, JSON.stringify(list));
    this.notify();
  }

  add(p: Playlist): void {
    this.save(this.playlists.concat([p]));
  }

  /** Replaces the playlist with the same id. */
  update(p: Playlist): void {
    this.save(this.playlists.map((x) => (x.id === p.id ? p : x)));
  }

  remove(p: Playlist): void {
    this.save(this.playlists.filter((x) => x.id !== p.id));
  }
}

function read(key: string): Playlist[] {
  try {
    const list = JSON.parse(localStorage.getItem(key) || '[]') as Partial<Playlist>[];
    return list.map((j) => {
      const p: Playlist = {
        id: j.id || newId(),
        name: j.name || '',
        type: (j.type || 'xtream') as PlaylistType,
        url: j.url || '',
        username: j.username || '',
        password: j.password || '',
        members: j.members || [],
      };
      // Not dropped as it is read back: synced without them, a phone's playlist would lose them too
      if (typeof j.userAgent === 'string' && j.userAgent) p.userAgent = j.userAgent;
      if (j.extra && typeof j.extra === 'object') p.extra = j.extra;
      return p;
    });
  } catch {
    return [];
  }
}

export const playlistStore = new PlaylistStore();
