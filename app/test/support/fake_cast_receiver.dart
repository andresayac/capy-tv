import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:iptv_player/chromecast/cast_link.dart';
import 'package:iptv_player/chromecast/cast_message.dart';

/// How the fake answers a LOAD.
enum FakeLoad {
  play, // BUFFERING, then PLAYING
  fail, // LOAD_FAILED
  silent, // nothing at all
  error, // it starts, then IDLE/ERROR
  stall, // it starts and stays BUFFERING
}

/// How the fake says a LOAD started.
enum FakeAck {
  requestId, // a MEDIA_STATUS with the LOAD's requestId
  zeroOnly, // only statuses with requestId 0, as Google TV does
  idleLoading, // first IDLE with extendedStatus LOADING, with the requestId
}

/// A message the fake was sent, and on which of its connections (from 1).
typedef FakeCastMessage = ({int link, String from, String to, String namespace, Map<String, dynamic> body});

/// A Chromecast on this machine for tests: TLS on loopback with a throwaway certificate, the real
/// framing, and the Default Media Receiver as the protocol describes it, with scripted faults. Its
/// behaviour encodes our reading of the protocol; it is no evidence of how real receivers act.
class FakeCastReceiver {
  FakeCastReceiver._(this.port, this._closeServer);

  static const mediaReceiver = 'CC1AD845';
  static const backdropApp = 'E8C28D3C';
  static const otherApp = '233637DE';
  static const elsewhere = 'http://elsewhere.test/other.mp4';

  final int port;
  final Future<void> Function() _closeServer;

  /// Every message it was sent, in order.
  final received = <FakeCastMessage>[];

  /// Connections accepted, and how many of them the other end closed.
  var connections = 0;
  var hungUp = 0;

  // What it does; any of it can change mid-test
  var answerPing = true;
  var launchError = false;
  var backdrop = false; // the Backdrop app is listed, before ours
  var ack = FakeAck.requestId;
  FutureOr<FakeLoad> Function(Map<String, dynamic> media) onLoad = (_) => FakeLoad.play;
  var staleError = false; // the last failed session's IDLE/ERROR comes again before the next ack
  var unknownFields = false; // its messages carry fields 8 and 9
  var refuse = false; // connections are dropped as they come
  var step = const Duration(milliseconds: 20); // between the states of a load
  var idleAtZero = false; // an IDLE says currentTime 0, as receivers that lost the stream do

  final _conns = <_Conn>{};
  _App? _app; // the app running, besides the Backdrop
  var _apps = 0;
  double level = 1;
  bool muted = false;

  // The media session
  int? mediaSessionId;
  String playerState = 'IDLE';
  String? _idleReason;
  Map<String, dynamic>? media;
  Map<String, dynamic>? _extended;
  var _nextMedia = 1;
  int? _lastError;
  var _base = Duration.zero;
  final _clock = Stopwatch();

  static Future<SecurityContext?>? _context;

