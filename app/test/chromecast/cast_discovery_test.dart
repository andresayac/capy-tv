// Finding Chromecasts: what a browser reports becomes rows, resolved one service at a time, and
// what people type becomes a device or nothing.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/chromecast/cast_discovery.dart';

/// A pretend network: the services on it (with the TXT record a browse brings, often none), and
/// how each resolve of a service is answered.
class _Network {
  _Network(this.answer, {Map<String, Map<String, String>>? present}) : present = present ?? {};

  /// What a browser started now finds.
  final Map<String, Map<String, String>> present;

  /// What answers the [attempt]th resolve (from 1) of [name]: null when nothing does.
  final CastServiceEvent? Function(String name, int attempt) answer;

  final asked = <String>[];
  final askedAt = <Duration>[];
  final _clock = Stopwatch()..start();
  final browsers = <_FakeBrowser>[];

  _FakeBrowser newBrowser() {
    final browser = _FakeBrowser(this);
    browsers.add(browser);
    return browser;
  }

  void emit(CastServiceEvent event) => browsers.last.emit(event);
}

/// A browser on a [_Network]: once started, it finds what is there.
class _FakeBrowser implements CastBrowser {
  _FakeBrowser(this.network);

  final _Network network;
  void Function(CastServiceEvent event)? _hear;
  void Function()? _onEnd;
  var stopped = false;

  @override
  Future<void> start(void Function(CastServiceEvent event) onEvent, void Function() onEnd) async {
    _hear = onEvent;
    _onEnd = onEnd;
    network.present.forEach((name, txt) {
      scheduleMicrotask(() => emit(CastServiceEvent(CastServiceChange.found, name, txt: txt)));
    });
  }

  @override
  Future<void> stop() async {
    stopped = true;
    _hear = null;
  }

  @override
  Future<void> resolve(String name) async {
    network.asked.add(name);
    network.askedAt.add(network._clock.elapsed);
    final answer = network.answer(name, network.asked.where((n) => n == name).length);
    if (answer != null) scheduleMicrotask(() => emit(answer));
  }

  void emit(CastServiceEvent event) => _hear?.call(event);

  /// The platform gives up browsing.
  void end() => _onEnd?.call();
}

CastServiceEvent _resolved(
  String name, {
  String id = '',
  String fn = '',
  String md = 'Chromecast',
  String ca = '4101',
  List<String> addresses = const [],
  String? hostname,
}) => CastServiceEvent(
  CastServiceChange.resolved,
  name,
  txt: {'id': id, 'fn': fn, 'md': md, 'ca': ca},
  addresses: addresses,
  hostname: hostname,
  port: 8009,
);

const _failed = CastServiceEvent(CastServiceChange.resolveFailed, '');

BonsoirCastDiscovery _discovery(
  _Network network, {
  bool keepAlive = false,
  Future<List<InternetAddress>> Function(String host)? lookup,
}) => BonsoirCastDiscovery(
  browser: network.newBrowser,
  keepAlive: keepAlive,
  lookup: lookup ?? (host) async => throw SocketException('no lookups here: $host'),
  resolveAfter: const Duration(milliseconds: 20),
  resolveTimeout: const Duration(milliseconds: 150),
);

/// The first list from [discovery] that passes [test].
Future<List<ChromecastDevice>> _until(CastDiscovery discovery, bool Function(List<ChromecastDevice> rows) test) =>
    discovery.devices.firstWhere(test).timeout(const Duration(seconds: 5));

