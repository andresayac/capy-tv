// The sync server's HTTP API (app/lib/sync/sync_client.dart, server/README.md).
//
// A browser's WebSocket cannot send the Authorization header the Flutter app's live socket has:
// the token goes as one of its subprotocols instead (see live()). A server that does not take it
// there refuses the socket, and the service asks for changes at intervals instead (SyncService).
import { toBase64 } from './crypto';

/** Why a call to the sync server failed, in terms the UI can explain. */
export type SyncProblem =
  | 'credentials' // wrong email or password
  | 'exists' // an account with that email already exists
  | 'rateLimited'
  | 'signedOut' // the session is gone: signed out elsewhere or account deleted
  | 'stale' // another device wrote first: fetch its changes and try again
  | 'invite' // this server only creates accounts with its invitation code
  | 'full' // this server has all the accounts it takes (MAX_ACCOUNTS)
  | 'quota' // the account is full
  | 'network'
  | 'notFound' // the server does not have what was asked, such as a model for recommendations
  | 'server';

export class SyncException extends Error {
  constructor(readonly problem: SyncProblem) {
    super(`SyncException(${problem})`);
  }
}

/** An item as the server keeps it: an opaque id and, unless deleted, an encrypted payload. */
export interface RemoteItem {
  id: string;
  payload: string | null;
}

/** A device signed in to the account. */
export interface Device {
  id: string;
  name: string;
  seen: Date;
  current: boolean;
}

/** Where an account stands: its latest revision, and its epoch (which account under that email). */
export interface Revision {
  rev: number;
  epoch: number;
}

const TIMEOUT = 20000;

/** The live socket's subprotocol, which the server picks; the token goes next to it. */
const LIVE_PROTOCOL = 'capy-sync';

type Json = Record<string, unknown>;

export class SyncClient {
  constructor(readonly server: string, public token: string | null = null) {}

  /**
   * The server address the user typed, or null if it is not usable. Plain http only for the
   * local network, where there is no certificate to get; anything else must be https.
   */
  static parseServer(text: string): string | null {
    let t = text.trim();
    if (!t) return null;
    if (t.indexOf('://') < 0) t = 'https://' + t;
    let u: URL;
    try {
      u = new URL(t);
    } catch {
      return null;
    }
    if (!u.hostname || (u.protocol !== 'https:' && u.protocol !== 'http:')) return null;
    if (u.protocol === 'http:' && !isLocal(u.hostname)) return null;
    const path = u.pathname.slice(-1) === '/' ? u.pathname : u.pathname + '/';
    return `${u.protocol}//${u.host}${path}`;
  }

  /** Creates an account and signs in; see SyncService.createAccount for what each key is. */
  async signUp(
    email: string,
    authKey: Uint8Array,
    device: string,
    k: { passwordKeys: string; recoveryKey: Uint8Array; recoveryKeys: string; invite?: string },
  ): Promise<Revision> {
    const body: Json = {
      email,
      authKey: toBase64(authKey),
      recoveryKey: toBase64(k.recoveryKey),
      passwordKeys: k.passwordKeys,
      recoveryKeys: k.recoveryKeys,
      device,
    };
    if (k.invite) body.invite = k.invite;
    const j = await this.call('POST', 'v1/accounts', body);
    if (!isSession(j)) throw new SyncException('server'); // a 200 that is no account
    this.token = j.token as string;
    return { rev: j.rev as number, epoch: j.epoch as number };
  }

  /**
   * Signs in with the auth key of the password or, with [recovery], of the recovery key. Returns
   * where the account stands and its keys, wrapped with that same secret.
   */
  async signIn(email: string, authKey: Uint8Array, device: string, recovery = false): Promise<{ at: Revision; keys: string }> {
    const body: Json = { email, device };
    body[recovery ? 'recoveryKey' : 'authKey'] = toBase64(authKey);
    const j = await this.call('POST', 'v1/sessions', body);
    if (!isSession(j)) throw new SyncException('server'); // a 200 that is no session
    this.token = j.token as string;
    return { at: { rev: j.rev as number, epoch: j.epoch as number }, keys: (j.keys as string) || '' };
  }

  /**
   * Sets a new password: [authKey] proves it, [passwordKeys] are the account's keys wrapped with
   * it. [proof] is the auth key of the current password or of the recovery key. Every other
   * device of the account is signed out.
   */
  async setPassword(proof: Uint8Array, authKey: Uint8Array, passwordKeys: string): Promise<void> {
    await this.call('PUT', 'v1/account/password', { proof: toBase64(proof), authKey: toBase64(authKey), passwordKeys });
  }

  /** Replaces the recovery key, with the same [proof] as [setPassword]. The one before stops working. */
  async setRecoveryKey(proof: Uint8Array, recoveryKey: Uint8Array, recoveryKeys: string): Promise<void> {
    await this.call('PUT', 'v1/account/recovery', { proof: toBase64(proof), recoveryKey: toBase64(recoveryKey), recoveryKeys });
  }

  async signOut(): Promise<void> {
    await this.call('DELETE', 'v1/sessions/current');
  }

  /** Deletes the account: [proof] is the auth key of the password, as a session alone must not do it. */
  async deleteAccount(proof: Uint8Array): Promise<void> {
    await this.call('DELETE', 'v1/account', { proof: toBase64(proof) });
  }

