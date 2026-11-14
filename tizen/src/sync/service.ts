// Keeps playlists, profiles, favorites and watch history the same on every device of an account
// (app/lib/sync/sync_service.dart): the same items, keys, envelopes and merge rules, so the TV and
// the Flutter app share one account.
//
// Everything is encrypted here before it goes to the server (see SyncKeys). Each playlist is one
// item, named after the playlist's sync id: its id on the device that added it, which the other
// devices take on. So is each library (a playlist's favorites and history for one profile), and
// the profiles with the parental PIN. Changes go out a moment after they happen (progress noted
// during playback, a while later). Playlists go by "latest change wins"; libraries merge (see
// Library). Writes are based on the last revision fetched, so a device that missed another's
// change fetches it before writing.
//
// Joining an account (the first sync of this device with it) goes the other way round: what the
// account has comes first, a provider account that is both here and there becomes one playlist,
// and playlists only here are added to the account.
//
// Where the Flutter app keeps the account (token and keys) in the system's secure storage, a web
// app has no keystore: it lives in the app's own localStorage, which no other app can read.
import { Library, mainProfileId, MediaRef } from '../data/library';
import { newId, Playlist, playlistExtra, playlistToJson, PlaylistType, playlistStore, sameAccount } from '../data/playlists';
import { profileStore } from '../data/profiles';
import { log } from '../log';
import { deviceName } from '../platform/tv';
import { session } from '../session';
import { Notifier } from '../ui/components';
import { Device, RemoteItem, Revision, SyncClient, SyncException, SyncProblem } from './client';
import { CAST_FOR, castRequest } from './cast';
import { RecoveryKey, SignInKeys, SyncKeys } from './crypto';

export type SyncStatus =
  | 'off' // no account on this device
  | 'syncing'
  | 'synced'
  | 'offline' // the server could not be reached; it retries on its own
  | 'expired'; // the session ended (signed out elsewhere, account deleted): sign in again

const ACCOUNT_KEY = 'sync.account';
const STATE_KEY = 'sync.state';

/** Version of the items' contents; items of other versions are left alone. */
const VERSION = 2;
const PROFILES_KEY = 'profiles';
/** Version of "send to" requests: not VERSION, so devices that do not know them skip them. */
const CAST_VERSION = 'cast-1';

type Json = Record<string, unknown>;

class SyncService extends Notifier {
  /** Lighter key derivation, for tests only. */
  kdf = { memoryKiB: 65536, passes: 3 };
  /** How long local changes wait for more before going out (ms). */
  delay = 2000;
  /** How long quiet changes (progress during playback) may wait. */
  quietDelay = 2 * 60 * 1000;
  /** How often to ask for other devices' changes while there is no live socket (see client.ts). */
  pollEvery = 60 * 1000;
  /**
   * How often to ask all the same while the socket is open: a browser cannot ping it as Flutter
   * does every 30 s, so one that died without a word (the network gone a moment) says nothing.
   */
  checkEvery = 5 * 60 * 1000;

  private _status: SyncStatus = 'off';
  private _server: string | null = null;
  private _email: string | null = null;
  private _problem: SyncProblem | null = null;
  private _lastSync: Date | null = null;
  private keys: SyncKeys | null = null;
  private client: SyncClient | null = null;
  private state = new SyncState();

  /** The language model the account's server offers for recommendations; null for none. */
  aiModel: string | null = null;

  /** How far the password's key derivation is (0 to 1) while it runs; null otherwise. */
  deriving: number | null = null;

  get status(): SyncStatus {
    return this._status;
  }

  /** Why the last sync failed, while status is offline; null for no answer at all. */
  get problem(): SyncProblem | null {
    return this._problem;
  }

  get server(): string | null {
    return this._server;
  }

  get email(): string | null {
    return this._email;
  }

  get lastSync(): Date | null {
    return this._lastSync;
  }

  /** Whether changes made here wait to go out: what leaving the app sends first. */
  get pending(): boolean {
    return !!(this.debounce || this.lazy);
  }

  /** Picks up the account this TV was signed in to, if any. Call once at startup. */
  start(): void {
    let j: Json;
    let keys: SyncKeys | null = null;
    try {
      const raw = localStorage.getItem(ACCOUNT_KEY);
      if (!raw) return;
      j = JSON.parse(raw);
      if (j.token) keys = SyncKeys.fromJson(j.keys as { enc: string; ids: string });
    } catch (e) {
      // Damaged: start without sync rather than not at all; signing in again fixes it
      log(`sync: the account could not be read: ${e}`);
      return;
    }
    this._server = j.server as string;
    this._email = j.email as string;
    const token = j.token as string | undefined;
    // What this TV knows of the account, also while signed out: signing in again keeps it, and with
    // it what was deleted elsewhere meanwhile, which an empty one would send back
    this.state = SyncState.fromJson(localStorage.getItem(STATE_KEY));
    if (!token || !keys) {
      this.setStatus('expired');
      return;
    }
    this.keys = keys;
    this.client = new SyncClient(this._server, token);
    this.begin();
  }

