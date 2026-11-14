// A panel at https with a certificate nobody vouches for (self-signed, as many are) signs in and
// gives its lists, as its channels play; what is not a provider's still checks certificates.
// The certificate is made for the test with openssl, which Git for Windows brings; without it the
// test is skipped.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iptv_player/data/xtream.dart';

/// openssl as found on PATH, or Git for Windows' own.
Future<String?> _openssl() async {
  for (final exe in [
    'openssl',
    r'C:\Program Files\Git\usr\bin\openssl.exe',
    r'C:\Program Files\Git\mingw64\bin\openssl.exe',
  ]) {
    try {
      if ((await Process.run(exe, ['version'])).exitCode == 0) return exe;
    } on ProcessException {
      // Not this one
    }
  }
  return null;
}

void main() {
  HttpOverrides.global = null; // real sockets
  HttpServer? server;
  late Directory dir;

  setUpAll(() async {
    final openssl = await _openssl();
    if (openssl == null) return;
    dir = Directory.systemTemp.createTempSync('cert');
    final made = await Process.run(openssl, [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=panel.test', //
      '-keyout', '${dir.path}/key.pem', '-out', '${dir.path}/cert.pem',
    ]);
    if (made.exitCode != 0) return;
    final context = SecurityContext()
      ..useCertificateChain('${dir.path}/cert.pem')
      ..usePrivateKey('${dir.path}/key.pem');
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    server!.listen((req) {
      req.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'user_info': {'username': 'demo', 'password': 'secret', 'auth': 1, 'status': 'Active'},
            'server_info': {'timezone': 'UTC'},
          }),
        )
        ..close();
    });
  });

  tearDownAll(() async {
    await server?.close(force: true);
    if (server != null) dir.deleteSync(recursive: true);
  });

  test("a panel whose certificate is its own signs in, as its channels would play", () async {
    if (server == null) return markTestSkipped('no openssl to make a certificate');
    final panel = XtreamSource(server: 'https://127.0.0.1:${server!.port}', username: 'demo', password: 'secret');
    expect((await panel.login()).status, 'Active');
    panel.close();
  });

  test('anything else still refuses that certificate', () async {
    if (server == null) return markTestSkipped('no openssl to make a certificate');
    final plain = http.Client();
    await expectLater(plain.get(Uri.parse('https://127.0.0.1:${server!.port}/')), throwsA(anything));
    plain.close();
  });
}