  async devices(): Promise<Device[]> {
    const j = await this.call('GET', 'v1/devices');
    return (j.devices as Json[]).map((d) => ({
      id: d.id as string,
      name: d.device as string,
      seen: new Date(d.seen as string),
      current: d.current === true,
    }));
  }

  /** Signs another device of the account out: it keeps what it has, but gets nothing new. */
  async signOutDevice(id: string): Promise<void> {
    await this.call('DELETE', `v1/devices/${encodeURIComponent(id)}`);
  }

  /** What changed after revision [since], and where the account stands now. */
  async items(since: number): Promise<{ at: Revision; items: RemoteItem[] }> {
    const j = await this.call('GET', `v1/items?since=${since}`);
    return {
      at: { rev: j.rev as number, epoch: j.epoch as number },
      items: (j.items as Json[]).map((i) => ({ id: i.id as string, payload: i.deleted === true ? null : (i.payload as string) })),
    };
  }

  /**
   * Stores [items] as one new revision of the account, and returns it. With [base], only if the
   * account is still at that revision; otherwise throws 'stale'.
   */
  async put(items: RemoteItem[], base?: number): Promise<number> {
    const body: Json = {
      items: items.map((i) => (i.payload === null ? { id: i.id, deleted: true } : { id: i.id, payload: i.payload })),
    };
    if (base !== undefined) body.base = base;
    const j = await this.call('PUT', 'v1/items', body);
    return j.rev as number;
  }

  /** The language model the server offers for recommendations, or null when it offers none. */
  async aiModel(): Promise<string | null> {
    try {
      return ((await this.call('GET', 'v1/ai')).model as string) || null;
    } catch (e) {
      if (e instanceof SyncException && e.problem === 'notFound') return null;
      throw e;
    }
  }

  /** The server's model's answer to [messages]; a JSON one when [json]. */
  async aiChat(messages: { role: string; content: string }[], json = false): Promise<string> {
    const j = await this.call('POST', 'v1/ai/chat', { messages, json }, 120000); // large models take their time
    return (j.content as string) || '';
  }

  /**
   * A socket that says when another device changed something: {"type": "changed", "rev": n},
   * and {"type": "hello", "rev": n} first. The token travels as the subprotocol "bearer.<token>",
   * in a header like the Flutter app's, so it stays out of addresses and their logs.
   */
  live(): WebSocket {
    const url = new URL('v1/live', this.server).toString().replace(/^http/, 'ws');
    return new WebSocket(url, [LIVE_PROTOCOL, `bearer.${this.token}`]);
  }

  private async call(method: string, path: string, body?: unknown, timeoutMs = TIMEOUT): Promise<Json> {
    const headers: Record<string, string> = {};
    if (this.token) headers.authorization = `Bearer ${this.token}`;
    if (body !== undefined) headers['content-type'] = 'application/json';
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), timeoutMs);
    let res: Response;
    let text: string;
    try {
      res = await fetch(new URL(path, this.server).toString(), {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: abort.signal,
      });
      text = await res.text();
    } catch {
      throw new SyncException('network');
    } finally {
      clearTimeout(timer);
    }
    if (res.status >= 200 && res.status < 300) {
      if (!text) return {};
      try {
        return JSON.parse(text) as Json;
      } catch {
        throw new SyncException('server');
      }
    }
    throw new SyncException(problemOf(res.status, text, method === 'POST' && path.indexOf('v1/sessions') === 0));
  }
}

/** Whether [j] is what signing in or up answers: a token, and where the account stands. */
function isSession(j: Json): boolean {
  return typeof j.token === 'string' && typeof j.rev === 'number' && typeof j.epoch === 'number';
}

function problemOf(status: number, body: string, signingIn: boolean): SyncProblem {
  const says = (code: string) => body.indexOf(`"${code}"`) >= 0;
  switch (status) {
    case 401: return signingIn ? 'credentials' : 'signedOut';
    case 409: return says('stale') ? 'stale' : 'exists';
    case 403: return says('invite') ? 'invite' : says('full') ? 'full' : says('credentials') ? 'credentials' : 'server'; // credentials: the current password
    case 413: return says('quota') ? 'quota' : 'server';
    case 429: return 'rateLimited';
    case 404: return 'notFound';
    default: return 'server';
  }
}

/** localhost, *.local, loopback, link-local and private IPv4 addresses, Tailscale's included. */
export function isLocal(host: string): boolean {
  if (host === 'localhost' || /\.local$/.test(host) || /\.ts\.net$/.test(host)) return true;
  const v6 = host.replace(/^\[|\]$/g, '').toLowerCase();
  if (v6 === '::1' || /^fe[89ab][0-9a-f]:/.test(v6)) return true;
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return false;
  const b = m.slice(1).map(Number);
  if (b.some((x) => x > 255)) return false;
  return (
    b[0] === 127 ||
    (b[0] === 169 && b[1] === 254) ||
    b[0] === 10 ||
    (b[0] === 172 && b[1] >= 16 && b[1] < 32) ||
    (b[0] === 192 && b[1] === 168) ||
    (b[0] === 100 && b[1] >= 64 && b[1] < 128) // Tailscale
  );
}
