import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';

import '../platform.dart' show isWeb;
import 'app_url.dart';
import 'off_thread.dart';
import 'provider_client.dart';
import 'source.dart';

/// An image that could not be had: the server said no, or did not answer.
class ImageUnavailable implements Exception {
  const ImageUnavailable();
}

/// Where the catalogs' posters, logos and backdrops come from: the disk when seen before, else the
/// line, a few at a time and what has just come on screen first. A catalog's images are many, on
/// hosts that are often slow or dead, and a TV stick can neither open dozens of connections at once
/// nor bring a whole screen of them again on each start.
class ImageStore {
  ImageStore({http.Client? client, Future<Directory?> Function()? directory, Duration Function()? elapsed})
    : _client = client ?? _quickClient(),
      _directory = directory ?? _cacheDirectory,
      _elapsed = elapsed ?? _stopwatch();

  /// A host that does not even take the connection is given up on in [_wait] too: the abort in
  /// [_download] only reaches a request the host took. A browser keeps its own connections.
  /// Posters are mostly on the provider's own hosts: their certificates are taken as its lists'
  /// are (see provider_http.dart).
  static http.Client _quickClient() => isWeb ? http.Client() : IOClient(providerHttpClient());

  static final instance = ImageStore();

  final http.Client _client;
  final Future<Directory?> Function() _directory;
  final Duration Function() _elapsed;

  /// How many images come over the line at once.
  var maxDownloads = 6;

  /// What the images on disk may take: past it the ones seen longest ago go. None, none are kept.
  var diskBytes = 300 << 20;

  /// How long the server has to answer, and then to send each piece.
  static const _wait = Duration(seconds: 15);

  /// The most an image may weigh: more is no poster, and would be held whole in memory.
  static const _heaviest = 12 << 20;

  /// How long an image that failed is left alone: one the server refused does not come back soon,
  /// and one that did not answer may have been the line.
  static const _refused = Duration(hours: 1), _silent = Duration(minutes: 1);

  final _wanted = <String, int>{};
  final _loading = <String, Future<Uint8List>>{};
  final _waiting = <_Waiting>[];
  final _failed = <String, DateTime>{}; // until when each is left alone, oldest first
  var _running = 0, _asked = 0;
  Future<Directory?>? _dir;

  /// What the images on disk take, as the last trim found it (null until the first has looked), and
  /// what was written since it began: together never less than there is (a file written again or
  /// deleted still counts), so at worst a trim too many.
  int? _onDisk;
  var _added = 0;
  Future<void>? _trimming;

  static Duration Function() _stopwatch() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  static Future<Directory?> _cacheDirectory() async =>
      Directory('${(await getApplicationCacheDirectory()).path}/images').create(recursive: true);

  /// The place for the images, trimmed once when first asked for: [diskBytes] may be less than the
  /// last time, with less room on the device.
  Future<Directory?> get _place => _dir ??= () async {
    try {
      final dir = await _directory();
      // Trimmed to nothing when there is no room now: what earlier days kept goes too
      if (dir != null) unawaited(_trim(dir));
      if (diskBytes <= 0) return null;
      return dir;
    } on Object {
      return null; // no platform to ask (tests), no room: no disk, that is all
    }
  }();

  /// Something on screen shows [url]. Until as many [unwant]s, its image may come; once nothing
  /// shows it, it stops waiting for its turn.
  void want(String url) => _wanted.update(url, (n) => n + 1, ifAbsent: () => 1);

  /// See [want].
  void unwant(String url) {
    final left = _wanted[url]! - 1;
    if (left > 0) {
      _wanted[url] = left;
      return;
    }
    _wanted.remove(url);
    _waiting.removeWhere((w) {
      if (w.url != url) return false;
      w.turn.completeError(const ImageUnavailable());
      return true;
    });
  }

  /// [url]'s image as it was sent. Throws [ImageUnavailable] when it cannot be had.
  Future<Uint8List> bytes(String url) {
    final until = _failed[url];
    if (until != null) {
      if (DateTime.now().isBefore(until)) return Future.error(const ImageUnavailable());
      _failed.remove(url);
    }
    return _loading[url] ??= _load(url).whenComplete(() {
      _loading.remove(url); // not returned: it is this very future, which would wait for itself
    });
  }

  /// What came for [url] is no image: not kept, and left alone for a while.
  void forget(String url) {
    _failedFor(url, _refused);
    unawaited(() async {
      try {
        await (await _fileOf(url))?.delete();
      } on FileSystemException {
        // It was not there
      }
    }());
  }

  void _failedFor(String url, Duration time) {
    if (_failed.length >= 4096) _failed.remove(_failed.keys.first);
    _failed[url] = DateTime.now().add(time);
  }

  Future<File?> _fileOf(String url) async {
    final dir = await _place;
    return dir == null ? null : File('${dir.path}/${stableHash(url)}');
  }

  Future<Uint8List> _load(String url) async {
    // Its place now, as it was asked for: looking on the disk first, they get there in any order
    final waiting = _Waiting(url, _elapsed().inMilliseconds ~/ _sameMoment.inMilliseconds, _asked++);
    final file = await _fileOf(url);
    final kept = file == null ? null : await _kept(file);
    if (kept != null) return kept;
    await _turn(waiting);
    try {
      final bytes = await _download(url);
      if (file != null) unawaited(_keep(file, bytes));
      return bytes;
    } finally {
      _running--;
      _next();
    }
  }

