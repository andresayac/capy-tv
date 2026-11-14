import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:http/http.dart' as http;

import '../platform.dart';
import 'epg.dart';
import 'models.dart';
import 'stable_hash.dart';

/// A source with a full record for each movie (Xtream's get_vod_info): synopsis, cast, backdrop,
/// trailer, TMDB id, all that listings leave out.
abstract interface class MovieDetails {
  Future<Movie> movieDetail(Movie m);
}

/// A source that can be told nobody needs it any more (the playlist was left): the lists and guide
/// it is still downloading stop there, and are not read, instead of competing with the next one
/// for the line, the memory and the cores. What is asked of it afterwards fails.
abstract interface class Closable {
  void close();
}

/// A source that keeps its whole lists in memory and can let go of them: replaced by its update on
/// a device with little memory, where the two do not fit at once. Asked again, they come back from
/// the copy on disk.
abstract interface class ListHolder {
  void forgetLists();
}

/// What the UI needs from any provider (Xtream, M3U and, later, Stalker).
abstract interface class ContentSource {
  Future<List<Category>> liveCategories();
  Future<List<LiveChannel>> liveChannels([String? categoryId]);
  Future<List<Category>> movieCategories();
  Future<List<Movie>> movies([String? categoryId]);
  Future<List<Category>> seriesCategories();
  Future<List<Series>> series([String? categoryId]);
  Future<SeriesDetail> seriesDetail(Series s);
  Future<List<EpgEntry>> shortEpg(LiveChannel c, {int limit = 4});

  /// Full XMLTV guide; empty when the source has none.
  Future<EpgGuide> guide();

  String liveUrl(LiveChannel c);
  String movieUrl(Movie m);
  String episodeUrl(Episode e);

  /// Catch-up URL, or null when the channel or the source does not support it.
  String? catchupUrl(LiveChannel c, DateTime start, Duration duration);

  /// HTTP headers the stream at [url] needs (an M3U entry's user agent); usually none.
  Map<String, String> headersFor(String url);

  /// Leaves adult content out of every category and list: categories named so (see
  /// [isAdultCategory]) and, where the provider marks them, adult items.
  abstract bool hideAdult;
}

final _adultName = RegExp(
  r'(?<![a-z])(xxx|adult(?:[oa]|e)?s?|porn\w*|er[oó]ti[ck][oa]?s?|hentai|sexo?|sexy|playboy|brazzers|erwachsene|x-?rated|mayores de 18(?!\d)|r-?18(?!\d))(?![a-z])|\+ ?18(?!\d)|(?<!\d)18 ?\+|🔞',
  caseSensitive: false,
);
final _adultTitleCaps = RegExp(r'(?<![A-Za-z])XXX(?![A-Za-z])');
final _adultTitle = RegExp(r'(?<![a-z])(porn\w*|hentai|brazzers|playboy)(?![a-z])', caseSensitive: false);

/// Whether the name of a channel or title itself says it is for adults. Stricter than
/// [isAdultCategory]: it applies to every profile without adult content, and "Young Adult" or "xXx"
/// are not.
bool isAdultTitle(String name) => _adultTitleCaps.hasMatch(name) || _adultTitle.hasMatch(name);

/// Whether a category's name says it is for adults ("XXX", "Adultos", "+18", ...).
bool isAdultCategory(String name) => _adultName.hasMatch(name);

/// Deletes the files next to [keep] whose names start with [prefix] and that nobody touched for
/// [age]: caches of playlists long gone. Never fails.
void dropStaleCache(File keep, String prefix, Duration age) {
  try {
    final kept = keep.uri.pathSegments.last;
    for (final f in keep.parent.listSync().whereType<File>()) {
      // By name: the same folder, and Windows writes its paths more than one way
      final name = f.uri.pathSegments.last;
      if (!name.startsWith(prefix) || name == kept) continue;
      if (DateTime.now().difference(f.lastModifiedSync()) > age) f.deleteSync();
    }
  } on FileSystemException {
    // Not worth failing over
  }
}