  /** Signs in to the account [email] on [server]. What is on this TV is kept and merged. */
  async signIn(server: string, email: string, password: string): Promise<void> {
    const mail = SignInKeys.normalizeEmail(email);
    const secret = await this.password(mail, password);
    await this.session(server, mail, async (client) => {
      const r = await client.signIn(mail, secret.authKey, deviceName());
      return { at: r.at, keys: unwrap(secret, r.keys) };
    });
  }

  /**
   * Creates the account [email] on [server] and signs in. Returns the account's recovery key, for
   * the user to keep: the only way in if the password is forgotten.
   */
  async createAccount(server: string, email: string, password: string, invite = ''): Promise<RecoveryKey> {
    const mail = SignInKeys.normalizeEmail(email);
    const secret = await this.password(mail, password);
    const keys = SyncKeys.random();
    const recoveryKey = RecoveryKey.random();
    const recovery = SignInKeys.recovery(recoveryKey);
    await this.session(server, mail, async (client) => {
      const at = await client.signUp(mail, secret.authKey, deviceName(), {
        passwordKeys: keys.wrap(secret.wrapKey),
        recoveryKey: recovery.authKey,
        recoveryKeys: keys.wrap(recovery.wrapKey),
        invite: invite.trim(),
      });
      return { at, keys };
    });
    return recoveryKey;
  }

  /**
   * Sets a new [password] for a forgotten one with the [recoveryKey], and signs in. Every other
   * device of the account is signed out, until it signs in with the new password.
   */
  async recover(server: string, email: string, recoveryKey: RecoveryKey, password: string): Promise<void> {
    const mail = SignInKeys.normalizeEmail(email);
    const recovery = SignInKeys.recovery(recoveryKey);
    const secret = await this.password(mail, password);
    await this.session(server, mail, async (client) => {
      const r = await client.signIn(mail, recovery.authKey, deviceName(), true);
      const keys = unwrap(recovery, r.keys);
      await client.setPassword(recovery.authKey, secret.authKey, keys.wrap(secret.wrapKey));
      return { at: r.at, keys };
    });
  }

  /** Throws a SyncException unless [password] is the account's. By signing in apart and out again: the ways of changing something with it would sign the other devices out. */
  async verifyPassword(password: string): Promise<void> {
    const secret = await this.password(this._email!, password);
    const client = new SyncClient(this._server!);
    await client.signIn(this._email!, secret.authKey, deviceName());
    await client.signOut();
  }

  /** Changes the password of the account. Every other device is signed out until it signs in again. */
  async changePassword(current: string, password: string): Promise<void> {
    const proof = await this.password(this._email!, current, 0, 2);
    const secret = await this.password(this._email!, password, 1, 2);
    await this.client!.setPassword(proof.authKey, secret.authKey, this.keys!.wrap(secret.wrapKey));
  }

  /** Makes a new recovery key in place of the account's, which stops working. Takes the password. */
  async newRecoveryKey(password: string): Promise<RecoveryKey> {
    const proof = await this.password(this._email!, password);
    const recoveryKey = RecoveryKey.random();
    const recovery = SignInKeys.recovery(recoveryKey);
    await this.client!.setRecoveryKey(proof.authKey, recovery.authKey, this.keys!.wrap(recovery.wrapKey));
    return recoveryKey;
  }

  /** Stretches a password, noting how far it is in [deriving]: step [step] of [steps]. */
  private async password(email: string, password: string, step = 0, steps = 1): Promise<SignInKeys> {
    this.setDeriving(step / steps);
    try {
      return await SignInKeys.password(email, password, {
        memoryKiB: this.kdf.memoryKiB,
        passes: this.kdf.passes,
        onProgress: (p) => this.setDeriving((step + p) / steps),
      });
    } finally {
      this.setDeriving(null);
    }
  }

  /** Notes the progress, telling listeners only when it moved by a percent. */
  private setDeriving(p: number | null): void {
    const before = this.deriving === null ? -1 : Math.floor(this.deriving * 100);
    this.deriving = p;
    if (p === null || Math.floor(p * 100) !== before) this.notify();
  }

