// A TV remote's focus lands only where it shows: never on a screen's own key listener, or on
// something behind the buttons, where nothing shows it and the remote seems lost.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// The web view a real Android build registers for flutter_inappwebview
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/player/play.dart';
import 'package:iptv_player/player/player_screen.dart';
import 'package:iptv_player/remote/remote_input.dart';
import 'package:iptv_player/ui/catalog.dart';
import 'package:iptv_player/ui/common.dart';
import 'package:iptv_player/ui/detail_screens.dart';
import 'package:iptv_player/ui/remote_keys.dart';
import 'package:iptv_player/ui/theme.dart';
import 'package:iptv_player/ui/trailer.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _trailer = 'dQw4w9WgXcQ';
const _arrows = [
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
];

/// A film playing: it opens, starts, and goes on until stopped.
class _FakePlayer implements Player {
  final _position = StreamController<Duration>.broadcast();

  @override
  PlatformPlayer? platform;

  @override
  var state = const PlayerState(playing: true, duration: Duration(hours: 2), width: 1920, height: 1080);

  @override
  late final stream = PlayerStream(
    const Stream.empty(), // playlist
    const Stream.empty(), // playing
    const Stream.empty(), // completed
    _position.stream,
    const Stream.empty(), // duration
    const Stream.empty(), // volume
    const Stream.empty(), // rate
    const Stream.empty(), // pitch
    const Stream.empty(), // buffering
    const Stream.empty(), // bufferingPercentage
    const Stream.empty(), // buffer
    const Stream.empty(), // playlistMode
    const Stream.empty(), // shuffle
    const Stream.empty(), // audioParams
    const Stream.empty(), // videoParams
    const Stream.empty(), // audioBitrate
    const Stream.empty(), // audioDevice
    const Stream.empty(), // audioDevices
    const Stream.empty(), // track
    const Stream.empty(), // tracks
    const Stream.empty(), // width
    const Stream.empty(), // height
    const Stream.empty(), // subtitle
    const Stream.empty(), // log
    const Stream.empty(), // error
  );

  @override
  Future<void> open(Playable playable, {bool play = true}) async => _position.add(const Duration(seconds: 1));

