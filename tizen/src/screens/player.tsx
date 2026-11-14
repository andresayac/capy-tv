// The player screen (app/lib/player/player_screen.dart): a queue of channels, a movie or a
// season's episodes. With the controls hidden the remote works like a TV: live, up/down and
// CH+/CH− zap; on demand, left/right skip 10 s; OK pauses; any other key shows the controls.
// Progress is saved to the library as it plays, and a title half seen resumes where it was.
// Each copy of a title gets a while to start, the one likely fastest first (see StreamStats); a
// stream that drops or freezes is opened again, with growing pauses, before "unavailable".
import { ComponentChild, ComponentChildren } from 'preact';
import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks';
import { Library, MediaRef, resumable } from '../data/library';
import { Intro, introMarks } from '../data/intro_marks';
import { EpgEntry, LiveChannel, SourceException } from '../data/source';
import { XtreamSource } from '../data/xtream';
import { isLanguage, settings } from '../data/settings';
import { StreamStats } from '../data/stream_stats';
import { t } from '../i18n';
import { log } from '../log';
import { OpenOptions, player, PlayerState, Track, TrackChooser } from '../platform/player';
import { SLEEP_CHOICES, SleepMinutes, sleepTimer } from '../data/sleep';
import { profileStore } from '../data/profiles';
import { watchTime } from '../data/watch_time';
import { confirmPin } from './profiles';
import { nowPlaying } from '../remote/now';
import { Keys } from '../platform/tv';
import { session } from '../session';
import { CapyStatus, Focusable, Icon, Notifier, PrimaryButton, SecondaryButton, useNotifier } from '../ui/components';
import { activeLayer, focus, focusables, focused } from '../ui/focus';
import { closeDialogs, push, showDialog, useBack, useKeys } from '../ui/router';
import { useRowWindow } from '../ui/window';
import { NetImage } from './home';
import './player.css';

/** One playable entry: a channel, a movie or an episode. */
export interface PlayItem {
  url: string;
  title: string;
  subtitle?: string;
  ref?: MediaRef; // when set, progress is saved to the library
  channel?: LiveChannel; // live: its guide shows in the controls
  /**
   * Other copies of the same title (another language or quality, another provider): the player
   * tries them, fastest first, when one does not start.
   */
  alternates?: string[];
  /** The User-Agent the stream needs; when unset, the source is asked (an M3U entry's). */
  userAgent?: string;
  /** This copy was picked by hand (a language, a provider): it goes first, the others only if it does not start. */
  pinned?: boolean;
  /** Where to start (sent from another device), in place of where it was left. */
  start?: number;
}

export function playQueue(items: PlayItem[], index = 0): Promise<void> {
  return push((done) => <PlayerScreen items={items} start={index} done={done} />, { clear: true }).then(() => {});
}

export function playChannels(channels: LiveChannel[], index: number): void {
  const { source } = session();
  playQueue(
    channels.map((c) => ({ url: source.liveUrl(c), title: c.name, channel: c, ref: liveRef(c) })),
    index,
  );
}

function liveRef(c: LiveChannel): MediaRef {
  const r: MediaRef = { kind: 'live', id: c.id, title: c.name };
  if (c.icon) r.image = c.icon;
  if (c.url) r.url = c.url;
  if (c.epgId) r.epg = c.epgId;
  return r;
}

const HIDE_AFTER = 3500;
const SKIP = 10000;
// A stream that never starts (an event channel before kick-off, a dead link) would otherwise spin
// forever; with other copies to try, a slow one is left sooner: one of them may well start at once
const START_TIMEOUT = 20000;
const START_TIMEOUT_WITH_OTHERS = 10000;
// The seek to where a title was left: slow on a slow line, and no reason to give up a copy that
// opened. As long as AVPlay's own seek is waited for; a seek that never lands must still end
const RESUME_SEEK_TIMEOUT = 30000;
// A live stream whose picture has not moved for this long, though nobody paused it, is opened again
const STALL_LIMIT = 12000;
// On demand a server can go quiet with the connection open, and nothing reports it: a picture still
// for this long, far past a slow line's rebuffering, is opened again where it was
const VOD_STALL_LIMIT = 45000;
const MAX_REOPENS = 5;
// On demand, a stream that breaks off is opened again where it was (FFmpeg's reconnect in Flutter)
const MAX_VOD_REOPENS = 2;
// The subtitle sizes on offer, in percent; each but the usual one is a class in player.css
/** Why a stream did not open, as far as it can be told. */
type FailWhy = 'network' | 'unsupported' | 'expired' | 'busy' | null;

const FAIL_TEXT = {
  network: 'failNetwork',
  unsupported: 'failUnsupportedHere',
  expired: 'failExpired',
  busy: 'failBusy',
  unknown: 'unavailableHint',
} as const;

/** From what AVPlay, hls.js or the <video> said (platform/player.ts). */
function failWhyOf(error: string): FailWhy {
  if (/NOT_SUPPORTED|UNSUPPORTED|MEDIA_ERR_[34]|bufferAppendError|fragParsingError|manifestIncompatibleCodecs/i.test(error)) return 'unsupported';
  if (/CONNECTION|NETWORK|TIMEOUT|TimeOut|LoadError|MEDIA_ERR_2/i.test(error)) return 'network';
  return null;
}

const SUBTITLE_SCALES = [75, 100, 125, 150, 200];
const SUBTITLE_LIFTS = [0, 10, 20]; // percent of the screen's height above the bottom
const SUBTITLE_DARKNESS = [50, 70, 90, 100];
// A row of the channel list, spacing included: the rows share one height (useRowWindow)
const CHANNEL_ROW = 6; // rem
const PX = 20; // px in a rem (theme.css)

// ISO 639 codes as streams write them, to the three letters the app's language names use
const TO_639_2: Record<string, string> = {
  es: 'spa', esa: 'spa', spa: 'spa', en: 'eng', eng: 'eng', fr: 'fra', fre: 'fra', fra: 'fra', de: 'deu', ger: 'deu', deu: 'deu',
  it: 'ita', ita: 'ita', pt: 'por', por: 'por', ja: 'jpn', jpn: 'jpn', ko: 'kor', kor: 'kor', zh: 'zho', chi: 'zho', zho: 'zho',
  ar: 'ara', ara: 'ara', ru: 'rus', rus: 'rus',
};

const iso3 = (code: string) => TO_639_2[code.toLowerCase().trim()] || code.toLowerCase().trim();

// Accent-insensitive, so a title "Ingles" does not repeat "Inglés"
const plain = (s: string) => s.toLowerCase().replace(/[áéíóú]/g, (c) => 'aeiou'['áéíóú'.indexOf(c)]);

/**
 * "Spanish · Latino" from the track's language plus whatever title it carries (niceTrack); an
 * unlabeled one is "Track N" by its place among the audio or the subtitle tracks.
 */
function trackName(tr: Track, position: number): string {
  const code = (tr.language || '').toLowerCase().trim();
  const lang = !code || code === 'und' ? '' : t('languageName', { code: iso3(code) });
  const title = (tr.title || '').trim();
  const label = [lang, title && plain(title) !== plain(lang) ? title : ''].filter((s) => s).join(' · ');
  const extra = tr.channels && tr.channels > 2 ? ` · ${tr.channels === 6 ? '5.1' : tr.channels === 8 ? '7.1' : tr.channels + 'ch'}` : '';
  return (label || t('trackN', { n: position + 1 })) + extra;
}

/**
 * How well a track tagged [tag] fits [language], lower first, as mpv ranks its alang list: the
 * language's own code, then the codes that stand for it (es), then the regional tags (lat, cas).
 * -1 when it does not fit at all.
 */
function languageRank(tag: string, language: string): number {
  if (!tag || !isLanguage(tag, language)) return -1;
  const code = tag.toLowerCase().trim();
  return code === language ? 0 : iso3(code) === language ? 1 : 2;
}

/** The track of [tracks] that best fits [language]; equals in stream order. */
function bestFor(tracks: Track[], language: string): Track | undefined {
  let best: Track | undefined;
  let rank = Infinity;
  for (const tr of tracks) {
    // A rendition with no LANGUAGE may still carry the code as its name
    const r = languageRank(tr.language || tr.title || '', language);
    if (r >= 0 && r < rank) {
      best = tr;
      rank = r;
    }
  }
  return best;
}

/**
 * The preferred audio and subtitle languages of the settings, applied before the stream plays as
 * mpv's alang/slang are in the Flutter app: unset leaves the stream's own choice, and so does a
 * track already as good as the best; subtitles "off" hides them.
 */
const chooseTracks: TrackChooser = (tracks, audio, text) => {
  const out: { audio?: number; text?: number } = {};
  const lang = settings.audioLanguage;
  if (lang) {
    const list = tracks.filter((tr) => tr.kind === 'audio');
    const best = bestFor(list, lang);
    const current = list.filter((tr) => tr.index === audio)[0];
    const tag = (tr: Track) => tr.language || tr.title || '';
    if (best && !(current && languageRank(tag(current), lang) === languageRank(tag(best), lang))) out.audio = best.index;
  }
  const subs = settings.subtitleLanguage;
  if (subs === 'off') out.text = -1;
  else if (subs) {
    const best = bestFor(tracks.filter((tr) => tr.kind === 'text'), subs);
    if (best && best.index !== text) out.text = best.index;
  }
  return out;
};

/** "1:02:03", or "2:03" under an hour. */
export function clock(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const two = (n: number) => (n < 10 ? '0' : '') + n;
  const h = Math.floor(s / 3600);
  return h > 0 ? `${h}:${two(Math.floor(s / 60) % 60)}:${two(s % 60)}` : `${Math.floor(s / 60)}:${two(s % 60)}`;
}

/** As Dart prints a double: "0.5x", "2.0x". */
const rateLabel = (r: number) => (Math.round(r) === r ? r.toFixed(1) : String(r)) + 'x';

/** One copy of a title to try: its address and what it needs to be asked with. */
interface Copy {
  url: string;
  userAgent?: string;
}

