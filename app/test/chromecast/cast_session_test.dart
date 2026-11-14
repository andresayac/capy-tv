// The Chromecast sender against a fake receiver on this machine: the link and its heartbeat, launching
// or joining the Default Media Receiver, loading with fallbacks, controls, drops, takeovers and the end.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/chromecast/cast_link.dart';
import 'package:iptv_player/chromecast/cast_session.dart';

import '../support/fake_cast_receiver.dart';

const _t = CastTimings(
  heartbeat: Duration(milliseconds: 100),
  deadline: Duration(milliseconds: 800),
  launch: Duration(seconds: 2),
  load: Duration(seconds: 2),
  reconnect: [Duration(milliseconds: 50), Duration(milliseconds: 100), Duration(milliseconds: 200)],
  poll: Duration(milliseconds: 100),
);

const _movie = CastMedia(
  url: 'http://192.168.1.5:8080/movie/u/p/1.mp4',
  contentType: 'video/mp4',
  title: 'Film',
  image: 'http://img.test/1.jpg',
  kind: CastMediaKind.movie,
  startAt: Duration(seconds: 100),
);
const _mkv = CastMedia(url: 'http://192.168.1.5:8080/movie/u/p/1.mkv', contentType: 'video/x-matroska');
const _relayed = CastMedia(url: 'http://192.168.1.2:40000/0123abcd/v.mp4', contentType: 'video/mp4');
const _next = CastMedia(
  url: 'http://192.168.1.5:8080/series/u/p/2.mp4',
  contentType: 'video/mp4',
  kind: CastMediaKind.episode,
);
const _live = CastMedia(
  url: 'http://192.168.1.2:40000/0123abcd/live.m3u8',
  contentType: 'application/x-mpegurl',
  live: true,
  hls: true,
  kind: CastMediaKind.live,
);

final _open = <CastSession>[];

/// A test with a fresh fake receiver; skipped when openssl is not there to make its certificate.
void _test(String name, Future<void> Function(FakeCastReceiver fake) body) {
  test(name, () async {
    final (fake, why) = await FakeCastReceiver.start();
    if (fake == null) return markTestSkipped(why);
    try {
      await body(fake);
    } finally {
      for (final s in _open) {
        await s.detach();
      }
      _open.clear();
      await fake.close();
    }
  });
}

Future<CastSession> _connect(FakeCastReceiver fake, {CastTimings timings = _t}) async {
  final s = await CastSession.connect('127.0.0.1', port: fake.port, timings: timings);
  _open.add(s);
  return s;
}

/// Waits for a status [ok] takes, listening, so one that passes quickly is not missed.
Future<CastStatus> _until(CastSession s, bool Function(CastStatus st) ok) async {
  if (ok(s.status.value)) return s.status.value;
  final done = Completer<CastStatus>();
  void check() {
    if (!done.isCompleted && ok(s.status.value)) done.complete(s.status.value);
  }

  s.status.addListener(check);
  try {
    return await done.future.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    fail('not reached; now ${s.status.value}');
  } finally {
    s.status.removeListener(check);
  }
}

Future<CastStatus> _phase(CastSession s, CastPhase phase) => _until(s, (st) => st.phase == phase);

