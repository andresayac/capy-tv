// The relay a cast receiver plays through: HLS rewritten to point back at it, files with Range,
// CORS for the receiver's page, and only for the receiver.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/chromecast/cast_plan.dart';
import 'package:iptv_player/chromecast/cast_relay.dart';
import 'package:iptv_player/chromecast/hls_rewrite.dart';
import 'package:iptv_player/chromecast/ts_filter.dart';

typedef _Asked = ({String method, String path, HttpHeaders headers});

/// A provider on this machine; [answer] serves each request, and [asked] lists them.
class _Provider {
  _Provider._(this._server);

  final HttpServer _server;
  final asked = <_Asked>[];

  static Future<_Provider> start(Future<void> Function(HttpRequest req) answer) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final provider = _Provider._(server);
    server.listen((req) {
      provider.asked.add((method: req.method, path: req.uri.toString(), headers: req.headers));
      answer(req);
    });
    return provider;
  }

  String url(String path) => 'http://127.0.0.1:${_server.port}$path';
  int count(String path) => asked.where((a) => a.path == path).length;
  Future<void> close() => _server.close(force: true);
}

typedef _Got = ({int status, HttpHeaders headers, List<int> body});

/// What a receiver asking for [url] gets.
Future<_Got> _fetch(String url, {String method = 'GET', Map<String, String> headers = const {}}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse(url));
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = <int>[];
    await res.forEach(body.addAll);
    return (status: res.statusCode, headers: res.headers, body: body);
  } finally {
    client.close(force: true);
  }
}

Future<String> _text(String url) async {
  final got = await _fetch(url);
  expect(got.status, 200, reason: url);
  return utf8.decode(got.body);
}

/// The addresses in a playlist: URI lines and URI attributes.
List<String> _addresses(String playlist) => [
  for (final line in const LineSplitter().convert(playlist))
    if (line.startsWith('#'))
      for (final m in RegExp(r'URI="([^"]+)"').allMatches(line)) m[1]!
    else if (line.isNotEmpty)
      line,
];

/// Serves [data] as a file server does, Range and all.
Future<void> _file(HttpRequest req, List<int> data, {String type = 'application/octet-stream'}) async {
  final res = req.response
    ..headers.set('content-type', type)
    ..headers.set('accept-ranges', 'bytes');
  final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(req.headers.value('range') ?? '');
  if (m == null) {
    res.contentLength = data.length;
    if (req.method != 'HEAD') res.add(data);
  } else {
    final start = int.parse(m[1]!), end = m[2]!.isEmpty ? data.length - 1 : int.parse(m[2]!);
    res
      ..statusCode = HttpStatus.partialContent
      ..headers.set('content-range', 'bytes $start-$end/${data.length}')
      ..contentLength = end - start + 1;
    if (req.method != 'HEAD') res.add(data.sublist(start, end + 1));
  }
  await res.close();
}

List<int> _bytes(int n, int seed) => [for (var i = 0; i < n; i++) (i * 7 + seed) % 256];

/// One MPEG-TS packet on [pid], its payload marked with [mark].
List<int> _packet(int pid, int mark) => [0x47, pid >> 8 & 0x1f, pid & 0xff, 0x10, for (var i = 4; i < 188; i++) mark];

/// The packets that carry one table section on [pid]: [table] with [body] after its header (number
/// 1, version 0, current), its CRC left zero.
List<int> _table(int pid, int table, List<int> body) {
  final length = 5 + body.length + 4;
  final payload = [0, table, 0xb0 | length >> 8, length & 0xff, 0, 1, 0xc1, 0, 0, ...body, 0, 0, 0, 0];
  return [
    for (var i = 0; i < payload.length; i += 184) ...[
      0x47,
      (i == 0 ? 0x40 : 0) | pid >> 8,
      pid & 0xff,
      0x10 | (i ~/ 184 & 0xf),
      for (var j = i; j < i + 184; j++) j < payload.length ? payload[j] : 0xff,
    ],
  ];
}

/// A PAT naming the PMTs [pmts], a program each.
List<int> _pat(List<int> pmts) => _table(0, 0x00, [
  for (final (i, pid) in pmts.indexed) ...[0, i + 1, 0xe0 | pid >> 8, pid & 0xff],
]);

/// A PMT on [pid] naming the streams [streams], the PCR on the first.
List<int> _pmt(int pid, List<int> streams) => _table(pid, 0x02, [
  0xe0 | streams.first >> 8,
  streams.first & 0xff,
  0xf0,
  0,
  for (final s in streams) ...[0x1b, 0xe0 | s >> 8, s & 0xff, 0xf0, 0],
]);

/// [stream] through a [TsTableFilter], in chunks of [size].
List<int> _filtered(List<int> stream, [int size = 188]) {
  final filter = TsTableFilter();
  return [
    for (var i = 0; i < stream.length; i += size) ...filter.add(stream.sublist(i, (i + size).clamp(0, stream.length))),
    ...filter.close(),
  ];
}

