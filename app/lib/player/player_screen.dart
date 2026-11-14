import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../chromecast/cast_discovery.dart';
import '../data/airing.dart';
import '../data/app_url.dart';
import '../data/catalog.dart';
import '../data/epg.dart';
import '../data/image_store.dart';
import '../data/intro_marks.dart';
import '../data/library.dart';
import '../data/models.dart' show LiveChannel;
import '../data/profiles.dart';
import '../data/recordings.dart';
import '../data/settings.dart';
import '../data/source.dart' show SourceError, SourceException;
import '../data/stream_stats.dart';
import '../data/watch_time.dart';
import '../data/xtream.dart' show XtreamSource;
import '../desktop_window.dart';
import '../device.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../remote/remote_input.dart';
import '../ui/cast_screen.dart';
import '../ui/common.dart';
import '../ui/profiles_screen.dart';
import '../ui/send_to.dart';
import '../ui/theme.dart';
import 'audio_choice.dart';
import 'audio_guard.dart';
import 'background_play.dart';
import 'background_recorder.dart';
import 'hls_recorder.dart';
import 'movi_player.dart';
import 'movi_sound.dart';
import 'multiview_screen.dart';
import 'pip.dart';
import 'play.dart';
import 'props.dart';
import 'record_relay.dart';
import 'recording_scheduler.dart';
import 'sleep_timer.dart';

part 'player_controls.dart';
part 'player_overlay.dart';
part 'player_failure.dart';
part 'player_panels.dart';
part 'player_reconnect.dart';
part 'player_recording.dart';
part 'player_system.dart';
part 'player_time_limit.dart';

const _skip = Duration(seconds: 10);

/// How the picture fills the screen, in the order the button goes through them: fit, fill (edges
/// cut), stretch, or a shape of its own.
const _pictureFits = ['contain', 'cover', 'fill', '16:9', '4:3', '21:9'];
final _mobile = isAndroid || isIOS;

/// media_kit adds the pseudo tracks "auto" and "no"; only real tracks are listed.
List<T> realTracks<T>(List<T> tracks) => tracks.where((t) => !['auto', 'no'].contains((t as dynamic).id)).toList();

/// Normalizes ISO 639-1 and 639-2/B codes to the 639-2/T codes the translations use.
const _langAliases = {
  'es': 'spa',
  'esa': 'spa',
  'en': 'eng',
  'fr': 'fra',
  'fre': 'fra',
  'de': 'deu',
  'ger': 'deu',
  'it': 'ita',
  'pt': 'por',
  'ja': 'jpn',
  'ko': 'kor',
  'zh': 'zho',
  'chi': 'zho',
  'ar': 'ara',
  'ru': 'rus',
};

/// "Spanish · Latino" from the track language plus whatever title it carries.
String niceTrack(AppLocalizations l, dynamic t, int index) {
  final code = (t.language as String?)?.toLowerCase();
  final lang = code == null || code.isEmpty || code == 'und' ? null : l.languageName(_langAliases[code] ?? code);
  final title = t.title as String?;
  // Accent-insensitive comparison so "Ingles" does not repeat "Inglés"
  String plain(String? s) =>
      (s ?? '').toLowerCase().replaceAllMapped(RegExp('[áéíóú]'), (m) => 'aeiou'['áéíóú'.indexOf(m[0]!)]);
  final parts = [lang, if (title != null && plain(title) != plain(lang)) title];
  final label = parts.whereType<String>().where((s) => s.isNotEmpty).join(' · ');
  return label.isEmpty ? l.trackN(index + 1) : label;
}

// selectedTracks lives in props.dart now: on the web there is no mpv track list to read, and the
// element's own selection is what gets reported.

