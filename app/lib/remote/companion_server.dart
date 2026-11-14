import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/backup.dart';
import '../data/playlists.dart';
import '../data/secrets.dart';
import '../data/settings.dart';
import '../data/source.dart';
import '../device.dart';
import '../sync/sync_client.dart';
import '../sync/sync_service.dart';
import 'companion_seal.dart';
import 'movie_night.dart';
import 'remote_input.dart';

/// Something a phone did through the companion page, for the app to tell the user.
sealed class CompanionEvent {
  const CompanionEvent();
}

class PlaylistReceived extends CompanionEvent {
  const PlaylistReceived(this.name, {this.noPassword = false});
  final String name;
  final bool noPassword; // saved, but not its password: the device's secure storage failed
}

class BackupReceived extends CompanionEvent {
  const BackupReceived(this.result);
  final ImportResult result;
}

class RemoteConnected extends CompanionEvent {
  const RemoteConnected();
}

class SyncSignedIn extends CompanionEvent {
  const SyncSignedIn(this.email);
  final String email;
}

/// A small web server on this device for the user's own phone. Scanning the QR the app shows
/// opens its page in the phone's browser, to add playlists with the phone's keyboard, use the
/// phone as a remote, sign this device in to the sync account, and move backups between devices.
/// Nothing goes through any outside server: it runs only while needed, only answers on the local
/// network, and every request must carry the session code from the QR, which changes every time
/// it starts. Passwords and backups travel sealed with a key that only the QR carries (see
/// [CompanionSeal]): the page is plain HTTP, and anyone on the network could read them otherwise.
class CompanionServer extends ChangeNotifier {
  CompanionServer._();

  static final instance = CompanionServer._();

  /// Fixed when free, so the address stays the same between sessions.
  static const preferredPort = 8765;
  static const _maxBody = 4 << 20; // a backup with a long history is well under this
  static const _maxFailures = 20;

  HttpServer? _server;
  String _host = '';
  String _token = '';
  String _guestToken = ''; // of whoever only came to vote: see [votingLink]
  var _seal = CompanionSeal.random();
  var _holds = 0;

  /// Wrong session codes by where they come from, each address forgotten [_failureMemory] after its
  /// last: the one guessing is locked out, not everybody. One count for all let a tab left open from
  /// an earlier session, retrying with its old code, lock out the phone that just scanned the new one.
  final _failures = <String, ({int count, DateTime last})>{};
  static const _failureMemory = Duration(minutes: 5);
  Timer? _stopTimer;
  final _sockets = <WebSocket>{};
  final _events = StreamController<CompanionEvent>.broadcast();
  AppSettings? _settings;
  Map<String, String> _strings = const {};

  /// Checks a playlist before saving it; replaceable in tests.
  @visibleForTesting
  Future<void> Function(Playlist) verify = (p) => p.verify();

  /// Where to listen when [hold] is not told: tests use the loopback, so no firewall asks.
  @visibleForTesting
  InternetAddress? bindOverride;

  Stream<CompanionEvent> get events => _events.stream;
  bool get running => _server != null;
  String get token => _token;

  /// Phones using this device as a remote right now.
  int get remotes => _sockets.length;

  /// The movie night being voted on, if any: phones see its titles and vote (see [MovieNight]).
  /// Pages open as remotes are told when it begins or ends, to show or hide their vote's tab.
  MovieNight? get night => _night;
  MovieNight? _night;
  set night(MovieNight? n) {
    if (identical(n, _night)) return;
    _night = n;
    final message = jsonEncode({'type': 'night', 'open': n != null});
    for (final s in _sockets) {
      s.add(message);
    }
  }

  /// Whether the device is on a local network a phone can reach.
  bool get reachable => _server != null && _host != InternetAddress.anyIPv4.address;

  /// The page to open on the phone, or null when not running. Without its key: typed by hand, it
  /// still works as a remote, but sends no passwords or backups (see [link]).
  Uri? get url => _server == null
      ? null
      : Uri(scheme: 'http', host: _host, port: _server!.port, path: '/', queryParameters: {'t': _token});

  /// The page as the QR code carries it, opened on [tab], with the key in the #fragment.
  Uri? link(String tab) => url?.replace(fragment: '$tab&k=${_seal.text}');

  /// The page for those in the room to vote on a movie night: without the key, and with a code that
  /// opens nothing else. Everyone there scans it; the backup, with every password, is not theirs.
  Uri? get votingLink => url?.replace(queryParameters: {'t': _guestToken}, fragment: 'night&guest');

  /// What seals passwords and backups in this session.
  @visibleForTesting
  CompanionSeal get seal => _seal;

