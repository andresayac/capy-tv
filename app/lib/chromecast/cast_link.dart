import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'cast_message.dart';

/// The namespaces the sender speaks.
abstract final class CastNs {
  static const connection = 'urn:x-cast:com.google.cast.tp.connection';
  static const heartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const receiver = 'urn:x-cast:com.google.cast.receiver';
  static const media = 'urn:x-cast:com.google.cast.media';
}

/// A message from the receiver: who sent it, on which namespace, and its JSON payload.
typedef CastReceived = ({String from, String namespace, Map<String, dynamic> body});

/// The TLS connection to a receiver: frames, request ids, and the heartbeat that tells a dead link.
class CastLink {
  CastLink._(this._raw, this._socket, Duration heartbeat, this._deadline)
    : localAddress = _socket.address,
      remoteAddress = _socket.remoteAddress {
    _sub = _socket.listen(_event, onError: (Object _) => _shut(), onDone: _shut, cancelOnError: true);
    _beat = Timer.periodic(heartbeat, (_) => _ping());
  }

  static const senderId = 'sender-0';
  static const receiverId = 'receiver-0';

  final RawSocket _raw; // kept to end the connection whatever TLS is doing
  final RawSecureSocket _socket;
  final Duration _deadline;

  /// The local end of the link: the address the receiver reaches this device on.
  final InternetAddress localAddress;

  /// The receiver's end: its address, also when it was given by name ("tv.local").
  final InternetAddress remoteAddress;

  late final StreamSubscription<RawSocketEvent> _sub;
  late final Timer _beat;
  Timer? _unanswered; // runs from a PING until its PONG
  final _decoder = CastFrameDecoder();
  final _out = Queue<List<int>>(); // frames not yet taken by the socket
  var _written = 0; // of the first of them
  final _messages = StreamController<CastReceived>.broadcast();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _done = Completer<void>();
  var _nextId = 1; // 0 is what receivers put on messages nobody asked for
  var _closed = false;

  /// Connects to [host], opens the virtual connection to the receiver and starts the heartbeat.
  /// [timeout] covers the TCP connect and, apart, the TLS handshake, which the timeout of
  /// SecureSocket.connect does not; the socket is closed when either runs out. A receiver's
  /// certificate is its own, self-signed: any is taken, for this socket only.
  static Future<CastLink> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 10),
    Duration heartbeat = const Duration(seconds: 5),
    Duration deadline = const Duration(seconds: 15),
  }) async {
    final raw = await RawSocket.connect(host, port, timeout: timeout);
    final RawSecureSocket socket;
    try {
      socket = await RawSecureSocket.secure(raw, onBadCertificate: (_) => true).timeout(timeout);
    } on Object {
      unawaited(raw.close().then((_) {}, onError: (Object _) {})); // ends the handshake too
      rethrow;
    }
    final link = CastLink._(raw, socket, heartbeat, deadline);
    link.open(receiverId);
    link._ping();
    return link;
  }

  /// Every message from the receiver but the heartbeat, replies to requests included.
  Stream<CastReceived> get messages => _messages.stream;

  /// Completes once the link is closed, by either end or because the receiver stopped answering.
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  /// Opens the virtual connection to [to]: receiver-0, or an app's transportId.
  void open(String to) => send(CastNs.connection, {'type': 'CONNECT'}, to: to);

  /// Sends [body]; nothing once the link is closed. Throws [FormatException] for a message over
  /// [CastMessage.maxFrame].
  void send(String namespace, Map<String, dynamic> body, {String to = receiverId}) {
    if (_closed) return;
    _out.add(CastMessage(source: senderId, destination: to, namespace: namespace, payload: jsonEncode(body)).frame());
    _flush();
  }

  /// Sends [body] with the next request id, and returns that id; the reply is to be looked for in
  /// [messages].
  int sendRequest(String namespace, Map<String, dynamic> body, {String to = receiverId}) {
    final id = _nextId++;
    send(namespace, {'type': body['type'], 'requestId': id, ...body}, to: to);
    return id;
  }

  /// Sends [body] with the next request id and completes with the reply carrying it. Throws
  /// [TimeoutException] past [timeout], [SocketException] when the link closes first.
  Future<Map<String, dynamic>> request(
    String namespace,
    Map<String, dynamic> body, {
    String to = receiverId,
    required Duration timeout,
  }) {
    if (_closed) return Future.error(const SocketException.closed());
    final id = _nextId;
    final reply = _pending[id] = Completer<Map<String, dynamic>>();
    sendRequest(namespace, body, to: to);
    return reply.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('no reply to request $id', timeout);
      },
    );
  }

  /// Closes the link once what was sent has gone out, or after a short while if it does not.
  Future<void> close() async {
    if (_done.isCompleted) return;
    _closed = true;
    for (var i = 0; i < 100 && _out.isNotEmpty && !_done.isCompleted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    try {
      await _socket.close().timeout(const Duration(seconds: 1));
    } on Object {
      // Not draining: closed below all the same
    }
    _shut();
  }

  void _ping() {
    send(CastNs.heartbeat, {'type': 'PING'});
    _unanswered ??= Timer(_deadline, _shut);
  }

  void _event(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final data = _socket.read();
      if (data != null) _read(data);
    } else if (event == RawSocketEvent.write) {
      _flush();
    } else if (event == RawSocketEvent.readClosed || event == RawSocketEvent.closed) {
      _shut();
    }
  }

  void _flush() {
    try {
      while (_out.isNotEmpty) {
        final frame = _out.first;
        _written += _socket.write(frame, _written);
        if (_written < frame.length) {
          _socket.writeEventsEnabled = true; // the rest once there is room
          return;
        }
        _out.removeFirst();
        _written = 0;
      }
    } on Object {
      _shut();
    }
  }

  void _read(List<int> chunk) {
    final List<CastMessage> got;
    try {
      got = _decoder.add(chunk);
    } on FormatException {
      return _shut(); // an oversize or broken frame: the stream cannot be followed past it
    }
    for (final m in got) {
      if (_done.isCompleted) return;
      final body = m.json;
      if (body == null) continue;
      if (m.namespace == CastNs.heartbeat) {
        if (body['type'] == 'PING') send(CastNs.heartbeat, {'type': 'PONG'}, to: m.source);
        if (body['type'] == 'PONG') {
          _unanswered?.cancel();
          _unanswered = null;
        }
        continue;
      }
      final id = body['requestId'];
      if (id is int && id != 0) _pending.remove(id)?.complete(body);
      _messages.add((from: m.source, namespace: m.namespace, body: body));
    }
  }

  void _shut() {
    if (_done.isCompleted) return;
    _closed = true;
    _beat.cancel();
    _unanswered?.cancel();
    _out.clear();
    _sub.cancel().ignore();
    _socket.close().ignore();
    _raw.close().ignore();
    for (final reply in _pending.values) {
      reply.completeError(const SocketException.closed());
    }
    _pending.clear();
    _messages.close().ignore();
    _done.complete();
  }
}
