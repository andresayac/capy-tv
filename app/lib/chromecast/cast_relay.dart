import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../data/provider_client.dart';
import 'cast_plan.dart';
import 'hls_rewrite.dart';
import 'ts_filter.dart';

/// Streams a cast receiver cannot take from the provider itself, served by this device on the
/// local network: HLS with the CORS headers the receiver's player needs and its playlists pointing
/// back here, and files the provider only hands over with its own headers. The provider's address,
/// credentials included, never reaches the receiver.
///
/// Plain http: a receiver does not start a stream from a self-signed https server. Each served
/// candidate has its own random token, and only the receiver may fetch. Provider connections are
/// opened as the receiver asks for them, never limited here. The cookies the provider sets for a
/// candidate go back with its later requests, as when mpv plays it here.
class CastRelay {
  CastRelay._(this._server, this._allow, String userAgent) {
    _client.userAgent = userAgent;
  }

  final HttpServer _server;
  final InternetAddress? _allow;
  final _client = providerHttpClient();
  final _targets = <String, _Target>{}; // by token
  var _closed = false;

  static const _answer = Duration(seconds: 20); // for the provider to start answering
  static const _idle = Duration(seconds: 30); // for the next bytes of an answer
  static const _maxPlaylist = 16 << 20;
  static const _maxRedirects = 5;
  static final _random = Random.secure();

  /// Plain http on [bindTo] (the cast link's local address), port 0; every path under a 128-bit
  /// random token; only [allow] (the receiver's address) may fetch, when given. The provider is
  /// told [userAgent] unless a candidate's headers say otherwise: mpv's own, as when it plays here.
  static Future<CastRelay> start(InternetAddress bindTo, {InternetAddress? allow, String userAgent = 'libmpv'}) async {
    final server = await HttpServer.bind(bindTo, 0);
    final relay = CastRelay._(server, allow, userAgent);
    server.listen(relay._handle, onError: (Object _) {});
    return relay;
  }

  /// The URL the receiver loads: a rewritten HLS playlist, or the file with Range passed through.
  /// A direct candidate needs no relay: its own URL.
  String serve(CastCandidate candidate) {
    if (_closed) throw StateError('The relay is closed');
    if (candidate.route == CastRoute.direct) return candidate.url;
    final name = candidate.route == CastRoute.hls ? 'index.m3u8' : 'v${_fileSuffix(candidate)}';
    final target = _Target(_token(), candidate, name);
    _targets[target.token] = target;
    return _url(target, name);
  }

  /// What HLS [candidate] (given to [serve] first) carries, read from its playlists as the receiver
  /// will get them, through here: its first variant's segments and, when it comes apart, its
  /// audio's. Its address after redirects is kept, so the receiver's first request opens no new
  /// session at the provider. Null when it is not served here or cannot be read now.
  Future<HlsFormat?> formatOf(CastCandidate candidate) async {
    if (candidate.route != CastRoute.hls) return null;
    final t = _targets.values.where((t) => t.candidate == candidate && !t.revoked).firstOrNull;
    if (t == null) return null;
    final top = await _load(t, '');
    final text = top.text;
    if (text == null) return null;
    _rewrite(t, '', text, top.from!);
    final (:variant, :audio) = hlsFirstVariant(text, top.from!);
    if (variant == null) return hlsFormatOf(text);
    final video = (await _first(t, [variant])).text;
    if (video == null) return null;
    final format = hlsFormatOf(video);
    final apart = audio == null ? null : (await _first(t, [audio])).text;
    return apart == null ? format : HlsFormat(hlsFormatOf(apart).segment, format.video);
  }

  /// Whether the receiver ever reached it: no, and a cast that cannot play was kept from this
  /// device (a firewall, a Wi-Fi that keeps its devices apart).
  bool get reached => _reached;
  var _reached = false;

  /// The last refusal the provider sent for what the receiver asked (401, 403...), if any.
  int? get refused => _refused;
  int? _refused;

  /// A new item: earlier tokens stop working, their upstreams end.
  void retarget() {
    for (final t in _targets.values) {
      t.revoke();
    }
    _targets.clear();
  }