/** The User-Agent the open source says [url] needs, if any (headersFor in the Flutter app). */
function userAgentFor(url: string): string | undefined {
  try {
    return session().source.userAgentFor(url) || undefined;
  } catch {
    return undefined; // no playlist open
  }
}

function copiesOf(item: PlayItem): Copy[] {
  const main: Copy = { url: item.url, userAgent: item.userAgent || userAgentFor(item.url) };
  return [main].concat((item.alternates || []).map((url) => ({ url, userAgent: userAgentFor(url) })));
}

/**
 * What _PlayerScreenState holds in the Flutter app: the queue, the copy playing, whether it
 * started, failed or is being opened again, and the controls' own state.
 */
class Playback extends Notifier {
  index: number;
  visible = true;
  /** "+10" / "−10" for a moment after a skip. */
  flash: string | null = null;
  /** Shows the "start over" pill while set. */
  resumedFrom: number | null = null;
  started = false;
  failed = false;
  /** Why it did not open, as far as the player and the provider tell. */
  failWhy: FailWhy = null;
  /** How many times the "unavailable" panel has shown, so it takes the remote once each time. */
  failures = 0;
  /** Trying another copy. */
  switching = false;
  /** The technical details of the stream show over the picture. */
  info = false;
  /** Where the series' opening titles are, if marked. */
  intro: Intro | null = null;
  /** Opening the stream again after it dropped. */
  reconnecting = false;

  private readonly library: Library;
  private copies: Copy[] = [];
  private copy = 0;
  private session = 0; // a new one per item opened, so a late callback knows it is stale
  private openedAt = 0;
  private hadDuration = false; // once started: a stream of unknown kind with a length is on demand
  private paused = false; // by the user: a still picture is then no stall
  private reopens = 0; // since it last played for a while
  private reopening = false; // waiting to open it again, or opening it
  private attempt = 0; // the latest reopening, so an older one that settles late is ignored
  private reopenedAt = 0;
  private moved = Date.now(); // when the position last moved forward
  private lastPosition = 0;
  private goodPosition = 0; // on demand: where to go back to after opening it again
  // Where it resumes, until it is there: meanwhile the position is near 0, and saved it would take
  // the place of where one was ("Continue watching" would lose it)
  private resumeTo = -1;
  private resumeSent = false; // its seek has been asked for
  private brokeAt = -1; // on demand: where it last "ended" early
  private lastState = player.state;
  // Where the last skip is headed: AVPlay reports the old position until a seek lands, so skips
  // pressed meanwhile add up from there instead of all starting from the same place
  private seekTarget = -1;
  private panels = 0;
  private left = false;
  private disposed = false;
  private hideTimer = 0;
  private flashTimer = 0;
  private flashSum = 0;
  private nextCancelled = false; // this episode ends without the next one starting
  private introSkipped = false;
  private resumeTimer = 0;
  private watchdog = 0;
  private reopenTimer = 0;
  private saveTimer = 0;
  private stallTimer = 0;
  private sleepCheckTimer = 0;
  private limitTimer = 0;
  private unsaved = 0; // seconds watched not yet noted
  private timeUp = false;
  private unlisten: (() => void) | null = null;

  constructor(readonly items: PlayItem[], start: number, private readonly done: () => void) {
    super();
    this.index = start;
    this.library = session().library;
  }

  get item(): PlayItem {
    return this.items[this.index];
  }

  /** Live by what the item is: a channel. */
  get isLive(): boolean {
    const item = this.item;
    return !!item.channel || (!!item.ref && item.ref.kind === 'live');
  }

  /**
   * Live for the controls and recovery: a channel, or a stream of unknown kind (catch-up from the
   * guide, a plain address) that started with no length. Before it starts, a movie would briefly
   * look live.
   */
  get live(): boolean {
    return this.isLive || (!this.item.ref && this.started && !this.hadDuration);
  }

  /** The series of the episode playing, by its title. */
  get seriesTitle(): string | null {
    const ref = this.item.ref;
    return ref && ref.kind === 'episode' ? ref.seriesTitle || null : null;
  }

  get hasPrev(): boolean {
    return this.index > 0;
  }

  get hasNext(): boolean {
    return this.index < this.items.length - 1;
  }

  /** A side panel, or any dialog, is over the player: the remote is the dialog's. */
  get panelOpen(): boolean {
    return this.panels > 0 || !!document.querySelector('[data-layer="dialog"]');
  }

  start(): void {
    player.setFit(settings.videoFitPicked ? settings.videoFit : null);
    this.unlisten = player.listen(() => this.onPlayer());
    this.saveTimer = window.setInterval(() => this.saveProgress(true), 10000);
    this.stallTimer = window.setInterval(() => this.checkStall(), 2000);
    this.sleepCheckTimer = window.setInterval(() => this.checkSleep(), 10000);
    this.limitTimer = window.setInterval(() => this.countTime(), 1000);
    document.addEventListener('visibilitychange', this.onVisibility);
    // Nothing opens once a kids profile's time today is up
    const left = watchTime.left(profileStore.current);
    if (left !== undefined && left <= 0) {
      this.stopForTime();
      return;
    }
    this.open();
    this.poke();
  }

  dispose(): void {
    this.disposed = true;
    if (this.unlisten) this.unlisten();
    document.removeEventListener('visibilitychange', this.onVisibility);
    for (const timer of [this.hideTimer, this.flashTimer, this.resumeTimer, this.watchdog, this.reopenTimer, this.zapTimer]) clearTimeout(timer);
    clearInterval(this.saveTimer);
    clearInterval(this.stallTimer);
    clearInterval(this.sleepCheckTimer);
    clearInterval(this.limitTimer);
    // The sleep timer was for what played here: not for whatever is opened next, an hour later
    sleepTimer.set({ kind: 'off' });
    this.noteTime();
    this.session++;
    if (!this.left) this.saveProgress();
    nowPlaying.set(null);
    if (player.rate !== 1) player.setRate(1); // the next viewing starts at normal speed
    player.stop();
  }

  /** Shows the controls; they hide after a while, only while the video plays. */
  poke = (): void => {
    if (this.disposed) return; // a side panel that closed after the player did
    this.visible = true;
    clearTimeout(this.hideTimer);
    this.hideTimer = window.setTimeout(() => {
      if (player.state === 'playing' && !this.panelOpen && !this.failed) {
        this.visible = false;
        this.notify();
      }
    }, settings.controlsSeconds * 1000 || HIDE_AFTER); // longer when Settings says so
    this.notify();
  };

  // Audio and subtitles chosen by hand, by language and name (indexes differ between copies and
  // episodes): kept the whole time the player is open, over a reconnection or the next episode
  private pickedAudio: Track | null = null;
  private pickedText: Track | 'off' | null = null;

  pickAudio(tr: Track): void {
    this.pickedAudio = tr;
    player.selectAudio(tr.index);
  }

  pickText(tr: Track | 'off'): void {
    this.pickedText = tr;
    player.selectText(tr === 'off' ? -1 : tr.index);
  }

  /** The picture's fit, kept for next time. */
  pickFit(fit: string): void {
    settings.set({ videoFit: fit });
    player.setFit(fit);
  }

  private openOptions(copy: Copy): OpenOptions {
    const same = (a: Track, b: Track) => a.kind === b.kind && a.language === b.language && (a.title || '') === (b.title || '');
    const choose: TrackChooser = (tracks, audio, text) => {
      const out = chooseTracks(tracks, audio, text);
      const a = this.pickedAudio && tracks.filter((tr) => same(tr, this.pickedAudio as Track))[0];
      if (a) out.audio = a.index;
      if (this.pickedText === 'off') out.text = -1;
      else if (this.pickedText) {
        const tx = tracks.filter((tr) => same(tr, this.pickedText as Track))[0];
        if (tx) out.text = tx.index;
      }
      return out;
    };
    return { userAgent: copy.userAgent, choose };
  }

  /** Opens the item; [sameItem] for its next copy after one that did not start. */
  private open(sameItem = false): void {
    const item = this.item;
    if (!sameItem) {
      const copies = copiesOf(item);
      this.copies = item.pinned ? copies.slice(0, 1).concat(StreamStats.fastestFirst(copies.slice(1), (c) => c.url)) : StreamStats.fastestFirst(copies, (c) => c.url);
      this.copy = 0;
      this.switching = false;
      this.retriedQuietly = false;
    }
    const copy = this.copies[this.copy];
    nowPlaying.set({ title: item.title, subtitle: item.subtitle });
    this.started = this.failed = this.reconnecting = this.paused = this.reopening = this.hadDuration = false;
    const session = ++this.session;
    this.reopens = 0;
    this.reopenedAt = 0;
    this.lastPosition = this.goodPosition = 0;
    this.seekTarget = this.brokeAt = this.resumeTo = -1;
    this.resumeSent = this.nextCancelled = this.introSkipped = false;
    this.intro = this.seriesTitle ? introMarks.of(this.seriesTitle) : null;
    this.moved = Date.now();
    clearTimeout(this.watchdog);
    clearTimeout(this.reopenTimer);
    this.watchdog = window.setTimeout(() => this.fail(session), this.copy + 1 < this.copies.length ? START_TIMEOUT_WITH_OTHERS : START_TIMEOUT);
    this.openedAt = Date.now();
    this.notify();
    player.open(copy.url, this.openOptions(copy)).then(
      () => this.opened(session),
      () => this.fail(session),
    );
  }

  /** The copy opened: a live channel (or a title with nothing to resume) is noted as seen, else it resumes. */
  private opened(session: number): void {
    if (session !== this.session) return;
    const item = this.item;
    const ref = item.ref;
    if (!ref) return;
    const saved = this.library.entry(ref);
    const at = item.start !== undefined ? item.start : saved && resumable(saved) ? saved.pos : 0;
    if (this.isLive || at <= 0) {
      this.library.record(ref);
      return;
    }
    this.resumeTo = at;
    // Seeking needs the length, which may come a moment after the picture
    this.whenDuration(session, 20000).then((known) => {
      if (session !== this.session) return;
      if (!known) {
        this.resumeTo = -1; // it plays from the start, then: that is where it is
        return;
      }
      // The pill shows while the seek is under way, not once it has landed
      this.resumedFrom = at;
      this.notify();
      // The start watchdog stops counting what is the seek's: it gets a limit of its own
      clearTimeout(this.watchdog);
      this.watchdog = window.setTimeout(() => this.fail(session), RESUME_SEEK_TIMEOUT);
      this.resumeSent = true;
      player.seek(at);
      clearTimeout(this.resumeTimer);
      this.resumeTimer = window.setTimeout(() => {
        this.resumedFrom = null;
        this.notify();
      }, 8000);
    });
  }

