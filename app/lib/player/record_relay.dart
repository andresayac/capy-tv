import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/provider_client.dart';
import 'background_recorder.dart';

/// Why a channel cannot go through the relay: it comes as HLS (a list of pieces, not one stream),
/// or the relay could not get it at all.
enum RelayProblem { hls, unreachable }

/// A channel played through this app while it is recorded: a relay on this device, for this device
/// only, fetches the stream once from the provider and hands the same bytes to the player and, while
/// recording, to a file. libmpv as media_kit builds it reads video files but has no muxer to write
/// one; and a second connection just to record is one the provider may not allow.
///
/// There is one stream from the provider at a time. While recording it runs at the provider's pace
/// whatever the player does: a paused player gets up to [playerLag] kept for it, then its connection
/// ends and it joins the stream again when it plays on. Not recording, the provider waits for the
/// player. A player connecting again (after a drop) joins the stream that runs; only once the
/// provider ends it does a new one start, and the recording goes on in the same file. A provider
/// that sends nothing for [stall] is taken as gone. While recording, a stream that ended is asked
/// for again by the relay itself, whether or not the player comes back.
class RecordRelay {
  RecordRelay._(this._server, this.source, this._headers, this._onUnusable, this._onWriteError);

  final HttpServer _server;

  /// The channel's own address.
  final Uri source;
  final Map<String, String> _headers;
  final void Function(RelayProblem problem)? _onUnusable;
  final void Function(Object error)? _onWriteError;
  final _client = providerHttpClient();

  /// What a paused player may be kept while recording before its connection ends.
  @visibleForTesting
  static var playerLag = 32 << 20;

  /// A provider that sends nothing this long while read is taken as gone, and so is one that takes
  /// the connection and never answers: the stream is asked for anew rather than waited on forever.
  /// Not counted while the stream waits for the player on purpose.
  @visibleForTesting
  static var stall = const Duration(seconds: 20);

  /// Waits before the relay asks for the stream again by itself, while recording: the first,
  /// doubled each time, up to the last; the first again after a stream that lasted [healthy]. A
  /// provider that answers with a few seconds and hangs up is not asked again and again at once.
  @visibleForTesting
  static var firstRetry = const Duration(seconds: 1),
      lastRetry = const Duration(seconds: 30),
      healthy = const Duration(seconds: 30);

  StreamSubscription<List<int>>? _upstream; // the provider's stream, while it runs
  final _lasted = Stopwatch(); // how long the provider's stream has run
  Future<bool>? _connecting;
  Timer? _retry; // asking for the stream again, while recording
  var _wait = firstRetry;
  var _unusable = false; // HLS: never asked for again
  var _held = false; // the provider's stream waits for the player
  ContentType? _type;
  int? _failure; // the provider's status, when it refused
  var _passed = false; // something came through: the channel works this way
  _Player? _player;
  IOSink? _file;
  final _taps = <RelayTap>[];
  var _closed = false;

  bool get _recording => _file != null || _taps.isNotEmpty;

  static Future<RecordRelay> start(
    String url, {
    Map<String, String> headers = const {},
    void Function(RelayProblem problem)? onUnusable,
    void Function(Object error)? onWriteError,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = RecordRelay._(server, Uri.parse(url), headers, onUnusable, onWriteError);
    server.listen(relay._serve);
    return relay;
  }

  /// Where the player reads the channel.
  String get url => 'http://${_server.address.address}:${_server.port}/channel.ts';

  /// Writes what comes from now on into [file], after what it has; or, with null, stops writing. A
  /// file that cannot be written (no room left) stops by itself, and [_onWriteError] says so.
  Future<void> recordTo(File? file) async {
    final old = _file;
    _file = null;
    if (old != null) {
      try {
        await old.close(); // not flush(): on a sink that failed it would wait forever
      } on Object {
        // Said when it failed
      }
    }
    if (file != null && !_closed) {
      final sink = _file = file.openWrite(mode: FileMode.append);
      unawaited(
        sink.done.catchError((Object e) {
          if (_file != sink) return;
          _file = null;
          _balance();
          _onWriteError?.call(e);
        }),
      );
      // Opens the file now: one that cannot be opened is said like any write that fails, not left
      // as an error nobody hears until the first bytes come
      sink.add(const <int>[]);
    }
    _balance();
  }

  /// Also writes what comes from now on into [file], after what it has, alongside the player and
  /// its own recording: a recording scheduled from the guide of the channel playing, which then
  /// needs no connection of its own. It ends when stopped, when the file cannot be written further,
  /// and, [RecorderEnd.released], when the relay closes or gets nothing for [RelayTap.stall].
  RelayTap tap(File file, {void Function(Object error)? onWriteError}) {
    final tap = RelayTap._(this, file, onWriteError);
    if (_closed) {
      unawaited(tap._end(RecorderEnd.released));
    } else {
      _taps.add(tap);
      _balance();
    }
    return tap;
  }

  void _untap(RelayTap tap) {
    if (_taps.remove(tap)) _balance();
  }

  /// A connection from the player: it joins the provider's stream, which starts if none runs. The
  /// player's connection before, if any, gets nothing more.
  Future<void> _serve(HttpRequest req) async {
    _player?.stopFeeding();
    _player = null;
    if (_closed) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      return _quietly(req.response.close);
    }
    if (_upstream == null && !await (_connecting ??= _connect().whenComplete(() => _connecting = null))) {
      req.response.statusCode = _failure ?? HttpStatus.badGateway;
      return _quietly(req.response.close);
    }
    req.response
      ..headers.contentType = _type ?? ContentType('video', 'mp2t')
      ..bufferOutput = false; // what comes goes on at once, also the last bytes before a lull
    late final _Player player;
    player = _player = _Player(
      req.response,
      onPause: _balance,
      onEnd: () {
        if (_player == player) _player = null;
        _balance();
      },
    );
    _balance();
  }