  /** Runs [open] with a new client to sign in to [server] as [mail], and switches to that account. */
  private async session(server: string, mail: string, open: (c: SyncClient) => Promise<{ at: Revision; keys: SyncKeys }>): Promise<void> {
    const client = new SyncClient(server);
    let opened: { at: Revision; keys: SyncKeys };
    try {
      opened = await open(client);
    } catch (e) {
      // Signed in, then something failed: no session left behind
      if (client.token) await client.signOut().catch(() => {});
      throw e;
    }
    // Signing in again after the session ended keeps what this TV knows of the account
    if (server !== this._server || mail !== this._email) this.state = new SyncState();
    this.check(opened.at);
    this.stop();
    this._server = server;
    this._email = mail;
    this.keys = opened.keys;
    this.client = client;
    this.setStatus('syncing'); // no longer expired, if it was
    this.saveAccount();
    this.saveState();
    await this.begin();
  }

  /** Leaves the account on this TV. Playlists, favorites and history stay here. */
  async signOut(): Promise<void> {
    try {
      if (this.client) await this.client.signOut();
    } catch {
      // Gone already, or offline: the session is forgotten here either way
    }
    this.forget();
  }

  /** Deletes the account and everything synced from the server. Devices keep their own copy. */
  async deleteAccount(password: string): Promise<void> {
    await this.verifyPassword(password); // a server older than the proof below would take any
    const proof = await this.password(this._email!, password);
    await this.client!.deleteAccount(proof.authKey);
    this.forget();
  }

  devices(): Promise<Device[]> {
    return this.client!.devices();
  }

  signOutDevice(id: string): Promise<void> {
    return this.client!.signOutDevice(id);
  }

  /** The answer of the server's model to [messages] (see aiModel). Throws a SyncException. */
  aiChat(messages: { role: string; content: string }[], json = false): Promise<string> {
    if (!this.client) return Promise.reject(new SyncException('signedOut'));
    return this.client.aiChat(messages, json);
  }

  private forget(): void {
    this.stop();
    this.aiModel = null;
    this._server = this._email = null;
    this.keys = null;
    this._lastSync = null;
    this.state = new SyncState();
    localStorage.removeItem(ACCOUNT_KEY);
    localStorage.removeItem(STATE_KEY);
    this.setStatus('off');
  }

  private saveAccount(): void {
    const j: Json = { server: this._server, email: this._email };
    if (this.client && this.client.token) j.token = this.client.token;
    if (this.keys) j.keys = this.keys.toJson();
    localStorage.setItem(ACCOUNT_KEY, JSON.stringify(j));
  }

  private saveState(): void {
    try {
      localStorage.setItem(STATE_KEY, JSON.stringify(this.state.toJson()));
    } catch {
      // Storage full: kept in memory; the next sync after a restart joins again
    }
  }

  /**
   * Makes sure what this TV knows still matches the account on the server. Returns whether it had
   * to start over, so everything must be fetched again.
   */
  private check(at: Revision): boolean {
    if (this.state.epoch !== 0 && at.epoch !== this.state.epoch) {
      // Another account under this email (deleted and created again): join it afresh
      this.state = new SyncState();
      this.state.epoch = at.epoch;
      return true;
    }
    this.state.epoch = at.epoch;
    if (at.rev < this.state.rev) {
      // The server lost changes (restored from a backup): everything goes to it again
      this.state.rebase();
      return true;
    }
    return false;
  }

  // Running

  private unlisten: (() => void)[] = [];
  private debounce = 0;
  private lazy = 0;
  private poller = 0;
  private socket: WebSocket | null = null;
  private socketFailures = 0;
  private reconnect = 0;
  /** Whether [liveServer] takes the live socket from a browser (see SyncClient.live); null until known. */
  private liveTaken: boolean | null = null;
  private liveServer = '';
  private checked = 0; // when the poll last asked while the socket was open
  private applying = false; // changes made by sync itself are not local changes

  /** Starts listening for changes here and elsewhere; completes after the first sync. */
  private begin(): Promise<void> {
    this.askForAi();
    const changed = () => this.changed();
    this.unlisten.push(playlistStore.listen(changed), profileStore.listen(changed));
    const saves = librarySaves();
    if (saves) {
      const saved = (e: LibrarySaved) => (e.quiet ? this.changedQuietly() : this.changed());
      saves.add(saved);
      this.unlisten.push(() => saves.delete(saved));
    }
    // Leaving the app sends what was waiting; coming back fetches what happened meanwhile
    const visibility = () => {
      if (!document.hidden || this.lazy || this.debounce) this.syncNow();
    };
    document.addEventListener('visibilitychange', visibility);
    this.unlisten.push(() => document.removeEventListener('visibilitychange', visibility));
    this.connect();
    this.poll();
    return this.syncNow();
  }

