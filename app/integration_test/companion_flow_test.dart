// The phone companion, end to end in the real app: the test plays the phone. It opens "Use your
// phone", loads the page the QR points to, sends the provider account from ../.env, then uses
// the phone as a remote and moves a backup. Screenshots go to build/screenshots/phone-*.png.
//   flutter test integration_test/companion_flow_test.dart -d windows
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/main.dart';
import 'package:iptv_player/remote/companion_server.dart';
import 'package:iptv_player/ui/screensaver.dart';
import 'package:media_kit/media_kit.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

final shots = Shots('phone');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  IdleWatcher.enabled = false; // the screensaver would come during long waits
  MediaKit.ensureInitialized();
  final env = readEnv();

  testWidgets(
    'a phone adds the playlist, drives the app and moves a backup',
    (t) async {
      await shots.init();
      await detectDevice(); // as main() does: on a TV, as a TV
      await useLandscapeFullScreen(); // as main() does: phones run the app in landscape
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final server = CompanionServer.instance;
      // On the desktop, listening on the network would make the firewall ask; the phone here is the test
      if (!Platform.isAndroid) server.bindOverride = InternetAddress.loopbackIPv4;
      final http = HttpClient();
      Future<(int, dynamic)> phone(String method, String path, [Object? body]) async {
        final req = await http.openUrl(method, server.url!.replace(path: path));
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        final res = await req.close();
        final text = await utf8.decodeStream(res);
        return (res.statusCode, path == '/' ? text : jsonDecode(text));
      }

      final settings = await AppSettings.load();
      await t.pumpWidget(
        RepaintBoundary(
          key: shots.root,
          child: SettingsScope(
            settings: settings,
            child: const IptvApp(locale: Locale('en')),
          ),
        ),
      );
      await settle(t);

      // 1. "Use your phone" shows the code to scan
      await t.tap(find.text('Use your phone').hitTestable());
      expect(await waitFor(t, () => shown(find.byType(QrImageView))), isTrue);
      expect(shown(find.text('Waiting for your phone…')), isTrue);
      await shots.take(t, 'qr');

      // 2. The phone opens the page the code points to and sends the account
      final (pageStatus, page) = await phone('GET', '/');
      expect(pageStatus, 200);
      expect(page, contains('"tabAdd":"Add list"'));
      // Sealed with the key the QR carries, as the page does
      Future<Map<String, String>> sealed(String path, Object body) async => {
        'sealed': await server.seal.seal(path, body),
      };
      final (status, added) = await phone(
        'POST',
        '/api/playlists',
        await sealed('/api/playlists', {
          'type': 'xtream',
          'name': 'From my phone',
          'url': env['XTREAM_CODE'],
          'username': env['XTREAM_USERNAME'],
          'password': env['XTREAM_PASSWORD'],
        }),
      );
      expect((status, added['name']), (200, 'From my phone'), reason: 'the app checks the account with the provider');
      expect(await waitFor(t, () => shown(find.textContaining('"From my phone" added'))), isTrue);
      await shots.take(t, 'received');
      // The screen goes back by itself to the list, where the playlist now is
      expect(await waitFor(t, () => !shown(find.byType(QrImageView))), isTrue);
      expect(shown(find.text('From my phone')), isTrue);
      expect(PlaylistStore.instance.playlists!.single.password, env['XTREAM_PASSWORD']);
      await shots.take(t, 'list', private: true); // its row shows the user and the panel

      // 3. Open it, then Account → Connect your phone, and connect as a remote
      await t.tap(find.text('From my phone').hitTestable());
      expect(await waitFor(t, () => shown(find.text('Make it yours'))), isTrue);
      if (shown(find.text('Settings').hitTestable())) {
        await t.tap(find.text('Settings').hitTestable().first);
      } else {
        await t.tap(find.byTooltip('Settings').hitTestable().first);
      }
      await settle(t, const Duration(seconds: 1));
      await t.scrollUntilVisible(find.text('Connect your phone'), 200, scrollable: find.byType(Scrollable).last);
      await t.pump();
      await t.tap(find.text('Connect your phone').hitTestable());
      expect(await waitFor(t, () => shown(find.byType(QrImageView))), isTrue);
      final ws = await WebSocket.connect(server.url!.replace(scheme: 'ws', path: '/ws').toString());
      final messages = ws.map((m) => jsonDecode(m as String) as Map<String, dynamic>).asBroadcastStream();
      expect((await messages.first)['type'], 'hello');
      expect(await waitFor(t, () => shown(find.text('Your phone is connected as a remote'))), isTrue);
      await shots.take(t, 'remote');

      // 4. The phone's back button goes back twice, to Home; its search box searches there
      void press(String key) => ws.add(jsonEncode({'type': 'key', 'key': key}));
      press('back');
      expect(await waitFor(t, () => !shown(find.byType(QrImageView))), isTrue);
      press('back');
      expect(await waitFor(t, () => shown(find.text('Make it yours'))), isTrue);
      ws.add(jsonEncode({'type': 'text', 'text': 'news'}));
      expect(await waitFor(t, () => shown(find.widgetWithText(TextField, 'news'))), isTrue, reason: 'Search shows it');
      await shots.take(t, 'search');
      // The arrows move the focus like a remote's
      final before = FocusManager.instance.primaryFocus;
      press('down');
      expect(await waitFor(t, () => FocusManager.instance.primaryFocus != before), isTrue);

      // 5. A backup goes to the phone and back: the same account is not added twice
      final (backupStatus, answer) = await phone('GET', '/api/backup');
      expect(backupStatus, 200);
      final backup = await server.seal.open('/api/backup', answer['sealed'] as String) as Map<String, dynamic>;
      expect((backup['playlists'] as List).single['password'], env['XTREAM_PASSWORD']);
      final (restored, result) = await phone('POST', '/api/backup', await sealed('/api/backup', backup));
      expect((restored, result['added'], result['updated']), (200, 0, 0));

      await ws.close();
      await server.stop();
      http.close();
    },
    skip: readEnv()['XTREAM_CODE'] == null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