/// Writes [bytes] to [file] whole or not at all (through a temporary file), so a reader never sees
/// half of it. Never fails: it is only a cache.
Future<void> writeCache(File file, List<int> bytes) async {
  try {
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
  } on FileSystemException {
    // Next time, then
  }
}

/// Downloads [url] into [file] as it arrives, never whole in memory: a full catalog or playlist is
/// tens of MB, and a TV stick has a few hundred for everything. [wait] is how long the answer, and
/// then each piece of it, may take, so a big list on a slow line still gets there. Returns the
/// status, the file written only for 200; throws [SourceException], or a [FileSystemException]
/// when [file] cannot be written.
///
/// One someone waits for counts in [listDownloads] from the moment it is asked for. One in the
/// background passes [giveWay] instead: as soon as that completes it stops, its connection closed,
/// throwing [DownloadStopped]. [stop] does the same to either, once nobody waits for it any more
/// (its source was closed, see [Closable]).
///
/// The most a whole list (a panel's channels, movies or series; an M3U) may take: the biggest are a
/// few hundred MB. Past it, it is no list, and would fill the disk or the memory.
const largestList = 512 << 20;

/// The same for a guide, which runs bigger.
const largestGuide = 1 << 30;

/// The most any other answer of a panel may take (a series' episodes, a movie's record).
const largestAnswer = 32 << 20;

/// [onPiece] sees each piece of the body as it comes. [first] sees the first one, with what the
/// server says it is, and may throw a [SourceException] to stop there: a channel's stream given as
/// a list would never end. Past [maxBytes] it stops too, with [SourceError.badResponse]: no list is
/// that big, and the disk or the memory would fill.
Future<int> downloadTo(
  http.Client client,
  Uri url,
  File file, {
  required Duration wait,
  Future<void>? giveWay,
  Future<void>? stop,
  void Function(List<int> piece)? onPiece,
  void Function(List<int> piece, String? contentType)? first,
  void Function(Map<String, String> headers)? onHeaders,
  int? maxBytes,
}) async {
  final shown = giveWay == null;
  if (shown) listDownloads._begin();
  var answered = false;
  final end = switch ((giveWay, stop)) {
    (final g?, final s?) => Future.any([g, s]),
    (final g, final s) => g ?? s,
  };
  // Given up for silence: its connection closes too, not left open with nobody reading it
  final silent = Completer<void>();
  void close() {
    if (!silent.isCompleted) silent.complete();
  }

  try {
    final http.StreamedResponse res;
    try {
      final abort = end == null ? silent.future : Future.any([end, silent.future]);
      final request = http.AbortableRequest('GET', url, abortTrigger: abort)..headers.addAll(providerHeaders);
      res = await client.send(request).timeout(wait);
    } on http.RequestAbortedException {
      throw const DownloadStopped();
    } on TimeoutException {
      close();
      throw const SourceException(SourceError.timeout);
    } catch (e) {
      throw networkError(e);
    }
    if (res.statusCode != 200) {
      unawaited(res.stream.listen(null).cancel());
      return res.statusCode;
    }
    onHeaders?.call(res.headers);
    // The size the server sends: a compressed body grows past it once unpacked
    final total = switch (res.headers['content-encoding']) {
      null || 'identity' => res.contentLength,
      _ => null,
    };
    final out = await file.open(mode: FileMode.write);
    if (shown) {
      listDownloads._answered(total);
      answered = true;
    }
    var received = 0;
    try {
      final body = res.stream.timeout(wait);
      await for (final piece in end == null ? body : _until(end, body)) {
        if (received == 0) first?.call(piece, res.headers['content-type']);
        await out.writeFrom(piece);
        received += piece.length;
        if (maxBytes != null && received > maxBytes) throw const SourceException(SourceError.badResponse, 'too big');
        if (shown) listDownloads._add(piece.length);
        onPiece?.call(piece);
      }
    } on DownloadStopped {
      rethrow;
    } on SourceException {
      close(); // its connection too: leaving the loop stops the reading, not the server sending
      rethrow;
    } on http.RequestAbortedException {
      throw const DownloadStopped();
    } on TimeoutException {
      close();
      throw const SourceException(SourceError.timeout);
    } on FileSystemException {
      rethrow;
    } catch (e) {
      throw networkError(e);
    } finally {
      await out.close();
    }
    // The line dropped before the end: a playlist cut short reads as a whole one
    if (total != null && received < total) throw const SourceException(SourceError.unreachable, 'cut short');
    return 200;
  } finally {
    if (shown) listDownloads._end(answered: answered);
  }
}

