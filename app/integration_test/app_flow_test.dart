import 'dart:async';
import 'dart:convert';
// Full user journey through the real app against the real provider from ../.env:
// add the playlist through the form, then live TV, movies, series, home, search and account.
// Saves a screenshot per step to build/screenshots/flow-*.png for design review.
//   flutter test integration_test/app_flow_test.dart -d windows
// On Android the device cannot read ../.env, so pass it as defines; screenshots stay on the
// device under the app's external files folder (see tool/test_android.sh to pull them):
//   flutter test integration_test/app_flow_test.dart -d emulator-5554 --no-uninstall --dart-define-from-file=../.env
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/poster_wall.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/data/trending.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/main.dart';
import 'package:iptv_player/player/player_screen.dart';
import 'package:iptv_player/remote/companion_server.dart';
import 'package:iptv_player/sync/cast.dart';
import 'package:iptv_player/ui/home_screen.dart';
import 'package:iptv_player/ui/playlists_screen.dart';
import 'package:iptv_player/ui/preview.dart';
import 'package:iptv_player/ui/screensaver.dart';
import 'package:iptv_player/ui/trailer.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

final shots = Shots('flow');

Future<void> snap(WidgetTester t, String name, {bool private = false}) => shots.take(t, name, private: private);

/// Taps [f] as soon as it can be hit: content that moves (the hero carousel advances on its
/// own) may be mid-animation when the step starts.
Future<void> tapOn(WidgetTester t, Finder f) async {
  await waitFor(t, () => shown(f.hitTestable()));
  await t.tap(f.hitTestable().first);
  await t.pump();
}

Future<void> tapText(WidgetTester t, String text) => tapOn(t, find.text(text));

/// Scrolls [list] from its start until [target] is on screen.
Future<void> scrollTo(WidgetTester t, Finder target, Finder list) async {
  t.state<ScrollableState>(list).position.jumpTo(0);
  await t.pump();
  await t.scrollUntilVisible(target, 200, scrollable: list);
  await t.pump(); // lay out the new offset before hit testing
}

Future<void> goBack(WidgetTester t) async {
  await t.tap(find.byType(BackButton).hitTestable().first);
  await settle(t, const Duration(seconds: 1));
}