  @override
  Future<void> stop() async => state = state.copyWith(playing: false);

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _FakeVideo implements VideoController {
  _FakeVideo(this.player);

  @override
  final Player player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  final id = ValueNotifier<int?>(null);
  @override
  final rect = ValueNotifier<Rect?>(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEngine implements PlaybackEngine {
  _FakeEngine(this.player) : controller = _FakeVideo(player);

  @override
  Player player;
  @override
  VideoController controller;
  @override
  bool hardware = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Source implements ContentSource {
  @override
  Future<List<Category>> movieCategories() async => const [];

  @override
  Future<List<Category>> seriesCategories() async => const [];

  @override
  Future<SeriesDetail> seriesDetail(Series s) async => SeriesDetail(
    series: s,
    seasons: const {
      1: [Episode(id: 'e1', season: 1, number: 1, title: 'Pilot')],
      2: [Episode(id: 'e2', season: 2, number: 1, title: 'Return')],
    },
  );

  @override
  String movieUrl(Movie m) => 'http://x/movie/${m.id}.mkv';

  @override
  String episodeUrl(Episode e) => 'http://x/series/${e.id}.mkv';

  @override
  Map<String, String> headersFor(String url) => const {};

  @override
  bool hideAdult = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

late AppSettings settings;
late Library library;

/// The app as on a TV, with its remote's keys.
Widget _app(Widget home, {GlobalKey<NavigatorState>? navigator}) => SettingsScope(
  settings: settings,
  child: MaterialApp(
    navigatorKey: navigator,
    theme: buildTheme(),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (_, child) => LibraryScope(
      library: library,
      child: Shortcuts(shortcuts: tvShortcuts, child: child!),
    ),
    home: home,
  ),
);

FocusNode get _focused => FocusManager.instance.primaryFocus!;

/// Whether the remote is on the button whose label has [label]: on the button itself, with its ring,
/// not on something that holds it.
bool _on(String label) {
  final context = _focused.context;
  if (context == null || context.findAncestorWidgetOfExactType<Focusable>() == null) return false;
  return find
      .descendant(of: find.byElementPredicate((e) => e == context), matching: find.textContaining(label))
      .evaluate()
      .isNotEmpty;
}

bool _inTrailer(FocusNode n) => n.context?.findAncestorWidgetOfExactType<TrailerBackdrop>() != null;

bool _onTrailer() => _inTrailer(_focused);

/// Trailers' web view as on an Android TV: the real one, down to its platform view (see [main]'s
/// setUp for the platform's side).
///
/// One trailer goes first on the real clock: the page trailers play in comes from a server of the
/// app's own, whose timer the test's clock would find still running at the end; and each trailer
/// waits for the one before, which a past test's clock would hold up for good.
Future<void> _webViews(WidgetTester t) async {
  AndroidInAppWebViewPlatform.registerWith();
  await t.runAsync(() async {
    await t.pumpWidget(TrailerBackdrop(load: () async => _trailer, onPlaying: (_) {}, onEnd: () {}));
    await Future<void>.delayed(TrailerBackdrop.delay + const Duration(milliseconds: 500));
    await t.pumpWidget(const SizedBox());
  });
}

/// Past the trailer's delay, until its web view is made: there, with a focus node of its own, but
/// unseen until YouTube plays.
Future<void> _trailerMade(WidgetTester t) async {
  bool made() => FocusManager.instance.rootScope.descendants.any(_inTrailer);
  await t.pump(TrailerBackdrop.delay);
  // What it waits for comes on the real clock: a turn of each until it is there
  for (var i = 0; i < 20 && !made(); i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump();
  }
  expect(made(), isTrue, reason: 'the web view is made');
}

/// Every arrow from everywhere the remote can be: never onto the trailer.
Future<void> _expectNoArrowOntoTheTrailer(WidgetTester t) async {
  final places = [
    for (final n in FocusManager.instance.rootScope.traversalDescendants)
      if (n is! FocusScopeNode && !_inTrailer(n)) n,
  ];
  for (final from in places) {
    for (final arrow in _arrows) {
      from.requestFocus();
      await t.pump();
      await t.sendKeyEvent(arrow);
      await t.pump(const Duration(milliseconds: 300));
      expect(_onTrailer(), isFalse, reason: '${arrow.keyLabel} from $from went to the trailer');
    }
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // A platform view is made as Android makes a web view's. Kept for every test: one that failed
    // leaves its screen to the next, which takes it down first
    binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load();
    library = await Library.load('test', mainProfileId);
    await ProfileStore.instance.load();
    isTv = true;
  });

  tearDown(() => isTv = false);

  void tvScreen(WidgetTester t) {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
  }

  testWidgets('when a profile\'s time runs out mid-film, the remote is on Exit, and goes across to more time', (
    t,
  ) async {
    tvScreen(t);
    final profiles = ProfileStore.instance;
    final leo = await profiles.add('Leo', kids: true);
    await profiles.update(leo.copyWith(dailyMinutes: 1));
    await profiles.select(leo.id);
    final navigator = GlobalKey<NavigatorState>();
    await t.pumpWidget(_app(const Scaffold(), navigator: navigator));
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          engine: _FakeEngine(_FakePlayer()),
          items: const [PlayItem(url: 'http://x/movie/5.mkv', title: 'A Film')],
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown); // onto the controls, at play
    await t.pump();
    expect(_focused.debugLabel, 'play');
    for (var i = 0; i < 65; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(find.text('That\'s all for today'), findsOneWidget);
    expect(_on('Exit'), isTrue, reason: 'the remote is on the panel, not on the player behind it ($_focused)');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(_on('30 more minutes'), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pump();
    expect(_on('Exit'), isTrue);
  });

  for (final width in [640.0, 480.0]) {
    testWidgets('in a window ${width.round()} wide, the controls of a live channel all stay within reach', (t) async {
      isTv = false;
      t.view.physicalSize = Size(width, 360);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final navigator = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(const Scaffold(), navigator: navigator));
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            engine: _FakeEngine(_FakePlayer()),
            items: const [
              PlayItem(
                url: 'http://x/live/5.ts',
                title: 'News',
                ref: MediaRef(kind: MediaKind.live, id: '5', title: 'News'),
              ),
            ],
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));
      expect(t.takeException(), isNull, reason: 'no overflow');
      navigator.currentState!.pop();
      await t.pump(const Duration(seconds: 3));
    });
  }

  testWidgets('a channel shows what is on now and next, from the guide', (t) async {
    tvScreen(t);
    final now = DateTime.now();
    currentGuide.value = EpgGuide({
      'news.tv': [
        EpgEntry(
          title: 'Morning news',
          start: now.subtract(const Duration(minutes: 10)),
          end: now.add(const Duration(minutes: 20)),
        ),
        EpgEntry(
          title: 'Weather',
          start: now.add(const Duration(minutes: 20)),
          end: now.add(const Duration(minutes: 30)),
        ),
      ],
    });
    addTearDown(() => currentGuide.value = null);
    final navigator = GlobalKey<NavigatorState>();
    await t.pumpWidget(_app(const Scaffold(), navigator: navigator));
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          engine: _FakeEngine(_FakePlayer()),
          items: const [
            PlayItem(
              url: 'http://x/live/5.ts',
              title: 'News',
              ref: MediaRef(kind: MediaKind.live, id: '5', title: 'News', epgId: 'news.tv'),
            ),
          ],
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Now · Morning news'), findsOneWidget);
    expect(find.text('Next · Weather'), findsOneWidget);
    navigator.currentState!.pop();
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('a player in the place of another goes on saying it plays once the old one is gone', (t) async {
    tvScreen(t);
    final navigator = GlobalKey<NavigatorState>();
    await t.pumpWidget(_app(const Scaffold(), navigator: navigator));
    Route<void> player() => MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(
        engine: _FakeEngine(_FakePlayer()),
        items: const [PlayItem(url: 'http://x/live/5.ts', title: 'News')],
      ),
    );
    navigator.currentState!.push(player());
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    expect(streamPlaying.value, isTrue);

    navigator.currentState!.pushReplacement(player());
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(PlayerScreen), findsOneWidget, reason: 'the old one has gone');
    expect(nowPlaying.value?.title, 'News');
    expect(streamPlaying.value, isTrue, reason: 'the stream keeps the line');

    navigator.currentState!.pop();
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    expect(nowPlaying.value, isNull);
    expect(streamPlaying.value, isFalse);
    await t.pump(const Duration(seconds: 3)); // what it noted of the stream gets saved
  });

  testWidgets('on the hero the arrows go between its buttons, never to the trailer behind them', (t) async {
    tvScreen(t);
    await _webViews(t);
    CatalogItem item(String id) => CatalogItem(
      id: id,
      title: 'Film $id',
      year: 2024,
      plot: 'A plot',
      open: (_) {},
      play: (_) {},
      trailer: () async => _trailer,
    );
    await t.pumpWidget(
      _app(
        Scaffold(
          body: ListView(
            children: [
              HeroCarousel(items: [item('1'), item('2'), item('3')], label: 'Movies'),
            ],
          ),
        ),
      ),
    );
    await t.pump();
    expect(_on('Play'), isTrue);
    await _trailerMade(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    expect(_on('Play'), isTrue, reason: 'nothing is above it, yet up went to $_focused');
    await _expectNoArrowOntoTheTrailer(t);
  });

  testWidgets('a hero out of sight does not move on: coming back, the remote stays on its Play', (t) async {
    tvScreen(t);
    CatalogItem item(String id) =>
        CatalogItem(id: id, title: 'Film $id', year: 2024, plot: 'A plot', open: (_) {}, play: (_) {});
    var shown = false;
    late StateSetter set;
    await t.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            // As a tab that is not the one on screen: built, its tickers off, no focus in it
            return TickerMode(
              enabled: shown,
              child: ExcludeFocus(
                excluding: !shown,
                child: Scaffold(
                  body: ListView(
                    children: [
                      HeroCarousel(items: [item('1'), item('2')], label: 'Movies'),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    // Its pages go by the wall clock: real seconds pass too, past a page's 8
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await t.pump(const Duration(seconds: 1));
    }
    set(() => shown = true);
    await t.pump();
    // The remote comes into the tab, on its hero's Play (Home's _select)
    Focus.of(t.element(find.text('Play').hitTestable().first)).requestFocus();
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 500));
    }
    expect(find.text('Film 1').hitTestable(), findsWidgets, reason: 'it waited out of sight');
    expect(_on('Play'), isTrue);
  });

  testWidgets('with reduced motion or a screen reader, the hero stays on its page', (t) async {
    tvScreen(t);
    CatalogItem item(String id) =>
        CatalogItem(id: id, title: 'Film $id', year: 2024, plot: 'A plot', open: (_) {}, play: (_) {});
    for (final data in const [MediaQueryData(disableAnimations: true), MediaQueryData(accessibleNavigation: true)]) {
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: data.disableAnimations, accessibleNavigation: data.accessibleNavigation),
              child: ExcludeFocus(
                // nobody on it: it would move on by itself
                child: Scaffold(
                  body: ListView(
                    children: [
                      HeroCarousel(items: [item('1'), item('2')], label: 'Movies'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      // Its pages go by the wall clock: real seconds pass too, past a page's 8
      for (var i = 0; i < 10; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
        await t.pump(const Duration(seconds: 1));
      }
      expect(find.text('Film 1').hitTestable(), findsWidgets, reason: 'still on its first page with $data');
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a hero that comes in above what has the remote brings that back into view', (t) async {
    tvScreen(t);
    CatalogItem item(String id) =>
        CatalogItem(id: id, title: 'Film $id', year: 2024, plot: 'A plot', open: (_) {}, play: (_) {});
    var hero = false;
    late StateSetter set;
    await t.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return Scaffold(
              body: ListView(
                children: [
                  // In its own slot, as on Home: what is below is not built anew
                  if (hero) HeroCarousel(items: [item('1'), item('2')], label: 'Movies') else const SizedBox.shrink(),
                  // Continue watching, a row of its own
                  SizedBox(
                    height: 200,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        Focusable(
                          autofocus: true,
                          onTap: () {},
                          child: const SizedBox(width: 300, child: Text('Card')),
                        ),
                      ],
                    ),
                  ),
                  for (var i = 0; i < 6; i++) SizedBox(height: 200, child: Text('Row $i')),
                ],
              ),
            );
          },
        ),
      ),
    );
    await t.pump();
    expect(_on('Card'), isTrue);
    set(() => hero = true); // the catalog came
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(_on('Card'), isTrue, reason: 'the remote stays where it was');
    final card = t.getRect(find.text('Card'));
    expect(card.top >= 0 && card.bottom <= 540, isTrue, reason: 'in sight, not pushed off by the hero: $card');
  });

  Future<void> upFromPlay(WidgetTester t, Widget page) async {
    tvScreen(t);
    await _webViews(t);
    await t.pumpWidget(_app(page));
    await t.pump();
    await t.pump(); // its details
    expect(_on('Play'), isTrue);
    await _trailerMade(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    expect(_focused.context?.findAncestorWidgetOfExactType<BackButton>(), isNotNull, reason: 'up went to $_focused');
    await _expectNoArrowOntoTheTrailer(t);
  }

  testWidgets('on a movie\'s page, up from Play goes to the back button, not to the trailer behind', (t) async {
    await upFromPlay(
      t,
      MovieDetailScreen(
        source: _Source(),
        movie: const Movie(id: '5', name: 'A Film', year: 2024, trailer: _trailer),
      ),
    );
  });

  testWidgets('and so on a series\' page', (t) async {
    await upFromPlay(
      t,
      SeriesDetailScreen(
        source: _Source(),
        series: const Series(id: 's', name: 'Show', trailer: _trailer),
      ),
    );
  });
}