  /**
   * Listens for changes from other devices (app/lib/sync/sync_service.dart, _connect): a change
   * shows here at once, and a password changed elsewhere signs this TV out at once. Drops
   * reconnect with growing pauses, followed by a sync. A server that does not take the socket
   * from a browser is left to the polling.
   */
  private connect(): void {
    const client = this.client;
    if (!client || !client.token || this._status === 'expired') return;
    if (this.liveServer !== client.server) {
      this.liveServer = client.server;
      this.liveTaken = null;
    }
    if (this.liveTaken === false) return;
    let socket: WebSocket;
    try {
      socket = client.live();
    } catch (e) {
      log(`sync: no live socket: ${e}`);
      return;
    }
    let opened = false;
    socket.onopen = () => {
      opened = true;
      // Signed out, or out of date, while it connected
      if (client !== this.client || this._status === 'expired') return socket.close();
      this.liveTaken = true;
      this.socket = socket;
      this.socketFailures = 0;
      this.checked = Date.now();
    };
    socket.onmessage = (m) => {
      if (client !== this.client) return;
      try {
        const rev = (JSON.parse(String(m.data)) as Json).rev;
        if (typeof rev === 'number' && rev !== this.state.rev) this.syncNow();
      } catch {
        // Not a message of the server's
      }
    };
    socket.onclose = () => {
      if (this.socket === socket) this.socket = null;
      if (client !== this.client || this._status === 'expired') return;
      if (opened || this.liveTaken !== null) return this.dropped(client);
      // Refused before it was ever taken. If the server answers everything else, it does not take
      // it this way: the sync under way (the first one, as a rule) tells, rather than more of them
      const decide = () => {
        if (client !== this.client || this._status === 'expired') return;
        if (this._status !== 'synced') return this.dropped(client);
        this.liveTaken = false;
        log('sync: the server takes no live socket from here; asking at intervals');
      };
      if (this.running) this.running.then(decide, decide);
      else decide();
    };
  }

  private dropped(client: SyncClient): void {
    const wait = Math.min(60, 2 << Math.min(this.socketFailures++, 5)) * 1000;
    clearTimeout(this.reconnect);
    this.reconnect = window.setTimeout(() => {
      if (client !== this.client) return;
      this.connect();
      this.syncNow(); // whatever happened while it was down
    }, wait);
  }

  private closeSocket(): void {
    clearTimeout(this.reconnect);
    this.reconnect = 0;
    const socket = this.socket;
    this.socket = null;
    if (socket) socket.close();
  }

  /** Notes whether the server offers a model; an offline server is asked again on the next start. */
  private async askForAi(): Promise<void> {
    const client = this.client;
    if (!client) return;
    try {
      const model = await client.aiModel();
      if (client === this.client) {
        this.aiModel = model;
        this.notify();
      }
    } catch (e) {
      log(`sync: recommendations: ${e}`);
    }
  }

  private stop(): void {
    this.unlisten.forEach((f) => f());
    this.unlisten = [];
    clearTimeout(this.debounce);
    clearTimeout(this.lazy);
    clearTimeout(this.poller);
    this.debounce = this.lazy = this.poller = 0;
    this.client = null; // before the socket closes, so it does not reconnect
    this.me = null;
    this.closeSocket();
  }

  private changed(): void {
    if (this.applying || !this.client) return;
    clearTimeout(this.debounce);
    this.debounce = window.setTimeout(() => this.syncNow(), this.delay);
  }

  /** Unlike changed(), more of these do not push it back: it goes quietDelay after the first. */
  private changedQuietly(): void {
    if (this.applying || !this.client) return;
    if (!this.lazy) this.lazy = window.setTimeout(() => this.syncNow(), this.quietDelay);
  }

  /**
   * What the live socket does, for a server that does not take it from a browser or while it is
   * down: while the TV shows the app, asks now and then whether the account moved on, and
   * fetches it when it did.
   */
  private poll(): void {
    const client = this.client;
    clearTimeout(this.poller);
    this.poller = window.setTimeout(() => {
      this.pollOnce(client).then(() => {
        if (client && client === this.client && this._status !== 'expired') this.poll();
      });
    }, this.pollEvery);
  }

