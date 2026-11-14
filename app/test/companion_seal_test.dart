// The companion page's sealing (assets/companion/seal.js, run with Node) against the app's
// (cryptography package), both ways, and against RFC 8439.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/remote/companion_seal.dart';

List<int> _hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

String _toHex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

/// Runs [code] with the page's Seal loaded; returns what it prints. Null without Node.
Future<String?> _node(String code) async {
  final seal = File('assets/companion/seal.js').absolute.path.replaceAll(r'\', '/');
  try {
    final r = await Process.run('node', ['-e', "const Seal = require('$seal');\n$code"], stdoutEncoding: utf8);
    if (r.exitCode != 0) throw StateError('node: ${r.stderr}');
    return (r.stdout as String).trim();
  } on ProcessException {
    return null;
  }
}

void main() {
  // RFC 8439, 2.8.2
  const plain =
      "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
  final key = _hex('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
  final nonce = _hex('070000004041424344454647');
  final aad = _hex('50515253c0c1c2c3c4c5c6c7');
  const tag = '1ae10b594f09e26a7e902ecbd0600691';

  test('the app follows RFC 8439', () async {
    final box = await Chacha20.poly1305Aead().encrypt(
      utf8.encode(plain),
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    expect(_toHex(box.mac.bytes), tag);
    expect(_toHex(box.cipherText).substring(0, 32), 'd31a8d34648e60db7b86afbc53ef7ec2');
  });

  test('so does the page', () async {
    final out = await _node('''
      const hex = (s) => Uint8Array.from(s.match(/../g).map((h) => parseInt(h, 16)));
      const toHex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
      const key = hex('${_toHex(key)}'), nonce = hex('${_toHex(nonce)}');
      const ct = Seal.chacha20(key, 1, nonce, new TextEncoder().encode(${jsonEncode(plain)}));
      console.log(toHex(ct).slice(0, 32));
      // RFC 8439, 2.5.2
      const tag = Seal.poly1305(hex('85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b'),
        new TextEncoder().encode('Cryptographic Forum Research Group'));
      console.log(toHex(tag));
    ''');
    if (out == null) return markTestSkipped('Node is not installed');
    expect(out.split('\n'), ['d31a8d34648e60db7b86afbc53ef7ec2', 'a8061dc1305136c6c22b8baf0c0127a9']);
  });

  test('what the page seals the app opens, and the other way round', () async {
    final seal = CompanionSeal.random();
    const value = {
      'email': 'ana@example.com',
      'password': 'pässword ✓',
      'list': [1, 2, 3],
    };
    final fromPage = await _node('''
      const key = Seal.keyFrom('${seal.text}');
      console.log(Seal.seal(key, '/api/sync', ${jsonEncode(value)}));
    ''');
    if (fromPage == null) return markTestSkipped('Node is not installed');
    expect(await seal.open('/api/sync', fromPage), value);
    await expectLater(seal.open('/api/backup', fromPage), throwsFormatException, reason: 'bound to its path');

    final fromApp = await seal.seal('/api/backup', value);
    // One character changed: another than the one there (with a random key it is an A now and then)
    final tampered = '${fromApp.substring(0, 20)}${fromApp[20] == 'A' ? 'B' : 'A'}${fromApp.substring(21)}';
    final opened = await _node('''
      const key = Seal.keyFrom('${seal.text}');
      console.log(JSON.stringify(Seal.open(key, '/api/backup', '$fromApp')));
      try { Seal.open(key, '/api/backup', '$tampered'); console.log('opened'); }
      catch (e) { console.log('refused'); }
    ''');
    expect(opened!.split('\n'), [jsonEncode(value), 'refused']);
  });

  test('only the same key opens it', () async {
    final sealed = await CompanionSeal.random().seal('/api/sync', {'a': 1});
    await expectLater(CompanionSeal.random().open('/api/sync', sealed), throwsFormatException);
    final seal = CompanionSeal.random();
    expect(CompanionSeal.fromText(seal.text).key, seal.key);
  });
}
