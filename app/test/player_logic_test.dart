// The player screen's own logic, with a player that does as each test says (support/fake_player):
// another copy when one does not open, a frozen channel opened again, a film resumed where it was
// left, the next episode at the end of one.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/player/play.dart';
import 'package:iptv_player/player/player_screen.dart';
import 'package:iptv_player/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_player.dart';

late AppSettings _settings;
late Library _library;

const _film = Movie(id: '5', name: 'A Film', extension: 'mkv');
const _channel = LiveChannel(id: '9', name: 'News 24', epgId: 'news.tv');
const _show = Series(id: 's', name: 'A Show');

Future<FakePlayer> _play(WidgetTester t, List<PlayItem> items, {FakePlayer? player}) async {
  final fake = player ?? FakePlayer();
  final navigator = GlobalKey<NavigatorState>();
  await t.pumpWidget(
    SettingsScope(
      settings: _settings,
      child: MaterialApp(
        navigatorKey: navigator,
        theme: buildTheme(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (_, child) => LibraryScope(library: _library, child: child!),
        home: const Scaffold(),
      ),
    ),
  );
  navigator.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(engine: FakeEngine(fake), items: items, library: _library),
    ),
  );
  await t.pump(const Duration(milliseconds: 500));
  await t.pump(const Duration(milliseconds: 500));
  return fake;
}

/// Lets [time] go by, a second at a time, as the player's timers and checks would see it.
Future<void> _wait(WidgetTester t, Duration time) async {
  for (var s = 0; s < time.inSeconds; s++) {
    await t.pump(const Duration(seconds: 1));
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    _settings = await AppSettings.load();
    _library = await Library.load('test', mainProfileId);
    await ProfileStore.instance.load();
    isTv = true;
  });

  tearDown(() => isTv = false);

  testWidgets('a copy that does not open gives way to the next one', (t) async {
    final fake = await _play(t, [
      PlayItem(
        url: 'http://a.example/movie/5.mkv',
        title: 'A Film',
        ref: MediaRef.movie(_film),
        alternates: const [PlayItem(url: 'http://b.example/movie/5.mkv', title: 'A Film')],
      ),
    ], player: FakePlayer(starts: (url) => url.startsWith('http://b.')));
    await _wait(t, const Duration(seconds: 3));
    expect([for (final m in fake.opened) Uri.parse(m.uri).host], ['a.example', 'b.example']);
    expect(find.text('Video not available'), findsNothing, reason: 'the other copy plays');
  });

  testWidgets('a live channel whose picture froze is opened again', (t) async {
    final fake = await _play(t, [
      PlayItem(url: 'http://x/live/9.ts', title: 'News 24', ref: MediaRef.channel(_channel)),
    ]);
    expect(fake.opened, hasLength(1));
    // Its time stops where it was: past the stall limit, and the pause before trying again
    await _wait(t, const Duration(seconds: 18));
    expect(fake.opened.length, greaterThanOrEqualTo(2), reason: 'opened again after it froze');
    expect(fake.opened.last.uri, 'http://x/live/9.ts');
  });

  testWidgets('a film left half way opens where it was, not at the start and then a jump', (t) async {
    final ref = MediaRef.movie(_film);
    await _library.record(ref, position: const Duration(minutes: 40), duration: const Duration(hours: 2));
    final fake = await _play(t, [PlayItem(url: 'http://x/movie/5.mkv', title: 'A Film', ref: ref)]);
    await _wait(t, const Duration(seconds: 2));
    expect(fake.opened.single.start, const Duration(minutes: 40));
    expect(fake.seeks, isEmpty);
  });

  testWidgets('at the end of an episode the next one starts', (t) async {
    const one = Episode(id: 'e1', season: 1, number: 1, title: 'Pilot');
    const two = Episode(id: 'e2', season: 1, number: 2, title: 'Second');
    final fake = await _play(t, [
      PlayItem(url: 'http://x/series/e1.mkv', title: 'A Show', ref: MediaRef.episode(_show, one)),
      PlayItem(url: 'http://x/series/e2.mkv', title: 'A Show', ref: MediaRef.episode(_show, two)),
    ], player: FakePlayer(length: const Duration(minutes: 45)));
    fake.end();
    await _wait(t, const Duration(seconds: 3));
    expect([for (final m in fake.opened) m.uri], ['http://x/series/e1.mkv', 'http://x/series/e2.mkv']);
  });
}