  private async pollOnce(client: SyncClient | null): Promise<void> {
    if (!client || client !== this.client || this._status === 'expired' || document.hidden) return;
    // Offline: try again. Without Library.saved, this is also how library changes go out
    if (this._status === 'offline' || !librarySaves()) return this.syncNow();
    // The socket tells of changes itself; now and then it is checked all the same (checkEvery)
    if (this.socket && Date.now() - this.checked < this.checkEvery) return;
    this.checked = Date.now();
    try {
      const { at } = await client.items(this.state.rev);
      if (client === this.client && at.rev !== this.state.rev) await this.syncNow();
    } catch {
      if (client === this.client) await this.syncNow(); // which says what went wrong
    }
  }

  private running: Promise<void> | null = null;
  private again = false;

  /**
   * Sends what changed here and fetches what changed elsewhere. Calls while one is running make
   * it go once more when done.
   */
  syncNow(): Promise<void> {
    if (!this.client || this._status === 'expired') return Promise.resolve();
    if (this.running) {
      this.again = true;
      return this.running;
    }
    const run = this.loop();
    this.running = run;
    const done = () => {
      if (this.running === run) this.running = null;
    };
    run.then(done, done);
    return run;
  }

  private async loop(): Promise<void> {
    for (let round = 0; round < 5; round++) {
      this.again = false;
      await this.syncOnce();
      if (!this.again || !this.client || this._status === 'expired') return;
    }
    this.changed(); // still more to do: a little later
  }

  private async syncOnce(): Promise<void> {
    const client = this.client!;
    const keys = this.keys!;
    clearTimeout(this.debounce);
    clearTimeout(this.lazy);
    this.debounce = this.lazy = 0;
    this.setStatus('syncing');
    try {
      const joining = !this.state.joined;
      // Changes here are noted before fetching, so they are not taken for older ones; when
      // joining, what the account has comes first
      if (!joining) this.scan(keys);
      await this.pull(client, keys);
      if (joining) this.scan(keys);
      await this.push(client, keys);
      if (client !== this.client) return; // signed out meanwhile
      this._lastSync = new Date();
      this.setStatus('synced');
    } catch (e) {
      if (client !== this.client) return;
      if (!(e instanceof SyncException)) {
        // Not the server's doing (storage, a bug): note it, and let the next change try again
        log(`sync failed: ${e instanceof Error ? e.stack || e.message : e}`);
        this.setStatus('offline');
      } else if (e.problem === 'stale') {
        this.again = true; // another device wrote first: fetch that, then try again
      } else if (e.problem === 'signedOut') {
        client.token = null;
        this.saveAccount();
        clearTimeout(this.poller);
        this.closeSocket();
        this.setStatus('expired');
      } else {
        this._problem = e.problem === 'network' ? null : e.problem;
        this.setStatus('offline');
      }
    }
  }

  // Playlists: one item each, the latest change wins

  private syncId(p: Playlist): string {
    return has(this.state.ids, p.id) ? this.state.ids[p.id] : p.id;
  }

  /** [p] as the account knows it: a combined playlist names its playlists by their sync ids. */
  private outgoing(p: Playlist): Playlist {
    return p.members.length ? { ...p, members: p.members.map((m) => (has(this.state.ids, m) ? this.state.ids[m] : m)) } : p;
  }

  /** [p] from the account as this TV knows it: the reverse of outgoing(). */
  private incoming(p: Playlist, here: Playlist[]): Playlist {
    if (!p.members.length) return p;
    return { ...p, members: p.members.map((m) => (here.filter((x) => this.syncId(x) === m)[0] || { id: m }).id) };
  }

  /** Notes what changed in the playlists since the last look. */
  private scan(keys: SyncKeys): void {
    const now = Date.now();
    const playlists = playlistStore.playlists;
    const here: Record<string, true> = {};
    for (const p of playlists) {
      const id = this.syncId(p);
      here[id] = true;
      const fp = keys.fingerprint(content(this.outgoing(p)));
      const known = this.state.playlists[id];
      if (!known || known.deleted || known.fp !== fp) {
        this.state.playlists[id] = { at: Math.max(now, (known ? known.at : 0) + 1), fp, dirty: true };
      }
    }
    for (const id of Object.keys(this.state.playlists)) {
      const known = this.state.playlists[id];
      if (!known.deleted && !here[id]) this.state.playlists[id] = { at: Math.max(now, known.at + 1), deleted: true, dirty: true };
    }
    for (const local of Object.keys(this.state.ids)) {
      if (!playlists.some((p) => p.id === local)) delete this.state.ids[local];
    }
  }