/// Waits until the player reports progress, then closes it with its own back button.
Future<bool> playAndClose(WidgetTester t, {Duration seekTo = Duration.zero}) async {
  if (!await waitFor(t, () => shown(find.byType(PlayerScreen)))) return false;
  // The current player each time: on Android it is replaced if the session falls back to software
  Player player() => t.widget<PlayerScreen>(find.byType(PlayerScreen)).player;
  final ok = await waitFor(t, () => player().state.position > const Duration(seconds: 2));
  if (ok && seekTo > Duration.zero) {
    await player().seek(seekTo);
    await waitFor(t, () => player().state.position >= seekTo);
  }
  // Controls auto-hide during playback; moving the mouse brings them back, as for a person
  final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(400, 300));
  await mouse.moveTo(const Offset(420, 320));
  await waitFor(t, () => shown(find.byIcon(Icons.arrow_back_rounded).hitTestable()));
  await snap(t, 'player');
  await t.tap(find.byIcon(Icons.arrow_back_rounded).hitTestable().first);
  await mouse.removePointer();
  await waitFor(t, () => !shown(find.byType(PlayerScreen)));
  return ok;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  IdleWatcher.enabled = false; // the screensaver would come during long waits
  MediaKit.ensureInitialized();
  final env = readEnv();

  testWidgets(
    'full journey with the real provider',
    (t) async {
      await shots.init();
      await detectDevice(); // as main() does: on a TV, as a TV
      await useLandscapeFullScreen(); // as main() does: phones run the app in landscape

      // What to look for in the UI, straight from the API
      final api = XtreamSource(
        server: env['XTREAM_CODE']!,
        username: env['XTREAM_USERNAME']!,
        password: env['XTREAM_PASSWORD']!,
        cacheDir: await getTemporaryDirectory(),
      );
      final allCats = await api.liveCategories();
      final liveCats = allCats.where((c) => !c.name.toUpperCase().contains('EVENT')).toList();
      final liveCat = liveCats.first;
      final channels = await api.liveChannels(liveCat.id);
      final movieCat = (await api.movieCategories()).first;
      final movie = (await api.movies(movieCat.id)).firstWhere((m) => m.poster != null);
      // A category with a channel that has something on air right now, per the XMLTV guide
      final guide = await api.guide();
      final everything = await api.liveChannels();
      final onAir = everything.where((c) => guide.nowOn(c.epgId) != null).toList();
      final guideChannel = onAir.first;
      final guideCat = allCats.firstWhere((c) => c.id == guideChannel.categoryId);
      final guideTitle = guide.nowOn(guideChannel.epgId)!.title;
      api.close();

      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({}); // the test account stays out of the system's vault
      final settings = await AppSettings.load();
      // As main() does, with a TMDB key: this week's trends from the very first start
      if (Trending.apiKey.isNotEmpty) {
        await Trending.refresh(language: 'en-US');
        expect(Trending.items.value, isNotEmpty, reason: 'TMDB answered');
      }
      // Emulators' hardware decoders stall on some streams: on a real device, HW_DECODER=true tests it
      if (Platform.isAndroid && !const bool.fromEnvironment('HW_DECODER')) await settings.set(decoder: 'software');
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

      // 1. Welcome → add the playlist through the form
      expect(shown(find.text('Your TV, your way')), isTrue);
      if (Trending.apiKey.isNotEmpty) {
        expect(
          await waitFor(t, () => shown(find.textContaining(RegExp('trending this week', caseSensitive: false)))),
          isTrue,
          reason: 'the backdrops',
        );
      }
      await snap(t, 'welcome');
      await tapText(t, 'Add playlist');
      await settle(t, const Duration(seconds: 1));
      await t.enterText(find.widgetWithText(TextFormField, 'Name'), 'My provider');
      await snap(t, 'add-playlist'); // before the account is in it
      await t.enterText(find.widgetWithText(TextFormField, 'Server URL'), env['XTREAM_CODE']!);
      await t.enterText(find.widgetWithText(TextFormField, 'Username'), env['XTREAM_USERNAME']!);
      await t.enterText(find.widgetWithText(TextFormField, 'Password'), env['XTREAM_PASSWORD']!);
      await tapText(t, 'Save');
      final saved = await waitFor(t, () => shown(find.text('My provider')) && !shown(find.text('Save')));
      await snap(t, 'after-save', private: true); // its row shows the user and the panel
      expect(saved, isTrue, reason: 'the form validates against the server and saves');

      // 2. Open it → Home starts empty
      await tapText(t, 'My provider');
      expect(await waitFor(t, () => shown(find.text('Make it yours'))), isTrue);
      if (Trending.apiKey.isNotEmpty) {
        // What is trending and this provider has, before anything has been watched
        expect(await waitFor(t, () => shown(find.text('TRENDING THIS WEEK'))), isTrue, reason: 'the hero');
      }
      await snap(t, 'home-empty');
      if (Trending.apiKey.isNotEmpty && TrailerBackdrop.supported) {
        // A trailer comes to life behind the hero: silent, without controls
        bool playing() => find
            .descendant(of: find.byType(TrailerBackdrop), matching: find.byType(AnimatedOpacity))
            .evaluate()
            .any((e) => (e.widget as AnimatedOpacity).opacity == 1);
        expect(await waitFor(t, playing, timeout: const Duration(seconds: 40)), isTrue, reason: 'a trailer plays');
        await settle(t, const Duration(seconds: 3));
        await snap(t, 'home-trailer');

        // Its page plays the trailer too, behind the title
        await tapOn(t, find.text('Details'));
        expect(await waitFor(t, () => shown(find.byType(BackButton))), isTrue);
        expect(await waitFor(t, playing, timeout: const Duration(seconds: 40)), isTrue, reason: 'on its page');
        await settle(t, const Duration(seconds: 3));
        await snap(t, 'detail-trailer');
        await goBack(t);
      }

      // Surprise me: a mood, then one title from the provider's catalog
      await tapText(t, 'Surprise me');
      await tapText(t, 'Action');
      await tapText(t, 'Pick one');
      expect(await waitFor(t, () => shown(find.text('Another one'))), isTrue);
      expect(shown(find.text('Details')), isTrue, reason: 'a title was picked');
      await snap(t, 'surprise');

      // Movie night: two phones vote through the companion server, the TV counts and crowns
      CompanionServer.instance.bindOverride = InternetAddress.loopbackIPv4; // no firewall question
      await tapText(t, 'Movie night');
      expect(await waitFor(t, () => shown(find.text('What shall we watch tonight?'))), isTrue);
      final server = CompanionServer.instance;
      expect(await waitFor(t, () => server.url != null), isTrue);
      final phone = HttpClient();
      Future<dynamic> ask(String method, String path, [Object? body]) async {
        final req = await phone.openUrl(method, server.url!.replace(path: path));
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        return jsonDecode(await utf8.decodeStream(await req.close()));
      }

      final titles = ((await ask('GET', '/api/night')) as Map)['titles'] as List;
      expect(titles.length, greaterThanOrEqualTo(2));
      for (final (voter, yes) in [('ana', true), ('bea', false)]) {
        for (final (i, title) in titles.indexed) {
          await ask('POST', '/api/night/vote', {'voter': voter, 'id': title['id'], 'yes': i == 1 ? true : yes});
        }
      }
      phone.close();
      expect(await waitFor(t, () => shown(find.text('2 phones have voted'))), isTrue);
      await snap(t, 'movie-night');
      await tapText(t, 'See the winner');
      expect(
        await waitFor(t, () => shown(find.text(titles[1]['title'] as String))),
        isTrue,
        reason: 'both said yes to it',
      );
      await snap(t, 'movie-night-winner');
      await goBack(t);
      await goBack(t);

      // 3. Live TV: a 24/7 category, then the first channel that plays
      await tapText(t, 'Live TV');
      final firstCat = find.text(displayCategoryName(allCats.first.name));
      expect(await waitFor(t, () => shown(firstCat)), isTrue);
      // The category list: a side column on wide screens, a row of chips on phones
      final catState = t.state<ScrollableState>(find.ancestor(of: firstCat, matching: find.byType(Scrollable)).first);
      final catList = find.byElementPredicate((e) => e is StatefulElement && e.state == catState);
      final catFinder = find.text(displayCategoryName(liveCat.name));
      await scrollTo(t, catFinder, catList);
      await t.tap(catFinder.hitTestable().first);
      expect(
        await waitFor(t, () => shown(find.text(channels.first.name))),
        isTrue,
        reason: 'channels of ${liveCat.name}',
      );
      await snap(t, 'live');
      var livePlayed = false;
      for (final c in channels.take(3)) {
        await t.tap(find.text(c.name).hitTestable().first);
        livePlayed = await playAndClose(t);
        if (livePlayed) break;
      }
      expect(livePlayed, isTrue, reason: 'one of the first channels of ${liveCat.name} plays');

      // 3b. The guide: what is on now shows on the channel card, and in the TV guide grid
      final guideCatFinder = find.text(displayCategoryName(guideCat.name));
      await scrollTo(t, guideCatFinder, catList);
      await t.tap(guideCatFinder.hitTestable().first);
      expect(
        await waitFor(t, () => shown(find.text(guideTitle))),
        isTrue,
        reason: '"${guideChannel.name}" should show "$guideTitle" on air',
      );
      await snap(t, 'live-on-air');
      await t.tap(find.byTooltip('TV guide').hitTestable().first);
      expect(
        await waitFor(t, () => shown(find.text(guideTitle).hitTestable())),
        isTrue,
        reason: 'the guide grid shows it',
      );
      await snap(t, 'tv-guide');
      await goBack(t);

      // 4. Movies: hero, details, My list, play, then "Continue"
      await tapText(t, 'Movies');
      expect(await waitFor(t, () => shown(find.text('MOVIES'))), isTrue);
      await snap(t, 'movies');
      await tapText(t, 'Details');
      expect(await waitFor(t, () => shown(find.text('Favorites'))), isTrue);
      await snap(t, 'movie-detail');
      await tapText(t, 'Favorites');
      expect(await waitFor(t, () => shown(find.text('In favorites'))), isTrue);
      await tapText(t, 'Play');
      expect(await playAndClose(t, seekTo: const Duration(minutes: 3)), isTrue, reason: 'movie plays');
      expect(
        await waitFor(t, () => shown(find.textContaining('Continue · 3:0'))),
        isTrue,
        reason: 'detail offers to continue',
      );
      await snap(t, 'movie-continue');
      await goBack(t);

      // 5. Series: open the featured one from the hero, play from its play button
      await tapText(t, 'Series');
      expect(await waitFor(t, () => shown(find.text('Details').hitTestable())), isTrue, reason: 'series hero');
      await snap(t, 'series');
      await tapText(t, 'Details');
      final playEpisode = find.textContaining(RegExp(r'S\d+ · E\d+'));
      expect(await waitFor(t, () => shown(playEpisode.hitTestable())), isTrue);
      await snap(t, 'series-detail');
      await tapOn(t, playEpisode);
      expect(await playAndClose(t, seekTo: const Duration(minutes: 2)), isTrue, reason: 'episode plays');
      await goBack(t);

      // 5b. Sent from another device of the account ("Send to"): the movie plays here from where
      // it was there, over whatever screen was open
      final watched = currentLibrary.value!.history.firstWhere((h) => h.ref.kind == MediaKind.movie).ref;
      castRequest.value = CastRequest(
        at: DateTime.now(),
        playlistId: currentLibrary.value!.playlistId,
        ref: watched,
        position: const Duration(minutes: 3),
        from: 'Living room',
      );
      expect(await waitFor(t, () => shown(find.byType(PlayerScreen))), isTrue, reason: 'it plays here');
      final sent = t.widget<PlayerScreen>(find.byType(PlayerScreen)).player;
      expect(
        await waitFor(t, () => sent.state.position >= const Duration(minutes: 3), timeout: const Duration(seconds: 40)),
        isTrue,
        reason: 'from where it was',
      );
      expect(castRequest.value, isNull, reason: 'taken');
      Navigator.of(t.element(find.byType(PlayerScreen))).pop();
      await waitFor(t, () => !shown(find.byType(PlayerScreen)));

      // 6. Home is now personal
      await tapText(t, 'Home');
      expect(await waitFor(t, () => shown(find.text('Continue watching'))), isTrue);
      // A landscape phone shows Home in a few screens: scroll down to each row
      final home = find
          .descendant(of: find.byKey(const PageStorageKey('home')), matching: find.byType(Scrollable))
          .first;
      // Movies and series first, live TV after
      if (Trending.apiKey.isNotEmpty) {
        // This week's most watched that the provider has, numbered
        await t.scrollUntilVisible(find.text('Most watched movies this week'), 200, scrollable: home);
        await t.scrollUntilVisible(find.text('Most watched series this week'), 200, scrollable: home);
        await snap(t, 'home-most-watched');
        // A poster kept under the mouse opens its preview, and closes when the mouse leaves
        final card = find.byType(PreviewedPoster).hitTestable().first;
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(t.getCenter(card));
        bool previewShown() => shown(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_PreviewCard'));
        expect(await waitFor(t, previewShown, timeout: const Duration(seconds: 5)), isTrue, reason: 'the preview');
        await snap(t, 'preview');
        await mouse.moveTo(const Offset(5, 5));
        expect(await waitFor(t, () => !previewShown(), timeout: const Duration(seconds: 5)), isTrue, reason: 'closed');
        await mouse.removePointer();
      }
      for (final row in ['Favorite movies', 'Recently watched channels']) {
        await t.scrollUntilVisible(find.text(row), 200, scrollable: home);
      }
      await snap(t, 'home');

      // 7. Search: before typing, what saves typing with a remote; then it finds the movie
      await tapText(t, 'Search');
      if (Trending.apiKey.isNotEmpty) {
        expect(await waitFor(t, () => shown(find.text('Most watched movies this week'))), isTrue);
      }
      await snap(t, 'search-start');
      // Its words out of order and without accents still find it, best match first
      await t.enterText(find.byType(TextField).hitTestable().first, movie.name);
      // Done typing: the keyboard goes away (on a landscape phone it covers the results)
      FocusManager.instance.primaryFocus?.unfocus();
      expect(
        await waitFor(t, () => shown(find.text(movie.name).hitTestable()), timeout: const Duration(seconds: 90)),
        isTrue,
        reason: 'search finds "${movie.name}"',
      );
      await snap(t, 'search');
      // A word cut short finds many: the best first, and all of them a tap away
      final field = find.byType(TextField).hitTestable().first;
      await t.tap(field); // focused again, as a person would, after the keyboard went away
      await t.pump();
      await t.enterText(field, 'spider man');
      expect(await waitFor(t, () => shown(find.textContaining(RegExp(r'Movies · \d{2,}')))), isTrue);
      await snap(t, 'search-many');
      // A title listed once per language or quality comes once; its page has the versions
      final versions = find.textContaining(RegExp(r'^\d+ versions$'));
      if (shown(versions)) {
        await t.tapAt(t.getCenter(versions.first).translate(0, -120)); // its poster, above the line
        await settle(t, const Duration(seconds: 1));
        // Built once scrolled to: further down the page
        final section = find.textContaining(RegExp(r'^\d+ versions$'));
        final page = find.byType(Scrollable).first;
        await t.scrollUntilVisible(section, 200, scrollable: page);
        await snap(t, 'versions');
        await goBack(t);
      }

      // 8. Settings: in the side navigation on wide screens, at the top of Home in a narrow window
      if (shown(find.text('Settings').hitTestable())) {
        await tapText(t, 'Settings');
      } else {
        await tapText(t, 'Home');
        await t.tap(find.byTooltip('Settings').hitTestable().first);
        await t.pump();
      }
      expect(await waitFor(t, () => shown(find.text('Active'))), isTrue);
      // What the list has: movies, series and channels, counted
      expect(await waitFor(t, () => shown(find.text('Channels'))), isTrue, reason: 'the list counted in Settings');
      await snap(t, 'account');
      // The lists again from the provider, under Home, while Settings stays open
      await scrollTo(t, find.text('Update channels and movies'), find.byType(Scrollable).last);
      await tapText(t, 'Update channels and movies');
      expect(
        await waitFor(t, () => shown(find.textContaining('List updated')), timeout: const Duration(seconds: 120)),
        isTrue,
        reason: 'the provider answered and the new lists are in',
      );
      await goBack(t);

      // 8b. Someone else's turn: who is watching is on Home, and the same playlist opens again
      // for the profile picked, without going through the welcome screen
      final leo = await ProfileStore.instance.add('Leo', kids: true);
      await tapText(t, 'Home');
      // At the top of Home, where an earlier step left it scrolled down
      t
          .state<ScrollableState>(
            find.descendant(of: find.byKey(const PageStorageKey('home')), matching: find.byType(Scrollable)).first,
          )
          .position
          .jumpTo(0);
      await settle(t, const Duration(seconds: 1));
      await t.tap(find.byTooltip('Switch profile').hitTestable().first);
      expect(await waitFor(t, () => shown(find.text("Who's watching?"))), isTrue);
      await settle(t, const Duration(seconds: 2));
      await snap(t, 'switch-profile');
      await tapText(t, 'Leo');
      expect(
        await waitFor(
          t,
          () =>
              ProfileStore.instance.current.id == leo.id &&
              shown(find.byType(HomeScreen)) &&
              !shown(find.text("Who's watching?")),
          timeout: const Duration(seconds: 40),
        ),
        isTrue,
        reason: 'back in the playlist, as Leo',
      );
      expect(currentLibrary.value?.profileId, leo.id, reason: "Leo's favorites and history");
      await settle(t, const Duration(seconds: 3));
      await snap(t, 'home-as-leo');

      // 9. Back on the welcome screen: the provider's best posters are noted now, for a device
      // without a TMDB key
      expect(PosterWall.posters.value.length, greaterThanOrEqualTo(8), reason: 'noted when the catalog loaded');
      Navigator.of(t.element(find.byType(HomeScreen))).popUntil((r) => r.isFirst);
      expect(await waitFor(t, () => shown(find.byType(PlaylistsScreen))), isTrue);
      await settle(t, const Duration(seconds: 5)); // the images come in
      await snap(t, 'welcome-again', private: true);
      // And behind the other screens out of the playlist, under their see-through bar
      for (final (button, title, name) in [
        ('Sync', 'Your lists everywhere', 'sync'),
        ('Profiles', 'Profiles and parental control', 'profiles'),
      ]) {
        await tapText(t, button);
        expect(await waitFor(t, () => shown(find.text(title).hitTestable())), isTrue);
        await settle(t, const Duration(seconds: 1));
        await snap(t, '$name-posters');
        await goBack(t);
      }

      // The screensaver an idle screen shows, and any key back
      unawaited(
        Navigator.of(t.element(find.byType(PlaylistsScreen)))
            .push(MaterialPageRoute<void>(builder: (_) => const ScreenSaver())),
      );
      await settle(t, const Duration(seconds: 4));
      expect(shown(find.byType(ScreenSaver)), isTrue);
      await snap(t, 'screensaver');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(await waitFor(t, () => !shown(find.byType(ScreenSaver))), isTrue, reason: 'a key leaves it');
    },
    skip: env['XTREAM_CODE'] == null,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