/// [body] until [stop] completes: then it ends there, with [DownloadStopped], and stops listening
/// to [body], which closes its connection. Whatever the client, and even while no piece comes.
Stream<List<int>> _until(Future<void> stop, Stream<List<int>> body) {
  StreamSubscription<List<int>>? listening;
  late final StreamController<List<int>> out;
  out = StreamController(
    sync: true,
    onListen: () {
      listening = body.listen(out.add, onError: out.addError, onDone: out.close);
      stop.then((_) {
        if (out.isClosed) return;
        listening?.cancel();
        out
          ..addError(const DownloadStopped())
          ..close();
      });
    },
    onPause: () => listening?.pause(),
    onResume: () => listening?.resume(),
    onCancel: () => listening?.cancel(),
  );
  return out.stream;
}

/// A background download that gave way (see [downloadTo]).
class DownloadStopped implements Exception {
  const DownloadStopped();
}

/// How far a download of a list got: the bytes so far, and in all when the server said.
typedef DownloadProgress = ({int received, int? total});

/// The lists downloading that someone waits for (see [downloadTo]), all of them together; null
/// while there are none. The total comes once all of them have answered, and one done still counts
/// until the last one ends, so the share does not fall as lists join or leave: a whole catalog is
/// asked for at once, and a small list answers long before a big one. For the loading screens: a
/// big catalog on a slow line takes minutes.
final listDownloads = ListDownloads._();

class ListDownloads extends ValueNotifier<DownloadProgress?> {
  ListDownloads._() : super(null);

  /// The least time between two changes: a TV stick redraws for each one.
  @visibleForTesting
  static var every = const Duration(milliseconds: 300);

  var _running = 0, _unanswered = 0, _received = 0, _total = 0;
  var _sized = true; // each download so far said how big it is
  final _shown = Stopwatch(); // since the last change

  void _begin() {
    _running++;
    _unanswered++;
    _show();
  }

  void _answered(int? total) {
    _unanswered--;
    if (total == null) {
      _sized = false;
    } else {
      _total += total;
    }
    _show();
  }

  void _add(int bytes) {
    _received += bytes;
    if (_shown.elapsed >= every) _show();
  }

  void _end({required bool answered}) {
    if (!answered) _unanswered--;
    if (--_running > 0) {
      _show();
    } else {
      _received = _total = 0;
      _sized = true;
      value = null;
    }
  }

  void _show() {
    _shown
      ..reset()
      ..start();
    value = (received: _received, total: _sized && _unanswered == 0 ? _total : null);
  }
}

/// What a list being brought holds.
enum ListKind { live, movies, series, playlist }

/// How far the lists of a kind have got: the items so far, how much of them has been read (null
/// while they are still downloading), and whether they are all here.
typedef ListImportRow = ({ListKind kind, int items, double? read, bool done});

/// One list someone waits for, from asking for it until it can be used.
class ListImport {
  ListImport._(this.kind);

  final ListKind kind;
  var _items = 0;
  double? _read;
  var _done = false;

  /// This many have come so far. Never fewer than before: read again, a list starts from none.
  void counted(int items) {
    if (items <= _items) return;
    _items = items;
    listImports._changed();
  }

