// The phone companion for this TV (app/lib/remote/companion_server.dart): scanning the QR the app
// shows opens a page on the user's phone to add playlists with the phone's keyboard, use the phone
// as a remote, sign this TV in to the sync account, move backups and vote on movie night. A
// Samsung web app cannot listen on a port, so the page talks to this TV through the sync server's
// bridge (relay.ts), every message sealed with a key that only the QR carries: the server cannot
// read any of it. It runs only while some screen holds it.
import { backupTooNew, exportBackup, importBackup, isBackup } from '../data/backup';
import { createPlaylist, Playlist, playlistStore, verifyPlaylist } from '../data/playlists';
import { SourceException } from '../data/source';
import { log } from '../log';
import { deviceName, Keys } from '../platform/tv';
import { SyncClient, SyncException } from '../sync/client';
import { syncService } from '../sync/service';
import { t } from '../i18n';
import { problemText } from '../screens/sync';
import { Notifier } from '../ui/components';
import { maybePop, toast } from '../ui/router';
import { MovieNight } from './movie_night';
import { nowPlaying, remoteSearch } from './now';
import { RelayRoom } from './relay';
import { CompanionSeal } from './seal';
import { companionStrings } from './strings';

/** Something a phone did, for the app to tell the user. */
export type CompanionEvent =
  | { kind: 'playlist'; name: string }
  | { kind: 'backup'; added: number; updated: number }
  | { kind: 'remote' }
  | { kind: 'signedIn'; email: string };

interface Call {
  id: string;
  method: string;
  path: string;
  body?: unknown;
}

/**
 * A phone heard from within this long counts as connected. The page says hello when its remote
 * opens; then every key, text and its keepalive count (Flutter counts the remote's open socket).
 */
const REMOTE_FRESH = 2 * 60 * 1000;

/** Pauses between tries while the server cannot make a room: growing, up to a minute. */
const RETRY_FIRST = 5000;
const RETRY_MAX = 60000;

class CompanionHost extends Notifier {
  private holds = 0;
  private room: RelayRoom | null = null;
  private seal = CompanionSeal.random();
  private guestSeal = CompanionSeal.random(); // of whoever only came to vote: see votingLink
  private server = '';
  private stopTimer = 0;
  private retryTimer = 0;
  private retries = 0;
  private starting: Promise<void> | null = null;
  private lastRemote = 0; // when a phone last spoke as a remote
  private lastSeen = 0; // when a phone last sent anything (a call: a backup, signing in)
  private freshTimer = 0;
  private eventListeners = new Set<(e: CompanionEvent) => void>();
  /** Why the bridge could not open (no server set, the server unreachable); null while fine. */
  failure: 'noServer' | 'unreachable' | null = null;
  private currentNight: MovieNight | null = null;

  /** The movie night being voted on, if any. A page open as a remote is told when it begins or ends. */
  get night(): MovieNight | null {
    return this.currentNight;
  }

  set night(n: MovieNight | null) {
    if (n === this.currentNight) return;
    this.currentNight = n;
    if (this.room) this.send({ type: 'night', open: !!n });
  }

  constructor() {
    super();
    nowPlaying.listen(() => this.room && this.send({ type: 'now', nowPlaying: nowPlaying.value }));
  }

  onEvent(l: (e: CompanionEvent) => void): () => void {
    this.eventListeners.add(l);
    return () => this.eventListeners.delete(l);
  }

  private emit(e: CompanionEvent): void {
    this.eventListeners.forEach((l) => l(e));
  }

  /** Phones using this TV as a remote right now. */
  get remotes(): number {
    return Date.now() - this.lastRemote < REMOTE_FRESH ? 1 : 0;
  }

  /** A phone is at it: the bridge stays, as Flutter's server does while a phone is connected. */
  private get inUse(): boolean {
    return !!this.remotes || Date.now() - this.lastSeen < REMOTE_FRESH;
  }

  /** The page as the QR code carries it, opened on [tab]; null until the bridge is open. */
  /** The page for those in the room to vote: a key of its own that opens nothing else, as everyone there scans it. */
  votingLink(): string | null {
    return this.room ? `${this.server}/companion#night&guest&k=${this.guestSeal.text}&r=${this.room.room.room}` : null;
  }

