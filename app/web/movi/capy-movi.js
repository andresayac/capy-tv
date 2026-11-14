// How the app plays a file in a browser: a <movi-player> inside a container the app shows, with
// the two things the panel's films were measured to need (2026-11-11):
//
//  - HevcFixSource: the newest MKVs are 10-bit HEVC labelled "Main". Every hardware decoder sets
//    itself up from that label and refuses the stream; relabelled "Main 10" as the bytes arrive,
//    they play. Software decoders ignore the label.
//  - the decode guard: a tablet's decoder may take the stream and still give no picture (an error,
//    no frames at all, or black ones). movi only falls back to software by itself when the
//    hardware refuses the codec up front, so the guard watches, and plays the film again in
//    software from the same point, in the same language.
//
// One host per app player (see lib/player/movi_player_web.dart). The container stays the same for
// the whole session: Flutter shows it once, and the <movi-player> inside comes and goes. That
// matters because the element builds its player when it enters the document and destroys it when
// it leaves.
//
// Everything the app needs to know is sent as one `capy` event on the container, whose detail is a
// snapshot of the player (time, length, size, state...) plus what happened (`type`).
import { HttpSource } from './element.js';

// ---------------------------------------------------------------------------------------------
// The HEVC label fix
//
// Same length in, same length out: only two bytes of each SPS (and of the hvcC header) change, so
// every offset the demuxer asks for stays where it was.
//
// Where the profile lives:
//  - hvcC (MKV CodecPrivate / MP4 hvcC box): byte 1 = profile_space(2) tier(1) profile_idc(5),
//    bytes 2..5 the compatibility flags, flag[j] being bit 31-j of them
//  - every SPS NAL (type 33): byte 3 = the same profile byte, byte 4 the first flag byte. An encoder
//    repeats the SPS before every keyframe, and the decoder believes the latest one, so all of them
//    have to change, not only the header's.

const MAIN = 1;
const MAIN10 = 2;
/** Bytes read on each side of what was asked, so an SPS cut by the edge of a read is still seen. */
const MARGIN = 16;
const SPS_PREFIX = 12;

const indexOf = (hay, needle, from) => {
  const first = needle[0];
  outer: for (let i = from; i <= hay.length - needle.length; i++) {
    if (hay[i] !== first) continue;
    for (let k = 1; k < needle.length; k++) if (hay[i + k] !== needle[k]) continue outer;
    return i;
  }
  return -1;
};

/** The hvcC of a 10-bit stream labelled Main, and the SPS it carries; null when not this case. */
const findHvcc = (b) => {
  for (let i = 0; i + 23 < b.length; i++) {
    // version 1, profile idc Main, 4:2:0, luma and chroma 10-bit
    if (b[i] !== 0x01 || (b[i + 1] & 0x1f) !== MAIN || b[i + 16] !== 0xfd || b[i + 17] !== 0xfa || b[i + 18] !== 0xfa) continue;
    let p = i + 23;
    const arrays = b[i + 22];
    for (let a = 0; a < arrays && p + 3 <= b.length; a++) {
      const type = b[p] & 0x3f;
      const count = (b[p + 1] << 8) | b[p + 2];
      p += 3;
      for (let n = 0; n < count && p + 2 <= b.length; n++) {
        const len = (b[p] << 8) | b[p + 1];
        p += 2;
        if (type === 33 && len >= SPS_PREFIX && p + SPS_PREFIX <= b.length) {
          return { at: i, sps: b.slice(p, p + SPS_PREFIX) };
        }
        p += len;
      }
    }
  }
  return null;
};

const relabel = (b, at) => {
  b[at] = (b[at] & 0xe0) | MAIN10;
  // Main 10 compatible on, Main off: a 10-bit stream cannot be decoded as Main
  b[at + 1] = (b[at + 1] | 0x20) & ~0x40;
};

export class HevcFixSource extends HttpSource {
  /** The first bytes of the stream's SPS as the encoder wrote it; null until the header is read. */
  sps = null;
  checkedHeader = false;
  fixed = 0;

