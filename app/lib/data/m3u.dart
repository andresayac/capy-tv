import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../device.dart' show lowMemory;
import '../platform.dart' show isWeb;
import 'epg.dart';
import 'kids.dart';
import 'models.dart';
import 'off_thread.dart';
import 'provider_http.dart';
import 'source.dart';
import 'watch_time.dart';
import 'xtream_paths.dart';

class M3uEntry {
  const M3uEntry({required this.name, required this.url, this.attrs = const {}, this.headers = const {}});

  final String name;
  final String url;
  final Map<String, String> attrs; // tvg-id, tvg-name, tvg-logo, group-title, catchup…

  /// What its stream asks to be sent with: #EXTVLCOPT:http-user-agent=, http-referrer=…, #EXTHTTP,
  /// or "|User-Agent=…&Referer=…" after the address.
  final Map<String, String> headers;

  String? get userAgent => headers['User-Agent'];

  String get group => switch (attrs['group-title']?.trim()) {
    null || '' => ungrouped, // group-title="" too: a category with no name
    final g => g,
  };
  String? get logo => attrs['tvg-logo'];

  /// On demand, by its address: panels put the type in the path, and elsewhere a video file is
  /// one. A list has no episode lists, so a series' entries go with the movies rather than nowhere.
  bool get isMovie {
    final path = _pathOf(url).toLowerCase();
    return _panelVod.hasMatch(path) || _videoFile.hasMatch(path);
  }
}

final _videoFile = RegExp(r'\.(mp4|mkv|avi|mov)$');

/// A panel's movie or episode: /movie/user/password/id. Not any address with /movie/ in it: a
/// channel's /movie/hbo/index.m3u8 is live.
final _panelVod = RegExp(r'/(movie|series)/[^/]+/[^/]+/\d+(\.\w+)?$');

/// The path of [url], without parsing it whole: lists have tens of thousands of entries.
String _pathOf(String url) {
  final scheme = url.indexOf('://');
  final start = scheme < 0 ? 0 : url.indexOf('/', scheme + 3);
  if (start < 0) return '';
  var end = url.length;
  for (final c in const ['?', '#', '|']) {
    final i = url.indexOf(c, start);
    if (i >= 0 && i < end) end = i;
  }
  return url.substring(start, end);
}

/// name="value", name='value' or name=value.
final _attr = RegExp(r'''([\w-]+)\s*=\s*("[^"]*"|'[^']*'|[^\s,"']+)''');

/// #EXTVLCOPT:http-user-agent= and the like, and the header each one is.
final _vlcHeader = RegExp(r'^#EXTVLCOPT:http-(user-agent|referrer|referer|origin|cookie)=(.*)$', caseSensitive: false);
const _headerNames = {
  'user-agent': 'User-Agent',
  'referrer': 'Referer',
  'referer': 'Referer',
  'origin': 'Origin',
  'cookie': 'Cookie',
};

String _unquoted(String v) {
  v = v.trim();
  return v.length >= 2 && (v[0] == '"' || v[0] == "'") && v[v.length - 1] == v[0] ? v.substring(1, v.length - 1) : v;
}

/// Whether [url] is a stream's: one of the ways streams come, or one with no scheme (relative to the
/// list, as before). A list's line with file://, edl:// or the like would have the player open what
/// is on the device, or what mpv makes of it, not a channel.
bool isStreamAddress(String url) {
  final scheme = _scheme.firstMatch(url)?[1]?.toLowerCase();
  return scheme == null || _streamSchemes.contains(scheme);
}

final _scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):');

const _streamSchemes = {'http', 'https', 'rtmp', 'rtmps', 'rtsp', 'udp', 'rtp', 'mms'};

/// A line that can only be an entry, with no #EXTINF before it: scheme://something.
final _streamAddress = RegExp(r'^[a-z][a-z0-9+.-]*://\S+$', caseSensitive: false);

/// An id for the entry at [url] that stays when the provider reorders the list: the stream id of
/// panel URLs (which also stays when the password changes), otherwise the URL itself, hashed
/// without what changes on every download (a token, an expiry, a signature). A list's own ids are
/// [M3uSource]'s, which also tells apart two addresses that would share one.
String m3uId(String url) => parseXtreamPath(Uri.tryParse(url)?.path ?? '')?.id ?? m3uHash(url);

/// [url] hashed without the parameters that change on every download.
String m3uHash(String url) => stableHash(_steady(url));