  /// Connections to the provider open now.
  @visibleForTesting
  int get upstreams => _targets.values.fold(0, (n, t) => n + t.open.length);

  Future<void> close() async {
    _closed = true;
    retarget();
    _client.close(force: true);
    await _server.close(force: true);
  }

  String _url(_Target t, String rest) =>
      Uri(scheme: 'http', host: _server.address.address, port: _server.port, path: '/${t.token}/$rest').toString();

  String _token() => [for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.done.ignore(); // a receiver that hangs up is no error here
    try {
      _allowCors(req);
      final segments = req.uri.pathSegments;
      final target = segments.isEmpty ? null : _targets[segments.first];
      final allow = _allow;
      if (target == null || (allow != null && req.connectionInfo?.remoteAddress.address != allow.address)) {
        return await _end(res, HttpStatus.forbidden);
      }
      _reached = true;
      if (req.method == 'OPTIONS') return await _end(res, HttpStatus.noContent);
      if (req.method != 'GET' && req.method != 'HEAD') {
        res.headers.set(HttpHeaders.allowHeader, 'GET, HEAD, OPTIONS');
        return await _end(res, HttpStatus.methodNotAllowed);
      }
      await _route(req, target, segments.sublist(1));
    } on _Revoked {
      await _end(res, HttpStatus.forbidden);
    } on TimeoutException {
      await _end(res, HttpStatus.gatewayTimeout);
    } on Object {
      await _end(res, HttpStatus.badGateway);
    }
  }

  /// Every answer carries these, errors too: the receiver's player runs in a page from elsewhere.
  void _allowCors(HttpRequest req) {
    req.response.headers
      ..set('access-control-allow-origin', '*')
      ..set('access-control-allow-methods', 'GET, HEAD, OPTIONS')
      ..set(
        'access-control-allow-headers',
        _headerSafe(req.headers['access-control-request-headers']?.join(', ')) ?? '*',
      )
      ..set('access-control-expose-headers', 'Content-Length, Content-Range, Accept-Ranges')
      // That page is on the internet and this device on the local network
      ..set('access-control-allow-private-network', 'true')
      ..set('access-control-max-age', '600');
  }

  Future<void> _route(HttpRequest req, _Target t, List<String> path) async {
    final id = path.length == 2 ? path[1].split('.').first : null;
    final link = id == null ? null : t.links[id];
    switch (path) {
      case [final name] when name == t.name:
        return t.candidate.route == CastRoute.hls
            ? _playlist(req, t, '')
            : _media(req, t, Uri.parse(t.candidate.url), segment: false);
      case ['p', _] when link?.kind == HlsKind.playlist:
        return _playlist(req, t, id!);
      case ['s', _] when link?.kind == HlsKind.media:
        return _media(req, t, link!.url, segment: true);
    }
    await _end(req.response, HttpStatus.notFound);
  }

  /// Playlist [id] ('' the candidate's own), fetched on every request (a live one changes) and
  /// rewritten to point here.
  Future<void> _playlist(HttpRequest req, _Target t, String id) async {
    final got = await _load(t, id);
    final text = got.text;
    if (text == null) return _end(req.response, got.status);
    final bytes = utf8.encode(_rewrite(t, id, text, got.from!));
    req.response
      ..headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..contentLength = bytes.length
      ..add(bytes);
    await req.response.close();
  }

  /// Playlist [id] from the provider: from where it came from last time, after redirects, so
  /// refreshes open no new sessions there; failing that, from where it was found. A variant or a
  /// rendition failing at both is looked for in a fresh master, as the master's address after
  /// redirects may hold a token that expired.
  Future<_Playlist> _load(_Target t, String id) async {
    final found = id.isEmpty ? Uri.parse(t.candidate.url) : t.links[t.moved[id] ?? id]!.url;
    final got = await _first(t, [?t.resolved[id], found]);
    if (got.text != null || id.isEmpty) return got;
    final master = await _load(t, '');
    if (master.text == null) return got;
    _rewrite(t, '', master.text!, master.from!); // for its new addresses; the receiver keeps the one it has
    final standIn = t.links.standIn('', id);
    final url = standIn == null ? null : t.links[standIn]!.url;
    if (url == null || url == found) return got;
    final fresh = await _first(t, [url]);
    if (fresh.text == null) return got;
    t.moved[id] = standIn!;
    return fresh;
  }

