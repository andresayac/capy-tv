import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../device.dart' show lowMemory;
import '../platform.dart';
import 'epg.dart';
import 'json_items.dart';
import 'kids.dart';
import 'models.dart';
import 'off_thread.dart';
import 'provider_http.dart';
import 'source.dart';
import 'watch_time.dart';

/// [inner], each request saying it comes from [agent].
class _AgentClient extends http.BaseClient {
  _AgentClient(this.inner, this.agent);

  final http.Client inner;
  final String agent;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['User-Agent'] = agent;
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

/// Xtream Codes API client (player_api.php); also works with XC_VM and similar panels.
class XtreamSource implements ContentSource, MovieDetails, KidsFilter, Closable, ListHolder {
  XtreamSource({
    required String server,
    required this.username,
    required this.password,
    this.liveFormat = 'ts',
    this.cacheDir,
    this.refetch = false,
    this.userAgent,
    http.Client? client,
  }) : base = normalizeServer(server),
       _given = client,
       _http = userAgent == null ? client ?? providerClient() : _AgentClient(client ?? providerClient(), userAgent);

  /// The client given to it, in tests; null in the app.
  final http.Client? _given;

  /// What the panel is told this player is, when it lets only some in: every request of its lists
  /// and guide, and the streams; null for the usual.
  final String? userAgent;

  final Uri base;
  final String username, password;

  /// Completed by [close]: what it is downloading for nobody stops.
  final _closed = Completer<void>();

  /// "ts" or "m3u8" for live channels.
  String liveFormat;

  /// The outputs the account allows, learned at [login]: none known, any.
  List<String> allowedFormats = const [];

  /// [liveFormat], or what the account allows instead (one that only allows HLS refuses .ts);
  /// and on the web always HLS, whatever the account lists: a browser cannot open live .ts at
  /// all (see [opensRawLiveTs]), while a server that lists only "ts" may still answer .m3u8, as
  /// iptv-steady does by sending the player on to the provider's.
  String get _liveFormat {
    if (!opensRawLiveTs) return 'm3u8';
    if (allowedFormats.isEmpty || allowedFormats.contains(liveFormat)) return liveFormat;
    return ['ts', 'm3u8'].firstWhere(allowedFormats.contains, orElse: () => liveFormat);
  }

  final http.Client _http;

  /// Where the full lists and the XMLTV guide are cached; defaults to the platform cache directory.
  final Directory? cacheDir;

  /// Full lists younger than this are read from the cache instead of the panel.
  static const listsFresh = Duration(hours: 6);

  /// Lists and guide fetched from the panel whatever the age of the copies on disk (the list is
  /// being updated); failing, nothing older is taken instead.
  final bool refetch;

  /// Server UTC offset learned at login; catch-up URLs use server wall-clock time.
  Duration? serverUtcOffset;

  /// How far its guide's times are moved, as the user set it for the playlist (Playlist.guideShift):
  /// a panel whose guide is on the wrong clock.
  Duration guideShift = Duration.zero;

  @override
  bool hideAdult = true; // whoever forgets to say hides too much, not too little

  @override
  bool kidsOnly = false;

  /// Accepts "host", "host:8080", "http://host:8080/" or a full player_api.php URL.
  static Uri normalizeServer(String server) {
    var s = server.trim();
    if (!s.contains('://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty || s.contains(' ') || (u.scheme != 'http' && u.scheme != 'https')) {
      throw const SourceException(SourceError.badAddress);
    }
    final path = u.path.replaceFirst(RegExp(r'/(player_api|get|xmltv)\.php$'), '').replaceFirst(RegExp(r'/+$'), '');
    return Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null, path: path);
  }

  String get _root => base.toString().replaceFirst(RegExp(r'/$'), '');

  /// Whether [url] is one of this panel's streams.
  bool serves(String url) => url.startsWith('$_root/');
  String get _u => Uri.encodeComponent(username);
  String get _p => Uri.encodeComponent(password);

