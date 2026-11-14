// Recording an HLS channel: the pieces the player fetches, fetched again and written one after
// another into a file, each once and in order.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/player/background_recorder.dart';
import 'package:iptv_player/player/hls_recorder.dart';

/// A provider on this machine; [answer] serves each request.
Future<(HttpServer, Uri)> _provider(Future<void> Function(HttpRequest) answer) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(answer);
  return (server, Uri.parse('http://127.0.0.1:${server.port}'));
}

/// Piece [n]'s bytes: each its own, so the file shows which went in, and in what order.
List<int> _seg(int n) => [for (var i = 0; i < 1500 + n; i++) (i * 13 + n * 7) % 256];

List<int> _segs(Iterable<int> ns) => [for (final n in ns) ..._seg(n)];

/// A media playlist of pieces [first] to [first] + [count] - 1, each a second long; [before] puts
/// a tag before some.
String _media(int first, int count, {bool ended = false, String head = '', Map<int, String> before = const {}}) {
  final b = StringBuffer('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:$first\n$head');
  for (var n = first; n < first + count; n++) {
    if (before[n] case final tag?) b.writeln(tag);
    b
      ..writeln('#EXTINF:1.000,')
      ..writeln('seg$n.ts');
  }
  if (ended) b.writeln('#EXT-X-ENDLIST');
  return '$b';
}

Future<void> _playlist(HttpRequest req, String text) async {
  req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
  req.response.write(text);
  await req.response.close();
}

/// Serves piece `seg<n>.ts` if [req] asks for one; whether it did.
Future<bool> _piece(HttpRequest req, {Set<int> missing = const {}}) async {
  final m = RegExp(r'seg(\d+)\.ts$').firstMatch(req.uri.path);
  if (m == null) return false;
  final n = int.parse(m[1]!);
  if (missing.contains(n)) {
    req.response.statusCode = HttpStatus.notFound;
  } else {
    req.response.headers.contentType = ContentType('video', 'mp2t');
    req.response.add(_seg(n));
  }
  await req.response.close();
  return true;
}

Future<void> _until(bool Function() ok, {String? reason}) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ok(), isTrue, reason: reason);
}

Matcher _refused(HlsProblem problem) => throwsA(isA<HlsRefused>().having((e) => e.problem, 'problem', problem));

