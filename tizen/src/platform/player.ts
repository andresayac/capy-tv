// Playback with two engines. AVPlay, the TV's own player, comes first: hardware decoding of
// everything the Flutter app plays with mpv, minus DTS (no Samsung TV since 2018 decodes it).
// What AVPlay refuses (some providers' AES-128 HLS) goes to hls.js on the browser's <video>,
// which decrypts and remuxes it itself. In a desktop browser only the second exists.
//
// A stream that breaks off after it started only turns the state to 'error' here: the player
// screen opens it again, with pauses and a limit, as the Flutter app does.
import Hls from 'hls.js/dist/hls.js';
import { stableHash } from '../data/source';
import { log } from '../log';
import { Notifier } from '../ui/components';
import { isTizen, webapisOrNull } from './tv';

export type PlayerState = 'idle' | 'opening' | 'playing' | 'paused' | 'ended' | 'error';

export interface Track {
  index: number;
  kind: 'audio' | 'text';
  /** ISO 639 code as the stream gives it ("spa", "esa", "en"), or "" */
  language: string;
  /** The track's own name where the stream gives one (an HLS rendition's NAME, "Latino"); AVPlay gives none. */
  title?: string;
  channels?: number;
}

/**
 * The tracks to start on, given the stream's and those in use (-1 = none): asked once they are
 * known and before the stream plays, so it does not start in one language and switch a moment
 * later (mpv's alang/slang in the Flutter app).
 */
export type TrackChooser = (tracks: Track[], audio: number, text: number) => { audio?: number; text?: number };

export interface OpenOptions {
  /** The User-Agent the stream needs (an M3U entry's #EXTVLCOPT); only AVPlay can send one. */
  userAgent?: string;
  choose?: TrackChooser;
}

type Engine = 'avplay' | 'web';

/** What AVPlay answers for a stream it cannot play at all, from prepareAsync or its listener (see openAvplay). */
const CANNOT_PLAY = /^prepare: .*PLAYER_ERROR_NOT_SUPPORTED_FILE/;

interface WebOnlyMark {
  hash: string;
  at: number;
}

/**
 * Streams AVPlay cannot play, by a hash of their address: it takes seconds to refuse, so for a
 * month they go straight to hls.js. Kept on this TV only.
 */
const webOnly = {
  key: 'player.webOnly',
  MAX: 500,
  MAX_AGE: 30 * 24 * 3600 * 1000,
  /** Those in force. The plain hashes of earlier versions marked any failure at all: dropped. */
  list(): WebOnlyMark[] {
    try {
      const oldest = Date.now() - this.MAX_AGE;
      return (JSON.parse(localStorage.getItem(this.key) || '[]') as WebOnlyMark[]).filter((x) => x && x.hash && x.at > oldest);
    } catch {
      return [];
    }
  },
  save(list: WebOnlyMark[]): void {
    try {
      localStorage.setItem(this.key, JSON.stringify(list));
    } catch {
      // Storage full: AVPlay is asked again next time
    }
  },
  has(url: string): boolean {
    const hash = stableHash(url);
    return this.list().some((x) => x.hash === hash);
  },
  remove(url: string): void {
    const hash = stableHash(url);
    this.save(this.list().filter((x) => x.hash !== hash));
  },
  add(url: string): void {
    const hash = stableHash(url);
    this.save(this.list().filter((x) => x.hash !== hash).concat([{ hash, at: Date.now() }]).slice(-this.MAX));
  },
};

/** How the picture can fill the screen, under the values of the Flutter app's videoFit setting. */
export const PICTURE_FITS = ['contain', 'cover', 'fill', '16:9', '4:3', '21:9'];

const FIT_SHAPES: Record<string, number> = { '16:9': 16 / 9, '4:3': 4 / 3, '21:9': 21 / 9 };

/** Where the picture goes: the whole screen, or a shape of its own centred on it. */
function fitRect(fit: string | null): { x: number; y: number; w: number; h: number } {
  const shape = (fit && FIT_SHAPES[fit]) || 16 / 9;
  const w = shape >= 16 / 9 ? 1920 : Math.round(1080 * shape);
  const h = shape >= 16 / 9 ? Math.round(1920 / shape) : 1080;
  return { x: Math.floor((1920 - w) / 2), y: Math.floor((1080 - h) / 2), w, h };
}

/** How long a seek on AVPlay is waited for: on a slow line one may take many seconds. */
const SEEK_WAIT = 30000;