  Uri _url([String? action, Map<String, String> params = const {}]) => base.replace(
    path: '${base.path}/player_api.php',
    queryParameters: {'username': username, 'password': password, 'action': ?action, ...params},
  );

  /// How long the panel may take to answer, and to send each piece of a list.
  static const _wait = Duration(seconds: 30);

  /// The panel's answer to [action], up to [most] bytes: past it, it is no answer of a panel, and
  /// would fill the memory.
  Future<Uint8List> _get([String? action, Map<String, String> params = const {}, int most = largestAnswer]) async {
    final http.StreamedResponse res;
    final silent = Completer<void>(); // given up for silence: its connection closes too
    void giveUp() {
      if (!silent.isCompleted) silent.complete();
    }

    try {
      final abort = Future.any([silent.future, _closed.future]);
      final request = http.AbortableRequest('GET', _url(action, params), abortTrigger: abort)
        ..headers.addAll(providerHeaders);
      res = await _http.send(request).timeout(_wait);
    } on TimeoutException {
      giveUp();
      throw const SourceException(SourceError.timeout);
    } catch (e) {
      throw networkError(e);
    }
    if (res.statusCode != 200) {
      unawaited(res.stream.listen(null).cancel());
      throw statusError(res.statusCode);
    }
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final piece in res.stream.timeout(_wait)) {
        bytes.add(piece);
        if (bytes.length > most) throw const SourceException(SourceError.badResponse, 'too big');
      }
    } on SourceException {
      giveUp();
      rethrow;
    } on TimeoutException {
      giveUp();
      throw const SourceException(SourceError.timeout);
    } catch (e) {
      throw networkError(e);
    }
    return bytes.takeBytes();
  }

  Future<Object?> _api([String? action, Map<String, String> params = const {}]) async =>
      _decode(await _get(action, params));

  /// A panel's answer as JSON, past any PHP notice before it; null when empty.
  static Object? _decode(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      final text = utf8.decode(bytes, allowMalformed: true);
      return jsonDecode(text.substring(afterPhpNotice(text) ?? 0));
    } on FormatException {
      throw const SourceException(SourceError.badResponse);
    }
  }

  final _lists = <String, Future<Object>>{};

  @override
  void forgetLists() => _lists.clear();

  /// A full list (every channel, movie or series, or a kind's categories), fetched once per
  /// session and shared by everything that shows it, categories included. Kept on disk: within
  /// [listsFresh] it is read from there, and an older copy does too, at once, while a new one comes
  /// in the background for the next time (a big list on a slow line takes minutes).
  Future<_Listing<T>> _listing<T>(String action, _FromJson<T> fromJson) async {
    final loading = _lists[action] ??= _loadListing(action, fromJson);
    try {
      return (await loading) as _Listing<T>;
    } catch (_) {
      // ignore: unawaited_futures, the map's entry taken out, not a call
      if (_lists[action] == loading) _lists.remove(action); // not kept: the next call tries again
      rethrow;
    }
  }

  Future<_Listing<T>> _loadListing<T>(String action, _FromJson<T> fromJson) async {
    final import = switch (action) {
      'get_live_streams' => listImports.start(ListKind.live),
      'get_vod_streams' => listImports.start(ListKind.movies),
      'get_series' => listImports.start(ListKind.series),
      _ => null, // categories: a few, and in a moment
    };
    try {
      final listing = await _bring(action, fromJson, import);
      import?.finish(listing.items.length);
      return listing;
    } on Object {
      import?.fail();
      rethrow;
    }
  }

  Future<_Listing<T>> _bring<T>(String action, _FromJson<T> fromJson, ListImport? import) async {
    final file = await _cacheFile('catalog', '$action.json');
    final saved = file != null && file.existsSync() ? file : null;
    if (saved != null && !refetch) {
      final old = DateTime.now().difference(saved.lastModifiedSync()) >= listsFresh;
      try {
        final listing = await _read(saved, fromJson, import);
        // A young copy of nothing may be what a panel down for a moment answered: asked again
        if (!old && listing.items.isNotEmpty) return listing;
        // An old copy of nothing is no copy to show: it would stay empty the whole session
        if (listing.items.isNotEmpty) {
          _refreshLater(_given, userAgent, _url(action), saved, _idOf(action));
          return listing;
        }
      } on Object {
        // Damaged: fetch it again
      }
    }
    // A copy with something in it was given above; one empty or damaged is no answer: what went
    // wrong is said instead
    return _fetch(action, fromJson, file, import, saved);
  }

  /// A new copy of the list at [url] for [file] in the background (see [refreshInBackground]).
  /// Static, and given only what it needs: waiting its turn it must not hold on to this source, and
  /// the catalog in it.
  /// Its own client (or [given], in tests): the source's is closed when its playlist is left, and
  /// the refresh may wait its turn longer than that.
  static void _refreshLater(http.Client? given, String? agent, Uri url, File file, String id) =>
      refreshInBackground(file, (part, giveWay) async {
        final base = given ?? providerClient();
        final client = agent == null ? base : _AgentClient(base, agent);
        try {
          final status = await downloadTo(client, url, part, wait: _wait, giveWay: giveWay, maxBytes: largestList);
          if (status != 200 || !await _isList(part, id)) return false;
          dropStaleCache(file, 'catalog-', const Duration(days: 30));
          return true;
        } finally {
          if (given == null) client.close();
        }
      });

  /// The key the items of [action]'s list have.
  static String _idOf(String action) => switch (action) {
    'get_series' => 'series_id',
    _ when action.endsWith('_categories') => 'category_id',
    _ => 'stream_id',
  };

  /// Whether [file] is a list, read to its end, with items that have [id]. None is kept, and it
  /// runs off the UI isolate when big. Neither an error the panel answers with ({"user_info":
  /// {"auth": 0}}, whose values look like items), nor an empty list, nor one cut short, may take the
  /// place of a good copy.
  static Future<bool> _isList(File file, String id) async {
    final path = file.path;
    bool check() {
      final raf = File(path).openSync();
      try {
        var found = false;
        for (final item in jsonItems(chunksOf(raf))) {
          found = found || item.containsKey(id);
        }
        return found;
      } on FormatException {
        return false;
      } finally {
        raf.closeSync();
      }
    }

    return file.lengthSync() > 256 * 1024 ? runOffThread(check) : check();
  }

  /// [action]'s list from the panel, kept in [file]. It goes to disk as it arrives and is read back
  /// from there item by item: whole in memory, as text and then as JSON, the catalog of a big panel
  /// takes more than a TV stick has.
  /// Neither an error the panel answers with a 200 nor an empty list takes the place of a [saved]
  /// copy with items (see [_isList]): the first is [SourceError.badResponse], the second gives that
  /// copy.
  Future<_Listing<T>> _fetch<T>(
    String action,
    _FromJson<T> fromJson,
    File? file,
    ListImport? import, [
    File? saved,
  ]) async {
    if (file == null) return _parse(await _get(action, const {}, largestList), fromJson); // no disk (tests)
    final part = partFile(file);
    holdRefresh(file); // this one brings it, and someone waits for it
    try {
      final int status;
      try {
        final counter = JsonItemCounter();
        status = await downloadTo(
          _http,
          _url(action),
          part,
          wait: _wait,
          stop: _closed.future,
          maxBytes: largestList,
          onPiece: import == null
              ? null
              : (piece) {
                  counter.add(piece);
                  import.counted(counter.count);
                },
        );
      } on FileSystemException {
        // No room on disk: in memory, then, where there is memory for it
        if (lowMemory) throw const SourceException(SourceError.noSpace);
        return await _parse(await _get(action, const {}, largestList), fromJson);
      }
      if (status != 200) throw statusError(status);
      // Here whole, but nobody waits for it any more: not read, which is most of the work
      if (_closed.isCompleted) throw const DownloadStopped();
      final listing = await _read(part, fromJson, import, key: _idOf(action));
      if (listing.items.isNotEmpty && listing.keyed == 0) throw const SourceException(SourceError.badResponse);
      if (listing.items.isEmpty && saved != null) {
        try {
          final last = await _read(saved, fromJson, null);
          if (last.items.isNotEmpty) return last;
        } on SourceException {
          // Damaged: nothing better than nothing, then
        }
      }
      try {
        await part.rename(file.path);
        dropStaleCache(file, 'catalog-', const Duration(days: 30));
      } on FileSystemException {
        // Not kept, then: it is only a cache
      }
      return listing;
    } finally {
      releaseRefresh(file);
      dropFile(part);
    }
  }

  /// The list in [file], read and turned into models item by item, off the UI isolate when big.
  /// With [key], it counts the items that have it ([_Listing.keyed]).
  static Future<_Listing<T>> _read<T>(File file, _FromJson<T> fromJson, ListImport? import, {String? key}) async {
    final path = file.path, length = file.lengthSync(), big = length > 256 * 1024;
    // Only the port goes in what is sent to the isolate: [import] reaches the screens listening
    final port = big ? import?.port() : null;
    final tell = port?.sendPort;
    _Listing<T> read() {
      final raf = File(path).openSync();
      var sofar = 0;
      Iterable<Uint8List> chunks() sync* {
        for (final chunk in chunksOf(raf)) {
          sofar += chunk.length;
          yield chunk;
        }
      }

      try {
        return _Listing.fromItems(
          jsonItems(chunks()),
          fromJson,
          key: key,
          each: tell == null ? null : (items) => tell.send((items, sofar / length)),
        );
      } finally {
        raf.closeSync();
      }
    }

    try {
      return big ? await runOffThread(read) : read();
    } on FormatException {
      throw const SourceException(SourceError.badResponse);
    } finally {
      port?.close();
    }
  }

  /// A list in memory (where there is no disk to put it on), turned into models off the UI isolate
  /// when big.
  static Future<_Listing<T>> _parse<T>(Uint8List bytes, _FromJson<T> fromJson) async {
    _Listing<T> parse() => _Listing.fromItems(jsonItems([bytes]), fromJson);
    try {
      return bytes.length > 256 * 1024 ? await runOffThread(parse) : parse();
    } on FormatException {
      throw const SourceException(SourceError.badResponse);
    }
  }

  /// The cache file [prefix]-(this account)-[name]; null where there is no cache directory (tests).
  Future<File?> _cacheFile(String prefix, String name) async {
    try {
      final dir = cacheDir ?? await getApplicationCacheDirectory();
      return File('${dir.path}/$prefix-${stableHash('$base|$username')}-$name');
    } on Object {
      return null; // no platform to ask (plain Dart tests): no cache, that is all
    }
  }

  /// The account status, as [login]; null when the panel cannot be reached for it now but its lists
  /// are on disk to open with (they say so themselves when they are read). Wrong credentials or an
  /// account that is no longer active still throw: a copy is no reason to open those.
  Future<AccountInfo?> loginOrSaved() async {
    try {
      return await login();
    } on SourceException catch (e) {
      // A 404 to a login is a login it does not know, or no panel at all: not a panel that is down
      if (e.error == SourceError.unauthorized ||
          e.error == SourceError.inactiveAccount ||
          e.error == SourceError.wrongServer) {
        rethrow;
      }
      for (final action in ['get_live_streams', 'get_vod_streams', 'get_series']) {
        if ((await _cacheFile('catalog', '$action.json'))?.existsSync() ?? false) {
          // Again in the background, for its clock and formats, once the panel is back
          unawaited(login().then((_) {}, onError: (Object _) {}));
          return null;
        }
      }
      rethrow;
    }
  }

  /// Checks the credentials and returns the account status.
  Future<AccountInfo> login() async {
    final Object? data;
    try {
      data = await _api();
    } on SourceException catch (e) {
      // Some panels (XUI) answer a login they do not know with 404, as if the page did not exist; so
      // does an address that is not a panel's: either may be wrong
      if (e.error == SourceError.httpStatus && e.detail == '404') throw const SourceException(SourceError.wrongServer);
      rethrow;
    }
    if (data is! Map<String, dynamic> || data['user_info'] is! Map) {
      throw const SourceException(SourceError.badResponse);
    }
    if (asInt((data['user_info'] as Map)['auth']) != 1) throw const SourceException(SourceError.unauthorized);
    final info = AccountInfo.fromJson(data);
    serverUtcOffset = info.serverUtcOffset;
    allowedFormats = info.formats;
    if (asInt((data['server_info'] as Map?)?['timestamp_now']) case final epoch?) WatchTime.trustServerTime(epoch);
    // Only a status the panel sent: some compatible ones send none for an account that works
    final status = asStr((data['user_info'] as Map)['status']);
    if (status != null && status.toLowerCase() != 'active') {
      throw SourceException(SourceError.inactiveAccount, status, info.expires);
    }
    return info;
  }

  @override
  Future<List<Category>> liveCategories() => _categories(_live);

  @override
  Future<List<LiveChannel>> liveChannels([String? categoryId]) => _items(_live, categoryId);

  @override
  Future<List<Category>> movieCategories() => _categories(_movies);

  @override
  Future<List<Movie>> movies([String? categoryId]) => _items(_movies, categoryId);

  @override
  Future<List<Category>> seriesCategories() => _categories(_series);

  @override
  Future<List<Series>> series([String? categoryId]) => _items(_series, categoryId);

  static const _live = _Kind<LiveChannel>('get_live_categories', 'get_live_streams', LiveChannel.fromJson);
  static const _movies = _Kind<Movie>('get_vod_categories', 'get_vod_streams', Movie.fromJson);
  static const _series = _Kind<Series>('get_series_categories', 'get_series', Series.fromJson);

  Future<List<Category>> _categories<T>(_Kind<T> kind) async {
    final all = (await _listing(kind.categories, _category)).items;
    final adult = hideAdult ? await _adultCategories(kind) : const <String>{};
    final shown = [
      for (final c in all)
        if (!adult.contains(c.id)) c,
    ];
    if (!kidsOnly) return shown;
    // Only those with something left for a child: most hold nothing once filtered
    final listing = await _listing(kind.streams, kind.fromJson);
    final kept = Set<T>.identity()..addAll(await _items(kind, null));
    return [
      for (final c in shown)
        if (listing.only(c.id).any(kept.contains)) c,
    ];
  }

  Future<List<T>> _items<T>(_Kind<T> kind, String? category) async {
    final listing = await _listing(kind.streams, kind.fromJson);
    final List<T> items;
    if (hideAdult) {
      final adult = await _adultCategories(kind);
      items = adult.contains(category) ? const [] : listing.only(category, hiding: adult);
    } else {
      items = listing.only(category);
    }
    if (!kidsOnly) return items;
    final inKids = Set<T>.identity();
    for (final c in (await _listing(kind.categories, _category)).items) {
      if (isKidsCategory(c.name)) inKids.addAll(listing.only(c.id));
    }
    return [
      for (final x in items)
        if (kidsMaySee(x, inKidsCategory: inKids.contains(x))) x,
    ];
  }

  /// A kind's adult categories: named so, or holding mostly items the panel marks as adult.
  Future<Set<String>> _adultCategories<T>(_Kind<T> kind) async {
    final adult = <String>{};
    // Without the names nothing can be hidden for sure: better a list that failed than one that shows them
    for (final c in (await _listing(kind.categories, _category)).items) {
      if (isAdultCategory(c.name)) adult.add(c.id);
    }
    try {
      adult.addAll((await _listing(kind.streams, kind.fromJson)).adultCategories);
    } on SourceException {
      // The names still count
    }
    return adult;
  }

  @override
  Future<SeriesDetail> seriesDetail(Series s) async {
    final bytes = await _get('get_series_info', {'series_id': s.id});
    // A soap of a thousand episodes is most of a MB: read where the page does not freeze for it
    return bytes.length > _bigDetail ? runOffThread(() => _seriesDetailOf((s, bytes))) : _seriesDetailOf((s, bytes));
  }

  /// Above this a series' record is read off the screen's thread, as the lists are.
  static const _bigDetail = 256 * 1024;

  static SeriesDetail _seriesDetailOf((Series, Uint8List) asked) {
    final data = _decode(asked.$2);
    if (data is! Map<String, dynamic>) throw const SourceException(SourceError.notFound);
    return SeriesDetail.fromJson(asked.$1, data);
  }

  /// Full movie record (get_vod_info); fills in whatever the listing left out.
  @override
  Future<Movie> movieDetail(Movie m) async {
    final data = await _api('get_vod_info', {'vod_id': m.id});
    final info = data is Map<String, dynamic> && data['info'] is Map<String, dynamic>
        ? data['info'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return m.withDetail(Movie.fromJson({...info, 'stream_id': m.id}));
  }

  @override
  Future<List<EpgEntry>> shortEpg(LiveChannel c, {int limit = 4}) async {
    final data = await _api('get_short_epg', {'stream_id': c.id, 'limit': '$limit'});
    final list = data is Map && data['epg_listings'] is List ? data['epg_listings'] as List : const [];
    // Its times with no timestamp are on the panel's clock
    return [
      for (final j in list.whereType<Map<String, dynamic>>()) ?EpgEntry.fromXtream(j, serverOffset: serverUtcOffset),
    ];
  }

  /// Full guide in XMLTV format (for the EPG grid).
  Uri get xmltvUri =>
      base.replace(path: '${base.path}/xmltv.php', queryParameters: {'username': username, 'password': password});

  @override
  Future<EpgGuide> guide() async {
    final dir = cacheDir ?? await getApplicationCacheDirectory();
    return loadXmltv(
      xmltvUri,
      cache: File('${dir.path}/epg-${stableHash('$base|$username')}.xml'),
      client: _http,
      maxAge: refetch ? Duration.zero : const Duration(hours: 6),
      stop: _closed.future,
      channels: _guideChannels(), // waited for only to read it: the guide downloads meanwhile
      shift: guideShift,
    );
  }

  /// What the guide is read for: its channels, all of them (also those a profile hides: the guide is
  /// the account's), by their guide id and name; null when they cannot be had, and the guide is kept
  /// whole.
  Future<GuideChannels?> _guideChannels() async {
    try {
      final all = (await _listing(_live.streams, _live.fromJson)).items;
      final names = <String, List<String>>{}; // two channels may share a name
      for (final c in all) {
        if (c.epgId case final id?) (names[c.name] ??= []).add(id);
      }
      return GuideChannels(
        ids: [for (final c in all) ?c.epgId],
        names: names,
        archive: [
          for (final c in all)
            if (c.hasArchive) ?c.epgId,
        ],
      );
    } on Object {
      return null;
    }
  }

  @override
  String liveUrl(LiveChannel c) => '$_root/live/$_u/$_p/${c.id}.$_liveFormat';

  @override
  String movieUrl(Movie m) => '$_root/movie/$_u/$_p/${m.id}.${m.extension}';

  @override
  String episodeUrl(Episode e) => '$_root/series/$_u/$_p/${e.id}.${e.extension}';

  /// /timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts, in server time.
  @override
  Map<String, String> headersFor(String url) => userAgent == null ? const {} : {'User-Agent': userAgent!};

  @override
  String? catchupUrl(LiveChannel c, DateTime start, Duration duration) {
    if (!c.hasArchive) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    // Wall-clock time on the server; without a known offset assume the server shares ours
    final t = start.toUtc().add(serverUtcOffset ?? start.toLocal().timeZoneOffset);
    final s = '${t.year}-${two(t.month)}-${two(t.day)}:${two(t.hour)}-${two(t.minute)}';
    // From the minute it starts in, to the end of its last one: a minute cut off is the ending
    final minutes = max(1, ((t.second + duration.inSeconds) / 60).ceil());
    return '$_root/timeshift/$_u/$_p/$minutes/$s/${c.id}.ts';
  }

  /// Its lists and guide still on their way stop (see [Closable]), and so does its connection.
  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
    _http.close();
  }
}