  private async pull(client: SyncClient, keys: SyncKeys): Promise<void> {
    let changes = await client.items(this.state.rev);
    if (this.check(changes.at)) {
      changes = await client.items(0);
      this.again = true; // and look at what is here again, against the new start
    }
    const playlists: Json[] = [];
    const libraries: Json[] = [];
    const casts: Json[] = [];
    let profiles: Json | null = null;
    for (const item of changes.items) {
      if (item.payload === null) continue;
      try {
        const envelope = keys.open(item.id, item.payload) as Json;
        const key = envelope.key;
        if (typeof key !== 'string' || keys.itemId(key) !== item.id) continue;
        if (envelope.v === CAST_VERSION) casts.push(envelope);
        if (envelope.v !== VERSION) continue;
        if (key === PROFILES_KEY) profiles = envelope.data as Json;
        else (key.indexOf('playlist/') === 0 ? playlists : libraries).push(envelope);
      } catch (e) {
        log(`sync: skipped an item that does not open: ${e}`);
      }
    }
    // Playlists that are here under their own id first, so those found by provider account
    // (when joining) cannot take their place
    const here: Record<string, true> = {};
    for (const p of playlistStore.playlists) here[this.syncId(p)] = true;
    const id = (e: Json) => (e.key as string).slice((e.key as string).indexOf('/') + 1);
    const ordered = playlists.filter((e) => here[id(e)]).concat(playlists.filter((e) => !here[id(e)]));
    this.applying = true;
    try {
      // Profiles first: libraries belong to them
      // Each on its own: one this TV cannot take (a newer version's, or damaged) is left, and the
      // rest still come, and what is here still goes. Otherwise it would stop the sync for good
      const each = (what: string, apply: () => void) => {
        try {
          apply();
        } catch (x) {
          log(`sync: skipped ${what} it cannot take: ${x}`);
        }
      };
      if (profiles) {
        const p = profiles;
        each('profiles', () => {
          profileStore.merge(p);
          this.state.profiles = keys.fingerprint(JSON.stringify(p)); // what the server has
        });
      }
      for (const e of ordered) each('a playlist', () => this.applyPlaylist(keys, id(e), e));
      for (const e of libraries) each('a library', () => this.applyLibrary(keys, id(e), e.data as Json));
    } finally {
      this.applying = false;
    }
    this.state.rev = changes.at.rev;
    this.state.joined = true;
    this.saveState();
    // After the playlists: the one a request is in may have just come
    for (const e of casts) {
      try {
        await this.applyCast(e);
      } catch (x) {
        log(`sync: skipped a request it cannot take: ${x}`);
      }
    }
  }

  private me: Device | null = null; // this TV, as the account knows it
  private castAt = 0; // the last request played here, so none plays twice

  /** A request found in the account: played here if it is for this TV, and new. */
  private async applyCast(e: Json): Promise<void> {
    const at = e.at as number;
    const data = e.data as Json;
    if (at <= this.castAt || Date.now() - at > CAST_FOR) return;
    if (!this.me) this.me = (await this.client!.devices()).filter((d) => d.current)[0] || null;
    if (!this.me || e.key !== `cast/${this.me.id}`) return;
    const playlist = playlistStore.playlists.filter((p) => this.syncId(p) === data.playlist)[0];
    if (!playlist) return;
    this.castAt = at;
    castRequest.put({ playlistId: playlist.id, ref: data.ref as MediaRef, position: (data.position as number) || 0, from: String(data.from), at });
  }

  private applyPlaylist(keys: SyncKeys, id: string, e: Json): void {
    const at = e.at as number;
    const known = this.state.playlists[id];
    if (known && known.at >= at) return; // what is here is as new or newer
    const list = playlistStore.playlists;
    let local = list.filter((p) => this.syncId(p) === id)[0];
    if (e.deleted === true) {
      this.state.playlists[id] = { at, deleted: true };
      // When joining, what is here stays, and goes back to the account
      if (local && this.state.joined) playlistStore.remove(local);
      return;
    }
    const remote = playlistFromJson(e.data as Json);
    this.state.playlists[id] = { at, fp: keys.fingerprint(content(remote)) };
    const p = this.incoming(remote, list);
    if (!local && !this.state.joined) {
      // Joining: the same provider account here is the same playlist, from now on under its id
      local = list.filter((x) => sameAccount(x, p) && this.syncId(x) === x.id && !has(this.state.playlists, x.id))[0];
      if (local) this.state.ids[local.id] = id;
    }
    if (!local) {
      // Under the same id as elsewhere, unless a playlist here has it already
      const localId = list.some((x) => x.id === id) ? newId() : id;
      if (localId !== id) this.state.ids[localId] = id;
      playlistStore.add({ ...p, id: localId });
    } else if (content(this.outgoing(local)) !== content(remote)) {
      playlistStore.update({ ...p, id: local.id }); // the local id keeps its library
    }
  }