  /// This many have been read, [share] of the list.
  void reading(int items, double share) {
    _read = share;
    if (items > _items) _items = items;
    listImports._changed();
  }

  /// It is here, with [items] in it.
  void finish(int items) {
    _items = items;
    _read = 1;
    _done = true;
    listImports._ended();
  }

  /// It did not come: it says nothing any more.
  void fail() => listImports._drop(this);

  /// For an isolate reading the list: what is sent here as (items, share) goes to [reading]. To be
  /// closed once it is read.
  ReceivePort port() => ReceivePort()
    ..listen((message) {
      final (int items, double share) = message as (int, double);
      reading(items, share);
    });
}

/// The lists someone waits for, by kind, as the loading screens show them; those of a catalog stay
/// together, done ones too, until a new load starts. Empty until the first.
final listImports = ListImports._();

class ListImports extends ValueNotifier<List<ListImportRow>> {
  ListImports._() : super(const []);

  /// How long lists that have all come are still shown: what is made of them takes a while more.
  @visibleForTesting
  static var linger = const Duration(seconds: 30);

  final _imports = <ListImport>[];
  final _shown = Stopwatch(); // since the last change
  DateTime? _endedAt;

  /// The rows to show now: none once they have been done for a while.
  List<ListImportRow> get current {
    final ended = _endedAt;
    return ended != null && DateTime.now().difference(ended) >= linger ? const [] : value;
  }

  /// All the items so far.
  int get items => current.fold(0, (sum, row) => sum + row.items);

  @visibleForTesting
  void reset() {
    _imports.clear();
    _endedAt = null;
    value = const [];
  }

  ListImport start(ListKind kind) {
    if (_endedAt != null) _imports.clear(); // the ones before are over: this is another load
    _endedAt = null;
    final import = ListImport._(kind);
    _imports.add(import);
    _publish();
    return import;
  }

  void _changed() {
    if (_shown.isRunning && _shown.elapsed < ListDownloads.every) return; // a TV stick redraws for each one
    _publish();
  }

  void _ended() {
    if (_imports.every((i) => i._done)) _endedAt = DateTime.now();
    _publish();
  }

  void _drop(ListImport import) {
    _imports.remove(import);
    _ended();
  }

  void _publish() {
    _shown
      ..reset()
      ..start();
    value = [
      for (final kind in ListKind.values)
        if (_imports.where((i) => i.kind == kind).toList() case final list when list.isNotEmpty)
          (
            kind: kind,
            items: list.fold(0, (sum, i) => sum + i._items),
            read: list.any((i) => i._read == null)
                ? null
                : list.fold<double>(0, (sum, i) => sum + i._read!) / list.length,
            done: list.every((i) => i._done),
          ),
    ];
  }
}

/// What every request to a provider (its lists, its guide, its images) says this player is: some
/// panels turn away a client that does not look like a browser. A browser sends its own and will
/// not let a page set it (Chrome refuses the header, Firefox first asks the server's leave, which
/// image hosts do not answer), so there nothing is added.
const providerHeaders = isWeb ? <String, String>{} : {'User-Agent': 'Mozilla/5.0'};

/// Whether a stream plays now. Lists refreshed in the background wait while one does, and one
/// downloading stops when it starts, so the stream has the line to itself. It follows what the
/// player says it shows (nowPlaying, in the remote's code).
final streamPlaying = ValueNotifier(false);

/// How many scheduled recordings record now (RecordingScheduler): the line is theirs as a stream's
/// is, though nothing plays.
final recordingsRunning = ValueNotifier(0);

/// What is being refreshed in the background (see [refreshInBackground]), by file.
final _refreshing = <String, _Refresh>{};
var _refreshes = Future<void>.value();

/// The files about to be replaced by a list someone waits for (see [holdRefresh]), and by how many.
final _held = <String, int>{};

class _Refresh {
  _Refresh(this.file, this.download);

  final File file;
  final Future<bool> Function(File part, Future<void> giveWay) download;
  var dropped = false;
  Completer<void>? giveWay; // while it downloads