Future<void> _eventually(bool Function() check, {String Function()? why}) async {
  // Under the whole suite a reconnection takes longer: within the test's own time, not 5 s
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail(why?.call() ?? 'did not happen in time');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Every phase [s] goes through from now on.
List<CastPhase> _phases(CastSession s) {
  final seen = <CastPhase>[];
  s.status.addListener(() {
    if (seen.isEmpty || seen.last != s.status.value.phase) seen.add(s.status.value.phase);
  });
  return seen;
}

Matcher _ended(CastEnd end) => isA<CastException>().having((e) => e.end, 'end', end);

void main() {
  group('link', () {
    test('the TLS handshake has its own timeout, and the socket is let go', () async {
      final (fake, _) = await FakeCastReceiver.start(tls: false);
      addTearDown(fake!.close);
      final clock = Stopwatch()..start();
      await expectLater(
        CastLink.connect('127.0.0.1', fake.port, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(fake.connections, 1, reason: 'TCP was accepted');
      await _eventually(() => fake.hungUp == 1);
    });

    _test('it PINGs, answers PING with PONG, and dies when PONGs stop, whatever else comes', (fake) async {
      final link = await CastLink.connect(
        '127.0.0.1',
        fake.port,
        heartbeat: const Duration(milliseconds: 50),
        deadline: const Duration(milliseconds: 300),
      );
      expect(link.localAddress.address, '127.0.0.1');
      await _eventually(() => fake.of('PING').length >= 3);
      expect(fake.of('CONNECT').single.to, CastLink.receiverId);
      expect(fake.of('PING').first.to, CastLink.receiverId);
      fake.ping();
      await _eventually(() => fake.of('PONG').isNotEmpty);
      expect(fake.of('PONG').single.to, CastLink.receiverId);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(link.isClosed, isFalse, reason: 'answered');
      fake.answerPing = false;
      final pings = Timer.periodic(const Duration(milliseconds: 40), (_) => fake.ping());
      addTearDown(pings.cancel);
      await link.done.timeout(const Duration(seconds: 3));
      expect(link.isClosed, isTrue);
      await _eventually(() => fake.hungUp == 1);
    });

    _test('replies come by requestId, from 1; a timeout, and a link closing, fail what waits', (fake) async {
      final link = await CastLink.connect('127.0.0.1', fake.port);
      addTearDown(link.close);
      final reply = await link.request(CastNs.receiver, {'type': 'GET_STATUS'}, timeout: const Duration(seconds: 2));
      expect(reply['type'], 'RECEIVER_STATUS');
      expect(reply['requestId'], 1);
      await expectLater(
        link.request(CastNs.receiver, {'type': 'NOTHING'}, timeout: const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      final waiting = link.request(CastNs.receiver, {'type': 'NOTHING'}, timeout: const Duration(seconds: 5));
      await _eventually(() => fake.received.where((m) => m.body['type'] == 'NOTHING').length == 2);
      fake.drop();
      await expectLater(waiting, throwsA(isA<SocketException>()));
      await link.done.timeout(const Duration(seconds: 2));
      expect(fake.received.map((m) => m.body['requestId']).whereType<int>(), [1, 2, 3]);
    });

    _test('an oversize frame from the receiver closes the link', (fake) async {
      final link = await CastLink.connect('127.0.0.1', fake.port);
      await _eventually(() => fake.of('CONNECT').isNotEmpty);
      fake.oversize();
      await link.done.timeout(const Duration(seconds: 2));
      expect(link.isClosed, isTrue);
    });
  });

  group('connect', () {
    _test('launches the media receiver, loads, plays; every request numbered from 1, never 0', (fake) async {
      fake.unknownFields = true; // fields 8 and 9 on all it sends
      final s = await _connect(fake);
      expect(s.status.value.phase, CastPhase.idle);
      expect(s.localAddress.address, '127.0.0.1');
      expect(fake.of('LAUNCH').single.body['appId'], 'CC1AD845');
      expect(fake.of('CONNECT').map((m) => m.to), [CastLink.receiverId, fake.transportId]);

      await s.load([_movie]);
      expect(s.status.value.phase, isIn([CastPhase.buffering, CastPhase.playing]));
      final st = await _phase(s, CastPhase.playing);
      expect(st.candidate, 0);
      expect(st.position, greaterThanOrEqualTo(const Duration(seconds: 100)));
      expect(st.volume, 1.0);

      final load = fake.of('LOAD').single;
      expect(load.to, fake.transportId);
      expect(load.body, {
        'type': 'LOAD',
        'requestId': load.body['requestId'],
        'sessionId': fake.sessionId,
        'media': _movie.toLoad(),
        'autoplay': true,
        'currentTime': 100.0,
      });
      await _eventually(() => fake.of('GET_STATUS').length >= 4); // polled
      final ids = [for (final m in fake.received) ?m.body['requestId'] as int?];
      expect(ids.first, 1);
      expect(ids, isNot(contains(0)));
      expect(ids, [for (var i = 1; i <= ids.length; i++) i], reason: 'one after another');
    });

    _test('joins the media receiver already running: no LAUNCH, and what played is not taken for ours', (fake) async {
      fake.running(content: _movie.url); // ours, from before: the same content
      fake.ack = FakeAck.zeroOnly; // so ours is known by its content
      final s = await _connect(fake);
      expect(fake.of('LAUNCH'), isEmpty);
      expect(fake.of('CONNECT').map((m) => m.to), [CastLink.receiverId, fake.transportId]);
      final phases = _phases(s);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      expect(fake.mediaSessionId, 2);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(s.status.value.phase, CastPhase.playing, reason: "the old one's INTERRUPTED was not ours");
      expect(phases, isNot(contains(CastPhase.ended)));
    });

    _test('the Backdrop app, listed first, is not taken for ours, launching or joining', (fake) async {
      fake.backdrop = true;
      final s = await _connect(fake);
      expect(fake.of('CONNECT').map((m) => m.to), [CastLink.receiverId, fake.transportId]);
      expect(fake.transportId, isNot('backdrop-transport'));
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);

      final other = await _connect(fake);
      expect(fake.of('LAUNCH'), hasLength(1), reason: 'joined');
      expect(fake.received.where((m) => m.link == 2 && m.body['type'] == 'CONNECT').map((m) => m.to), [
        CastLink.receiverId,
        fake.transportId,
      ]);
      expect(other.status.value.phase, CastPhase.idle);
    });

    _test('LAUNCH_ERROR fails as launchFailed; nothing listening, as connectFailed', (fake) async {
      fake.launchError = true;
      await expectLater(
        CastSession.connect('127.0.0.1', port: fake.port, timings: _t),
        throwsA(_ended(CastEnd.launchFailed)),
      );
      await _eventually(() => fake.hungUp == 1);

      final gone = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = gone.port;
      await gone.close();
      await expectLater(
        CastSession.connect('127.0.0.1', port: port, timings: _t),
        throwsA(_ended(CastEnd.connectFailed)),
      );
    });
  });

  group('load', () {
    _test('a candidate answered LOAD_FAILED gives way to the next', (fake) async {
      fake.onLoad = (m) => m['contentId'] == _mkv.url ? FakeLoad.fail : FakeLoad.play;
      final s = await _connect(fake);
      await s.load([_mkv, _movie]);
      final st = await _phase(s, CastPhase.playing);
      expect(st.candidate, 1);
      expect(fake.of('LOAD').map((m) => m.body['media']['contentId']), [_mkv.url, _movie.url]);
      expect(fake.media!['contentId'], _movie.url);
    });

    _test('IDLE/ERROR gives way to the next, and the stale ERROR of the one before is not ours', (fake) async {
      fake.staleError = true;
      fake.onLoad = (m) => m['contentId'] == _movie.url ? FakeLoad.error : FakeLoad.play;
      final s = await _connect(fake);
      await s.load([_movie, _relayed]);
      final st = await _phase(s, CastPhase.playing);
      expect(st.candidate, 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(s.status.value.phase, CastPhase.playing);
    });

    _test('a candidate that never starts times out to the next', (fake) async {
      fake.onLoad = (m) => m['contentId'] == _movie.url ? FakeLoad.silent : FakeLoad.play;
      const timings = CastTimings(
        heartbeat: Duration(milliseconds: 100),
        deadline: Duration(milliseconds: 800),
        load: Duration(milliseconds: 1000),
        poll: Duration(milliseconds: 100),
      );
      final s = await _connect(fake, timings: timings);
      final clock = Stopwatch()..start();
      await s.load([_movie, _relayed]);
      expect(clock.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 1000)));
      final st = await _phase(s, CastPhase.playing);
      expect(st.candidate, 1);
    });

    _test('one that started but only buffers is kept after as long again, not skipped', (fake) async {
      fake.onLoad = (_) => FakeLoad.stall;
      const timings = CastTimings(
        heartbeat: Duration(milliseconds: 100),
        deadline: Duration(milliseconds: 800),
        load: Duration(milliseconds: 1000),
        poll: Duration(milliseconds: 100),
      );
      final s = await _connect(fake, timings: timings);
      final clock = Stopwatch()..start();
      await s.load([_movie, _relayed]).timeout(const Duration(seconds: 6));
      expect(clock.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 1000)));
      expect(s.status.value.phase, CastPhase.buffering);
      expect(s.status.value.candidate, 0);
      expect(fake.of('LOAD'), hasLength(1));
    });

    _test('none plays: ended, cannotPlay; the link stays for another load', (fake) async {
      fake.onLoad = (_) => FakeLoad.fail;
      final s = await _connect(fake);
      await s.load([_movie, _mkv]);
      expect(s.status.value.phase, CastPhase.ended);
      expect(s.status.value.end, CastEnd.cannotPlay);
      expect(s.status.value.candidate, 1);
      fake.onLoad = (_) => FakeLoad.play;
      await s.load([_movie]);
      final st = await _phase(s, CastPhase.playing);
      expect(st.end, isNull);
      expect(fake.connections, 1);
    });

    for (final (ack, name) in [
      (FakeAck.zeroOnly, 'only requestId 0 statuses (Google TV)'),
      (FakeAck.idleLoading, 'an IDLE+LOADING ack'),
    ]) {
      _test('$name is a start, not a failure', (fake) async {
        fake.ack = ack;
        final s = await _connect(fake);
        final phases = _phases(s);
        await s.load([_movie]);
        final st = await _phase(s, CastPhase.playing);
        expect(st.candidate, 0);
        expect(fake.of('LOAD'), hasLength(1));
        expect(phases, containsAllInOrder([CastPhase.loading, CastPhase.buffering, CastPhase.playing]));
        expect(phases, isNot(contains(CastPhase.ended)));
      });
    }

    _test('a LOAD over 64 KiB loses its metadata to fit, and one that cannot fit is skipped', (fake) async {
      final big = CastMedia(
        url: _movie.url,
        contentType: 'video/mp4',
        title: 'Film',
        image: 'http://img.test/${'x' * 70000}.jpg',
        kind: CastMediaKind.movie,
      );
      final huge = CastMedia(url: 'http://p.test/${'y' * 70000}.mp4', contentType: 'video/mp4');
      final s = await _connect(fake);
      await s.load([huge, big]);
      final st = await _phase(s, CastPhase.playing);
      expect(st.candidate, 1);
      expect(fake.of('LOAD').single.body['media']['metadata'], {'metadataType': 1, 'title': 'Film'});
    });

    _test('a newer load supersedes one still waiting', (fake) async {
      fake.onLoad = (m) => m['contentId'] == _movie.url ? FakeLoad.silent : FakeLoad.play;
      final s = await _connect(fake);
      final first = s.load([_movie]);
      await _eventually(() => fake.of('LOAD').length == 1);
      await s.load([_relayed]);
      await first.timeout(const Duration(seconds: 1));
      await _phase(s, CastPhase.playing);
      expect(fake.media!['contentId'], _relayed.url);
      expect(fake.of('LOAD'), hasLength(2));
    });

    _test('a live channel that fails while playing is loaded once more; anything else cannot play', (fake) async {
      final s = await _connect(fake);
      await s.load([_live]);
      await _phase(s, CastPhase.playing);
      fake.error();
      await _until(s, (st) => fake.of('LOAD').length == 2 && st.phase == CastPhase.playing);
      fake.error();
      var st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.cannotPlay);
      expect(fake.of('LOAD'), hasLength(2));

      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      fake.error();
      st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.cannotPlay);
      expect(fake.of('LOAD'), hasLength(3), reason: 'no reload for a movie');
    });

    _test('a reload that has held earns a later failure its own reload', (fake) async {
      const timings = CastTimings(
        heartbeat: Duration(milliseconds: 100),
        deadline: Duration(milliseconds: 800),
        load: Duration(milliseconds: 1000),
        poll: Duration(milliseconds: 100),
      );
      final s = await _connect(fake, timings: timings);
      await s.load([_live]);
      await _phase(s, CastPhase.playing);
      fake.error();
      await _until(s, (st) => fake.of('LOAD').length == 2 && st.phase == CastPhase.playing);
      await Future<void>.delayed(const Duration(milliseconds: 1800)); // plays on, well past timings.load
      fake.error();
      await _until(s, (st) => fake.of('LOAD').length == 3 && st.phase == CastPhase.playing);
      fake.error(); // straight after that reload
      final st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.cannotPlay);
      expect(fake.of('LOAD'), hasLength(3));
    });
  });

  group('playing', () {
    _test('controls go with our mediaSessionId; volume and mute to the receiver', (fake) async {
      final s = await _connect(fake);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      final id = fake.mediaSessionId;
      await s.pause();
      await _phase(s, CastPhase.paused);
      await s.seek(const Duration(minutes: 30));
      await _until(s, (st) => st.position >= const Duration(minutes: 30) && st.position < const Duration(minutes: 31));
      await s.play();
      await _phase(s, CastPhase.playing);
      await s.setVolume(0.4);
      await _until(s, (st) => st.volume == 0.4);
      await s.setMuted(true);
      await _until(s, (st) => st.muted);
      for (final type in ['PAUSE', 'SEEK', 'PLAY']) {
        expect(fake.of(type).single.body['mediaSessionId'], id, reason: type);
        expect(fake.of(type).single.to, fake.transportId, reason: type);
      }
      expect(fake.of('SEEK').single.body['currentTime'], 1800);
      expect(fake.of('SET_VOLUME').map((m) => m.body['volume']), [
        {'level': 0.4},
        {'muted': true},
      ]);
      expect(fake.level, 0.4);
      expect(fake.muted, isTrue);
    });

    _test('the position moves between statuses', (fake) async {
      const timings = CastTimings(
        heartbeat: Duration(milliseconds: 100),
        deadline: Duration(milliseconds: 800),
        poll: Duration(seconds: 30), // no status requests: only the position's own ticks
      );
      final s = await _connect(fake, timings: timings);
      await s.load([_movie]);
      final at = (await _phase(s, CastPhase.playing)).position;
      var updates = 0;
      s.status.addListener(() => updates++);
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      final moved = s.status.value.position - at;
      expect(moved, greaterThanOrEqualTo(const Duration(milliseconds: 800)));
      expect(moved, lessThan(const Duration(milliseconds: 2500)));
      expect(updates, greaterThanOrEqualTo(2));
    });

    _test('an IDLE saying 0 does not lose where it was, and the end of a film is the whole of it', (fake) async {
      final s = await _connect(fake);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final at = s.status.value.position;
      expect(at, greaterThan(const Duration(milliseconds: 500)));
      fake.idleAtZero = true;
      fake.error();
      final st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.cannotPlay);
      expect(st.position, greaterThanOrEqualTo(at), reason: 'not the 0 the receiver said');

      await s.load([_next]);
      await _phase(s, CastPhase.playing);
      fake.finish();
      final done = await _phase(s, CastPhase.ended);
      expect(done.end, CastEnd.finished);
      if (done.duration case final d?) expect(done.position, d, reason: 'played to its end: seen whole');
    });

    _test('played to its end: ended, finished; the next loads on the same link', (fake) async {
      final s = await _connect(fake);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      fake.finish();
      final st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.finished);
      await s.load([_next]);
      await _phase(s, CastPhase.playing);
      expect(fake.media!['contentId'], _next.url);
      expect(fake.connections, 1);
    });
  });

  group('taken over, or our app closed', () {
    for (final (how, end, name) in [
      ((FakeCastReceiver f) => f.launchOther(), CastEnd.takenOver, 'another app launched'),
      (
        (FakeCastReceiver f) => f.launchOther(announce: false),
        CastEnd.takenOver,
        'another app launched, with only a CLOSE: the status is asked',
      ),
      ((FakeCastReceiver f) => f.interrupt(), CastEnd.takenOver, "another sender's media in our app (INTERRUPTED)"),
      ((FakeCastReceiver f) => f.stopApp(), CastEnd.stopped, 'our app stopped at the receiver, nothing else running'),
      (
        (FakeCastReceiver f) => f
          ..backdrop = true
          ..stopApp(),
        CastEnd.stopped,
        'our app closed, only the Backdrop left',
      ),
      (
        (FakeCastReceiver f) => f.stopApp(announce: false),
        CastEnd.stopped,
        'our app closed, with only a CLOSE: the status is asked',
      ),
    ]) {
      _test('$name: ${end.name}', (fake) async {
        final s = await _connect(fake);
        await s.load([_movie]);
        await _phase(s, CastPhase.playing);
        how(fake);
        final st = await _phase(s, CastPhase.ended);
        expect(st.end, end);
        await _eventually(() => fake.hungUp == 1);
        await expectLater(s.load([_movie]), throwsA(_ended(end)));
      });
    }

    for (final (fails, end) in [(false, CastEnd.finished), (true, CastEnd.cannotPlay)]) {
      _test('once ${end.name}, our app closing on its own keeps that end', (fake) async {
        final s = await _connect(fake);
        if (fails) fake.onLoad = (_) => FakeLoad.fail;
        await s.load([_movie]);
        if (!fails) {
          await _phase(s, CastPhase.playing);
          fake.finish();
        }
        expect((await _phase(s, CastPhase.ended)).end, end);
        var shown = 0;
        s.status.addListener(() => shown++);
        fake.stopApp(); // its idle timeout
        await _eventually(() => fake.hungUp == 1);
        expect(s.status.value.end, end);
        expect(shown, 0, reason: 'closed quietly');
        await expectLater(s.load([_next]), throwsA(_ended(CastEnd.stopped)));
      });
    }
  });

  group('our media gone unseen', () {
    _test('replaced while the link was down: taken over once back', (fake) async {
      final s = await _connect(fake);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      fake.drop();
      fake.interrupt(); // its statuses reach nobody
      final st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.takenOver);
      expect(fake.connections, 2);
    });

    _test('replaced with no status about it: the next poll tells, taken over', (fake) async {
      final s = await _connect(fake);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      fake.interrupt(announce: false);
      final st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.takenOver);
      expect(fake.connections, 1);
    });

    _test('gone near its end while the link was down: finished, the link kept', (fake) async {
      fake.onLoad = (m) {
        m['duration'] = 102.0; // it resumes at 100 s
        return FakeLoad.play;
      };
      final s = await _connect(fake);
      await s.load([_movie]);
      await _until(s, (st) => st.phase == CastPhase.playing && st.duration != null);
      fake.drop();
      fake.vanish();
      final st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.finished);
      await s.load([_next]);
      await _phase(s, CastPhase.playing);
      expect(fake.connections, 2);
    });

    _test('gone mid-way with no status about it: lost', (fake) async {
      fake.onLoad = (m) {
        m['duration'] = 3600.0;
        return FakeLoad.play;
      };
      final s = await _connect(fake);
      await s.load([_movie]);
      await _until(s, (st) => st.phase == CastPhase.playing && st.duration != null);
      fake.vanish();
      final st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.lost);
      await _eventually(() => fake.hungUp == 1);
    });
  });

  group('reconnect', () {
    for (final (fault, name) in [
      ((FakeCastReceiver f) => f.drop(), 'a dropped socket'),
      ((FakeCastReceiver f) => f.oversize(), 'an oversize frame'),
    ]) {
      _test('after $name: back to our session by its sessionId, nothing launched or loaded again', (fake) async {
        final s = await _connect(fake);
        await s.load([_movie]);
        await _phase(s, CastPhase.playing);
        final phases = _phases(s);
        fault(fake);
        await _until(s, (st) => st.phase == CastPhase.playing && fake.connections == 2);
        expect(phases, containsAllInOrder([CastPhase.reconnecting, CastPhase.playing]));
        Iterable<String> connects() =>
            fake.received.where((m) => m.link == 2 && m.body['type'] == 'CONNECT').map((m) => m.to);
        await _eventually(() => connects().length == 2); // the fake reads them after we sent them
        expect(connects(), [CastLink.receiverId, fake.transportId]);
        expect(fake.of('LAUNCH'), hasLength(1));
        expect(fake.of('LOAD'), hasLength(1));
        await s.pause();
        await _phase(s, CastPhase.paused);
      });
    }

    _test('after the receiver stops answering PING', (fake) async {
      final s = await _connect(fake);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      fake.answerPing = false;
      await _phase(s, CastPhase.reconnecting);
      fake.answerPing = true;
      await _phase(s, CastPhase.playing);
      expect(fake.connections, 2);
      expect(fake.of('LAUNCH'), hasLength(1));
      expect(fake.of('LOAD'), hasLength(1));
    });

    _test('a LOAD cut off by a drop is sent again once back', (fake) async {
      fake.onLoad = (_) => FakeLoad.silent;
      final s = await _connect(fake);
      final loading = s.load([_movie]);
      await _eventually(() => fake.of('LOAD').length == 1);
      fake.onLoad = (_) => FakeLoad.play;
      fake.drop();
      await loading.timeout(const Duration(seconds: 3));
      final st = await _phase(s, CastPhase.playing);
      expect(st.candidate, 0);
      expect(fake.of('LOAD').map((m) => m.link), [1, 2]);
    });

    _test('none of the tries gets through: ended, lost', (fake) async {
      final s = await _connect(fake);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      fake.refuse = true;
      fake.drop();
      final st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.lost);
      expect(fake.connections, 1 + _t.reconnect.length);
    });

    _test('back, but our session is gone: ended, lost', (fake) async {
      final s = await _connect(fake);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      fake.forget();
      fake.drop();
      final st = await _phase(s, CastPhase.ended);
      expect(st.end, CastEnd.lost);
      expect(fake.connections, 2);
    });
  });

  group('the end', () {
    _test('stop: the media, then our app, then the link', (fake) async {
      final s = await _connect(fake);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      final media = fake.mediaSessionId, session = fake.sessionId;
      await s.stop();
      expect(s.status.value.phase, CastPhase.ended);
      expect(s.status.value.end, CastEnd.stopped);
      final stops = fake.of('STOP');
      expect(stops.map((m) => m.namespace), [CastNs.media, CastNs.receiver]);
      expect(stops.first.body['mediaSessionId'], media);
      expect(stops.last.body['sessionId'], session);
      expect(fake.appId, isNull);
      await _eventually(() => fake.hungUp == 1);
      await expectLater(s.load([_movie]), throwsA(_ended(CastEnd.stopped)));
    });

    _test('stop while reconnecting: our app is stopped over a link of its own', (fake) async {
      const timings = CastTimings(
        heartbeat: Duration(milliseconds: 100),
        deadline: Duration(milliseconds: 800),
        reconnect: [Duration(seconds: 2)], // still waiting when stop() comes
        poll: Duration(milliseconds: 100),
      );
      final s = await _connect(fake, timings: timings);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      final media = fake.mediaSessionId, session = fake.sessionId;
      fake.drop();
      await _phase(s, CastPhase.reconnecting);
      final clock = Stopwatch()..start();
      await s.stop();
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(s.status.value.phase, CastPhase.ended);
      expect(s.status.value.end, CastEnd.stopped);
      final stops = fake.of('STOP');
      expect(stops.map((m) => m.namespace), [CastNs.media, CastNs.receiver]);
      expect(stops.map((m) => m.link), [2, 2]);
      expect(stops.first.body['mediaSessionId'], media);
      expect(stops.last.body['sessionId'], session);
      expect(fake.appId, isNull, reason: 'the TV stopped playing');
      await _eventually(
        () => fake.hungUp >= 1,
        why: () => 'the link of its own was not closed: ${fake.connections} links, ${fake.hungUp} closed',
      );
      expect((fake.connections, fake.hungUp), (2, 1), reason: 'that link, and no other');
    });

    _test('detach: the link closes, the receiver plays on', (fake) async {
      final s = await _connect(fake);
      await s.load([_movie]);
      await _phase(s, CastPhase.playing);
      final transport = fake.transportId;
      await s.detach();
      expect(s.status.value.phase, CastPhase.ended);
      await _eventually(() => fake.hungUp == 1);
      expect(fake.playerState, 'PLAYING');
      expect(fake.transportId, transport);
      expect(fake.of('STOP'), isEmpty);
      expect(fake.of('CLOSE'), isEmpty);
    });
  });
}