  /// The first of [urls] that gives a playlist, or how the last one failed.
  Future<_Playlist> _first(_Target t, List<Uri> urls) async {
    var failed = const _Playlist.failed(HttpStatus.badGateway);
    for (final url in urls.toSet()) {
      try {
        final f = await _open(t, url);
        try {
          final status = f.response!.statusCode;
          final text = status >= 200 && status < 300 ? await _text(f) : null;
          if (text != null) return _Playlist(text, f.url);
          // A refusal as it came; a page or a redirect too many is no playlist
          if (status >= 400) _refused = status;
          failed = _Playlist.failed(status >= 400 ? status : HttpStatus.badGateway);
        } finally {
          _release(t, f); // the provider is let go before the receiver hears back
        }
      } on _Revoked {
        rethrow;
      } on TimeoutException {
        failed = const _Playlist.failed(HttpStatus.gatewayTimeout);
      } on Object {
        failed = const _Playlist.failed(HttpStatus.badGateway);
      }
    }
    return failed;
  }

  /// [text], fetched from [from], as the latest version of playlist [id], every address in it
  /// pointing here.
  String _rewrite(_Target t, String id, String text, Uri from) {
    final body = t.links.rewrite(
      id,
      text,
      from,
      (linkId, kind, url) => _url(t, kind == HlsKind.playlist ? 'p/$linkId.m3u8' : 's/$linkId${_suffix(url)}'),
    );
    t.remember(id, from);
    return body;
  }

  /// [f]'s body when it is a playlist, else null. A body that starts as something else is let go
  /// at once: a video stream at a playlist's address would otherwise be read up to the limit.
  Future<String?> _text(_Fetch f) async {
    final bytes = BytesBuilder(copy: false);
    bool? hls;
    await for (final chunk in f.body.timeout(_idle)) {
      bytes.add(chunk);
      hls ??= _startsAsHls(bytes.toBytes()) ?? (bytes.length >= 1024 ? false : null);
      if (hls == false) return null;
      if (bytes.length > _maxPlaylist) throw const HttpException('The playlist is too large');
    }
    final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    return isHls(text) ? text : null;
  }

  /// A segment (or key) or a file, passed through as it comes, Range and all: one provider request
  /// per request, since the receiver reads a file with several ranges at once. A TS segment the
  /// provider calls something else (an image, octet-stream) goes as what it is, without its DVB
  /// service tables.
  Future<void> _media(HttpRequest req, _Target t, Uri url, {required bool segment}) async {
    final res = req.response;
    final f = await _open(
      t,
      url,
      media: true,
      extra: {
        for (final h in const [HttpHeaders.rangeHeader, HttpHeaders.ifRangeHeader]) h: ?req.headers[h]?.first,
      },
    );
    try {
      final rs = f.response!;
      if (rs.statusCode >= 400) {
        _refused = rs.statusCode;
        _copy(rs, res, const [HttpHeaders.contentRangeHeader]);
        _release(t, f);
        return await _end(res, rs.statusCode);
      }
      if (rs.statusCode != HttpStatus.ok && rs.statusCode != HttpStatus.partialContent) {
        _release(t, f);
        return await _end(res, HttpStatus.badGateway);
      }
      // The first bytes tell what the body is before the headers go
      final body = StreamIterator(f.body.timeout(_idle));
      final first = await body.moveNext() ? body.current : null;
      var type = rs.headers.contentType?.mimeType.toLowerCase();
      final ts = segment && first != null && first.isNotEmpty && first[0] == 0x47;
      if (_vague(type)) type = ts ? 'video/mp2t' : (segment ? type : t.candidate.contentType);
      // Without its tables a body no longer has the provider's length; a range is left as it is
      final filter = ts && type == 'video/mp2t' && rs.statusCode == HttpStatus.ok;
      res.statusCode = rs.statusCode;
      if (type != null) res.headers.set(HttpHeaders.contentTypeHeader, type);
      _copy(rs, res, const [
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]);
      if (!filter && rs.contentLength >= 0) res.contentLength = rs.contentLength;
      if (req.method == 'HEAD' || first == null) {
        await body.cancel();
        _release(t, f);
        return await res.close();
      }
      final rest = _rest(first, body);
      await res.addStream(filter ? _stripTables(rest) : rest);
      _release(t, f); // the provider is let go before the receiver hears the end
      await res.close();
    } finally {
      _release(t, f);
    }
  }

