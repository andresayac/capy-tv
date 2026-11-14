import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import '../platform.dart';

/// A Chromecast found on the local network, or one typed by hand.
class ChromecastDevice {
  const ChromecastDevice({required this.id, required this.name, required this.host, this.port = 8009, this.model = ''});

  /// The id it announces (TXT id), or "host:port" for one typed by hand. Until its TXT record is
  /// known, one found goes by the id its service name ends in ("Chromecast-<32 hex digits>"), else
  /// by its service name.
  final String id;

  /// The name its owner gave it (TXT fn), else the service name, else the host.
  final String name;

  /// Its model (TXT md), such as "Chromecast Ultra"; empty when not known.
  final String model;

  /// An IPv4 literal, or a name typed by hand. Empty for one found whose address is not known:
  /// it is still being resolved, or it could not be.
  final String host;
  final int port;

  @override
  bool operator ==(Object other) => other is ChromecastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ChromecastDevice($id, $name, $host:$port)';
}

/// Finds Chromecasts. [devices] gives the list as it is when listened to, then the whole list
/// again on every change, in the order found.
abstract class CastDiscovery {
  Stream<List<ChromecastDevice>> get devices;

  Future<void> start();

  Future<void> stop();
}

/// The Chromecast typed in [text]: "192.168.1.20", "192.168.1.20:8009" or a host name, with or
/// without a port. Null when it is not usable, such as an IPv6 address or a mistyped IPv4.
ChromecastDevice? parseCastAddress(String text) {
  var host = text.trim().toLowerCase();
  var port = 8009;
  final colon = host.lastIndexOf(':');
  if (colon >= 0) {
    final digits = host.substring(colon + 1);
    final p = RegExp(r'^\d{1,5}$').hasMatch(digits) ? int.parse(digits) : 0;
    if (p < 1 || p > 65535) return null;
    port = p;
    host = host.substring(0, colon);
  }
  final ip = InternetAddress.tryParse(host);
  if (ip != null ? ip.type != InternetAddressType.IPv4 : !_isHostName(host)) return null;
  return ChromecastDevice(id: '$host:$port', name: host, host: host, port: port);
}

/// RFC 1123 host names. One whose last label is all digits is a mistyped IPv4, not a name.
bool _isHostName(String host) {
  if (host.isEmpty || host.length > 253) return false;
  final labels = host.split('.');
  final label = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
  return labels.every(label.hasMatch) && !RegExp(r'^\d+$').hasMatch(labels.last);
}

/// What a browser says about a `_googlecast._tcp` service: found, changed (such as its TXT record
/// coming in), resolved with its addresses, a resolve that failed, or gone.
enum CastServiceChange { found, updated, resolved, resolveFailed, lost }

/// A [CastServiceChange] to the service named [name] (its instance name), with what is known of
/// it so far. A failed resolve has no name: bonsoir does not say which one failed.
class CastServiceEvent {
  const CastServiceEvent(
    this.change,
    this.name, {
    this.txt = const {},
    this.addresses = const [],
    this.hostname,
    this.port = 0,
  });

  final CastServiceChange change;
  final String name;
  final Map<String, String> txt;

  /// IPv4 and/or IPv6 literals; empty until resolved.
  final List<String> addresses;

  /// Its mDNS name, such as "abc.local", where the platform gives one.
  final String? hostname;

  /// 0 until resolved.
  final int port;
}

/// The network side of [BonsoirCastDiscovery]: bonsoir in the app, a fake in tests. Each one is
/// started once at most; browsing again takes a new one.
abstract class CastBrowser {
  /// Browses `_googlecast._tcp` until [stop]. [onEvent] hears what it finds, and [onEnd] that it
  /// stopped browsing on its own (the platform failed, or gave up).
  Future<void> start(void Function(CastServiceEvent event) onEvent, void Function() onEnd);

  Future<void> stop();

  /// Asks for the addresses of the service [name]: a resolved or resolveFailed event answers, or
  /// nothing does.
  Future<void> resolve(String name);
}