  /// Keeps the server running while some screen needs it; pair with [release]. [strings] are the
  /// page's texts in the app's language; [bind] defaults to every local network interface.
  Future<void> hold({AppSettings? settings, Map<String, String>? strings, InternetAddress? bind}) async {
    _holds++;
    _stopTimer?.cancel();
    if (settings != null) _settings = settings;
    if (strings != null) _strings = strings;
    if (_server != null) return;
    final address = bind ?? bindOverride ?? InternetAddress.anyIPv4;
    HttpServer server;
    try {
      server = await HttpServer.bind(address, preferredPort);
    } on SocketException {
      server = await HttpServer.bind(address, 0);
    }
    _server = server;
    _host = address.isLoopback ? address.address : await localAddress() ?? address.address;
    _token = _newToken();
    _guestToken = _newToken();
    _seal = CompanionSeal.random();
    _failures.clear();
    server.listen(_handle);
    nowPlaying.addListener(_sendNowPlaying);
    notifyListeners();
  }

  /// The screen that needed the server is gone: stop once no phone is using it as a remote.
  void release() {
    if (_holds > 0) _holds--;
    _maybeStop();
  }

  void _maybeStop({bool remoteLeft = false}) {
    if (_holds > 0 || _sockets.isNotEmpty) return;
    _stopTimer?.cancel();
    // A phone used as a remote whose screen locked stops answering too: it has a while to come back
    // on its own, with the same code
    _stopTimer = Timer(remoteLeft ? const Duration(minutes: 5) : const Duration(seconds: 30), stop);
  }

  Future<void> stop() async {
    _stopTimer?.cancel();
    nowPlaying.removeListener(_sendNowPlaying);
    for (final s in _sockets.toList()) {
      await s.close();
    }
    _sockets.clear();
    await _server?.close(force: true);
    _server = null;
    _holds = 0;
    notifyListeners();
  }