  /** [id] is a playlist's sync id, followed by @profile for any profile but the main one. */
  private applyLibrary(keys: SyncKeys, id: string, remote: Json): void {
    const [playlist, profile] = libraryOf(id);
    const local = playlistStore.playlists.filter((p) => this.syncId(p) === playlist)[0];
    if (!local) return; // the playlist was removed here
    if (!profileStore.profiles.some((p) => p.id === profile)) return; // so was the profile
    this.state.libraries[id] = keys.fingerprint(JSON.stringify(remote)); // what the server has
    openLibrary(local.id, profile).merge(remote); // anything only here goes out in the push
  }

  private async push(client: SyncClient, keys: SyncKeys): Promise<void> {
    const items: RemoteItem[] = [];
    const done: (() => void)[] = [];
    const playlists = playlistStore.playlists;
    for (const id of Object.keys(this.state.playlists)) {
      const known = this.state.playlists[id];
      if (!known.dirty) continue;
      const p = known.deleted ? undefined : playlists.filter((x) => this.syncId(x) === id)[0];
      if (!known.deleted && !p) continue;
      const key = `playlist/${id}`;
      const itemId = keys.itemId(key);
      const envelope: Json = { v: VERSION, key, at: known.at };
      if (!p) envelope.deleted = true;
      else envelope.data = playlistJson({ ...this.outgoing(p), id });
      items.push({ id: itemId, payload: keys.seal(itemId, envelope) });
      done.push(() => {
        this.state.playlists[id] = sent(known);
      });
    }
    // Libraries of playlists or profiles that are gone go with them
    const profiles = profileStore.profiles;
    for (const id of Object.keys(this.state.libraries)) {
      const [playlist, profile] = libraryOf(id);
      const gone = this.state.playlists[playlist];
      if (!(gone && gone.deleted) && profiles.some((p) => p.id === profile)) continue;
      items.push({ id: keys.itemId(`library/${id}`), payload: null });
      done.push(() => {
        delete this.state.libraries[id];
      });
    }
    for (const p of playlists) {
      for (const profile of profiles) {
        const id = libraryId(this.syncId(p), profile.id);
        const library = openLibrary(p.id, profile.id).toJson();
        const empty = !(library.favorites as unknown[]).length && !(library.history as unknown[]).length;
        if (empty && library.cleared === 0 && !has(this.state.libraries, id)) continue; // nothing to share yet
        const fp = keys.fingerprint(JSON.stringify(library));
        if (fp === this.state.libraries[id]) continue;
        const key = `library/${id}`;
        const itemId = keys.itemId(key);
        items.push({ id: itemId, payload: keys.seal(itemId, { v: VERSION, key, data: library }) });
        done.push(() => {
          this.state.libraries[id] = fp;
        });
      }
    }
    // The profiles and the PIN, once there is anything to share: more than the untouched main one
    const mine = profileStore.toJson();
    const fp = keys.fingerprint(JSON.stringify(mine));
    const untouched = profiles.length === 1 && profiles[0].at === 0 && mine.pin == null;
    if (fp !== this.state.profiles && !(untouched && this.state.profiles === null)) {
      const itemId = keys.itemId(PROFILES_KEY);
      items.push({ id: itemId, payload: keys.seal(itemId, { v: VERSION, key: PROFILES_KEY, data: mine }) });
      done.push(() => {
        this.state.profiles = fp;
      });
    }
    if (!items.length) return;
    // Only on top of what was fetched: if another device wrote since, this fails as stale
    const rev = await client.put(items, this.state.rev);
    done.forEach((f) => f());
    this.state.rev = rev;
    this.saveState();
  }

  private setStatus(s: SyncStatus): void {
    if (s !== 'offline') this._problem = null;
    this._status = s;
    this.notify();
  }
}

function unwrap(secret: SignInKeys, wrapped: string): SyncKeys {
  try {
    return SyncKeys.unwrap(secret.wrapKey, wrapped);
  } catch {
    throw new SyncException('server'); // what the server keeps is damaged
  }
}

const has = (o: object, k: string) => Object.prototype.hasOwnProperty.call(o, k);

// Playlists as the Flutter app encodes them

/** Playlist.toJson(), what this TV does not read included. */
function playlistJson(p: Playlist): Json {
  return playlistToJson(p) as Json;
}

const TYPES: PlaylistType[] = ['xtream', 'm3u', 'combined'];