  void stop() {
    final g = giveWay;
    if (g != null && !g.isCompleted) g.complete();
  }
}

/// Brings a new copy of [file], an old one, for the next load, in the background: [download]
/// writes it into the file it is given (see [downloadTo], giving way when told) and says whether it
/// came whole and is what [file] holds; only then does it take [file]'s place. The copy already
/// read stays for this session: two catalogs of one list do not fit in a TV stick.
///
/// One at a time, the next once it is over: a slow line brings one list sooner alone. None while
/// a stream plays or a list someone waits for downloads; one under way then stops, its part
/// dropped, and starts again once they are over. One per file, whatever source asks, and none
/// while a list someone waits for is replacing it ([holdRefresh]). Failing it says nothing: [file]
/// stays, and the next load tries again.
void refreshInBackground(File file, Future<bool> Function(File part, Future<void> giveWay) download) {
  if (_refreshing.containsKey(file.path) || _held.containsKey(file.path)) return; // on its way already
  final refresh = _refreshing[file.path] = _Refresh(file, download);
  _refreshes = _refreshes.then((_) => _run(refresh)).whenComplete(() {
    if (_refreshing[file.path] == refresh) _refreshing.remove(file.path);
  });
}

/// A list someone waits for is about to replace [file]: its refresh, if any, is forgotten, and
/// none is asked for until [releaseRefresh], once that list is in its place (not before: reading it
/// back takes a while, and the line is free meanwhile).
void holdRefresh(File file) {
  _held.update(file.path, (n) => n + 1, ifAbsent: () => 1);
  final refresh = _refreshing.remove(file.path);
  if (refresh == null) return;
  refresh.dropped = true;
  refresh.stop();
}

/// See [holdRefresh].
void releaseRefresh(File file) {
  final left = _held[file.path]! - 1;
  if (left > 0) {
    _held[file.path] = left;
  } else {
    _held.remove(file.path);
  }
}

/// Completes once the refreshes asked for so far are over.
@visibleForTesting
Future<void> backgroundRefreshes() => _refreshes;

Future<void> _run(_Refresh r) async {
  while (!r.dropped) {
    if (_busy) {
      await _nextChange();
      continue;
    }
    final giveWay = r.giveWay = Completer<void>();
    void yieldWhenBusy() {
      if (_busy) r.stop();
    }

    streamPlaying.addListener(yieldWhenBusy);
    recordingsRunning.addListener(yieldWhenBusy);
    listDownloads.addListener(yieldWhenBusy);
    final part = partFile(r.file);
    try {
      if (await r.download(part, giveWay.future)) await part.rename(r.file.path);
      return;
    } on DownloadStopped {
      // Again once what took the line is over
    } on Object {
      return; // the copy there was stays; the next load tries again
    } finally {
      streamPlaying.removeListener(yieldWhenBusy);
      recordingsRunning.removeListener(yieldWhenBusy);
      listDownloads.removeListener(yieldWhenBusy);
      r.stop(); // a request that timed out waiting for its answer is still open: this closes it
      dropFile(part);
    }
  }
}

/// A stream plays or records, or a list someone waits for downloads: the line is theirs.
bool get _busy => streamPlaying.value || recordingsRunning.value > 0 || listDownloads._running > 0;

/// Completes on the next change of what plays or downloads.
Future<void> _nextChange() {
  final changed = Completer<void>();
  void done() {
    streamPlaying.removeListener(done);
    recordingsRunning.removeListener(done);
    listDownloads.removeListener(done);
    if (!changed.isCompleted) changed.complete();
  }

  streamPlaying.addListener(done);
  recordingsRunning.addListener(done);
  listDownloads.addListener(done);
  return changed.future;
}

var _downloads = 0;

