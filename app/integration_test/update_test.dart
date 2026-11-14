// Updates from the sync server, on Android: a newer build found on the server, downloaded, and
// handed to Android's installer; or, until the user allows the app to install others, the way to
// that setting. Needs a sync server with a release of a higher build, at SYNC_TEST:
//   APP_DIR=<folder with app.json and an APK> PORT=8095 DATA=:memory: SIGNIN_LIMIT=1000 SIGNUP_OPEN=1 server
//   flutter test integration_test/update_test.dart -d <device> --dart-define=SYNC_TEST=http://10.0.2.2:8095/
// Run it once as installed (Android asks), and once after
//   adb shell appops set com.capytv.app.test REQUEST_INSTALL_PACKAGES allow
// to see both ways. It creates an account on that server, and deletes it at the end; it runs only
// against one on this machine or the local network, never a real one.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/sync/app_update.dart';
import 'package:iptv_player/sync/sync_service.dart';
import 'package:iptv_player/ui/app_update_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = String.fromEnvironment('SYNC_TEST');

/// A test server: this machine, the emulator's way to it, or a private address. Not the real one.
bool _isTestServer(Uri u) {
  final host = u.host;
  if (host == 'localhost' || host == '10.0.2.2') return true;
  final ip = InternetAddress.tryParse(host);
  if (ip == null) return false;
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final b = ip.rawAddress;
  return ip.type == InternetAddressType.IPv4
      ? b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168)
      : (b[0] & 0xfe) == 0xfc; // fc00::/7
}

Future<bool> waitFor(WidgetTester t, bool Function() ok, {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (ok()) return true;
    await t.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return ok();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a newer build on the server: offered, downloaded, to the installer', skip: _server.isEmpty, (t) async {
    if (!Platform.isAndroid) return;
    expect(_isTestServer(Uri.parse(_server)), isTrue, reason: 'SYNC_TEST is to be a test server, never a real one');
    // This device's own session and data are not to be touched
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    SyncService.kdf = (memoryKiB: 1024, passes: 1);
    await SyncService.instance.createAccount(
      server: Uri.parse(_server),
      email: 'update-${DateTime.now().millisecondsSinceEpoch}@example.com',
      password: 'correct horse battery',
    );
    await SyncService.instance.checkForUpdate();
    final release = AppUpdate.available.value;
    expect(release, isNotNull, reason: 'the build on the server is newer than this one');

    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(onPressed: () => showAppUpdate(context, release!), child: const Text('open')),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Capy TV ${release!.label}'), findsOneWidget);

    final allowed = await AppUpdate.canInstall();
    await t.tap(find.text('Update'));
    if (allowed) {
      expect(
        await waitFor(t, () => find.byType(AlertDialog).evaluate().isEmpty),
        isTrue,
        reason: "downloaded, checked, and handed to Android's installer",
      );
    } else {
      expect(await waitFor(t, () => find.text('Allow the update').evaluate().isNotEmpty), isTrue);
      expect(await AppUpdate.allowInstall(), isTrue, reason: "Android's setting for it opens");
    }
    await SyncService.instance.deleteAccount('correct horse battery'); // none left behind
  });
}
