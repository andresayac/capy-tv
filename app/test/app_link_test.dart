// The pair link, which the companion page builds, Android opens the app for and PairScreen reads;
// and updates, handed to Android's installer under the app's own id.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/main.dart';
import 'package:iptv_player/ui/pair_screen.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('the companion page links with the scheme Android opens the app for', () {
    expect(_read('assets/companion/index.html'), contains("'capytv://open/pair?'"));
    expect(
      _read('android/app/src/main/AndroidManifest.xml'),
      contains('<data android:scheme="capytv" android:host="open" android:pathPrefix="/pair"/>'),
    );
  });

  test('a pair link opens the pair screen, whole or as the route Flutter makes of it', () {
    final key = Uri.encodeQueryComponent(base64.encode(List.filled(32, 7)));
    final query = 'u=http%3A%2F%2F192.168.1.20%3A8765&t=K7Q3X&n=Living+room&k=$key';
    for (final name in ['capytv://open/pair?$query', '/pair?$query']) {
      expect(PairScreen.forRoute(name)?.link.queryParameters, {
        'u': 'http://192.168.1.20:8765',
        't': 'K7Q3X',
        'n': 'Living room',
        'k': base64.encode(List.filled(32, 7)),
      }, reason: name);
    }
    expect(PairScreen.forRoute('/pair?u=http%3A%2F%2F192.168.1.20%3A8765'), isNull); // no session code
    expect(PairScreen.forRoute('/settings?u=x&t=y'), isNull);
    expect(PairScreen.forRoute(null), isNull);
    for (final bad in [
      'u=https%3A%2F%2F192.168.1.20&t=K&k=$key', // not a device on this network
      'u=http%3A%2F%2Fattacker.example&t=K&k=$key',
      'u=http%3A%2F%2F8.8.8.8%3A80&t=K&k=$key',
      'u=http%3A%2F%2F192.168.1.20&t=K', // without the key
      'u=http%3A%2F%2F192.168.1.20&t=K&k=short',
      'u=%3A%2F%2F&t=K&k=$key',
    ]) {
      expect(PairScreen.forRoute('/pair?$bad'), isNull, reason: bad);
    }
    final tailscale = 'u=http%3A%2F%2F100.101.1.2%3A8765&t=K&k=$key';
    expect(PairScreen.forRoute('/pair?$tailscale'), isNotNull);
  });

  test('a device named with "#" keeps its key and its name, also once the app is open', () {
    final page = _read('assets/companion/index.html');
    final link = page.split('\n').singleWhere((line) => line.contains("'capytv://open/pair?'"));
    expect(link.trim(), endsWith('n: DEVICE });'), reason: 'the name last, so a "#" in it cuts nothing else');
    final key = base64.encode(List.filled(32, 7));
    final query = Uri(queryParameters: {'u': 'http://192.168.1.20:8765', 't': 'K7Q3X', 'k': key, 'n': 'TV #2'}).query;
    for (final name in ['capytv://open/pair?$query', Uri.decodeComponent('/pair?$query')]) {
      final screen = PairScreen.forRoute(name);
      expect(screen?.link.queryParameters['k'], key, reason: name);
      expect(screen?.device, 'TV #2', reason: name);
    }
  });

  test('a link never starts the app past "Who\'s watching?"', () {
    final key = Uri.encodeQueryComponent(base64.encode(List.filled(32, 7)));
    final routes = initialRoutes('capytv://open/pair?u=http%3A%2F%2F192.168.1.20&t=K&k=$key');
    expect([for (final r in routes) r.settings.name?.split(':').first], ['/', 'capytv']);
    expect(initialRoutes('/'), hasLength(1));
  });

  test("updates reach Android's installer through a provider named after the app's own id", () {
    // Read where it runs, not written down: the id changed once (README, "Updates from your server")
    expect(
      _read('android/app/src/main/AndroidManifest.xml'),
      contains(r'android:authorities="${applicationId}.updates"'),
    );
    expect(
      _read('android/app/src/main/kotlin/com/capytv/app/MainActivity.kt'),
      contains(r'FileProvider.getUriForFile(this, "$packageName.updates", apk)'),
    );
  });
}
