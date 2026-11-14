import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Seals what crosses the local network between this device and the user's phone (the companion
/// page, or the app on the phone): passwords, the sync account, backups.
///
/// The page is plain HTTP, so a key made for each session travels only inside the QR code, in the
/// address's #fragment, which browsers never send. ChaCha20-Poly1305 (RFC 8439), with the API path
/// as associated data so a sealed request cannot be replayed to another endpoint; sealed text is
/// base64(nonce ‖ ciphertext ‖ tag). The page does the same in assets/companion/seal.js.
class CompanionSeal {
  CompanionSeal(List<int> key) : key = List.unmodifiable(key) {
    if (key.length != 32) throw ArgumentError('A 32-byte key');
  }

  factory CompanionSeal.random() {
    final random = Random.secure();
    return CompanionSeal([for (var i = 0; i < 32; i++) random.nextInt(256)]);
  }

  /// From [text] as the QR code carries it.
  factory CompanionSeal.fromText(String text) => CompanionSeal(base64Url.decode(base64Url.normalize(text)));

  static final _aead = Chacha20.poly1305Aead();

  final List<int> key;

  /// The key for the QR code: base64url without padding.
  String get text => base64Url.encode(key).replaceAll('=', '');

  Future<String> seal(String path, Object? value) async {
    final box = await _aead.encrypt(utf8.encode(jsonEncode(value)), secretKey: SecretKey(key), aad: utf8.encode(path));
    return base64.encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// What [seal] sealed for [path]. Throws a [FormatException] if it was sealed with another key,
  /// for another path, or changed on the way.
  Future<Object?> open(String path, String sealed) async {
    try {
      final all = base64.decode(sealed);
      if (all.length < 28) throw const FormatException('sealed');
      final box = SecretBox(
        all.sublist(12, all.length - 16),
        nonce: all.sublist(0, 12),
        mac: Mac(all.sublist(all.length - 16)),
      );
      final clear = await _aead.decrypt(box, secretKey: SecretKey(key), aad: utf8.encode(path));
      return jsonDecode(utf8.decode(clear));
    } on SecretBoxAuthenticationError {
      throw const FormatException('sealed');
    }
  }
}