/// A server that answers anything with an endless [type] body, a bare socket: an HTTP server does
/// not hear of a client gone. [cut] completes when the relay lets go; [sent] counts what went.
class _Endless {
  _Endless._(this._server, this.type);

  final ServerSocket _server;
  final String type;
  final cut = Completer<void>();
  var asked = 0, sent = 0;

  static Future<_Endless> start(String type) async {
    final endless = _Endless._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), type);
    endless._server.listen(endless._answer);
    return endless;
  }

  void _answer(Socket socket) {
    asked++;
    void end() => cut.isCompleted ? null : cut.complete();
    // A link the relay drops with data unread is reset on some systems: an error, then the end
    socket.done.ignore();
    socket.listen((_) {}, onDone: end, onError: (Object _) => end());
    socket.write('HTTP/1.1 200 OK\r\nContent-Type: $type\r\nContent-Length: ${1 << 30}\r\n\r\n');
    Timer.periodic(const Duration(milliseconds: 5), (timer) {
      if (cut.isCompleted) return timer.cancel();
      try {
        socket.add(_bytes(16 * 1024, timer.tick));
        sent += 16 * 1024;
      } on Object {
        timer.cancel();
      }
    });
  }

  String url(String path) => 'http://127.0.0.1:${_server.port}$path';
  Future<void> close() => _server.close();
}

const _hls = 'application/x-mpegurl';