/* eslint-disable @typescript-eslint/no-explicit-any */
export interface StreamDetails {
  videoCodec?: string;
  videoBits?: number;
  audioCodec?: string;
  channels?: number;
  sampleRate?: number; // Hz
  audioBits?: number;
}

class Player extends Notifier {
  state: PlayerState = 'idle';
  buffering = false;
  /** What failed, as the engine names it (PLAYER_ERROR_CONNECTION_FAILED, manifestLoadError…). */
  error = '';
  /** The subtitle line on screen now. */
  subtitle = '';
  tracks: Track[] = [];
  audio = -1;
  text = -1; // -1 = subtitles off
  width = 0;
  height = 0;
  /** Playback speed; kept from one stream to the next until the player screen closes. */
  rate = 1;
  engine: Engine = isTizen ? 'avplay' : 'web';
  private fit: string | null = null; // one of PICTURE_FITS; null: nothing picked, the engine's own
  private video: HTMLVideoElement | null = null;
  private hls: Hls | null = null;
  private seq = 0; // a newer open() makes the callbacks of an older one stale
  // AVPlay hands each subtitle line with how long it shows: it goes then, unless the next comes first
  private subtitleTimer = 0;
  private subtitleEnds = 0;
  private subtitleLeft = 0; // what was left of the line when paused
  // AVPlay wants one seek answered before the next: one under way, and the latest asked meanwhile
  private seekBusy = false;
  private seekNext = -1;
  private seekTimer = 0;
  private seekId = 0; // an answer that comes after its time is not taken for the next one's
  private seekAt = 0; // when the <video> was last sent somewhere
  /** Whether the last seek was answered as done, rather than refused or never answered. */
  seekLanded = true;

  private get av(): any {
    const w = webapisOrNull();
    return w && w.avplay;
  }

  private set(changes: Partial<Player>): void {
    Object.assign(this, changes);
    this.notify();
  }

  /** Opens and plays [url]; resolves once it plays, rejects when no engine opens it. [unmarked]: its webOnly mark just went. */
  async open(url: string, opts: OpenOptions = {}, unmarked = false): Promise<void> {
    this.stop();
    const seq = ++this.seq;
    this.set({ state: 'opening', error: '', subtitle: '', tracks: [], audio: -1, text: -1, buffering: true, width: 0, height: 0 });
    const started = Date.now();
    let error = '';
    // A stream that needs its own User-Agent always goes to AVPlay first: hls.js cannot send one
    const marked = isTizen && !unmarked && !opts.userAgent && webOnly.has(url);
    if (isTizen && !marked) {
      try {
        await this.openAvplay(url, seq, opts);
        log(`player: AVPlay in ${Date.now() - started} ms, ${this.width}x${this.height}, ${this.tracks.length} tracks`);
        return;
      } catch (e) {
        if (seq !== this.seq) throw e;
        error = (e as Error).message;
        log(`player: AVPlay: ${error}; trying hls.js`);
        this.closeAvplay();
      }
    }
    try {
      await this.openWeb(url, seq, opts.choose);
      // Only what AVPlay cannot play: a dropped connection says nothing about the next time. And not
      // one with a User-Agent: hls.js got it without, and AVPlay stays the one to try
      if (CANNOT_PLAY.test(error) && !opts.userAgent) webOnly.add(url);
      log(`player: hls.js in ${Date.now() - started} ms, ${this.width}x${this.height}`);
    } catch (e) {
      if (seq !== this.seq) throw e;
      const name = error || (e as Error).message;
      log(`player: hls.js: ${(e as Error).message}`);
      // Sent here by a mark and hls.js cannot: the mark goes, and AVPlay gets its turn, once
      if (marked) {
        webOnly.remove(url);
        return this.open(url, opts, true);
      }
      this.set({ state: 'error', error: name, buffering: false });
      throw new Error(name);
    }
  }