/// Waits until [test] holds.
Future<void> _eventually(bool Function() test) async {
  final clock = Stopwatch()..start();
  while (!test()) {
    if (clock.elapsed > const Duration(seconds: 5)) fail('still not so after 5 s');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // for the tests through bonsoir's platform channels

  test('a found Chromecast shows at once by its service name, then as it calls itself once resolved', () async {
    final network = _Network(
      (name, _) => _resolved(name, id: 'abc123', fn: 'Living Room TV', addresses: ['fe80::1', '192.168.1.20']),
      present: {'Chromecast-abc123': {}},
    );
    final discovery = _discovery(network);
    await discovery.start();

    final found = await _until(discovery, (rows) => rows.isNotEmpty);
    expect(found.single.id, 'Chromecast-abc123');
    expect(found.single.name, 'Chromecast-abc123');
    expect(found.single.host, '');
    expect(network.asked, isEmpty, reason: 'its address is asked for a moment later, not at once');

    // Android reads the TXT record on its own and says so before any resolve
    network.emit(
      const CastServiceEvent(
        CastServiceChange.updated,
        'Chromecast-abc123',
        txt: {'id': 'abc123', 'fn': 'Living Room TV'},
      ),
    );
    final named = (await discovery.devices.first).single;
    expect((named.id, named.name, named.host), ('abc123', 'Living Room TV', ''));

    final resolved = (await _until(discovery, (rows) => rows.single.host.isNotEmpty)).single;
    expect(resolved.id, 'abc123');
    expect(resolved.name, 'Living Room TV');
    expect(resolved.model, 'Chromecast');
    expect(resolved.host, '192.168.1.20', reason: 'the first IPv4, not the IPv6 before it');
    expect(resolved.port, 8009);
    expect(network.asked, ['Chromecast-abc123']);
    expect(await discovery.devices.first, [resolved], reason: 'a late listener gets the list as it is');
  });

  test('a found Chromecast goes by the id in its service name until its TXT record is known', () async {
    const service = 'Chromecast-Ultra-0123456789ABCDEF0123456789abcdef';
    final network = _Network(
      (name, _) => _resolved(name, id: '0123456789abcdef0123456789abcdef', fn: 'TV', addresses: ['192.168.1.20']),
      present: {service: {}},
    );
    final discovery = _discovery(network);
    await discovery.start();

    final found = (await _until(discovery, (rows) => rows.isNotEmpty)).single;
    expect((found.id, found.name), ('0123456789abcdef0123456789abcdef', service));
    final resolved = (await _until(discovery, (rows) => rows.single.host.isNotEmpty)).single;
    expect(resolved, found, reason: 'the same row all along');
    expect(resolved.name, 'TV');
  });

  test('a service that does not answer waits behind the others, and is not taken for a stuck resolver', () async {
    final network = _Network(
      (name, attempt) => switch (name) {
        'Silent' => null,
        'Flaky' => attempt < 3 ? _failed : _resolved(name, id: 'flaky', addresses: ['192.168.1.21']),
        _ => _resolved(name, id: 'fine', addresses: ['192.168.1.22']),
      },
      present: {'Silent': {}, 'Flaky': {}, 'Fine': {}},
    );
    final discovery = _discovery(network);
    await discovery.start();

    final rows = await _until(discovery, (rows) => rows.where((d) => d.host.isNotEmpty).length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 300)); // past the last timeout
    // Each is asked once before any is asked again; a failure waits a moment, so the next goes first
    expect(network.asked, ['Silent', 'Flaky', 'Fine', 'Silent', 'Flaky', 'Silent', 'Flaky']);
    expect([for (final d in rows) d.host], ['', '192.168.1.21', '192.168.1.22']);
    expect(network.browsers, hasLength(1), reason: 'the others answered: one device is silent, not the resolver');
  });

  test('a failed resolve is asked again a little later, then a little more, not at once', () async {
    final network = _Network(
      (name, attempt) => attempt < 3 ? _failed : _resolved(name, id: 'abc', addresses: ['192.168.1.20']),
      present: {'Chromecast-abc': {}},
    );
    final discovery = _discovery(network);
    await discovery.start();

    await _until(discovery, (rows) => rows.single.host.isNotEmpty);
    final at = network.askedAt;
    expect(at, hasLength(3));
    expect(at[1] - at[0], greaterThanOrEqualTo(const Duration(milliseconds: 15)));
    expect(at[2] - at[1], greaterThanOrEqualTo(const Duration(milliseconds: 50)));
  });

  test('the same Chromecast found twice is one row, and speaker groups and speakers are left out', () async {
    final network = _Network(
      (name, _) => switch (name) {
        'Old-name' => _resolved(name, id: 'abc', fn: 'TV'),
        'New-name' => _resolved(name, id: 'abc', fn: 'TV', addresses: ['192.168.1.21']),
        'Some-speaker' => _resolved(name, id: 'sp', fn: 'Bedroom', md: 'Google Home', ca: '2052'),
        _ => _resolved(name, id: 'group', fn: 'Kitchen', md: 'Google Cast Group', addresses: ['192.168.1.22']),
      },
      present: {
        'Old-name': {},
        'New-name': {},
        'Some-group': {},
        'Some-speaker': {},
        'Known-group': {'id': 'g2', 'fn': 'Upstairs', 'md': 'Google Cast Group'},
        'Known-speaker': {'id': 's2', 'fn': 'Kitchen', 'md': 'Google Nest Mini', 'ca': '2052'},
      },
    );
    final discovery = _discovery(network);
    await discovery.start();

    final found = await _until(discovery, (rows) => rows.length == 4);
    expect([for (final d in found) d.name], ['Old-name', 'New-name', 'Some-group', 'Some-speaker']);

    final rows = await _until(discovery, (rows) => rows.length == 1 && rows.single.host.isNotEmpty);
    expect(rows.single.id, 'abc');
    expect(rows.single.host, '192.168.1.21', reason: 'the row with an address wins');
    expect(network.asked, [
      'Old-name',
      'New-name',
      'Some-group',
      'Some-speaker',
    ], reason: 'one known to play audio only is not resolved');
  });

  test('with no IPv4 among its addresses, its host name is looked up', () async {
    final looked = <String>[];
    final network = _Network(
      (name, _) => name == 'Gone'
          ? _resolved(name, id: 'gone', addresses: ['fe80::1'], hostname: 'gone.local')
          : _resolved(name, id: 'here', addresses: ['fe80::2'], hostname: 'here.local'),
      present: {'Gone': {}, 'Here': {}},
    );
    final discovery = _discovery(
      network,
      lookup: (host) async {
        looked.add(host);
        if (host == 'gone.local') throw const SocketException('no such host');
        return [InternetAddress('fe80::3'), InternetAddress('192.168.1.30')];
      },
    );
    await discovery.start();

    final rows = await _until(discovery, (rows) => rows.any((d) => d.host.isNotEmpty));
    expect(looked, ['gone.local', 'here.local']);
    expect([for (final d in rows) (d.id, d.host)], [('gone', ''), ('here', '192.168.1.30')]);
    expect(network.asked, ['Gone', 'Here'], reason: 'resolved, even with no address: not asked again');
  });

  test('a resolver that never answers gets a new browser, which finds and resolves again', () async {
    final network = _Network(
      (name, attempt) => attempt <= 3 ? null : _resolved(name, id: 'abc', addresses: ['192.168.1.20']),
      present: {'Chromecast-abc': {}},
    );
    final discovery = _discovery(network);
    await discovery.start();

    final rows = await _until(discovery, (rows) => rows.single.host.isNotEmpty);
    expect(rows.single.id, 'abc');
    expect(network.asked, ['Chromecast-abc', 'Chromecast-abc', 'Chromecast-abc', 'Chromecast-abc']);
    expect(network.browsers, hasLength(2));
    expect(network.browsers.first.stopped, isTrue);
    expect(network.browsers.last.stopped, isFalse);
  });

  test('a resolver still stuck after that is left as it is until the next start', () async {
    final sixth = Completer<void>(), twelfth = Completer<void>();
    final network = _Network((name, attempt) {
      if (attempt == 6) sixth.complete();
      if (attempt == 12) twelfth.complete();
      return null;
    }, present: {'Chromecast-abc': {}});
    final discovery = _discovery(network);
    await discovery.start();

    await sixth.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 500)); // past the last timeout, and then some
    expect(network.asked, hasLength(6));
    expect(network.browsers, hasLength(2));
    expect([for (final d in await discovery.devices.first) (d.id, d.host)], [('Chromecast-abc', '')]);

    // The next start browses anew, and may start afresh once more
    await discovery.stop();
    await discovery.start();
    await twelfth.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(network.asked, hasLength(12));
    expect(network.browsers, hasLength(4));
  });

  test('after a new browser, services never asked go before the ones that went unanswered', () async {
    final present = <String, Map<String, String>>{'Silent-1': {}, 'Silent-2': {}};
    final network = _Network(
      (name, _) => name == 'Late' ? _resolved(name, id: 'late', addresses: ['192.168.1.30']) : null,
      present: present,
    );
    final discovery = _discovery(network);
    await discovery.start();
    present['Late'] = {}; // there for the next browser to find

    await _until(discovery, (rows) => rows.any((d) => d.host.isNotEmpty));
    expect(network.browsers, hasLength(2), reason: 'two services left unanswered look like a stuck resolver');
    expect(network.asked.take(3), ['Silent-1', 'Silent-2', 'Late']);
  });

  test('failures bonsoir reports late, for resolves that timed out, are not held against the one asked now', () async {
    final network = _Network(
      // A never answers in time. Each of its resolves fails at last just as B is asked, and
      // bonsoir does not say whose failure it is; B is answered once they are all in
      (name, attempt) => name == 'A'
          ? null
          : attempt <= 3
          ? _failed
          : _resolved(name, id: 'b', addresses: ['192.168.1.21']),
      present: {'A': {}, 'B': {}},
    );
    final discovery = _discovery(network);
    await discovery.start();

    final rows = await _until(discovery, (rows) => rows.any((d) => d.host.isNotEmpty));
    expect(rows.last.host, '192.168.1.21');
    expect(network.asked.where((n) => n == 'A'), hasLength(3));
    expect(network.asked.where((n) => n == 'B'), hasLength(4), reason: 'three failures that may be A\'s, then B');
    expect(network.browsers, hasLength(1));
  });

  test('a service gone leaves the list', () async {
    final network = _Network((name, _) => _resolved(name, id: name), present: {'A': {}, 'B': {}});
    final discovery = _discovery(network);
    await discovery.start();
    await _until(discovery, (rows) => rows.length == 2);

    network.emit(const CastServiceEvent(CastServiceChange.lost, 'A'));
    expect([for (final d in await discovery.devices.first) d.id], ['B']);
  });

  test('a service gone while it is resolved is not asked for again', () async {
    late final _Network network;
    network = _Network((name, _) {
      scheduleMicrotask(() => network.emit(CastServiceEvent(CastServiceChange.lost, name)));
      return null;
    }, present: {'A': {}});
    final discovery = _discovery(network);
    await discovery.start();

    await _until(discovery, (rows) => network.asked.isNotEmpty && rows.isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 500)); // past a resolve timeout
    expect(network.asked, ['A']);
    expect(network.browsers, hasLength(1), reason: 'the resolver answered nothing, but it is not stuck');
  });

  test('start is idempotent; kept alive (Windows), stop leaves the browser running', () async {
    final network = _Network(
      (name, _) => _resolved(name, id: 'abc', addresses: ['192.168.1.20']),
      present: {'A': {}},
    );
    final discovery = _discovery(network, keepAlive: true);
    await Future.wait([discovery.start(), discovery.start()]);
    await _until(discovery, (rows) => rows.single.host.isNotEmpty);

    await discovery.stop();
    await discovery.start();
    expect(network.browsers, hasLength(1));
    expect(network.browsers.single.stopped, isFalse);
    expect([for (final d in await discovery.devices.first) d.host], ['192.168.1.20']);
  });

  test('kept alive, one that could not be resolved is asked again when announced, and at the next start', () async {
    var up = false;
    final network = _Network(
      (name, _) => up ? _resolved(name, id: 'abc', addresses: ['192.168.1.20']) : _failed,
      present: {
        'Chromecast-abc': {'id': 'abc'},
      },
    );
    final discovery = _discovery(network, keepAlive: true);
    await discovery.start();

    await _eventually(() => network.asked.length == 3);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(network.asked, hasLength(3));
    expect((await discovery.devices.first).single.host, '');

    // Announced again (Windows passes on every answer it hears as an update), still failing
    network.emit(const CastServiceEvent(CastServiceChange.updated, 'Chromecast-abc', txt: {'id': 'abc'}));
    await _eventually(() => network.asked.length == 6);

    // It comes up while nobody looks: nothing is resolved until the next start
    up = true;
    await discovery.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(network.asked, hasLength(6));
    await discovery.start();
    final rows = await _until(discovery, (rows) => rows.single.host.isNotEmpty);
    expect(rows.single.host, '192.168.1.20');
    expect(network.asked, hasLength(7));
    expect(network.browsers, hasLength(1));
  });

  test('kept alive, a known address is asked for again at the next start: Windows passes on the old one', () async {
    var address = '192.168.1.20';
    final network = _Network(
      (name, _) => name == 'Chromecast-abc'
          ? _resolved(name, id: 'abc', addresses: [address])
          : _resolved(name, id: 'xyz', addresses: ['192.168.1.30']),
      present: {
        'Chromecast-abc': {'id': 'abc'},
      },
    );
    final discovery = _discovery(network, keepAlive: true);
    await discovery.start();
    await _until(discovery, (rows) => rows.single.host == '192.168.1.20');

    // It got a new address overnight; announced again, it comes with the one Windows had
    address = '192.168.1.21';
    network.emit(
      const CastServiceEvent(
        CastServiceChange.updated,
        'Chromecast-abc',
        txt: {'id': 'abc'},
        addresses: ['192.168.1.20'],
      ),
    );
    await discovery.stop();
    // Found after the stop: not resolved before the next start either
    network.emit(const CastServiceEvent(CastServiceChange.found, 'Chromecast-xyz', txt: {'id': 'xyz'}));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(network.asked, ['Chromecast-abc']);
    expect([for (final d in await discovery.devices.first) d.host], ['192.168.1.20', '']);

    await discovery.start();
    expect((await discovery.devices.first).first.host, '192.168.1.20', reason: 'kept while it is asked again');
    final rows = await _until(discovery, (rows) => rows.first.host == '192.168.1.21' && rows.last.host.isNotEmpty);
    expect([for (final d in rows) (d.id, d.host)], [('abc', '192.168.1.21'), ('xyz', '192.168.1.30')]);
    expect(network.asked, hasLength(3));
    expect(network.browsers, hasLength(1));
  });

  test('elsewhere, stop ends the browser and forgets the rows; start browses anew', () async {
    final network = _Network(
      (name, _) => _resolved(name, id: 'abc', addresses: ['192.168.1.20']),
      present: {'A': {}},
    );
    final discovery = _discovery(network);
    await discovery.start();
    await _until(discovery, (rows) => rows.isNotEmpty);

    await discovery.stop();
    expect(network.browsers.single.stopped, isTrue);
    expect(await discovery.devices.first, isEmpty);

    await discovery.start();
    expect(network.browsers, hasLength(2));
    await _until(discovery, (rows) => rows.isNotEmpty && rows.single.host.isNotEmpty);
  });

  test('a browser that cannot start finds nothing, and the next start tries again', () async {
    var fail = true;
    final network = _Network(
      (name, _) => _resolved(name, id: 'abc', addresses: ['192.168.1.20']),
      present: {'A': {}},
    );
    final discovery = BonsoirCastDiscovery(
      browser: () => fail ? _BrokenBrowser() : network.newBrowser(),
      keepAlive: true,
      resolveAfter: const Duration(milliseconds: 20),
    );
    await discovery.start();
    expect(await discovery.devices.first, isEmpty);

    fail = false;
    await discovery.start();
    await _until(discovery, (rows) => rows.isNotEmpty && rows.single.host.isNotEmpty);
  });

  test('a browser that stops on its own drops its rows, and a fresh one starts at once, once per start', () async {
    final network = _Network(
      (name, _) => _resolved(name, id: 'abc', addresses: ['192.168.1.20']),
      present: {'A': {}},
    );
    final discovery = _discovery(network, keepAlive: true);
    await discovery.start();
    await _until(discovery, (rows) => rows.isNotEmpty && rows.single.host.isNotEmpty);

    final emptied = _until(discovery, (rows) => rows.isEmpty);
    network.browsers.last.end();
    await emptied;
    expect(network.browsers, hasLength(2));
    expect(network.browsers.first.stopped, isTrue);
    await _until(discovery, (rows) => rows.isNotEmpty && rows.single.host.isNotEmpty);

    // The fresh one gives up too: nothing more until the next start
    network.browsers.last.end();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(network.browsers, hasLength(2));
    expect(await discovery.devices.first, isEmpty);

    await discovery.stop();
    await discovery.start();
    expect(network.browsers, hasLength(3));
    await _until(discovery, (rows) => rows.isNotEmpty && rows.single.host.isNotEmpty);
  });

  group('through bonsoir', () {
    BonsoirCastDiscovery bonsoir() => BonsoirCastDiscovery(
      keepAlive: true,
      resolveAfter: const Duration(milliseconds: 20),
      resolveTimeout: const Duration(milliseconds: 150),
    );

    test('a browse the platform gives up on is started afresh; other native errors leave it be', () async {
      final native = _NativeBonsoir((discovery, _) {
        discovery
          ..send('discoveryStarted')
          ..send('discoveryServiceFound', _nativeService('Chromecast-abc'));
      });
      addTearDown(native.dispose);
      final discovery = bonsoir();
      await discovery.start();
      await _until(discovery, (rows) => rows.length == 1 && rows.single.host == '192.168.1.20');
      expect(native.resolved, ['Chromecast-abc']);

      // A resolve or a clean-up that failed natively: browsing goes on
      native.discoveries.single.sink!.error(code: 'discoveryError', message: 'service info callback failed');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(native.discoveries, hasLength(1));

      // Windows gives up on a browse with an error, then a stopped event nobody asked for
      native.discoveries.single.sink!.error(code: 'discoveryError', message: '1460');
      native.discoveries.single.send('discoveryStopped');
      await _eventually(() => native.discoveries.length == 2);
      expect(native.discoveries.first.stopped, isTrue, reason: 'let go of natively as well');
      await _until(discovery, (rows) => rows.length == 1 && rows.single.host == '192.168.1.20');
    });

    test('kept alive, a browse that never says it started, or fails before it does, is started afresh', () async {
      final native = _NativeBonsoir((discovery, n) {
        switch (n) {
          case 1: // Windows: the browse failed at once, and what bonsoir was about to send is dropped
            break;
          case 2: // the platform says it could not start
            discovery.sink!.error(code: 'discoveryError', message: 'start failed');
          default:
            discovery
              ..send('discoveryStarted')
              ..send('discoveryServiceFound', _nativeService('Chromecast-abc'));
        }
      });
      addTearDown(native.dispose);
      final discovery = bonsoir();
      await discovery.start();

      await _eventually(() => native.discoveries.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(native.discoveries, hasLength(2), reason: 'one fresh browser per start');
      expect(await discovery.devices.first, isEmpty);

      await discovery.stop();
      await discovery.start();
      await _until(discovery, (rows) => rows.length == 1 && rows.single.host == '192.168.1.20');
      expect(native.discoveries, hasLength(3));
    });
  });

  test('devices are the same device by id', () {
    const a = ChromecastDevice(id: 'abc', name: 'TV', host: '');
    const b = ChromecastDevice(id: 'abc', name: 'Living Room TV', host: '192.168.1.20');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(const ChromecastDevice(id: 'xyz', name: 'TV', host: '')));
  });

  group('parseCastAddress', () {
    test('an IPv4 address, with or without a port', () {
      final plain = parseCastAddress('192.168.1.20')!;
      expect(
        (plain.id, plain.name, plain.host, plain.port),
        ('192.168.1.20:8009', '192.168.1.20', '192.168.1.20', 8009),
      );
      final ported = parseCastAddress('  192.168.1.20:8010 ')!;
      expect((ported.id, ported.host, ported.port), ('192.168.1.20:8010', '192.168.1.20', 8010));
    });

    test('a host name, with or without a port', () {
      final name = parseCastAddress('Living-Room.local')!;
      expect(
        (name.id, name.name, name.host, name.port),
        ('living-room.local:8009', 'living-room.local', 'living-room.local', 8009),
      );
      expect(parseCastAddress('tv:8009')?.host, 'tv');
    });

    test('nothing usable', () {
      for (final text in [
        '',
        '   ',
        '192.168.1',
        '256.1.1.1',
        '192.168.1.20:',
        '192.168.1.20:0',
        '192.168.1.20:65536',
        '192.168.1.20:80a',
        '192.168.1.20:+80',
        ':8009',
        'fe80::1',
        '[::1]:8009',
        'http://192.168.1.20',
        'living room',
        '-tv.local',
        'tv..local',
      ]) {
        expect(parseCastAddress(text), isNull, reason: text);
      }
    });
  });
}

