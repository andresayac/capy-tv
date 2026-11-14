// Two providers as one list, in the real app: combined from the playlists screen, a title both
// have shown once with both copies among its versions, and played through the combined list.
// The provider from ../.env stands in for both. Screenshots go to build/screenshots/combined-*.png.
//   flutter test integration_test/combined_flow_test.dart -d windows --dart-define-from-file=../.env
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/data/stream_stats.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/main.dart';
import 'package:iptv_player/player/player_screen.dart';
import 'package:iptv_player/ui/home_screen.dart';
import 'package:iptv_player/ui/screensaver.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

final shots = Shots('combined');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  IdleWatcher.enabled = false; // the screensaver would come during long waits
  MediaKit.ensureInitialized();
  final env = readEnv();

  testWidgets(
    'two providers combined: one card per title, both copies, and it plays',
    (t) async {
      await shots.init();
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      PlaylistStore.instance.reset();
      await ProfileStore.instance.load();
      await detectDevice(); // as main() does: on a TV, as a TV
      await useLandscapeFullScreen();
      // The first two providers in .env (XTREAM_CODE, then XTREAM_CODE_1 or _2); the first one twice
      // when there is only one
      final suffixes = ['', for (var n = 1; n < 10; n++) '_$n'].where((x) => (env['XTREAM_CODE$x'] ?? '').isNotEmpty);
      final pair = [suffixes.first, suffixes.length > 1 ? suffixes.elementAt(1) : suffixes.first];
      for (final (name, sfx) in [('Provider A', pair[0]), ('Provider B', pair[1])]) {
        await PlaylistStore.instance.add(
          Playlist.create(
            type: PlaylistType.xtream,
            url: env['XTREAM_CODE$sfx']!,
            name: name,
            username: env['XTREAM_USERNAME$sfx']!,
            password: env['XTREAM_PASSWORD$sfx']!,
          ),
        );
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
      Future<void> tapText(String text) async {
        expect(await waitFor(t, () => shown(find.text(text).hitTestable())), isTrue, reason: '"$text" should show');
        await t.tap(find.text(text).hitTestable().first);
        await t.pump();
      }

      // Combine them
      await tapText('Combine playlists');
      await tapText('Provider A');
      await tapText('Provider B');
      await shots.take(t, 'pick');
      await tapText('Save');
      expect(await waitFor(t, () => shown(find.text('Provider A + Provider B'))), isTrue, reason: 'the new list');
      await shots.take(t, 'playlists', private: true); // its rows show the users and the panels

      // Open it: the catalogs of both, each title once
      await tapText('Provider A + Provider B');
      expect(await waitFor(t, () => shown(find.byType(HomeScreen)), timeout: const Duration(seconds: 90)), isTrue);
      await tapText('Search');
      final field = find.byType(TextField).hitTestable().first;
      await t.tap(field);
      await t.pump();
      await t.enterText(field, 'spider man');
      final versions = find.textContaining(RegExp(r'^\d+ versions$'));
      expect(await waitFor(t, () => shown(versions), timeout: const Duration(seconds: 90)), isTrue);
      await shots.take(t, 'search');

      // A title's page lists the copies of both providers, and plays one of them
      await t.tapAt(t.getCenter(versions.first).translate(0, -120));
      await settle(t, const Duration(seconds: 1));
      final section = find.textContaining(RegExp(r'^\d+ versions$'));
      await t.scrollUntilVisible(section, 200, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('Provider A · '), findsWidgets);
      expect(find.textContaining('Provider B · '), findsWidgets);
      await shots.take(t, 'versions');
      await t.scrollUntilVisible(find.text('Play').hitTestable(), -200, scrollable: find.byType(Scrollable).first);
      await t.tap(find.text('Play').hitTestable().first);
      expect(await waitFor(t, () => shown(find.byType(PlayerScreen))), isTrue);
      final player = t.widget<PlayerScreen>(find.byType(PlayerScreen)).engine.player;
      expect(
        await waitFor(
          t,
          () => player.state.position > const Duration(seconds: 2),
          timeout: const Duration(seconds: 60),
        ),
        isTrue,
        reason: 'a movie of the combined list plays',
      );
      await shots.take(t, 'playing');
      // How long each provider took to start, as the app learnt it (no addresses)
      for (final (name, sfx) in [('Provider A', pair[0]), ('Provider B', pair[1])]) {
        // ignore: avoid_print
        print('$name starts in about ${StreamStats.expected('${env['XTREAM_CODE$sfx']}/x').inMilliseconds} ms');
      }
      Navigator.of(t.element(find.byType(PlayerScreen))).pop();
      await settle(t, const Duration(seconds: 1));
    },
    skip: env['XTREAM_CODE'] == null,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