  /// Opens the provider's stream. False when it cannot be had; before anything came through, that
  /// makes the channel one the relay cannot carry.
  Future<bool> _connect() async {
    final HttpClientResponse up;
    HttpClientRequest? request;
    try {
      request = await _client.getUrl(source);
      _headers.forEach(request.headers.set);
      // Connected, but no answer: as a stream that stalls
      up = await request.close().timeout(stall);
    } on Object {
      request?.abort();
      _failure = null;
      if (!_passed) _onUnusable?.call(RelayProblem.unreachable);
      return false;
    }
    final hls = (up.headers.contentType?.mimeType.toLowerCase() ?? '').contains('mpegurl');
    if (up.statusCode >= 400 || hls) {
      _failure = hls ? HttpStatus.unsupportedMediaType : up.statusCode;
      unawaited(_quietly(() async => (await up.detachSocket()).destroy())); // let go of the provider
      if (hls) {
        _unusable = true;
        _onUnusable?.call(RelayProblem.hls);
      } else if (!_passed) {
        _onUnusable?.call(RelayProblem.unreachable);
      }
      return false;
    }
    _type = up.headers.contentType;
    var first = true;
    // Its timer stops while the subscription is paused: a stream held for the player is not "gone"
    _upstream =
        up
            .timeout(stall)
            .listen(
              (chunk) {
                if (first) {
                  first = false;
                  // An HLS list sent as something else
                  if (chunk.length >= 7 && String.fromCharCodes(chunk.take(7)) == '#EXTM3U') {
                    _unusable = true;
                    _endUpstream(cancel: true);
                    _onUnusable?.call(RelayProblem.hls);
                    return;
                  }
                }
                _passed = true;
                _file?.add(chunk);
                if (_taps.isNotEmpty) {
                  for (final tap in List.of(_taps)) {
                    tap._add(chunk);
                  }
                }
                _player?.add(chunk, keepUp: _recording);
              },
              onError: (Object _) => _endUpstream(),
              onDone: _endUpstream,
              cancelOnError: true,
            )
          // Held until whoever asked for it is in place ([_balance]): what came with the answer
          // would otherwise go by before the player that asked for it is fed
          ..pause();
    _held = true;
    _lasted
      ..reset()
      ..start();
    return true;
  }

  /// The provider's stream ended (or is ended): the player's connection ends with it, and the player
  /// opens a new one, which starts a new stream.
  void _endUpstream({bool cancel = false}) {
    final up = _upstream;
    _upstream = null;
    _held = false;
    if (cancel) unawaited(up?.cancel());
    _player?.stopFeeding();
    _player = null;
    if (_lasted.elapsed >= healthy) _wait = firstRetry; // it worked a good while: at once again
    _again();
  }

  /// While recording, a stream that ended is asked for again by the relay itself, a little later
  /// each time nothing comes: the player may be paused, or gone to its error panel, and not come back
  /// for it. A player that comes first starts it as ever, and this one is not needed.
  void _again() {
    _retry?.cancel();
    _retry = null;
    if (_closed || _unusable || !_recording) return;
    _retry = Timer(_wait, () async {
      _retry = null;
      if (_closed || !_recording || _upstream != null) return;
      _wait = Duration(milliseconds: min(_wait.inMilliseconds * 2, lastRetry.inMilliseconds));
      if (await (_connecting ??= _connect().whenComplete(() => _connecting = null))) {
        _balance();
      } else if (_upstream == null) {
        _again();
      }
    });
  }

