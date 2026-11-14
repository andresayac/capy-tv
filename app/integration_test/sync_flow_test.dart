// Account sync in the real app: another device of the account has a playlist; this one signs in
// from the Sync screen, gets it, and then gets the next one live. Then an account made here: its
// recovery key, a new password, a new recovery key, and back in with it after forgetting the
// password. Uses a sync server built from ../server (see test/support/sync_server.dart).
// Screenshots go to build/screenshots/sync-*.png.
//   flutter test integration_test/sync_flow_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/main.dart';
import 'package:iptv_player/sync/sync_client.dart';
import 'package:iptv_player/sync/sync_service.dart';
import 'package:iptv_player/ui/screensaver.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/sync_server.dart';
import 'support.dart';

final shots = Shots('sync');

// enterText only reconnects the keyboard when the field changes: a tap first makes sure the same
// field typed into twice is listening again
Future<void> fill(WidgetTester t, String label, String value) async {
  final field = find.widgetWithText(TextFormField, label);
  await t.tap(field);
  await t.pump();
  await t.enterText(field, value);
  await t.pump();
  expect(
    t.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).controller.text,
    value,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  IdleWatcher.enabled = false; // the screensaver would come during long waits

  testWidgets('sign in on a new device and the lists follow', (t) async {
    final (server, why) = await TestSyncServer.start();
    if (server == null) return markTestSkipped(why);
    addTearDown(server.stop);
    await shots.init();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    PlaylistStore.instance.reset();
    await detectDevice(); // as main() does: on a TV, as a TV
    await useLandscapeFullScreen();

    // The other device: creates the account and sends a playlist with a favorite
    const email = 'ana@example.com', password = 'correct horse battery';
    final phone = SyncClient(server.url);
    final keys = await createAccountElsewhere(phone, email, password, 'Pixel 9');
    Future<RemoteItem> item(String key, Map<String, dynamic> body) async {
      final id = await keys.itemId(key);
      return RemoteItem(id, await keys.seal(id, {'v': 2, 'key': key, ...body}));
    }

    const news = Playlist(id: 'p1', name: 'News & sports', type: PlaylistType.m3u, url: 'http://lists.test/news.m3u');
    final now = DateTime.now().millisecondsSinceEpoch;
    await phone.put([
      await item('playlist/p1', {'at': now, 'data': news.toJson()}),
      await item('library/p1', {
        'data': Library.fromJson({
          'favorites': [
            {'kind': 'live', 'id': '7', 'title': 'World News'},
          ],
          'favAt': {'live:7': now},
        }).toJson(),
      }),
    ]);

    // This device: nothing yet
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
    await waitFor(t, () => shown(find.text('Sync')));
    await shots.take(t, 'welcome');
    await t.tap(find.text('Sync'));
    await waitFor(t, () => shown(find.text('Your lists everywhere')));
    await shots.take(t, 'sign-in');

    await fill(t, 'Sync server', server.url.toString());
    await fill(t, 'Email', email);
    await fill(t, 'Password', 'not it');
    await t.tap(find.text('Sign in'));
    expect(await waitFor(t, () => shown(find.text('Wrong email or password'))), isTrue);
    await shots.take(t, 'wrong-password');

    await fill(t, 'Password', password);
    final started = DateTime.now();
    await t.tap(find.text('Sign in'));
    await t.pump(const Duration(milliseconds: 200));
    if (shown(find.text('Securing your keys…'))) await shots.take(t, 'securing-keys');
    expect(await waitFor(t, () => shown(find.textContaining('Up to date'))), isTrue);
    debugPrint('signed in and synced in ${DateTime.now().difference(started).inMilliseconds} ms');
    await waitFor(t, () => shown(find.text('Pixel 9')));
    await shots.take(t, 'signed-in');

    // Back on the playlists: the list from the other device, with its favorite
    await t.tap(find.byType(BackButton));
    expect(await waitFor(t, () => shown(find.text('News & sports'))), isTrue);
    final here = (await PlaylistStore.instance.load()).single;
    expect((await Library.load(here.id, mainProfileId)).favorites(MediaKind.live).single.title, 'World News');
    await shots.take(t, 'playlists-synced');

    // A list added on the other device shows up here by itself
    const movies = Playlist(id: 'p2', name: 'Movies', type: PlaylistType.m3u, url: 'http://lists.test/movies.m3u');
    await phone.put([
      await item('playlist/p2', {'at': now + 1, 'data': movies.toJson()}),
    ]);
    expect(await waitFor(t, () => shown(find.text('Movies')), timeout: const Duration(seconds: 10)), isTrue);
    await shots.take(t, 'live-update');

    await SyncService.instance.signOut();
    phone.close();
  });

  testWidgets('a new account keeps its recovery key, and gets back in with it', (t) async {
    final (server, why) = await TestSyncServer.start();
    if (server == null) return markTestSkipped(why);
    addTearDown(server.stop);
    await shots.init();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    PlaylistStore.instance.reset();
    await detectDevice(); // as main() does: on a TV, as a TV
    await useLandscapeFullScreen();
    await PlaylistStore.instance.add(
      const Playlist(id: 'own', name: 'Free channels', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u'),
    );

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
    await waitFor(t, () => shown(find.text('Sync')));
    await t.tap(find.text('Sync'));
    await waitFor(t, () => shown(find.text('Your lists everywhere')));

    String recoveryKey() => t.widget<Text>(find.byKey(const ValueKey('recoveryKey'))).data!.replaceAll('\n', '-');
    Finder action(String label) => find.widgetWithText(TextButton, label);

    // Create the account: the recovery key shows once
    const email = 'ines@example.com';
    await fill(t, 'Sync server', server.url.toString());
    await fill(t, 'Email', email);
    await t.tap(find.text('New here? Create an account'));
    await t.pump();
    await fill(t, 'Password', 'first pass phrase');
    await fill(t, 'Repeat password', 'first pass phrase');
    await shots.take(t, 'create');
    await t.tap(find.text('Create sync account'));
    expect(await waitFor(t, () => shown(find.text('Your recovery key'))), isTrue);
    final first = recoveryKey();
    expect(first, matches(RegExp(r'^([0-9A-Z]{4}-){7}[0-9A-Z]{4}$')));
    await shots.take(t, 'recovery-key');
    await t.tap(find.text("I've written it down"));
    expect(await waitFor(t, () => shown(find.textContaining('Up to date'))), isTrue);
    await shots.take(t, 'created');

    // A new password: the current one is needed
    await t.tap(find.text('Change password'));
    await waitFor(t, () => shown(find.text('Current password')));
    await fill(t, 'Current password', 'not it');
    await fill(t, 'New password', 'second pass phrase');
    await fill(t, 'Repeat password', 'second pass phrase');
    await t.tap(action('Change password'));
    expect(await waitFor(t, () => shown(find.text('Wrong password'))), isTrue);
    await shots.take(t, 'change-password-wrong');
    await fill(t, 'Current password', 'first pass phrase');
    await t.tap(action('Change password'));
    expect(await waitFor(t, () => shown(find.text('Password changed'))), isTrue);
    expect(await waitFor(t, () => !shown(find.text('Current password'))), isTrue, reason: 'the dialog closes');

    // A new recovery key, in place of the first
    await t.tap(find.text('New recovery key'));
    await waitFor(t, () => shown(find.text('Password')));
    await shots.take(t, 'new-recovery-key');
    await fill(t, 'Password', 'second pass phrase');
    await t.tap(action('New recovery key'));
    expect(await waitFor(t, () => shown(find.text('Your recovery key'))), isTrue);
    final second = recoveryKey();
    expect(second, isNot(first));
    await t.tap(find.text("I've written it down"));
    // Not pumpAndSettle: the posters behind the screen keep drifting
    await waitFor(t, () => !shown(find.text('Your recovery key')));

    // Signed out and the password forgotten: the recovery key gets back in, with everything
    await t.tap(find.text('Sign out'));
    expect(await waitFor(t, () => shown(find.text('Forgot your password?'))), isTrue);
    await t.tap(find.text('Forgot your password?'));
    await t.pump();
    await fill(t, 'Recovery key', first);
    await fill(t, 'New password', 'third pass phrase');
    await fill(t, 'Repeat password', 'third pass phrase');
    await t.tap(find.text('Set new password'));
    expect(await waitFor(t, () => shown(find.text('Wrong email or recovery key'))), isTrue, reason: 'replaced');
    await shots.take(t, 'recover-wrong-key');
    await fill(t, 'Recovery key', second.toLowerCase().replaceAll('-', ' '));
    await t.tap(find.text('Set new password'));
    expect(await waitFor(t, () => shown(find.textContaining('Up to date'))), isTrue);
    await shots.take(t, 'recovered');
    expect(SyncService.instance.email, email);
    expect((await PlaylistStore.instance.load()).single.name, 'Free channels');

    // And the new password is the one that works now
    await SyncService.instance.signOut();
    await expectLater(
      SyncService.instance.signIn(server: server.url, email: email, password: 'second pass phrase'),
      throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.credentials)),
    );
    await SyncService.instance.signIn(server: server.url, email: email, password: 'third pass phrase');
    await SyncService.instance.signOut();
  });
}
