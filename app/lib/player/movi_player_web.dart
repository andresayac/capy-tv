// The app's player in a browser, behind media_kit's Player so the player screen reads it like
// any other: a film or an episode (a file) plays in a <movi-player>, an HLS or DASH stream (the
// live channels) in the browser's own <video>, as before.
//
// Why movi for files, measured on the panel's films (2026-11-11): the <video> plays AC-3 and E-AC-3
// without sound, cannot open AVI, FLV or MPG, cannot switch the audio language, and fails on the
// newest 10-bit HEVC films. movi reads the file itself (FFmpeg in WebAssembly), decodes with the
// device's hardware through WebCodecs, lists and switches the languages, and with the fixes in
// web/movi/capy-movi.js plays those HEVC films too, falling back to software decoding when the
// hardware gives no picture.
//
// The picture is the container this player owns (see [CapyWebPlayer.viewType]), shown by
// [MoviPicture]; the <video> is still shown by media_kit's own Video widget.
//
// movi reads the file with fetch, so the file must be readable with CORS: the address given is
// the video proxy's (see app_url.dart). If movi cannot open it at all, the same file is given to
// the <video> instead, as the app did before.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

@JS('document.createElement')
external JSObject _createElement(JSString tag);

@JS('customElements.whenDefined')
external JSPromise<JSAny?> _whenDefined(JSString name);

/// A player for the app: files in movi, streams in the browser's <video>.
Player newPlayer({required bool hardware}) {
  const configuration = PlayerConfiguration(logLevel: MPVLogLevel.warn);
  return Player(
    configuration: configuration,
    platformPlayer: CapyWebPlayer(configuration: configuration, hardware: hardware),
  );
}

/// Whether [player] plays the file itself, picture and sound, with its languages: true while
/// movi has it. The hidden sound element of movi_sound.dart is then not wanted.
bool playsFilesItself(Player player) {
  final p = player.platform;
  return p is CapyWebPlayer && p.moviActive.value;
}

/// How long a file may take to show its first frame in movi before the player screen gives up:
/// it reads the file's head and probes it first, which through a proxy took up to half a minute.
const moviStartTimeout = Duration(seconds: 45);

/// The picture of [player]: movi's container while it plays a file, [video] otherwise.
/// [fit] is the app's picture fit ("contain", "cover", "fill", or a shape such as "16:9", whose
/// ratio is [aspect]).
class MoviPicture extends StatelessWidget {
  const MoviPicture({super.key, required this.player, required this.video, required this.fit, this.aspect});

  final Player player;
  final Widget video;
  final String fit;
  final double? aspect;

  @override
  Widget build(BuildContext context) {
    final p = player.platform;
    if (p is! CapyWebPlayer) return video;
    return ValueListenableBuilder<bool>(
      valueListenable: p.moviActive,
      builder: (context, movi, _) {
        if (!movi) return video;
        // A shape of its own: the box takes it, and the picture fills the box
        final shaped = aspect != null;
        p.setFit(shaped ? 'fill' : (fit == 'cover' || fit == 'fill' ? fit : 'contain'));
        Widget view = HtmlElementView(viewType: p.viewType);
        if (shaped) {
          view = Center(
            child: AspectRatio(aspectRatio: aspect!, child: view),
          );
        }
        // Text subtitles in the app's own style and place, as over its Video elsewhere: movi's
        // text comes through the player (see capy-movi.js, watchSubtitles)
        final subtitles = switch (video) {
          Video(:final controller, :final subtitleViewConfiguration) when subtitleViewConfiguration.visible =>
            SubtitleView(
              // Its padding is read once: a new one when the controls move it
              key: ValueKey(subtitleViewConfiguration.padding),
              controller: controller,
              configuration: subtitleViewConfiguration,
            ),
          _ => null,
        };
        // The app's own widgets take every touch and click; the picture is only a picture
        return IgnorePointer(
          child: ColoredBox(
            color: const Color(0xFF000000),
            child: Stack(fit: StackFit.expand, children: [view, ?subtitles]),
          ),
        );
      },
    );
  }
}