class _BrokenBrowser implements CastBrowser {
  @override
  Future<void> start(void Function(CastServiceEvent event) onEvent, void Function() onEnd) async =>
      throw StateError('no DNS-SD here');

  @override
  Future<void> stop() async {}

  @override
  Future<void> resolve(String name) async {}
}

/// Bonsoir's platform side, played by the test: the method channel the plugin calls, and an event
/// channel per discovery. Every resolve is answered with 192.168.1.20.
class _NativeBonsoir {
  _NativeBonsoir(this.onStart) {
    _messenger.setMockMethodCallHandler(_channel, _handle);
  }

  static const _channel = MethodChannel('fr.skyost.bonsoir');
  static TestDefaultBinaryMessenger get _messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// What starting the [n]th discovery (from 1) does.
  final void Function(_NativeDiscovery discovery, int n) onStart;
  final discoveries = <_NativeDiscovery>[];
  final resolved = <String>[];

  Future<Object?> _handle(MethodCall call) async {
    final arguments = Map<String, Object?>.from(call.arguments as Map);
    final id = arguments['id']! as int;
    if (call.method == 'discovery.initialize') {
      final discovery = _NativeDiscovery(id);
      discoveries.add(discovery);
      _messenger.setMockStreamHandler(
        EventChannel('fr.skyost.bonsoir.discovery.$id'),
        MockStreamHandler.inline(onListen: (_, sink) => discovery.sink = sink),
      );
      return true;
    }
    final discovery = discoveries.lastWhere((d) => d.id == id);
    switch (call.method) {
      case 'discovery.start':
        onStart(discovery, discoveries.indexOf(discovery) + 1);
      case 'discovery.resolveService':
        final name = arguments['name']! as String;
        resolved.add(name);
        discovery.send('discoveryServiceResolved', _nativeService(name, addresses: ['192.168.1.20']));
      case 'discovery.stop':
        discovery.stopped = true;
    }
    return true;
  }

  void dispose() {
    _messenger.setMockMethodCallHandler(_channel, null);
    for (final discovery in discoveries) {
      _messenger.setMockStreamHandler(EventChannel('fr.skyost.bonsoir.discovery.${discovery.id}'), null);
    }
  }
}

class _NativeDiscovery {
  _NativeDiscovery(this.id);

  final int id;
  MockStreamHandlerEventSink? sink;
  var stopped = false;

  void send(String event, [Map<String, Object?>? service]) => sink!.success({'id': event, 'service': ?service});
}

/// A service as bonsoir's platform side encodes it.
Map<String, Object?> _nativeService(String name, {List<String> addresses = const []}) => {
  'service.name': name,
  'service.type': '_googlecast._tcp',
  'service.port': 8009,
  'service.attributes': {'id': 'abc', 'fn': 'TV', 'md': 'Chromecast', 'ca': '4101'},
  if (addresses.isNotEmpty) 'service.hostAddresses': addresses,
};