  /// A receiver on loopback; null with the reason when openssl, which makes its certificate, is
  /// missing. With [tls] false it accepts TCP and never answers, for handshake timeouts.
  static Future<(FakeCastReceiver?, String)> start({bool tls = true}) async {
    if (!tls) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      final fake = FakeCastReceiver._(server.port, () async {
        await server.close();
        for (final s in held) {
          s.destroy();
        }
      });
      server.listen((s) {
        fake.connections++;
        held.add(s);
        s.listen((_) {}, onDone: () => fake.hungUp++, onError: (Object _) => fake.hungUp++);
      });
      return (fake, '');
    }
    final context = await (_context ??= _makeContext());
    if (context == null) return (null, "openssl not found: it makes the fake receiver's certificate");
    final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
    final fake = FakeCastReceiver._(server.port, () => server.close());
    server.listen(fake._accept, onError: (Object _) {}); // handshakes the client gave up on
    return (fake, '');
  }

  /// The sessionId and transportId of the app running.
  String? get sessionId => _app?.sessionId;
  String? get transportId => _app?.transportId;
  String? get appId => _app?.appId;

  /// The messages of [type] it was sent.
  List<FakeCastMessage> of(String type) => [
    for (final m in received)
      if (m.body['type'] == type) m,
  ];

  /// The Default Media Receiver runs already, playing [content] for another sender.
  void running({String content = elsewhere}) {
    _app = _newApp(mediaReceiver);
    mediaSessionId = _nextMedia++;
    media = {'contentId': content, 'contentType': 'video/mp4', 'streamType': 'BUFFERED'};
    _set('PLAYING');
  }

  /// Every connection drops, as on a Wi-Fi drop; the receiver plays on.
  void drop() {
    // Off the list first: a socket may say it is done while being destroyed, and this end closing
    // it is not the other end hanging up
    final dropped = [..._conns];
    _conns.clear();
    for (final c in dropped) {
      c.socket.destroy();
    }
  }

  /// The receiver restarted: no app runs.
  void forget() {
    _app = null;
    _resetMedia();
  }

  /// The media played to its end.
  void finish() {
    _set('IDLE', idle: 'FINISHED');
    _broadcastMedia();
  }

  /// The media failed while it played.
  void error() {
    _lastError = mediaSessionId;
    _set('IDLE', idle: 'ERROR');
    _broadcastMedia();
  }

  /// Another sender launched another app: ours closes. With [announce] false only the CLOSE comes; the
  /// status tells the rest when asked.
  void launchOther({bool announce = true}) {
    final old = _app;
    _app = _newApp(otherApp);
    _resetMedia();
    if (old != null) _closeTransport(old.transportId);
    if (announce) _broadcastReceiver();
  }

  /// Another sender loaded its own media into our app. With [announce] false no status says so; only
  /// the list does, when asked.
  void interrupt({bool announce = true}) {
    _set('IDLE', idle: 'INTERRUPTED');
    if (announce) _broadcastMedia();
    mediaSessionId = _nextMedia++;
    media = {'contentId': elsewhere, 'contentType': 'video/mp4', 'streamType': 'BUFFERED'};
    _set('PLAYING');
    if (announce) _broadcastMedia(withMedia: true);
  }

  /// Our app was stopped at the receiver, by its remote, or closed itself once idle. With [announce]
  /// false only the CLOSE comes.
  void stopApp({bool announce = true}) {
    final old = _app;
    _app = null;
    _resetMedia();
    if (announce) _broadcastReceiver();
    if (old != null) _closeTransport(old.transportId);
  }

  /// The media session ends without a word and leaves the list, as when its IDLE went out while the
  /// sender was away.
  void vanish() => _resetMedia();

  /// A PING to every sender.
  void ping() {
    for (final c in _conns) {
      _send(c, CastNs.heartbeat, {'type': 'PING'}, from: CastLink.receiverId, to: CastLink.senderId);
    }
  }

  /// A frame header over the 64 KiB limit, to every sender.
  void oversize() {
    for (final c in _conns) {
      _write(c, Uint8List(4 + 16)..buffer.asByteData().setUint32(0, CastMessage.maxFrame));
    }
  }

  Future<void> close() async {
    drop();
    await _closeServer();
  }

  static Future<SecurityContext?> _makeContext() async {
    final openssl = await _openssl();
    if (openssl == null) return null;
    final dir = Directory.systemTemp.createTempSync('fake-cast');
    try {
      // A config file rather than -subj, whose leading slash Git for Windows' openssl may take for a path
      File('${dir.path}/req.cnf')
          .writeAsStringSync('[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = fake-cast\n');
      final r = await Process.run(openssl, [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', //
        '-keyout', 'key.pem', '-out', 'cert.pem', '-config', 'req.cnf',
      ], workingDirectory: dir.path);
      if (r.exitCode != 0) throw StateError('openssl could not make a certificate: ${r.stderr}');
      return SecurityContext()
        ..useCertificateChainBytes(File('${dir.path}/cert.pem').readAsBytesSync())
        ..usePrivateKeyBytes(File('${dir.path}/key.pem').readAsBytesSync());
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  static Future<String?> _openssl() async {
    final programs = Platform.environment['ProgramFiles'];
    for (final exe in [
      'openssl',
      if (Platform.isWindows && programs != null) ...[
        '$programs\\Git\\usr\\bin\\openssl.exe',
        '$programs\\Git\\mingw64\\bin\\openssl.exe',
      ],
    ]) {
      try {
        if ((await Process.run(exe, ['version'])).exitCode == 0) return exe;
      } on ProcessException {
        // Not there; the next one
      }
    }
    return null;
  }

  void _accept(SecureSocket socket) {
    connections++;
    if (refuse) {
      socket.destroy();
      return;
    }
    final c = _Conn(socket, connections);
    _conns.add(c);
    void gone() {
      if (_conns.remove(c)) hungUp++;
    }

    socket.listen(
      (chunk) {
        final List<CastMessage> got;
        try {
          got = c.decoder.add(chunk);
        } on FormatException {
          socket.destroy();
          return gone();
        }
        for (final m in got) {
          _handle(c, m);
        }
      },
      onError: (Object _) => gone(),
      onDone: gone,
      cancelOnError: true,
    );
    socket.done.then((_) {}, onError: (Object _) {});
  }

  void _handle(_Conn c, CastMessage m) {
    final body = m.json;
    if (body == null) return;
    received.add((link: c.number, from: m.source, to: m.destination, namespace: m.namespace, body: body));
    final type = body['type'], id = body['requestId'];
    final rid = id is int ? id : 0;
    switch (m.namespace) {
      case CastNs.connection:
        if (type == 'CONNECT') c.open.add(m.destination);
        if (type == 'CLOSE') c.open.remove(m.destination);
      case CastNs.heartbeat:
        if (type == 'PING' && answerPing) {
          _send(c, CastNs.heartbeat, {'type': 'PONG'}, from: m.destination, to: m.source);
        }
      case CastNs.receiver:
        if (m.destination == CastLink.receiverId && c.open.contains(CastLink.receiverId)) {
          _receiver(c, m.source, type, rid, body);
        }
      case CastNs.media:
        final app = _app;
        // Only for our app's transport, and once connected to it, as a receiver does
        if (app == null || app.appId != mediaReceiver || m.destination != app.transportId) return;
        if (!c.open.contains(app.transportId)) return;
        _media(c, m.source, type, rid, body);
    }
  }

  void _receiver(_Conn c, String to, Object? type, int rid, Map<String, dynamic> body) {
    void reply() => _send(c, CastNs.receiver, _receiverStatus(rid), from: CastLink.receiverId, to: to);
    switch (type) {
      case 'GET_STATUS':
        reply();
      case 'LAUNCH':
        if (launchError) {
          _send(
            c,
            CastNs.receiver,
            {'type': 'LAUNCH_ERROR', 'requestId': rid, 'reason': 'NOT_FOUND'},
            from: CastLink.receiverId,
            to: to,
          );
          return;
        }
        Timer(step, () {
          final appId = body['appId'] as String;
          if (_app?.appId != appId) {
            final old = _app;
            _app = _newApp(appId);
            _resetMedia();
            if (old != null) _closeTransport(old.transportId);
          }
          reply();
        });
      case 'STOP':
        final app = _app;
        if (app != null && body['sessionId'] == app.sessionId) {
          _app = null;
          _resetMedia();
          _closeTransport(app.transportId);
        }
        reply();
      case 'SET_VOLUME':
        final v = body['volume'];
        if (v is Map && v['level'] is num) level = (v['level'] as num).toDouble();
        if (v is Map && v['muted'] is bool) muted = v['muted'] as bool;
        reply();
    }
  }

  void _media(_Conn c, String to, Object? type, int rid, Map<String, dynamic> body) {
    final from = _app!.transportId;
    void reply({bool withMedia = false}) => _send(c, CastNs.media, _mediaStatus(rid, withMedia), from: from, to: to);
    if (type == 'GET_STATUS') return reply(withMedia: true);
    if (type == 'LOAD') {
      unawaited(_load(c, to, rid, body));
      return;
    }
    if (body['mediaSessionId'] != mediaSessionId || mediaSessionId == null) {
      _send(
        c,
        CastNs.media,
        {'type': 'INVALID_REQUEST', 'requestId': rid, 'reason': 'INVALID_MEDIA_SESSION_ID'},
        from: from,
        to: to,
      );
      return;
    }
    switch (type) {
      case 'PLAY':
        _set('PLAYING');
      case 'PAUSE':
        _set('PAUSED');
      case 'SEEK':
        final t = body['currentTime'];
        _base = Duration(milliseconds: ((t is num ? t : 0) * 1000).round());
        _clock.reset();
      case 'STOP':
        _set('IDLE', idle: 'CANCELLED');
    }
    reply();
  }

  Future<void> _load(_Conn c, String to, int rid, Map<String, dynamic> body) async {
    final loaded = Map<String, dynamic>.from(body['media'] as Map);
    final outcome = await onLoad(loaded);
    final transport = _app?.transportId;
    if (transport == null) return;
    final stale = _lastError;
    if (staleError && stale != null) {
      _broadcast(CastNs.media, {
        'type': 'MEDIA_STATUS',
        'requestId': 0,
        'status': [
          {'mediaSessionId': stale, 'playerState': 'IDLE', 'idleReason': 'ERROR', 'currentTime': 0, 'playbackRate': 1},
        ],
      }, from: transport);
    }
    if (outcome == FakeLoad.fail) {
      _send(c, CastNs.media, {'type': 'LOAD_FAILED', 'requestId': rid}, from: transport, to: to);
      return;
    }
    if (mediaSessionId != null && playerState != 'IDLE') {
      _set('IDLE', idle: 'INTERRUPTED');
      _broadcastMedia(withMedia: true); // with its content, which may be the same as the new one's
    }
    final id = mediaSessionId = _nextMedia++;
    media = loaded;
    final t = body['currentTime'];
    _base = Duration(milliseconds: ((t is num ? t : 0) * 1000).round());
    _clock.reset();
    playerState = 'IDLE';
    _idleReason = null;
    _extended = null;
    if (outcome == FakeLoad.silent) return;
    switch (ack) {
      case FakeAck.requestId:
        _set('BUFFERING');
        _send(c, CastNs.media, _mediaStatus(rid, true), from: transport, to: to);
      case FakeAck.zeroOnly:
        _set('BUFFERING');
        _broadcastMedia(withMedia: true);
      case FakeAck.idleLoading:
        _extended = {'playerState': 'LOADING', 'media': loaded};
        _send(c, CastNs.media, _mediaStatus(rid, false), from: transport, to: to);
        await Future<void>.delayed(step);
        if (mediaSessionId != id) return;
        _set('BUFFERING');
        _broadcastMedia();
    }
    await Future<void>.delayed(step);
    if (mediaSessionId != id || outcome == FakeLoad.stall) return;
    if (outcome == FakeLoad.error) return error();
    _set('PLAYING');
    _broadcastMedia();
  }

  _App _newApp(String appId) {
    final n = ++_apps;
    return _App(appId, 'session-$n', 'web-$n');
  }

  void _resetMedia() {
    mediaSessionId = null;
    media = null;
    playerState = 'IDLE';
    _idleReason = null;
    _extended = null;
  }

  /// Where the media is now, in seconds.
  double get _now => (_base + (playerState == 'PLAYING' ? _clock.elapsed : Duration.zero)).inMilliseconds / 1000;

  void _set(String state, {String? idle}) {
    _base = Duration(milliseconds: (_now * 1000).round());
    _clock
      ..reset()
      ..start();
    playerState = state;
    _idleReason = idle;
    _extended = null;
  }

  Map<String, dynamic> _receiverStatus(int rid) => {
    'type': 'RECEIVER_STATUS',
    'requestId': rid,
    'status': {
      if (backdrop || _app != null)
        'applications': [
          if (backdrop) _App(backdropApp, 'backdrop-session', 'backdrop-transport').toJson(),
          ?_app?.toJson(),
        ],
      'volume': {'level': level, 'muted': muted, 'controlType': 'attenuation', 'stepInterval': 0.05},
    },
  };

  Map<String, dynamic> _mediaStatus(int rid, bool withMedia) => {
    'type': 'MEDIA_STATUS',
    'requestId': rid,
    'status': [
      if (mediaSessionId != null)
        {
          'mediaSessionId': mediaSessionId,
          'playbackRate': 1,
          'playerState': playerState,
          'currentTime': idleAtZero && playerState == 'IDLE' ? 0 : _now,
          'supportedMediaCommands': 274447,
          'volume': {'level': 1, 'muted': false},
          'idleReason': ?_idleReason,
          'extendedStatus': ?_extended,
          if (withMedia) 'media': ?media,
        },
    ],
  };

  void _broadcastMedia({bool withMedia = false}) {
    final transport = _app?.transportId;
    if (transport != null) _broadcast(CastNs.media, _mediaStatus(0, withMedia), from: transport);
  }

  void _broadcastReceiver() => _broadcast(CastNs.receiver, _receiverStatus(0), from: CastLink.receiverId);

  void _broadcast(String namespace, Map<String, dynamic> body, {required String from}) {
    for (final c in [..._conns]) {
      if (c.open.contains(from)) _send(c, namespace, body, from: from, to: '*');
    }
  }

  void _closeTransport(String transport) {
    for (final c in [..._conns]) {
      if (c.open.remove(transport)) {
        _send(c, CastNs.connection, {'type': 'CLOSE'}, from: transport, to: CastLink.senderId);
      }
    }
  }

  void _send(_Conn c, String namespace, Map<String, dynamic> body, {required String from, required String to}) {
    var bytes = CastMessage(source: from, destination: to, namespace: namespace, payload: jsonEncode(body)).encode();
    if (unknownFields) bytes = Uint8List.fromList([...bytes, 0x40, 0x01, 0x48, 0x00]); // continued, remaining_length
    _write(
      c,
      Uint8List(bytes.length + 4)
        ..buffer.asByteData().setUint32(0, bytes.length)
        ..setRange(4, bytes.length + 4, bytes),
    );
  }

  void _write(_Conn c, List<int> bytes) {
    try {
      c.socket.add(bytes);
    } on Object {
      // That sender is gone
    }
  }
}

class _Conn {
  _Conn(this.socket, this.number);

  final SecureSocket socket;
  final int number;
  final decoder = CastFrameDecoder();
  final open = <String>{}; // the virtual connections the sender opened
}

class _App {
  const _App(this.appId, this.sessionId, this.transportId);

  final String appId;
  final String sessionId;
  final String transportId;

  Map<String, dynamic> toJson() => {
    'appId': appId,
    'displayName': appId,
    'sessionId': sessionId,
    'transportId': transportId,
    'namespaces': [
      {'name': CastNs.media},
    ],
    'isIdleScreen': appId == FakeCastReceiver.backdropApp,
  };
}