/** Playlist.fromJson(): throws on what is not a playlist, as Dart's casts do. */
function playlistFromJson(j: Json): Playlist {
  const type = j.type as PlaylistType;
  if (typeof j.id !== 'string' || typeof j.name !== 'string' || typeof j.url !== 'string' || TYPES.indexOf(type) < 0) {
    throw new Error('not a playlist');
  }
  const members = Array.isArray(j.members) ? (j.members as unknown[]).map(String) : [];
  const p: Playlist = { id: j.id, name: j.name, type, url: j.url, username: (j.username as string) || '', password: (j.password as string) || '', members };
  if (typeof j.userAgent === 'string' && j.userAgent) p.userAgent = j.userAgent;
  const extra = playlistExtra(j as Record<string, unknown>);
  if (extra) p.extra = extra;
  return p;
}

/** What a playlist is, without its id: what tells whether it changed (as before, when it has nothing extra). */
function content(p: Playlist): string {
  const j = playlistToJson(p);
  delete j.id;
  return JSON.stringify(j);
}


// Libraries

interface LibrarySaved {
  playlistId: string;
  profileId: string;
  quiet: boolean;
}

/** Library.saved, where library.ts has it: tells of every save, so changes go out at once. */
function librarySaves(): Set<(e: LibrarySaved) => void> | undefined {
  return Library.saved;
}

/** The library of [playlistId] and [profileId]: the open one if it is that, so it merges live. */
function openLibrary(playlistId: string, profileId: string): Library {
  let open: Library | null = null;
  try {
    open = session().library;
  } catch {
    // No playlist open
  }
  return open && open.playlistId === playlistId && open.profileId === profileId ? open : Library.load(playlistId, profileId);
}

const libraryId = (playlist: string, profile: string) => (profile === mainProfileId ? playlist : `${playlist}@${profile}`);

function libraryOf(id: string): [string, string] {
  const at = id.indexOf('@');
  return at < 0 ? [id, mainProfileId] : [id.slice(0, at), id.slice(at + 1)];
}

// What this TV knows of the account

/** What this TV knows of a playlist's item: when it last changed and a fingerprint of it. */
interface Known {
  at: number;
  fp?: string;
  deleted?: boolean;
  dirty?: boolean; // changed here, not sent yet
}

function knownJson(k: Known): Known {
  const j: Known = { at: k.at };
  if (k.fp !== undefined && k.fp !== null) j.fp = k.fp;
  if (k.deleted) j.deleted = true;
  if (k.dirty) j.dirty = true;
  return j;
}

const sent = (k: Known): Known => knownJson({ at: k.at, fp: k.fp, deleted: k.deleted });

/** Saved as the Flutter app saves it ("sync.state"), so the shapes stay one. */
class SyncState {
  epoch = 0; // which account, among those that had this email
  rev = 0; // the account's revision this TV has caught up with
  joined = false; // synced with the account at least once
  playlists: Record<string, Known> = {}; // by sync id
  libraries: Record<string, string> = {}; // by sync id[@profile]: fingerprint of what the server has
  profiles: string | null = null; // fingerprint of the profiles the server has
  ids: Record<string, string> = {}; // local playlist id → sync id, where they differ

  static fromJson(raw: string | null): SyncState {
    const s = new SyncState();
    try {
      const j = raw ? JSON.parse(raw) : null;
      if (!j || j.v !== VERSION) return s; // older: join again
      s.epoch = j.epoch;
      s.rev = j.rev;
      s.joined = j.joined === true;
      for (const k of Object.keys(j.playlists)) s.playlists[k] = knownJson(j.playlists[k]);
      s.libraries = { ...j.libraries };
      s.profiles = typeof j.profiles === 'string' ? j.profiles : null;
      s.ids = { ...j.ids };
      return s;
    } catch {
      return new SyncState();
    }
  }

  /** The server lost changes: fetch everything and send everything again. */
  rebase(): void {
    this.rev = 0;
    this.libraries = {};
    this.profiles = null;
    for (const k of Object.keys(this.playlists)) this.playlists[k] = knownJson({ ...this.playlists[k], dirty: true });
  }

  toJson(): Json {
    const playlists: Record<string, Known> = {};
    for (const k of Object.keys(this.playlists)) playlists[k] = knownJson(this.playlists[k]);
    const j: Json = { v: VERSION, epoch: this.epoch, rev: this.rev, joined: this.joined, playlists, libraries: this.libraries };
    if (this.profiles !== null) j.profiles = this.profiles;
    j.ids = this.ids;
    return j;
  }
}

export const syncService = new SyncService();