  private whenDuration(session: number, timeout: number): Promise<boolean> {
    return new Promise((resolve) => {
      if (player.duration > 0) return resolve(true);
      let timer = 0;
      const finish = () => {
        off();
        clearTimeout(timer);
        resolve(session === this.session && player.duration > 0);
      };
      const off = player.listen(() => {
        if (session !== this.session || player.duration > 0) finish();
      });
      timer = window.setTimeout(finish, timeout);
    });
  }

  /**
   * The copy did not start: the next one is tried, if any; else the "unavailable" panel shows,
   * with the remote on Retry. Not once it played.
   */
  private fail(session: number): void {
    // Both engines refusing says so twice (the state, then the open): one retry is already waiting
    if (session !== this.session || this.started || this.failed || session === this.quietRetry) return;
    clearTimeout(this.watchdog);
    StreamStats.failed(this.copies[this.copy].url);
    if (this.copy + 1 < this.copies.length) {
      log(`player: copy ${this.copy + 1} of ${this.copies.length} did not start, trying the next`);
      this.copy++;
      this.switching = true;
      this.open(true);
      return;
    }
    // Once more, quietly: a provider that allows one connection may not have let the last channel go
    if (this.live && !this.retriedQuietly) {
      this.retriedQuietly = true;
      this.quietRetry = session;
      window.setTimeout(() => session === this.session && !this.started && this.open(true), 1500);
      return;
    }
    this.showFailure();
  }

  private retriedQuietly = false;
  private quietRetry = 0; // the session waiting for it

  private showFailure(): void {
    this.failures++;
    this.failed = true;
    this.reconnecting = false;
    this.failWhy = failWhyOf(player.error);
    // A refusal reads as a load error: the account is asked about unless the format is the cause
    if (this.failWhy !== 'unsupported') this.askAccount();
    this.poke();
  }

  /** The account may have ended, or every connection it allows be in use elsewhere. */
  private askAccount(): void {
    const source = session().source;
    if (!(source instanceof XtreamSource)) return;
    const at = this.session;
    const tell = (why: FailWhy) => {
      if (why && at === this.session && this.failed && this.failWhy !== 'unsupported') {
        this.failWhy = why;
        this.notify();
      }
    };
    source.login().then(
      (info) => tell(info.maxConnections && (info.activeConnections || 0) >= info.maxConnections ? 'busy' : null),
      (e) => tell(e instanceof SourceException && e.error === 'inactiveAccount' ? 'expired' : null),
    );
  }

  /** Every change of the player: position, start, state. */
  private onPlayer(): void {
    const st = player.state;
    const p = player.position;
    if (p > this.lastPosition) {
      this.moved = Date.now();
      if (this.reconnecting && this.reopenedAt && p >= 1000) {
        this.reconnecting = false; // back
        this.notify();
      }
    }
    this.lastPosition = p;
    // Landed, or as near as it goes: a stream only seeks to where its keyframes are
    if (this.seekTarget >= 0 && (Math.abs(p - this.seekTarget) < 3000 || !player.seeking)) this.seekTarget = -1;
    // Refused or never answered it may be anywhere: where one was stays saved until playing gets there
    if (this.resumeTo >= 0 && (Math.abs(p - this.resumeTo) < 3000 || (this.resumeSent && !player.seeking && player.seekLanded))) this.resumeTo = -1;
    if (this.started && st === 'playing' && !this.reconnecting && p > 0) this.goodPosition = p;
    if (!this.started && p >= 500 && (st === 'playing' || st === 'paused')) {
      clearTimeout(this.watchdog);
      StreamStats.started(this.copies[this.copy].url, Date.now() - this.openedAt);
      this.started = true;
      this.switching = false;
      this.failed = false; // it recovered after the panel showed, if it had
      this.notify();
    }
    if (this.started && !this.hadDuration && player.duration > 0) {
      this.hadDuration = true;
      this.notify();
    }
    if (st !== this.lastState) {
      this.lastState = st;
      this.onState(st);
    }
  }

  private onState(st: PlayerState): void {
    // The controls stay up while it does not play, and hide again once it does
    if (st === 'paused') {
      clearTimeout(this.hideTimer);
      this.visible = true;
      this.notify();
    } else if (st === 'playing' && this.visible) {
      this.poke();
    }
    if (this.reopening) return; // opening it again sees to its own outcome
    if (st === 'ended') this.onEnded();
    else if (st === 'error') {
      if (!this.started) this.fail(this.session);
      else this.recover();
    }
  }

  private onEnded(): void {
    if (!this.started) return this.fail(this.session);
    if (this.live) return this.recover(); // a live stream does not end: it dropped
    // AVPlay may call a connection that closed mid-film "completed": a break, opened again where
    // it was, not the end (which would mark it seen and close the player). A length that was only
    // estimated (a .ts file) can be off: ending again at the same place is the end after all
    const dur = player.duration;
    const reached = Math.max(this.goodPosition, this.seekTarget);
    if (dur > 0 && reached < dur - 30000 && !(this.brokeAt >= 0 && reached < this.brokeAt + 30000)) {
      this.brokeAt = reached;
      return this.recover();
    }
    // Ending twice at one place well short of the end (under 90 %) is a file cut short, not an
    // estimate that was off: said as such, where it got to kept, not marked seen
    if (dur > 0 && reached < dur * 0.9) return this.showFailure();
    this.reconnecting = false; // so it is saved as seen whole
    if (sleepTimer.atEnd) this.triggerSleep(true); // "when it ends": this one, before the next episode
    else if (this.hasNext && !this.nextCancelled) this.go(1); // binge: the next episode starts by itself
    else this.leave(); // the end: back to where it was opened from
  }

  /**
   * Every 2 s: a picture that stopped moving although nobody paused it and no seek is on its way.
   * Live or opened again after a break it is soon (else "Reconnecting…" would spin for good), any
   * other on-demand stream after longer; one not playing (time up, the end) is left alone.
   */
  private checkStall(): void {
    if (!this.started || this.failed || this.timeUp) return;
    const now = Date.now();
    if (this.paused || player.state === 'paused' || player.seeking) {
      this.moved = now;
      return;
    }
    const limit = this.live || this.reconnecting ? STALL_LIMIT : player.state === 'playing' ? VOD_STALL_LIMIT : Infinity;
    if (now - this.moved > limit) this.recover();
    else if (this.reopens > 0 && !this.reconnecting && this.reopenedAt && now - this.reopenedAt > 60000 && now - this.moved < STALL_LIMIT) this.reopens = 0; // fine again
  }

  /** Counts what a profile with a time per day watches, and stops when it is up (Flutter's _countTime). */
  private countTime(): void {
    const p = profileStore.current;
    const left = watchTime.left(p);
    if (left === undefined || this.timeUp || player.state !== 'playing') return;
    this.unsaved++;
    if (this.unsaved >= 15) this.noteTime();
    if (left - this.unsaved <= 0) this.stopForTime();
  }

  private noteTime(): void {
    if (!this.unsaved) return;
    watchTime.add(profileStore.current.id, this.unsaved);
    this.unsaved = 0;
  }

  /** "That's all for today": it stops, and only a grown-up with the PIN gives more. */
  private async stopForTime(): Promise<void> {
    this.timeUp = true;
    this.noteTime();
    this.saveProgress();
    player.stop();
    for (;;) {
      const more = await showDialog<boolean>((done) => <TimeUpPrompt done={done} />);
      if (this.disposed) return;
      if (!more) return this.leave();
      if (!profileStore.hasPin) {
        await showDialog<void>((done) => <TimeUpPrompt done={() => done()} noPin />);
        continue;
      }
      if (!(await confirmPin())) continue;
      watchTime.addTime(profileStore.current.id, 30);
      this.timeUp = false;
      return this.open();
    }
  }

  /** Fires every 10 s: triggers sleep when the countdown reaches zero (or past it). */
  private checkSleep(): void {
    // A panel left open (the sleep timer's own, chosen and never closed) does not keep it awake
    if (this.disposed) return;
    const left = sleepTimer.left;
    if (left !== null && left <= 0) this.triggerSleep(false);
  }

  /**
   * Asks "Still watching?": with no answer, or Exit, it stops and leaves the player. Any other
   * answer (Back too) means someone is awake. [ended]: what was playing is over.
   */
  private async triggerSleep(ended: boolean): Promise<void> {
    sleepTimer.set({ kind: 'off' }); // off first, so it does not fire again while the prompt is up
    closeDialogs(); // over the panels left open: the prompt has the remote, and leaving closes them
    const keepWatching = await showDialog<boolean>((done) => <SleepPrompt done={done} />);
    if (this.disposed) return;
    if (keepWatching === false) this.leave();
    else if (ended && this.hasNext && !this.nextCancelled) this.go(1);
    else if (ended) this.leave();
  }

  /**
   * The stream dropped or froze after it had started: opens it again after a pause that grows
   * each time, and gives up after a few tries.
   */
  private recover(): void {
    if (this.failed || this.reopening) return; // already on it
    if (this.reopens >= (this.live ? MAX_REOPENS : MAX_VOD_REOPENS)) return this.giveUp();
    this.reopen(1000 << this.reopens++);
  }

  /** No more tries: the engine lets go of a stream it may still hold, so nothing plays behind the panel. */
  private giveUp(): void {
    this.saveProgress();
    player.stop();
    this.showFailure();
  }

