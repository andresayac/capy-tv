// Recording a channel through the relay: the player and the file get the same bytes, from one
// connection to the provider.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/player/background_recorder.dart';
import 'package:iptv_player/player/record_relay.dart';

/// A provider on this machine; [answer] serves each request.
Future<(HttpServer, Uri)> _provider(Future<void> Function(HttpRequest) answer) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(answer);
  return (server, Uri.parse('http://127.0.0.1:${server.port}/live/user/pass/1.ts'));
}

/// What a player reading [url] gets: the status, and the bytes as they come.
Future<(int, List<int>)> _read(String url, {void Function(int bytes)? onBytes}) async {
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    final got = <int>[];
    await for (final chunk in res) {
      got.addAll(chunk);
      onBytes?.call(got.length);
    }
    return (res.statusCode, got);
  } finally {
    client.close(force: true);
  }
}

List<int> _bytes(int n, int seed) => [for (var i = 0; i < n; i++) (i * 7 + seed) % 256];

void main() {
  HttpOverrides.global = null; // real sockets
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('relay'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the player and the file get what the provider sends, asked for with its headers', () async {
    final sent = _bytes(300 * 1024, 1);
    final agents = <String?>[];
    final (provider, url) = await _provider((req) async {
      agents.add(req.headers.value('user-agent'));
      req.response.headers.contentType = ContentType('video', 'mp2t');
      for (var i = 0; i < sent.length; i += 16 * 1024) {
        req.response.add(sent.sublist(i, (i + 16 * 1024).clamp(0, sent.length)));
        await req.response.flush();
      }
      await req.response.close();
    });
    final relay = await RecordRelay.start(url.toString(), headers: {'User-Agent': 'libmpv'});
    final file = File('${dir.path}/a.ts');
    await relay.recordTo(file);
    final (status, got) = await _read(relay.url);
    await relay.recordTo(null);
    expect(status, 200);
    expect(got, sent);
    expect(file.readAsBytesSync(), sent);
    expect(agents, ['libmpv']);
    await relay.close();
    await provider.close(force: true);
  });

  test('stopped halfway, the file has what came until then; the player gets it all', () async {
    final before = _bytes(64 * 1024, 2), after = _bytes(64 * 1024, 3);
    final gate = Completer<void>();
    final (provider, url) = await _provider((req) async {
      req.response.add(before);
      await req.response.flush();
      await gate.future;
      req.response.add(after);
      await req.response.close();
    });
    final relay = await RecordRelay.start(url.toString());
    final file = File('${dir.path}/b.ts');
    await relay.recordTo(file);
    final (_, got) = await _read(
      relay.url,
      onBytes: (n) async {
        if (n == before.length) {
          await relay.recordTo(null);
          gate.complete();
        }
      },
    );
    expect(got, [...before, ...after]);
    expect(file.readAsBytesSync(), before);
    await relay.close();
    await provider.close(force: true);
  });

  test('the player connecting again (after a drop) goes on in the same file', () async {
    var n = 0;
    final (provider, url) = await _provider((req) async {
      req.response.add(_bytes(1000, n++));
      await req.response.close();
    });
    final relay = await RecordRelay.start(url.toString());
    final file = File('${dir.path}/c.ts');
    await relay.recordTo(file);
    await _read(relay.url);
    await _read(relay.url);
    await relay.recordTo(null);
    expect(file.readAsBytesSync(), [..._bytes(1000, 0), ..._bytes(1000, 1)]);
    await relay.close();
    await provider.close(force: true);
  });

  test('HLS is said, by its type or by what it is; a refusal too, and reaches the player', () async {
    for (final (type, body) in [
      (ContentType('application', 'vnd.apple.mpegurl'), '#EXTM3U\n#EXT-X-VERSION:3\n'),
      (ContentType.text, '#EXTM3U\n#EXTINF:10,\nseg1.ts\n'),
    ]) {
      final (provider, url) = await _provider((req) async {
        req.response.headers.contentType = type;
        req.response.write(body);
        await req.response.close();
      });
      final said = <RelayProblem>[];
      final relay = await RecordRelay.start(url.toString(), onUnusable: said.add);
      await relay.recordTo(File('${dir.path}/d.ts'));
      await _read(relay.url).catchError((Object _) => (0, <int>[]));
      expect(said, [RelayProblem.hls], reason: '$type');
      await relay.close();
      await provider.close(force: true);
    }

    final (provider, url) = await _provider((req) async {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
    });
    final said = <RelayProblem>[];
    final relay = await RecordRelay.start(url.toString(), onUnusable: said.add);
    final (status, _) = await _read(relay.url);
    expect(status, HttpStatus.forbidden);
    expect(said, [RelayProblem.unreachable], reason: 'the player goes back to the channel directly');
    await relay.close();
    await provider.close(force: true);
  });

  test('a file that cannot be written stops the recording, said once, and stopping does not wait', () async {
    final (provider, url) = await _provider((req) async {
      for (var i = 0; i < 20; i++) {
        req.response.add(_bytes(16 * 1024, i));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await req.response.close();
    });
    final errors = <Object>[];
    final relay = await RecordRelay.start(url.toString(), onWriteError: errors.add);
    await relay.recordTo(File('${dir.path}/missing/e.ts')); // its folder is not there
    final read = _read(relay.url);
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (errors.isEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(errors, hasLength(1));
    await relay.recordTo(null).timeout(const Duration(seconds: 5));
    final (_, got) = await read;
    expect(got, hasLength(20 * 16 * 1024), reason: 'the player went on');
    await relay.close().timeout(const Duration(seconds: 5));
    await provider.close(force: true);
  });

  test('recording, the provider is read at its pace with the player paused; past what is kept for it, the '
      "player's connection ends", () async {
    RecordRelay.playerLag = 256 * 1024;
    addTearDown(() => RecordRelay.playerLag = 32 << 20);
    final sent = _bytes(16 << 20, 4);
    final (provider, url) = await _provider((req) async {
      for (var i = 0; i < sent.length; i += 64 * 1024) {
        req.response.add(sent.sublist(i, i + 64 * 1024));
        await req.response.flush();
      }
      await req.response.close();
    });
    final relay = await RecordRelay.start(url.toString());
    final file = File('${dir.path}/f.ts');
    await relay.recordTo(file);
    final client = HttpClient();
    final res = await (await client.getUrl(Uri.parse(relay.url))).close();
    final got = <int>[];
    final done = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = res.listen((chunk) {
      got.addAll(chunk);
      sub.pause(); // the player paused
    }, onDone: done.complete);
    final end = DateTime.now().add(const Duration(seconds: 15));
    while ((!file.existsSync() || file.lengthSync() < sent.length) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await relay.recordTo(null);
    expect(file.lengthSync(), sent.length, reason: 'all of it, the player paused');
    expect(file.readAsBytesSync(), sent);
    sub.onData(got.addAll);
    sub.resume();
    await done.future.timeout(const Duration(seconds: 15));
    expect(got.length, lessThan(sent.length), reason: 'the player fell too far behind: its connection ended');
    expect(got, sent.sublist(0, got.length));
    client.close(force: true);
    await relay.close();
    await provider.close(force: true);
  });

  test('a player connecting again joins the stream that runs: one connection to the provider', () async {
    var requests = 0;
    final gate = Completer<void>();
    final first = _bytes(64 * 1024, 5), second = _bytes(64 * 1024, 6);
    final (provider, url) = await _provider((req) async {
      requests++;
      req.response.add(first);
      await req.response.flush();
      await gate.future;
      req.response.add(second);
      await req.response.close();
    });
    final relay = await RecordRelay.start(url.toString());
    final file = File('${dir.path}/g.ts');
    await relay.recordTo(file);
    // The first connection hangs up once it has the first part
    final c1 = HttpClient();
    final r1 = await (await c1.getUrl(Uri.parse(relay.url))).close();
    var n = 0;
    await for (final chunk in r1) {
      n += chunk.length;
      if (n >= first.length) break;
    }
    c1.close(force: true);
    final again = _read(relay.url);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    gate.complete();
    final (_, got) = await again;
    await relay.recordTo(null);
    expect(requests, 1);
    expect(got, second, reason: 'from where the stream is');
    expect(file.readAsBytesSync(), [...first, ...second]);
    await relay.close();
    await provider.close(force: true);
  });

  test(
    'a scheduled recording taps the same stream alongside the player\'s own; the relay closing lets it go',
    () async {
      final sent = _bytes(200 * 1024, 5);
      var requests = 0;
      final hold = Completer<void>();
      final (provider, url) = await _provider((req) async {
        requests++;
        req.response.add(sent);
        await req.response.flush();
        await hold.future;
        await req.response.close();
      });
      final relay = await RecordRelay.start(url.toString());
      final own = File('${dir.path}/own.ts'), scheduled = File('${dir.path}/scheduled.ts')..writeAsBytesSync([9]);
      await relay.recordTo(own);
      final tap = relay.tap(scheduled);
      final client = HttpClient();
      final res = await (await client.getUrl(Uri.parse(relay.url))).close();
      var n = 0;
      final reading = res.listen((chunk) => n += chunk.length, onError: (Object _) {});
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (tap.bytes < sent.length || n < sent.length) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await relay.recordTo(null);
      expect(requests, 1, reason: 'one connection to the provider for all three');
      expect(own.readAsBytesSync(), sent);

      await relay.close();
      expect(await tap.done.timeout(const Duration(seconds: 5)), RecorderEnd.released);
      expect(scheduled.readAsBytesSync(), [9, ...sent], reason: 'after what it had');
      await tap.stop(); // nothing more to do
      await reading.cancel();
      client.close(force: true);
      hold.complete();
      await provider.close(force: true);
    },
  );

  test('a tap stopped keeps what came; one that gets nothing for a while is let go', () async {
    final (provider, url) = await _provider((req) async {
      req.response.add(_bytes(1000, 6));
      await req.response.close();
    });
    final relay = await RecordRelay.start(url.toString());
    final file = File('${dir.path}/h.ts');
    final tap = relay.tap(file);
    await _read(relay.url);
    await tap.stop();
    expect(await tap.done, RecorderEnd.stopped);
    expect(file.readAsBytesSync(), _bytes(1000, 6));

    RelayTap.stall = const Duration(milliseconds: 200);
    addTearDown(() => RelayTap.stall = const Duration(seconds: 60));
    final idle = relay.tap(File('${dir.path}/i.ts'));
    expect(await idle.done.timeout(const Duration(seconds: 5)), RecorderEnd.released);
    await relay.close();
    await provider.close(force: true);
  });

  group('while recording, a provider that goes quiet or hangs up', () {
    setUp(() {
      RecordRelay.stall = const Duration(milliseconds: 400);
      RecordRelay.firstRetry = const Duration(milliseconds: 50);
    });
    tearDown(() {
      RecordRelay.stall = const Duration(seconds: 20);
      RecordRelay.firstRetry = const Duration(seconds: 1);
    });

    Future<void> until(bool Function() done) async {
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!done()) {
        if (DateTime.now().isAfter(end)) fail('not in time');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('one that goes quiet without hanging up is let go, and the stream asked for anew', () async {
      var n = 0;
      final hold = Completer<void>();
      final (provider, url) = await _provider((req) async {
        final k = n++;
        req.response
          ..bufferOutput =
              false // sent now, not when it closes
          ..add(_bytes(1000, k));
        await req.response.flush();
        if (k == 0) await hold.future; // quiet, the connection kept open
        await req.response.close();
      });
      final relay = await RecordRelay.start(url.toString());
      final file = File('${dir.path}/quiet.ts');
      await relay.recordTo(file);
      final (_, got) = await _read(relay.url).timeout(const Duration(seconds: 5));
      expect(got, _bytes(1000, 0), reason: "the player's connection ends, for it to open the channel again");
      await until(() => file.lengthSync() >= 2000);
      await relay.recordTo(null);
      expect(file.readAsBytesSync().sublist(0, 2000), [..._bytes(1000, 0), ..._bytes(1000, 1)]);
      hold.complete();
      await relay.close();
      await provider.close(force: true);
    });

    test('one that takes the connection and never answers is let go too', () async {
      final hold = Completer<void>();
      final (provider, url) = await _provider((req) async {
        await hold.future; // no answer at all
        await req.response.close();
      });
      final relay = await RecordRelay.start(url.toString());
      await relay.recordTo(File('${dir.path}/silent.ts'));
      final (status, _) = await _read(relay.url).timeout(const Duration(seconds: 5));
      expect(status, HttpStatus.badGateway, reason: 'said, rather than a player that waits forever');
      await relay.recordTo(null);
      hold.complete();
      await relay.close();
      await provider.close(force: true);
    });

    test('with the player paused or gone, a stream the provider ends goes on, asked for by the relay', () async {
      var n = 0;
      final (provider, url) = await _provider((req) async {
        final k = n++;
        if (k < 3) req.response.add(_bytes(1000, k));
        await req.response.close();
      });
      final relay = await RecordRelay.start(url.toString());
      final file = File('${dir.path}/gone.ts');
      await relay.recordTo(file);
      await _read(relay.url); // the player reads the first stream, and does not come back
      await until(() => file.lengthSync() >= 3000);
      // A provider that hangs up at once is asked again a little later each time, not on and on
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(n, lessThan(9), reason: 'every 50 ms it would be over a dozen');
      await relay.recordTo(null);
      expect(file.readAsBytesSync(), [..._bytes(1000, 0), ..._bytes(1000, 1), ..._bytes(1000, 2)]);
      final asked = n;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(n, asked, reason: 'not recording any more: not asked for again');
      await relay.close();
      await provider.close(force: true);
    });
  });
}