  /// Asks the provider for [url] on behalf of [t]. Redirects are followed here, so every hop gets
  /// the headers and the final address is known.
  Future<_Fetch> _open(_Target t, Uri url, {Map<String, String> extra = const {}, bool media = false}) async {
    var at = url;
    for (var hop = 0; ; hop++) {
      if (t.revoked) throw const _Revoked();
      final request = await _client.getUrl(at);
      final f = _Fetch(request);
      if (t.revoked) {
        f.cut();
        throw const _Revoked();
      }
      t.open.add(f);
      request.followRedirects = false;
      // Media goes as it is, its length and ranges true to its bytes
      if (media) request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      for (final MapEntry(:key, :value) in {...t.candidate.headers, ...extra}.entries) {
        try {
          request.headers.set(key, value);
        } on Object {
          // Not a header HTTP allows: left out
        }
      }
      final cookies = t.cookies.headerFor(at);
      if (cookies != null) {
        final own = request.headers.value(HttpHeaders.cookieHeader);
        request.headers.set(HttpHeaders.cookieHeader, own == null ? cookies : '$own; $cookies');
      }
      final timer = Timer(_answer, () => request.abort(TimeoutException('The provider did not answer')));
      try {
        f.response = await request.close();
      } on Object {
        t.open.remove(f);
        if (t.revoked) throw const _Revoked();
        rethrow;
      } finally {
        timer.cancel();
      }
      t.cookies.take(at, f.response!.headers[HttpHeaders.setCookieHeader]);
      final location = f.response!.headers[HttpHeaders.locationHeader]?.first;
      if (f.response!.isRedirect && location != null && hop < _maxRedirects) {
        _release(t, f);
        at = at.resolve(location);
        continue;
      }
      f.url = at;
      return f;
    }
  }

  void _release(_Target t, _Fetch f) {
    f.cut();
    t.open.remove(f);
  }
}

/// Ends [res] with [status]; one whose headers went out already just ends.
Future<void> _end(HttpResponse res, int status) async {
  try {
    res.statusCode = status;
    res.headers.contentLength = 0;
  } on Object {
    // Begun already
  }
  try {
    await res.close();
  } on Object {
    // The receiver is gone
  }
}

void _copy(HttpClientResponse from, HttpResponse to, List<String> names) {
  for (final name in names) {
    if (_headerSafe(from.headers[name]?.first) case final value?) to.headers.set(name, value);
  }
}

/// [value] when HTTP can carry it (printable ASCII and tabs), else none: a provider's or a stranger's
/// "café" would throw where it is set.
String? _headerSafe(String? value) =>
    value == null || value.codeUnits.any((c) => (c < 32 && c != 9) || c > 126) ? null : value;

/// A type that says nothing about a body: missing, octet-stream, or a disguise (image, text).
bool _vague(String? type) =>
    type == null ||
    type == 'application/octet-stream' ||
    type == 'binary/octet-stream' ||
    type.startsWith('image/') ||
    type.startsWith('text/');

/// Whether [head], the first bytes of a body, starts as a playlist does: #EXTM3U, after a BOM and
/// white space. Null while too few have come to tell.
bool? _startsAsHls(List<int> head) {
  const bom = [0xef, 0xbb, 0xbf];
  var i = 0;
  while (i < bom.length && i < head.length && head[i] == bom[i]) {
    i++;
  }
  if (i == head.length && i < bom.length) return null;
  if (i < bom.length) i = 0;
  while (i < head.length && (head[i] == 0x20 || (head[i] >= 0x09 && head[i] <= 0x0d))) {
    i++;
  }
  for (final byte in '#EXTM3U'.codeUnits) {
    if (i == head.length) return null;
    if (head[i++] != byte) return false;
  }
  return true;
}

