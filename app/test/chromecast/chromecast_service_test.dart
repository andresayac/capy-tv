// The one cast at a time: one asked for and then stopped, or replaced, while it still connects
// never starts on the TV.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/chromecast/cast_discovery.dart';
import 'package:iptv_player/chromecast/cast_plan.dart';
import 'package:iptv_player/chromecast/cast_session.dart';
import 'package:iptv_player/chromecast/chromecast_service.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:iptv_player/player/play.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_cast_receiver.dart';

/// Counts what it is asked to do.
class _CountingDiscovery implements CastDiscovery {
  var starts = 0, stops = 0;

  @override
  Stream<List<ChromecastDevice>> get devices => const Stream.empty();

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> stop() async => stops++;
}

PlayItem _movie(String id) => PlayItem(
  url: 'http://provider.test/movie/user/pass/$id.mp4',
  title: 'Film $id',
  ref: MediaRef(kind: MediaKind.movie, id: id, title: 'Film $id'),
);

void main() {
  HttpOverrides.global = null; // real sockets
  final service = ChromecastService.instance;
  tearDown(service.stop);

  test('each "Send to" looks afresh, made once, and stops looking when it closes', () async {
    SharedPreferences.setMockInitialValues({});
    final counting = _CountingDiscovery();
    var made = 0;
    ChromecastService.discoveryForTests = () {
      made++;
      return counting;
    };
    addTearDown(() => ChromecastService.discoveryForTests = null);
    await service.discover();
    await service.stopDiscovery();
    await service.discover(); // one that failed before gets another go
    expect((made, counting.starts, counting.stops), (1, 2, 1));
  });

  test('an Xtream account that allows no HLS is told at once: its channel cannot be cast', () {
    final x = XtreamSource(server: 'http://tv.example:8080', username: 'u', password: 'p')..allowedFormats = ['ts'];
    const url = 'http://tv.example:8080/live/u/p/7.ts';
    expect(ChromecastService.accountFormatsFor(x, url), {'ts'});
    expect(ChromecastService.accountFormatsFor(x, 'http://other.example/live/u/p/7.ts'), isNull);
    expect(ChromecastService.accountFormatsFor(null, url), isNull);
    final plan = castPlan(
      PlayItem(
        url: url,
        title: 'News',
        ref: const MediaRef(kind: MediaKind.live, id: '7', title: 'News'),
      ),
      accountFormats: ChromecastService.accountFormatsFor(x, url),
    );
    expect(plan.refusal, CastRefusal.noHls);
  });

  test('stopped while it connects: the TV does not start', () async {
    final (fake, why) = await FakeCastReceiver.start();
    if (fake == null) return markTestSkipped(why);
    final device = ChromecastDevice(id: 'fake', name: 'Fake TV', host: '127.0.0.1', port: fake.port);
    final casting = service.cast(device, _movie('1'));
    await service.stop(); // "Stop casting" while it says "Connecting"
    await expectLater(casting, throwsA(isA<CastException>().having((e) => e.end, 'end', CastEnd.stopped)));
    expect(fake.of('LOAD'), isEmpty);
    expect(service.current.value, isNull);
    await fake.close();
  });

  test('a cast the TV cannot play says so to the end, not "stopped" once it lets go', () async {
    final (fake, why) = await FakeCastReceiver.start();
    if (fake == null) return markTestSkipped(why);
    fake.onLoad = (_) => FakeLoad.fail;
    final device = ChromecastDevice(id: 'fake', name: 'Fake TV', host: '127.0.0.1', port: fake.port);
    final cast = await service.cast(device, _movie('1'));
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (cast.session.status.value.phase != CastPhase.ended && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500)); // the stop that follows
    expect(cast.session.status.value.end, CastEnd.cannotPlay);
    await fake.close();
  });

  test('another cast asked for while the first connects: only the second plays', () async {
    final (first, why) = await FakeCastReceiver.start();
    if (first == null) return markTestSkipped(why);
    final (second, _) = await FakeCastReceiver.start();
    final one = ChromecastDevice(id: 'one', name: 'One', host: '127.0.0.1', port: first.port);
    final two = ChromecastDevice(id: 'two', name: 'Two', host: '127.0.0.1', port: second!.port);
    // Expected from the start: it may fail before the second is in, and an error nobody waits for
    // fails the test
    final earlier = expectLater(service.cast(one, _movie('1')), throwsA(isA<CastException>()));
    final later = await service.cast(two, _movie('2'));
    await earlier;
    expect(service.current.value, same(later));
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (second.of('LOAD').isEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(second.of('LOAD'), hasLength(1));
    expect(first.of('LOAD'), isEmpty, reason: 'the first TV never started');
    await first.close();
    await second.close();
  });

  test('sent again to the same TV while the first still connects: the one given up does not stop it', () async {
    final (fake, why) = await FakeCastReceiver.start();
    if (fake == null) return markTestSkipped(why);
    final device = ChromecastDevice(id: 'fake', name: 'Fake TV', host: '127.0.0.1', port: fake.port);
    // Back while it connects, and sent again; expected from the start, as above
    final earlier = expectLater(service.cast(device, _movie('1')), throwsA(isA<CastException>()));
    final later = await service.cast(device, _movie('2'));
    await earlier;
    final end = DateTime.now().add(const Duration(seconds: 20)); // slow under the whole suite
    while (later.session.status.value.phase != CastPhase.playing && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300)); // a STOP would have come by now
    expect(fake.of('STOP'), isEmpty, reason: 'the TV keeps the app the second cast joined');
    expect(later.session.status.value.phase, CastPhase.playing);
    await service.stop();
    await fake.close();
  });
}