  /// [file]'s bytes, when it is there and has some. Not each time noted as seen: that is a write.
  Future<Uint8List?> _kept(File file) async {
    try {
      final about = await file.stat();
      if (about.type == FileSystemEntityType.notFound || about.size == 0) return null;
      final bytes = await file.readAsBytes();
      if (DateTime.now().difference(about.modified) > const Duration(days: 1)) {
        unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
      }
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  /// Written whole or not at all, and not forced onto the disk: an image takes no waiting for, and
  /// one lost to a power cut is brought again ([forget]).
  Future<void> _keep(File file, Uint8List bytes) async {
    final part = File('${file.path}.part');
    try {
      await part.writeAsBytes(bytes);
      await part.rename(file.path);
      // The folder is gone through only once it is past what it may take: with thousands of
      // images that is a stat of each, and most of the time there is room
      _added += bytes.length;
      final onDisk = _onDisk;
      if (onDisk != null && onDisk + _added > diskBytes * 1.1) await _trim(file.parent);
    } on FileSystemException {
      // Next time, then
    }
  }

  /// One at a time: what is written meanwhile does not start another.
  Future<void> _trim(Directory dir) => _trimming ??= () async {
    _added = 0; // what is written from now on may or may not be seen by it: counted again, then
    try {
      _onDisk = await _trimOffThread(dir.path, diskBytes);
    } on Object {
      // Next time, then
    } finally {
      _trimming = null;
    }
  }();

  // Static, so what goes to the isolate holds only these two: a closure made in [_trim] would take
  // the store with it, which cannot be sent
  static Future<int> _trimOffThread(String path, int most) => runOffThread(() => trimImages(path, most));

  Future<void> _turn(_Waiting waiting) {
    if (!_wanted.containsKey(waiting.url)) throw const ImageUnavailable();
    _waiting.add(waiting);
    _next();
    return waiting.turn.future;
  }

  /// One screen's worth asked for together, in the order it was asked: top to bottom.
  static const _sameMoment = Duration(milliseconds: 200);

  /// What was asked for last goes first (it is what is on screen now), and each moment's in order.
  void _next() {
    while (_running < maxDownloads && _waiting.isNotEmpty) {
      var next = 0;
      for (var i = 1; i < _waiting.length; i++) {
        if (_waiting[i].goesBefore(_waiting[next])) next = i;
      }
      _running++;
      _waiting.removeAt(next).turn.complete();
    }
  }

  Future<Uint8List> _download(String url) async {
    // Once given up on, its connection is closed too: a timeout only stops the waiting, and a slow
    // host would keep one open for each image long after its turn went to the next
    final done = Completer<void>();
    try {
      // The address as the host gave it, except where the platform has to reach it otherwise
      // (a browser, through the proxy of app_url.dart)
      final request = http.AbortableRequest('GET', Uri.parse(imageUrl(url)), abortTrigger: done.future)
        ..headers.addAll(providerHeaders);
      final res = await _client.send(request).timeout(_wait);
      if (res.statusCode != 200 || (res.contentLength ?? 0) > _heaviest) {
        unawaited(res.stream.listen(null).cancel());
        final busy = res.statusCode >= 500 || res.statusCode == 408 || res.statusCode == 429;
        _failedFor(url, busy ? _silent : _refused);
        throw const ImageUnavailable();
      }
      final bytes = BytesBuilder(copy: false);
      await for (final piece in res.stream.timeout(_wait)) {
        bytes.add(piece);
        if (bytes.length > _heaviest) {
          _failedFor(url, _refused);
          throw const ImageUnavailable();
        }
      }
      if (bytes.isEmpty) {
        _failedFor(url, _refused);
        throw const ImageUnavailable();
      }
      return bytes.takeBytes();
    } on ImageUnavailable {
      rethrow;
    } on FormatException {
      _failedFor(url, _refused); // no address at all
      throw const ImageUnavailable();
    } on Object {
      _failedFor(url, _silent);
      throw const ImageUnavailable();
    } finally {
      if (!done.isCompleted) done.complete(); // a request that is over is not touched
    }
  }
}

class _Waiting {
  _Waiting(this.url, this.moment, this.order);

  final String url;
  final int moment, order;
  final turn = Completer<void>();

  bool goesBefore(_Waiting other) => moment != other.moment ? moment > other.moment : order < other.order;
}

/// Deletes the files in the directory at [path] seen longest ago, until the rest take no more than
/// [most] bytes. Returns what the rest take.
int trimImages(String path, int most) {
  final files = [for (final f in Directory(path).listSync().whereType<File>()) (file: f, about: f.statSync())]
    ..sort((a, b) => b.about.modified.compareTo(a.about.modified));
  var total = 0, kept = 0;
  for (final (:file, :about) in files) {
    total += about.size;
    if (total > most) {
      try {
        file.deleteSync();
        continue;
      } on FileSystemException {
        // Next time, then
      }
    }
    kept += about.size;
  }
  return kept;
}
