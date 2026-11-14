// In a browser: the file's sound played by a <movi-player>, so the languages can be chosen.
//
// Chrome cannot switch a <video>'s audio track (there is no audioTracks API) and the player built
// on it reports no tracks at all, so the app showed "Not available". movi-player reads the file
// itself and does know them.
//
// What plays what: media_kit keeps the picture (its <video>, which is what the app draws), and a
// hidden <movi-player> with `audioonly` plays the sound. When the user picks a language, movi is
// told and nothing else moves. The <video>'s own sound is turned down so the two are not heard at
// once — see soundTookOver.
//
// The stream has to be readable with CORS for movi (it fetches the file to demux it), so this
// takes the proxy's address when there is one: see app_url.dart.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:media_kit/media_kit.dart';

/// What movi found in the stream [player] has, and the element playing its sound; null until it
/// has been started.
final _sounds = <Player, _Sound>{};

/// The audio tracks movi read for [player]: empty natively, and until it has read the file.
List<AudioTrack> moviAudioTracks(Player player) => _sounds[player]?.tracks ?? const [];

/// Whether movi took the sound over, so the picture's own sound must keep quiet.
bool soundTookOver(Player player) => (_sounds[player]?.tracks.isNotEmpty ?? false);

/// Points a hidden, sound-only `<movi-player>` at [url] for [player], replacing whatever it had.
Future<void> startMoviSound(Player player, String url, {double volume = 100, int tries = 8}) async {
  stopMoviSound(player);
  final sound = _Sound(player, volume);
  _sounds[player] = sound;
  for (var i = 0; i < tries; i++) {
    if (await sound.open(url)) return;
    if (!identical(_sounds[player], sound)) return; // another stream came meanwhile
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }
  stopMoviSound(player);
}

/// Lets go of the sound and its element, giving the picture's own audio back.
void stopMoviSound(Player player) {
  _sounds.remove(player)?.dispose();
}

/// The language picked for [track], given to movi; false where it was not its sound.
Future<bool> selectMoviAudio(Player player, AudioTrack track) async {
  final sound = _sounds[player];
  if (sound == null) return false;
  return sound.select(track.id);
}

/// The sound's volume, 0 to 100, as the app's own.
void setMoviVolume(Player player, double volume) => _sounds[player]?.setVolume(volume);

/// The sound pauses, plays, seeks and changes speed with the picture.
void moviPlay(Player player) => _sounds[player]?.play();
void moviPause(Player player) => _sounds[player]?.pause();
void moviSeek(Player player, Duration at) => _sounds[player]?.seek(at);
void moviRate(Player player, double rate) => _sounds[player]?.setRate(rate);

@JS('document.createElement')
external JSObject _createElement(JSString tag);

@JS('document.body.appendChild')
external JSObject _appendChild(JSObject child);

@JS('customElements.whenDefined')
external JSPromise<JSAny?> _whenDefined(JSString name);

/// Whether the element was registered, and its script compiled: the import in web/index.html
/// defines it asynchronously, so the first ask may come before it exists.
var _ready = false;

/// Waits for `<movi-player>` to be defined: the import in web/index.html defines it
/// asynchronously, so the first ask may come before it exists.
Future<bool> _ensureDefined() async {
  if (_ready) return true;
  try {
    await _whenDefined('movi-player'.toJS).toDart;
    _ready = true;
    return true;
  } on Object catch (e) {
    debugPrint('movi: whenDefined failed: $e');
    return false; // no customElements at all (not a browser page of ours)
  }
}

JSObject? _newElement() {
  try {
    final el = _createElement('movi-player'.toJS);
    // The element builds its player when it enters the document (connectedCallback), not when it
    // is made: it has to be added first, and asked then.
    _appendChild(el);
    return el;
  } on Object catch (e) {
    debugPrint('movi: createElement failed: $e');
    return null;
  }
}

class _Sound {
  _Sound(this.player, this.volume);

  final Player player;
  double volume;
  JSObject? _element;
  Timer? _poll;
  var _disposed = false;
  var _picking = false;

  List<AudioTrack> tracks = const [];