  /** Opens the copy playing again after [delay] ms; on demand, back where it was. */
  private reopen(delay: number): void {
    const session = this.session;
    const attempt = ++this.attempt;
    const copy = this.copies[this.copy];
    // Where it was headed if a resume or a skip was under way, not the near 0 it had got to
    const at = this.live ? 0 : this.resumeTo >= 0 ? this.resumeTo : this.seekTarget >= 0 ? this.seekTarget : this.goodPosition;
    this.resumeSent = false; // opening it tells whoever listens: not to be taken for a landing
    this.reconnecting = this.reopening = true;
    this.reopenedAt = 0;
    this.notify();
    clearTimeout(this.reopenTimer);
    this.reopenTimer = window.setTimeout(() => {
      if (session !== this.session || attempt !== this.attempt) return; // zapped or retried meanwhile
      log(`player: opening it again (${this.reopens})`);
      this.paused = false; // it plays again once open, whatever was pressed while it waited
      this.lastPosition = 0;
      let settled = false;
      // Opened, refused, or still not open after a while (AVPlay can hang on a dead server)
      const settle = () => {
        if (settled || session !== this.session || attempt !== this.attempt) return;
        settled = true;
        clearTimeout(this.reopenTimer);
        this.reopening = false;
        this.reopenedAt = this.moved = Date.now();
        if (player.state === 'ended') this.onEnded(); // at once: a break again, or the end after all
        else if (player.state !== 'playing' && player.state !== 'paused') this.recover(); // again, after a longer pause
      };
      this.reopenTimer = window.setTimeout(settle, START_TIMEOUT);
      player
        .open(copy.url, this.openOptions(copy))
        .then(
          () => {
            if (settled || session !== this.session || at <= 0) return;
            this.seekTarget = at;
            this.resumeSent = this.resumeTo >= 0;
            player.seek(at);
          },
          () => {},
        )
        .then(settle);
    }, delay);
  }

  /** The TV brought the app back: the controls show; a live channel is opened afresh. */
  private onVisibility = (): void => {
    if (document.hidden) return;
    this.poke();
    if (this.failed) return;
    if (!this.started) return this.open(true); // it was still opening: this copy from the start
    if (this.live) {
      this.paused = false;
      this.reopens = 0;
      this.reopen(0);
    }
  };

  /** Play/pause from the user, remembered so a paused live picture is not taken for a stall. */
  togglePlay = (): void => {
    const pausing = player.state === 'playing';
    player.playOrPause();
    this.paused = pausing;
    this.poke();
  };

  /**
   * Where the bar and the times stand: where a skip or a resume is going until it gets there. The
   * player says nothing meanwhile, and on a slow line that is seconds of a bar that does not move.
   */
  get displayPosition(): number {
    if (this.seekTarget >= 0) return this.seekTarget;
    if (this.resumeTo >= 0 && (!this.resumeSent || player.seeking)) return this.resumeTo;
    // Broken off and being opened again: where it was, not the 0:00 of a fresh start
    if (this.reconnecting && !this.live && this.goodPosition > 0) return this.goodPosition;
    return player.position;
  }

  /** "Next episode" shows in an episode's last half minute, the one after it ready to start. */
  get nextOffered(): boolean {
    const dur = player.duration;
    const left = dur - this.displayPosition;
    return !this.isLive && this.hasNext && !this.nextCancelled && !sleepTimer.atEnd && this.started && !this.failed && !this.reconnecting && player.state !== 'ended' && dur >= 60000 && left > 0 && left <= 30000;
  }

  cancelNext = (): void => {
    this.nextCancelled = true;
    this.notify();
  };

  seekBy = (ms: number): void => {
    if (this.live || this.failed || !this.started || this.reopening) return;
    // On from where the last skip is going, however long it is taking to get there
    const from = this.displayPosition;
    const dur = player.duration;
    this.seekTo(Math.max(0, dur > 0 ? Math.min(from + ms, dur) : from + ms));
    clearTimeout(this.flashTimer);
    this.flashSum = this.flash ? this.flashSum + ms : ms; // what is shown adds up while it shows
    this.flash = `${this.flashSum < 0 ? '−' : '+'}${Math.abs(this.flashSum) / 1000}`;
    this.flashTimer = window.setTimeout(() => {
      this.flash = null;
      this.notify();
    }, 650);
    this.poke();
  };

  private seekTo(to: number): void {
    this.seekTarget = to;
    this.moved = Date.now(); // a slow skip is no stall
    this.resumeTo = -1; // somewhere else chosen
    player.seek(to);
  }

  /** "Skip intro" shows while the marked opening titles play. */
  get introOffered(): boolean {
    const intro = this.intro;
    if (this.introSkipped || !introMarks.complete(intro) || !this.started || this.failed || this.reconnecting) return false;
    const pos = this.displayPosition;
    return pos >= intro!.start! - 1000 && pos < intro!.end! - 2000;
  }

  skipIntro = (): void => {
    if (!this.introOffered) return;
    this.introSkipped = true;
    this.seekTo(this.intro!.end!);
    this.poke();
  };

  /** Marks where the series' opening titles start or end, at this point of the episode; or clears both. */
  markIntro(what: 'start' | 'end' | 'clear'): void {
    const series = this.seriesTitle;
    if (!series) return;
    const at = Math.round(this.displayPosition);
    const was = this.intro;
    const intro: Intro = what === 'clear' ? { start: null, end: null } : { start: what === 'start' ? at : was ? was.start : null, end: what === 'end' ? at : was ? was.end : null };
    introMarks.save(series, intro);
    this.intro = what === 'clear' ? null : intro;
    this.notify();
  }

  setInfo(on: boolean): void {
    this.info = on;
    this.notify();
  }

  /** "2 of 3", when the title has more than one copy. */
  get copyNote(): string {
    return this.copies.length > 1 ? t('nOfTotal', { n: this.copy + 1, total: this.copies.length }) : '';
  }

  startOver = (): void => {
    player.seek(0);
    this.seekTarget = this.resumeTo = -1;
    this.resumedFrom = null;
    this.notify();
  };

  /** Moves through the queue: channel zapping for live, previous/next episode on demand. Stops at the ends. */
  go = (step: number): void => {
    const next = this.index + step;
    if (next < 0 || next >= this.items.length) return;
    this.saveProgress();
    this.index = next;
    this.resumedFrom = null;
    clearTimeout(this.resumeTimer);
    this.poke();
    if (!this.live) return this.open();
    // Zapping with the key held: only the channel stopped at opens, not each one passed
    clearTimeout(this.zapTimer);
    this.zapTimer = window.setTimeout(() => this.open(), 350);
  };

  private zapTimer = 0;

  retry = (): void => this.open();

  leave = (): void => {
    this.saveProgress();
    this.left = true;
    this.done();
  };

  /** The position as the library keeps it; a title about to end counts as seen whole. [quiet] while playing. */
  private saveProgress(quiet = false): void {
    const ref = this.item.ref;
    const dur = player.duration;
    if (!ref || this.isLive || dur <= 0 || player.state === 'idle' || player.state === 'opening') return;
    if (this.resumeTo >= 0) return; // not there yet: where it was stays
    // Broken off and being opened again, or given up on: where it was, not where the fresh copy
    // is (from 0, or "ended" by a connection that closed)
    const broken = this.reconnecting || this.reopening || this.failed;
    const at = broken ? this.goodPosition : this.seekTarget >= 0 ? this.seekTarget : player.position;
    if (broken && at <= 0) return;
    const pos = (player.state === 'ended' && !broken) || at >= dur - 5000 ? dur : at;
    this.library.record(ref, pos, dur, quiet);
  }

  /** A side panel over the player: the controls stay up meanwhile, and the remote comes back where it was. */
  async openPanel(render: (done: () => void) => ComponentChild): Promise<void> {
    const from = focused();
    this.panels++;
    this.poke();
    await showDialog<void>((done) => render(() => done()));
    this.panels--;
    if (from && document.body.contains(from)) focus(from);
    this.poke();
  }
}