  /// The provider's stream waits only while nothing needs it: no recording, and the player paused
  /// or gone.
  void _balance() {
    if (!_recording) {
      _retry?.cancel(); // nothing to ask for it again for
      _retry = null;
    }
    final up = _upstream;
    if (up == null) return;
    final wait = !_recording && (_player?.paused ?? true);
    if (wait && !_held) {
      _held = true;
      up.pause();
    } else if (!wait && _held) {
      _held = false;
      up.resume();
    }
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    _retry = null;
    _player?.stopFeeding();
    _player = null;
    final up = _upstream;
    _upstream = null;
    await up?.cancel();
    await recordTo(null);
    for (final tap in List.of(_taps)) {
      await tap._end(RecorderEnd.released);
    }
    _client.close(force: true);
    await _server.close(force: true);
  }
}

Future<void> _quietly(Future<void> Function() f) async {
  try {
    await f();
  } on Object {
    // The other end is gone
  }
}

/// A file the relay writes alongside the player (see [RecordRelay.tap]).
class RelayTap implements ChannelRecorder {
  RelayTap._(this._relay, File file, this._onWriteError) {
    final sink = _sink = file.openWrite(mode: FileMode.append);
    sink.done.catchError((Object e) {
      if (_sink != sink || _ending) return;
      _sink = null;
      _onWriteError?.call(e);
      unawaited(_end(RecorderEnd.writeFailed));
    });
    sink.add(const <int>[]); // opens the file now, as [RecordRelay.recordTo] does
    _watch = Timer.periodic(stall, (_) {
      if (_bytes == _seen) unawaited(_end(RecorderEnd.released));
      _seen = _bytes;
    });
  }

  /// Nothing came this long (the provider dropped and the player gave up): it is let go, to go on
  /// on a connection of its own.
  @visibleForTesting
  static var stall = const Duration(seconds: 60);

  final RecordRelay _relay;
  final void Function(Object error)? _onWriteError;
  IOSink? _sink;
  late final Timer _watch;
  final _done = Completer<RecorderEnd>();
  var _bytes = 0, _seen = 0;
  var _ending = false;

  @override
  int get bytes => _bytes;

  @override
  Future<RecorderEnd> get done => _done.future;

  @override
  Future<void> stop() async {
    await _end(RecorderEnd.stopped);
    await done;
  }

  void _add(List<int> chunk) {
    _bytes += chunk.length;
    _sink?.add(chunk);
  }

  Future<void> _end(RecorderEnd how) async {
    if (_ending) return;
    _ending = true;
    _watch.cancel();
    _relay._untap(this);
    final sink = _sink;
    _sink = null;
    // Not flush(): on a sink that failed it would wait forever
    await _quietly(() async => sink?.close());
    _done.complete(how);
  }
}

/// The player's connection: fed what the provider sends, at the player's pace.
class _Player {
  _Player(this._response, {required this.onPause, required this.onEnd}) {
    _feed = StreamController<List<int>>(
      onPause: () {
        paused = true;
        onPause();
      },
      onResume: () {
        paused = false;
        _lag = 0;
        onPause();
      },
    );
    () async {
      await _quietly(() async {
        await _response.addStream(_feed.stream);
        await _response.close();
      });
      await _quietly(_response.close);
      _end();
    }();
  }

  final HttpResponse _response;
  final void Function() onPause, onEnd;
  late final StreamController<List<int>> _feed;
  var paused = false;
  var _lag = 0; // kept for it while paused
  var _fed = true;
  var _ended = false;

  /// Hands [chunk] on. With [keepUp] (recording) the provider does not wait for the player: past
  /// [RecordRelay.playerLag] kept for it, it is fed no more and its connection ends once it has read
  /// that.
  void add(List<int> chunk, {required bool keepUp}) {
    if (!_fed) return;
    _feed.add(chunk);
    if (!paused) return;
    _lag += chunk.length;
    if (keepUp && _lag > RecordRelay.playerLag) stopFeeding();
  }

  void stopFeeding() {
    if (!_fed) return;
    _fed = false;
    _feed.close();
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    paused = false;
    stopFeeding();
    onEnd();
  }
}