/// What expires or is signed anew each time a list is downloaded: "?token=…&expires=…".
const _volatile = {'token', 'expires', 'expire', 'exp', 'st', 'e', 'sig', 'signature', 'hash', 'md5', 'hdnts'};

String _steady(String url) {
  final q = url.indexOf('?');
  if (q < 0) return url;
  final hash = url.indexOf('#', q);
  final query = url.substring(q + 1, hash < 0 ? url.length : hash);
  final kept = [
    for (final p in query.split('&'))
      if (!_volatile.contains(p.split('=').first.toLowerCase())) p,
  ];
  if (kept.length == query.split('&').length) return url;
  return url.substring(0, q) + (kept.isEmpty ? '' : '?${kept.join('&')}') + (hash < 0 ? '' : url.substring(hash));
}

/// Parses an extended M3U/M3U8 playlist. Tolerates blank lines, a BOM and \r\n line endings.
List<M3uEntry> parseM3u(String text, {String? list}) {
  final reader = M3uReader(list: list);
  const LineSplitter().convert(text).forEach(reader.add);
  return reader.entries;
}

/// An M3U playlist read a line at a time, so a big one need not be in memory whole, as text and as
/// lines, besides its entries.
class M3uReader {
  M3uReader({String? list}) : _base = list == null ? null : Uri.tryParse(list);

  /// Where the list was downloaded from: an entry's address with no scheme ("live/1.ts") is
  /// relative to it. Without it such an entry is none: it would reach the player as a path on the
  /// device.
  final Uri? _base;

  final entries = <M3uEntry>[];

  /// The first line with something in it, where the guides' addresses go.
  String? header;

  String? _name, _group;
  String? _headerShift; // the header's tvg-shift: every channel's that has none of its own
  var _headers = <String, String>{};
  var _attrs = <String, String>{};
  var _described = false; // an #EXTINF came for the next entry
  var _media = false; // an HLS manifest, whose lines are its segments or variants, not channels
  var _locked = false; // the next entry's stream is behind DRM (#KODIPROP:…license_type=)

  /// The entries left out because their streams are behind DRM (Widevine and the like), which no
  /// player here can open: listed, they would only fail.
  var locked = 0;

  void add(String line) {
    line = line.replaceFirst('\uFEFF', '').trim();
    if (line.isEmpty || _media) return;
    if (header == null) {
      header = line;
      if (line.toUpperCase().startsWith('#EXTM3U')) {
        for (final m in _attr.allMatches(line)) {
          if (m[1]!.toLowerCase() == 'tvg-shift') _headerShift = _unquoted(m[2]!);
        }
      }
    }
    final upper = line.length > 12 ? line.substring(0, 12).toUpperCase() : line.toUpperCase();
    if (line.startsWith('#EXT-X-TARGETDURATION') || line.startsWith('#EXT-X-STREAM-INF')) {
      _media = true;
      entries.clear();
    } else if (upper.startsWith('#EXTINF')) {
      _described = true;
      // #EXTINF:-1 tvg-id="x" group-title="y",Channel name, which may contain commas
      final comma = _firstCommaOutsideQuotes(line);
      final title = comma < 0 ? '' : line.substring(comma + 1).trim();
      _name = title.isEmpty ? null : title;
      final head = comma < 0 ? line : line.substring(0, comma);
      // Empty values are none: group-title="" is no group, tvg-logo="" no logo
      _attrs = {
        for (final m in _attr.allMatches(head))
          if (_unquoted(m[2]!) case final v when v.isNotEmpty) m[1]!.toLowerCase(): v,
      };
      if (_attrs['user-agent'] case final ua?) _headers.putIfAbsent('User-Agent', () => ua);
    } else if (upper.startsWith('#KODIPROP:')) {
      // Kodi's inputstream.adaptive with a licence: a stream that needs a DRM key
      final prop = line.toLowerCase();
      if (prop.contains('license_type=') || prop.contains('license_key=')) _locked = true;
    } else if (upper.startsWith('#EXTGRP:')) {
      // Before #EXTINF or after it: kept apart until the address
      final g = line.substring(8).trim();
      if (g.isNotEmpty) _group = g;
    } else if (_vlcHeader.firstMatch(line) case final m?) {
      final v = _unquoted(m[2]!);
      if (v.isNotEmpty) _headers[_headerNames[m[1]!.toLowerCase()]!] = v;
    } else if (upper.startsWith('#EXTHTTP:')) {
      try {
        if (jsonDecode(line.substring(9)) case final Map<String, dynamic> j) {
          for (final MapEntry(:key, :value) in j.entries) {
            if (value is String) _headers[_headerNames[key.toLowerCase()] ?? key] = value;
          }
        }
      } on FormatException {
        // Not JSON: nothing to send, then
      }
    } else if (!line.startsWith('#') && (_described || _streamAddress.hasMatch(line))) {
      // Only an entry described, or an address: a web page or "Account expired" sent with a 200
      // would otherwise be a list of channels called <html> and the like.
      // "address|User-Agent=x&Referer=y": what goes with it, after the bar
      var url = line;
      final bar = line.indexOf('|');
      if (bar > 0) {
        url = line.substring(0, bar);
        for (final pair in line.substring(bar + 1).split('&')) {
          final eq = pair.indexOf('=');
          if (eq <= 0) continue;
          final key = pair.substring(0, eq).trim();
          _headers[_headerNames[key.toLowerCase()] ?? key] = Uri.decodeComponent(pair.substring(eq + 1).trim());
        }
      }
      if (_group != null) _attrs.putIfAbsent('group-title', () => _group!);
      if (_headerShift case final shift? when shift.isNotEmpty) _attrs.putIfAbsent('tvg-shift', () => shift);
      if (_locked) {
        locked++;
      } else if (_address(url) case final url?) {
        entries.add(
          M3uEntry(
            name: _name ?? _attrs['tvg-name'] ?? url,
            url: url,
            attrs: _attrs,
            headers: _headers.isEmpty ? const {} : _headers,
          ),
        );
      }
      _name = _group = null;
      _headers = {};
      _attrs = {};
      _described = _locked = false;
    }
  }

