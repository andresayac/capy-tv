// A player for the player screen's tests: it opens what it is given, starts what [starts] lets
// start (its time moving on, a picture of a size), or fails with an error; and the test moves its
// time on, freezes it, or ends it. What was opened, and where, is kept.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:iptv_player/player/play.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class FakePlayer implements Player {
  FakePlayer({this.starts = _always, this.length = const Duration(hours: 2)});

  /// Whether a stream at this address starts; one that does not sends an error.
  final bool Function(String url) starts;

  /// How long what starts is.
  final Duration length;

  static bool _always(String _) => true;

  /// What was opened, in order.
  final opened = <Media>[];
  final seeks = <Duration>[];

  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _error = StreamController<String>.broadcast();

  @override
  PlatformPlayer? platform;

  @override
  var state = const PlayerState();

  @override
  late final stream = PlayerStream(
    const Stream.empty(), // playlist
    _playing.stream,
    _completed.stream,
    _position.stream,
    _duration.stream,
    const Stream.empty(), // volume
    const Stream.empty(), // rate
    const Stream.empty(), // pitch
    const Stream.empty(), // buffering
    const Stream.empty(), // bufferingPercentage
    const Stream.empty(), // buffer
    const Stream.empty(), // playlistMode
    const Stream.empty(), // shuffle
    const Stream.empty(), // audioParams
    const Stream.empty(), // videoParams
    const Stream.empty(), // audioBitrate
    const Stream.empty(), // audioDevice
    const Stream.empty(), // audioDevices
    const Stream.empty(), // track
    const Stream.empty(), // tracks
    const Stream.empty(), // width
    const Stream.empty(), // height
    const Stream.empty(), // subtitle
    const Stream.empty(), // log
    _error.stream,
  );

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    opened.add(media);
    if (!starts(media.uri)) {
      state = const PlayerState();
      // As mpv does: the error once the open has returned
      scheduleMicrotask(() => _error.add('Failed to open ${media.uri}'));
      return;
    }
    final from = media.start ?? Duration.zero;
    state = PlayerState(playing: true, duration: length, position: from, width: 1920, height: 1080);
    scheduleMicrotask(() {
      _duration.add(length);
      _playing.add(true);
      moveTo(from + const Duration(seconds: 1));
    });
  }

  /// Its time, as the stream plays.
  void moveTo(Duration position) {
    state = state.copyWith(position: position);
    _position.add(position);
  }

  /// What plays comes to its end.
  void end() {
    moveTo(state.duration);
    state = state.copyWith(playing: false, completed: true);
    _completed.add(true);
  }

  @override
  Future<void> seek(Duration duration) async {
    seeks.add(duration);
    moveTo(duration);
  }

  @override
  Future<void> stop() async => state = state.copyWith(playing: false);

  @override
  Future<void> pause() async => state = state.copyWith(playing: false);

  @override
  Future<void> play() async => state = state.copyWith(playing: true);

  @override
  Future<void> playOrPause() async => state = state.copyWith(playing: !state.playing);

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class FakeVideo implements VideoController {
  FakeVideo(this.player);

  @override
  final Player player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  final id = ValueNotifier<int?>(null);
  @override
  final rect = ValueNotifier<Rect?>(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeEngine implements PlaybackEngine {
  FakeEngine(this.player) : controller = FakeVideo(player);

  @override
  Player player;
  @override
  VideoController controller;
  @override
  bool hardware = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