  link(tab: string): string | null {
    return this.room ? `${this.server}/companion#${tab}&k=${this.seal.text}&r=${this.room.room.room}` : null;
  }

  /** Keeps the bridge open while some screen needs it; pair with [release]. */
  hold(server: string): Promise<void> {
    this.holds++;
    clearTimeout(this.stopTimer);
    if (this.room && this.server === server) return Promise.resolve();
    return this.open(server);
  }

  /** Tries again at once, for a screen that holds it: its Retry button, a server set up since. */
  retry(server: string): Promise<void> {
    if (!this.holds || (this.room && this.server === server)) return Promise.resolve();
    this.retries = 0;
    if (this.starting && this.failure) {
      // A try on its own is under way: the button still shows that something happens
      this.failure = null;
      this.notify();
    }
    return this.open(server);
  }

  /** [again]: a try on its own, which leaves the last failure (and its Retry) on screen meanwhile. */
  private open(server: string, again = false): Promise<void> {
    clearTimeout(this.retryTimer);
    if (!this.starting) this.starting = this.start(server, again).then(() => void (this.starting = null));
    return this.starting;
  }

  private async start(server: string, again: boolean): Promise<void> {
    // A new try: the screens wait for it, not for the last one's failure. One on its own keeps it,
    // so the Retry the remote may be on does not go away every few seconds
    if (!again) this.failure = null;
    this.stop();
    if (!server) {
      this.failure = 'noServer';
      return this.notify();
    }
    try {
      this.room = await RelayRoom.create(server);
    } catch (e) {
      log(`companion: ${(e as Error).message}`);
      this.failure = 'unreachable';
      // The server is down a moment, most likely: again on its own while some screen waits
      if (this.holds > 0) {
        const wait = Math.min(RETRY_MAX, RETRY_FIRST * Math.pow(2, this.retries++));
        this.retryTimer = window.setTimeout(() => this.holds > 0 && !this.room && this.open(server, true), wait);
      }
      return this.notify();
    }
    this.retries = 0;
    this.server = server;
    this.seal = CompanionSeal.random(); // a new key every time: an old QR opens nothing
    this.guestSeal = CompanionSeal.random();
    this.failure = null;
    const room = this.room;
    room.listen(
      (body) => this.handle(body),
      () => {
        // The room expired or the server restarted: a new one, a new QR
        if (this.room === room) {
          this.room = null;
          if (this.holds > 0) this.open(server);
          else this.notify();
        }
      },
    );
    // The screen that asked for it left while it opened: its release found nothing to close
    if (!this.holds) this.closeSoon();
    this.notify();
  }

  /** The screen that needed it is gone: close once no phone is using it. */
  release(): void {
    if (this.holds > 0) this.holds--;
    if (this.holds > 0) return;
    clearTimeout(this.retryTimer); // nobody waits for it any more
    this.retries = 0;
    this.closeSoon();
  }

  /** Closes it in a while, unless a phone is using it then or a screen holds it again. */
  private closeSoon(): void {
    clearTimeout(this.stopTimer);
    this.stopTimer = window.setTimeout(() => (this.inUse ? this.closeSoon() : this.stop()), 30000);
  }

  private stop(): void {
    clearTimeout(this.retryTimer);
    if (this.room) this.room.close();
    this.room = null;
    this.notify();
  }

  private send(envelope: unknown, seal = this.seal): void {
    if (!this.room) return;
    this.room.toPhone(seal.seal('relay/phone', envelope)).catch((e) => log(`companion: ${e.message}`));
  }

  private handle(body: string): void {
    let m: Record<string, unknown>;
    let guest = false;
    try {
      m = this.seal.open('relay/tv', body) as Record<string, unknown>;
    } catch {
      try {
        m = this.guestSeal.open('relay/tv', body) as Record<string, unknown>;
        guest = true;
      } catch {
        return; // not sealed with this session's keys: ignored
      }
    }
    // Anything sealed with this session's keys is a phone still there
    this.lastSeen = Date.now();
    if (guest) return this.answerGuest(m);
    switch (m.type) {
      case 'key':
        this.heard();
        return void pressRemoteKey(String(m.key));
      case 'text':
        this.heard();
        return typeRemoteText(String(m.text));
      case 'hello': // the remote opened on the page
      case 'alive': // and is still open there, every half minute
        if (!this.remotes) this.emit({ kind: 'remote' });
        this.heard();
        if (m.type === 'hello') this.send({ type: 'hello', device: deviceName(), nowPlaying: nowPlaying.value });
        return;
      case 'bye': // the page closed
        this.lastRemote = 0;
        clearTimeout(this.freshTimer);
        return this.notify();
    }
    if (typeof m.id === 'string') {
      const call = m as unknown as Call;
      this.answer(call).then(
        ([status, answer]) => this.send({ re: call.id, status, body: answer }),
        (e) => this.send({ re: call.id, status: 500, body: { error: 'server', detail: String(e && e.message) } }),
      );
    }
  }

