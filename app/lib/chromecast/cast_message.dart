import 'dart:convert';
import 'dart:typed_data';

/// One message of the Chromecast protocol (CASTV2): its CastMessage protobuf, coded by hand. Fields 1-5
/// are always written (proto2 `required`), then the payload: text in 6, or binary in 7.
class CastMessage {
  const CastMessage({
    required this.source,
    required this.destination,
    required this.namespace,
    this.payload = '',
    this.binary,
  });

  /// The most a frame may take either way, its 4-byte length included, as Chromium's framer allows.
  static const maxFrame = 64 * 1024;

  final String source;
  final String destination;
  final String namespace;
  final String payload; // payload_utf8, JSON in every namespace we use
  final Uint8List? binary; // payload_binary, with payload type 1

  bool get isBinary => binary != null;

  /// The payload as a JSON object; null when it is not one.
  Map<String, dynamic>? get json {
    try {
      final v = jsonDecode(payload);
      return v is Map<String, dynamic> ? v : null;
    } on FormatException {
      return null;
    }
  }

  /// The protobuf bytes, without the length in front.
  Uint8List encode() {
    final out = BytesBuilder(copy: false);
    void varint(int v) {
      while (v >= 0x80) {
        out.addByte((v & 0x7f) | 0x80);
        v >>= 7;
      }
      out.addByte(v);
    }

    void field(int tag, List<int> bytes) {
      out.addByte(tag);
      varint(bytes.length);
      out.add(bytes);
    }

    out
      ..addByte(0x08) // protocol_version: CASTV2_1_0
      ..addByte(0);
    field(0x12, utf8.encode(source));
    field(0x1a, utf8.encode(destination));
    field(0x22, utf8.encode(namespace));
    final b = binary;
    out
      ..addByte(0x28) // payload_type: 0 text, 1 binary
      ..addByte(b == null ? 0 : 1);
    if (b == null) {
      field(0x32, utf8.encode(payload));
    } else {
      field(0x3a, b);
    }
    return out.takeBytes();
  }

  /// The message as it goes on the wire: a big-endian length, then [encode]. Throws [FormatException]
  /// past [maxFrame]: a receiver drops the connection for such a frame.
  Uint8List frame() {
    final body = encode();
    if (body.length + 4 > maxFrame) throw FormatException('a frame of ${body.length + 4} bytes, over $maxFrame');
    final out = Uint8List(body.length + 4);
    out.buffer.asByteData().setUint32(0, body.length);
    out.setRange(4, out.length, body);
    return out;
  }

  /// The size [frame] gives, to check before sending.
  int get frameSize => encode().length + 4;

  /// Reads the protobuf bytes of one message. Fields it does not know are skipped by their wire type
  /// (newer receivers add 8 and 9). Throws [FormatException] when they do not parse.
  static CastMessage decode(List<int> bytes) {
    var at = 0;
    int varint() {
      var v = 0;
      for (var shift = 0; shift < 64; shift += 7) {
        if (at >= bytes.length) throw const FormatException('a cast message cut short');
        final b = bytes[at++];
        v |= (b & 0x7f) << shift;
        if (b < 0x80) return v;
      }
      throw const FormatException('a varint over 10 bytes');
    }

    List<int> take(int n) {
      if (n < 0 || n > bytes.length - at) throw const FormatException('a cast message cut short');
      final out = bytes.sublist(at, at + n);
      at += n;
      return out;
    }

    var source = '', destination = '', namespace = '', payload = '', type = 0;
    List<int>? binary;
    while (at < bytes.length) {
      final key = varint();
      switch ((key >> 3, key & 7)) {
        case (2, 2):
          source = utf8.decode(take(varint()));
        case (3, 2):
          destination = utf8.decode(take(varint()));
        case (4, 2):
          namespace = utf8.decode(take(varint()));
        case (5, 0):
          type = varint();
        case (6, 2):
          payload = utf8.decode(take(varint()));
        case (7, 2):
          binary = take(varint());
        case (_, 0): // protocol_version, or one we do not know
          varint();
        case (_, 1):
          take(8);
        case (_, 2):
          take(varint());
        case (_, 5):
          take(4);
        case (_, final wire):
          throw FormatException('wire type $wire in a cast message');
      }
    }
    return CastMessage(
      source: source,
      destination: destination,
      namespace: namespace,
      payload: payload,
      binary: type == 1 ? Uint8List.fromList(binary ?? const []) : null,
    );
  }
}

/// Cuts the bytes from a receiver into messages, however the chunks split or join the frames. Binary
/// messages (device authentication) are dropped: we use none.
class CastFrameDecoder {
  var _buf = Uint8List(4096);
  var _len = 0;

  /// The text messages that [chunk] completes. Throws [FormatException] for a frame over
  /// [CastMessage.maxFrame] or one that does not parse; nothing after that can be read.
  List<CastMessage> add(List<int> chunk) {
    _append(chunk);
    final out = <CastMessage>[];
    var at = 0;
    while (_len - at >= 4) {
      final size = _buf[at] << 24 | _buf[at + 1] << 16 | _buf[at + 2] << 8 | _buf[at + 3];
      if (size + 4 > CastMessage.maxFrame) {
        throw FormatException('a frame of ${size + 4} bytes, over ${CastMessage.maxFrame}');
      }
      if (_len - at - 4 < size) break;
      final message = CastMessage.decode(Uint8List.sublistView(_buf, at + 4, at + 4 + size));
      at += 4 + size;
      if (!message.isBinary) out.add(message);
    }
    if (at > 0) {
      _buf.setRange(0, _len - at, _buf, at);
      _len -= at;
    }
    return out;
  }

  void _append(List<int> chunk) {
    final need = _len + chunk.length;
    if (need > _buf.length) {
      var size = _buf.length * 2;
      while (size < need) {
        size *= 2;
      }
      final grown = Uint8List(size);
      grown.setRange(0, _len, _buf);
      _buf = grown;
    }
    _buf.setRange(_len, need, chunk);
    _len = need;
  }
}