String _fmt(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// Full-screen player: video edge to edge; what plays and what the stream is on top; progress
/// and the controls below, with side panels for audio and subtitles, speed, the episodes or
/// channels, and the player's settings (sleep timer, volume boost, stream info). Fully usable with
/// a TV remote.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.engine, required this.items, this.index = 0, this.library});

  final PlaybackEngine engine;
  Player get player => engine.player;
  VideoController get controller => engine.controller;
  final List<PlayItem> items; // channels to zap through, or episodes to continue with
  final int index;
  final Library? library;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with _PlayerRecording, _PlayerTimeLimit, _PlayerSystem, _PlayerFailure, _PlayerReconnect {
  @override
  Player get player => widget.player;
  final _subs = <StreamSubscription>[];
  // The player itself: it has the remote while the controls are hidden. Never a place the arrows go
  // to among the controls: it holds them all, so from there no arrow would lead anywhere
  @override
  final _focus = FocusNode(debugLabel: 'player', skipTraversal: true);
  final _playFocus = FocusNode(debugLabel: 'play');
  bool _visible = true, _panelOpen = false, _fullscreen = false;
  Timer? _hide;
  Duration? _drag; // position while the progress bar is being dragged
  String? _flash; // "+10" / "−10" flash after a skip
  Timer? _flashTimer;

  // Live by what the item is (mpv may still report an estimated duration for live TS). Only an
  // unknown stream (e.g. a plain URL) is judged by its duration, once it has started: before that
  // a movie would briefly look live.
  @override
  bool get _live => _item.isLive || (_item.ref == null && _started && player.state.duration == Duration.zero);

  late int _index = widget.index;
  @override
  PlayItem get _item => widget.items[_index];
  bool get _hasNext => _index < widget.items.length - 1;
  Timer? _saveTimer;
  Duration? _resumedFrom; // shows the "start over" pill while set
  Timer? _resumeTimer;
  // A stream that never starts (an event channel before kick-off, a dead link) would otherwise
  // spin forever: give up after a while, or at once if the player reports an error first
  static const _startTimeout = Duration(seconds: 20);
  // With other copies to try, a slow one is left sooner: one of them may well start at once
  static const _startTimeoutWithOthers = Duration(seconds: 10);
  @override
  bool _started = false;
  @override
  bool _failed = false;

  // The copies of the item to try, likely fastest first at this hour (see StreamStats), and the
  // one playing. A copy that does not start makes way for the next before "unavailable" shows.
  List<PlayItem> _sources = const [];
  var _source = 0;
  var _switching = false; // trying another copy
  final _startClock = Stopwatch();
  @override
  PlayItem get _stream => _sources.isEmpty ? _item : _sources[_source];
  Timer? _watchdog;
  final _retryFocus = FocusNode(debugLabel: 'retry');

  @override
  var _reconnecting = false;
  var _leftLive = false; // a channel stopped as the app went to the background
  var _retriedQuietly = false; // a channel that did not start, opened once more before saying so
  var _opening = false; // between asking for a stream and mpv taking it: what plays is the last one's
  Duration? _brokeAt; // where a movie last stopped short of its end
  var _breaks = 0; // and how many times in a row
  @override
  var _session = 0; // a new one per item opened, so a late reopen knows it is stale
  @override
  var _paused = false; // by the user: a still picture is then no stall
  Timer? _stallCheck;

  // This session's settings
  final _sleep = SleepTimer();
  var _slept = false; // stopped by the sleep timer: its panel shows
  @override
  bool get _stopped => _slept || _timeUp || _sentAway != null;

  /// Sent to another device, which plays it: this one let go of the stream, and says where it is.
  String? _sentAway;
  // The first button of the panel that shows once playback stops: Keep watching, or Exit once the time
  // is up. The remote is put there (see _stopPlayback), the controls it was on being gone
  @override
  final _wakeFocus = FocusNode(debugLabel: 'stopped panel');
  var _nextCancelled = false; // this episode ends without the next one starting
  Intro? _intro; // the series' opening titles, where marked
  var _introSkipped = false;
  var _boost = 0; // dB over the stream's own volume
  var _info = false; // stream info on screen
  List<(String, String)> _details = const [];
  late var _fit = SettingsScope.maybeOf(context)?.videoFit ?? 'contain';
  var _showLeft = false; // the time left instead of the length
  double? _fps;
  Timer? _tick;
  // Phones: touches locked (a pocket, a child), the lock showing a moment on a tap
  var _locked = false, _lockHint = false;
  Timer? _lockHintTimer;
  @override
  var _pip = false; // the small window can be opened here

  // Live channels keep what they send (see [_cacheFor]): how far behind the live picture this one
  // is, after a pause or a rewind
  var _behind = Duration.zero;
  bool get _late => _item.isLive && _behind > const Duration(seconds: 15);

  // Touch screens: a finger up or down on the left half sets the brightness, on the right half the
  // volume; sideways it seeks. What changes shows while it moves
  ({IconData icon, String text})? _gesture;
  double? _brightness; // the screen's, read on opening
  var _brightnessSet = false; // changed here: the system's comes back on leaving
  var _brightnessSide = false;
  Duration? _seekTarget;
  bool get _touch => _mobile && !isTv && !_locked;

  // Sound on in the background (a setting, see [BackgroundPlay]): Android's controls for it, and
  // no picture decoded while nobody sees it
  @override
  late final bool _background = BackgroundPlay.available && (SettingsScope.maybeOf(context)?.backgroundPlay ?? false);
  late final AppLifecycleListener _lifecycle;
  String? _videoTrack; // the picture's track, while only the sound plays

  /// Tries the next copy of the item, if any; else shows the "unavailable" panel with the remote
  /// already on Retry. Not once it played.
  void _fail() {
    if (!mounted || _started || _failed || _stopped) return;
    StreamStats.failed(_stream.url);
    if (_source + 1 < _sources.length) {
      _source++;
      setState(() => _switching = true);
      _open(sameItem: true);
      return;
    }
    // Once more, quietly: a provider that allows one connection may not have let the last channel go
    if (_item.isLive && !_retriedQuietly) {
      _retriedQuietly = true;
      final session = _session;
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && session == _session && !_started && !_stopped) _open(sameItem: true);
      });
      return;
    }
    _showFailure();
  }

  @override
  void _showFailure() {
    setState(() {
      _failed = true;
      _reconnecting = false;
    });
    if (_failCause == null) unawaited(_askWhy());
    _poke();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _retryFocus.context != null ? _retryFocus.requestFocus() : null,
    );
  }

  /// How far from its end a movie that stops counts as cut rather than over.
  static const _endSlack = Duration(seconds: 30);

  double _volumeBeforeMute = 100;

  /// What the player opens for [item]: its address, and in a browser through the video proxy, so
  /// the whole file is readable with CORS (movi-player demuxes it to offer its audio languages).
  /// A relay is a local address of the app itself: it goes as it is. [start]: where it opens.
  @override
  Media _mediaFor(PlayItem item, {Duration? start}) {
    final relay = _relay;
    if (relay != null) return Media(relay.url);
    return Media(videoUrl(item.url), httpHeaders: item.headers, start: start);
  }

  /// Lets go of the hidden sound element of movi_sound.dart, if the last stream had one. In a
  /// browser nothing reads a stream a second time any more: a file plays in movi itself, picture,
  /// sound and languages (movi_player_web.dart), and a stream (HLS) stays with the browser's
  /// <video> alone. On live channels that second reader found no languages, held a second
  /// connection to the provider for minutes, and on one channel's HLS master playlist froze the
  /// page (measured 2026-11-12). Natively nothing happens: mpv reads the tracks itself.
  void _readAudio() => stopMoviSound(player);

  /// Sound off, and back on at what it was, not at full.
  void _toggleMute() {
    final v = player.state.volume;
    if (v > 0) _volumeBeforeMute = v;
    setAudioVolume(player, v > 0 ? 0 : _volumeBeforeMute);
  }

  /// Play/pause from the user, remembered so a paused live picture is not taken for a stall.
  /// [user]: not Android's audio focus doing it (see [_onSound]).
  @override
  Future<void> _togglePlay({bool user = true}) async {
    final pausing = player.state.playing;
    if (user) _pausedForSound = false;
    await player.playOrPause();
    _paused = pausing;
    _poke();
    if (pausing) unawaited(_saveProgress(quiet: true));
    // Playing again after another app took the sound: it is ours again
    if (!pausing && user && mounted && !_background) unawaited(AudioGuard.hold(_onSound));
  }

  @override
  void initState() {
    super.initState();
    _listen();
    // Pausing and going to the background save too, so a longer wait loses nothing more
    _saveTimer = Timer.periodic(const Duration(seconds: 30), (_) => _saveProgress(quiet: true));
    _stallCheck = Timer.periodic(const Duration(seconds: 2), (_) => _checkStall());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    Pip.onPlayPause = _togglePlay;
    Pip.onClosed = _onPipClosed;
    Pip.active.addListener(_onPip);
    _lifecycle = AppLifecycleListener(onStateChange: _onAppState);
    Pip.supported().then((on) => mounted && on ? setState(() => _pip = true) : null);
    if (_mobile && !isTv) _readBrightness(); // ready for the first move
    _begin();
    _poke();
    // The settings are read once this is in the tree
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_background) unawaited(AudioGuard.hold(_onSound));
    });
  }

  /// A profile's time for today first: nothing opens once it is up, not even for a moment.
  Future<void> _begin() async {
    final left = await WatchTime.left(ProfileStore.instance.current);
    if (!mounted) return;
    _timeLeft = left;
    if (left != null && left <= Duration.zero) return _stopForTime();
    await _open();
  }

  /// A few times a second while the controls show (their bar and times), once a second without
  /// (a countdown, the intro's button); at once when the time jumped (a seek).
  void _timeMoved() {
    if (!mounted) return;
    final now = DateTime.now(), position = player.state.position;
    final every = _visible || _drag != null ? const Duration(milliseconds: 250) : const Duration(seconds: 1);
    final jumped = (position - _drawnPosition).abs() > const Duration(seconds: 2);
    if (!jumped && now.difference(_drawnAt) < every) return;
    _drawnAt = now;
    _drawnPosition = position;
    setState(() {});
  }

  var _drawnAt = DateTime(0);
  var _drawnPosition = Duration.zero;

  void _listen() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    final s = player.stream;
    // The time going by comes many times a second: the screen is built anew as often as what shows
    // needs it, not at each one
    _subs.add(s.position.listen((_) => _timeMoved()));
    _subs.add(s.buffer.listen((_) => _timeMoved()));
    for (final st in <Stream>[s.duration, s.playing, s.buffering, s.tracks, s.track, s.volume, s.rate, s.audioParams]) {
      _subs.add(st.listen((_) => mounted ? setState(() {}) : null));
    }
    _subs.add(
      s.position.listen((p) {
        if (_opening) return; // the last stream's, not this one's: it has not started
        if (p > _lastPosition) {
          _moved = clock.now();
          if (_reconnecting && _reopened != null && p >= const Duration(seconds: 1)) {
            setState(() => _reconnecting = false); // back
          }
        }
        _lastPosition = p;
        if (_started || p < const Duration(milliseconds: 500)) return;
        _watchdog?.cancel();
        StreamStats.started(_stream.url, _startClock.elapsed);
        setState(() {
          _started = true;
          _switching = false;
        });
        if (_resumedFrom != null) _hideResumeLater();
        unawaited(_deinterlace());
        if (_failed) {
          setState(() => _failed = false); // it recovered after all
          _focus.requestFocus();
        }
      }),
    );
    _subs.add(s.videoParams.listen((_) => _readFps()));
    // At once: leaving the app right after must find it so
    _subs.add(
      s.playing.listen((_) {
        _tellPip();
        _tellMedia();
      }),
    );
    _subs.add(s.duration.listen((_) => _tellMedia()));
    _subs.add(s.rate.listen((_) => _tellMedia()));
    // Why a stream did not open, from mpv's log; only the cause is kept: the lines carry the address
    _subs.add(
      s.log.listen((line) {
        if (_started) return;
        final cause = _causeOf(line.text);
        // It may come after the panel showed: drawn again with it
        if (cause != null && cause != _failCause && mounted) _setCause(cause);
      }),
    );
    // Once the stream has opened (its picture has a size), mpv's errors are mostly passing ones
    // ("cannot seek", a bad audio frame, more often with hardware decoding): whether it starts is
    // then up to the watchdog. Before that, an error means it did not open.
    _subs.add(
      s.error.listen((_) {
        if ((player.state.width ?? 0) == 0) _fail();
      }),
    );
    _subs.add(
      s.completed.listen((done) {
        if (!done || _stopped || _opening) return;
        final st = player.state;
        final short = !_item.isLive && st.duration > Duration.zero && st.position < st.duration - _endSlack;
        // mpv says it ended when the server stopped sending: far from the end, that is a cut. A second
        // stop at the same place is the file's real end (a .ts may say a wrong length)
        if (short && _brokeAt != st.position) {
          // Given up after the third: where it stopped is not taken for its end, so leaving saves
          // that place, not the movie as watched whole
          if (_breaks >= 2) return _showFailure();
          _breaks++;
          _brokeAt = st.position;
          setState(() => _reconnecting = true);
          Future<void>.delayed(Duration(seconds: 1 << _breaks), () {
            if (mounted && !_stopped) _open(sameItem: true, from: st.position);
          });
          return;
        }
        _breaks = 0;
        if (_sleep.atEnd && !_live) {
          _sleepNow(); // not on to the next episode
        } else if (_live && _started) {
          _recover(); // a live stream does not end: it dropped
        } else if (!_item.isLive && _hasNext && !_nextCancelled) {
          _go(1); // binge: next episode starts by itself
        } else if (!_item.isLive) {
          // Over, nothing after it: the controls stay to say so, and the screensaver may come
          _saveProgress();
          _poke();
          sayStopped(this);
        }
      }),
    );
  }

  /// An interlaced channel (1080i, 576i) shows combs on every movement where the picture is drawn
  /// as it comes (Windows, the software decoder): mpv deinterlaces that one. Not always on, or mpv
  /// would filter every stream; Android's hardware decoder leaves it to the chip, which does it.
  Future<void> _deinterlace() async {
    // mpv's only (props.dart asks nothing of any other player): a browser deinterlaces by itself
    if (isWeb || (isAndroid && widget.engine.hardware)) return;
    // A build without the filter refuses it, and the picture stays as it is
    final interlaced = await playerProperty(player, 'video-frame-info/interlaced') == 'yes';
    await setPlayerProperty(player, 'deinterlace', interlaced ? 'yes' : 'no');
  }

  /// Opens the item; [sameItem] for its next copy after one that did not start, or the same copy
  /// again, from [from].
  @override
  Future<void> _open({bool sameItem = false, Duration? from}) async {
    final item = _item;
    if (!sameItem) {
      _failCause = null; // a retry of the same keeps what the first try said
      // Another title: the cuts of the one before count for nothing
      _breaks = 0;
      _brokeAt = null;
      _sources = item.pinned
          ? [item, ...StreamStats.fastestFirst(item.alternates, (s) => s.url)]
          : StreamStats.fastestFirst([item, ...item.alternates], (s) => s.url);
      _source = 0;
      _switching = false;
      _retriedQuietly = false;
    }
    _opening = true;
    final stream = _stream;
    sayPlaying(this, (title: item.title, subtitle: item.subtitle));
    // What is on, from the guide or, for a channel it leaves out, asked of the provider now (Airing),
    // for the overlay's "on now" when it shows
    final on = item.isLive
        ? currentAiring.value?.now(liveChannelOf(item.ref), currentGuide.value) ??
              currentGuide.value?.nowOn(item.ref?.epgId)
        : null;
    // Zapping with a screen reader: which channel it landed on, and what is on, said out loud
    if (!sameItem && item.isLive && MediaQuery.accessibleNavigationOf(context)) {
      unawaited(
        SemanticsService.sendAnnouncement(
          View.of(context),
          [item.title, if (on != null) '${context.l10n.onNow}: ${on.title}'].join(', '),
          Directionality.of(context),
        ),
      );
    }
    setState(() => _started = _failed = _reconnecting = _paused = false);
    _fps = null;
    _nextCancelled = _introSkipped = false;
    _intro = null;
    if (_seriesTitle case final series?) {
      unawaited(
        IntroMarks.of(series).then(
          (m) {
            if (mounted && item == _item) setState(() => _intro = m);
          },
          onError: (Object e) => debugPrint('Intro marks: $e'), // none marked: skipping is by hand
        ),
      );
    }
    final session = ++_session;
    _tapChannel();
    _reopens = 0;
    _lastPosition = Duration.zero;
    _moved = clock.now();
    _watchdog?.cancel();
    _watchdog = Timer(_source + 1 < _sources.length ? _startTimeoutWithOthers : _startTimeout, _fail);
    _startClock
      ..reset()
      ..start();

    // Another channel, or another copy of it: what was recorded is kept, and the relay goes
    final url = Uri.parse(stream.url);
    if (_recording != null && (_hls?.source ?? _relay?.source) != url) await _stopRecording();
    if (_relay case final relay? when relay.source != url) {
      _relay = null;
      await relay.close();
    }
    // Another channel asked for while that was closing: it is the one that opens, not this
    if (session != _session) return;
    await _cacheFor(item.isLive);
    if (!mounted || _stopped || session != _session) {
      if (session == _session) _opening = false;
      return; // the time ran out, or another came
    }
    _behind = Duration.zero;
    await _textSubtitlesAgain(player);
    final ref = item.ref;
    final saved = ref == null ? null : widget.library?.entry(ref);
    final start = ref == null || item.isLive
        ? null
        : from ?? item.start ?? (saved != null && saved.resumable ? saved.position : null);
    final resume = start != null && start > Duration.zero ? start : null;
    // Opened right where it resumes, not at the start and then a jump; a browser's player seeks
    // once it knows the length, as before
    final opensThere = resume != null && !kIsWeb && _relay == null;
    await player.open(_mediaFor(stream, start: opensThere ? resume : null));
    if (session != _session) return;
    // A file in a browser's movi reads its head and probes it before the first frame, which took
    // up to half a minute through a proxy: more time before it counts as not starting
    if (playsFilesItself(player) && !_started) {
      _watchdog?.cancel();
      _watchdog = Timer(moviStartTimeout - _startClock.elapsed, _fail);
    }
    _readAudio();
    _opening = false;
    if (ref == null) return;
    if (resume == null) {
      await widget.library?.record(ref);
      return;
    }
    if (opensThere) {
      setState(() => _resumedFrom = resume);
    } else {
      // Seeking needs the duration, which only arrives once the stream is probed
      try {
        await player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 20));
      } on TimeoutException {
        return;
      }
      if (!mounted || item != _item) return;
      // The pill shows while the seek is under way, not once it has landed
      setState(() => _resumedFrom = resume);
      await player.seek(resume);
    }
    _hideResumeLater();
  }

  /// The "start over" pill goes 8 s after the picture moves, not after the stream was asked for:
  /// a slow start (a slow server or device) took it away before it was seen. Not started yet, the
  /// position's listener times it once it is.
  void _hideResumeLater() {
    _resumeTimer?.cancel();
    if (!_started) return;
    _resumeTimer = Timer(const Duration(seconds: 8), () => mounted ? setState(() => _resumedFrom = null) : null);
  }

  /// [quiet] while playing: other devices get the position a while later, not every few seconds.
  @override
  Future<void> _saveProgress({bool quiet = false}) async {
    final ref = _item.ref;
    final st = player.state;
    if (ref == null || _item.isLive || st.duration <= Duration.zero) return;
    if (_reconnecting || _opening) return; // a cut being mended, or another opening: no progress
    final cut = st.completed && st.position < st.duration - _endSlack && _brokeAt != st.position;
    final finished = (st.completed && !cut) || st.position >= st.duration - const Duration(seconds: 5);
    await widget.library?.record(
      ref,
      position: finished ? st.duration : st.position,
      duration: st.duration,
      quiet: quiet,
    );
  }

  /// Moves through the queue: channel zapping for live, previous/next episode for VOD.
  Future<void> _go(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= widget.items.length) return;
    await _saveProgress();
    setState(() {
      _index = next;
      _resumedFrom = null;
    });
    _poke();
    if (!_item.isLive) return _open();
    // Zapping with the key held: the name follows at once, and only the channel stopped at opens,
    // not each one passed with a connection and a line in the recent ones
    _zap?.cancel();
    _zap = Timer(const Duration(milliseconds: 350), () {
      if (mounted && !_stopped) _open();
    });
  }

  Timer? _zap;
  var _decoderBusy = false;

  @override
  void dispose() {
    unawaited(AudioGuard.release(_onSound));
    for (final s in _subs) {
      s.cancel();
    }
    _hide?.cancel();
    _zap?.cancel();
    _flashTimer?.cancel();
    _saveTimer?.cancel();
    _resumeTimer?.cancel();
    _watchdog?.cancel();
    _stallCheck?.cancel();
    _tick?.cancel();
    _noteTime();
    _lockHintTimer?.cancel();
    Pip.active.removeListener(_onPip);
    _lifecycle.dispose();
    _tapChannel(off: true);
    _relay?.close(); // what was recorded is kept
    stopMoviSound(player); // the browser's sound element, if any
    RecordingScheduler.instance.playerRecordingEnded(this);
    _hls?.stop();
    if (_mediaSaid != null) BackgroundPlay.hide(this);
    BackgroundPlay.release(this);
    if (_brightnessSet) ScreenBrightness.instance.resetApplicationScreenBrightness();
    if (Pip.onPlayPause == _togglePlay) Pip.onPlayPause = null;
    if (Pip.onClosed == _onPipClosed) Pip.onClosed = null;
    if (_pip) Pip.update(auto: false, playing: false); // leaving the app now leaves it
    _retryFocus.dispose();
    _wakeFocus.dispose();
    sayStopped(this);
    final fullscreen = _fullscreen;
    unawaited(() async {
      if (Pip.desktop) await Pip.leave();
      if (fullscreen) await DesktopWindow.instance.setFullScreen(false);
    }());
    _focus.dispose();
    _playFocus.dispose();
    super.dispose();
  }

  void _poke() {
    if (!mounted) return;
    setState(() => _visible = true);
    _hide?.cancel();
    // With a screen reader, the controls take longer to find than they last: they stay
    if (WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.accessibleNavigation) return;
    // As long as Settings says: a moment, or longer for whoever needs it
    final seconds = SettingsScope.read(context)?.controlsSeconds ?? 0;
    _hide = Timer(seconds > 0 ? Duration(seconds: seconds) : const Duration(milliseconds: 3500), () {
      if (mounted && player.state.playing && !_panelOpen && _drag == null && !_failed) {
        setState(() => _visible = false);
        _focus.requestFocus(); // a hidden button must not take the next OK
      }
    });
  }

  Future<void> _setFullscreen(bool on) async {
    await DesktopWindow.instance.setFullScreen(on); // the desktop title bar hides meanwhile
    if (mounted) setState(() => _fullscreen = on);
  }

  @override
  void _seekTo(Duration t) {
    final dur = player.state.duration;
    if (t < Duration.zero) t = Duration.zero;
    if (!_item.isLive && t > dur) t = dur; // a channel is held to what it kept by mpv
    // Where it moved to is no freeze: the stall watch starts from here
    _lastPosition = t;
    _moved = clock.now();
    player.seek(t).then((_) => _tellMedia(moved: true));
  }

  void _seekBy(Duration d) {
    if (_live && !_item.isLive) return; // a stream of unknown kind, without an end
    _seekTo(player.state.position + d);
    _flashText(d.isNegative ? '−${-d.inSeconds}' : '+${d.inSeconds}');
    _poke();
  }

  /// The arrow that last zapped or skipped, and until when another of its axis does the same:
  /// those bring the controls up, and the next press went into them instead of on.
  LogicalKeyboardKey? _lastArrow;
  DateTime _arrowUntil = DateTime(0);

  KeyEventResult _arrowAgain(LogicalKeyboardKey k, VoidCallback action) {
    _lastArrow = k;
    _arrowUntil = DateTime.now().add(const Duration(milliseconds: 3500));
    return _handled(action);
  }

  @override
  void _flashText(String text, {Duration time = const Duration(milliseconds: 650)}) {
    _flashTimer?.cancel();
    setState(() => _flash = text);
    _flashTimer = Timer(time, () => mounted ? setState(() => _flash = null) : null);
  }

  Future<void> _readBrightness() async {
    try {
      _brightness = await ScreenBrightness.instance.application;
    } on Object {
      _brightness = 0.5;
    }
  }

  void _verticalStart(DragStartDetails d) =>
      _brightnessSide = d.localPosition.dx < MediaQuery.sizeOf(context).width / 2;

  /// A finger moved up or down by [fraction] of the screen: a swipe over most of it goes all the way.
  void _verticalMove(double fraction) {
    final change = -fraction * 1.3;
    if (_brightnessSide) {
      final b = _brightness;
      if (b == null) return; // still reading where it is
      _brightness = (b + change).clamp(0.0, 1.0);
      _brightnessSet = true;
      ScreenBrightness.instance.setApplicationScreenBrightness(_brightness!);
      setState(() => _gesture = (icon: Icons.brightness_6_rounded, text: '${(_brightness! * 100).round()} %'));
    } else {
      final v = (player.state.volume + change * 100).clamp(0.0, 100.0);
      setAudioVolume(player, v);
      setState(
        () => _gesture = (icon: v == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, text: '${v.round()} %'),
      );
    }
  }

  /// Sideways: a swipe across the screen moves a minute and a half.
  void _horizontalMove(double fraction) {
    final st = player.state;
    if (_live || st.duration <= Duration.zero) return;
    final from = st.position;
    var to = (_seekTarget ?? from) + Duration(milliseconds: (fraction * 90000).round());
    if (to < Duration.zero) to = Duration.zero;
    if (to > st.duration) to = st.duration;
    final d = to - from;
    setState(() {
      _seekTarget = to;
      _gesture = (
        icon: d.isNegative ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
        text: '${_fmt(to)}  (${d.isNegative ? '−' : '+'}${_fmt(d.abs())})',
      );
    });
  }

  void _gestureEnd() {
    final to = _seekTarget;
    if (to != null) _seekTo(to);
    setState(() {
      _seekTarget = null;
      _gesture = null;
    });
  }

  /// Into the small window, shaped like the picture.
  Future<void> _enterPip() async {
    final st = player.state, l = context.l10n;
    final ok = await Pip.enter(
      width: st.videoParams.dw ?? st.width,
      height: st.videoParams.dh ?? st.height,
      pause: l.pause,
      play: l.play,
    );
    // Only Android has a setting that refuses it
    if (!ok && mounted && !Pip.desktop) _tell(l.pipOff);
  }

  void _onPip() {
    if (!mounted) return;
    setState(() => _visible = false); // the small window shows the picture alone; back, the controls are hidden
    // Its button went with the controls: the keys (a computer's Esc, P, Space) are the player's
    _focus.requestFocus();
  }

  /// Closing the small window is done watching, for now: it pauses, also with the sound on in the
  /// background (without it, leaving the app pauses anyway).
  void _onPipClosed() {
    if (mounted && player.state.playing) _togglePlay();
  }

  /// In the background only the sound plays: no picture is decoded while nobody sees it (and the
  /// screen it went to is gone). Back, the same track plays again; media_kit also brings it back
  /// when Android hands the player a new screen surface.
  Future<void> _onAppState(AppLifecycleState state) async {
    final native = player.platform;
    // Android's controls, if they could not show while the app was away
    if (state == AppLifecycleState.resumed && _mediaSaid == null) _tellMedia();
    // The system may end the app from there
    if (state == AppLifecycleState.paused) unawaited(_saveProgress(quiet: true));
    // A channel left behind lets its connection go, as on the TV, and opens again on coming back
    if (!_background && _item.isLive && !Pip.active.value && _recording == null) {
      if (state == AppLifecycleState.paused && !_stopped && !_leftLive) {
        _leftLive = true;
        await player.stop();
      } else if (state == AppLifecycleState.resumed && _leftLive) {
        _leftLive = false;
        if (mounted && !_stopped) await _open(sameItem: true);
      }
    }
    if (!_background || native is! NativePlayer) return;
    if (state == AppLifecycleState.paused && !Pip.active.value && _videoTrack == null) {
      final now = await playerProperty(player, 'vid');
      final first = player.state.tracks.video.where((v) => v.id != 'auto' && v.id != 'no').firstOrNull;
      _videoTrack = now.isNotEmpty && now != 'no' ? now : first?.id ?? 'auto';
      await setPlayerProperty(player, 'vid', 'no');
    } else if (state == AppLifecycleState.resumed && _videoTrack != null) {
      final track = _videoTrack!;
      _videoTrack = null;
      await setPlayerProperty(player, 'vid', track);
      // The surface may come back a moment after the app: once more then
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (mounted && _videoTrack == null && await playerProperty(player, 'vid') == 'no') {
        await setPlayerProperty(player, 'vid', track);
      }
    }
  }

  /// Live channels keep what they sent behind the picture, so a pause holds the place and a rewind
  /// finds it: in memory, as much as the device can spare. mpv's cache file only ever grows (its
  /// limits are for its index), so on disk two hours of a channel filled a TV stick. Movies and
  /// episodes keep mpv's usual cache: 200 MB, which a 1 GB stick has not got to spare (a film in
  /// Full HD filled it, and the app was closed), so there they keep 50.
  Future<void> _cacheFor(bool live) async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    final (ahead, behind) = switch ((live, deviceTier)) {
      (true, DeviceTier.low) => ('16MiB', '32MiB'),
      (true, DeviceTier.medium) => ('32MiB', '128MiB'),
      (true, _) => ('64MiB', '512MiB'),
      (false, _) => (lowMemory ? '40MiB' : '150MiB', lowMemory ? '10MiB' : '50MiB'),
    };
    await setPlayerProperty(player, 'cache-on-disk', 'no');
    await setPlayerProperty(player, 'demuxer-max-bytes', ahead);
    await setPlayerProperty(player, 'demuxer-max-back-bytes', behind);
    await setPlayerProperty(player, 'demuxer-seekable-cache', live ? 'yes' : 'auto');
  }

  /// How far behind the live picture a channel plays: from what it kept to where it plays. What it
  /// kept comes as mpv tells it ([PlayerState.buffer] is its demuxer-cache-time): asking mpv each
  /// second would wait on it, and hold the whole app while it is busy.
  void _readBehind() {
    if (!_item.isLive || !_started) return;
    var behind = player.state.buffer - player.state.position;
    if (behind < Duration.zero) behind = Duration.zero;
    if ((behind - _behind).abs() >= const Duration(milliseconds: 500)) setState(() => _behind = behind);
  }

  /// Back to the live picture, from a pause or a rewind.
  Future<void> _goLive() async {
    _seekTo(player.state.buffer - const Duration(seconds: 2));
    if (!player.state.playing) await _togglePlay();
    if (mounted) setState(() => _behind = Duration.zero);
  }

  void _onTick() {
    if (!mounted) return;
    // Two minutes past where it was cut, the movie plays on well: a later cut is a first one again
    if (_breaks > 0 && player.state.position > (_brokeAt ?? Duration.zero) + const Duration(minutes: 2)) {
      _breaks = 0;
    }
    if (_recordingSince != null) setState(() {}); // its time
    _readBehind();
    _countTime();
    _tellPip();
    if (_sleep.due) {
      _sleepNow();
    } else if (_sleep.warnNow && player.state.playing) {
      // Said ahead, so it does not stop mid-scene without warning, with the way to go on
      _sleep.warned = true;
      _flashText(context.l10n.sleepSoon(_sleep.minutes!), time: const Duration(seconds: 10));
    } else if (_sleep.left != null && _visible) {
      setState(() {}); // the time left on its badge
    }
    if (_info) _readDetails();
  }

  /// A key or a touch after the sleep timer said it stops soon: someone is watching, the wait
  /// starts again.
  void _stillWatching() {
    if (!_sleep.warned || _sleep.left == null || _stopped) return;
    _sleep.again();
    _flashText(context.l10n.sleepExtended(_sleep.minutes!), time: const Duration(seconds: 3));
  }

  /// The sleep timer is up: progress saved, the stream closed (a paused one still holds one of the
  /// provider's connections) and the device free to sleep. Keep watching opens it again, where it
  /// was.
  Future<void> _sleepNow() async {
    if (_stopped) return;
    _sleep.off();
    _slept = true;
    await _stopPlayback();
  }

  @override
  Future<void> _stopPlayback() async {
    // The lock is for a picture playing: with it stopped, its panel's way out must work
    _lockHintTimer?.cancel();
    if (mounted) setState(() => _locked = _lockHint = false);
    await _saveProgress();
    _session++; // a reopen under way is stale now
    _watchdog?.cancel();
    // A recording ends here too, saved; the channel comes back directly if watching goes on. One
    // scheduled of it goes on, on a connection of its own
    _tapChannel(off: true);
    if (_recording != null) await _stopRecording();
    final relay = _relay;
    _relay = null;
    await relay?.close();
    await player.stop();
    sayStopped(this); // the screensaver may come
    if (_mediaSaid != null) {
      _mediaSaid = null;
      unawaited(BackgroundPlay.hide(this)); // and the device may sleep
    }
    if (!mounted) return;
    setState(() {
      _paused = true;
      _reconnecting = false;
      _flash = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _wakeFocus.context != null ? _wakeFocus.requestFocus() : null);
  }

  void _wake() {
    setState(() {
      _slept = false;
      _sentAway = null;
    });
    _focus.requestFocus();
    unawaited(_open());
  }

  /// Louder than the stream allows (some providers' audio is low): an audio filter in mpv, kept
  /// for the rest of this session.
  Future<void> _setBoost(int db) async {
    // The gain mpv gives what has no ReplayGain tag, which is everything here; the libmpv this app
    // ships has no lavfi volume filter, and with it set the next stream opened without sound
    await setPlayerProperty(player, 'replaygain-fallback', '$db');
    if (mounted) setState(() => _boost = db);
  }

  BoxFit get _boxFit => switch (_fit) {
    'cover' => BoxFit.cover,
    'fill' => BoxFit.fill,
    _ => BoxFit.contain, // a shape of its own is fitted whole too
  };

  /// The shape the picture is drawn at, for a stream whose own is wrong (a 4:3 broadcast sent
  /// squeezed, a film cropped); null for the stream's own.
  double? get _aspect => switch (_fit) {
    '16:9' => 16 / 9,
    '4:3' => 4 / 3,
    '21:9' => 21 / 9,
    _ => null,
  };

  String _fitLabel(AppLocalizations l, String fit) => switch (fit) {
    'contain' => l.fitContain,
    'cover' => l.fitCover,
    'fill' => l.fitFill,
    _ => fit, // "16:9"
  };

  /// The picture's fit, kept for next time: a phone's long screen is often best zoomed.
  void _setFit(String fit) {
    setState(() => _fit = fit);
    SettingsScope.maybeOf(context)?.set(videoFit: fit);
    _flashText(_fitLabel(context.l10n, fit), time: const Duration(milliseconds: 900));
    _poke();
  }

  void _nextFit() => _setFit(_pictureFits[(_pictureFits.indexOf(_fit) + 1) % _pictureFits.length]);

  Future<void> _readFps() async {
    if (!mounted) return;
    final fps = double.tryParse(await playerProperty(player, 'container-fps'));
    if (mounted && fps != _fps) setState(() => _fps = fps);
  }

  /// What the stream is, for the stream info panel: read from mpv every second while it shows.
  Future<void> _readDetails() async {
    final l = context.l10n;
    final [format, vbits, acodec, abits, rate, hwdec, cache, drops, switched] = await Future.wait([
      for (final name in [
        'video-format',
        'video-bitrate',
        'audio-codec-name',
        'audio-bitrate',
        'audio-params/samplerate',
        'hwdec-current',
        'demuxer-cache-duration',
        'frame-drop-count',
        // A browser's film that went over to software by itself: why (see capy-movi.js); '' elsewhere
        'capy-switched',
      ])
        playerProperty(player, name),
    ]);
    if (!mounted) return;
    final st = player.state;
    String bits(String v) {
      final b = double.tryParse(v) ?? 0;
      return b >= 1e6 ? '${(b / 1e6).toStringAsFixed(1)} Mb/s' : (b > 0 ? '${(b / 1e3).round()} kb/s' : '');
    }

    String join(List<String?> parts) => parts.whereType<String>().where((p) => p.isNotEmpty).join(' · ');
    final w = st.videoParams.dw ?? st.width, h = st.videoParams.dh ?? st.height;
    final hz = int.tryParse(rate) ?? 0;
    final hardware = hwdec.isNotEmpty && hwdec != 'no';
    setState(
      () => _details = [
        (
          l.infoVideo,
          join([
            if (w != null && h != null && w > 0) '$w×$h',
            format,
            if ((_fps ?? 0) > 0) '${_fps!.toStringAsFixed(2)} fps',
          ]),
        ),
        (l.audio, join([acodec, _channels(l, st.audioParams.channelCount), if (hz > 0) '${hz ~/ 1000} kHz'])),
        (l.infoDecoder, hardware ? '${l.decoderHw} ($hwdec)' : (switched.isNotEmpty ? l.decoderSwAuto : l.decoderSw)),
        (l.infoBitrate, join([bits(vbits), bits(abits)])),
        (l.infoBuffer, '${(double.tryParse(cache) ?? 0).toStringAsFixed(1)} s'),
        (l.infoDropped, drops.isEmpty ? '0' : drops),
        if (_sources.length > 1) (l.infoCopy, l.nOfTotal(_source + 1, _sources.length)),
      ],
    );
  }

  /// "STEREO", "5.1"... from how many channels the audio has.
  static String? _channels(AppLocalizations l, int? n) => switch (n) {
    null || 0 => null,
    1 => l.channelsMono,
    2 => l.channelsStereo,
    3 => '2.1',
    6 => '5.1',
    8 => '7.1',
    _ => '$n.0',
  };

  /// "FHD", "60 FPS", "5.1": what the stream is, at a glance.
  List<String> _badges(PlayerState st, AppLocalizations l) {
    final w = st.videoParams.dw ?? st.width ?? 0, h = st.videoParams.dh ?? st.height ?? 0;
    final lines = math.max(h, w * 9 ~/ 16); // a wide film's 1920×800 is still full HD
    final res = lines >= 2000
        ? '4K'
        : lines >= 1400
        ? 'QHD'
        : lines >= 1000
        ? 'FHD'
        : lines >= 700
        ? 'HD'
        : lines > 0
        ? 'SD'
        : null;
    final fps = _fps;
    return [?res, if (fps != null && fps > 0) l.fpsBadge(fps.round()), ?_channels(l, st.audioParams.channelCount)];
  }

  /// The series of the episode playing, by its title.
  String? get _seriesTitle => _item.ref?.kind == MediaKind.episode ? _item.ref?.seriesTitle : null;

  /// "Skip intro" shows while the marked opening titles play.
  bool _introOffered(PlayerState st) =>
      !_introSkipped &&
      IntroMarks.complete(_intro) &&
      st.position >= _intro!.start! - const Duration(seconds: 1) &&
      st.position < _intro!.end! - const Duration(seconds: 2);

  void _skipIntro() {
    _seekTo(_intro!.end!);
    setState(() => _introSkipped = true);
  }

  /// Marks where the opening titles start or end, at the position playing; both null clears them.
  Future<void> _markIntro({bool start = false, bool end = false, bool clear = false}) async {
    final series = _seriesTitle;
    if (series == null) return;
    final at = player.state.position;
    final intro = clear ? (start: null, end: null) : (start: start ? at : _intro?.start, end: end ? at : _intro?.end);
    await IntroMarks.save(series, intro);
    if (mounted) setState(() => _intro = clear ? null : intro);
  }

  /// "Next episode" shows in an episode's last half minute, the one after it ready to start.
  bool _nextOffered(PlayerState st) =>
      !_item.isLive &&
      _hasNext &&
      !_nextCancelled &&
      _started &&
      st.duration >= const Duration(minutes: 1) && // not a clip
      st.duration - st.position <= const Duration(seconds: 30) &&
      st.position < st.duration;

  /// The other decoder, now: a new player opens what plays where it was, with this session's
  /// speed, volume and boost; the old one lets go.
  /// Switches to the [hardware] decoder or the software one; says which is in use after (the one
  /// before, when another switch was still going on).
  Future<bool> _switchDecoder(bool hardware) async {
    // One at a time: two at once would each let go of the same player and leave one playing unseen
    if (hardware == widget.engine.hardware || _decoderBusy) return widget.engine.hardware;
    _decoderBusy = true;
    final st = player.state, at = st.position;
    final Player old;
    try {
      old = await widget.engine.switchDecoder(hardware: hardware);
    } finally {
      _decoderBusy = false;
    }
    if (!mounted) {
      unawaited(old.dispose());
      return widget.engine.hardware;
    }
    _listen(); // the new player's streams
    setState(() {});
    unawaited(old.stop().whenComplete(old.dispose));
    await player.setVolume(st.volume);
    if (st.rate != 1) await player.setRate(st.rate);
    if (_boost != 0) await _setBoost(_boost);
    await _open(sameItem: true, from: _live ? null : at);
    return widget.engine.hardware;
  }

  /// Plays this on another device of the account, from here; here it pauses.
  Future<void> _sendTo() async {
    _panelOpen = true;
    final position = _live ? Duration.zero : player.state.position;
    final to = await sendTo(context, ref: _item.ref, item: _item, position: position);
    _panelOpen = false;
    if (to == null || !mounted) return;
    switch (to) {
      case SentToDevice(:final name, :final active):
        // One that was about a moment ago plays it: this one saves where it was and lets go of the
        // stream, one connection for the provider; sent to one that may be asleep, it goes on here
        if (active) {
          _sentAway = name;
          await _stopPlayback();
        } else {
          _flashText(context.l10n.sentToDevice(name), time: const Duration(seconds: 3));
        }
      case CastToDevice(:final device):
        await _castTo(device, position);
    }
  }

  /// What a cast does not take of what plays here (F04-007): the subtitles showing, an audio
  /// track chosen other than the video's first, which the TV plays. Said as it goes, in words.
  Future<List<String>> _lostOnCast() async {
    final picked = await selectedTracks(player);
    if (!mounted) return const [];
    final l = context.l10n;
    final audio = realTracks(player.state.tracks.audio);
    return [
      if (picked.sub.isNotEmpty && picked.sub != 'no') l.castNoSubtitles,
      if (audio.length > 1 && picked.audio.isNotEmpty && picked.audio != audio.first.id) l.castOtherAudio,
    ];
  }

  /// The TV plays it now: this player notes where it was and makes way for the cast's remote, so
  /// the provider sees one connection.
  Future<void> _castTo(ChromecastDevice device, Duration position) async {
    await _saveProgress();
    if (_recording != null) await _stopRecording();
    final lost = await _lostOnCast();
    if (!mounted) return;
    // A live channel reaches the TV through this app: an iPhone stops it once the app leaves the screen
    if (_item.isLive && !RecordingKeepAlive.survivesBackground) _tell(context.l10n.keepAppOpenToCast);
    // F04-007: what plays here and not there is said, rather than found missing on the TV
    if (lost.isNotEmpty) _tell(lost.join(' '));
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => CastScreen(device: device, item: _item, from: position, queue: widget.items, index: _index),
      ),
    );
  }

  void _lock() {
    setState(() {
      _locked = true;
      _visible = false;
    });
    _showLockHint();
  }

  void _showLockHint() {
    _lockHintTimer?.cancel();
    setState(() => _lockHint = true);
    _lockHintTimer = Timer(const Duration(seconds: 3), () => mounted ? setState(() => _lockHint = false) : null);
  }

  void _unlock() {
    _lockHintTimer?.cancel();
    setState(() => _locked = _lockHint = false);
    _poke();
  }

  KeyEventResult _handled(void Function() f) {
    f();
    return KeyEventResult.handled;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (_stopped) return KeyEventResult.ignored; // the remote is on its panel's buttons
    if (e is KeyDownEvent) _stillWatching();
    final k = e.logicalKey;
    // A key held repeats: moving and zapping should, play/pause and the rest flicker on and off
    if (e is KeyRepeatEvent && !_repeats.contains(k)) return KeyEventResult.handled;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK || k == LogicalKeyboardKey.mediaPlayPause) {
      return _handled(_togglePlay);
    }
    // The media keys of TV remotes (Fire TV, Android TV) and keyboards, with or without the controls
    if (k == LogicalKeyboardKey.mediaPlay) return _handled(() => player.state.playing ? _poke() : _togglePlay());
    if (k == LogicalKeyboardKey.mediaPause) return _handled(() => player.state.playing ? _togglePlay() : _poke());
    if (k == LogicalKeyboardKey.mediaFastForward) return _handled(() => _seekBy(_skip));
    if (k == LogicalKeyboardKey.mediaRewind) return _handled(() => _seekBy(-_skip));
    if (k == LogicalKeyboardKey.mediaTrackNext) return _handled(() => _go(1));
    if (k == LogicalKeyboardKey.mediaTrackPrevious) return _handled(() => _go(-1));
    if (k == LogicalKeyboardKey.contextMenu) return _handled(_openTracks); // the ☰ button: audio and subtitles
    // The computer's small window: Esc and F bring the window back as it was (in full screen if
    // it was); P makes it small and back
    if (Pip.desktop && Pip.active.value && (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.keyF)) {
      return _handled(Pip.leave);
    }
    if (k == LogicalKeyboardKey.keyP && _pip && Pip.desktop) {
      return _handled(() => Pip.active.value ? Pip.leave() : _enterPip());
    }
    if (k == LogicalKeyboardKey.keyF) return _handled(() => _setFullscreen(!_fullscreen));
    if (k == LogicalKeyboardKey.keyA) return _handled(_openTracks);
    if (k == LogicalKeyboardKey.keyM) return _handled(_toggleMute);
    if (k == LogicalKeyboardKey.escape && _fullscreen && !_mobile) return _handled(() => _setFullscreen(false));
    // With the controls hidden the remote behaves like in TV apps:
    // left/right skip, OK toggles pause and any other key shows the controls.
    if (k == LogicalKeyboardKey.channelUp) return _handled(() => _go(1));
    if (k == LogicalKeyboardKey.channelDown) return _handled(() => _go(-1));
    if (!_visible) {
      // Live: up/down zap through the channel list, like a TV
      if (_item.isLive && k == LogicalKeyboardKey.arrowUp) return _arrowAgain(k, () => _go(-1));
      if (_item.isLive && k == LogicalKeyboardKey.arrowDown) return _arrowAgain(k, () => _go(1));
      if (k == LogicalKeyboardKey.arrowLeft) return _arrowAgain(k, () => _seekBy(-_skip));
      if (k == LogicalKeyboardKey.arrowRight) return _arrowAgain(k, () => _seekBy(_skip));
      // A channel stays live: OK shows what is on rather than freezing it
      if (_ok.contains(k) && _item.isLive) return _handled(_poke);
      if (_ok.contains(k)) return _handled(_okOnPlayer);
      // The volume keys are the system's: taken here, the first press only showed the controls
      if (_systemVolume.contains(k)) {
        _poke();
        return KeyEventResult.ignored;
      }
      return _handled(_poke);
    }
    _poke();
    // Shown, but with the focus still on the picture (paused, or before the first arrow): OK is
    // still the player's, or it would do nothing at all
    if (_ok.contains(k) && _focus.hasPrimaryFocus) return _handled(_okOnPlayer);
    // The controls are there but the focus is still on the player (it starts there, and goes back as
    // they hide): an arrow takes it to them, at play, and from there the arrows move it
    final arrow = [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    ].contains(k);
    // More of the same: on zapping or skipping, the controls it brought up notwithstanding
    final vertical = k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown;
    final last = _lastArrow;
    if (arrow && _focus.hasPrimaryFocus && last != null && DateTime.now().isBefore(_arrowUntil)) {
      final lastVertical = last == LogicalKeyboardKey.arrowUp || last == LogicalKeyboardKey.arrowDown;
      if (vertical == lastVertical && (!vertical || _item.isLive)) {
        return _arrowAgain(k, () {
          if (k == LogicalKeyboardKey.arrowUp) _go(-1);
          if (k == LogicalKeyboardKey.arrowDown) _go(1);
          if (k == LogicalKeyboardKey.arrowLeft) _seekBy(-_skip);
          if (k == LogicalKeyboardKey.arrowRight) _seekBy(_skip);
        });
      }
    }
    if (arrow && _focus.hasPrimaryFocus && _playFocus.context != null) return _handled(_playFocus.requestFocus);
    return KeyEventResult.ignored; // with the controls visible, arrows move the focus
  }

  static final _repeats = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.mediaFastForward,
    LogicalKeyboardKey.mediaRewind,
    LogicalKeyboardKey.channelUp,
    LogicalKeyboardKey.channelDown,
    LogicalKeyboardKey.audioVolumeUp,
    LogicalKeyboardKey.audioVolumeDown,
  };

  static final _systemVolume = {
    LogicalKeyboardKey.audioVolumeUp,
    LogicalKeyboardKey.audioVolumeDown,
    LogicalKeyboardKey.audioVolumeMute,
  };

  static final _ok = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  /// OK takes what is offered on screen, as in TV apps; else play or pause.
  void _okOnPlayer() {
    if (_introOffered(player.state)) return _skipIntro();
    if (_nextOffered(player.state)) {
      _go(1);
      return;
    }
    _togglePlay();
  }

  /// A side panel over the picture; [title] is its name to a screen reader, said as it opens.
  Future<void> _openPanel(String title, Widget Function(BuildContext) builder) async {
    _panelOpen = true;
    _poke();
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (ctx, _, _) => Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: title,
        child: _SidePanel(child: builder(ctx)),
      ),
      transitionBuilder: (_, anim, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
    _panelOpen = false;
    _poke();
  }

  void _openTracks() => _openPanel(
    context.l10n.audioAndSubtitles,
    (_) => _TracksPanel(player: player, direct: isAndroid && widget.engine.hardware),
  );

  /// The player opened anew at the live picture (through the relay, or back from it): its watch
  /// on the stream's time starts over, playing, not behind.
  @override
  void _openedAgainLive() {
    _lastPosition = Duration.zero;
    _reopened = _moved = clock.now();
    _paused = false;
    _behind = Duration.zero;
  }

  /// Several channels at once, this one first: this player makes way for them.
  Future<void> _openMultiview() async {
    final channels = [
      for (final i in widget.items)
        if (i.isLive) i,
    ];
    // A recording under way stops with its notice, as for a cast, rather than cut off unsaid; and
    // this player lets go of the channel, which the provider would otherwise see asked for twice
    if (_recording != null) await _stopRecording();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    await player.stop();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => MultiviewScreen(first: _item, channels: channels),
      ),
    );
  }

  void _openSpeed() => _openPanel(context.l10n.speed, (ctx) => _SpeedPanel(player: player));

  void _openList() => _openPanel(
    _item.isLive ? context.l10n.playerChannels : context.l10n.playerEpisodes,
    (ctx) => _QueuePanel(
      title: _item.isLive ? ctx.l10n.playerChannels : ctx.l10n.playerEpisodes,
      items: widget.items,
      current: _index,
      onPick: (i) {
        Navigator.pop(ctx);
        _go(i - _index);
      },
    ),
  );

  void _openSettings() => _openPanel(
    context.l10n.playerSettings,
    (ctx) => _SettingsPanel(
      sleep: _sleep,
      live: _live,
      boost: _boost,
      info: _info,
      fit: _fit,
      fitLabel: (f) => _fitLabel(ctx.l10n, f),
      onChanged: () => setState(() {}),
      onBoost: _setBoost,
      onInfo: (on) {
        setState(() => _info = on);
        if (on) _readDetails();
      },
      onFit: _setFit,
      hardware: widget.engine.hardware,
      onDecoder: _switchDecoder,
      intro: _seriesTitle == null ? null : () => _intro,
      onIntro: _markIntro,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final st = player.state;
    final big = MediaQuery.sizeOf(context).shortestSide >= 600;
    final settings = SettingsScope.maybeOf(context);
    final subtitleBand = settings?.subtitleBackground ?? false;
    // Save while the player is still alive: once the route pops, playQueue disposes it
    return PopScope(
      canPop: !_locked || _stopped, // back too waits for the lock, unless nothing plays any more
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _saveProgress();
        } else if (_locked) {
          _showLockHint();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: MouseRegion(
            cursor: _visible ? MouseCursor.defer : SystemMouseCursors.none,
            onHover: (_) => _poke(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // In a browser a file plays in movi, whose picture is its own; elsewhere this is
                // the Video below as it is
                MoviPicture(
                  key: ObjectKey(player),
                  player: player,
                  fit: _fit,
                  aspect: _aspect,
                  video: Video(
                    key: ObjectKey(widget.controller), // a new one when the decoder changes
                    controller: widget.controller,
                    controls: NoVideoControls,
                    // With the sound on in the background, leaving the app does not pause
                    pauseUponEnteringBackgroundMode: !_background,
                    fit: _boxFit,
                    aspectRatio: _aspect,
                    subtitleViewConfiguration: SubtitleViewConfiguration(
                      // Without it media_kit scales the text down to the screen's share of 1080p, half
                      // on a TV; with it the system's text size counts too
                      textScaler: MediaQuery.textScalerOf(context),
                      style: TextStyle(
                        fontFamily: appFont,
                        fontSize: subtitleSize(MediaQuery.sizeOf(context).height, settings?.subtitleScale ?? 100),
                        height: 1.3,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        backgroundColor: subtitleBand
                            ? Colors.black.withValues(alpha: (settings?.subtitleBandDarkness ?? 70) / 100)
                            : null,
                        shadows: subtitleBand
                            ? null
                            : (settings?.subtitleOutline ?? false)
                            ? _subtitleOutline
                            : const [Shadow(blurRadius: 8), Shadow(blurRadius: 2, offset: Offset(1, 1))],
                      ),
                      // Higher when Settings says so, and over the controls while they show
                      padding: EdgeInsets.fromLTRB(
                        32,
                        0,
                        32,
                        (_visible && !Pip.active.value ? (big ? 170 : 150) : 44) +
                            MediaQuery.sizeOf(context).height * (settings?.subtitleLift ?? 0) / 100,
                      ),
                    ),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _locked
                      ? _showLockHint
                      : () {
                          _stillWatching(); // a touch after the sleep timer's warning
                          _visible ? setState(() => _visible = false) : _poke();
                        },
                  onVerticalDragStart: _touch ? _verticalStart : null,
                  onVerticalDragUpdate: _touch
                      ? (d) => _verticalMove(d.delta.dy / MediaQuery.sizeOf(context).height)
                      : null,
                  onVerticalDragEnd: _touch ? (_) => _gestureEnd() : null,
                  onHorizontalDragUpdate: _touch && !_live
                      ? (d) => _horizontalMove(d.delta.dx / MediaQuery.sizeOf(context).width)
                      : null,
                  onHorizontalDragEnd: _touch && !_live ? (_) => _gestureEnd() : null,
                  onDoubleTapDown: (d) {
                    if (_locked) return;
                    if (!_mobile) {
                      _setFullscreen(!_fullscreen);
                      return;
                    }
                    final x = d.localPosition.dx / MediaQuery.sizeOf(context).width;
                    if (x < 0.35) _seekBy(-_skip);
                    if (x > 0.65) _seekBy(_skip);
                  },
                ),
                if ((st.buffering || _reconnecting || (_switching && !_started)) && !_failed && !_stopped)
                  const Center(child: SizedBox.square(dimension: 56, child: CircularProgressIndicator(strokeWidth: 3))),
                if ((_reconnecting || (_switching && !_started)) && !_failed)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 96,
                    child: Center(
                      child: Panel(
                        radius: AppRadius.pill,
                        color: AppColors.scrim,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        // Said as it comes, as it is seen
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _reconnecting ? context.l10n.reconnecting : context.l10n.tryingAnotherCopy,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_resumedFrom != null && !Pip.active.value)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 96,
                    child: Center(
                      child: Panel(
                        radius: AppRadius.pill,
                        color: AppColors.scrim,
                        padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              context.l10n.resumedFrom(_fmt(_resumedFrom!)),
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 10),
                            TextButton(
                              onPressed: () {
                                player.seek(Duration.zero);
                                setState(() => _resumedFrom = null);
                              },
                              child: Text(context.l10n.startOver),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_info && _details.isNotEmpty && !_stopped && !Pip.active.value)
                  Positioned(
                    left: 0,
                    top: 0,
                    child: SafeArea(
                      minimum: EdgeInsets.fromLTRB(big ? 28 : 16, big ? 104 : 80, 0, 0),
                      child: _StreamInfo(_details),
                    ),
                  ),
                if (_gesture case (:final icon, :final text))
                  Center(
                    child: Panel(
                      radius: AppRadius.pill,
                      color: AppColors.scrim,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 30),
                          const SizedBox(width: 12),
                          Text(
                            text,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_flash case final flash?)
                  Semantics(
                    liveRegion: true,
                    child: Center(
                      // A sentence (the sleep timer's warning) in smaller type, over a few lines
                      child: flash.length > 24
                          ? Padding(
                              padding: const EdgeInsets.all(24),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 560),
                                child: Panel(
                                  radius: AppRadius.panel,
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                                  child: Text(
                                    flash,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, height: 1.3),
                                  ),
                                ),
                              ),
                            )
                          : Panel(
                              radius: AppRadius.pill,
                              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                              child: Text(flash, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
                            ),
                    ),
                  ),
                if (!_locked && !_stopped && !Pip.active.value)
                  IgnorePointer(
                    ignoring: !_visible,
                    child: AnimatedOpacity(
                      opacity: _visible ? 1 : 0,
                      duration: const Duration(milliseconds: 260),
                      // Hidden, its animations (the LIVE dot) stop asking for frames
                      child: TickerMode(enabled: _visible, child: _overlay(st, big)),
                    ),
                  ),
                if (!_stopped && !_failed && !Pip.active.value && _introOffered(st))
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: SafeArea(
                      minimum: EdgeInsets.fromLTRB(0, 0, big ? 28 : 16, _visible ? (big ? 150 : 124) : (big ? 40 : 24)),
                      child: _RoundButton(
                        icon: Icons.skip_next_rounded,
                        text: context.l10n.skipIntro,
                        onTap: _skipIntro,
                      ),
                    ),
                  ),
                if (!_stopped && !_failed && !Pip.active.value && _nextOffered(st))
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: SafeArea(
                      minimum: EdgeInsets.fromLTRB(0, 0, big ? 28 : 16, _visible ? (big ? 150 : 124) : (big ? 40 : 24)),
                      child: _NextCard(
                        next: widget.items[_index + 1],
                        seconds: (st.duration - st.position).inSeconds,
                        onPlay: () => _go(1),
                        onCancel: () => setState(() => _nextCancelled = true),
                      ),
                    ),
                  ),
                if (_locked && _lockHint)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: SafeArea(
                      minimum: const EdgeInsets.only(left: 24),
                      child: Row(
                        children: [
                          _RoundButton(
                            icon: Icons.lock_rounded,
                            tooltip: context.l10n.tapToUnlock,
                            size: 56,
                            onTap: _unlock,
                          ),
                          const SizedBox(width: 14),
                          Panel(
                            radius: AppRadius.pill,
                            color: AppColors.scrim,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                            child: Text(context.l10n.tapToUnlock, style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (Pip.desktop && Pip.active.value) _MiniControls(playing: st.playing, onPlayPause: _togglePlay),
                if (_failed && !_stopped) Center(child: _unavailable()),
                if (_slept) _sleepPanel(),
                if (_sentAway case final device?) _sentPanel(device),
                if (_timeUp) _timeUpPanel(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// setState, for the screen's parts that are extensions of it (player_overlay.dart).
  void _update(VoidCallback change) => setState(change);
}

/// Subtitles' size for a screen [height] dp tall: about the Samsung app's share of it, 16 dp at least.
double subtitleSize(double height, int scale) => (height * 0.042).clamp(16.0, 56.0) * scale / 100;