/// media_kit's [PlatformPlayer] over movi (files) and media_kit's own [WebPlayer] (streams).
class CapyWebPlayer extends PlatformPlayer {
  CapyWebPlayer({required super.configuration, required this.hardware})
    : _video = WebPlayer(configuration: configuration) {
    _container = _createElement('div'.toJS);
    _container.callMethod(
      'setAttribute'.toJS,
      'style'.toJS,
      'width:100%;height:100%;background:#000;overflow:hidden;pointer-events:none'.toJS,
    );
    viewType = 'capy-movi-${_count++}';
    final container = _container;
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) => container);
    _listener = ((JSObject e) => _onCapy(e)).toJS;
    _container.callMethod('addEventListener'.toJS, 'capy'.toJS, _listener);
    _forwardVideo();
    _video.waitForPlayerInitialization.then((_) {
      if (!completer.isCompleted) completer.complete();
    });
  }

  static var _count = 0;

  /// Whether to decode on the device's hardware first; false starts in software, as the app's
  /// decoder setting says.
  final bool hardware;

  /// The browser's own player, for streams and as the fallback.
  final WebPlayer _video;

  /// Whether movi plays what is open; the picture to show follows it.
  final moviActive = ValueNotifier<bool>(false);

  /// The platform view of movi's container.
  late final String viewType;

  late final JSObject _container;
  late final JSFunction _listener;
  JSObject? _host;
  final _subs = <StreamSubscription<dynamic>>[];
  var _disposed = false;

  // What was asked of the one playing now
  Media? _media;
  var _session = 0;
  var _wantPlay = true;
  var _started = false; // movi showed a picture or moved on: its errors are the app's then
  var _fellBack = false; // movi could not open it, the <video> has it
  var _prefsApplied = false;
  var _moviState = 'idle'; // movi's own word for where it is, from its last event

  /// movi's states before the picture moves: the element says "paused" through all of them.
  static const _gettingGoing = {'idle', 'loading', 'ready', 'seeking', 'buffering'};

  // Kept across items and backends
  double _volume = 100;
  double _rate = 1;
  List<String> _preferAudio = const [];
  List<String> _preferSubtitles = const [];
  var _subtitlesOff = false;

  /// What the decode guard last said: why the hardware was left for software, '' while it holds.
  final decoderNote = ValueNotifier<String>('');

  // -------------------------------------------------------------------------------------------
  // Preferences, from the app's settings (see props_web.dart)

  /// Audio languages to start on, in order: codes as a file writes them ("spa", "es"...).
  void preferAudio(List<String> codes) => _preferAudio = [for (final c in codes) c.trim().toLowerCase()];

  /// Subtitle languages to start on; none means the file's own default.
  void preferSubtitles(List<String> codes) {
    _preferSubtitles = [for (final c in codes) c.trim().toLowerCase()];
    _subtitlesOff = false;
  }

  /// No subtitles unless asked for.
  void preferSubtitlesOff() {
    _subtitlesOff = true;
    _preferSubtitles = const [];
  }

  /// mpv's [name] as far as movi can say, for the stream info; null while the <video> plays.
  String? property(String name) {
    final host = _host;
    if (!moviActive.value || host == null) return null;
    try {
      final info = host.callMethod<JSAny?>('info'.toJS).dartify();
      if (info is Map) return '${info[name] ?? ''}';
    } on Object {
      // A host that went meanwhile
    }
    return '';
  }

  /// movi's objectfit: contain, cover, fill.
  void setFit(String fit) {
    try {
      _host?.callMethod('setFit'.toJS, fit.toJS);
    } on Object {
      // Not there yet: the next one takes the fit it is given
    }
  }

  // -------------------------------------------------------------------------------------------
  // Opening

  /// movi's host, once its script has loaded; null where it did not (no WebCodecs, an old
  /// browser, the file missing): the <video> plays everything then.
  Future<JSObject?> _ensureHost() async {
    if (_host != null) return _host;
    try {
      await _whenDefined('movi-player'.toJS).toDart.timeout(const Duration(seconds: 10));
      for (var i = 0; i < 100; i++) {
        final api = globalContext.getProperty<JSAny?>('capyMovi'.toJS);
        if (!api.isUndefinedOrNull) {
          return _host = (api as JSObject).callMethod<JSObject>('create'.toJS, _container);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } on Object catch (e) {
      debugPrint('movi: not available ($e); files play in <video>');
    }
    return null;
  }

  /// A file movi should read: anything but an HLS or DASH manifest, which the browser's player
  /// streams (and which movi was not measured on), or an Xtream live channel: a .ts that never
  /// ends, which movi cannot read (it reads a file by its length and ranges).
  static bool _isFile(String uri) {
    final path = (Uri.tryParse(uri)?.path ?? uri).toLowerCase();
    // Through the proxy the stream's own address is in its query
    final inner = Uri.tryParse(uri)?.queryParameters['u'];
    final innerPath = inner == null ? '' : (Uri.tryParse(inner)?.path ?? inner).toLowerCase();
    bool stream(String p) => p.endsWith('.m3u8') || p.endsWith('.m3u') || p.endsWith('.mpd') || p.startsWith('/live/');
    return !stream(path) && !stream(innerPath);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (_disposed) return;
    final session = ++_session;
    final Media? media = switch (playable) {
      Media m => m,
      Playlist(:final medias, :final index) when medias.isNotEmpty => medias[index.clamp(0, medias.length - 1)],
      _ => null,
    };
    _media = media;
    _wantPlay = play;
    _started = false;
    _fellBack = false;
    _prefsApplied = false;
    decoderNote.value = '';
    if (media == null) return stop();

    final host = _isFile(media.uri) ? await _ensureHost() : null;
    if (session != _session || _disposed) return;
    if (host == null) return _openVideo(media, play: play);

    // movi: the <video> lets go first, and nothing it says from now on counts
    moviActive.value = true;
    if (_video.state.playlist.medias.isNotEmpty) await _video.stop();
    _reset(Playlist([media]));
    _moviState = 'idle';
    _setBuffering(true);
    _setPlaying(play);
    try {
      host.callMethod('setVolume'.toJS, (_volume / 100).toJS);
      host.callMethod('setRate'.toJS, _rate.toJS);
      host.callMethod(
        'open'.toJS,
        media.uri.toJS,
        {'start': (media.start?.inMilliseconds ?? 0) / 1000, 'hardware': hardware, 'paused': !play}.jsify(),
      );
    } on Object catch (e) {
      debugPrint('movi: open failed ($e); trying <video>');
      return _openVideo(media, play: play);
    }
  }

  Future<void> _openVideo(Media media, {required bool play}) async {
    _host?.callMethod('close'.toJS);
    moviActive.value = false;
    _reset(Playlist([media]));
    if (_video.state.volume != _volume) await _video.setVolume(_volume);
    await _video.open(media, play: play);
    if (_rate != 1) await _video.setRate(_rate);
  }

  /// Back to nothing, as media_kit's players do on opening, with what carries over.
  void _reset(Playlist playlist) {
    state = PlayerState().copyWith(
      volume: _volume,
      rate: _rate,
      pitch: state.pitch,
      playlistMode: state.playlistMode,
      audioDevice: state.audioDevice,
      audioDevices: state.audioDevices,
      playlist: playlist,
    );
    _add(playlistController, playlist);
    _add(playingController, false);
    _add(completedController, false);
    _add(positionController, Duration.zero);
    _add(durationController, Duration.zero);
    _add(bufferingController, false);
    _add(bufferController, Duration.zero);
    _add(audioParamsController, const AudioParams());
    _add(videoParamsController, const VideoParams());
    _add(trackController, Track());
    _add(tracksController, Tracks());
    _add(widthController, null);
    _add(heightController, null);
    _add(subtitleController, const ['', '']);
  }

  // -------------------------------------------------------------------------------------------
  // What movi says

  void _onCapy(JSObject event) {
    if (_disposed || !moviActive.value) return;
    final raw = event.getProperty<JSAny?>('detail'.toJS).dartify();
    if (raw is! Map) return;
    final d = {for (final e in raw.entries) '${e.key}': e.value};
    final type = d['type'] as String? ?? '';
    final s = d['state'] as String? ?? 'idle';

    if (type == 'subtitle') {
      // The cue on screen now, its lines as lines; '' for none
      final text = d['subtitle'] as String? ?? '';
      final lines = [text, ''];
      state = state.copyWith(subtitle: lines);
      _add(subtitleController, lines);
      return;
    }
    if (type == 'decoder') {
      final why = d['why'] as String? ?? '';
      if (why.isNotEmpty) {
        decoderNote.value = why;
        _add(logController, PlayerLog(prefix: 'movi', level: 'info', text: 'software decoding: $why'));
      }
      return; // the new element has nothing to say yet
    }
    if (type == 'error') {
      final message = d['message'] as String? ?? 'error';
      // It never opened: the <video> gets a try, as the app played files before
      final media = _media;
      if (!_started && !_fellBack && media != null) {
        _fellBack = true;
        debugPrint('movi: could not open the file ($message); trying <video>');
        unawaited(_openVideo(media, play: _wantPlay));
        return;
      }
      _setBuffering(false);
      _setPlaying(false);
      _add(errorController, message);
      return;
    }

    if (d['tracks'] case final Map tracks) _setTracks(tracks);

    // A new element with nothing read yet reports a zero time: not where the film is
    final loaded = s != 'idle' && s != 'loading';
    final w = (d['w'] as num?)?.toInt() ?? 0, h = (d['h'] as num?)?.toInt() ?? 0;
    if (w > 0 && h > 0 && (w != state.width || h != state.height)) {
      state = state.copyWith(width: w, height: h);
      _add(widthController, w);
      _add(heightController, h);
      final params = VideoParams(w: w, h: h, dw: w, dh: h, aspect: w / h);
      state = state.copyWith(videoParams: params);
      _add(videoParamsController, params);
    }
    final duration = _secs(d['duration']);
    if (duration > Duration.zero && duration != state.duration) {
      state = state.copyWith(duration: duration);
      _add(durationController, duration);
    }
    if (loaded) {
      final position = _secs(d['t']);
      if (position != state.position) {
        state = state.copyWith(position: position);
        _add(positionController, position);
        if (position > const Duration(milliseconds: 500)) _started = true;
      }
      final buffer = _secs(d['buffered']);
      if (buffer != state.buffer) {
        state = state.copyWith(buffer: buffer);
        _add(bufferController, buffer);
      }
    }
    if (w > 0) _started = true;

    _moviState = s;
    final ended = type == 'ended' || d['ended'] == true || s == 'ended';
    // movi says "paused" until the picture moves. mpv and the <video> say "playing" from the
    // moment they are asked to, and the screen draws its pause button and spinner from that:
    // a play button through the whole load reads as a film that stopped.
    _setPlaying(!ended && (d['paused'] != true || (_wantPlay && _gettingGoing.contains(s))));
    if (ended != state.completed) {
      state = state.copyWith(completed: ended);
      _add(completedController, ended);
    }
    _setBuffering(!ended && (s == 'loading' || s == 'buffering' || s == 'seeking' || (s == 'idle' && !_started)));

    final volume = ((d['volume'] as num?)?.toDouble() ?? _volume / 100) * 100;
    if ((volume - state.volume).abs() > 0.01) {
      state = state.copyWith(volume: volume);
      _add(volumeController, volume);
    }
    final rate = (d['rate'] as num?)?.toDouble() ?? _rate;
    if ((rate - state.rate).abs() > 0.001) {
      state = state.copyWith(rate: rate);
      _add(rateController, rate);
    }
  }

  void _setBuffering(bool on) {
    if (on == state.buffering) return;
    state = state.copyWith(buffering: on);
    _add(bufferingController, on);
  }

  void _setPlaying(bool on) {
    if (on == state.playing) return;
    state = state.copyWith(playing: on);
    _add(playingController, on);
  }

  void _setTracks(Map raw) {
    List<Map<String, Object?>> list(Object? v) => [
      if (v is List)
        for (final t in v)
          if (t is Map) {for (final e in t.entries) '${e.key}': e.value},
    ];
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    final audioRaw = list(raw['audio']), subsRaw = list(raw['subtitles']);
    final audio = [
      for (final t in audioRaw)
        AudioTrack(
          '${(t['id'] as num?)?.toInt()}',
          text(t['title']),
          text(t['language']),
          codec: text(t['codec']),
          channelscount: (t['channels'] as num?)?.toInt(),
        ),
    ];
    final subtitles = [
      for (final t in subsRaw)
        SubtitleTrack('${(t['id'] as num?)?.toInt()}', text(t['title']), text(t['language']), codec: text(t['codec'])),
    ];
    final audioOn = (raw['audioOn'] as num?)?.toInt(), subtitleOn = (raw['subtitleOn'] as num?)?.toInt();
    final tracks = Tracks(
      video: [VideoTrack.auto(), VideoTrack.no()],
      audio: [AudioTrack.auto(), AudioTrack.no(), ...audio],
      subtitle: [SubtitleTrack.auto(), SubtitleTrack.no(), ...subtitles],
    );
    final track = Track(
      video: VideoTrack.auto(),
      audio: audio.firstWhere((t) => t.id == '$audioOn', orElse: AudioTrack.auto),
      subtitle: subtitles.firstWhere((t) => t.id == '$subtitleOn', orElse: SubtitleTrack.no),
    );
    state = state.copyWith(tracks: tracks, track: track);
    _add(tracksController, tracks);
    _add(trackController, track);
    // The sound heard: its channels and rate, for the stream info ("5.1 · 48 kHz")
    final on = audioRaw.where((t) => (t['id'] as num?)?.toInt() == audioOn).firstOrNull;
    if (on != null) {
      final params = AudioParams(
        sampleRate: (on['sampleRate'] as num?)?.toInt(),
        channelCount: (on['channels'] as num?)?.toInt(),
      );
      if (params != state.audioParams) {
        state = state.copyWith(audioParams: params);
        _add(audioParamsController, params);
      }
    }
    if (!_prefsApplied && audio.isNotEmpty) {
      _prefsApplied = true;
      _applyPreferences(audioRaw, subsRaw, audioOn, subtitleOn);
    }
  }

  /// The languages the app's settings ask for, once per item, as mpv's alang and slang do.
  void _applyPreferences(
    List<Map<String, Object?>> audio,
    List<Map<String, Object?>> subtitles,
    int? audioOn,
    int? subtitleOn,
  ) {
    int? match(List<Map<String, Object?>> tracks, List<String> codes) {
      for (final code in codes) {
        for (final t in tracks) {
          if ((t['language'] as String? ?? '').toLowerCase() == code) return (t['id'] as num?)?.toInt();
        }
      }
      return null;
    }

    final host = _host;
    if (host == null) return;
    final a = match(audio, _preferAudio);
    if (a != null && a != audioOn) host.callMethod('selectAudio'.toJS, a.toJS);
    if (_subtitlesOff) {
      if (subtitleOn != null) host.callMethodVarArgs('selectSubtitle'.toJS, [null]);
    } else {
      final s = match(subtitles, _preferSubtitles);
      if (s != null && s != subtitleOn) host.callMethod('selectSubtitle'.toJS, s.toJS);
    }
  }

  static Duration _secs(Object? v) =>
      v is num && v.isFinite && v > 0 ? Duration(microseconds: (v * 1e6).round()) : Duration.zero;

  void _add<T>(StreamController<T> c, T value) {
    if (!c.isClosed) c.add(value);
  }

  // -------------------------------------------------------------------------------------------
  // What the <video> says, while it plays

  void _forwardVideo() {
    final s = _video.stream;
    void on<T>(Stream<T> stream, StreamController<T> to) {
      _subs.add(
        stream.listen((v) {
          if (moviActive.value || _disposed) return;
          state = _video.state;
          _add(to, v);
        }),
      );
    }

    on(s.playlist, playlistController);
    on(s.playing, playingController);
    on(s.completed, completedController);
    on(s.position, positionController);
    on(s.duration, durationController);
    on(s.volume, volumeController);
    on(s.rate, rateController);
    on(s.pitch, pitchController);
    on(s.buffering, bufferingController);
    on(s.bufferingPercentage, bufferingPercentageController);
    on(s.buffer, bufferController);
    on(s.playlistMode, playlistModeController);
    on(s.shuffle, shuffleController);
    on(s.audioParams, audioParamsController);
    on(s.videoParams, videoParamsController);
    on(s.audioBitrate, audioBitrateController);
    on(s.audioDevice, audioDeviceController);
    on(s.audioDevices, audioDevicesController);
    on(s.track, trackController);
    on(s.tracks, tracksController);
    on(s.width, widthController);
    on(s.height, heightController);
    on(s.subtitle, subtitleController);
    on(s.log, logController);
    on(s.error, errorController);
  }

  // -------------------------------------------------------------------------------------------
  // Controls

  void _call(String name, [JSAny? arg]) {
    try {
      if (arg == null) {
        _host?.callMethod(name.toJS);
      } else {
        _host?.callMethod(name.toJS, arg);
      }
    } on Object {
      // A host that went meanwhile
    }
  }

  @override
  Future<void> play() async {
    _wantPlay = true;
    if (!moviActive.value) return _video.play();
    _call('play');
    // Still loading, movi says nothing until it gets going: the button answers the tap now
    if (_gettingGoing.contains(_moviState)) _setPlaying(true);
  }

  @override
  Future<void> pause() async {
    _wantPlay = false;
    if (!moviActive.value) return _video.pause();
    _call('pause');
    if (_gettingGoing.contains(_moviState)) _setPlaying(false);
  }

  @override
  Future<void> playOrPause() => state.playing ? pause() : play();

  @override
  Future<void> seek(Duration duration) async {
    if (!moviActive.value) return _video.seek(duration);
    _call('seek', (duration.inMilliseconds / 1000).toJS);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 100).toDouble();
    if (!moviActive.value) return _video.setVolume(_volume);
    _call('setVolume', (_volume / 100).toJS);
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    if (!moviActive.value) return _video.setRate(rate);
    _call('setRate', rate.toJS);
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    if (!moviActive.value) return _video.setAudioTrack(track);
    final id = int.tryParse(track.id);
    if (id != null) _call('selectAudio', id.toJS);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    if (!moviActive.value) {
      // Before anything opened (the settings' "off"): a preference, for whichever plays
      if (track.id == 'no' && state.playlist.medias.isEmpty) _subtitlesOff = true;
      return _video.setSubtitleTrack(track);
    }
    if (track.id == 'no') {
      _host?.callMethodVarArgs('selectSubtitle'.toJS, [null]);
      return;
    }
    final id = int.tryParse(track.id);
    if (id != null) _call('selectSubtitle', id.toJS);
  }

  @override
  Future<void> setVideoTrack(VideoTrack track) async {
    if (!moviActive.value) return _video.setVideoTrack(track);
  }

  @override
  Future<void> stop() async {
    _session++;
    _media = null;
    if (moviActive.value) {
      _call('close');
      _reset(const Playlist([]));
      return;
    }
    await _video.stop();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _session++;
    _call('close');
    try {
      _container.callMethod('removeEventListener'.toJS, 'capy'.toJS, _listener);
    } on Object {
      // Gone with the page
    }
    for (final s in _subs) {
      await s.cancel();
    }
    try {
      await _video.dispose();
    } on Object {
      // Already let go
    }
    // moviActive and decoderNote are left to the garbage collector: the player screen's picture
    // may still listen while its route animates away
    await super.dispose();
  }

  // The rest is the <video>'s: a playlist of one, as the app uses it

  @override
  Future<void> add(Media media) => _video.add(media);

  @override
  Future<void> remove(int index) => _video.remove(index);

  @override
  Future<void> next() => _video.next();

  @override
  Future<void> previous() => _video.previous();

  @override
  Future<void> jump(int index) => _video.jump(index);

  @override
  Future<void> move(int from, int to) => _video.move(from, to);

  @override
  Future<void> setPlaylistMode(PlaylistMode playlistMode) => _video.setPlaylistMode(playlistMode);

  @override
  Future<void> setPitch(double pitch) => _video.setPitch(pitch);

  @override
  Future<void> setShuffle(bool shuffle) => _video.setShuffle(shuffle);

  @override
  Future<void> setAudioDevice(AudioDevice audioDevice) => _video.setAudioDevice(audioDevice);

  @override
  Future<Uint8List?> screenshot({String? format = 'image/jpeg', bool includeLibassSubtitles = false}) async {
    if (moviActive.value) return null;
    return _video.screenshot(format: format, includeLibassSubtitles: includeLibassSubtitles);
  }

  /// The <video>'s: media_kit's Video widget finds its element by it.
  @override
  Future<int> get handle => _video.handle;
}