  private openAvplay(url: string, seq: number, opts: OpenOptions): Promise<void> {
    const av = this.av;
    this.engine = 'avplay';
    return new Promise((resolve, reject) => {
      let step = 'open';
      const fail = (name: string) => reject(new Error(`${step}: ${name}`));
      try {
        av.open(url);
        step = 'properties';
        if (opts.userAgent) av.setStreamingProperty('USER_AGENT', opts.userAgent);
        av.setDisplayRect(0, 0, 1920, 1080);
        this.applyFit();
        step = 'listener';
        av.setListener({
          onbufferingstart: () => seq === this.seq && this.set({ buffering: true }),
          onbufferingcomplete: () => seq === this.seq && this.set({ buffering: false }),
          oncurrentplaytime: () => seq === this.seq && this.notify(),
          onsubtitlechange: (duration: number, text: string) => seq === this.seq && this.showSubtitle((text || '').trim(), Number(duration)),
          onstreamcompleted: () => seq === this.seq && this.set({ state: 'ended' }),
          onerror: (type: string) => {
            if (seq !== this.seq) return;
            if (this.state === 'opening') fail(String(type));
            else this.set({ state: 'error', error: String(type), buffering: false });
          },
          onevent: () => {},
        });
        step = 'prepare';
        av.prepareAsync(
          () => {
            if (seq !== this.seq) return;
            this.readAvplayTracks();
            // READY: the tracks can be picked before the first frame, though some firmware wants PLAYING
            const picked = this.applyChoice(opts.choose);
            av.play();
            this.applyFit(); // nothing promises that a mode set before prepare is kept
            if (!picked) this.applyChoice(opts.choose);
            this.set({ state: 'playing', buffering: false });
            if (this.rate !== 1) this.applyRate();
            resolve();
          },
          (e: any) => fail(e ? `${e.name} ${e.message}` : 'PLAYER_ERROR'),
        );
      } catch (e) {
        fail(`${(e as any).name} ${(e as any).message}`);
      }
    });
  }

  private readAvplayTracks(): void {
    const tracks: Track[] = [];
    let width = 0;
    let height = 0;
    let audio = -1;
    let text = -1;
    try {
      for (const t of this.av.getTotalTrackInfo()) {
        let info: any = {};
        try {
          info = JSON.parse(t.extra_info);
        } catch {
          // Not JSON on some streams
        }
        if (t.type === 'VIDEO') {
          width = Number(info.Width) || 0;
          height = Number(info.Height) || 0;
        } else if (t.type === 'AUDIO') {
          tracks.push({ index: t.index, kind: 'audio', language: (info.language || '').trim(), channels: Number(info.channels) || undefined });
        } else if (t.type === 'TEXT') {
          tracks.push({ index: t.index, kind: 'text', language: (info.track_lang || '').trim() });
        }
      }
      // What AVPlay picked by itself, a default subtitle track included: just opened, it is not silenced
      for (const c of this.av.getCurrentStreamInfo()) {
        if (c.type === 'AUDIO') audio = c.index;
        else if (c.type === 'TEXT') text = c.index;
      }
    } catch {
      // Whatever was read
    }
    if (text >= 0 && !tracks.some((tr) => tr.kind === 'text' && tr.index === text)) text = -1;
    this.set({ tracks, audio, text, width, height });
  }

  /** What the engine tells of the stream as it plays now, for the stream info. */
  details(): StreamDetails {
    const d: StreamDetails = {};
    try {
      if (this.engine === 'avplay') {
        for (const s of this.av.getCurrentStreamInfo()) {
          const info = JSON.parse(s.extra_info || '{}');
          if (s.type === 'VIDEO') {
            d.videoCodec = info.fourCC;
            d.videoBits = Number(info.Bit_rate) || undefined;
          } else if (s.type === 'AUDIO') {
            d.audioCodec = info.fourCC;
            d.channels = Number(info.channels) || undefined;
            d.sampleRate = Number(info.sample_rate) || undefined;
            d.audioBits = Number(info.bit_rate) || undefined;
          }
        }
      } else if (this.hls && this.hls.currentLevel >= 0) {
        const level = this.hls.levels[this.hls.currentLevel];
        d.videoCodec = level.videoCodec;
        d.videoBits = level.bitrate || undefined;
        d.audioCodec = level.audioCodec;
      }
    } catch {
      // Whatever was read
    }
    return d;
  }

  /** Starts on the tracks [choose] picks; false when the engine refused them (AVPlay before playing, on some firmware). */
  private applyChoice(choose: TrackChooser | undefined): boolean {
    if (!choose) return true;
    const pick = choose(this.tracks, this.audio, this.text);
    try {
      if (pick.audio !== undefined && pick.audio !== this.audio) this.selectAudio(pick.audio);
      if (pick.text !== undefined && pick.text !== this.text) this.selectText(pick.text);
      return true;
    } catch {
      return false;
    }
  }

  private closeAvplay(): void {
    try {
      const s = this.av.getState();
      if (s !== 'NONE' && s !== 'IDLE') this.av.stop();
      this.av.close();
    } catch {
      // Already closed
    }
  }