/// Chromecasts on the local network, through bonsoir (NsdManager on Android, DNS-SD on Windows).
///
/// A row shows as soon as its service is found, named by the service name. Its address is asked
/// for a second later, one service at a time: bonsoir's resolver stalls when asked many at once
/// (Bonsoir issues 106, 121 and 155). A service that does not answer waits behind the others. A
/// resolver that answers nothing at all is started afresh, once per [start], except where
/// [keepAlive] holds; a browser that stops on its own is started afresh too.
class BonsoirCastDiscovery implements CastDiscovery {
  BonsoirCastDiscovery({
    CastBrowser Function()? browser,
    bool? keepAlive,
    Future<List<InternetAddress>> Function(String host)? lookup,
    this.resolveAfter = const Duration(seconds: 1),
    this.resolveTimeout = const Duration(seconds: 5),
  }) : _newBrowser = browser,
       keepAlive = keepAlive ?? isWindows,
       _lookup = lookup ?? ((host) => InternetAddress.lookup(host, type: InternetAddressType.IPv4));

  final CastBrowser Function()? _newBrowser;

  /// Browses from the first [start] for the rest of the run, [stop] or not: on Windows, starting
  /// and stopping bonsoir again and again crashes in native code (Bonsoir issue 159). Nothing is
  /// resolved between a [stop] and the next [start].
  final bool keepAlive;

  final Future<List<InternetAddress>> Function(String host) _lookup;

  /// How long after a service is found its address is asked for, and how long an answer (or a
  /// host name lookup) is waited for. A failed resolve is asked again [resolveAfter] later, then
  /// three times that. Tests shorten them.
  final Duration resolveAfter, resolveTimeout;

  static const _retries = 2;

  final _entries = <String, _Entry>{}; // by service name, in the order found
  final _changes = StreamController<List<ChromecastDevice>>.broadcast();
  var _list = const <ChromecastDevice>[];
  CastBrowser? _browser;
  Future<void>? _started;
  var _active = false; // between start and stop
  var _fresh = false; // a fresh browser is still allowed in this start
  var _resolving = false;
  _Entry? _asked; // the service being resolved
  Completer<_Answer?>? _answer; // null when nothing answered
  final _stale = <String, int>{}; // resolves that timed out but may still be answered, by service
  final _silent = <String>{}; // services left unanswered since the resolver last answered anything
  var _silentAsks = 0; // resolves in a row left unanswered

  @override
  Stream<List<ChromecastDevice>> get devices => Stream.multi((listener) {
    listener.add(_list);
    final changes = _changes.stream.listen(listener.add);
    listener.onCancel = changes.cancel;
  });

  @override
  Future<void> start() {
    if (!_active) {
      _active = true;
      _fresh = true;
      _forgetResolver();
      // Kept alive, the rows found before are still here. Those without an address are asked for
      // again, and those with one too: Windows hands on the address it had, which may be stale
      for (final entry in _entries.values) {
        _queue(entry);
      }
    }
    return _started ??= _open();
  }

  /// Starts a new browser. One that cannot start finds nothing, and the next [start] tries again.
  /// Kept alive, one that never says it started counts as ended, or it would stay dead for the run.
  Future<void> _open() async {
    final browser = _browser =
        _newBrowser?.call() ?? _BonsoirBrowser(startedWithin: keepAlive ? resolveTimeout * 2 : null);
    try {
      await browser.start((event) {
        if (_browser == browser) _onEvent(event);
      }, () => _ended(browser));
    } on Object {
      if (_browser == browser) {
        _browser = null;
        _started = null;
      }
    }
  }

  @override
  Future<void> stop() async {
    _active = false;
    if (keepAlive) {
      for (final entry in _entries.values) {
        entry.endRound();
      }
      return;
    }
    final started = _started, browser = _browser;
    _started = null;
    _browser = null;
    _forget();
    await started;
    if (browser != null) await _quietly(browser.stop);
  }

  /// [browser] stopped browsing on its own. Its rows go, since nothing will say when one is gone.
  /// A fresh browser starts at once, once per [start]; else at the next [start].
  void _ended(CastBrowser browser) {
    if (_browser != browser) return;
    _browser = null;
    _started = null;
    _forget();
    unawaited(_quietly(browser.stop));
    if (_active && _fresh) {
      _fresh = false;
      _started = _open();
    }
  }

  /// Drops the rows and the resolve waited for.
  void _forget() {
    for (final entry in _entries.values) {
      entry.endRound();
    }
    _entries.clear();
    _forgetResolver();
    _settle(null);
    _publish();
  }

