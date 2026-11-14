import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../data/off_thread.dart';

const _context = 'iptv-player/sync/v1';

final _aes = AesGcm.with256bits();

List<int> _random(int length) {
  final random = Random.secure();
  return List.generate(length, (_) => random.nextInt(256));
}

/// The keys of a sync account's data: [encKey] encrypts every item and [idKey] names them, so
/// the server stores data it cannot read and cannot even tell apart.
///
/// They are random, made once with the account. The server keeps them too, but only wrapped
/// (encrypted) with keys from the password and from the recovery key (see [SignInKeys]), which
/// it never sees. Changing the password, or setting a new one with the recovery key, only wraps
/// them again: everything synced stays readable.
class SyncKeys {
  const SyncKeys({required this.encKey, required this.idKey});

  factory SyncKeys.random() => SyncKeys(encKey: _random(32), idKey: _random(32));

  factory SyncKeys.fromJson(Map<String, dynamic> j) =>
      SyncKeys(encKey: base64.decode(j['enc'] as String), idKey: base64.decode(j['ids'] as String));

  final List<int> encKey, idKey;

  /// What stays on the device (in secure storage) once signed in.
  Map<String, dynamic> toJson() => {'enc': base64.encode(encKey), 'ids': base64.encode(idKey)};

  static final _wrapping = utf8.encode('$_context/keys');

  /// These keys encrypted with [key] (a [SignInKeys.wrapKey]), for the server to keep.
  Future<String> wrap(List<int> key) async {
    final box = await _aes.encrypt(utf8.encode(jsonEncode(toJson())), secretKey: SecretKey(key), aad: _wrapping);
    return base64.encode(box.concatenation());
  }

  /// Opens what [wrap] made. Throws if [key] is not the one it was made with.
  static Future<SyncKeys> unwrap(List<int> key, String wrapped) async {
    final box = SecretBox.fromConcatenation(
      base64.decode(wrapped),
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    final clear = await _aes.decrypt(box, secretKey: SecretKey(key), aad: _wrapping);
    return SyncKeys.fromJson(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
  }

  /// Encrypts [data] as item [id]: gzip, then AES-256-GCM with the id as associated data, so the
  /// server can neither read an item nor pass it off as another.
  Future<String> seal(String id, Object? data) async {
    final box = await _aes.encrypt(
      gzip.encode(utf8.encode(jsonEncode(data))),
      secretKey: SecretKey(encKey),
      aad: utf8.encode(id),
    );
    return base64.encode(box.concatenation());
  }

  /// Opens what [seal] made. Throws if it was made with another key or for another item.
  Future<Object?> open(String id, String payload) async {
    final box = SecretBox.fromConcatenation(
      base64.decode(payload),
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    final clear = await _aes.decrypt(box, secretKey: SecretKey(encKey), aad: utf8.encode(id));
    return jsonDecode(utf8.decode(gzip.decode(clear)));
  }

  /// The name of item [key] on the server: the same on every device of the account,
  /// meaningless to anyone else.
  Future<String> itemId(String key) => _mac('id:$key');

  /// Tells whether something changed without keeping it (or an easy-to-guess hash of it, since it
  /// may hold a password) in the plain preferences.
  Future<String> fingerprint(String text) => _mac('fp:$text');

  Future<String> _mac(String text) async {
    final mac = await Hmac.sha256().calculateMac(utf8.encode(text), secretKey: SecretKey(idKey));
    return base64Url.encode(mac.bytes).replaceAll('=', '');
  }
}

/// What a password, or the recovery key, gives on the device: [authKey], which proves it to the
/// server without revealing it, and [wrapKey], which wraps the account's [SyncKeys] and is never
/// sent.
class SignInKeys {
  const SignInKeys({required this.authKey, required this.wrapKey});

  final List<int> authKey, wrapKey;

  /// Argon2id with RFC 9106's second recommended profile (64 MiB, 3 passes): a fraction of a
  /// second on a desktop, a few seconds on a TV stick, and the same cost for every guess at the
  /// password from a stolen server database. The salt comes from the email, so every device
  /// derives the same keys without asking anyone. Runs in its own isolate to keep the UI smooth.
  static Future<SignInKeys> password(String email, String password, {int memoryKiB = 65536, int passes = 3}) =>
      runOffThread(() => _password(normalizeEmail(email), password, memoryKiB, passes));

  static Future<SignInKeys> _password(String email, String password, int memoryKiB, int passes) async {
    final salt = (await Sha256().hash(utf8.encode('$_context/$email'))).bytes.sublist(0, 16);
    final master = await Argon2id(
      memory: memoryKiB,
      parallelism: 1,
      iterations: passes,
      hashLength: 32,
    ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    return _split(master, '');
  }

  /// The recovery key is random and long enough to need no stretching.
  static Future<SignInKeys> recovery(RecoveryKey key) => _split(SecretKey(key.bytes), 'recovery/');

  static Future<SignInKeys> _split(SecretKey master, String prefix) async {
    Future<List<int>> part(String name) async => (await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(secretKey: master, nonce: const [], info: utf8.encode('$_context/$prefix$name'))).extractBytes();
    return SignInKeys(authKey: await part('auth'), wrapKey: await part('wrap'));
  }

  static String normalizeEmail(String email) => email.trim().toLowerCase();
}

/// The way back into an account whose password is forgotten: 160 random bits, shown once when
/// the account is made, for the user to write down. Written in Crockford's base32, which has no
/// I, L, O or U to misread, in groups of four.
class RecoveryKey {
  RecoveryKey(List<int> bytes) : bytes = List.unmodifiable(bytes) {
    if (bytes.length != _length) throw ArgumentError.value(bytes.length, 'bytes', 'not $_length');
  }

  factory RecoveryKey.random() => RecoveryKey(_random(_length));

  static const _length = 20;
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  final List<int> bytes;

  /// What the user typed, forgiving case, spaces, dashes, and letters taken for the digits they
  /// look like. Null when it cannot be a recovery key.
  static RecoveryKey? parse(String text) {
    final clean = text
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    if (clean.length != _length * 8 ~/ 5) return null;
    final out = <int>[];
    var buffer = 0, bits = 0;
    for (final c in clean.split('')) {
      final v = _alphabet.indexOf(c);
      if (v < 0) return null;
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xff);
        buffer &= (1 << bits) - 1;
      }
    }
    return RecoveryKey(out);
  }

  /// As the user writes it down: eight groups of four, like K7QM-3XRA-….
  String get text {
    final chars = StringBuffer();
    var buffer = 0, bits = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        chars.write(_alphabet[(buffer >> bits) & 31]);
      }
      buffer &= (1 << bits) - 1;
    }
    final s = chars.toString();
    return [for (var i = 0; i < s.length; i += 4) s.substring(i, i + 4)].join('-');
  }

  @override
  bool operator ==(Object other) => other is RecoveryKey && other.text == text;

  @override
  int get hashCode => text.hashCode;
}