/// A file of its own next to [file] for one download into it: two loads of one list at once (a
/// playlist opened again while its first load still runs) must not write into one file. Those left
/// by downloads cut short (the app closed meanwhile) go once an hour old; one running writes more
/// often than that.
File partFile(File file) {
  final part = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}-${_downloads++}.part');
  dropStaleCache(part, '${file.uri.pathSegments.last}.', const Duration(hours: 1));
  return part;
}

/// Deletes [file] if it is there. Never fails.
void dropFile(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // Not worth failing over
  }
}

/// A short hash of [s] that is the same on every device and every run, unlike hashCode: for file
/// names and ids. 64-bit FNV-1a, in hex.
///
/// The same value on every platform, the web included, because it names ids that sync between a
/// TV and a browser: there the arithmetic goes through BigInt (stable_hash_web.dart), since a
/// JavaScript number carries 53 bits. See stable_hash.dart.
String stableHash(String s) => fnv1a64Hex(s);

enum SourceError {
  unreachable,
  timeout,
  unauthorized,
  inactiveAccount,
  httpStatus,
  badResponse,
  notFound,
  emptyPlaylist,

  /// The server's address cannot be one ("host:80a", "ftp://x", a space in it).
  badAddress,

  /// A 404 to a login: a panel that does not know it, or an address that is not a panel's.
  wrongServer,

  /// A 429 or 5xx: the provider is overloaded, or down for a while.
  providerBusy,

  /// The device has no room left for the list, and too little memory to hold it instead.
  noSpace,

  /// The device is on no network: no Wi-Fi, no cable.
  offline,

  /// The server's name could not be looked up: no internet, or a name written wrong.
  dns,

  /// The secure connection failed: most often the device's clock is wrong.
  tls,
}

/// What an answer with [status] (not 200) is: a refused account, a provider overloaded, or else
/// the status itself.
SourceException statusError(int status) => switch (status) {
  401 || 403 => SourceException(SourceError.unauthorized, '$status'),
  429 || >= 500 => SourceException(SourceError.providerBusy, '$status'),
  _ => SourceException(SourceError.httpStatus, '$status'),
};

/// Whether [e] is the panel itself saying the account is no good (the auth in its answer, or an
/// account not active), rather than a server that would not let its API be asked (401, 403, 404).
bool accountRefused(Object e) =>
    e is SourceException &&
    ((e.error == SourceError.unauthorized && e.detail == null) || e.error == SourceError.inactiveAccount);

/// A failure the UI can translate: [error] picks the message, [detail] fills it in.
/// What a network failure says, without its address: http's message carries the URL, and with it
/// the account of an Xtream panel.
/// [e], a connection that failed, as what to check: no network, a name that cannot be looked
/// up, a secure connection that failed, or else the server itself out of reach.
SourceException networkError(Object e) => SourceException(_networkKind(e), networkDetail(e));

SourceError _networkKind(Object e) {
  if (e is TlsException) return SourceError.tls; // a handshake or a certificate
  final text = switch (e) {
    final SocketException s => '${s.message} ${s.osError?.message ?? ''}',
    final http.ClientException c => c.message,
    _ => '',
  }.toLowerCase();
  bool any(List<String> words) => words.any(text.contains);
  if (any(['handshake', 'certificate'])) return SourceError.tls;
  if (any([
    'host lookup',
    'no address associated',
    'no such host',
    'nodename nor servname',
    'name or service not known',
  ])) {
    return SourceError.dns;
  }
  if (any(['network is unreachable', 'no route to host', 'host is unreachable', 'network unreachable'])) {
    return SourceError.offline;
  }
  return SourceError.unreachable;
}

String networkDetail(Object e) => e is http.ClientException ? e.message : '${e.runtimeType}';

class SourceException implements Exception {
  const SourceException(this.error, [this.detail, this.until]);

  final SourceError error;
  final String? detail;

  /// An account that is not active: when it ends or ended, as the panel says.
  final DateTime? until;

  @override
  String toString() => detail == null ? 'SourceException(${error.name})' : 'SourceException(${error.name}: $detail)';
}