  /// [url] as the player gets it: a stream's address, or one relative to the list made whole.
  /// Null for anything else (file://, a path on the device).
  String? _address(String url) {
    if (_scheme.hasMatch(url)) return isStreamAddress(url) ? url : null;
    try {
      final whole = _base?.resolve(url);
      return whole != null && _streamSchemes.contains(whole.scheme) ? whole.toString() : null;
    } on FormatException {
      return null;
    }
  }

  /// Whether it was one stream's HLS manifest, not a list of channels.
  bool get isStream => _media;

  /// The guides the playlist declares (see [m3uGuideUrls]).
  List<String> get guideUrls => header == null ? const [] : m3uGuideUrls(header!);
}

/// The comma before the name, past quoted values: the quote that opened one closes it, so the
/// apostrophe of tvg-name="L'Equipe" is no quote.
int _firstCommaOutsideQuotes(String s) {
  String? quote;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == quote) quote = null;
    } else if ((c == '"' || c == "'") && i > 0 && s[i - 1] == '=') {
      quote = c;
    } else if (c == '"') {
      quote = c;
    } else if (c == ',') {
      return i;
    }
  }
  return -1;
}

/// Counts the entries of a playlist as its bytes go by: lines that are neither blank nor a #
/// comment. To say how many have come while a big one still downloads.
class M3uEntryCounter {
  var count = 0;
  var _atStart = true;

  void add(List<int> piece) {
    const newline = 0x0a, carriageReturn = 0x0d, space = 0x20, tab = 0x09, hash = 0x23, bom = {0xef, 0xbb, 0xbf};
    for (final b in piece) {
      if (b == newline || b == carriageReturn) {
        _atStart = true;
      } else if (_atStart && b != space && b != tab && !bom.contains(b)) {
        _atStart = false;
        if (b != hash) count++;
      }
    }
  }
}

/// The guide URLs an M3U playlist declares in its header (x-tvg-url, url-tvg or tvg-url), up to
/// three: some list several, by commas or spaces, each with channels the others lack.
List<String> m3uGuideUrls(String text) {
  final header =
      const LineSplitter()
          .convert(text.replaceFirst('\uFEFF', ''))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .firstOrNull ??
      '';
  if (!header.toUpperCase().startsWith('#EXTM3U')) return const [];
  final m = _guideAttr.firstMatch(header);
  return [
    for (final u in (m?[1] ?? '').split(RegExp(r'[,\s]+')))
      if (u.isNotEmpty) u,
  ].take(3).toList();
}

final _guideAttr = RegExp(r'(?:x-tvg-url|url-tvg|tvg-url)\s*=\s*"([^"]+)"', caseSensitive: false);

/// The first guide an M3U playlist declares, if any (see [m3uGuideUrls]).
String? m3uGuideUrl(String text) => m3uGuideUrls(text).firstOrNull;