function PlayerScreen({ items, start, done }: { items: PlayItem[]; start: number; done: () => void }) {
  const holder = useRef<Playback | null>(null);
  if (!holder.current) holder.current = new Playback(items, start, done);
  const c = holder.current;
  useNotifier(player);
  useNotifier(c);
  useNotifier(settings);
  const [epg, setEpg] = useState<EpgEntry[]>([]);
  const root = useRef<HTMLDivElement>(null);
  const playBox = useRef<HTMLDivElement>(null);
  const dockPlayBox = useRef<HTMLDivElement>(null);
  const retryBox = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    c.start();
    return () => {
      c.dispose();
      document.body.classList.remove('player-controls-up');
    };
  }, []);

  // hls.js's subtitle lines, which Chromium draws on the <video> outside this screen, rise above
  // the dock while the controls show (Flutter's subtitle padding, 44 dp or 150 dp)
  useEffect(() => {
    document.body.classList.toggle('player-controls-up', c.visible);
  }, [c.visible]);

  // On the body, as the controls' are: hls.js's lines are drawn on the <video>, outside this screen
  const subtitleScale = settings.subtitleScale;
  const subtitleBand = settings.subtitleBackground;
  const { subtitleBandDarkness, subtitleOutline, subtitleLift } = settings;
  useEffect(() => {
    const body = document.body.classList;
    for (const scale of SUBTITLE_SCALES) body.toggle(`subs-${scale}`, scale === subtitleScale);
    body.toggle('subs-band', subtitleBand);
    body.toggle('subs-outline', subtitleOutline);
    for (const lift of SUBTITLE_LIFTS) body.toggle(`subs-lift-${lift}`, lift === subtitleLift);
    document.body.style.setProperty('--subs-band', String(subtitleBandDarkness / 100));
  }, [subtitleScale, subtitleBand, subtitleBandDarkness, subtitleOutline, subtitleLift]);

  // The next episode, offered with the controls away, takes the remote: OK plays it now
  const offered = c.nextOffered;
  const nextBox = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!offered || c.visible || c.panelOpen || !nextBox.current) return;
    const first = focusables(nextBox.current)[0];
    if (first) focus(first);
  }, [offered, c.visible]);

  // "Skip intro", offered with the controls away, takes the remote: OK skips
  const introOffered = c.introOffered;
  const introBox = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!introOffered || c.visible || c.panelOpen || !introBox.current) return;
    const first = focusables(introBox.current)[0];
    if (first) focus(first);
  }, [introOffered, c.visible]);

  // A channel's guide: what is on now and next; again when that ends, or when the guide comes in
  const guideHolder = session().guide;
  useNotifier(guideHolder);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    setEpg([]);
    const channel = c.item.channel;
    let timer = 0;
    const until = (e: EpgEntry[]) => {
      // Once what is on now ends, what comes next is "now"
      if (e.length) timer = window.setTimeout(() => alive && setTick((n) => n + 1), Math.max(1000, e[0].end.getTime() - Date.now() + 1000));
    };
    if (channel) {
      // The guide's when it has what is on now; else the provider's for this channel alone, as for a
      // channel the guide leaves out or a copy kept from before the provider's guide failed
      const guide = guideHolder.guide;
      if (guide.nowOn(channel.epgId)) {
        const e = guide.upcoming(channel.epgId, 2);
        setEpg(e);
        until(e);
      } else {
        session().source.shortEpg(channel, 2).then((e) => {
          if (!alive) return;
          setEpg(e);
          until(e);
        }, () => {});
      }
    }
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [c.index, tick, guideHolder.guide]);

  const first = (...boxes: (HTMLElement | null)[]) =>
    boxes.map((b) => b && b.querySelector<HTMLElement>('.f:not([data-disabled])')).filter((el) => el)[0] || null;

  // The "unavailable" panel takes the remote at once, once each time it shows: one OK retries.
  // Not from under a side panel (the stream gave up while it was open): once that closes
  const panelOpen = c.panelOpen;
  const retried = useRef(0);
  useEffect(() => {
    if (!c.failed || panelOpen || retried.current === c.failures) return;
    const retry = first(retryBox.current);
    if (!retry) return;
    retried.current = c.failures;
    focus(retry);
  }, [c.failed, c.failures, panelOpen]);

  // The focus never gets lost with the controls (a button that went away, one now disabled):
  // play/pause takes it, as when the player opened; Retry while the stream is unavailable
  useEffect(() => {
    const layer = activeLayer();
    const box = root.current;
    if (!layer || !box || !layer.contains(box)) return;
    const f = focused();
    if (f && box.contains(f) && !f.hasAttribute('data-disabled')) return;
    const target = c.failed ? first(retryBox.current, dockPlayBox.current) : first(playBox.current, dockPlayBox.current);
    if (target) focus(target);
  });

  useBack(() => {
    if (c.panelOpen) return false; // Back closes the panel alone
    c.leave();
    return true;
  });

  useKeys((e) => {
    if (c.panelOpen) return false; // the panel has the remote
    const k = e.keyCode;
    if (k === Keys.playPause) {
      c.togglePlay();
      return true;
    }
    if (k === Keys.play) {
      if (player.state === 'playing') c.poke();
      else c.togglePlay();
      return true;
    }
    if (k === Keys.pause) {
      if (player.state === 'playing') c.togglePlay();
      else c.poke();
      return true;
    }
    if (k === Keys.fastForward) return c.seekBy(SKIP), true;
    if (k === Keys.rewind) return c.seekBy(-SKIP), true;
    if (k === Keys.channelUp) return c.go(1), true;
    if (k === Keys.channelDown) return c.go(-1), true;
    if (k === Keys.trackNext) return c.go(1), true;
    if (k === Keys.trackPrevious) return c.go(-1), true;
    // Flutter's menu key and A open audio and subtitles, with or without the controls; Samsung
    // remotes have neither: Info, yellow, and the Caption and MTS keys where the remote has them
    if (k === Keys.info || k === Keys.yellow || k === Keys.caption || k === Keys.mts) return openTracks(), true;
    if (k === Keys.back || k === Keys.escape) return false;
    if (!c.visible && !c.failed) {
      if (c.introOffered && k === Keys.enter) return c.skipIntro(), true;
      // The next episode on offer has the remote: OK on its buttons, Left and Right between them
      const offer = c.nextOffered && nextBox.current ? focusables(nextBox.current) : [];
      if (offer.length && (k === Keys.enter || k === Keys.left || k === Keys.right)) {
        const at = offer.indexOf(focused() as HTMLElement);
        if (k === Keys.enter) return offer[Math.max(at, 0)].click(), true;
        if (at >= 0) return focus(offer[k === Keys.left ? 0 : offer.length - 1]), true;
      }
      // Live: up/down zap through the channel list, like a TV
      if (c.isLive && k === Keys.up) return c.go(-1), true;
      if (c.isLive && k === Keys.down) return c.go(1), true;
      if (k === Keys.left || k === Keys.right) {
        c.seekBy(k === Keys.left ? -SKIP : SKIP);
        // The controls are up now: from the bar the next arrows skip on, rather than move the focus
        const bar = root.current && root.current.querySelector<HTMLElement>('.pbar');
        if (bar) focus(bar);
        return true;
      }
      // A channel stays live: OK shows what is on rather than freezing it
      if (k === Keys.enter) return c.isLive ? c.poke() : c.togglePlay(), true;
      c.poke();
      return true;
    }
    // On the progress bar, left/right skip 10 s like in TV apps
    const f = focused();
    if (f && f.classList.contains('pbar') && (k === Keys.left || k === Keys.right)) {
      c.seekBy(k === Keys.left ? -SKIP : SKIP);
      return true;
    }
    c.poke();
    return false; // with the controls showing, the arrows move the focus
  });

  const item = c.item;
  const live = c.live;
  const st = player.state;
  const playing = st === 'playing';
  const dur = player.duration;
  const pos = c.displayPosition;
  const loading = (player.buffering || st === 'opening' || c.reconnecting || (c.switching && !c.started)) && !c.failed;
  const note = (c.reconnecting || (c.switching && !c.started)) && !c.failed ? (c.reconnecting ? t('reconnecting') : t('tryingAnotherCopy')) : null;
  const now = epg[0];
  const next = epg[1];
  const epgProgress = now ? Math.min(1, Math.max(0, (Date.now() - now.start.getTime()) / (now.end.getTime() - now.start.getTime()))) : 0;
  const channel = c.isLive ? item.channel : undefined;
  const openTracks = () => c.openPanel(() => <TracksPanel c={c} />);
  const openSpeed = () => c.openPanel((done) => <SpeedPanel done={done} />);

  return (
    <div ref={root} class="player">
      {player.subtitle && (
        <div class="player-subtitle" style={{ bottom: offered ? (c.visible ? '30rem' : '19rem') : c.visible ? '15rem' : introOffered ? '10rem' : '4.4rem' }}>
          <span>{player.subtitle}</span>
        </div>
      )}
      {loading && !c.visible && (
        <div class="player-center">
          <div class="spinner" style={{ width: '5.6rem', height: '5.6rem', borderWidth: '0.3rem' }} />
        </div>
      )}
      {/* Its own key: else a subtitle line or the spinner, coming before it, would take this box over
          and every control be built anew, the focus going with them */}
      <div key="controls" class="player-layer player-overlay" style={{ opacity: c.visible ? 1 : 0 }}>
        <div class="player-layer player-shade" />
        {/* Top: back, the channel or title, the live badge */}
        <div class="row" style={{ position: 'absolute', left: 0, right: 0, top: 0, padding: '1.2rem 1.6rem 0 1.2rem' }}>
          <CircleButton icon="arrow_back_rounded" size={44} onTap={c.leave} />
          <span style={{ width: '1.6rem', flex: 'none' }} />
          {channel && (
            <div style={{ width: '6.6rem', height: '4.4rem', flex: 'none', marginRight: '1.2rem', background: 'var(--surface-high)', borderRadius: '0.8rem', padding: '0.4rem', boxSizing: 'border-box' }}>
              <NetImage url={channel.icon} icon="tv_rounded" />
            </div>
          )}
          <div class="grow">
            <div class="row">
              {channel && channel.number !== undefined && (
                <span class="muted" style={{ fontSize: 'calc(1.8rem * var(--text-scale))', fontWeight: 700, marginRight: '1rem', flex: 'none' }}>
                  {channel.number}
                </span>
              )}
              <span class="grow ellipsis" style={{ fontSize: 'calc(1.8rem * var(--text-scale))', fontWeight: 800, letterSpacing: '-0.03rem' }}>
                {item.title}
              </span>
            </div>
            {item.subtitle && (
              <div class="ellipsis" style={{ color: 'rgba(255,255,255,0.7)' }}>
                {item.subtitle}
              </div>
            )}
          </div>
          {live && <LiveBadge />}
        </div>
        {/* Center: −10 · play/pause · +10 (the "unavailable" panel takes its place) */}
        {!c.failed && (
          <div class="player-center">
            <div class="row" data-fgroup>
              {!live && <CircleButton icon="replay_10_rounded" size={52} onTap={() => c.seekBy(-SKIP)} />}
              <span style={{ width: '2.8rem' }} />
              <div ref={playBox}>
                <PlayButton playing={playing} loading={loading} onTap={c.togglePlay} />
              </div>
              <span style={{ width: '2.8rem' }} />
              {!live && <CircleButton icon="forward_10_rounded" size={52} onTap={() => c.seekBy(SKIP)} />}
            </div>
          </div>
        )}
        {/* Bottom: the dock, with the progress (on demand) or the guide (live) over its buttons */}
        <div class="panel" style={{ position: 'absolute', left: '1.2rem', right: '1.2rem', bottom: '1.2rem', background: 'var(--scrim)', padding: '1.4rem 0.8rem 0.8rem 1.4rem' }}>
          {!live && (
            <div class="row">
              <span class="player-time">{clock(pos)}</span>
              <span style={{ width: '1.1rem', flex: 'none' }} />
              <div class="grow">
                <ProgressBar position={pos} duration={dur} buffered={Math.max(pos, player.bufferedTo)} onTap={c.togglePlay} />
              </div>
              <span style={{ width: '1.1rem', flex: 'none' }} />
              <span class="player-time">{'−' + clock(dur - pos)}</span>
              <span style={{ width: '0.8rem', flex: 'none' }} />
            </div>
          )}
          {live && now && (
            <div style={{ padding: '0 0.8rem 0.8rem 0.4rem' }}>
              <div class="ellipsis">
                <span class="muted">{t('onNow')} · </span>
                <b>{now.title}</b>
                {next && <span class="muted" style={{ marginLeft: '2.4rem' }}>{`${t('upNext')} · ${next.title}`}</span>}
              </div>
              <Bar value={epgProgress} />
            </div>
          )}
          <div class="row" data-fgroup>
            <div ref={dockPlayBox}>
              <DockButton icon={playing ? 'pause_rounded' : 'play_arrow_rounded'} label={t(playing ? 'pause' : 'play')} onTap={c.togglePlay} />
            </div>
            {!live && <DockButton icon="replay_10_rounded" label={t('back10')} onTap={() => c.seekBy(-SKIP)} />}
            {!live && <DockButton icon="forward_10_rounded" label={t('forward10')} onTap={() => c.seekBy(SKIP)} />}
            {c.isLive && items.length > 1 && <DockButton icon="skip_previous_rounded" label={t('previousChannel')} onTap={c.hasPrev ? () => c.go(-1) : undefined} />}
            {c.isLive && items.length > 1 && <DockButton icon="skip_next_rounded" label={t('nextChannel')} onTap={c.hasNext ? () => c.go(1) : undefined} />}
            <div class="grow" />
            {!c.isLive && c.hasNext && <DockButton icon="skip_next_rounded" label={t('nextEpisode')} onTap={() => c.go(1)} />}
            {c.isLive && item.ref && <FavoriteDockButton refOf={item.ref} />}
            {items.length > 1 && <DockButton icon="playlist_play_rounded" label={t(c.isLive ? 'playerChannels' : 'playerEpisodes')} onTap={() => c.openPanel((close) => <QueuePanel c={c} done={close} />)} />}
            <DockButton icon="subtitles_rounded" label={t('audioAndSubtitles')} onTap={openTracks} />
            <DockButton icon="aspect_ratio_rounded" label={t('pictureFit')} onTap={() => c.openPanel(() => <PicturePanel c={c} />)} />
            {!live && <DockButton icon="speed_rounded" label={t('speed')} onTap={openSpeed} />}
            <DockButton icon="bedtime_rounded" label={t('sleepTimer')} onTap={() => c.openPanel((done) => <SleepPanel done={done} live={c.isLive} />)} />
            <DockButton icon="tune_rounded" label={t('playerSettings')} onTap={() => c.openPanel(() => <SettingsPanel c={c} />)} />
          </div>
        </div>
      </div>
      {/* Voice Guide says which channel it landed on and what is on, as the channel changes */}
      {c.isLive && (
        <div aria-live="polite" style={{ position: 'absolute', width: '1px', height: '1px', overflow: 'hidden', clip: 'rect(0 0 0 0)' }}>
          {[channel && channel.number !== undefined ? `${channel.number} ${item.title}` : item.title, now ? `${t('onNow')}: ${now.title}` : ''].filter(Boolean).join(', ')}
        </div>
      )}
      {note && (
        <div class="player-top-pill">
          <div class="player-pill" style={{ padding: '1rem 1.8rem' }}>
            {note}
          </div>
        </div>
      )}
      {c.resumedFrom !== null && !c.failed && (
        <div class="player-top-pill">
          <div class="player-pill" style={{ padding: '0.3rem 0.3rem 0.3rem 1.8rem' }}>
            <span>{t('resumedFrom', { time: clock(c.resumedFrom) })}</span>
            <span style={{ width: '0.7rem' }} />
            <Focusable class="button" radius={999} onTap={c.startOver}>
              {t('startOver')}
            </Focusable>
          </div>
        </div>
      )}
      {c.info && <StreamInfo c={c} />}
      {introOffered && (
        <div ref={introBox} style={{ position: 'absolute', right: '2.8rem', bottom: c.visible ? '15rem' : '4rem' }}>
          <PrimaryButton icon="skip_next_rounded" label={t('skipIntro')} onPressed={c.skipIntro} />
        </div>
      )}
      {c.flash && (
        <div class="player-center">
          <div class="panel" style={{ borderRadius: '99.9rem', padding: '1.4rem 2.8rem', fontSize: 'calc(3.4rem * var(--text-scale))', fontWeight: 800 }}>
            {c.flash}
          </div>
        </div>
      )}
      {offered && (
        <div ref={nextBox} class="panel" style={{ position: 'absolute', right: '2.8rem', bottom: c.visible ? '15rem' : '4rem', width: '32rem', boxSizing: 'border-box', background: 'var(--scrim)', padding: '1.4rem 1.6rem' }}>
          <div class="muted" style={{ fontSize: 'calc(1.3rem * var(--text-scale))' }}>{t('nextEpisodeIn', { seconds: Math.ceil((dur - pos) / 1000) })}</div>
          <div class="clamp2" style={{ fontWeight: 700, marginTop: '0.4rem' }}>{items[c.index + 1].subtitle || items[c.index + 1].title}</div>
          <div class="wrap" style={{ marginTop: '1.2rem' }}>
            <PrimaryButton icon="play_arrow_rounded" label={t('playNow')} onPressed={() => c.go(1)} />
            <SecondaryButton label={t('cancel')} onPressed={c.cancelNext} />
          </div>
        </div>
      )}
      {c.failed && (
        <div class="player-center">
          <div class="panel" style={{ background: 'var(--scrim)', padding: '2.8rem', maxWidth: '42rem', textAlign: 'center' }}>
            <CapyStatus mood="video" size={68} />
            <h2 class="title-large" style={{ marginTop: '1.4rem' }}>
              {c.isLive ? t('channelUnavailable') : t('videoUnavailable')}
            </h2>
            <p class="muted" style={{ margin: '0.8rem 0 0', lineHeight: 1.4 }}>
              {t(FAIL_TEXT[c.failWhy || 'unknown'])}
            </p>
            <div class="wrap" style={{ justifyContent: 'center', marginTop: '1.6rem' }}>
              <span ref={retryBox}>
                <PrimaryButton icon="refresh_rounded" label={t('retry')} onPressed={c.retry} />
              </span>
              {c.isLive && c.hasNext && <SecondaryButton icon="skip_next_rounded" label={t('nextChannel')} onPressed={() => c.go(1)} />}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

/** A thin white progress line on a dim track. */
export function Bar({ value, height = 0.3 }: { value: number; height?: number }) {
  return (
    <div style={{ height: `${height}rem`, background: 'rgba(255,255,255,0.2)', borderRadius: `${height}rem`, marginTop: '0.8rem', overflow: 'hidden' }}>
      <div style={{ width: `${Math.min(1, Math.max(0, value)) * 100}%`, height: '100%', background: 'var(--text)' }} />
    </div>
  );
}

/** The big white play/pause in the middle, where the remote starts; a spinner in it while loading. */
function PlayButton({ playing, loading, onTap }: { playing: boolean; loading: boolean; onTap: () => void }) {
  return (
    <Focusable radius={38} scale={1.08} onTap={onTap} autofocus>
      <div style={{ width: '7.6rem', height: '7.6rem', borderRadius: '50%', background: 'var(--text)', color: 'var(--black)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        {loading ? <div class="spinner on-light" style={{ width: '3.4rem', height: '3.4rem', borderWidth: '0.3rem' }} /> : <Icon icon={playing ? 'pause_rounded' : 'play_arrow_rounded'} size={40} />}
      </div>
    </Focusable>
  );
}

function CircleButton({ icon, size, onTap }: { icon: string; size: number; onTap: () => void }) {
  return (
    <Focusable radius={size / 2} scale={1.08} onTap={onTap}>
      <div style={{ width: `${size / 10}rem`, height: `${size / 10}rem`, borderRadius: '50%', background: 'var(--scrim)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Icon icon={icon} size={size * 0.5} />
      </div>
    </Focusable>
  );
}

/** A button of the dock; without [onTap] it is greyed out and the remote passes it by. */
/** An icon alone, its name above it while it has the remote (as the app's tooltip). */
function DockButton({ icon, onTap, label }: { icon: string; onTap?: () => void; label?: string }) {
  return (
    <div class="dock-btn" style={{ margin: '0 0.2rem', flex: 'none' }}>
      <Focusable radius={999} scale={1.06} onTap={onTap} label={label}>
        <div style={{ display: 'flex', padding: '1rem', color: onTap ? undefined : 'rgba(255,255,255,0.3)' }}>
          <Icon icon={icon} size={26} />
        </div>
      </Focusable>
      {label && (
        <div class="dock-tip" aria-hidden="true">
          {label}
        </div>
      )}
    </div>
  );
}

/** Adds the channel playing to My list, or takes it off. */
function FavoriteDockButton({ refOf }: { refOf: MediaRef }) {
  const { library } = session();
  useNotifier(library);
  const on = library.isFavorite(refOf);
  return <DockButton icon={on ? 'favorite_rounded' : 'favorite_border_rounded'} label={on ? t('inMyList') : t('myList')} onTap={() => library.toggleFavorite(refOf)} />;
}

/**
 * The progress: played, loaded ahead (where the engine says) and a round thumb. A focus stop of
 * its own over the dock's buttons that grows when focused; left/right on it skip 10 s.
 */
function ProgressBar({ position, duration, buffered, onTap }: { position: number; duration: number; buffered: number; onTap: () => void }) {
  const [active, setActive] = useState(false);
  const frac = (ms: number) => (duration <= 0 ? 0 : Math.min(1, Math.max(0, ms / duration)));
  const played = frac(position);
  const height = active ? '0.8rem' : '0.5rem';
  const thumb = active ? 1.8 : 1.2;
  return (
    <div class="f pbar" tabIndex={-1} onClick={onTap} onFocus={() => setActive(true)} onBlur={() => setActive(false)}>
      <div class="pbar-box">
        <div class="pbar-line" style={{ width: '100%', height, background: 'rgba(255,255,255,0.24)' }} />
        <div class="pbar-line" style={{ width: `${frac(buffered) * 100}%`, height, background: 'rgba(255,255,255,0.38)' }} />
        <div class="pbar-line" style={{ width: `${played * 100}%`, height, background: 'var(--text)' }} />
        <div class="pbar-thumb" style={{ left: `${played * 100}%`, width: `${thumb}rem`, height: `${thumb}rem`, marginLeft: `${-thumb / 2}rem`, marginTop: `${-thumb / 2}rem` }} />
      </div>
    </div>
  );
}

function LiveBadge() {
  return (
    <div class="player-pill" style={{ flex: 'none', padding: '0.7rem 1.4rem' }}>
      <span class="player-live-dot" />
      <span style={{ marginLeft: '0.8rem', fontWeight: 800, letterSpacing: '0.12rem', fontSize: 'calc(1.2rem * var(--text-scale))' }}>{t('live')}</span>
    </div>
  );
}

/**
 * A solid panel at the right edge over a light barrier, so most of the picture stays in sight
 * (_SidePanel): audio and subtitles, or speed.
 */
function SidePanel({ children, long }: { children: ComponentChildren; long?: boolean }) {
  const box = useRef<HTMLDivElement>(null);
  // The router's dialog barrier, lighter here (Flutter's black38)
  useLayoutEffect(() => {
    const barrier = box.current && box.current.parentElement;
    if (barrier) barrier.style.background = 'rgba(0,0,0,0.38)';
  }, []);
  return (
    <div ref={box} class={'player-panel' + (long ? ' long' : '')}>
      <div class="panel">{children}</div>
    </div>
  );
}

function PanelTitle({ text }: { text: string }) {
  return (
    <h2 class="title-large" style={{ padding: '0.4rem 0.4rem 1rem' }}>
      {text}
    </h2>
  );
}

function RoundCheck({ selected }: { selected: boolean }) {
  return (
    <span
      style={{
        width: '2rem',
        height: '2rem',
        flex: 'none',
        marginLeft: '1.2rem',
        borderRadius: '50%',
        boxSizing: 'border-box',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        color: 'var(--black)',
        background: selected ? 'var(--text)' : 'transparent',
        border: selected ? 'none' : '0.15rem solid var(--subtle)',
      }}
    >
      {selected && <Icon icon="check_rounded" size={14} />}
    </span>
  );
}

/** One row of a side panel: muted unless selected, with a round check at the right. */
function Option({ label, selected, onTap, autofocus }: { label: string; selected: boolean; onTap: () => void; autofocus?: boolean }) {
  return (
    <div style={{ padding: '0.3rem 0' }}>
      <Focusable radius={14} scale={1.02} onTap={onTap} autofocus={autofocus}>
        <div class="row" style={{ padding: '1.3rem 1.4rem', background: selected ? 'rgba(255,255,255,0.1)' : 'transparent' }}>
          <span class="grow" style={{ fontSize: 'calc(1.5rem * var(--text-scale))', fontWeight: selected ? 700 : 500, color: selected ? 'var(--text)' : 'var(--muted)' }}>
            {label}
          </span>
          <RoundCheck selected={selected} />
        </div>
      </Focusable>
    </div>
  );
}

/** A row of a side panel that says what is set: OK goes on to the next value. Without [onTap], greyed out. */
function SettingRow({ label, value, onTap }: { label: string; value: string; onTap?: () => void }) {
  return (
    <div style={{ padding: '0.3rem 0' }}>
      <Focusable radius={14} scale={1.02} onTap={onTap}>
        <div class="row" style={{ padding: '1.3rem 1.4rem' }}>
          <span class="grow" style={{ fontSize: 'calc(1.5rem * var(--text-scale))', fontWeight: 500, color: onTap ? 'var(--muted)' : 'var(--subtle)' }}>
            {label}
          </span>
          <span style={{ flex: 'none', marginLeft: '1.2rem', fontSize: 'calc(1.5rem * var(--text-scale))', fontWeight: 700 }}>{value}</span>
        </div>
      </Focusable>
    </div>
  );
}

/** Audio and subtitles: the stream's tracks by language, the ones in use marked. Chosen, they stay ([c]). */
function TracksPanel({ c }: { c: Playback }) {
  useNotifier(player);
  useNotifier(settings);
  const scale = settings.subtitleScale;
  const band = settings.subtitleBackground;
  const audio = player.tracks.filter((tr) => tr.kind === 'audio');
  const text = player.tracks.filter((tr) => tr.kind === 'text');
  return (
    <SidePanel>
      <PanelTitle text={t('audio')} />
      {!audio.length && (
        <div class="muted" style={{ padding: '0.8rem' }}>
          {t('notAvailable')}
        </div>
      )}
      {audio.map((tr, i) => (
        <Option
          key={`a${tr.index}`}
          label={trackName(tr, i)}
          selected={tr.index === player.audio}
          autofocus={tr.index === player.audio}
          onTap={() => c.pickAudio(tr)}
        />
      ))}
      <div style={{ height: '1.8rem' }} />
      <PanelTitle text={t('subtitles')} />
      <Option label={t('off')} selected={player.text < 0} onTap={() => c.pickText('off')} />
      {text.map((tr, i) => (
        <Option key={`t${tr.index}`} label={trackName(tr, i)} selected={tr.index === player.text} onTap={() => c.pickText(tr)} />
      ))}
      {/* How subtitles look, whether or not this has any: they are for whatever plays next too */}
      <SettingRow
        label={t('subtitleSize')}
        value={`${scale} %`}
        onTap={() => settings.set({ subtitleScale: SUBTITLE_SCALES[(SUBTITLE_SCALES.indexOf(scale) + 1) % SUBTITLE_SCALES.length] })}
      />
      <SettingRow label={t('subtitleBackground')} value={band ? t('settingOn') : t('settingOff')} onTap={() => settings.set({ subtitleBackground: !band })} />
      {band ? (
        <SettingRow
          label={t('subtitleBandDarkness')}
          value={`${settings.subtitleBandDarkness} %`}
          onTap={() => settings.set({ subtitleBandDarkness: next(SUBTITLE_DARKNESS, settings.subtitleBandDarkness) })}
        />
      ) : (
        <SettingRow
          label={t('subtitleOutline')}
          value={settings.subtitleOutline ? t('settingOn') : t('settingOff')}
          onTap={() => settings.set({ subtitleOutline: !settings.subtitleOutline })}
        />
      )}
      <SettingRow
        label={t('subtitleLift')}
        value={settings.subtitleLift === 20 ? t('subtitleLiftHighest') : settings.subtitleLift === 10 ? t('subtitleLiftHigher') : t('subtitleLiftBottom')}
        onTap={() => settings.set({ subtitleLift: next(SUBTITLE_LIFTS, settings.subtitleLift) })}
      />
    </SidePanel>
  );
}

/** The one after [value] in [list], round to the first. */
function next(list: number[], value: number): number {
  return list[(list.indexOf(value) + 1) % list.length];
}

/** The technical details of what plays, over the picture (_StreamInfo): what the engine tells. */
function StreamInfo({ c }: { c: Playback }) {
  const [, tick] = useState(0);
  useEffect(() => {
    const timer = window.setInterval(() => tick((n) => n + 1), 1000);
    return () => clearInterval(timer);
  }, []);
  const d = player.details();
  const join = (...parts: (string | undefined)[]) => parts.filter((p) => p).join(' · ');
  const bits = (b?: number) => (!b ? '' : b >= 1e6 ? `${(b / 1e6).toFixed(1)} Mb/s` : `${Math.round(b / 1e3)} kb/s`);
  const channels = d.channels === 1 ? t('channelsMono') : d.channels === 2 ? t('channelsStereo') : d.channels === 3 ? '2.1' : d.channels === 6 ? '5.1' : d.channels === 8 ? '7.1' : d.channels ? `${d.channels}.0` : '';
  const buffer = player.bufferedTo - player.position;
  const rows: [string, string][] = [
    [t('infoVideo'), join(player.width > 0 ? `${player.width}×${player.height}` : '', d.videoCodec)],
    [t('audio'), join(d.audioCodec, channels, d.sampleRate ? `${Math.floor(d.sampleRate / 1000)} kHz` : '')],
    [t('infoDecoder'), player.engine === 'avplay' ? 'AVPlay' : 'Web'],
    [t('infoBitrate'), join(bits(d.videoBits), bits(d.audioBits))],
    [t('infoBuffer'), buffer > 0 ? `${(buffer / 1000).toFixed(1)} s` : ''],
    [t('infoCopy'), c.copyNote],
  ];
  return (
    <div class="panel player-stream-info" style={{ position: 'absolute', left: '2.8rem', top: '9rem', background: 'var(--scrim)', padding: '1rem 1.4rem' }}>
      {rows
        .filter((r) => r[1])
        .map((r) => (
          <div key={r[0]} class="row" style={{ padding: '0.2rem 0', fontSize: 'calc(1.3rem * var(--text-scale))' }}>
            <span class="muted" style={{ width: '13rem', flex: 'none' }}>
              {r[0]}
            </span>
            <span style={{ fontWeight: 600 }}>{r[1]}</span>
          </div>
        ))}
    </div>
  );
}

/** The player's settings for this viewing: the stream info, and where a series' intro is. */
function SettingsPanel({ c }: { c: Playback }) {
  useNotifier(c);
  const intro = c.intro;
  const mark = (at: number | null | undefined) => (at === null || at === undefined ? t('introNotMarked') : clock(at));
  return (
    <SidePanel>
      <PanelTitle text={t('playerSettings')} />
      <SettingRow label={t('streamInfo')} value={c.info ? t('settingOn') : t('settingOff')} onTap={() => c.setInfo(!c.info)} />
      {c.seriesTitle && (
        <div>
          <div style={{ height: '1.8rem' }} />
          <PanelTitle text={t('seriesIntro')} />
          <SettingRow label={t('introStart')} value={mark(intro && intro.start)} onTap={() => c.markIntro('start')} />
          <SettingRow label={t('introEnd')} value={mark(intro && intro.end)} onTap={() => c.markIntro('end')} />
          <SettingRow label={t('introClear')} value="" onTap={intro ? () => c.markIntro('clear') : undefined} />
        </div>
      )}
    </SidePanel>
  );
}

/**
 * The queue: a channel list or a series' episodes, the one playing marked and with the remote
 * (_QueuePanel). There can be thousands, so only the rows near the view are built, and only those
 * ask the guide what is on.
 */
function QueuePanel({ c, done }: { c: Playback; done: () => void }) {
  const { guide: holder, airing } = session();
  useNotifier(holder);
  useNotifier(airing); // what the provider says is on, for channels the guide leaves out
  const items = c.items;
  const playing = c.index;
  const win = useRowWindow(items.length, CHANNEL_ROW * PX, 0, playing);
  const box = useRef<HTMLDivElement | null>(null);
  useLayoutEffect(() => {
    if (box.current) box.current.scrollTop = Math.max(0, (playing - 2) * CHANNEL_ROW * PX);
  }, []);
  // What is on stays true with the panel left open
  const [, tick] = useState(0);
  useEffect(() => {
    const timer = window.setInterval(() => tick((n) => n + 1), 60000);
    return () => clearInterval(timer);
  }, []);
  const guide = holder.guide;
  const rows: number[] = [];
  for (let i = win.first; i < win.end; i++) rows.push(i);
  return (
    <SidePanel long>
      <PanelTitle text={t(c.isLive ? 'playerChannels' : 'playerEpisodes')} />
      {/* Past the panel's padding, so a focused row can grow without being clipped */}
      <div
        ref={(el) => {
          box.current = el;
          win.ref(el);
        }}
        class="vscroll"
        onScroll={win.onScroll}
        onFocusIn={(e: FocusEvent) => {
          const row = (e.target as HTMLElement).closest('[data-row]');
          if (row) win.focusRow(Number(row.getAttribute('data-row')));
        }}
        style={{ flex: `0 1 ${items.length * CHANNEL_ROW}rem`, minHeight: 0, overflowY: 'auto', overflowX: 'hidden', margin: '0 -1rem', padding: '0 1rem' }}
      >
        <div style={{ position: 'relative', height: `${items.length * CHANNEL_ROW}rem` }}>
          {rows.map((i) => {
            const item = items[i];
            const channel = item.channel;
            const now = !c.isLive ? undefined : channel ? airing.nowOn(channel, guide) : guide.nowOn(item.ref && item.ref.epg);
            return (
              <div key={i} data-row={i} style={{ position: 'absolute', left: 0, right: 0, top: `${i * CHANNEL_ROW}rem`, height: `${CHANNEL_ROW}rem` }}>
                <ChannelRow
                  number={channel && channel.number}
                  name={c.isLive ? item.title : item.subtitle || item.title}
                  now={now && now.title}
                  selected={i === playing}
                  onTap={() => {
                    done();
                    if (i !== playing) c.go(i - playing);
                  }}
                />
              </div>
            );
          })}
        </div>
      </div>
    </SidePanel>
  );
}

/** One channel of the list, of a height set by CHANNEL_ROW however long its name. */
function ChannelRow({ number, name, now, selected, onTap }: { number?: number; name: string; now?: string; selected: boolean; onTap: () => void }) {
  return (
    <div style={{ padding: '0.3rem 0' }}>
      <Focusable radius={14} scale={1.02} onTap={onTap} autofocus={selected}>
        <div class="row" style={{ height: `${CHANNEL_ROW - 0.6}rem`, padding: '0 1.4rem', boxSizing: 'border-box', background: selected ? 'rgba(255,255,255,0.1)' : 'transparent' }}>
          {number !== undefined && (
            <span class="muted" style={{ width: '5.4rem', flex: 'none', fontSize: 'calc(1.5rem * var(--text-scale))', fontWeight: 700 }}>
              {number}
            </span>
          )}
          <div class="grow">
            <div class="ellipsis" style={{ fontSize: 'calc(1.5rem * var(--text-scale))', fontWeight: selected ? 700 : 500, color: selected ? 'var(--text)' : 'var(--muted)' }}>
              {name}
            </div>
            {now && (
              <div class="ellipsis muted" style={{ fontSize: 'calc(1.2rem * var(--text-scale))', marginTop: '0.2rem' }}>
                {now}
              </div>
            )}
          </div>
          <RoundCheck selected={selected} />
        </div>
      </Focusable>
    </div>
  );
}

function fitLabel(fit: string): string {
  return fit === 'contain' ? t('fitContain') : fit === 'cover' ? t('fitCover') : fit === 'fill' ? t('fitFill') : fit; // "16:9"
}

/** How the picture fills the screen: what this engine can do, the panel open to try them one after another. */
function PicturePanel({ c }: { c: Playback }) {
  useNotifier(player);
  useNotifier(settings);
  const fits = player.fits;
  const current = fits.indexOf(settings.videoFit) >= 0 ? settings.videoFit : 'contain';
  return (
    <SidePanel>
      <PanelTitle text={t('pictureFit')} />
      {fits.map((f) => (
        <Option key={f} label={fitLabel(f)} selected={f === current} autofocus={f === current} onTap={() => c.pickFit(f)} />
      ))}
    </SidePanel>
  );
}

/**
 * Playback speed, on demand only. The <video> plays any rate; AVPlay only whole trick-play ones,
 * muted, so there it is normal or 2x.
 */
function SpeedPanel({ done }: { done: () => void }) {
  useNotifier(player);
  const rates = player.engine === 'web' ? [0.5, 0.75, 1, 1.25, 1.5, 2] : [1, 2];
  return (
    <SidePanel>
      <PanelTitle text={t('speed')} />
      {rates.map((r) => (
        <Option key={String(r)} label={r === 1 ? t('normalSpeed') : rateLabel(r)} selected={player.rate === r} autofocus={player.rate === r} onTap={() => {
            player.setRate(r);
            done();
          }} />
      ))}
    </SidePanel>
  );
}

// ---------------------------------------------------------------------------
// Sleep timer panel (side panel opened from the dock "bedtime" button)
// ---------------------------------------------------------------------------

function sleepLabel(minutes: SleepMinutes): string {
  if (minutes === 0) return t('off');
  if (minutes === 120) return '2 h';
  return t('minutes', { n: minutes });
}

/** Closes once something is chosen. "When it ends" is not offered live: a channel never ends. */
function SleepPanel({ done, live }: { done: () => void; live: boolean }) {
  useNotifier(sleepTimer);
  const mode = sleepTimer.mode;
  const current: SleepMinutes | 'atEnd' = mode.kind === 'off' || (live && mode.kind === 'atEnd') ? 0 : mode.kind === 'atEnd' ? 'atEnd' : mode.minutes;

  const pick = (v: SleepMinutes | 'atEnd') => {
    if (v === 'atEnd') sleepTimer.set({ kind: 'atEnd' });
    else if (v === 0) sleepTimer.set({ kind: 'off' });
    else sleepTimer.set({ kind: 'after', minutes: v, endsAt: Date.now() + v * 60000 });
    done();
  };

  return (
    <SidePanel>
      <PanelTitle text={t('sleepTimer')} />
      {(SLEEP_CHOICES as readonly number[]).map((m) => (
        <Option
          key={String(m)}
          label={sleepLabel(m as SleepMinutes)}
          selected={current === m}
          autofocus={current === m || (current === 0 && m === 0)}
          onTap={() => pick(m as SleepMinutes)}
        />
      ))}
      {!live && <Option key="atEnd" label={t('sleepWhenItEnds')} selected={current === 'atEnd'} onTap={() => pick('atEnd')} />}
    </SidePanel>
  );
}

// ---------------------------------------------------------------------------
// Sleep prompt: "Still watching?" countdown shown before sleep fires
// ---------------------------------------------------------------------------

const STILL_WATCHING_SECS = 60;

function TimeUpPrompt({ done, noPin }: { done: (more: boolean) => void; noPin?: boolean }) {
  return (
    <div class="panel" style={{ padding: '2.8rem', maxWidth: '44rem', textAlign: 'center' }}>
      <Icon icon="hourglass_bottom_rounded" size={40} />
      <h2 class="title-large" style={{ marginTop: '1.4rem' }}>{t('timeUp')}</h2>
      <p class="muted" style={{ margin: '0.8rem 0 0', lineHeight: 1.4 }}>{noPin ? t('moreTimeNeedsPin') : t('timeUpHint')}</p>
      <div class="wrap" style={{ justifyContent: 'center', marginTop: '1.6rem' }}>
        <PrimaryButton icon="close_rounded" label={t('exitPlayer')} onPressed={() => done(false)} autofocus />
        {!noPin && <SecondaryButton icon="more_time_rounded" label={t('moreTime')} onPressed={() => done(true)} />}
      </div>
    </div>
  );
}

function SleepPrompt({ done }: { done: (keepWatching: boolean) => void }) {
  const [secs, setSecs] = useState(STILL_WATCHING_SECS);

  useEffect(() => {
    const iv = window.setInterval(() => {
      setSecs((s) => {
        if (s <= 1) {
          clearInterval(iv);
          done(false);
          return 0;
        }
        return s - 1;
      });
    }, 1000);
    return () => clearInterval(iv);
  }, []);

  return (
    <div class="panel" style={{ padding: '2.8rem', maxWidth: '44rem', textAlign: 'center' }}>
      <Icon icon="bedtime_rounded" size={40} />
      <h2 class="title-large" style={{ marginTop: '1.4rem' }}>{t('sleepStillWatching')}</h2>
      <p class="muted" style={{ margin: '0.8rem 0 0', lineHeight: 1.4 }}>
        {t('sleepStillWatchingHint', { seconds: secs })}
      </p>
      <div class="wrap" style={{ justifyContent: 'center', marginTop: '1.6rem' }}>
        <PrimaryButton icon="play_arrow_rounded" label={t('keepWatching')} onPressed={() => done(true)} />
        <SecondaryButton icon="close_rounded" label={t('exitPlayer')} onPressed={() => done(false)} />
      </div>
    </div>
  );
}