  void _forgetResolver() {
    _stale.clear();
    _heard();
  }

  void _onEvent(CastServiceEvent event) {
    switch (event.change) {
      case CastServiceChange.found || CastServiceChange.updated || CastServiceChange.resolved:
        final entry = _entries.putIfAbsent(event.name, () => _Entry(event.name));
        final had = entry.host;
        entry.take(event);
        if (event.change == CastServiceChange.resolved) {
          _resolved(entry);
        } else if (entry == _asked && had == null && entry.host != null) {
          _settle(_Answer.resolved); // Android 14 and later can bring the address in an update
        } else if (entry.host == null && !entry.answered) {
          _queue(entry); // found, or announced again after it could not be resolved
        }
      case CastServiceChange.resolveFailed:
        _heard();
        // Unnamed: while another service's resolve that timed out may still be answered, the
        // failure may be that one's, and is not held against the service asked now
        final late = _stale.keys.where((name) => name != _asked?.name).firstOrNull;
        if (late != null) _unstale(late);
        _settle(late == null ? _Answer.failed : _Answer.maybeFailed);
      case CastServiceChange.lost:
        final entry = _entries.remove(event.name);
        _stale.remove(event.name);
        entry?.endRound();
        if (entry != null && entry == _asked) _settle(_Answer.failed);
    }
    _publish();
  }

  /// A resolve answered for [entry]: the one asked, or one that timed out earlier.
  void _resolved(_Entry entry) {
    _heard();
    entry
      ..answered = true
      ..silent = false;
    if (entry == _asked) {
      _settle(_Answer.resolved);
    } else {
      if (_stale.containsKey(entry.name)) _unstale(entry.name);
      entry.endRound();
    }
    if (entry.host == null) unawaited(_lookupHost(entry));
  }

  /// Starts a round of resolves for [entry], [resolveAfter] from now, unless one is under way. One
  /// that went unanswered before waits twice that, so that the others go first.
  void _queue(_Entry entry) {
    if (!_active || entry.inRound || entry.audioOnly) return;
    entry
      ..inRound = true
      ..refresh = entry.host != null
      ..asks = 0
      ..due = Timer(entry.silent ? resolveAfter * 2 : resolveAfter, () => _ready(entry));
  }

  void _ready(_Entry entry) {
    entry.ready = true;
    unawaited(_resolveQueued());
  }

  /// Resolves the services queued, one at a time.
  Future<void> _resolveQueued() async {
    if (_resolving) return;
    _resolving = true;
    for (var entry = _next(); entry != null; entry = _next()) {
      await _ask(entry);
    }
    _resolving = false;
  }

  /// The service to ask for next: the one asked least so far, then one that did not go unanswered
  /// before, then the first found.
  _Entry? _next() {
    if (!_active || _browser == null) return null;
    _Entry? next;
    for (final entry in _entries.values) {
      if (entry.inRound && (entry.audioOnly || (entry.host != null && !entry.refresh))) entry.endRound();
      if (!entry.ready) continue;
      if (next == null || entry.asks < next.asks || (entry.asks == next.asks && next.silent && !entry.silent)) {
        next = entry;
      }
    }
    return next;
  }

  /// Asks for [entry]'s address once. A failed resolve is asked again a little later, and one that
  /// maybe failed does not count; one nobody answers goes behind the services asked fewer times.
  Future<void> _ask(_Entry entry) async {
    final browser = _browser!;
    entry
      ..ready = false
      ..asks += 1;
    final waiting = _answer = Completer<_Answer?>();
    _asked = entry;
    unawaited(
      Future.sync(() => browser.resolve(entry.name)).catchError((Object _) {
        if (!waiting.isCompleted) waiting.complete(_Answer.failed);
      }),
    );
    final answer = await waiting.future.timeout(resolveTimeout, onTimeout: () => null);
    _asked = null;
    _answer = null;
    if (_browser != browser || _entries[entry.name] != entry) return; // stopped, ended, restarted or gone
    entry.silent = answer == null;
    if (answer == _Answer.resolved) entry.answered = true;
    if (answer == _Answer.maybeFailed) entry.asks -= 1;
    if (answer == null) {
      _stale.update(entry.name, (n) => n + 1, ifAbsent: () => 1);
      _silent.add(entry.name);
      _silentAsks++;
    }
    if (!entry.inRound) return; // kept alive, and stopped meanwhile
    if (answer == _Answer.resolved || entry.asks > _retries) {
      entry.endRound();
    } else if (answer != null) {
      entry.due = Timer(resolveAfter * (entry.asks > 1 ? 3 : 1), () => _ready(entry));
    } else {
      entry.ready = true;
    }
    if (answer == null && _looksStuck()) _restart(browser);
  }