  /** What someone who only came to vote may ask; no key presses, no text, no backup. */
  private answerGuest(m: Record<string, unknown>): void {
    if (typeof m.id !== 'string') return;
    const call = m as unknown as Call;
    const what = `${call.method} ${call.path}`;
    const reply = (status: number, answer: unknown) => this.send({ re: call.id, status, body: answer }, this.guestSeal);
    if (what === 'GET /api/info') return reply(200, { device: deviceName(), strings: companionStrings(), night: !!this.night });
    if (what !== 'GET /api/night' && what !== 'POST /api/night/vote') return reply(403, { error: 'forbidden' });
    this.answer(call).then(
      ([status, answer]) => reply(status, answer),
      (e) => reply(500, { error: 'server', detail: String(e && e.message) }),
    );
  }

  /** A phone spoke as a remote: connected, until it goes quiet for REMOTE_FRESH. */
  private heard(): void {
    const was = !!this.remotes;
    this.lastRemote = Date.now();
    clearTimeout(this.freshTimer);
    this.freshTimer = window.setTimeout(() => this.notify(), REMOTE_FRESH + 100); // no longer
    if (!was) this.notify();
  }

  /** What the local companion server would answer to [c]. */
  private async answer(c: Call): Promise<[number, unknown]> {
    switch (`${c.method} ${c.path}`) {
      case 'GET /api/info':
        return [200, this.info()];
      case 'POST /api/playlists':
        return this.addPlaylist(c);
      case 'GET /api/backup':
        return [200, { sealed: this.seal.seal('/api/backup', exportBackup()) }];
      case 'POST /api/backup':
        return this.restore(c);
      case 'POST /api/sync':
        return this.signIn(c);
      case 'GET /api/night':
        return [200, this.night ? await this.night.forPhone() : { open: false }];
      case 'POST /api/night/vote': {
        // Nothing private, so not sealed: only those with the QR reach the room
        const j = (c.body || {}) as Record<string, unknown>;
        if (!this.night) return [409, { error: 'closed' }];
        const ok = this.night.vote(String(j.voter || ''), String(j.id || ''), j.yes === true);
        return ok ? [200, { ok: true }] : [400, { error: 'invalid' }];
      }
      default:
        return [404, { error: 'not found' }];
    }
  }

  private info(): Record<string, unknown> {
    return {
      device: deviceName(),
      strings: companionStrings(),
      night: !!this.night,
      playlists: playlistStore.playlists.map((p) => p.name),
      nowPlaying: nowPlaying.value,
      sync: {
        email: syncService.email || undefined,
        server: syncService.server || this.server,
        signedIn: syncService.status !== 'off' && syncService.status !== 'expired',
      },
    };
  }

  /** The sealed body of [c] for its path; null when it is not sealed with this session's key. */
  private opened(c: Call): unknown {
    try {
      return this.seal.open(c.path, String(((c.body || {}) as Record<string, unknown>).sealed));
    } catch {
      return null;
    }
  }

  private async addPlaylist(c: Call): Promise<[number, unknown]> {
    const j = this.opened(c) as Record<string, string> | null;
    if (!j) return [400, { error: 'sealed' }];
    const type = j.type === 'm3u' ? 'm3u' : 'xtream';
    const p = createPlaylist({ type, url: j.url || '', name: j.name || '', username: j.username || '', password: j.password || '' });
    if (!p.url || (p.type === 'xtream' && (!p.username || !p.password))) return [400, { error: 'missing' }];
    try {
      await verifyPlaylist(p);
    } catch (e) {
      // The phone shows the same message the app would
      if (e instanceof SourceException) return [422, { error: e.error, detail: e.detail }];
      throw e;
    }
    const same = playlistStore.playlists.filter((x: Playlist) => x.type === p.type && x.url === p.url && x.username === p.username)[0];
    if (same) playlistStore.update({ ...same, password: p.password });
    else playlistStore.add(p);
    this.emit({ kind: 'playlist', name: p.name });
    return [200, { ok: true, name: p.name }];
  }