  fix(bytes) {
    if (!this.checkedHeader) {
      const found = findHvcc(bytes);
      if (found) this.sps = found.sps;
      // The header is in the first read; a stream without the hvcC there is not one of these
      this.checkedHeader = true;
    }
    if (!this.sps) return bytes;
    const header = findHvcc(bytes);
    if (header) relabel(bytes, header.at + 1);
    for (let i = indexOf(bytes, this.sps, 0); i >= 0; i = indexOf(bytes, this.sps, i + 1)) {
      relabel(bytes, i + 3);
      this.fixed++;
    }
    return bytes;
  }

  async read(offset, length) {
    const size = this.getKnownSize ? this.getKnownSize() : 0;
    const from = Math.max(0, offset - MARGIN);
    const to = size > 0 ? Math.min(size, offset + length + MARGIN) : offset + length + MARGIN;
    const wide = new Uint8Array(await super.read(from, to - from));
    this.fix(wide);
    const start = offset - from;
    return wide.slice(start, start + Math.min(length, wide.length - start)).buffer;
  }

  // The player also peeks at bytes it already has, without a read: those must be fixed too
  peekHead(offset, length) { return this.peekFixed('peekHead', offset, length); }
  peekMetadata(offset, length) { return this.peekFixed('peekMetadata', offset, length); }
  peekRange(offset, length) { return this.peekFixed('peekRange', offset, length); }

  peekFixed(name, offset, length) {
    const from = Math.max(0, offset - MARGIN);
    const wide = super[name](from, length + (offset - from) + MARGIN);
    if (wide && wide.length >= length + (offset - from)) {
      return this.fix(new Uint8Array(wide)).subarray(offset - from, offset - from + length);
    }
    // The margin is not there yet: fix what was asked for, as it is
    const exact = super[name](offset, length);
    return exact ? this.fix(new Uint8Array(exact)) : null;
  }

  // A shared buffer would hand the demuxer the bytes as they came; with none it reads through us
  getSharedBuffer() { return null; }
}

// ---------------------------------------------------------------------------------------------
// The decode guard's limits

const TICK_MS = 500;
/** Seconds of film played with no new frame before the picture counts as stuck. */
const STUCK_LIMIT = 3;
/** Seconds of film played on black frames alone before the decoder counts as blind. */
const BLACK_LIMIT = 10;
/** Waiting this long with no new frame, while SOUND_READY seconds of sound are decoded, blames the decoder. */
const WAIT_LIMIT_MS = 4000;
const SOUND_READY = 5;
/** A frame whose brightest sampled pixel is darker than this is black. */
const BLACK_LUMA = 20;
const DECODE_ERROR = /decod|encodingerror|operationerror|codec/i;