  /// Answers the resolve waited for, if any.
  void _settle(_Answer? answer) {
    final waiting = _answer;
    if (waiting != null && !waiting.isCompleted) waiting.complete(answer);
  }

  /// The resolver answered something: it is not stuck.
  void _heard() {
    _silent.clear();
    _silentAsks = 0;
  }

  void _unstale(String name) {
    final left = (_stale[name] ?? 0) - 1;
    if (left > 0) {
      _stale[name] = left;
    } else {
      _stale.remove(name);
    }
  }

  /// Nothing has answered since every service waiting was asked: two services left unanswered,
  /// or one three times, look like a stuck resolver rather than one silent device.
  bool _looksStuck() =>
      (_silent.length > 1 || _silentAsks > _retries) &&
      !_entries.values.any((e) => e.inRound && e.asks == 0 && !e.audioOnly);

  /// Bonsoir's resolver may be stuck for good, and only a new browser frees it. The rows stay; the
  /// new browser finds them again, and those without an address are resolved anew, the ones that
  /// went unanswered last.
  void _restart(CastBrowser stuck) {
    if (keepAlive || !_fresh || _browser != stuck) return;
    _fresh = false;
    for (final entry in _entries.values) {
      entry.endRound();
    }
    _forgetResolver();
    unawaited(_quietly(stuck.stop));
    _started = _open();
  }

  /// Resolved without an IPv4: its host name is looked up instead.
  Future<void> _lookupHost(_Entry entry) async {
    final hostname = entry.hostname;
    if (hostname == null || entry.lookingUp) return;
    entry.lookingUp = true;
    final host = await _lookupIPv4(hostname);
    entry.lookingUp = false;
    if (host == null || _entries[entry.name] != entry) return;
    entry.host ??= host;
    _publish();
  }

  Future<String?> _lookupIPv4(String hostname) async {
    try {
      final found = await _lookup(hostname).timeout(resolveTimeout);
      return found.where((a) => a.type == InternetAddressType.IPv4).firstOrNull?.address;
    } on Object {
      return null;
    }
  }

  void _publish() {
    final rows = <String, ChromecastDevice>{};
    for (final entry in _entries.values) {
      if (entry.audioOnly) continue;
      final device = entry.device;
      final had = rows[device.id];
      // One Chromecast found under two names: the row with an address wins, where the first was
      if (had == null || (had.host.isEmpty && device.host.isNotEmpty)) rows[device.id] = device;
    }
    _list = List.unmodifiable(rows.values);
    _changes.add(_list);
  }
}

/// How a resolve was answered. A failure is only maybe ours while one that timed out earlier may
/// still be answered: bonsoir does not say which one failed.
enum _Answer { resolved, failed, maybeFailed }

/// A service found, with what is known of it so far.
class _Entry {
  _Entry(this.name);

  final String name;
  var txt = const <String, String>{};
  var port = 0;
  String? hostname;
  String? host; // its IPv4, once known
  var answered = false; // a resolve answered, with an IPv4 or not
  var silent = false; // the last resolve asked for went unanswered
  var lookingUp = false; // its host name

  // A round of resolves: due a moment after it is queued, then up to three asks
  var inRound = false;
  var refresh = false; // its address is known, and asked for again in case it changed
  var ready = false; // it may be asked now
  var asks = 0;
  Timer? due;

  void endRound() {
    due?.cancel();
    due = null;
    inRound = false;
    ready = false;
  }

  /// Speaker groups and speakers, which play audio only: TXT md names a group, or TXT ca (its
  /// capabilities, as bits) lacks video out (bit 0).
  bool get audioOnly {
    if (txt['md'] == 'Google Cast Group') return true;
    final capabilities = int.tryParse(txt['ca'] ?? '');
    return capabilities != null && capabilities & 1 == 0;
  }