  private async restore(c: Call): Promise<[number, unknown]> {
    const data = this.opened(c);
    if (data === null) return [400, { error: 'sealed' }];
    if (!isBackup(data)) return [400, { error: 'format' }];
    if (backupTooNew(data)) return [400, { error: 'newer' }];
    const result = importBackup(data, !!data.settings);
    this.emit({ kind: 'backup', added: result.added, updated: result.updated });
    return [200, { ok: true, ...result }];
  }

  /** Signs this TV in to the sync account typed on the phone. */
  private async signIn(c: Call): Promise<[number, unknown]> {
    const j = this.opened(c) as Record<string, string> | null;
    if (!j) return [400, { error: 'sealed' }];
    const server = SyncClient.parseServer(j.server || '');
    const email = (j.email || '').trim();
    if (!server) return [400, { error: 'sync_address' }];
    if (!email || !j.password) return [400, { error: 'missing' }];
    // The password's key derivation runs on this TV's processor and takes a while: the TV says
    // so too, as its Sync screen does
    toast(t('webSigningIn'));
    try {
      await syncService.signIn(server, email, j.password);
    } catch (e) {
      if (e instanceof SyncException) {
        toast(problemText(e.problem));
        return [422, { error: `sync_${e.problem}` }];
      }
      throw e;
    }
    this.emit({ kind: 'signedIn', email: syncService.email || email });
    return [200, { ok: true, email: syncService.email }];
  }
}

export const companionHost = new CompanionHost();
(window as unknown as { capyCompanion: CompanionHost }).capyCompanion = companionHost; // for scripts/tv.mjs eval

/** Remote buttons, by the names the companion page sends. */
const REMOTE_KEYS: Record<string, number> = {
  up: Keys.up,
  down: Keys.down,
  left: Keys.left,
  right: Keys.right,
  ok: Keys.enter,
  playpause: Keys.playPause,
  chup: Keys.channelUp,
  chdown: Keys.channelDown,
};

/**
 * Presses a remote button, as a key from the real remote arrives. 'back' goes back as Flutter's
 * maybePop: on the first screen it does nothing, rather than close the app (and the bridge).
 */
export function pressRemoteKey(name: string): boolean {
  if (name === 'back') {
    maybePop();
    return true;
  }
  const code = REMOTE_KEYS[name];
  if (code === undefined) return false;
  const e = new KeyboardEvent('keydown', { bubbles: true, cancelable: true });
  Object.defineProperty(e, 'keyCode', { get: () => code });
  (document.activeElement || document.body).dispatchEvent(e);
  return true;
}

/** Types [text] into the focused text field, replacing what it had; without one, searches. */
export function typeRemoteText(text: string): void {
  const active = document.activeElement as HTMLElement | null;
  const field = active && (active.tagName === 'INPUT' ? active : active.classList.contains('field') ? active : null);
  if (!field) {
    // Under a dialog, the search would show what was typed for it: a key, a password
    if (document.querySelector('[data-layer="dialog"]')) return toast(t('pickFieldFirst'));
    if (!text) return; // sent empty: nothing to search, and no reason to leave the screen
    return remoteSearch.send(text);
  }
  const fill = (input: HTMLInputElement) => {
    const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!;
    set.call(input, text);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    // The keyboard closes, and that is all: in Flutter the text only fills the field, it submits nothing
    const done = new KeyboardEvent('keydown', { bubbles: true });
    Object.defineProperty(done, 'keyCode', { get: () => Keys.imeDone });
    Object.defineProperty(done, 'closeOnly', { value: true });
    input.dispatchEvent(done);
  };
  if (field.tagName === 'INPUT') return fill(field as HTMLInputElement);
  // A field the remote is on but not editing: open it, then fill it
  field.click();
  setTimeout(() => {
    const input = field.querySelector('input');
    if (input) fill(input);
  }, 50);
}