void main() {
  HttpOverrides.global = null; // real sockets
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('hls');
    HlsRecorder.pace = 0.02; // a second's wait is 20 ms
  });
  tearDown(() {
    HlsRecorder.pace = 1;
    dir.deleteSync(recursive: true);
  });

  group('reading playlists', () {
    final base = Uri.parse('http://p.example/live/u/p/1.m3u8');

    test('attributes, quoted ones with commas', () {
      expect(hlsAttributes('BANDWIDTH=1701776,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud",RESOLUTION=1280x720'), {
        'BANDWIDTH': '1701776',
        'CODECS': 'avc1.64001f,mp4a.40.2',
        'AUDIO': 'aud',
        'RESOLUTION': '1280x720',
      });
    });

    test('a master playlist: its variants, and which is recorded', () {
      final master = HlsMaster.parse('''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="apart",NAME="es",DEFAULT=YES,URI="es.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="apart",NAME="en",URI="en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="in",NAME="es",DEFAULT=YES
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="in",NAME="en",URI="en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2"
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,AUDIO="in"
http://cdn.example/hi.m3u8
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="iframes.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=90000000
uhd.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1200000,AUDIO="apart"
video.m3u8
''', base)!;
      final v = master.variants;
      expect(
        [for (final x in v) x.uri.toString()],
        [
          'http://p.example/live/u/p/low/index.m3u8',
          'http://cdn.example/hi.m3u8',
          'http://p.example/live/u/p/uhd.m3u8',
          'http://p.example/live/u/p/video.m3u8',
        ],
      );
      expect([for (final x in v) x.bandwidth], [800000, 2400000, 90000000, 1200000]);
      expect([for (final x in v) x.separateAudio], [false, false, false, true], reason: 'one sound is in the variant');
      expect(HlsMaster.pick(v), v[1], reason: 'the best one under the cap');
      expect(HlsMaster.pick(v, bandwidth: 800000), v[0], reason: 'the one the player plays');
      expect(HlsMaster.pick(v, bandwidth: 90000000), v[2]);
      expect(HlsMaster.pick(v, bandwidth: 5), v[1], reason: 'not one of them');
      expect(
        HlsMaster.pick([HlsVariant(base.resolve('a')), HlsVariant(base.resolve('b'))]).uri.path,
        '/live/u/p/a',
        reason: 'none says its bandwidth: the first',
      );
      expect(HlsMaster.parse(_media(0, 3), base), isNull, reason: 'a media playlist');
    });

    test('a media playlist: numbers, lengths, keys, byte ranges, a discontinuity passed over', () {
      final p = HlsMedia.parse('''
\uFEFF#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:41
#EXTINF:5.96,
a.ts
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=AES-128,URI="https://k.example/key?id=1",IV=0x0102
#EXTINF:6.0,title
/abs/b.ts
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x",KEYFORMAT="com.apple.streamingkeydelivery"
#EXT-X-KEY:METHOD=AES-128,URI="k2"
#EXT-X-BYTERANGE:100@0
#EXTINF:4,
all.ts
#EXT-X-BYTERANGE:50
#EXTINF:4,
all.ts
#EXT-X-KEY:METHOD=NONE
#EXTINF:4,
c.ts
''', base);
      expect(p.targetDuration, 6);
      expect(p.timed, isTrue);
      expect(p.ended, isFalse);
      expect(p.fragmented, isFalse);
      final s = p.segments;
      expect([for (final x in s) x.sequence], [41, 42, 43, 44, 45]);
      expect(s[0].uri.toString(), 'http://p.example/live/u/p/a.ts');
      expect(s[1].uri.toString(), 'http://p.example/abs/b.ts');
      expect([for (final x in s) x.duration], [5.96, 6.0, 4, 4, 4]);
      expect(s[0].key, isNull);
      expect(s[1].key!.plain, isTrue);
      expect(s[1].key!.uri.toString(), 'https://k.example/key?id=1');
      expect(s[1].key!.ivFor(42), [...List.filled(14, 0), 1, 2], reason: 'its own IV');
      expect(s[2].key!.uri.toString(), 'http://p.example/live/u/p/k2', reason: 'the key format decrypted here');
      expect(s[2].key!.ivFor(43), [...List.filled(15, 0), 43], reason: 'its number');
      expect(s[2].key!.ivFor(0x0102), [...List.filled(14, 0), 1, 2]);
      expect([s[2].range, s[3].range, s[4].range], [(0, 100), (100, 50), null]);
      expect(s[4].key, isNull);

      final fmp4 = HlsMedia.parse('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4,\na.m4s\n#EXT-X-ENDLIST\n', base);
      expect(fmp4.fragmented, isTrue);
      expect(fmp4.ended, isTrue);
      expect(fmp4.timed, isFalse, reason: 'no target duration');
      final plain = HlsMedia.parse('#EXTM3U\n#EXTINF:-1,Channel\nhttp://h.example/live/1.ts\n', base);
      expect(plain.timed, isFalse, reason: 'a plain M3U list of one stream');
      final drm = HlsMedia.parse('#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="k"\n#EXTINF:4,\na.ts\n', base);
      expect(drm.segments.single.key!.plain, isFalse);
      final other = HlsMedia.parse(
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k",KEYFORMAT="urn:x"\n#EXTINF:4,\na.ts\n',
        base,
      );
      expect(other.segments.single.key!.plain, isFalse);
    });

    test('where a recording starts: near a live end, or where the player is in a complete one', () {
      expect(HlsMedia.parse(_media(10, 6), base).startIndex(), 3);
      expect(HlsMedia.parse(_media(10, 2), base).startIndex(), 0);
      expect(HlsMedia.parse(_media(10, 0), base).startIndex(), 0);
      final vod = HlsMedia.parse(_media(0, 5, ended: true), base);
      expect(vod.startIndex(), 0);
      expect(vod.startIndex(position: const Duration(milliseconds: 2500)), 2);
      expect(vod.startIndex(position: const Duration(minutes: 9)), 4);
      expect(
        HlsMedia.parse(_media(10, 6), base).startIndex(position: const Duration(seconds: 1)),
        3,
        reason: 'live: the position does not count',
      );
    });
  });

  test('a live channel is followed through a redirect: each piece once, in order, from near its end, asked for '
      'with its headers', () async {
    final paths = <String>[];
    final agents = <String?>{}, referers = <String?>{};
    var polls = 0;
    final (provider, root) = await _provider((req) async {
      paths.add(req.uri.path);
      agents.add(req.headers.value('user-agent'));
      referers.add(req.headers.value('referer'));
      switch (req.uri.path) {
        case '/live/u/p/1.ts':
          return req.response.redirect(Uri.parse('/edge/t0k3n/master.m3u8'));
        case '/edge/t0k3n/master.m3u8':
          return _playlist(req, '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=500000
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000
hi/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=90000000
uhd/index.m3u8
''');
        case '/edge/t0k3n/hi/index.m3u8':
          final k = polls++;
          return _playlist(req, _media(k, 5)); // one more piece each time
        default:
          if (!await _piece(req)) req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });
    final file = File('${dir.path}/a.ts');
    // No User-Agent from the playlist (an Xtream one gives none): as the player, not as Dart
    final rec = await HlsRecorder.start('$root/live/u/p/1.ts', file, headers: {'Referer': 'http://lists.example/'});
    await _until(() => rec.written >= 6);
    await rec.stop();
    final got = file.readAsBytesSync();
    final n = rec.written;
    expect(got, _segs([for (var i = 2; i < 2 + n; i++) i]), reason: 'from three pieces before the end, none twice');
    expect(rec.missed, 0);
    expect(paths.where((p) => p == '/live/u/p/1.ts'), hasLength(1), reason: 'the address it was sent on to is kept');
    expect(paths.where((p) => p.endsWith('master.m3u8')), hasLength(1));
    expect(paths.where((p) => p == '/edge/t0k3n/hi/index.m3u8').length, greaterThanOrEqualTo(2));
    expect(paths.where((p) => p.contains('low/') || p.contains('uhd/')), isEmpty, reason: 'the best one under the cap');
    final pieces = paths.where((p) => p.startsWith('/edge/t0k3n/hi/seg')).toList();
    expect(pieces.toSet(), hasLength(pieces.length), reason: 'each piece fetched once');
    expect(agents, {'libmpv'});
    expect(referers, {'http://lists.example/'});
    await provider.close(force: true);
  });

  test(
    'a discontinuity goes through; what went by in a stall is a gap; a piece not there is lost, the rest kept',
    () async {
      var polls = 0;
      final (provider, root) = await _provider((req) async {
        if (req.uri.path == '/hls/index.m3u8') {
          switch (polls++) {
            case 0:
              return _playlist(req, _media(0, 4, before: {2: '#EXT-X-DISCONTINUITY'}));
            case 1:
              return _playlist(req, _media(1, 4)); // 4 is not there
            case 2:
              req.response.statusCode = HttpStatus.serviceUnavailable; // a stall
              return req.response.close();
            default:
              return _playlist(req, _media(10, 4)); // and on much further
          }
        }
        if (!await _piece(req, missing: {4})) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        }
      });
      final file = File('${dir.path}/b.ts');
      final rec = await HlsRecorder.start('$root/hls/index.m3u8', file);
      await _until(() => rec.written >= 7 && polls >= 5);
      await rec.stop();
      expect(file.readAsBytesSync(), _segs([1, 2, 3, 10, 11, 12, 13]));
      expect(rec.missed, 6, reason: 'piece 4, not had while listed, and 5 to 9, gone by');
      await provider.close(force: true);
    },
  );

  test('a stream that starts over, numbered from the start again, is followed from its new end', () async {
    var polls = 0;
    final (provider, root) = await _provider((req) async {
      if (req.uri.path == '/hls/index.m3u8') return _playlist(req, polls++ == 0 ? _media(100, 5) : _media(0, 5));
      await _piece(req);
    });
    final file = File('${dir.path}/c.ts');
    final rec = await HlsRecorder.start('$root/hls/index.m3u8', file);
    await _until(() => rec.written >= 6 && polls >= 3);
    await rec.stop();
    expect(file.readAsBytesSync(), _segs([102, 103, 104, 2, 3, 4]));
    expect(rec.missed, 0);
    await provider.close(force: true);
  });

  test('AES-128 pieces are decrypted, with their own IV or their number; a complete playlist from where the player '
      'is', () async {
    final key = List<int>.generate(16, (i) => i * 11 + 3);
    final aes = AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty);
    final ownIv = List<int>.generate(16, (i) => 0xa0 + i);
    final secret = <int, List<int>>{};
    for (var n = 0; n < 4; n++) {
      final box = await aes.encrypt(
        _seg(n),
        secretKey: SecretKey(key),
        nonce: n.isEven ? ownIv : HlsKey('AES-128').ivFor(n),
      );
      secret[n] = box.cipherText;
    }
    var keys = 0, reads = 0;
    final hex = ownIv.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final text = _media(
      0,
      4,
      ended: true,
      before: {
        0: '#EXT-X-KEY:METHOD=AES-128,URI="/keys/1",IV=0x$hex',
        1: '#EXT-X-KEY:METHOD=AES-128,URI="/keys/1"',
        2: '#EXT-X-KEY:METHOD=AES-128,URI="/keys/1",IV=0x$hex',
        3: '#EXT-X-KEY:METHOD=AES-128,URI="/keys/1"',
      },
    );
    final (provider, root) = await _provider((req) async {
      final m = RegExp(r'seg(\d+)\.ts$').firstMatch(req.uri.path);
      if (req.uri.path == '/vod/index.m3u8') {
        reads++;
        return _playlist(req, text);
      }
      if (req.uri.path == '/keys/1') {
        keys++;
        req.response.add(key);
      } else if (m != null) {
        req.response.add(secret[int.parse(m[1]!)]!);
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });
    final file = File('${dir.path}/d.ts');
    var ended = 0;
    final rec = await HlsRecorder.start(
      '$root/vod/index.m3u8',
      file,
      position: const Duration(milliseconds: 1200),
      onEnded: () => ended++,
    );
    await _until(() => ended > 0, reason: 'written to its end');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await rec.stop();
    expect(file.readAsBytesSync(), _segs([1, 2, 3]), reason: 'from the second, where the player is');
    expect(keys, 1, reason: 'the key is asked for once');
    expect(ended, 1);
    expect(reads, 1, reason: 'complete: not read again');
    await provider.close(force: true);
  });

  test('refused, and why: other encryption, fMP4, sound apart, a provider that says no, a first piece it does not '
      'give, not HLS', () async {
    var endless = false;
    final (provider, root) = await _provider((req) async {
      switch (req.uri.path) {
        case '/drm.m3u8':
          return _playlist(req, _media(0, 4, head: '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://k"\n'));
        case '/keyformat.m3u8':
          return _playlist(req, _media(0, 4, head: '#EXT-X-KEY:METHOD=AES-128,URI="k",KEYFORMAT="urn:drm"\n'));
        case '/fmp4.m3u8':
          return _playlist(req, '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4,\na.m4s\n');
        case '/alt.m3u8':
          return _playlist(req, '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="es",DEFAULT=YES,URI="es.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="a"
video.m3u8
''');
        case '/nopiece.m3u8':
          return _playlist(req, _media(0, 4)); // its pieces: forbidden
        case '/plain.m3u8':
          // A plain M3U list named as HLS, its one entry an endless stream
          return _playlist(req, '#EXTM3U\n#EXTINF:-1,Channel\nlive/1.ts\n');
        case '/endless.m3u8':
          return _playlist(req, '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nfast.ts\n');
        case '/fast.ts':
          // A piece with no end, sent as fast as it is read, until it hangs up
          var gone = false;
          unawaited(req.response.done.then((_) {}, onError: (Object _) {}).whenComplete(() => gone = true));
          final chunk = Uint8List(1 << 20)..fillRange(0, 1 << 20, 0x47);
          try {
            while (!endless && !gone) {
              req.response.add(chunk);
              await req.response.flush();
              await Future<void>.delayed(Duration.zero); // a flush to a closed one is done at once
            }
          } on Object {
            // It hung up
          }
          return;
        case '/live/1.ts':
          // An endless MPEG-TS stream, not a playlist: given up at once
          req.response.headers.contentType = ContentType('video', 'mp2t');
          try {
            while (!endless) {
              req.response.add(List.filled(188 * 64, 0x47));
              await req.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          } on Object {
            return; // it hung up
          }
        default:
          req.response.statusCode = HttpStatus.forbidden;
      }
      await req.response.close();
    });
    final file = File('${dir.path}/e.ts');
    Future<HlsRecorder> start(String path) => HlsRecorder.start('$root$path', file);
    await expectLater(start('/drm.m3u8'), _refused(HlsProblem.encrypted));
    await expectLater(start('/keyformat.m3u8'), _refused(HlsProblem.encrypted));
    await expectLater(start('/fmp4.m3u8'), _refused(HlsProblem.fragmented));
    await expectLater(start('/alt.m3u8'), _refused(HlsProblem.separateAudio));
    await expectLater(start('/nope.m3u8'), _refused(HlsProblem.unreachable));
    await expectLater(start('/live/1.ts').timeout(const Duration(seconds: 5)), _refused(HlsProblem.unreachable));
    await expectLater(start('/nopiece.m3u8'), _refused(HlsProblem.unreachable));
    await expectLater(start('/plain.m3u8').timeout(const Duration(seconds: 5)), _refused(HlsProblem.unreachable));
    await expectLater(start('/endless.m3u8').timeout(const Duration(seconds: 10)), _refused(HlsProblem.unreachable));
    endless = true;
    expect(file.existsSync(), isFalse, reason: 'no file for a refusal');
    await provider.close(force: true);
  });

  test('a channel that turns to fMP4 midway ends the recording, said once; what came is kept', () async {
    var polls = 0;
    final (provider, root) = await _provider((req) async {
      if (req.uri.path == '/hls/index.m3u8') {
        return _playlist(req, polls++ == 0 ? _media(0, 3) : _media(1, 3, head: '#EXT-X-MAP:URI="init.mp4"\n'));
      }
      await _piece(req);
    });
    final said = <HlsProblem>[];
    final file = File('${dir.path}/f.ts');
    final rec = await HlsRecorder.start('$root/hls/index.m3u8', file, onUnusable: said.add);
    await _until(() => said.isNotEmpty);
    await rec.stop().timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(said, [HlsProblem.fragmented]);
    expect(file.readAsBytesSync(), _segs([0, 1, 2]));
    final at = polls;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(polls, at, reason: 'it is not read any more');
    await provider.close(force: true);
  });

  test('a file that cannot be written ends the recording, said once, and stopping does not wait', () async {
    var polls = 0;
    final (provider, root) = await _provider((req) async {
      if (req.uri.path == '/hls/index.m3u8') return _playlist(req, _media(polls++, 5));
      await _piece(req);
    });
    final errors = <Object>[];
    final rec = await HlsRecorder.start(
      '$root/hls/index.m3u8',
      File('${dir.path}/missing/g.ts'), // its folder is not there
      onWriteError: errors.add,
    );
    await _until(() => errors.isNotEmpty);
    await rec.stop().timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(errors, hasLength(1));
    final at = polls;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(polls, at, reason: 'nothing more is fetched');
    await provider.close(force: true);
  });

  test('stopping lets go of a piece still coming: the file has the whole ones', () async {
    final gate = Completer<void>();
    var asked = false;
    final (provider, root) = await _provider((req) async {
      if (req.uri.path == '/hls/index.m3u8') return _playlist(req, _media(0, 4));
      if (req.uri.path.endsWith('seg3.ts')) {
        asked = true;
        req.response.add(_seg(3).sublist(0, 500)); // half of it, then nothing for a while
        await req.response.flush();
        await gate.future;
        try {
          await req.response.close();
        } on Object {
          // It hung up
        }
        return;
      }
      await _piece(req);
    });
    final file = File('${dir.path}/h.ts');
    final rec = await HlsRecorder.start('$root/hls/index.m3u8', file);
    await _until(() => rec.written == 2 && asked);
    await rec.stop().timeout(const Duration(seconds: 5));
    expect(file.readAsBytesSync(), _segs([1, 2]));
    expect(rec.missed, 0, reason: 'let go, not lost');
    gate.complete();
    await provider.close(force: true);
  });

  test('a piece not there yet is tried again while it is listed, before the ones after it; one that never comes '
      'is given up after a few reads', () async {
    var polls = 0, early = 0;
    final (provider, root) = await _provider((req) async {
      if (req.uri.path == '/hls/index.m3u8') return _playlist(req, _media(0, 6 + polls++)); // an event's: it grows
      // Listed a moment before the edge has it: the first read's three tries, and one more
      if (req.uri.path.endsWith('/seg4.ts') && ++early <= 4) {
        req.response.statusCode = HttpStatus.notFound;
        return req.response.close();
      }
      await _piece(req, missing: {7});
    });
    final file = File('${dir.path}/i.ts');
    final rec = await HlsRecorder.start('$root/hls/index.m3u8', file);
    await _until(() => rec.written >= 8);
    await rec.stop();
    final n = rec.written;
    expect(file.readAsBytesSync(), _segs([3, 4, 5, 6, for (var i = 8; i < 4 + n; i++) i]), reason: 'in order');
    expect(rec.missed, 1, reason: 'piece 7, never there');
    await provider.close(force: true);
  });

  test('pieces that stop coming end the recording, said once; what came is kept', () async {
    var polls = 0;
    final (provider, root) = await _provider((req) async {
      if (req.uri.path == '/hls/index.m3u8') return _playlist(req, _media(polls++, 5));
      final m = RegExp(r'seg(\d+)\.ts$').firstMatch(req.uri.path);
      if (m != null && int.parse(m[1]!) >= 5) {
        req.response.statusCode = HttpStatus.forbidden; // this session is not let in any more
        return req.response.close();
      }
      await _piece(req);
    });
    final said = <HlsProblem>[];
    final file = File('${dir.path}/j.ts');
    final rec = await HlsRecorder.start('$root/hls/index.m3u8', file, onUnusable: said.add);
    await _until(() => said.isNotEmpty);
    await rec.stop().timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(said, [HlsProblem.unreachable]);
    expect(file.readAsBytesSync(), _segs([2, 3, 4]));
    final at = polls;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(polls, at, reason: 'it is not read any more');
    await provider.close(force: true);
  });

  test('an event that ends is written to its end, and that is said', () async {
    var polls = 0;
    final (provider, root) = await _provider((req) async {
      if (req.uri.path == '/hls/index.m3u8') {
        return _playlist(req, polls++ == 0 ? _media(0, 4) : _media(0, 6, ended: true));
      }
      await _piece(req);
    });
    var ended = 0;
    final file = File('${dir.path}/k.ts');
    final rec = await HlsRecorder.start('$root/hls/index.m3u8', file, onEnded: () => ended++);
    await _until(() => ended > 0);
    await rec.stop().timeout(const Duration(seconds: 5));
    expect(file.readAsBytesSync(), _segs([1, 2, 3, 4, 5]));
    final at = polls;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(polls, at, reason: 'it is not read any more');
    expect(ended, 1);
    await provider.close(force: true);
  });

  test('cookies the provider sets, on a redirect or with the playlist, go back with the pieces', () async {
    final sent = <String>[];
    Set<String> cookies(HttpRequest req) => {
      for (final c in (req.headers.value('cookie') ?? '').split(';'))
        if (c.trim().isNotEmpty) c.trim(),
    };
    final (provider, root) = await _provider((req) async {
      final have = cookies(req);
      switch (req.uri.path) {
        case '/live/1.ts':
          req.response.headers.add('set-cookie', 'gate=open; Path=/; HttpOnly');
          return req.response.redirect(Uri.parse('/hls/index.m3u8'));
        case '/hls/index.m3u8' when have.contains('gate=open'):
          req.response.headers
            ..add('set-cookie', 'session=s1; Path=/hls')
            ..add('set-cookie', 'elsewhere=1; Domain=other.example; Path=/'); // not this host's to set
          return _playlist(req, _media(0, 5));
        default:
          if (req.uri.path.startsWith('/hls/seg')) {
            sent.add(req.headers.value('cookie') ?? '');
            if (have.containsAll({'mine=1', 'gate=open', 'session=s1'}) && await _piece(req)) return;
          }
          req.response.statusCode = HttpStatus.forbidden;
      }
      await req.response.close();
    });
    final file = File('${dir.path}/l.ts');
    final rec = await HlsRecorder.start('$root/live/1.ts', file, headers: {'Cookie': 'mine=1'});
    await _until(() => rec.written >= 3);
    await rec.stop();
    expect(file.readAsBytesSync(), _segs([2, 3, 4]));
    expect(sent, everyElement(isNot(contains('elsewhere'))));
    await provider.close(force: true);
  });

  test("a media playlist that fails is read again where it is, then from the channel's address; another host's, "
      'numbered its own way, is followed from its live end', () async {
    var asked = 0, readsA = 0, readsB = 0;
    late final Uri a, b;
    final (channel, root) = await _provider((req) => req.response.redirect(asked++ == 0 ? a : b));
    final (serverA, rootA) = await _provider((req) async {
      if (req.uri.path == '/a/index.m3u8') {
        if (readsA++ < 2) return _playlist(req, _media(99 + readsA, 5));
        req.response.statusCode = HttpStatus.serviceUnavailable; // gone, for good
        return req.response.close();
      }
      await _piece(req);
    });
    // Another server, a little behind in numbers of its own: its pieces are other bytes
    final (serverB, rootB) = await _provider((req) async {
      if (req.uri.path == '/b/index.m3u8') return _playlist(req, _media(100 + readsB++, 5));
      final m = RegExp(r'seg(\d+)\.ts$').firstMatch(req.uri.path)!;
      req.response.add(_seg(int.parse(m[1]!) + 500));
      await req.response.close();
    });
    a = rootA.resolve('/a/index.m3u8');
    b = rootB.resolve('/b/index.m3u8');
    final file = File('${dir.path}/m.ts');
    final rec = await HlsRecorder.start('$root/live/1.m3u8', file);
    await _until(() => rec.written >= 7);
    await rec.stop();
    final n = rec.written;
    expect(file.readAsBytesSync(), [
      ..._segs([102, 103, 104, 105]),
      ..._segs([for (var i = 0; i < n - 4; i++) 602 + i]),
    ]);
    expect(rec.missed, 0, reason: 'no gap from numbers of another server');
    expect(readsA, 5, reason: 'two read, then three tries before going to the channel again');
    expect(asked, 2, reason: 'the channel asked for once more, not on every failure');
    await Future.wait([
      for (final s in [channel, serverA, serverB]) s.close(force: true),
    ]);
  });

  test('numbered anew far ahead: followed from its live end, not counted as a gap', () async {
    var polls = 0;
    final (provider, root) = await _provider((req) async {
      if (req.uri.path == '/hls/index.m3u8') {
        final k = polls++;
        return _playlist(req, k == 0 ? _media(0, 5) : _media(5000 + k, 5));
      }
      await _piece(req);
    });
    final file = File('${dir.path}/n.ts');
    final rec = await HlsRecorder.start('$root/hls/index.m3u8', file);
    await _until(() => rec.written >= 6);
    await rec.stop();
    final n = rec.written;
    expect(file.readAsBytesSync(), _segs([2, 3, 4, for (var i = 0; i < n - 3; i++) 5003 + i]));
    expect(rec.missed, 0);
    await provider.close(force: true);
  });

  test("a piece's number as its IV, big-endian", () {
    expect(HlsKey('AES-128').ivFor(0x0102030405060708), [...List.filled(8, 0), 1, 2, 3, 4, 5, 6, 7, 8]);
    expect(Uint8List.fromList(HlsKey('AES-128').ivFor(0)), Uint8List(16));
  });

  test('for a recording scheduled from the guide: a playlist that ends, all of it, then done', () async {
    final (server, base) = await _provider((req) async {
      if (await _piece(req)) return;
      await _playlist(req, _media(0, 3, ended: true));
    });
    final file = File('${dir.path}/scheduled.ts');
    final rec = await startHlsChannelRecorder('$base/live.m3u8', file);
    expect(await rec.done.timeout(const Duration(seconds: 10)), RecorderEnd.finished, reason: 'not "stopped by hand"');
    expect(file.readAsBytesSync(), _segs([0, 1, 2]));
    expect(rec.bytes, _segs([0, 1, 2]).length);
    await server.close(force: true);
  });
}