/** The element's events the app hears of, as a `capy` event with a fresh snapshot. */
const FORWARDED = [
  'play', 'pause', 'playing', 'waiting', 'ended', 'timeupdate', 'durationchange', 'resize',
  'volumechange', 'ratechange', 'seeking', 'seeked', 'statechange', 'loadedmetadata', 'canplay',
  'progress', 'trackschange', 'audiotrackchange', 'subtitletrackchange',
];
/** Events after which the track lists are sent along. */
const TRACK_EVENTS = new Set(['trackschange', 'audiotrackchange', 'subtitletrackchange', 'loadedmetadata', 'canplay', 'playing']);
/** The time is sent this often at most while playing: more is redrawing the screen for nothing. */
const TIME_EVERY_MS = 250;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class CapyMoviHost {
  constructor(container) {
    this.container = container;
    this.el = null;
    this.mode = 'hardware';
    this.session = 0;
    this.volume = 1;
    this.muted = false;
    this.rate = 1;
    this.fit = 'contain';
    this.switched = null; // why it went to software, once it has
    this.timer = 0;
    this.wantPlay = false;
    this.sampler = 0;
    this.sampleVideo = null;
    this.luma = null;
    this.lastTimeSent = 0;
    this.tracksSent = '';
  }

  /**
   * Plays [url]. opts: start (s), hardware (false starts in software), fix (false skips the HEVC
   * fix), headers, paused (opens without playing).
   */
  async open(url, opts = {}) {
    this.close();
    const session = ++this.session;
    this.url = url;
    this.opts = opts;
    this.switched = null;
    this.wantPlay = !opts.paused;
    // Tracks to put on once the element has read the file: the file's own defaults for now
    this.wantAudio = null;
    this.wantSub = undefined;
    // The element only builds its player inside the document: Flutter may not have put the
    // container there yet on the first open
    for (let i = 0; i < 200 && !this.container.isConnected; i++) {
      await sleep(50);
      if (session !== this.session) return;
    }
    if (session !== this.session) return;
    this.mount(opts.hardware === false ? 'software' : 'hardware', opts.start || 0, null, undefined, !opts.paused);
  }

  /** Lets go of the film; the container stays, empty. */
  close() {
    this.session++;
    this.unmount();
    this.source = null;
  }

  mount(mode, at, audio, sub, play) {
    this.unmount();
    this.mode = mode;
    const el = document.createElement('movi-player');
    if (play) el.setAttribute('autoplay', '');
    // Its own remembered volume, speed and languages would fight the app's
    el.setAttribute('persist', 'none');
    el.setAttribute('nohotkeys', '');
    el.setAttribute('doubletap', 'false');
    el.setAttribute('playsinline', '');
    el.setAttribute('tabindex', '-1');
    el.setAttribute('objectfit', this.fit);
    el.setAttribute('volume', String(this.volume));
    if (this.muted) el.setAttribute('muted', '');
    if (this.rate !== 1) el.setAttribute('playbackrate', String(this.rate));
    if (mode === 'software') el.setAttribute('sw', '');
    if (at > 0) el.setAttribute('startat', String(at));
    // The app's own widgets take every touch, click and key: the picture is only a picture
    el.style.cssText = 'display:block;width:100%;height:100%;pointer-events:none;outline:none';

    this.errors = [];
    this.waits = 0;
    for (const name of FORWARDED) {
      el.addEventListener(name, (e) => {
        if (el !== this.el) return; // one that was let go
        if (name === 'statechange' && e.detail === 'buffering') this.waits++;
        if (name === 'timeupdate') {
          const now = performance.now();
          if (now - this.lastTimeSent < TIME_EVERY_MS) return;
          this.lastTimeSent = now;
        }
        this.emit(name);
      });
    }
    el.addEventListener('error', (e) => {
      if (el !== this.el) return;
      const message = String((e.detail && (e.detail.message || e.detail)) || 'error');
      this.errors.push(message);
      // On hardware a decoder's error is the guard's to mend, not the app's to show
      if (this.mode === 'hardware' && DECODE_ERROR.test(message)) return this.check();
      this.emit('error', { message });
    });
    // The screen movi paints when it gives up, with no error event: a codec the hardware will not
    // take up front (an Xvid AVI) offers its "Try software decoding" button, which is the guard's
    // to press; anything else is the app's to say, now rather than when its wait runs out
    el.addEventListener('errordisplay', (e) => {
      if (el !== this.el) return;
      const d = e.detail || {};
      if (this.mode === 'hardware' && d.canTrySoftware) return this.toSoftware(`hardware refused: ${d.title || 'format'}`);
      const message = [d.title, d.message].filter(Boolean).join(': ') || 'error';
      this.errors.push(message);
      this.emit('error', { message });
    });

    // What the last element already read of the file: its head, so the new one starts from there
    // instead of fetching it again (seconds, through a proxy)
    const before = this.source;
    if (before && before.url === this.url && before.headBuffer && before.headFilled > 0) {
      try {
        HttpSource.offerWarmHead(this.url, before.headBuffer.slice(0, before.headFilled));
      } catch (e) {
        // Read again, then
      }
    }
    this.source = null;

    this.container.replaceChildren(el);
    this.el = el;
    // After it is in the document: a source set before would wait for nothing
    if (this.opts.fix === false) {
      el.src = this.url;
    } else {
      this.source = new HevcFixSource(this.url, this.opts.headers || {});
      el.sourceAdapter = this.source;
    }
    if (audio != null) this.wantAudio = audio;
    if (sub !== undefined) this.wantSub = sub;
    if (this.wantAudio != null || this.wantSub !== undefined) this.applyWanted(el);
    this.watch = { lastFrames: -1, frameAt: null, black: 0, sawPicture: false, lastT: null, waitFrames: null, waitSince: null };
    this.landed = false;
    if (mode === 'hardware') {
      this.sample();
      this.timer = setInterval(() => this.check(), TICK_MS);
    }
    this.watchSubtitles(el);
    this.emit('decoder', { why: this.switched || '' });
  }

  unmount() {
    clearInterval(this.timer);
    this.timer = 0;
    this.unsample();
    if (this.subtitleObserver) this.subtitleObserver.disconnect();
    this.subtitleObserver = null;
    clearTimeout(this.subtitleWait);
    this.subtitleSent = '';
    const el = this.el;
    this.el = null;
    this.tracksSent = '';
    if (el) el.remove();
  }

  /**
   * Text subtitles, for the app to draw in its own style. movi writes the current cue into an
   * overlay of its own, under the app's controls and in a grey of its choosing; that overlay is
   * made invisible and its text sent on as a `subtitle` event. A picture subtitle (a Blu-ray's)
   * is an image there, and stays movi's to show.
   */
  watchSubtitles(el) {
    let tries = 0;
    const attach = () => {
      if (el !== this.el) return;
      const overlay = el.subtitleOverlay;
      if (!overlay) {
        if (tries++ < 200) this.subtitleWait = setTimeout(attach, 300);
        return;
      }
      const send = () => {
        if (el !== this.el) return;
        const picture = !!overlay.querySelector('img, canvas');
        const opacity = picture ? '' : '0';
        if (overlay.style.opacity !== opacity) overlay.style.opacity = opacity;
        // opacity keeps the text laid out, so its lines still read as lines
        const text = picture ? '' : (overlay.innerText || '').split('\n').map((l) => l.trim()).filter(Boolean).join('\n');
        if (text === this.subtitleSent) return;
        this.subtitleSent = text;
        this.container.dispatchEvent(new CustomEvent('capy', { detail: { type: 'subtitle', subtitle: text } }));
      };
      this.subtitleObserver = new MutationObserver(send);
      this.subtitleObserver.observe(overlay, { childList: true, subtree: true, characterData: true });
      send();
    };
    attach();
  }

  // -------------------------------------------------------------------------------------------
  // What the app tells it

  // While it still reads the file the element goes by its autoplay once it is ready, whatever was
  // said meanwhile: the attribute follows the viewer too

  play() {
    this.wantPlay = true;
    const el = this.el;
    if (!el) return;
    el.setAttribute('autoplay', '');
    el.play().catch(() => {});
  }

  pause() {
    this.wantPlay = false;
    const el = this.el;
    if (!el) return;
    el.removeAttribute('autoplay');
    el.pause();
  }

  seek(t) {
    const el = this.el;
    if (!el) return;
    t = Math.max(0, t);
    let state = 'idle';
    try {
      state = (el.player && el.player.getState && el.player.getState()) || 'idle';
    } catch (e) {
      state = 'idle';
    }
    // Still reading the file: once read it goes to its startat, which would undo this seek. It
    // starts here instead
    if (!el.player || state === 'idle' || state === 'loading') {
      el.setAttribute('startat', String(t));
      return;
    }
    el.currentTime = t;
  }

  setVolume(v) {
    this.volume = Math.max(0, Math.min(1, v));
    if (this.el) this.el.volume = this.volume;
    this.emit('volumechange');
  }

  setMuted(m) {
    this.muted = !!m;
    if (this.el) this.el.muted = this.muted;
    this.emit('volumechange');
  }

  setRate(r) {
    this.rate = r > 0 ? r : 1;
    if (this.el) this.el.playbackRate = this.rate;
    this.emit('ratechange');
  }

  /** contain, cover, fill or zoom, as movi's objectfit. */
  setFit(fit) {
    this.fit = fit;
    if (this.el) this.el.setAttribute('objectfit', fit);
  }

  /** Whether [el] has read the file's tracks, so one can be picked. */
  static knowsTracks(el) {
    try {
      return !!(el && el.player && el.player.getAudioTracks && el.player.getAudioTracks().length > 0);
    } catch (e) {
      return false;
    }
  }

  selectAudio(id) {
    const el = this.el;
    if (!el) return false;
    // Not read yet (a software player taking over): it gets this one once it has
    if (!CapyMoviHost.knowsTracks(el)) {
      this.wantAudio = id;
      this.applyWanted(el);
      return true;
    }
    try {
      const ok = el.pickAudioTrack ? el.pickAudioTrack(id) : el.player.selectAudioTrack(id);
      this.emit('audiotrackchange');
      return ok !== false;
    } catch (e) {
      return false;
    }
  }

  /** [id] null for none. */
  async selectSubtitle(id) {
    if (id === undefined) id = null;
    const el = this.el;
    if (!el) return false;
    if (!CapyMoviHost.knowsTracks(el)) {
      this.wantSub = id;
      this.applyWanted(el);
      return true;
    }
    try {
      const ok = await (el.pickSubtitleTrack ? el.pickSubtitleTrack(id) : el.player.selectSubtitleTrack(id));
      this.emit('subtitletrackchange');
      return ok !== false;
    } catch (e) {
      return false;
    }
  }

  // -------------------------------------------------------------------------------------------
  // What it tells the app

  /**
   * Seconds of the film ready ahead of the play head. Not the element's `buffered`: movi works
   * that out from the bytes read, and once it has read the end of the file (where an MKV keeps
   * its index) it says the whole film is there. The sound it has decoded ahead is what is
   * really in hand.
   */
  ahead() {
    const p = this.el && this.el.player;
    return p ? this.soundReady(p) : 0;
  }

  snapshot(type) {
    const el = this.el, p = el && el.player;
    let state = 'idle';
    try {
      state = (p && p.getState && p.getState()) || 'idle';
    } catch (e) {
      state = 'idle';
    }
    const duration = el ? el.duration : 0;
    const t = el ? this.time(el, state) : 0;
    const buffered = Number.isFinite(duration) && duration > 0 ? Math.min(duration, t + this.ahead()) : t + this.ahead();
    return {
      type,
      t,
      duration: Number.isFinite(duration) ? duration : 0,
      buffered,
      paused: el ? el.paused : true,
      ended: el ? !!el.ended : false,
      state,
      w: el ? el.videoWidth || 0 : 0,
      h: el ? el.videoHeight || 0 : 0,
      volume: this.volume,
      muted: this.muted,
      rate: el ? el.playbackRate || this.rate : this.rate,
      mode: this.mode,
    };
  }

  /**
   * Where the film is. An element told to start further on (startat: a software player taking
   * over, a seek while it read the file) says 0, "seeking", for seconds before it gets there:
   * until then, where it is going is the answer.
   */
  time(el, state) {
    const t = el.currentTime || 0;
    if (this.landed) return t;
    const at = parseFloat(el.getAttribute('startat') || '0') || 0;
    const there = state === 'playing' || state === 'paused' || state === 'ended' || (state === 'buffering' && t > 0);
    if (at <= 0 || there || Math.abs(t - at) < 2) {
      this.landed = true;
      return t;
    }
    return at;
  }

  emit(type, extra) {
    const detail = { ...this.snapshot(type), ...extra };
    if (TRACK_EVENTS.has(type) || type === 'decoder') {
      const tracks = this.tracks();
      const key = JSON.stringify(tracks);
      if (key !== this.tracksSent) {
        this.tracksSent = key;
        detail.tracks = tracks;
      }
    }
    this.container.dispatchEvent(new CustomEvent('capy', { detail }));
  }

  /**
   * What the app's stream info shows, under mpv's property names: the decoder, the codecs, the
   * frame rate, the seconds read ahead.
   */
  info() {
    const el = this.el, p = el && el.player;
    const out = { 'hwdec-current': this.mode === 'hardware' ? 'webcodecs' : 'no', 'capy-switched': this.switched || '' };
    if (!p) return out;
    try {
      const tm = p.trackManager;
      const v = tm && tm.getActiveVideoTrack ? tm.getActiveVideoTrack() : null;
      const a = tm && tm.getActiveAudioTrack ? tm.getActiveAudioTrack() : null;
      if (v) {
        out['video-format'] = v.codec || '';
        out['container-fps'] = v.frameRate ? String(v.frameRate) : '';
        out['video-bitrate'] = v.bitRate ? String(v.bitRate) : '';
      }
      if (a) {
        out['audio-codec-name'] = a.codec || '';
        out['audio-params/samplerate'] = a.sampleRate ? String(a.sampleRate) : '';
        out['audio-bitrate'] = a.bitRate ? String(a.bitRate) : '';
      }
      out['demuxer-cache-duration'] = String(this.ahead());
      const health = p.getRenderHealth && p.getRenderHealth();
      if (health && health.framesDropped != null) out['frame-drop-count'] = String(health.framesDropped);
    } catch (e) {
      // A player half let go: what was read so far
    }
    return out;
  }

  /** The file's audio and subtitle tracks, and which ones are on. */
  tracks() {
    const p = this.el && this.el.player;
    const none = { audio: [], subtitles: [], audioOn: null, subtitleOn: null };
    if (!p || !p.getAudioTracks) return none;
    try {
      const tm = p.trackManager;
      const a = tm && tm.getActiveAudioTrack ? tm.getActiveAudioTrack() : null;
      const s = tm && tm.getActiveSubtitleTrack ? tm.getActiveSubtitleTrack() : null;
      const shape = (t) => ({
        id: t.id,
        language: t.language || '',
        title: t.label || '',
        codec: t.codec || '',
        channels: t.channels || 0,
        sampleRate: t.sampleRate || 0,
        image: t.subtitleType === 'image',
      });
      return {
        audio: p.getAudioTracks().map(shape),
        subtitles: (p.getSubtitleTracks ? p.getSubtitleTracks() : []).map(shape),
        audioOn: a ? a.id : null,
        subtitleOn: s ? s.id : null,
      };
    } catch (e) {
      return none;
    }
  }

  /**
   * The tracks wanted on [el] (those that were on before a software player took over, or picked
   * while it read the file), once it has read the file. What is wanted is read when it is put on,
   * so a later pick wins.
   */
  async applyWanted(el) {
    if (this.applyingFor === el) return; // one wait per element
    this.applyingFor = el;
    try {
      for (let i = 0; i < 120; i++) {
        await sleep(250);
        if (el !== this.el) return;
        if (!CapyMoviHost.knowsTracks(el)) continue;
        const p = el.player;
        const audio = this.wantAudio, sub = this.wantSub;
        try {
          const tm = p.trackManager;
          const on = tm && tm.getActiveAudioTrack ? tm.getActiveAudioTrack() : null;
          if (audio != null && (!on || on.id !== audio) && p.getAudioTracks().some((t) => t.id === audio)) {
            el.pickAudioTrack(audio);
          }
          if (sub !== undefined) await el.pickSubtitleTrack(sub);
        } catch (e) {
          // A track the element would not take: it plays its own default
        }
        this.emit('trackschange');
        return;
      }
    } finally {
      if (this.applyingFor === el) this.applyingFor = null;
    }
  }

  // -------------------------------------------------------------------------------------------
  // The decode guard
  //
  // Watched on hardware only:
  //  - an error from the decoder
  //  - the clock moving on while no frame is presented: the sound plays, the picture is stuck
  //  - waiting with the sound already in hand and no frame coming: a decoder that swallows packets
  //    without an error keeps movi "buffering" at 0. A slow network looks alike, but then there is
  //    little sound decoded either; here there is plenty
  //  - only black frames for BLACK_LIMIT seconds of film, before any frame with a picture in it.
  //    Once one real frame has been seen the hardware is proven for this film, and the check
  //    stops: films go black on purpose

  check() {
    const el = this.el, p = el && el.player;
    if (!p || this.mode !== 'hardware') return;
    const err = this.errors.find((e) => DECODE_ERROR.test(e));
    if (err) return this.toSoftware(`decoder error: ${err}`);

    const state = p.getState && p.getState();
    const health = p.getRenderHealth && p.getRenderHealth();
    const frames = health ? health.framesPresented : null;
    const w = this.watch;
    if ((state === 'buffering' || state === 'loading' || state === 'ready') && !el.paused) {
      if (w.waitFrames !== frames || w.waitSince == null) {
        w.waitFrames = frames;
        w.waitSince = performance.now();
      }
      const ready = this.soundReady(p);
      const waited = performance.now() - w.waitSince;
      if (ready >= SOUND_READY && waited >= WAIT_LIMIT_MS) {
        return this.toSoftware(`no frame for ${(waited / 1000).toFixed(1)} s with ${ready.toFixed(0)} s of sound ready`);
      }
    } else {
      w.waitSince = null;
    }
    if (state !== 'playing') {
      // Paused, buffering, seeking: the clock is not the picture's to keep up with, and counting
      // starts again once it plays
      w.lastT = null;
      w.frameAt = null;
      return;
    }
    const t = el.currentTime;
    // The film's time moved by more than playing could move it (a seek between two looks, which
    // the state did not show): not seconds of film without a frame
    const jumped = w.lastT != null && (t < w.lastT || t - w.lastT > 2);
    if (jumped) w.frameAt = null;
    if (frames != null) {
      if (frames !== w.lastFrames) {
        // A seek resets the count to 0: any change is a frame (or a fresh start)
        w.lastFrames = frames;
        w.frameAt = t;
      } else if (w.frameAt == null) {
        w.frameAt = t;
      } else if (t - w.frameAt >= STUCK_LIMIT) {
        return this.toSoftware(`no new frame for ${(t - w.frameAt).toFixed(1)} s of film`);
      }
    }
    if (!w.sawPicture && this.luma != null && w.lastT != null && !jumped) {
      if (this.luma < BLACK_LUMA) w.black += Math.max(0, t - w.lastT);
      else {
        w.sawPicture = true;
        this.unsample();
      }
      if (w.black >= BLACK_LIMIT) return this.toSoftware(`only black frames for ${w.black.toFixed(1)} s of film`);
    }
    w.lastT = t;
  }

  /** Seconds of sound decoded ahead, from movi's stats ("Audio Buffer": "123.15s"); 0 if unknown. */
  soundReady(p) {
    try {
      const v = parseFloat(String((p.getStats && p.getStats())['Audio Buffer']));
      return Number.isFinite(v) ? v : 0;
    } catch (e) {
      return 0;
    }
  }

  toSoftware(why) {
    if (this.mode !== 'hardware' || !this.el) return;
    const el = this.el, p = el.player;
    const at = Math.max(0, (el.currentTime || 0) - 1);
    let audio = null, sub = undefined;
    try {
      const tm = p && p.trackManager;
      const a = tm && tm.getActiveAudioTrack && tm.getActiveAudioTrack();
      const s = tm && tm.getActiveSubtitleTrack && tm.getActiveSubtitleTrack();
      // Before it read the file there is nothing to carry over: what was asked for stays wanted
      if (CapyMoviHost.knowsTracks(el)) {
        audio = a ? a.id : null;
        sub = s ? s.id : null;
      }
    } catch (e) {
      audio = null;
      sub = undefined;
    }
    this.switched = why;
    console.info(`capy-movi: hardware gave no picture (${why}); playing in software`);
    // A decoder's error pauses movi: what counts is whether the viewer had it playing
    this.mount('software', at, audio, sub, this.wantPlay);
  }

  // The picture is drawn on a WebGL canvas, which reads back empty once composited; its captured
  // stream does not. A 32x18 copy is enough to tell black from a picture.
  sample() {
    let stream = null;
    try {
      stream = this.el.captureStream(4);
    } catch (e) {
      stream = null;
    }
    if (!stream) return; // nothing to look at: the frame count alone decides
    const video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.srcObject = stream;
    video.play().catch(() => {});
    const canvas = document.createElement('canvas');
    canvas.width = 32;
    canvas.height = 18;
    const g = canvas.getContext('2d', { willReadFrequently: true });
    this.luma = null;
    this.sampler = setInterval(() => {
      if (video.readyState < 2) return;
      g.drawImage(video, 0, 0, 32, 18);
      const d = g.getImageData(0, 0, 32, 18).data;
      let max = 0;
      for (let i = 0; i < d.length; i += 4) {
        const y = 0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2];
        if (y > max) max = y;
      }
      this.luma = max;
    }, TICK_MS);
    this.sampleVideo = video;
  }

  unsample() {
    clearInterval(this.sampler);
    this.sampler = 0;
    if (this.sampleVideo) {
      this.sampleVideo.srcObject = null;
      this.sampleVideo = null;
    }
    this.luma = null;
  }
}

window.capyMovi = {
  /** A host for [container], the element the app shows. */
  create: (container) => new CapyMoviHost(container),
  HevcFixSource,
};