  /// 8 characters a person can read off the screen and type, from an alphabet without look-alikes.
  static String _newToken() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(8, (_) => alphabet[r.nextInt(alphabet.length)]).join();
  }

  /// This device's address on the local network: a private IPv4, preferring Wi-Fi and Ethernet
  /// over virtual adapters (Hyper-V, VPNs, Docker...).
  static Future<String?> localAddress() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final virtual = RegExp(
      r'vethernet|virtual|vmware|vbox|docker|wsl|hyper-v|tap|tun|zerotier|tailscale',
      caseSensitive: false,
    );
    final physical = RegExp(r'wi-?fi|wlan|eth|^en\d|ethernet', caseSensitive: false);
    String? best;
    var bestScore = -100;
    for (final i in interfaces) {
      for (final a in i.addresses) {
        if (a.isLoopback || a.isLinkLocal) continue;
        final ip = a.address;
        final private =
            ip.startsWith('192.168.') || ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
        final score = (private ? 2 : 0) + (physical.hasMatch(i.name) ? 1 : 0) - (virtual.hasMatch(i.name) ? 4 : 0);
        if (score > bestScore) (best, bestScore) = (ip, score);
      }
    }
    return best;
  }

  bool _authorized(HttpRequest req, String token) {
    final given = req.uri.queryParameters['t'] ?? req.headers.value('x-session') ?? '';
    // Same time whatever the input, so the code cannot be guessed character by character
    var diff = given.length ^ token.length;
    for (var i = 0; i < token.length; i++) {
      diff |= token.codeUnitAt(i) ^ (i < given.length ? given.codeUnitAt(i) : 0);
    }
    return diff == 0;
  }

  static const _guestMay = {'GET /', 'GET /api/info', 'GET /api/night', 'POST /api/night/vote'};

  /// Whether [from] guessed wrong too often, lately.
  bool _locked(String from) {
    final f = _failures[from];
    if (f == null) return false;
    if (DateTime.now().difference(f.last) > _failureMemory) {
      _failures.remove(from);
      return false;
    }
    return f.count >= _maxFailures;
  }

  void _failed(String from) {
    final f = _failures[from];
    final now = DateTime.now();
    final before = f == null || now.difference(f.last) > _failureMemory ? 0 : f.count;
    _failures[from] = (count: before + 1, last: now);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer');
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path.startsWith('/fonts/')) return await _font(req, path.substring(7));
      final from = req.connectionInfo?.remoteAddress.address ?? '';
      if (_locked(from)) return await _json(res, {'error': 'locked'}, status: 429);
      final guest = !_authorized(req, _token) && _authorized(req, _guestToken);
      if (!guest && !_authorized(req, _token)) {
        // A guess is a code given; a request with none (a page opened without its link) is no guess
        final given = req.uri.queryParameters.containsKey('t') || req.headers.value('x-session') != null;
        if (given) _failed(from);
        return await _json(res, {'error': 'unauthorized'}, status: 403);
      }
      // Not a failed guess, which would lock out everybody
      if (guest && !_guestMay.contains('${req.method} $path')) {
        return await _json(res, {'error': 'forbidden'}, status: 403);
      }
      switch ((req.method, path)) {
        case ('GET', '/'):
          await _page(res);
        case ('GET', '/api/info'):
          await _json(res, guest ? {'device': deviceName, 'night': night != null} : await _info());
        case ('POST', '/api/playlists'):
          await _addPlaylist(req);
        case ('GET', '/api/backup'):
          await _exportBackup(req);
        case ('POST', '/api/backup'):
          await _importBackup(req);
        case ('POST', '/api/sync'):
          await _signIn(req);
        case ('GET', '/api/night'):
          await _json(res, night?.toJson() ?? {'open': false});
        case ('POST', '/api/night/vote'):
          await _vote(req);
        case ('GET', '/ws') when WebSocketTransformer.isUpgradeRequest(req):
          await _remote(await WebSocketTransformer.upgrade(req));
        default:
          await _json(res, {'error': 'not found'}, status: 404);
      }
    } catch (e) {
      try {
        await _json(res, {'error': 'server', 'detail': '$e'}, status: 500);
      } catch (_) {
        // The response had started already
      }
    }
  }

  /// A phone's yes or no to a title of the movie night: {voter, id, yes}. Nothing private, so not
  /// sealed; the session code is enough.
  Future<void> _vote(HttpRequest req) async {
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > 4096) throw const FormatException('Too large'); // a vote is a few words
    }
    final j = jsonDecode(utf8.decode(bytes));
    final n = night;
    if (n == null) return _json(req.response, {'error': 'closed'}, status: 409);
    final ok = j is Map && n.vote('${j['voter'] ?? ''}', '${j['id'] ?? ''}', yes: j['yes'] == true);
    await _json(req.response, ok ? {'ok': true} : {'error': 'invalid'}, status: ok ? 200 : 400);
  }

  Future<void> _json(HttpResponse res, Object body, {int status = 200}) async {
    res
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await res.close();
  }

  /// The sealed body of a request to [req]'s path; null (after answering 400) when it is not sealed
  /// with this session's key.
  Future<Object?> _opened(HttpRequest req) async {
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBody) throw const FormatException('Too large');
    }
    try {
      final j = jsonDecode(utf8.decode(bytes));
      return await _seal.open(req.uri.path, (j as Map)['sealed'] as String);
    } on Object {
      await _json(req.response, {'error': 'sealed'}, status: 400);
      return null;
    }
  }

  Future<void> _page(HttpResponse res) async {
    final html = (await rootBundle.loadString('assets/companion/index.html'))
        .replaceFirst('/*SEAL*/', await rootBundle.loadString('assets/companion/seal.js'))
        .replaceFirst('/*STRINGS*/{}', jsonEncode(_strings))
        .replaceFirst('/*DEVICE*/""', jsonEncode(deviceName));
    res.headers.contentType = ContentType.html;
    res.write(html);
    await res.close();
  }

  Future<void> _font(HttpRequest req, String name) async {
    const fonts = {'inter-400.ttf': 'Inter-400', 'inter-600.ttf': 'Inter-600', 'inter-800.ttf': 'Inter-800'};
    final file = fonts[name];
    if (file == null) return _json(req.response, {'error': 'not found'}, status: 404);
    final data = await rootBundle.load('assets/fonts/$file.ttf');
    req.response
      ..headers.set('Content-Type', 'font/ttf')
      ..headers.set('Cache-Control', 'max-age=86400')
      ..add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    await req.response.close();
  }

  Future<Map<String, dynamic>> _info() async {
    final sync = SyncService.instance;
    return {
      'device': deviceName,
      'night': night != null,
      'playlists': [for (final p in await PlaylistStore.instance.load()) p.name],
      'nowPlaying': _nowPlayingJson(),
      'sync': {
        'email': ?sync.email,
        'server': sync.server?.toString() ?? const String.fromEnvironment('SYNC_SERVER'),
        'signedIn': sync.status != SyncStatus.off && sync.status != SyncStatus.expired,
      },
    };
  }

  Future<void> _addPlaylist(HttpRequest req) async {
    final j = await _opened(req);
    if (j is! Map<String, dynamic>) return;
    final type = j['type'] == 'm3u' ? PlaylistType.m3u : PlaylistType.xtream;
    final link = (j['url'] as String? ?? '').trim();
    var p = Playlist.create(
      type: type,
      url: link,
      name: j['name'] as String? ?? '',
      username: j['username'] as String? ?? '',
      password: j['password'] as String? ?? '',
    );
    if (p.url.isEmpty || (p.type == PlaylistType.xtream && (p.username.isEmpty || p.password.isEmpty))) {
      return _json(req.response, {'error': 'missing'}, status: 400);
    }
    try {
      await verify(p);
    } on SourceException catch (e) {
      // A provider's link taken for its account, which did not check out but not because the panel
      // refused it (its API closed): the link is tried as the M3U list it also is, as the app's
      // own form does
      final asList = p.type == PlaylistType.xtream && Playlist.xtreamLink(link) != null && !accountRefused(e)
          ? Playlist(id: p.id, name: p.name, type: PlaylistType.m3u, url: link)
          : null;
      try {
        if (asList == null) rethrow;
        await verify(asList);
        p = asList;
      } on SourceException {
        // The phone shows the same message the app would: the account's
        return _json(req.response, {'error': e.error.name, 'detail': e.detail}, status: 422);
      }
    }
    final store = PlaylistStore.instance;
    final same = (await store.load()).where(p.sameAccount).firstOrNull;
    try {
      same == null ? await store.add(p) : await store.update(same.copyWith(password: p.password));
    } on SecretsUnavailable {
      // The list is saved all the same: only its password was not, and both screens say so
      _events.add(PlaylistReceived(p.name, noPassword: true));
      return _json(req.response, {'error': 'secrets'}, status: 507);
    }
    _events.add(PlaylistReceived(p.name));
    await _json(req.response, {'ok': true, 'name': p.name});
  }

  Future<void> _exportBackup(HttpRequest req) async {
    final data = await Backup.export(settings: _settings);
    await _json(req.response, {'sealed': await _seal.seal(req.uri.path, data)});
  }

  Future<void> _importBackup(HttpRequest req) async {
    final data = await _opened(req);
    if (data == null) return;
    if (data is! Map<String, dynamic> || !Backup.isBackup(data)) {
      return _json(req.response, {'error': 'format'}, status: 400);
    }
    final ImportResult result;
    try {
      result = await Backup.import(data, settings: data['settings'] == null ? null : _settings);
    } on BackupTooNew {
      return _json(req.response, {'error': 'newer'}, status: 400);
    } on FormatException {
      return _json(req.response, {'error': 'format'}, status: 400);
    }
    _events.add(BackupReceived(result));
    await _json(req.response, {'ok': true, ...result.toJson()});
  }

  /// Signs this device in to the sync account typed on the phone.
  Future<void> _signIn(HttpRequest req) async {
    final j = await _opened(req);
    if (j is! Map<String, dynamic>) return;
    final server = SyncClient.parseServer(j['server'] as String? ?? '');
    final email = (j['email'] as String? ?? '').trim(), password = j['password'] as String? ?? '';
    if (server == null) return _json(req.response, {'error': 'sync_address'}, status: 400);
    if (email.isEmpty || password.isEmpty) return _json(req.response, {'error': 'missing'}, status: 400);
    try {
      await SyncService.instance.signIn(server: server, email: email, password: password);
    } on SyncException catch (e) {
      return _json(req.response, {'error': 'sync_${e.problem.name}'}, status: 422);
    }
    _events.add(SyncSignedIn(SyncService.instance.email ?? email));
    await _json(req.response, {'ok': true, 'email': SyncService.instance.email});
  }

  Future<void> _remote(WebSocket socket) async {
    // No closing comes from a phone that left the Wi-Fi or was switched off: unanswered pings tell
    socket.pingInterval = const Duration(seconds: 30);
    _sockets.add(socket);
    _stopTimer?.cancel();
    _events.add(const RemoteConnected());
    notifyListeners();
    socket.add(jsonEncode({'type': 'hello', 'device': deviceName, 'nowPlaying': _nowPlayingJson()}));
    try {
      await for (final message in socket) {
        if (message is! String) continue;
        final j = jsonDecode(message);
        if (j is! Map) continue;
        switch (j['type']) {
          case 'key':
            pressRemoteKey('${j['key']}');
          case 'text' when j['sealed'] is String:
            try {
              typeRemoteText('${await _seal.open('/ws/text', j['sealed'] as String)}');
            } on Object {
              // Not sealed with this session's key: ignored
            }
          case 'text':
            // It came in the clear, without the QR's key: never into a password
            if (!typeRemoteText('${j['text']}', sealed: false)) socket.add(jsonEncode({'type': 'needQr'}));
        }
      }
    } finally {
      _sockets.remove(socket);
      notifyListeners();
      _maybeStop(remoteLeft: true);
    }
  }

  Map<String, dynamic>? _nowPlayingJson() {
    final n = nowPlaying.value;
    return n == null ? null : {'title': n.title, 'subtitle': n.subtitle};
  }

  void _sendNowPlaying() {
    final message = jsonEncode({'type': 'now', 'nowPlaying': _nowPlayingJson()});
    for (final s in _sockets) {
      s.add(message);
    }
  }
}