  /// Takes in what [event] tells; what it leaves out stays as it was.
  void take(CastServiceEvent event) {
    if (event.txt.isNotEmpty) txt = event.txt;
    if (event.port > 0) port = event.port;
    hostname = event.hostname ?? hostname;
    host = _firstIPv4(event.addresses) ?? host;
  }

  ChromecastDevice get device => ChromecastDevice(
    id: _nonEmpty(txt['id']) ?? _idIn(name) ?? name,
    name: _nonEmpty(txt['fn']) ?? name,
    model: txt['md'] ?? '',
    host: host ?? '',
    port: port > 0 ? port : 8009,
  );
}

String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

/// The TXT id a Google cast device puts at the end of its service name, such as
/// "Chromecast-Ultra-<32 hex digits>", so that its row keeps one id from the moment it is found.
String? _idIn(String serviceName) => RegExp(r'-([0-9a-fA-F]{32})$').firstMatch(serviceName)?.group(1)?.toLowerCase();

String? _firstIPv4(List<String> addresses) {
  for (final a in addresses) {
    final ip = InternetAddress.tryParse(a);
    if (ip != null && ip.type == InternetAddressType.IPv4) return ip.address;
  }
  return null;
}

Future<void> _quietly(Future<void> Function() f) async {
  try {
    await f();
  } on Object {
    // Already stopped, or the platform said no: nothing more to do
  }
}

/// [CastBrowser] through bonsoir.
class _BonsoirBrowser implements CastBrowser {
  _BonsoirBrowser({this.startedWithin});

  /// How long the platform has to say browsing started, where a browse that fails at once may
  /// say nothing at all (bonsoir on Windows drops what it was about to send).
  final Duration? startedWithin;

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _events;
  final _services = <String, BonsoirService>{}; // as bonsoir gave them, to resolve by name
  void Function()? _onEnd; // until it ends or is stopped
  Timer? _starting;

  @override
  Future<void> start(void Function(CastServiceEvent event) onEvent, void Function() onEnd) async {
    final discovery = _discovery = BonsoirDiscovery(type: '_googlecast._tcp', printLogs: false);
    _onEnd = onEnd;
    var started = false;
    await discovery.initialize();
    _events = discovery.eventStream?.listen(
      (event) {
        if (event is BonsoirDiscoveryStartedEvent) {
          started = true;
          return _starting?.cancel();
        }
        // Not asked for: stop() lets go of onEnd first
        if (event is BonsoirDiscoveryStoppedEvent) return _end();
        final change = switch (event) {
          BonsoirDiscoveryServiceFoundEvent() => CastServiceChange.found,
          BonsoirDiscoveryServiceUpdatedEvent() => CastServiceChange.updated,
          BonsoirDiscoveryServiceResolvedEvent() => CastServiceChange.resolved,
          BonsoirDiscoveryServiceResolveFailedEvent() => CastServiceChange.resolveFailed,
          BonsoirDiscoveryServiceLostEvent() => CastServiceChange.lost,
          _ => null,
        };
        final service = event.service;
        if (change == null) return;
        if (service == null) return onEvent(CastServiceEvent(change, ''));
        if (change == CastServiceChange.lost) {
          _services.remove(service.name);
        } else {
          _services[service.name] = service;
        }
        onEvent(
          CastServiceEvent(
            change,
            service.name,
            txt: service.attributes,
            addresses: service.hostAddresses,
            hostname: service.hostname,
            port: service.port,
          ),
        );
      },
      // Before it started, browsing failed. After, a resolve or a clean-up failed, and the rows
      // stay; a browse that fails then says so with a stopped event as well
      onError: (Object _) {
        if (!started) _end();
      },
      onDone: _end,
    );
    await discovery.start();
    final within = startedWithin;
    if (!started && within != null && _onEnd != null) _starting = Timer(within, _end);
  }

  void _end() {
    final onEnd = _onEnd;
    _onEnd = null;
    _starting?.cancel();
    onEnd?.call();
  }

  @override
  Future<void> stop() async {
    _onEnd = null;
    _starting?.cancel();
    await _events?.cancel();
    await _discovery?.stop();
  }

  @override
  Future<void> resolve(String name) async {
    final discovery = _discovery, service = _services[name];
    if (discovery == null || service == null) throw StateError('No service named $name');
    await discovery.serviceResolver.resolveService(service);
  }
}