/// The extension of [url]'s file name, with its dot, or nothing: a receiver's player tells a
/// segment's format by it.
String _suffix(Uri url) {
  final m = RegExp(r'\.([A-Za-z0-9]{1,5})$').firstMatch(url.pathSegments.lastOrNull ?? '');
  return m == null ? '' : '.${m[1]!.toLowerCase()}';
}

String _fileSuffix(CastCandidate c) => switch (_suffix(Uri.tryParse(c.url) ?? Uri())) {
  '' => switch (c.contentType) {
    'video/webm' => '.webm',
    'video/x-matroska' => '.mkv',
    _ => '.mp4',
  },
  final s => s,
};

/// [first], then what [more] brings.
Stream<List<int>> _rest(List<int> first, StreamIterator<List<int>> more) async* {
  try {
    yield first;
    while (await more.moveNext()) {
      yield more.current;
    }
  } finally {
    await more.cancel();
  }
}

Stream<List<int>> _stripTables(Stream<List<int>> input) async* {
  final filter = TsTableFilter();
  await for (final chunk in input) {
    final kept = filter.add(chunk);
    if (kept.isNotEmpty) yield kept;
  }
  final rest = filter.close();
  if (rest.isNotEmpty) yield rest;
}

/// One served candidate, under its own token.
class _Target {
  _Target(this.token, this.candidate, this.name);

  final String token, name;
  final CastCandidate candidate;
  final links = HlsLinks();
  final resolved = <String, Uri>{}; // a playlist's address after redirects, by id ('' the first), oldest first
  final moved = <String, String>{}; // a playlist the receiver asks for by id -> the one a fresh master has there
  final cookies = _Cookies();
  final open = <_Fetch>{};
  var revoked = false;

  void remember(String id, Uri url) {
    resolved.remove(id);
    resolved[id] = url;
    if (resolved.length > 256) resolved.remove(resolved.keys.first);
  }

  void revoke() {
    revoked = true;
    for (final f in [...open]) {
      f.cut();
    }
    open.clear();
  }
}

/// One request to the provider, which [cut] ends at any point: before it is answered, or while its
/// body comes (the body then ends with an error).
class _Fetch {
  _Fetch(this.request);

  final HttpClientRequest request;
  HttpClientResponse? response;
  late Uri url; // where the response came from, after redirects
  StreamController<List<int>>? _out;
  StreamSubscription<List<int>>? _in;
  var _cut = false;

  /// The response's body; read once.
  Stream<List<int>> get body {
    if (_cut) return Stream.error(const _Revoked());
    final out = _out = StreamController<List<int>>(sync: true);
    out.onListen = () {
      if (_cut) return;
      final sub = _in = response!.listen(
        (chunk) => out.isClosed ? null : out.add(chunk),
        onError: (Object e, StackTrace s) => out.isClosed ? null : out.addError(e, s),
        onDone: () => out.isClosed ? null : out.close(),
      );
      out
        ..onPause = sub.pause
        ..onResume = sub.resume
        ..onCancel = sub.cancel;
    };
    return out.stream;
  }

  void cut() {
    if (_cut) return;
    _cut = true;
    request.done.ignore();
    request.abort(const _Revoked()); // does nothing once the answer began
    final out = _out;
    if (out == null) {
      // An unread body: listening and leaving at once lets go of the connection
      try {
        response?.listen(null).cancel();
      } on Object {
        // Read already
      }
      return;
    }
    unawaited(_in?.cancel());
    if (!out.isClosed) {
      out.addError(const _Revoked());
      unawaited(out.close());
    }
  }
}

class _Revoked implements Exception {
  const _Revoked();
}

/// A playlist the provider gave, from [from] after redirects; without [text], the [status] the
/// receiver gets instead.
class _Playlist {
  const _Playlist(String this.text, Uri this.from) : status = HttpStatus.ok;
  const _Playlist.failed(this.status) : text = null, from = null;

  final String? text;
  final Uri? from;
  final int status;
}

/// The cookies the provider sets while a candidate plays, sent back with its later requests, as
/// mpv's HLS demuxer does: some CDNs let segments through only with a cookie their playlist set.
class _Cookies {
  final _jar = <String, _Cookie>{}; // by name, domain and path, oldest first

