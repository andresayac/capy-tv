// What each profile really sees of a list with an adult group, in the real app: when the list
// opens, after "Update list", and when someone else takes over with the list open. Served from
// this machine, no provider needed:
//   flutter test integration_test/adult_filter_flow_test.dart -d windows
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/main.dart';
import 'package:iptv_player/ui/home_screen.dart';
import 'package:iptv_player/ui/screensaver.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  IdleWatcher.enabled = false; // the screensaver would come during long waits

  testWidgets('a kids profile never sees the adult group, however the list got there', (t) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    PlaylistStore.instance.reset();
    final store = ProfileStore.instance;
    await store.load();

    final lists = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${lists.port}';
    lists.listen((req) async {
      if (req.uri.path != '/list.m3u') req.response.statusCode = 404;
      if (req.uri.path == '/list.m3u') {
        req.response.headers.contentType = ContentType('audio', 'x-mpegurl');
        req.response.write(
          '#EXTM3U\n'
          '#EXTINF:-1 group-title="Adults",Night Channel\n$base/live/1.ts\n'
          '#EXTINF:-1 group-title="Cartoons",Bunny Channel\n$base/live/2.ts\n'
          '#EXTINF:-1 group-title="Adults",Night Thing\n$base/movie/1.mp4\n'
          '#EXTINF:-1 group-title="Cartoons",Bunny Film\n$base/movie/2.mp4\n'
          '#EXTINF:-1 group-title="Grown-ups",Tax Film\n$base/movie/3.mp4\n',
        );
      }
      await req.response.close();
    });
    addTearDown(() => lists.close(force: true));
    // Two, so that none opens by itself
    await PlaylistStore.instance.add(Playlist.create(type: PlaylistType.m3u, url: '$base/list.m3u', name: 'Family'));
    await PlaylistStore.instance.add(Playlist.create(type: PlaylistType.m3u, url: '$base/list.m3u', name: 'Spare'));

    await store.update(store.current.copyWith(name: 'Ana', adult: true));
    await store.add('Leo', kids: true);
    await store.load(); // as the app starts: two profiles, so it asks who is watching

    await detectDevice(); // as main() does: on a TV, as a TV
    await useLandscapeFullScreen();
    final settings = await AppSettings.load();
    await t.pumpWidget(
      SettingsScope(
        settings: settings,
        child: const IptvApp(locale: Locale('en')),
      ),
    );

    Future<void> tapText(String text) async {
      expect(await waitFor(t, () => shown(find.text(text).hitTestable())), isTrue, reason: '"$text" should show');
      await t.tap(find.text(text).hitTestable().first);
      await t.pump();
    }

    Future<void> inTheList(String name) async {
      expect(
        await waitFor(
          t,
          () => store.current.name == name && shown(find.byType(HomeScreen)) && !shown(find.text("Who's watching?")),
          timeout: const Duration(seconds: 40),
        ),
        isTrue,
        reason: 'in the list, as $name',
      );
      await settle(t);
    }

    Future<void> search(String text) async {
      await t.enterText(find.byType(TextField).hitTestable().first, text);
      await settle(t);
    }

    // The tabs, then a search for one title of each group
    Future<void> checkTabs({required bool adults, required String who}) async {
      final expected = adults ? findsWidgets : findsNothing;
      for (final tab in ['Movies', 'Live TV']) {
        await tapText(tab);
        expect(await waitFor(t, () => shown(find.text('Cartoons'))), isTrue, reason: '$tab has loaded for $who');
        if (adults) await waitFor(t, () => shown(find.text('Adults')));
        await settle(t, const Duration(seconds: 1));
        expect(find.text('Adults'), expected, reason: '$tab as $who');
        if (tab == 'Movies' && !adults) {
          expect(find.text('Grown-ups'), findsNothing, reason: 'not for children, as $who');
        }
      }
      await tapText('Series');
      await settle(t, const Duration(seconds: 1));
      expect(find.text('Adults'), findsNothing, reason: 'an M3U has no series, as $who');
      await tapText('Search');
      await search('Bunny');
      expect(await waitFor(t, () => shown(find.text('Bunny Film'))), isTrue, reason: 'the search works, as $who');
      await search('Night');
      if (adults) await waitFor(t, () => shown(find.text('Night Thing')));
      expect(find.text('Night Thing'), expected, reason: 'searched, as $who');
      await search('');
    }

    Future<void> changeTo(String name) async {
      await tapText('Home');
      await settle(t, const Duration(seconds: 1));
      await t.tap(find.byTooltip('Switch profile').hitTestable().first);
      expect(await waitFor(t, () => shown(find.text("Who's watching?"))), isTrue);
      await tapText(name);
      await inTheList(name);
    }

    // Opened from the list of playlists
    await tapText('Leo');
    await tapText('Family');
    await inTheList('Leo');
    await checkTabs(adults: false, who: 'Leo, on opening');

    // "Update list" brings the whole list again
    if (shown(find.text('Settings').hitTestable())) {
      await tapText('Settings');
    } else {
      await tapText('Home');
      await t.tap(find.byTooltip('Settings').hitTestable().first);
      await t.pump();
    }
    final refresh = find.text('Update channels and movies');
    expect(await waitFor(t, () => refresh.evaluate().isNotEmpty), isTrue);
    await t.scrollUntilVisible(refresh, 200, scrollable: find.byType(Scrollable).last);
    await tapText('Update channels and movies');
    expect(
      await waitFor(t, () => shown(find.textContaining('List updated')), timeout: const Duration(seconds: 60)),
      isTrue,
    );
    await t.tap(find.byType(BackButton).hitTestable().first);
    await settle(t, const Duration(seconds: 1));
    await checkTabs(adults: false, who: 'Leo, after updating');

    // A grown-up who chose to see it does, and it goes again when Leo takes over with the list open
    await changeTo('Ana');
    await checkTabs(adults: true, who: 'Ana');
    await changeTo('Leo');
    await checkTabs(adults: false, who: 'Leo, taking over');
  });
}
