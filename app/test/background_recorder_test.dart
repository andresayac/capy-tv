// Recording a channel with no player: the stream into a file, asked for again when it drops.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/player/background_recorder.dart';

/// A provider on this machine; [answer] serves each request, numbered from 0.
Future<(HttpServer, String)> _provider(Future<void> Function(HttpRequest req, int n) answer) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var n = 0;
  // What is written goes out at once, as from a provider that streams
  server.listen((req) => answer(req..response.bufferOutput = false, n++));
  return (server, 'http://127.0.0.1:${server.port}/live/user/pass/1.ts');
}

List<int> _bytes(int n, int seed) => [for (var i = 0; i < n; i++) (i * 7 + seed) % 256];

/// Waits until [ok] holds, at most [timeout].
Future<void> _until(bool Function() ok, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  HttpOverrides.global = null; // real sockets
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('recorder');
    BackgroundRecorder.firstRetry = const Duration(milliseconds: 20);
    BackgroundRecorder.lastRetry = const Duration(milliseconds: 80);
    BackgroundRecorder.stallTimeout = const Duration(seconds: 20);
    BackgroundRecorder.healthy = const Duration(seconds: 30);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a stream that drops is asked for again and goes on in the same file, after what it had', () async {
    final a = _bytes(100 * 1024, 1), b = _bytes(50 * 1024, 2);
    final agents = <String?>[];
    final hold = Completer<void>();
    final (provider, url) = await _provider((req, n) async {
      agents.add(req.headers.value('user-agent'));
      req.response.headers.contentType = ContentType('video', 'mp2t');
      switch (n) {
        case 0:
          req.response.add(a);
          await req.response.close(); // the provider drops it
        case 1:
          req.response.statusCode = HttpStatus.serviceUnavailable; // and refuses it once
          await req.response.close();
        default:
          req.response.add(b);
          await req.response.flush();
          await hold.future;
          await req.response.close();
      }
    });
    final file = File('${dir.path}/a.ts')..writeAsBytesSync([9, 9, 9]);
    final recorder = await BackgroundRecorder.start(url, file, headers: {'User-Agent': 'Agent/1'});
    await _until(() => recorder.bytes == a.length + b.length);
    await recorder.stop();
    expect(await recorder.done, RecorderEnd.stopped);
    expect(file.readAsBytesSync(), [9, 9, 9, ...a, ...b]);
    expect(agents, ['Agent/1', 'Agent/1', 'Agent/1']);
    hold.complete();
    await provider.close(force: true);
  });

  test('stopped, it lets go of the provider and keeps what came', () async {
    final sent = _bytes(64 * 1024, 3);
    final gone = Completer<void>();
    final agents = <String?>[];
    final (provider, url) = await _provider((req, n) async {
      agents.add(req.headers.value('user-agent'));
      unawaited(req.response.done.then((_) {}, onError: (_) {}).whenComplete(gone.complete));
      req.response.add(sent);
      // Goes on sending until the recorder hangs up
      while (!gone.isCompleted) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (!gone.isCompleted) req.response.add(const [0x47]);
      }
    });
    final file = File('${dir.path}/b.ts');
    final recorder = await BackgroundRecorder.start(url, file);
    await _until(() => recorder.bytes >= sent.length);
    await recorder.stop();
    final kept = file.readAsBytesSync();
    expect(kept.length, recorder.bytes);
    expect(kept.take(sent.length), sent);
    await gone.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(agents, ['libmpv'], reason: 'mpv\'s own agent, and not asked for again once stopped');
    await provider.close(force: true);
  });

  test('a stream that stalls is taken as dropped', () async {
    BackgroundRecorder.stallTimeout = const Duration(milliseconds: 300);
    final hold = Completer<void>();
    final (provider, url) = await _provider((req, n) async {
      req.response.add(_bytes(1000, n));
      await req.response.flush();
      await hold.future; // and then nothing
    });
    final recorder = await BackgroundRecorder.start(url, File('${dir.path}/c.ts'));
    await _until(() => recorder.bytes >= 2000);
    expect((recorder as BackgroundRecorder).tries, greaterThanOrEqualTo(2));
    await recorder.stop();
    hold.complete();
    await provider.close(force: true);
  });

  test('a file that cannot be written ends the recording and says so', () async {
    final (provider, url) = await _provider((req, n) async {
      req.response.add(_bytes(1000, 4));
      await req.response.close();
    });
    final errors = <Object>[];
    final recorder = await BackgroundRecorder.start(
      url,
      File('${dir.path}/missing/folder/d.ts'),
      onWriteError: errors.add,
    );
    expect(await recorder.done.timeout(const Duration(seconds: 10)), RecorderEnd.writeFailed);
    expect(errors, hasLength(1));
    await recorder.stop(); // nothing more to do
    await provider.close(force: true);
  });

  test('a channel that comes as HLS is not recorded', () async {
    final (provider, url) = await _provider((req, n) async {
      req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
      req.response.write('#EXTM3U\n#EXT-X-VERSION:3\n');
      await req.response.close();
    });
    final file = File('${dir.path}/e.ts');
    final recorder = await BackgroundRecorder.start(url, file);
    expect(await recorder.done.timeout(const Duration(seconds: 10)), RecorderEnd.hls);
    expect(file.lengthSync(), 0);
    await provider.close(force: true);
  });

  test('the recorder is picked by the address: HLS has none until one is set; not over HTTP, none', () {
    expect(recorderFor('http://host/live/u/p/1.ts'), isNotNull);
    expect(recorderFor('HTTPS://host/live/u/p/1.ts'), isNotNull);
    expect(recorderFor('http://host/live/u/p/1.m3u8?token=x'), isNull);
    expect(isHlsUrl('http://host/hls/index.M3U8'), isTrue);
    for (final url in ['udp://@239.0.0.1:1234', 'rtmp://host/live/1', 'rtsp://host/1', 'not an address']) {
      expect(recorderFor(url), isNull, reason: url);
    }
  });

  test('a provider that takes the request and never answers is asked again', () async {
    BackgroundRecorder.stallTimeout = const Duration(milliseconds: 300);
    final hold = Completer<void>();
    final sent = _bytes(1000, 7);
    final (provider, url) = await _provider((req, n) async {
      if (n == 0) return hold.future; // no headers, ever
      req.response.add(sent);
      await req.response.flush();
      await hold.future;
    });
    final file = File('${dir.path}/f.ts');
    final recorder = await BackgroundRecorder.start(url, file);
    await _until(() => recorder.bytes == sent.length);
    expect((recorder as BackgroundRecorder).tries, 2);
    await recorder.stop();
    expect(file.readAsBytesSync(), sent);
    hold.complete();
    await provider.close(force: true);
  });

  test('a provider that sends a short clip and hangs up is asked again later each time, not at once', () async {
    BackgroundRecorder.firstRetry = const Duration(milliseconds: 20);
    BackgroundRecorder.lastRetry = const Duration(milliseconds: 160);
    final (provider, url) = await _provider((req, n) async {
      req.response.add(_bytes(1024, n)); // "not on air", and gone
      await req.response.close();
    });
    final recorder = await BackgroundRecorder.start(url, File('${dir.path}/g.ts'));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    // Waits 20, 40, 80, 160, 160...: about 8 tries; asked again at once each time, it would be 30 or more
    expect((recorder as BackgroundRecorder).tries, lessThanOrEqualTo(10));
    expect(recorder.tries, greaterThanOrEqualTo(2));
    await recorder.stop();
    await provider.close(force: true);
  });

  test('after a connection that lasted, a drop is asked for again at once', () async {
    BackgroundRecorder.firstRetry = const Duration(milliseconds: 20);
    BackgroundRecorder.lastRetry = const Duration(seconds: 5);
    BackgroundRecorder.healthy = const Duration(milliseconds: 300);
    final asked = <DateTime>[];
    DateTime? dropped;
    final (provider, url) = await _provider((req, n) async {
      asked.add(DateTime.now());
      if (n < 5) return req.response.close(); // refused: waits of 20, 40, 80, 160, 320 ms
      if (n == 5) {
        // A good while streaming, then dropped
        for (var i = 0; i < 8; i++) {
          req.response.add(_bytes(100, i));
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        dropped = DateTime.now();
        return req.response.close();
      }
      req.response.add(_bytes(100, 9));
      await req.response.flush();
      await Future<void>.delayed(const Duration(seconds: 5));
    });
    final recorder = await BackgroundRecorder.start(url, File('${dir.path}/h.ts'));
    await _until(() => asked.length >= 7);
    expect(asked[5].difference(asked[4]), greaterThanOrEqualTo(const Duration(milliseconds: 300)), reason: 'it grew');
    // The first wait again, not the 640 ms the doubling had reached
    expect(asked[6].difference(dropped!), lessThan(const Duration(milliseconds: 400)));
    expect((recorder as BackgroundRecorder).tries, 7);
    await recorder.stop();
    await provider.close(force: true);
  });
}