void main() {
  HttpOverrides.global = null; // real sockets
  final loopback = InternetAddress.loopbackIPv4;

  test('CORS on GET, HEAD and OPTIONS, private network access allowed, without asking the provider', () async {
    final movie = _bytes(5000, 1);
    final provider = await _Provider.start((req) => _file(req, movie));
    final relay = await CastRelay.start(loopback, allow: loopback);
    final url = relay.serve(
      CastCandidate(url: provider.url('/movie/u/p/9.mp4'), contentType: 'video/mp4', route: CastRoute.progressive),
    );
    expect(url, matches(RegExp(r'^http://127\.0\.0\.1:\d+/[0-9a-f]{32}/v\.mp4$')));

    final pre = await _fetch(
      url,
      method: 'OPTIONS',
      headers: {
        'Origin': 'https://www.gstatic.com',
        'Access-Control-Request-Method': 'GET',
        'Access-Control-Request-Headers': 'range',
        'Access-Control-Request-Private-Network': 'true',
      },
    );
    expect(pre.status, HttpStatus.noContent);
    expect(pre.headers.value('access-control-allow-origin'), '*');
    expect(pre.headers.value('access-control-allow-methods'), contains('GET'));
    expect(pre.headers.value('access-control-allow-headers'), 'range');
    expect(pre.headers.value('access-control-allow-private-network'), 'true');
    expect(provider.asked, isEmpty);

    for (final method in ['GET', 'HEAD']) {
      final got = await _fetch(url, method: method, headers: {'Origin': 'https://www.gstatic.com'});
      expect(got.status, 200, reason: method);
      expect(got.headers.value('access-control-allow-origin'), '*', reason: method);
      expect(got.headers.value('access-control-allow-private-network'), 'true', reason: method);
      expect(got.headers.value('access-control-expose-headers'), contains('Content-Range'), reason: method);
      expect(got.headers.contentType?.mimeType, 'video/mp4', reason: 'the plan says what it is, not octet-stream');
      expect(got.headers.contentLength, movie.length, reason: method);
      expect(got.body, method == 'GET' ? movie : isEmpty);
    }
    await relay.close();
    await provider.close();
  });

  test('it tells whether the receiver reached it, and what the provider refused', () async {
    final provider = await _Provider.start((req) async {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
    });
    final relay = await CastRelay.start(loopback, allow: loopback);
    final url = relay.serve(
      CastCandidate(url: provider.url('/live/u/p/1.m3u8'), contentType: 'application/x-mpegurl', route: CastRoute.hls),
    );
    expect((relay.reached, relay.refused), (false, null), reason: 'nothing asked yet: a firewall would look so');
    expect((await _fetch(url)).status, isNot(200));
    expect((relay.reached, relay.refused), (true, HttpStatus.forbidden));
    await relay.close();
    await provider.close();
  });

  test('a header HTTP cannot carry ("café") is answered, not left hanging', () async {
    final provider = await _Provider.start((req) => _file(req, _bytes(10, 1)));
    final relay = await CastRelay.start(loopback, allow: loopback);
    final url = Uri.parse(
      relay.serve(CastCandidate(url: provider.url('/m.mp4'), contentType: 'video/mp4', route: CastRoute.progressive)),
    );
    // Sent by hand: Dart's own client would not send it
    final socket = await Socket.connect(url.host, url.port);
    socket.add(
      latin1.encode(
        'OPTIONS ${url.path} HTTP/1.1\r\nHost: ${url.host}\r\nAccess-Control-Request-Headers: caf\u00e9\r\n'
        'Connection: close\r\n\r\n',
      ),
    );
    final answer = latin1.decode(await socket.expand((b) => b).toList().timeout(const Duration(seconds: 5)));
    socket.destroy();
    expect(answer, startsWith('HTTP/1.1 204'));
    expect(answer.toLowerCase(), contains('access-control-allow-headers: *'));
    await relay.close();
    await provider.close();
  });

  test('a file: Range passed through, one provider request per request, parallel ones too', () async {
    final movie = _bytes(100000, 2);
    final provider = await _Provider.start((req) => _file(req, movie, type: 'video/x-matroska'));
    final relay = await CastRelay.start(loopback, allow: loopback);
    final url = relay.serve(
      CastCandidate(
        url: provider.url('/movie/u/p/9.mkv'),
        contentType: 'video/x-matroska',
        route: CastRoute.progressive,
      ),
    );
    expect(url, endsWith('/v.mkv'));

    final part = await _fetch(url, headers: {'Range': 'bytes=1000-1999'});
    expect(part.status, HttpStatus.partialContent);
    expect(part.headers.value('content-range'), 'bytes 1000-1999/100000');
    expect(part.headers.contentLength, 1000);
    expect(part.body, movie.sublist(1000, 2000));

    final parts = await Future.wait([
      for (final start in [0, 40000, 99000]) _fetch(url, headers: {'Range': 'bytes=$start-'}),
    ]);
    expect([for (final p in parts) p.body.length], [100000, 60000, 1000]);
    expect(parts[2].body, movie.sublist(99000));
    expect(provider.asked, hasLength(4), reason: 'one each, none held back');
    expect(
      {for (final a in provider.asked) a.headers.value('range')},
      {'bytes=1000-1999', 'bytes=0-', 'bytes=40000-', 'bytes=99000-'},
    );
    expect(relay.upstreams, 0);
    await relay.close();
    await provider.close();
  });

  test('the provider gets the User-Agent and headers, mpv\'s own by default; never the receiver\'s', () async {
    final provider = await _Provider.start((req) => _file(req, _bytes(10, 3)));
    final relay = await CastRelay.start(loopback, allow: loopback);
    CastCandidate file(Map<String, String> headers) => CastCandidate(
      url: provider.url('/f.mp4'),
      contentType: 'video/mp4',
      route: CastRoute.progressive,
      headers: headers,
    );
    await _fetch(relay.serve(file(const {})), headers: {'User-Agent': 'CrKey/1.56'});
    await _fetch(relay.serve(file({'User-Agent': 'VLC/3.0.20', 'Referer': 'http://portal.example/'})));
    expect(provider.asked[0].headers.value('user-agent'), 'libmpv');
    expect(provider.asked[1].headers.value('user-agent'), 'VLC/3.0.20');
    expect(provider.asked[1].headers.value('referer'), 'http://portal.example/');
    await relay.close();

    final own = await CastRelay.start(loopback, userAgent: 'Capy/1.0');
    await _fetch(own.serve(file(const {})));
    expect(provider.asked.last.headers.value('user-agent'), 'Capy/1.0');
    await own.close();
    await provider.close();
  });

  test('HLS: redirects followed, addresses resolved against where they landed, refreshes go there; a 4xx '
      'or 5xx there resolves once more', () async {
    var edge = 'A';
    final refused = <String, int>{};
    late final _Provider provider;
    provider = await _Provider.start((req) async {
      final res = req.response;
      switch (req.uri.path) {
        case final path when refused.containsKey(path):
          res.statusCode = refused[path]!;
        case '/live/u/p/7.m3u8':
          res
            ..statusCode = HttpStatus.found
            ..headers.set('location', '/edge/s1/master.m3u8');
        case '/edge/s1/master.m3u8':
          res.headers.set('content-type', 'application/vnd.apple.mpegurl');
          res.write(
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en",URI="audio/en.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="a"\n'
            'low/index.m3u8\n',
          );
        case '/edge/s1/low/index.m3u8':
          res
            ..statusCode = HttpStatus.temporaryRedirect
            ..headers.set('location', provider.url('/cdn/$edge/low.m3u8'));
        case final path when path.startsWith('/cdn/') && path.endsWith('/low.m3u8'):
          res.headers.set('content-type', 'application/x-mpegURL');
          res.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="../keys/k.bin"\n'
            '#EXTINF:4,\nseg1.ts\n',
          );
        case final path when path.startsWith('/cdn/') && path.endsWith('/seg1.ts'):
          res.headers.set('content-type', 'video/mp2t');
          res.add(_packet(0x100, 1));
        case '/cdn/keys/k.bin':
          res.headers.set('content-type', 'application/octet-stream');
          res.add(List.filled(16, 9));
        default:
          res.statusCode = HttpStatus.notFound;
      }
      await res.close();
    });
    final relay = await CastRelay.start(loopback, allow: loopback);
    final index = relay.serve(
      CastCandidate(
        url: provider.url('/live/u/p/7.m3u8'),
        contentType: _hls,
        route: CastRoute.hls,
        headers: const {'User-Agent': 'VLC/3.0.20'},
        live: true,
      ),
    );
    expect(index, endsWith('/index.m3u8'));

    final got = await _fetch(index);
    expect(got.status, 200);
    expect(got.headers.contentType?.mimeType, 'application/vnd.apple.mpegurl');
    expect(got.headers.value('access-control-allow-origin'), '*');
    final master = utf8.decode(got.body);
    expect(master, isNot(contains(provider.url(''))), reason: 'the provider stays out of sight');
    final [audio, variant] = _addresses(master);
    expect(audio, endsWith('.m3u8'));
    expect(variant, startsWith(index.replaceFirst('index.m3u8', 'p/')));

    final media = await _text(variant);
    final [key, segment] = _addresses(media);
    expect(key, endsWith('.bin'), reason: 'ids keep the extension');
    expect(segment, endsWith('.ts'));
    expect((await _fetch(segment)).body, _packet(0x100, 1));
    expect((await _fetch(key)).body, List.filled(16, 9));
    expect(provider.count('/cdn/A/seg1.ts'), 1, reason: 'resolved against the address after the redirect');
    expect(provider.count('/cdn/keys/k.bin'), 1);

    await _text(variant); // a refresh
    expect(provider.count('/edge/s1/low/index.m3u8'), 1, reason: 'refreshes go where the redirect landed');
    expect(provider.count('/cdn/A/low.m3u8'), 2);

    refused['/cdn/A/low.m3u8'] = HttpStatus.forbidden;
    edge = 'B';
    final again = await _text(variant);
    expect(provider.count('/edge/s1/low/index.m3u8'), 2, reason: 'a 4xx there: resolved again');
    expect(provider.count('/cdn/B/low.m3u8'), 1);
    expect((await _fetch(_addresses(again).last)).status, 200);
    expect(provider.count('/cdn/B/seg1.ts'), 1);

    refused['/cdn/B/low.m3u8'] = HttpStatus.serviceUnavailable;
    edge = 'C';
    await _text(variant);
    expect(provider.count('/edge/s1/low/index.m3u8'), 3, reason: 'a 5xx there: resolved again');
    expect(provider.count('/cdn/C/low.m3u8'), 1);
    expect({for (final a in provider.asked) a.headers.value('user-agent')}, {'VLC/3.0.20'}, reason: 'every hop');
    expect(provider.count('/live/u/p/7.m3u8'), 1, reason: 'the master was asked for once');
    await relay.close();
    await provider.close();
  });

  test('a variant whose address expired is found again in a fresh master; refreshes go there from then '
      'on', () async {
    var token = 'AAA', open = true;
    final provider = await _Provider.start((req) async {
      final res = req.response;
      final path = req.uri.path;
      if (path == '/live/u/p/7.m3u8' && open) {
        // Tokens in the address the redirect gives, and so in every address resolved against it
        res
          ..statusCode = HttpStatus.found
          ..headers.set('location', '/tok/$token/master.m3u8');
      } else if (!path.startsWith('/tok/$token/')) {
        res.statusCode = HttpStatus.forbidden;
      } else if (path.endsWith('/master.m3u8')) {
        res.write(
          '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en",URI="en.m3u8"\n'
          // Measured anew on every request, as some servers do
          '#EXT-X-STREAM-INF:BANDWIDTH=${token == 'AAA' ? 800000 : 812345},AUDIO="a"\n'
          'low.m3u8\n',
        );
      } else if (path.endsWith('.m3u8')) {
        res.write('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg.ts\n');
      } else {
        res.headers.set('content-type', 'video/mp2t');
        res.add(_packet(0x100, 1));
      }
      await res.close();
    });
    final relay = await CastRelay.start(loopback, allow: loopback);
    final index = relay.serve(
      CastCandidate(url: provider.url('/live/u/p/7.m3u8'), contentType: _hls, route: CastRoute.hls, live: true),
    );
    final [audio, variant] = _addresses(await _text(index));
    expect((await _fetch(_addresses(await _text(variant)).single)).status, 200);

    token = 'BBB';
    final again = await _text(variant);
    expect(provider.count('/tok/AAA/low.m3u8'), 2, reason: 'asked once where it was found, which failed');
    expect(provider.count('/live/u/p/7.m3u8'), 2, reason: 'the master again, from the start');
    expect(provider.count('/tok/BBB/low.m3u8'), 1);
    expect((await _fetch(_addresses(again).single)).status, 200);
    expect(provider.count('/tok/BBB/seg.ts'), 1);

    await _text(variant);
    expect(provider.count('/tok/BBB/low.m3u8'), 2, reason: 'refreshes go to the new address');
    expect(provider.count('/live/u/p/7.m3u8'), 2);

    await _text(audio); // never asked for before: found with the old token, then in the master it got
    expect(provider.count('/tok/AAA/en.m3u8'), 1);
    expect(provider.count('/tok/BBB/en.m3u8'), 1);
    expect(provider.count('/live/u/p/7.m3u8'), 2, reason: 'the fresh master\'s address still works');

    // No master to be had: the variant's own refusal reaches the receiver
    token = 'CCC';
    open = false;
    expect((await _fetch(variant)).status, HttpStatus.forbidden);
    expect(relay.upstreams, 0);
    await relay.close();
    await provider.close();
  });

  test('what an HLS stream carries is read through the relay, its redirect kept for the receiver', () async {
    final provider = await _Provider.start((req) async {
      final res = req.response;
      final path = req.uri.path;
      if (path == '/live/u/p/8.m3u8') {
        res
          ..statusCode = HttpStatus.found
          ..headers.set('location', '/tok/T/master.m3u8');
      } else if (path == '/tok/T/master.m3u8') {
        res.write(
          '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en",DEFAULT=YES,URI="en.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="a"\n'
          'low.m3u8\n',
        );
      } else if (path == '/tok/T/low.m3u8') {
        res.write('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:6,\nseg1.m4s\n');
      } else if (path == '/tok/T/en.m3u8') {
        res.write('#EXTM3U\n#EXTINF:6,\nseg1.aac\n');
      } else if (path == '/plain.m3u8') {
        res.write('#EXTM3U\n#EXTINF:6,\nseg1.ts\n');
      } else {
        res.statusCode = HttpStatus.notFound;
      }
      await res.close();
    });
    final relay = await CastRelay.start(loopback, allow: loopback);
    final cmaf = CastCandidate(
      url: provider.url('/live/u/p/8.m3u8'),
      contentType: _hls,
      route: CastRoute.hls,
      live: true,
    );
    final index = relay.serve(cmaf);
    expect(await relay.formatOf(cmaf), const HlsFormat('aac', 'fmp4'), reason: 'fMP4 video, its audio packed apart');
    await _text(index);
    expect(provider.count('/live/u/p/8.m3u8'), 1, reason: 'the receiver goes where the redirect led');

    final plain = CastCandidate(url: provider.url('/plain.m3u8'), contentType: _hls, route: CastRoute.hls);
    relay.serve(plain);
    expect(await relay.formatOf(plain), HlsFormat.ts);

    final gone = CastCandidate(url: provider.url('/nothing.m3u8'), contentType: _hls, route: CastRoute.hls);
    relay.serve(gone);
    expect(await relay.formatOf(gone), isNull, reason: 'not read: the receiver is told nothing new');
    expect(
      await relay.formatOf(
        CastCandidate(url: provider.url('/plain.m3u8'), contentType: _hls, route: CastRoute.progressive),
      ),
      isNull,
    );
    await relay.close();
    await provider.close();
  });

  test('a cached address that no longer answers: back to where the playlist was found', () async {
    Future<_Provider> edge() => _Provider.start((req) async {
      req.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg.ts\n');
      await req.response.close();
    });
    final edge1 = await edge();
    var to = edge1;
    final origin = await _Provider.start((req) async {
      req.response
        ..statusCode = HttpStatus.found
        ..headers.set('location', to.url('/live.m3u8'));
      await req.response.close();
    });
    final relay = await CastRelay.start(loopback, allow: loopback);
    final index = relay.serve(
      CastCandidate(url: origin.url('/live/u/p/7.m3u8'), contentType: _hls, route: CastRoute.hls, live: true),
    );
    await _text(index);
    await _text(index);
    expect(origin.asked, hasLength(1));
    expect(edge1.asked, hasLength(2));

    await edge1.close();
    final edge2 = await edge();
    to = edge2;
    await _text(index);
    expect(origin.asked, hasLength(2), reason: 'the cached edge is gone');
    expect(edge2.asked, hasLength(1));
    await relay.close();
    await origin.close();
    await edge2.close();
  });

  test('a long film in HLS: its first segment plays as its last does', () async {
    final provider = await _Provider.start((req) async {
      final res = req.response;
      if (req.uri.path == '/vod.m3u8') {
        res.write(
          '#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:3\n'
          '${[for (var i = 0; i < 2400; i++) '#EXTINF:3,\ns$i.ts\n'].join()}'
          '#EXT-X-ENDLIST\n',
        );
      } else {
        res.headers.set('content-type', 'video/mp2t');
        res.add(_packet(0x100, 1));
      }
      await res.close();
    });
    final relay = await CastRelay.start(loopback, allow: loopback);
    final segments = _addresses(
      await _text(relay.serve(CastCandidate(url: provider.url('/vod.m3u8'), contentType: _hls, route: CastRoute.hls))),
    );
    expect(segments, hasLength(2400));
    for (final segment in [segments.first, segments.last]) {
      expect((await _fetch(segment)).status, 200, reason: segment);
    }
    expect([provider.count('/s0.ts'), provider.count('/s2399.ts')], [1, 1]);
    await relay.close();
    await provider.close();
  });

  test('a playlist address that answers with video is let go at once, not read to the limit', () async {
    final endless = await _Endless.start('video/mp2t');
    final relay = await CastRelay.start(loopback, allow: loopback);
    final got = await _fetch(
      relay.serve(
        CastCandidate(url: endless.url('/live/u/p/7.m3u8'), contentType: _hls, route: CastRoute.hls, live: true),
      ),
    );
    expect(got.status, HttpStatus.badGateway);
    await endless.cut.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('the provider was not let go'));
    expect(endless.sent, lessThan(4 << 20), reason: 'the limit is 16 MiB');
    expect(relay.upstreams, 0);
    await relay.close();
    await endless.close();
  });

  test('cookies the provider sets go back with the candidate\'s later requests, where they belong', () async {
    final provider = await _Provider.start((req) async {
      final res = req.response;
      final cookie = req.headers.value('cookie') ?? '';
      switch (req.uri.path) {
        case '/c/live.m3u8':
          res
            ..statusCode = HttpStatus.found
            ..headers.set('location', '/c/master.m3u8')
            ..headers.add('set-cookie', 'hop=1; Path=/');
        case '/c/master.m3u8':
          res.headers
            ..add('set-cookie', 'hdntl=exp=1~acl=%2f*~hmac=ab; Path=/c; HttpOnly')
            ..add('set-cookie', 'elsewhere=1; Path=/other')
            ..add('set-cookie', 'foreign=1; Domain=example.com')
            ..add('set-cookie', 'gone=1; Expires=Wed, 21-Oct-2065 07:28:00 GMT');
          res.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv/low.m3u8\n');
        case '/c/v/low.m3u8' when cookie.contains('hdntl='):
          res.headers.add('set-cookie', 'gone=; Path=/c; Max-Age=0');
          res.write('#EXTM3U\n#EXTINF:4,\nseg.ts\n');
        case '/c/v/seg.ts' when cookie.contains('hdntl='):
          res.add(_packet(0x100, 1));
        default:
          res.statusCode = HttpStatus.forbidden;
      }
      await res.close();
    });
    final relay = await CastRelay.start(loopback, allow: loopback);
    final candidate = CastCandidate(
      url: provider.url('/c/live.m3u8'),
      contentType: _hls,
      route: CastRoute.hls,
      headers: const {'Cookie': 'own=1'},
      live: true,
    );
    final variant = _addresses(await _text(relay.serve(candidate))).single;
    final segment = _addresses(await _text(variant)).single;
    expect((await _fetch(segment)).body, _packet(0x100, 1));
    Set<String> sent(String path) =>
        (provider.asked.lastWhere((a) => a.path == path).headers.value('cookie') ?? '').split('; ').toSet();
    expect(sent('/c/live.m3u8'), {'own=1'});
    expect(sent('/c/master.m3u8'), {'own=1', 'hop=1'}, reason: 'a redirect\'s cookie goes on the next hop');
    expect(sent('/c/v/low.m3u8'), {'own=1', 'hop=1', 'hdntl=exp=1~acl=%2f*~hmac=ab', 'gone=1'});
    expect(sent('/c/v/seg.ts'), {'own=1', 'hop=1', 'hdntl=exp=1~acl=%2f*~hmac=ab'}, reason: 'gone was deleted');

    // Another candidate, or the next item, starts with none
    await _fetch(relay.serve(candidate));
    expect(sent('/c/live.m3u8'), {'own=1'});
    relay.retarget();
    await _fetch(relay.serve(candidate));
    expect(sent('/c/live.m3u8'), {'own=1'});
    expect(provider.count('/c/live.m3u8'), 3);
    await relay.close();
    await provider.close();
  });

  test('a bad token, an unknown id and other methods are turned away; the provider is not asked', () async {
    final provider = await _Provider.start((req) => _file(req, _bytes(10, 4)));
    final relay = await CastRelay.start(loopback, allow: loopback);
    final url = relay.serve(CastCandidate(url: provider.url('/a.m3u8'), contentType: _hls, route: CastRoute.hls));
    final token = Uri.parse(url).pathSegments.first;
    final root = url.substring(0, url.indexOf(token));
    for (final (bad, status) in [
      ('${root}0123456789abcdef0123456789abcdef/index.m3u8', HttpStatus.forbidden),
      ('${root}index.m3u8', HttpStatus.forbidden),
      (root, HttpStatus.forbidden),
      ('$root$token/s/zz.ts', HttpStatus.notFound),
      ('$root$token/p/zz.m3u8', HttpStatus.notFound),
      ('$root$token/v.mp4', HttpStatus.notFound),
    ]) {
      final got = await _fetch(bad);
      expect(got.status, status, reason: bad);
      expect(got.headers.value('access-control-allow-origin'), '*', reason: 'errors carry CORS too');
    }
    expect((await _fetch(url, method: 'POST')).status, HttpStatus.methodNotAllowed);
    expect(provider.asked, isEmpty);
    await relay.close();

    // Only the receiver may fetch
    final other = await CastRelay.start(loopback, allow: InternetAddress('127.0.0.2'));
    final got = await _fetch(
      other.serve(CastCandidate(url: provider.url('/a.m3u8'), contentType: _hls, route: CastRoute.hls)),
    );
    expect(got.status, HttpStatus.forbidden);
    expect(provider.asked, isEmpty);
    await other.close();
    await provider.close();
  });

  test('the provider\'s refusals reach the receiver; what is no playlist is a bad gateway', () async {
    final provider = await _Provider.start((req) async {
      if (req.uri.path == '/blocked.m3u8') {
        req.response.statusCode = HttpStatus.forbidden;
      } else {
        req.response.write('<html>Not today</html>');
      }
      await req.response.close();
    });
    final relay = await CastRelay.start(loopback, allow: loopback);
    CastCandidate hls(String path) => CastCandidate(url: provider.url(path), contentType: _hls, route: CastRoute.hls);
    expect((await _fetch(relay.serve(hls('/blocked.m3u8')))).status, HttpStatus.forbidden);
    expect((await _fetch(relay.serve(hls('/page.m3u8')))).status, HttpStatus.badGateway);
    expect(relay.upstreams, 0);
    await relay.close();
    await provider.close();
  });

  test('TS segments sent as images or octet-stream go as video/mp2t; other media as it came', () async {
    final ts = [..._packet(0, 1), ..._packet(0x100, 2)];
    final png = [0x89, 0x50, 0x4e, 0x47, ..._bytes(100, 5)];
    final provider = await _Provider.start((req) async {
      final res = req.response;
      switch (req.uri.path) {
        case '/live.m3u8':
          res.write('#EXTM3U\n#EXTINF:4,\na.jpg\n#EXTINF:4,\nb\n#EXTINF:4,\nc.png?x=1\n');
        case '/a.jpg':
          res.headers.set('content-type', 'image/jpeg');
          res.add(ts);
        case '/b':
          res.headers.set('content-type', 'application/octet-stream');
          res.add(ts);
        case '/c.png':
          res.headers.set('content-type', 'image/png');
          res.add(png);
      }
      await res.close();
    });
    final relay = await CastRelay.start(loopback, allow: loopback);
    final playlist = await _text(
      relay.serve(CastCandidate(url: provider.url('/live.m3u8'), contentType: _hls, route: CastRoute.hls, live: true)),
    );
    final [a, b, c] = _addresses(playlist);
    expect(a, endsWith('.jpg'));
    expect(c, endsWith('.png'));
    expect(Uri.parse(b).pathSegments.last, isNot(contains('.')));
    for (final (url, type, body) in [(a, 'video/mp2t', ts), (b, 'video/mp2t', ts), (c, 'image/png', png)]) {
      final got = await _fetch(url);
      expect(got.headers.contentType?.mimeType, type, reason: url);
      expect(got.body, body, reason: url);
      // A player that asks first what a segment is gets the same answer
      final head = await _fetch(url, method: 'HEAD');
      expect(head.headers.contentType?.mimeType, type, reason: 'HEAD $url');
      expect(head.body, isEmpty);
    }
    await relay.close();
    await provider.close();
  });

  group('DVB service tables', () {
    const tables = [0x10, 0x11, 0x12, 0x13, 0x14, 0x1e, 0x1f];
    // The PAT and PMT, then video, audio and tables interleaved
    final head = [
      ..._pat([0x1000]),
      ..._pmt(0x1000, [0x100, 0x101]),
    ];
    final pids = [0x11, 0x12, 0x100, 0x10, 0x101, 0x14, 0x1e, 0x100, 0x1f, 0x13, 0x15, 0x100];
    final stream = [...head, for (final (i, pid) in pids.indexed) ..._packet(pid, i)];
    final kept = [
      ...head,
      for (final (i, pid) in pids.indexed)
        if (!tables.contains(pid)) ..._packet(pid, i),
    ];

    test('dropped whatever the chunks they come in', () {
      for (final size in [1, 2, 7, 100, 187, 188, 189, 375, 376, 1000, stream.length]) {
        expect(_filtered(stream, size), kept, reason: 'chunks of $size');
      }
    });

    test('kept where the PAT or a PMT names them: a PMT, video or audio on those PIDs', () {
      // As ATSC captures have them: video on 0x11, audio on 0x14, the PMT on 0x10 or elsewhere
      final video = _packet(0x11, 1), audio = _packet(0x14, 2), eit = _packet(0x12, 3);
      for (final pmt in [0x10, 0x1000]) {
        final tables = [
          ..._pat([pmt]),
          ..._pmt(pmt, [0x11, 0x14]),
        ];
        expect(_filtered([...tables, ...video, ...audio, ...eit, ...video], 100), [
          ...tables,
          ...video,
          ...audio,
          ...video,
        ], reason: 'the PMT on $pmt');
      }

      // A PMT long enough for two packets names 0x13 last
      final long = _pmt(0x1000, [for (var i = 0; i < 40; i++) 0x200 + i, 0x13]);
      expect(long, hasLength(376));
      final pat = _pat([0x1000]);
      expect(_filtered([...pat, ...long, ..._packet(0x13, 4), ..._packet(0x12, 5)], 100), [
        ...pat,
        ...long,
        ..._packet(0x13, 4),
      ]);

      // The NIT the PAT names under program 0 goes
      final nit = _table(0, 0x00, [0, 0, 0xe0, 0x10, 0, 1, 0xf0, 0x00]);
      final pmt = _pmt(0x1000, [0x100]);
      expect(_filtered([...nit, ...pmt, ..._packet(0x10, 6)]), [...nit, ...pmt]);
    });

    test('nothing goes before the PAT and every PMT it names have been read', () {
      final pat = _pat([0x1000, 0x1001]), pmt1 = _pmt(0x1000, [0x100]), pmt2 = _pmt(0x1001, [0x200]);
      final sdt = _packet(0x11, 1);
      expect(_filtered([...sdt, ...pat, ...sdt, ...pmt1, ...sdt, ...pmt2, ...sdt, ..._packet(0x100, 2)]), [
        ...sdt,
        ...pat,
        ...sdt,
        ...pmt1,
        ...sdt,
        ...pmt2,
        ..._packet(0x100, 2),
      ]);
    });

    test('a stream that loses sync goes on as it is; a packet cut short at the end too', () {
      final filter = TsTableFilter();
      final garbage = _bytes(300, 6).map((b) => b == 0x47 ? 0 : b).toList();
      final out = [
        ...filter.add([...head, ..._packet(0x11, 1), ..._packet(0x100, 2), ...garbage]),
        ...filter.add(_packet(0x11, 3)),
        ...filter.close(),
      ];
      expect(out, [...head, ..._packet(0x100, 2), ...garbage, ..._packet(0x11, 3)]);

      final short = TsTableFilter();
      expect(
        [
          ...short.add([..._packet(0x100, 1), ..._packet(0x101, 2).sublist(0, 50)]),
          ...short.close(),
        ],
        [..._packet(0x100, 1), ..._packet(0x101, 2).sublist(0, 50)],
      );
    });

    test('stripped from segments as they stream, with no length; a range as it is', () async {
      final provider = await _Provider.start((req) async {
        final res = req.response;
        if (req.uri.path == '/live.m3u8') {
          res.write('#EXTM3U\n#EXTINF:4,\nseg.ts\n');
          return res.close();
        }
        if (req.headers.value('range') != null) return _file(req, stream, type: 'video/mp2t');
        res
          ..headers.set('content-type', 'video/mp2t')
          ..contentLength = stream.length;
        for (var i = 0; i < stream.length; i += 101) {
          res.add(stream.sublist(i, (i + 101).clamp(0, stream.length)));
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        await res.close();
      });
      final relay = await CastRelay.start(loopback, allow: loopback);
      final playlist = await _text(
        relay.serve(
          CastCandidate(url: provider.url('/live.m3u8'), contentType: _hls, route: CastRoute.hls, live: true),
        ),
      );
      final segment = _addresses(playlist).single;
      final got = await _fetch(segment);
      expect(got.status, 200);
      expect(got.headers.contentLength, -1);
      expect(got.body, kept);

      final range = await _fetch(segment, headers: {'Range': 'bytes=188-'});
      expect(range.status, HttpStatus.partialContent);
      expect(range.body, stream.sublist(188), reason: 'its offsets must stay true');
      await relay.close();
      await provider.close();
    });
  });

  test('retarget: the old token stops working and its provider connections end, mid-body or before an '
      'answer', () async {
    final endless = await _Endless.start('video/mp4'); // a file that never ends
    final waiting = Completer<void>();
    final provider = await _Provider.start((req) async => waiting.complete()); // never answers
    final relay = await CastRelay.start(loopback, allow: loopback);
    final file = relay.serve(
      CastCandidate(url: endless.url('/movie.mp4'), contentType: 'video/mp4', route: CastRoute.progressive),
    );
    final playlist = relay.serve(
      CastCandidate(url: provider.url('/slow.m3u8'), contentType: _hls, route: CastRoute.hls),
    );

    final client = HttpClient();
    final res = await (await client.getUrl(Uri.parse(file))).close();
    expect(res.statusCode, 200);
    final ended = Completer<void>();
    var got = 0;
    void end() => ended.isCompleted ? null : ended.complete();
    res.listen((chunk) => got += chunk.length, onError: (Object _) => end(), onDone: end);
    final pending = _fetch(playlist);
    await waiting.future.timeout(const Duration(seconds: 5));
    while (got < 64 * 1024) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(relay.upstreams, 2);

    relay.retarget();
    await endless.cut.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('the provider was not let go'));
    await ended.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('the receiver was not let go'));
    expect((await pending.timeout(const Duration(seconds: 5))).status, HttpStatus.forbidden);
    expect(relay.upstreams, 0);
    expect((await _fetch(file)).status, HttpStatus.forbidden);
    expect(endless.asked, 1);

    // The next item goes on
    final next = relay.serve(
      CastCandidate(url: provider.url('/next.mp4'), contentType: 'video/mp4', route: CastRoute.direct),
    );
    expect(next, provider.url('/next.mp4'), reason: 'a direct candidate needs no relay');
    client.close(force: true);
    await relay.close();
    await provider.close();
    await endless.close();
  });
}
