import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/provider_client.dart';

/// How a recording with no player ended.
enum RecorderEnd {
  /// Stopped from outside ([ChannelRecorder.stop]); never said of an end by itself.
  stopped,

  /// The provider stopped giving the channel for a long while: another connection is to go on in
  /// the same file.
  dropped,

  /// The channel turned into one that cannot be recorded (encrypted, another format): what it has
  /// is kept.
  refused,

  /// The channel ended by itself, written to its end (an HLS playlist that closes).
  finished,

  /// The file could not be written further (no room left): what it has is kept.
  writeFailed,

  /// The channel came as HLS, a list of pieces rather than one stream, which this recorder cannot
  /// write down.
  hls,

  /// What it recorded from (the player's relay) no longer gets the channel: another
  /// connection is to go on in the same file.
  released,
}

/// A channel being recorded with no player, until it is stopped.
abstract interface class ChannelRecorder {
  /// Bytes written so far.
  int get bytes;

  /// Completes once it ended, and its file is closed.
  Future<RecorderEnd> get done;

  Future<void> stop();
}

/// Starts recording [url] into [file], after what the file has.
typedef StartRecorder = Future<ChannelRecorder> Function(
  String url,
  File file, {
  Map<String, String> headers,
  void Function(Object error)? onWriteError,
});

/// The recorder for HLS channels (.m3u8), set at start (startHlsChannelRecorder); without one they
/// are not recorded.
StartRecorder? hlsRecorder;

bool isHlsUrl(String url) => Uri.tryParse(url)?.path.toLowerCase().endsWith('.m3u8') ?? false;

/// The recorder for [url]; null when there is none for it (udp://, rtmp:// and such are not asked
/// for over HTTP).
StartRecorder? recorderFor(String url) {
  final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return isHlsUrl(url) ? hlsRecorder : BackgroundRecorder.start;
}

/// Records a channel that comes as one stream (MPEG-TS, as the player gets it) into a file, with
/// no player: for recordings scheduled from the guide. A stream that drops, stalls or is refused is
/// asked for again, a little later each time up to [lastRetry], and goes on in the same file.
class BackgroundRecorder implements ChannelRecorder {
  BackgroundRecorder._(this.source, this.file, Map<String, String> headers, this._onWriteError)
    // As the player asks for it, mpv's own, unless the playlist says otherwise
    : _headers = {'User-Agent': 'libmpv', ...headers};

  /// Waits between tries: the first, doubled each time up to the last.
  @visibleForTesting
  static var firstRetry = const Duration(seconds: 1), lastRetry = const Duration(seconds: 30);

  /// A stream that sends nothing this long is taken as dropped; also a provider that does not answer.
  @visibleForTesting
  static var stallTimeout = const Duration(seconds: 20);

  /// A connection that lasted this long was a good one: when it drops, the stream is asked for again
  /// at once. A shorter one (a provider that answers with a few seconds' clip, "not on air" or
  /// "limit reached", and hangs up) is asked for again later each time, as one refused.
  @visibleForTesting
  static var healthy = const Duration(seconds: 30);

  static Future<ChannelRecorder> start(
    String url,
    File file, {
    Map<String, String> headers = const {},
    void Function(Object error)? onWriteError,
  }) async {
    final r = BackgroundRecorder._(Uri.parse(url), file, headers, onWriteError);
    r._open();
    unawaited(r._run());
    return r;
  }

  final Uri source;
  final File file;
  final Map<String, String> _headers;
  final void Function(Object error)? _onWriteError;
  HttpClient? _client; // the connection's: one each, so one that ends is gone and never used again
  final _done = Completer<RecorderEnd>();
  IOSink? _sink;
  StreamSubscription<List<int>>? _upstream;
  Completer<void>? _wake; // the wait between tries, cut short by stop
  Completer<void>? _connection; // ends with the provider's stream, or with stop
  var _ending = false;
  var _bytes = 0;

  /// Times the provider was asked for the stream.
  @visibleForTesting
  var tries = 0;

  @override
  int get bytes => _bytes;

  @override
  Future<RecorderEnd> get done => _done.future;

  @override
  Future<void> stop() async {
    await _end(RecorderEnd.stopped);
    await done;
  }

  void _open() {
    final sink = _sink = file.openWrite(mode: FileMode.append);
    sink.done.catchError((Object e) {
      if (_sink != sink) return;
      _sink = null;
      if (_ending) return;
      _onWriteError?.call(e);
      unawaited(_end(RecorderEnd.writeFailed));
    });
    // Opens the file now: one that cannot be opened is said like any write that fails
    sink.add(const <int>[]);
  }

  Future<void> _run() async {
    var wait = firstRetry;
    final lasted = Stopwatch();
    while (!_ending) {
      lasted
        ..reset()
        ..start();
      if (await _once() && lasted.elapsed >= healthy) wait = firstRetry;
      if (_ending) break;
      await _pause(wait);
      wait = Duration(milliseconds: min(wait.inMilliseconds * 2, lastRetry.inMilliseconds));
    }
  }

  /// One connection to the provider, until it ends; true when something came through.
  Future<bool> _once() async {
    tries++;
    final client = _client = providerHttpClient();
    try {
      return await _read(client);
    } on Object {
      return false;
    } finally {
      client.close(force: true); // lets go of the provider
      if (_client == client) _client = null;
    }
  }

  Future<bool> _read(HttpClient client) async {
    final request = await client.getUrl(source);
    _headers.forEach(request.headers.set);
    // Connected, but no answer: as a stream that stalls
    final up = await request.close().timeout(stallTimeout);
    final hls = (up.headers.contentType?.mimeType.toLowerCase() ?? '').contains('mpegurl');
    if (hls) unawaited(_end(RecorderEnd.hls));
    if (_ending || up.statusCode >= 400 || hls) return false;
    var first = true, got = false;
    final ended = _connection = Completer<void>();
    void finish([Object? _]) {
      if (!ended.isCompleted) ended.complete();
    }

    _upstream = up
        .timeout(stallTimeout)
        .listen(
          (chunk) {
            if (first) {
              first = false;
              // An HLS list sent as something else
              if (chunk.length >= 7 && String.fromCharCodes(chunk.take(7)) == '#EXTM3U') {
                unawaited(_end(RecorderEnd.hls));
                return;
              }
            }
            got = true;
            _bytes += chunk.length;
            _sink?.add(chunk);
          },
          onError: finish,
          onDone: finish,
          cancelOnError: true,
        );
    await ended.future;
    _upstream = null;
    return got;
  }

  Future<void> _pause(Duration d) {
    final wake = _wake = Completer<void>();
    final timer = Timer(d, () => wake.isCompleted ? null : wake.complete());
    return wake.future.whenComplete(timer.cancel);
  }

  Future<void> _end(RecorderEnd how) async {
    if (_ending) return;
    _ending = true;
    for (final c in [_wake, _connection]) {
      if (c != null && !c.isCompleted) c.complete();
    }
    final up = _upstream;
    _upstream = null;
    await _quietly(() async => up?.cancel());
    final sink = _sink;
    _sink = null;
    // Not flush(): on a sink that failed it would wait forever
    await _quietly(() async => sink?.close());
    _client?.close(force: true);
    _done.complete(how);
  }
}

Future<void> _quietly(Future<void> Function() f) async {
  try {
    await f();
  } on Object {
    // Gone already
  }
}
