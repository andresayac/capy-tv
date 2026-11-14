// A connection that fails says what to check: no network, a name that cannot be looked up, a
// secure connection (most often the clock), or the server itself.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/data/xtream.dart';

void main() {
  test('each failure as what to check', () {
    expect(networkError(const SocketException("Failed host lookup: 'tv.invalid'")).error, SourceError.dns);
    expect(
      networkError(const SocketException('Connection failed', osError: OSError('Network is unreachable', 101))).error,
      SourceError.offline,
    );
    expect(networkError(const HandshakeException('CERTIFICATE_VERIFY_FAILED')).error, SourceError.tls);
    expect(networkError(http.ClientException("Failed host lookup: 'tv.invalid'")).error, SourceError.dns);
    expect(
      networkError(const SocketException('Connection refused', osError: OSError('Connection refused', 111))).error,
      SourceError.unreachable,
    );
    expect(networkError(StateError('x')).error, SourceError.unreachable);
  });

  test("a panel's address whose name is not found says so", () async {
    final s = XtreamSource(
      server: 'http://tv.invalid',
      username: 'u',
      password: 'p',
      client: MockClient((_) async => throw http.ClientException("Failed host lookup: 'tv.invalid'")),
    );
    await expectLater(s.login(), throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.dns)));
  });
}