  /// The engine behind the element, or null.
  JSObject? get _engine {
    final e = _element?.getProperty<JSAny?>('player'.toJS);
    return e.isUndefinedOrNull ? null : e as JSObject;
  }

  Future<bool> open(String url) async {
    if (!await _ensureDefined()) return false; // the element's script did not load
    final element = _element ??= _newElement();
    if (element == null || _disposed) return false;
    try {
      // Attributes, not properties: movi reads these as HTML attributes (a bare `audioonly`), the
      // way a page writes them. The sound only: the picture is the app's own <video>.
      element.callMethod('setAttribute'.toJS, 'audioonly'.toJS, ''.toJS);
      element.callMethod('setAttribute'.toJS, 'muted'.toJS, ''.toJS);
      element.callMethod(
        'setAttribute'.toJS,
        'style'.toJS,
        'position:fixed;width:2px;height:2px;left:-20px;top:-20px;opacity:0'.toJS,
      );
      element.callMethod('setAttribute'.toJS, 'volume'.toJS, '${volume / 100}'.toJS);
      // Its player is made by setting the source: src first, then ask
      element.setProperty('src'.toJS, url.toJS);
    } on Object catch (e) {
      debugPrint('movi: opening failed: $e');
      return false;
    }
    // The player appears a moment after the source is set
    for (var i = 0; i < 30 && _engine == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (_disposed) return false;
    }

    final done = Completer<bool>();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 400), (timer) async {
      if (_disposed || done.isCompleted) return timer.cancel();
      final found = _readTracks();
      if (found.isEmpty) {
        // A file is demuxed a few seconds after its header arrives; an HLS manifest names its
        // tracks at once, so nothing to wait for there
        if (timer.tick > 120) {
          timer.cancel();
          done.complete(false);
        }
        return;
      }
      timer.cancel();
      tracks = found;
      // Its sound from the start, at the app's volume
      try {
        _engine?.callMethod('play'.toJS);
      } on Object {
        // A browser that will not start it without a gesture: the picture's sound does, and this
        // one joins at the next play (the app has had the user's click by then)
      }
      done.complete(true);
    });
    return done.future;
  }

  List<AudioTrack> _readTracks() {
    try {
      final list = _engine?.callMethod('getAudioTracks'.toJS).dartify();
      if (list is! List) return const [];
      final out = <AudioTrack>[];
      for (final (i, raw) in list.indexed) {
        if (raw is! Map) continue;
        int? id;
        var language = '', title = '';
        for (final e in raw.entries) {
          final k = '${e.key}', v = e.value;
          if (k == 'id' && v is num) id = v.toInt();
          if (k == 'language' && v is String) language = v;
          if (k == 'title' && v is String) title = v;
        }
        out.add(AudioTrack('${id ?? i + 1}', title.isEmpty ? null : title, language.isEmpty ? null : language));
      }
      return out;
    } on Object {
      return const [];
    }
  }

  bool select(String id) {
    if (_picking) return false;
    _picking = true;
    try {
      final ok = _engine?.callMethod('selectAudioTrack'.toJS, (int.tryParse(id) ?? 1).toJS).dartify();
      return ok == true;
    } on Object {
      return false;
    } finally {
      _picking = false;
    }
  }

  void setVolume(double v) {
    volume = v;
    try {
      _element?.setProperty('volume'.toJS, (v / 100).toJS);
    } on Object {
      // Gone
    }
  }

  void play() => _call('play');
  void pause() => _call('pause');

  void seek(Duration at) {
    try {
      _element?.setProperty('currentTime'.toJS, (at.inMilliseconds / 1000).toJS);
    } on Object {
      // Gone
    }
  }

  void setRate(double rate) {
    try {
      _engine?.callMethod('setPlaybackRate'.toJS, rate.toJS);
    } on Object {
      // Gone
    }
  }

  void _call(String name) {
    try {
      _element?.callMethod(name.toJS);
    } on Object {
      // Gone
    }
  }

  void dispose() {
    _disposed = true;
    _poll?.cancel();
    try {
      _element?.callMethod('remove'.toJS);
    } on Object {
      // Already gone
    }
    _element = null;
    tracks = const [];
  }
}