/// Source backed by an M3U playlist: live channels and movies grouped by group-title.
class M3uSource implements ContentSource, KidsFilter, Closable {
  M3uSource(this.entries, {this.guideUrls = const [], this.cacheDir});

  final List<M3uEntry> entries;
  final List<String> guideUrls;
  final Directory? cacheDir;

  /// How far its guide's times are moved, as the user set it for the playlist (Playlist.guideShift),
  /// besides each channel's tvg-shift.
  Duration guideShift = Duration.zero;

  /// Completed by [close]: the guide it is downloading for nobody stops (its list is in already).
  final _closed = Completer<void>();

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
  }

  /// The guide downloaded whatever the age of the copy on disk (the list is being updated).
  var refetchGuide = false;

  /// Playlists younger than this are read from the cache instead of downloaded again.
  static const fresh = Duration(hours: 6);

  /// Downloads and parses the playlist at [url]. With [cached], a copy younger than [fresh] is
  /// read from the cache instead; an older one too, at once, while a new one comes in the
  /// background for the next time (a big playlist on a slow line takes minutes), and it still does
  /// when the download fails. With [refetch] (the list is being updated) neither, and its guide is
  /// downloaded again too.
  static Future<M3uSource> load(String url, {http.Client? client, bool cached = true, bool refetch = false}) async {
    final import = listImports.start(ListKind.playlist);
    try {
      final source = await _bring(url, client, cached, refetch, import);
      import.finish(source.entries.length);
      return source;
    } on Object {
      import.fail();
      rethrow;
    }
  }

  static Future<M3uSource> _bring(String url, http.Client? client, bool cached, bool refetch, ListImport import) async {
    File? file;
    try {
      file = File('${(await getApplicationCacheDirectory()).path}/m3u-${stableHash(url)}.m3u');
    } on Object {
      // No platform to ask (plain Dart tests): no disk, that is all
    }
    final saved = cached && file != null && file.existsSync() ? file : null;
    // A copy that cannot be read (damaged, or gone meanwhile) is none: the list comes again
    Future<M3uSource?> readSaved(File saved) async {
      try {
        return await _read(saved, import, url);
      } on Object catch (e) {
        debugPrint('m3u: the saved copy could not be read: ${e.runtimeType}');
        return null;
      }
    }

    if (saved != null && !refetch) {
      final old = DateTime.now().difference(saved.lastModifiedSync()) >= fresh;
      final source = await readSaved(saved);
      if (source != null) {
        if (old) _refreshLater(url, client, saved);
        return source;
      }
    }
    final M3uSource? source;
    try {
      source = await _fetch(url, client, file, import, keep: cached);
    } on SourceException {
      final source = saved == null || refetch ? null : await readSaved(saved);
      if (source == null) rethrow;
      return source; // unreachable now: the last copy will do
    }
    if (source == null) throw const SourceException(SourceError.emptyPlaylist);
    return source..refetchGuide = refetch;
  }

  /// The playlist at [url]. It goes to disk as it arrives (kept in [file] with [keep]) and is read
  /// back from there a line at a time: whole in memory, as text and then as lines, a big playlist
  /// takes more than a TV stick has. Null when there is nothing in it.
  static Future<M3uSource?> _fetch(
    String url,
    http.Client? client,
    File? file,
    ListImport import, {
    required bool keep,
  }) async {
    final c = client ?? providerClient();
    try {
      if (file == null) return await _parse(await _download(url, c), url); // no disk (tests)
      final part = partFile(file);
      if (keep) holdRefresh(file); // this one brings it, and someone waits for it
      try {
        final int status;
        try {
          final counter = M3uEntryCounter();
          status = await downloadTo(
            c,
            _uri(url),
            part,
            wait: _wait,
            first: _noStream,
            maxBytes: largestList,
            onHeaders: _trustDate,
            onPiece: (piece) {
              counter.add(piece);
              import.counted(counter.count);
            },
          );
        } on FileSystemException {
          // No room on disk: in memory, then, where there is memory for it
          if (lowMemory) throw const SourceException(SourceError.noSpace);
          return await _parse(await _download(url, c), url);
        }
        if (status != 200) throw statusError(status);
        final source = await _read(part, import, url);
        if (source != null && keep) {
          try {
            await part.rename(file.path);
            dropStaleCache(file, 'm3u-', const Duration(days: 30));
          } on FileSystemException {
            // Not kept, then: it is only a cache
          }
        }
        return source;
      } finally {
        if (keep) releaseRefresh(file);
        dropFile(part);
      }
    } on SourceException catch (e) {
      if (e.detail != _streamGiven) rethrow;
      return _sourceOf(const [], const [], true, url); // a channel's address given as the list
    } finally {
      if (client == null) c.close();
    }
  }

  /// A new copy of the playlist at [url] for [file] in the background (see [refreshInBackground]).
  static void _refreshLater(String url, http.Client? client, File file) =>
      refreshInBackground(file, (part, giveWay) async {
        final c = client ?? providerClient();
        try {
          final int status;
          try {
            status = await downloadTo(
              c,
              _uri(url),
              part,
              wait: _wait,
              giveWay: giveWay,
              first: _noStream,
              maxBytes: largestList,
            );
          } on SourceException {
            return false; // the copy there is stays
          }
          // A playlist has no end to look for: sent with no size and cut short, or an "account
          // expired" of one entry, it reads as a whole one. Much less than there was waits for an update
          if (status != 200 || part.lengthSync() < file.lengthSync() ~/ 2 || !await _isPlaylist(part)) return false;
          dropStaleCache(file, 'm3u-', const Duration(days: 30));
          return true;
        } finally {
          if (client == null) c.close();
        }
      });

  /// Whether [file] holds a playlist, as [M3uReader] would read it: an entry with its #EXTINF line
  /// or a bare stream address, at least, none of them kept. A server's error page or an empty answer
  /// is none, and may not take the place of a good copy.
  static Future<bool> _isPlaylist(File file) {
    final path = file.path;
    return runOffThread(() async {
      var described = false;
      final lines = _bytes(path).transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());
      await for (final raw in lines) {
        final line = raw.trim();
        if (line.startsWith('#EXTINF')) {
          described = true;
        } else if (line.isNotEmpty && !line.startsWith('#') && (described || _streamAddress.hasMatch(line))) {
          return true;
        }
      }
      return false;
    });
  }

  /// How long the server may take to answer, and to send each piece of the playlist.
  static const _wait = Duration(seconds: 60);

  static const _streamGiven = 'a stream';

  /// Stops a download that is a channel's stream, not a list: the server says it is video or sound,
  /// or it starts as an MPEG-TS does. It would never end, filling the disk.
  static void _noStream(List<int> piece, String? contentType) {
    final type = contentType?.toLowerCase() ?? '';
    // Lists themselves are often sent as audio/x-mpegurl or audio/mpegurl
    final media = (type.startsWith('video/') || type.startsWith('audio/')) && !type.contains('mpegurl');
    final ts = piece.length > 188 && piece[0] == 0x47 && piece[188] == 0x47;
    if (media || ts) {
      throw const SourceException(SourceError.badResponse, _streamGiven);
    }
  }

  static Uri _uri(String url) {
    try {
      return Uri.parse(url);
    } on FormatException catch (e) {
      throw SourceException(SourceError.unreachable, networkDetail(e));
    }
  }

  /// The provider's clock, from its answer's Date: a profile's time per day counts by it, as by an
  /// Xtream panel's (WatchTime.trustServerTime), not by a device clock moved ahead.
  static void _trustDate(Map<String, String> headers) {
    final date = headers['date'];
    if (date == null) return;
    try {
      WatchTime.trustServerTime(HttpDate.parse(date).millisecondsSinceEpoch ~/ 1000);
    } on Object {
      // No date to go by: the device's clock, as before
    }
  }

  /// The playlist at [url] in memory, as far as [largestList]; [_noStream] stops a channel's stream.
  static Future<List<int>> _download(String url, http.Client c) async {
    try {
      final res = await c.send(http.Request('GET', _uri(url))..headers.addAll(providerHeaders)).timeout(_wait);
      if (res.statusCode != 200) {
        unawaited(res.stream.listen(null).cancel());
        throw statusError(res.statusCode);
      }
      _trustDate(res.headers);
      final bytes = BytesBuilder(copy: false);
      await for (final piece in res.stream.timeout(_wait)) {
        if (bytes.isEmpty) _noStream(piece, res.headers['content-type']);
        bytes.add(piece);
        if (bytes.length > largestList) throw const SourceException(SourceError.badResponse, 'too big');
      }
      return bytes.takeBytes();
    } on TimeoutException {
      throw const SourceException(SourceError.timeout);
    } on SourceException {
      rethrow;
    } catch (e) {
      throw networkError(e);
    }
  }

  /// The playlist in [file], read a line at a time off the UI isolate. Null when there is nothing
  /// in it.
  static Future<M3uSource?> _read(File file, ListImport import, String url) async {
    final path = file.path, length = file.lengthSync();
    final port = import.port(); // only the port goes to the isolate: [import] reaches the screens
    final tell = port.sendPort;
    try {
      final (entries, guide, stream) = await runOffThread(() async {
        final reader = M3uReader(list: url);
        final decoder = await _decoderFor(path);
        var sofar = 0, told = 0;
        // Counted as they are on disk, packed or not, as [length] is
        var bytes = File(path).openRead().map((chunk) {
          sofar += chunk.length;
          return chunk;
        });
        if (_gzipped(path)) bytes = bytes.transform(gzip.decoder);
        final lines = bytes.transform(decoder).transform(const LineSplitter());
        await for (final line in lines) {
          reader.add(line);
          if (reader.entries.length >= told + 1024 && length > 0) {
            told = reader.entries.length;
            tell.send((told, sofar / length));
          }
        }
        return (reader.entries, reader.guideUrls, reader.isStream);
      });
      return _sourceOf(entries, guide, stream, url);
    } finally {
      port.close();
    }
  }

  /// A playlist in memory (where there is no disk to put it on), parsed off the UI isolate. Null
  /// when there is nothing in it.
  static Future<M3uSource?> _parse(List<int> bytes, String url) async {
    // A plain map crosses to an isolate and back; a record with a List inside it may not
    final result = await runOffThread<Map<String, Object?>>(() {
      // A browser has no gzip of dart:io: there a .gz needs the server to say it is one
      final plain = _isGzip(bytes) && !isWeb ? gzip.decode(bytes) : bytes;
      final text = _isUtf8(plain.take(64 << 10).toList())
          ? utf8.decode(plain, allowMalformed: true)
          : latin1.decode(plain);
      final reader = M3uReader(list: url);
      const LineSplitter().convert(text).forEach(reader.add);
      return {'entries': reader.entries, 'guide': m3uGuideUrls(text), 'stream': reader.isStream};
    });
    final entries = (result['entries'] as List).cast<M3uEntry>();
    final guide = (result['guide'] as List).cast<String>();
    return _sourceOf(entries, guide, result['stream'] == true, url);
  }

  /// The list read, or null when there is nothing in it. One channel's HLS address given as the
  /// list is that channel, named after its server: its lines are its qualities or pieces.
  static M3uSource? _sourceOf(List<M3uEntry> entries, List<String> guide, bool stream, String url) {
    if (entries.isNotEmpty) return M3uSource(entries, guideUrls: guide);
    if (!stream) return null;
    final host = Uri.tryParse(url)?.host ?? '';
    return M3uSource([M3uEntry(name: host.isEmpty ? url : host, url: url)]);
  }

  /// UTF-8, or Latin-1 for a playlist whose start is no UTF-8 ("Espa\xf1a" would read "Espaï¿½a").
  static Future<Converter<List<int>, String>> _decoderFor(String path) async {
    final head = <int>[];
    await for (final chunk in _bytes(path)) {
      head.addAll(chunk);
      if (head.length >= 64 << 10) break;
    }
    return _isUtf8(head.length > 64 << 10 ? head.sublist(0, 64 << 10) : head)
        ? const Utf8Decoder(allowMalformed: true)
        : const Latin1Decoder();
  }

  /// The playlist in [path] as text bytes: a .gz sent with no Content-Encoding (so the HTTP client
  /// left it packed) is unpacked here, as the guide is (epg.dart, _readGuide).
  static Stream<List<int>> _bytes(String path) {
    final raw = File(path).openRead();
    return _gzipped(path) ? raw.transform(gzip.decoder) : raw;
  }

  static bool _gzipped(String path) {
    final raf = File(path).openSync();
    try {
      return _isGzip(raf.readSync(2));
    } finally {
      raf.closeSync();
    }
  }

  static bool _isGzip(List<int> head) => head.length >= 2 && head[0] == 0x1f && head[1] == 0x8b;

  /// Whether [head], the start of a text, is UTF-8: its last bytes may cut a letter short.
  static bool _isUtf8(List<int> head) {
    try {
      utf8.decode(head.length > 3 ? head.sublist(0, head.length - 3) : head);
      return true;
    } on FormatException {
      return false;
    }
  }

  @override
  bool get hideAdult => _hideAdult;
  @override
  set hideAdult(bool v) {
    if (v != _hideAdult) _lists = null;
    _hideAdult = v;
  }

  var _hideAdult = true; // whoever forgets to say hides too much, not too little

  @override
  bool get kidsOnly => _kidsOnly;
  @override
  set kidsOnly(bool v) {
    if (v != _kidsOnly) _lists = null;
    _kidsOnly = v;
  }

  var _kidsOnly = false;

  /// The channels and movies shown, by group, worked out once: picking a category goes through the
  /// whole list otherwise, on the UI's thread, each time. Again when what is hidden changes.
  ({
    List<LiveChannel> live,
    Map<String, List<LiveChannel>> liveIn,
    List<Movie> movies,
    Map<String, List<Movie>> moviesIn,
  })?
  _lists;

  ({
    List<LiveChannel> live,
    Map<String, List<LiveChannel>> liveIn,
    List<Movie> movies,
    Map<String, List<Movie>> moviesIn,
  })
  get _shownLists => _lists ??= () {
    final live = <LiveChannel>[], movies = <Movie>[];
    final liveIn = <String, List<LiveChannel>>{}, moviesIn = <String, List<Movie>>{};
    var place = 0;
    for (final e in entries) {
      if (e.isMovie) continue;
      place++;
      if (!_shown(e)) continue;
      final c = LiveChannel(
        id: _ids[e.url]!,
        name: e.name,
        number: int.tryParse(e.attrs['tvg-chno']?.trim() ?? '') ?? place,
        icon: e.logo,
        epgId: _epgIdOf(e),
        categoryId: e.group,
        archiveDays: int.tryParse(e.attrs['catchup-days'] ?? e.attrs['tvg-rec'] ?? '') ?? 0,
        url: e.url,
      );
      live.add(c);
      (liveIn[e.group] ??= []).add(c);
    }
    for (final e in _movies) {
      final m = Movie(id: _ids[e.url]!, name: e.name, poster: e.logo, categoryId: e.group, url: e.url);
      movies.add(m);
      (moviesIn[e.group] ??= []).add(m);
    }
    return (live: live, liveIn: liveIn, movies: movies, moviesIn: moviesIn);
  }();

  // An M3U says nothing about age: its group, its names and an adult="1" are all there is
  bool _shown(M3uEntry e) =>
      (!kidsOnly || isKidsCategory(e.group)) &&
      (!hideAdult ||
          !(isAdultCategory(e.group) ||
              isAdultTitle(e.name) ||
              isAdultTitle(e.attrs['tvg-name'] ?? '') ||
              e.attrs['adult'] == '1'));

  Iterable<M3uEntry> get _movies => entries.where((e) => e.isMovie && _shown(e));

  @override
  Future<List<Category>> liveCategories() async => [for (final g in _shownLists.liveIn.keys) Category(id: g, name: g)];

  @override
  Future<List<LiveChannel>> liveChannels([String? categoryId]) async =>
      List.of(categoryId == null ? _shownLists.live : _shownLists.liveIn[categoryId] ?? const []);

  @override
  Future<List<Category>> movieCategories() async => [
    for (final g in _shownLists.moviesIn.keys) Category(id: g, name: g),
  ];

  @override
  Future<List<Movie>> movies([String? categoryId]) async =>
      List.of(categoryId == null ? _shownLists.movies : _shownLists.moviesIn[categoryId] ?? const []);

  // M3U playlists carry no season structure
  @override
  Future<List<Category>> seriesCategories() async => const [];

  @override
  Future<List<Series>> series([String? categoryId]) async => const [];

  @override
  Future<SeriesDetail> seriesDetail(Series s) async => SeriesDetail(series: s, seasons: const {});

  @override
  Future<List<EpgEntry>> shortEpg(LiveChannel c, {int limit = 4}) async => const [];

  /// Its guides as one, each in turn (a guide is tens of MB; at once they would not fit in a TV
  /// stick); where two describe a channel, the first one's.
  @override
  Future<EpgGuide> guide() async {
    final guides = <EpgGuide>[];
    final channels = Future.value(_guideChannels());
    for (final u in guideUrls) {
      if (_closed.isCompleted) return EpgGuide.empty; // nobody waits for it any more
      final url = Uri.tryParse(u);
      if (url == null || !url.hasScheme) continue;
      final dir = cacheDir ?? await getApplicationCacheDirectory();
      guides.add(
        await loadXmltv(
          url,
          cache: File('${dir.path}/epg-${stableHash(url.toString())}.xml'),
          maxAge: refetchGuide ? Duration.zero : const Duration(hours: 6),
          stop: _closed.future,
          channels: channels,
          shift: guideShift,
        ),
      );
    }
    return guides.isEmpty ? EpgGuide.empty : EpgGuide.merge(guides);
  }

  /// The guide id [e] goes by: its tvg-id; with none, its name, by which the guide's own names for
  /// its channels are matched (see [GuideChannels]).
  static String _epgIdOf(M3uEntry e) => e.attrs['tvg-id'] ?? e.attrs['tvg-name'] ?? e.name;

  /// What its guides are read for: its channels, all of them (also those a profile hides: the guide
  /// is the playlist's), by the guide id, the names and the tvg-shift of each.
  GuideChannels _guideChannels() {
    final ids = <String>[], archive = <String>[];
    final names = <String, List<String>>{};
    final shifts = <String, Duration>{};
    for (final e in entries) {
      if (e.isMovie) continue;
      final id = _epgIdOf(e);
      ids.add(id);
      for (final n in {e.name, ?e.attrs['tvg-name']}) {
        (names[n] ??= []).add(id);
      }
      if (parseTvgShift(e.attrs['tvg-shift']) case final shift?) shifts[id] = shift;
      if ((int.tryParse(e.attrs['catchup-days'] ?? e.attrs['tvg-rec'] ?? '') ?? 0) > 0) archive.add(id);
    }
    return GuideChannels(ids: ids, names: names, shifts: shifts, archive: archive);
  }

  @override
  String liveUrl(LiveChannel c) => _current(c.id, c.url);

  @override
  String movieUrl(Movie m) => _current(m.id, m.url);

  /// Where the entry [id] is in the list as it is now: one from the library (Continue watching, My
  /// list) keeps the address it had, whose token may have expired or whose password changed. An
  /// address still in the list is kept, so of two entries that share an id each plays its own.
  String _current(String id, String? saved) {
    if (saved != null && _ids.containsKey(saved)) return saved;
    if (_byId[id] case final url?) return url;
    // Gone from the list, or saved when the playlist was another kind (an Xtream account, which
    // keeps no address): a kept address plays only if it is a stream's, not a path on the device
    if (saved != null && saved.contains('://') && isStreamAddress(saved)) return saved;
    throw const SourceException(SourceError.notFound);
  }

  /// Each entry's id, worked out once for the list: of two addresses with the same id (two
  /// servers' /hls/news/1), the first keeps it, so what was saved by it stays, and the next go by
  /// their address, hashed.
  late final Map<String, String> _ids = () {
    final ids = <String, String>{}, taken = <String>{};
    for (final e in entries) {
      if (ids.containsKey(e.url)) continue;
      var id = m3uId(e.url);
      if (!taken.add(id)) {
        id = m3uHash(e.url);
        taken.add(id);
      }
      ids[e.url] = id;
    }
    return ids;
  }();

  late final _byId = () {
    final out = <String, String>{};
    for (final MapEntry(key: url, value: id) in _ids.entries) {
      out.putIfAbsent(id, () => url);
    }
    return out;
  }();

  /// Whether [url] is one of this list's entries.
  bool has(String url) => _ids.containsKey(url);

  /// Whether the list is a panel's M3U export, whose channels go by the short /user/password/id:
  /// most of its addresses of that shape share the same user and password. A list of some server's
  /// /news/hd/7.ts is not one, and its addresses are not a panel's.
  late final bool isPanelExport = () {
    final accounts = <(String, String), int>{};
    var short = 0;
    for (final e in entries) {
      final p = parseXtreamPath(Uri.tryParse(e.url)?.path ?? '');
      if (p == null || p.type != null) continue;
      short++;
      accounts.update((p.user, p.password), (n) => n + 1, ifAbsent: () => 1);
    }
    final most = accounts.values.fold(0, (a, b) => a > b ? a : b);
    return most >= 2 && most * 2 > short;
  }();

  @override
  String episodeUrl(Episode e) => throw const SourceException(SourceError.notFound); // M3U lists have no series

  @override
  String? catchupUrl(LiveChannel c, DateTime start, Duration duration) => null;

  late final _headers = {
    for (final e in entries)
      if (e.headers.isNotEmpty) e.url: e.headers,
  };

  @override
  Map<String, String> headersFor(String url) => _headers[url] ?? const {};
}