  /** The page's <video>, under the screens like AVPlay's plane. */
  private videoElement(): HTMLVideoElement {
    if (!this.video) {
      const v = document.createElement('video');
      v.style.cssText = 'position:absolute;left:0;top:0;width:1920px;height:1080px;background:#000';
      document.body.insertBefore(v, document.body.firstChild);
      v.ontimeupdate = () => this.notify();
      v.onprogress = () => this.notify();
      v.onwaiting = () => this.set({ buffering: true });
      v.onplaying = () => this.set({ buffering: false, state: 'playing' });
      v.onpause = () => this.state === 'playing' && this.set({ state: 'paused' });
      v.onended = () => this.set({ state: 'ended' });
      // A plain file that breaks off once playing (hls.js reports its own through its events)
      v.onerror = () => {
        if (this.engine !== 'web' || this.hls || !v.getAttribute('src')) return;
        if (this.state === 'playing' || this.state === 'paused') {
          this.set({ state: 'error', error: `MEDIA_ERR_${v.error ? v.error.code : 0}`, buffering: false });
        }
      };
      this.video = v;
    }
    return this.video;
  }

  /**
   * hls.js on the <video>. Xtream panels serve every live channel as HLS too: a ".ts" address is
   * asked as ".m3u8". Anything else that is not HLS goes to the <video> as it is.
   */
  private openWeb(url: string, seq: number, choose?: TrackChooser): Promise<void> {
    this.engine = 'web';
    const v = this.videoElement();
    v.style.display = '';
    this.applyFit();
    const hlsUrl = /\/live\/[^/]+\/[^/]+\/\d+\.ts$/.test(url) ? url.replace(/\.ts$/, '.m3u8') : url;
    const isHls = /\.m3u8(\?|$)/.test(hlsUrl);
    if (!isHls || !Hls.isSupported()) {
      v.src = url;
      return v.play().then(() => {
        if (seq !== this.seq) return;
        this.set({ state: 'playing', buffering: false, width: v.videoWidth, height: v.videoHeight });
        if (this.rate !== 1) this.applyRate();
      });
    }
    return new Promise((resolve, reject) => {
      const hls = new Hls({ enableWorker: true, lowLatencyMode: false, backBufferLength: 30 });
      this.hls = hls;
      let started = false;
      let mended = 0; // when a media error was last mended in place
      hls.on(Hls.Events.ERROR, (_e, data) => {
        if (seq !== this.seq || !data.fatal) return;
        if (!started) return reject(new Error(data.details));
        // A decoding hiccup now and then is mended in place; anything else, a network error that
        // outlasted hls.js's own retries included, goes to the screen, which opens it again
        if (data.type === Hls.ErrorTypes.MEDIA_ERROR && Date.now() - mended > 10000) {
          mended = Date.now();
          hls.recoverMediaError();
          return;
        }
        this.set({ state: 'error', error: data.details, buffering: false });
      });
      hls.on(Hls.Events.MANIFEST_PARSED, () => {
        if (seq !== this.seq) return;
        // The renditions are known by now: start on the chosen ones rather than switch after
        this.readWebTracks();
        this.applyChoice(choose);
        v.play().catch(() => {});
      });
      hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, () => seq === this.seq && this.readWebTracks());
      hls.on(Hls.Events.SUBTITLE_TRACKS_UPDATED, () => seq === this.seq && this.readWebTracks());
      v.addEventListener(
        'playing',
        () => {
          if (seq !== this.seq || started) return;
          started = true;
          this.readWebTracks();
          this.set({ state: 'playing', buffering: false, width: v.videoWidth, height: v.videoHeight });
          if (this.rate !== 1) this.applyRate();
          resolve();
        },
        { once: true },
      );
      hls.loadSource(hlsUrl);
      hls.attachMedia(v);
    });
  }

  private readWebTracks(): void {
    const hls = this.hls;
    if (!hls) return;
    const tracks: Track[] = [];
    hls.audioTracks.forEach((t, i) =>
      tracks.push({ index: i, kind: 'audio', language: (t.lang || '').trim(), title: t.name || undefined, channels: Number(t.channels) || undefined }),
    );
    hls.subtitleTracks.forEach((t, i) => tracks.push({ index: i, kind: 'text', language: (t.lang || '').trim(), title: t.name || undefined }));
    this.set({ tracks, audio: hls.audioTrack, text: hls.subtitleDisplay ? hls.subtitleTrack : -1 });
  }

  get playing(): boolean {
    return this.state === 'playing';
  }

  /** Milliseconds played. */
  get position(): number {
    if (this.engine === 'web') return this.video ? this.video.currentTime * 1000 : 0;
    try {
      return this.av.getCurrentTime();
    } catch {
      return 0;
    }
  }

  /** Milliseconds in all; 0 for a live channel. */
  get duration(): number {
    if (this.engine === 'web') return this.video && isFinite(this.video.duration) ? this.video.duration * 1000 : 0;
    try {
      return this.av.getDuration();
    } catch {
      return 0;
    }
  }

  /** How far the stream is loaded from the position on, in ms of the title; 0 when the engine does not say (AVPlay). */
  get bufferedTo(): number {
    const v = this.video;
    if (this.engine !== 'web' || !v) return 0;
    const now = v.currentTime;
    try {
      for (let i = 0; i < v.buffered.length; i++) {
        if (v.buffered.start(i) <= now + 0.5 && v.buffered.end(i) >= now) return v.buffered.end(i) * 1000;
      }
    } catch {
      // No ranges yet
    }
    return 0;
  }

  playOrPause(): void {
    if (this.state === 'playing') this.pause();
    else if (this.state === 'paused') this.resume();
  }

  pause(): void {
    if (this.state !== 'playing') return;
    try {
      if (this.engine === 'avplay') this.av.pause();
      else if (this.video) this.video.pause();
    } catch {
      // Not in a state to pause
    }
    // The line on screen stays while paused, with what was left of its time
    if (this.subtitleTimer) {
      clearTimeout(this.subtitleTimer);
      this.subtitleTimer = 0;
      this.subtitleLeft = Math.max(0, this.subtitleEnds - Date.now());
    }
    this.set({ state: 'paused' });
  }

  resume(): void {
    if (this.state !== 'paused') return;
    try {
      if (this.engine === 'avplay') this.av.play();
      else if (this.video) this.video.play().catch(() => {});
    } catch {
      // Not in a state to play
    }
    const left = this.subtitleLeft;
    this.set({ state: 'playing' });
    if (this.subtitle && left) this.showSubtitle(this.subtitle, left);
    if (this.rate !== 1) this.applyRate();
  }

  /** A seek on its way, or waiting for the one before it; not one past SEEK_WAIT, as the <video> would say so for good. */
  get seeking(): boolean {
    return this.engine === 'avplay' ? this.seekBusy : !!this.video && this.video.seeking && Date.now() - this.seekAt < SEEK_WAIT;
  }

  seek(ms: number): void {
    const dur = this.duration;
    let to = Math.max(0, Math.min(ms, dur || ms));
    if (this.engine !== 'avplay') {
      this.seekLanded = true;
      this.seekAt = Date.now();
      if (this.video) this.video.currentTime = to / 1000;
    } else {
      // Samsung's FAQ: seekTo cannot go to the very start or the very end
      to = Math.max(1000, dur ? Math.min(to, dur - 1000) : to);
      if (this.seekBusy) this.seekNext = to;
      else this.seekAvplay(to);
    }
    // Last: it tells whoever listens, who must already find a seek under way
    this.clearSubtitle();
  }

  private seekAvplay(to: number): void {
    const id = ++this.seekId;
    this.seekBusy = true;
    const done = (landed: boolean) => {
      if (id !== this.seekId || !this.seekBusy) return;
      clearTimeout(this.seekTimer);
      this.seekBusy = false;
      this.seekLanded = landed;
      const next = this.seekNext;
      this.seekNext = -1;
      if (next >= 0) this.seekAvplay(next);
      else this.notify();
    };
    // Samsung does not promise either callback: a seek never answered must not hold the others
    this.seekTimer = window.setTimeout(() => done(false), SEEK_WAIT);
    try {
      this.av.seekTo(to, () => done(true), () => done(false));
    } catch {
      done(false); // not seekable now
    }
  }

  /**
   * Playback speed. The <video> takes any; AVPlay only whole trick-play rates (2, 4…), and
   * those muted, so the player offers it 2x at most.
   */
  setRate(rate: number): void {
    this.rate = rate;
    this.applyRate();
    this.notify();
  }

  private applyRate(): void {
    try {
      if (this.engine === 'avplay') {
        // A rate the <video> took (1.5x) that the next stream, on AVPlay, cannot: normal speed,
        // so the speed panel says what plays
        if (this.rate !== 1 && this.rate !== 2) this.rate = 1;
        if (this.state === 'playing' || this.state === 'paused') this.av.setSpeed(this.rate);
      } else if (this.video) {
        this.video.playbackRate = this.rate;
      }
    } catch {
      // Not at this rate, or not now
    }
  }

  /** The fits this engine can do: AVPlay has no mode that zooms and cuts the edges. */
  get fits(): string[] {
    return this.engine === 'avplay' ? PICTURE_FITS.filter((f) => f !== 'cover') : PICTURE_FITS;
  }

  /** How the picture fills the screen, now and on every stream opened after; null leaves it to the engine. */
  setFit(fit: string | null): void {
    this.fit = fit;
    this.applyFit();
  }

  private applyFit(): void {
    const fit = this.fit;
    const { x, y, w, h } = fitRect(fit);
    const shaped = !!fit && !!FIT_SHAPES[fit];
    if (this.engine === 'web') {
      if (!this.video) return;
      // A shape of its own is a box of that shape with the picture stretched into it
      const s = this.video.style;
      s.objectFit = fit === 'cover' ? 'cover' : fit === 'fill' || shaped ? 'fill' : '';
      s.left = `${x}px`;
      s.top = `${y}px`;
      s.width = `${w}px`;
      s.height = `${h}px`;
      return;
    }
    if (fit === null) return;
    // However the firmware takes these, the stream goes on playing
    try {
      this.av.setDisplayRect(x, y, w, h);
    } catch {
      // Not now
    }
    const modes = fit === 'fill' || shaped ? ['FULL_SCREEN'] : ['AUTO_ASPECT_RATIO', 'LETTER_BOX'];
    for (const mode of modes) {
      try {
        this.av.setDisplayMethod(`PLAYER_DISPLAY_MODE_${mode}`);
        return;
      } catch {
        // The next one, if there is one
      }
    }
  }

  selectAudio(index: number): void {
    if (this.engine === 'avplay') this.av.setSelectTrack('AUDIO', index);
    else if (this.hls) this.hls.audioTrack = index;
    this.set({ audio: index });
  }

  /** A subtitle track by index, or -1 for none. */
  selectText(index: number): void {
    if (this.engine === 'avplay') {
      if (index < 0) this.av.setSilentSubtitle(true);
      else {
        this.av.setSilentSubtitle(false);
        this.av.setSelectTrack('TEXT', index);
      }
    } else if (this.hls) {
      this.hls.subtitleDisplay = index >= 0;
      this.hls.subtitleTrack = index;
    }
    this.clearSubtitleTimer();
    this.set({ text: index, subtitle: '' });
  }

  /** A subtitle line from AVPlay, cleared after [ms] (its display time) unless another comes first. */
  private showSubtitle(line: string, ms: number): void {
    this.clearSubtitleTimer();
    if (line && ms > 0 && isFinite(ms)) {
      this.subtitleEnds = Date.now() + ms;
      if (this.state === 'paused') this.subtitleLeft = ms;
      else this.subtitleTimer = window.setTimeout(() => this.clearSubtitle(), ms);
    }
    this.set({ subtitle: line });
  }

  private clearSubtitleTimer(): void {
    clearTimeout(this.subtitleTimer);
    this.subtitleTimer = 0;
    this.subtitleLeft = 0;
  }

  private clearSubtitle(): void {
    this.clearSubtitleTimer();
    if (this.subtitle) this.set({ subtitle: '' });
  }

  stop(): void {
    this.seq++;
    this.seekId++;
    clearTimeout(this.seekTimer);
    this.seekBusy = false;
    this.seekNext = -1;
    this.clearSubtitleTimer();
    if (isTizen) this.closeAvplay();
    if (this.hls) {
      this.hls.destroy();
      this.hls = null;
    }
    if (this.video) {
      this.video.pause();
      this.video.removeAttribute('src');
      this.video.load();
      this.video.style.display = 'none';
    }
    if (this.state !== 'idle') this.set({ state: 'idle', buffering: false, subtitle: '' });
  }
}

export const player = new Player();
(window as unknown as { capyPlayer: Player }).capyPlayer = player; // for scripts/tv.mjs eval

// The TV puts the app away (Home, another source): it must let go of the decoder. The player
// screen brings the controls up, and opens a live channel afresh, when the app comes back.
document.addEventListener('visibilitychange', () => {
  if (document.hidden && player.state === 'playing') player.pause();
});