  /// Keeps the cookies [setCookie], the Set-Cookie headers of an answer from [url]. One that has
  /// expired already deletes the one it names.
  void take(Uri url, List<String>? setCookie) {
    for (final header in setCookie ?? const <String>[]) {
      final c = _Cookie.parse(header, url);
      if (c == null) continue;
      final key = '${c.name}; ${c.domain}; ${c.path}';
      _jar.remove(key);
      if (c.live(DateTime.now())) _jar[key] = c;
      if (_jar.length > 50) _jar.remove(_jar.keys.first);
    }
  }

  /// The Cookie header for a request to [url], or null when no cookie goes there.
  String? headerFor(Uri url) {
    final now = DateTime.now();
    _jar.removeWhere((_, c) => !c.live(now));
    final sent = [
      for (final c in _jar.values)
        if (c.goesTo(url)) c,
    ]..sort((a, b) => b.path.length.compareTo(a.path.length)); // the most specific first
    return sent.isEmpty ? null : sent.map((c) => '${c.name}=${c.value}').join('; ');
  }
}

/// A cookie as RFC 6265 has a client read it, leniently: what it cannot read it leaves out.
class _Cookie {
  _Cookie(this.name, this.value, this.domain, this.path, {required this.hostOnly, required this.secure, this.expires});

  final String name, value, domain, path;
  final bool hostOnly, secure;
  final DateTime? expires; // null: while the candidate plays

  /// [header], a Set-Cookie value from [from]; null when it is no cookie, or one for another site.
  static _Cookie? parse(String header, Uri from) {
    final [pair, ...attributes] = header.split(';');
    final eq = pair.indexOf('=');
    final name = eq < 0 ? '' : pair.substring(0, eq).trim();
    if (name.isEmpty) return null;
    final host = from.host.toLowerCase();
    final slash = from.path.lastIndexOf('/');
    var domain = host, path = slash <= 0 ? '/' : from.path.substring(0, slash);
    var hostOnly = true, secure = false;
    DateTime? expires;
    int? maxAge;
    for (final attribute in attributes) {
      final i = attribute.indexOf('=');
      final value = i < 0 ? '' : attribute.substring(i + 1).trim();
      switch ((i < 0 ? attribute : attribute.substring(0, i)).trim().toLowerCase()) {
        case 'domain' when value.isNotEmpty:
          final d = (value.startsWith('.') ? value.substring(1) : value).toLowerCase();
          if (!_domainMatch(host, d)) return null;
          (domain, hostOnly) = (d, false);
        case 'path' when value.startsWith('/'):
          path = value;
        case 'secure':
          secure = true;
        case 'max-age':
          maxAge = int.tryParse(value) ?? maxAge;
        case 'expires':
          expires = _cookieDate(value) ?? expires;
      }
    }
    // Max-Age wins over Expires; zero or less deletes
    if (maxAge != null) {
      expires = maxAge > 0 ? DateTime.now().add(Duration(seconds: maxAge)) : DateTime.fromMillisecondsSinceEpoch(0);
    }
    final value = pair.substring(eq + 1).trim();
    return _Cookie(name, value, domain, path, hostOnly: hostOnly, secure: secure, expires: expires);
  }

  bool live(DateTime now) => expires?.isAfter(now) ?? true;

  bool goesTo(Uri url) {
    final host = url.host.toLowerCase();
    if (hostOnly ? host != domain : !_domainMatch(host, domain)) return false;
    if (secure && !url.isScheme('https')) return false;
    final p = url.path.isEmpty ? '/' : url.path;
    return p == path || (p.startsWith(path) && (path.endsWith('/') || p[path.length] == '/'));
  }

  /// Whether [domain] takes in [host]: it is the host, or a name the host is under. A bare name
  /// (like "com") takes in only itself.
  static bool _domainMatch(String host, String domain) =>
      host == domain || (domain.contains('.') && host.endsWith('.$domain') && InternetAddress.tryParse(host) == null);

  /// The dates cookies come with: HTTP's, and the old Netscape form with dashes.
  static DateTime? _cookieDate(String text) {
    for (final form in [text, text.replaceAll('-', ' ')]) {
      try {
        return HttpDate.parse(form);
      } on Object {
        // The next form
      }
    }
    return null;
  }
}