/// Makes a model of an item of a list, sharing what the list's items repeat through [pool].
typedef _FromJson<T> = T Function(Map<String, dynamic> j, ValuePool pool);

Category _category(Map<String, dynamic> j, ValuePool _) => Category.fromJson(j);

/// The calls for one kind of content.
class _Kind<T> {
  const _Kind(this.categories, this.streams, this.fromJson);

  final String categories, streams;
  final _FromJson<T> fromJson;
}

/// A full list as the panel sends it, and where each category's items are in it: an item may be in
/// several (category_ids, besides category_id). Also which items the panel marks as adult.
class _Listing<T> {
  _Listing(this.items, this._byCategory, this._adult, this.adultCategories, {this.keyed = 0});

  /// From the panel's items as they are read (see [jsonItems]), each made into a model at once.
  /// [each] hears how many there are every so many of them.
  factory _Listing.fromItems(
    Iterable<Map<String, dynamic>> raw,
    _FromJson<T> fromJson, {
    String? key,
    void Function(int items)? each,
  }) {
    var keyed = 0;
    final items = <T>[];
    final byCategory = <String, List<int>>{};
    final adult = <int>{}, adultIn = <String, int>{};
    final pool = ValuePool(); // dropped once the list is read
    for (final (i, j) in raw.indexed) {
      items.add(fromJson(j, pool));
      if (key != null && j.containsKey(key)) keyed++;
      if (i % 1024 == 1023) each?.call(i + 1);
      // Some panels send category_id itself as a list
      final more = [
        if (j['category_ids'] case final List ids) ...ids,
        if (j['category_id'] case final List ids) ...ids,
      ];
      final marked = asInt(j['is_adult']) == 1 || isAdultTitle(asStr(j['title']) ?? asStr(j['name']) ?? '');
      if (marked) adult.add(i);
      for (final c in {asStr(j['category_id']), for (final x in more) asStr(x)}.nonNulls) {
        (byCategory[c] ??= []).add(i);
        if (marked) adultIn[c] = (adultIn[c] ?? 0) + 1;
      }
    }
    byCategory.updateAll((_, indices) => Int32List.fromList(indices)); // 4 bytes each, no room to grow
    return _Listing(items, byCategory, adult, {
      for (final MapEntry(key: c, value: n) in adultIn.entries)
        if (n * 2 > byCategory[c]!.length) c,
    }, keyed: keyed);
  }

  final List<T> items;

  /// How many items had the key asked for when read: none, in a list of some, is no list.
  final int keyed;
  final Map<String, List<int>> _byCategory;
  final Set<int> _adult;

  /// Categories where most items are marked as adult.
  final Set<String> adultCategories;

  /// The items of [category] (all with null). With [hiding], neither items marked as adult nor
  /// those in any of those categories.
  List<T> only(String? category, {Set<String>? hiding}) {
    // An item in any of those categories is in that category's own list
    final hidden = hiding == null ? null : {..._adult, for (final c in hiding) ...?_byCategory[c]};
    final indices = category == null ? [for (var i = 0; i < items.length; i++) i] : _byCategory[category] ?? const [];
    return [
      for (final i in indices)
        if (hidden == null || !hidden.contains(i)) items[i],
    ];
  }
}
