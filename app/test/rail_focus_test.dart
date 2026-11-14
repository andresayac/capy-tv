// A TV remote along a row of posters: right as far as it scrolls, then left goes back the way it
// came, poster by poster, and only from the first one to the side navigation.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/data/trending.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/common.dart';
import 'package:iptv_player/ui/home_screen.dart';
import 'package:iptv_player/ui/remote_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _films = 40, _tops = 12, _seen = 25;

class _Source implements ContentSource {
  @override
  Future<List<Category>> liveCategories() async => const [Category(id: '1', name: 'News')];

  @override
  Future<List<LiveChannel>> liveChannels([String? categoryId]) async => const [];

  @override
  Future<List<Category>> movieCategories() async => const [Category(id: 'm', name: 'Blockbusters')];

  // The rows of what is new take the films; the ones trending are older, in no row but their own
  @override
  Future<List<Movie>> movies([String? categoryId]) async => [
    for (var i = 0; i < _films; i++)
      Movie(
        id: 'f$i',
        name: 'Film $i',
        year: 2020,
        added: DateTime(2026, 10, 1).subtract(Duration(days: i)),
      ),
    for (var i = 0; i < _tops; i++) Movie(id: 't$i', name: 'Top $i', year: 2020, added: DateTime(2020, 1, 1)),
  ];

  @override
  Future<List<Category>> seriesCategories() async => const [];

  @override
  Future<List<Series>> series([String? categoryId]) async => const [];

  @override
  Future<EpgGuide> guide() async => EpgGuide.empty;

  @override
  String movieUrl(Movie m) => 'http://x/movie/${m.id}.mkv';

  @override
  Map<String, String> headersFor(String url) => const {};

  @override
  bool hideAdult = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _playlist = Playlist(id: 'p', name: 'My provider', type: PlaylistType.xtream, url: 'http://x', username: 'u');

late AppSettings settings;
late Library library;

/// The app as on a TV, with its remote's keys.
Widget _app(Widget home) => SettingsScope(
  settings: settings,
  child: MaterialApp(
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

bool _shows(FocusNode node, String title) => find
    .descendant(of: find.byElementPredicate((e) => e == node.context), matching: find.text(title))
    .evaluate()
    .isNotEmpty;

/// The focus node of the poster or card showing [title].
FocusNode _nodeOf(String title) => FocusManager.instance.rootScope.traversalDescendants.firstWhere(
  (n) => n.context?.findAncestorWidgetOfExactType<Focusable>() != null && _shows(n, title),
);

/// What the remote is on: "nav" on the side navigation, or which of the [name] posters.
String _where(String name) {
  if (_focused.debugLabel?.startsWith('nav ') ?? false) return 'nav';
  for (var i = 0; i < _films; i++) {
    if (_shows(_focused, '$name $i')) return '$name $i';
  }
  return '$_focused';
}

ScrollableState? get _row => Scrollable.maybeOf(_focused.context!, axis: Axis.horizontal);

Future<void> _press(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyEvent(key);
  await t.pump();
  await t.pump(const Duration(milliseconds: 200));
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load();
    library = await Library.load('test', mainProfileId);
    await ProfileStore.instance.load();
    isTv = true;
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  });

  tearDown(() {
    isTv = false;
    lowMemory = false;
    Trending.items.value = const [];
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  /// Home at a TV's size, once its lists are in.
  Future<void> home(WidgetTester t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(HomeScreen(playlist: _playlist, source: _Source())));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  /// [steps] to the right along the row of the [name] posters from its first, far enough to scroll
  /// it, and back the same way; one more left is the side navigation.
  Future<void> alongAndBack(WidgetTester t, String name, {int steps = 16}) async {
    _nodeOf('$name 0').requestFocus();
    await t.pump();
    expect(_where(name), '$name 0');
    final row = _row!;
    for (var i = 1; i <= steps; i++) {
      await _press(t, LogicalKeyboardKey.arrowRight);
      expect(_where(name), '$name $i', reason: 'right from $name ${i - 1}');
    }
    expect(row.position.pixels, greaterThan(row.position.viewportDimension / 2), reason: 'it scrolled');
    for (var i = steps - 1; i >= 0; i--) {
      await _press(t, LogicalKeyboardKey.arrowLeft);
      expect(_where(name), '$name $i', reason: 'left from $name ${i + 1}');
      expect(_row, same(row), reason: 'still on its row');
    }
    await _press(t, LogicalKeyboardKey.arrowLeft);
    expect(_where(name), 'nav', reason: 'left from the first poster');
  }

  testWidgets('along a row on Home and back, left goes poster by poster, and only then to the side navigation', (
    t,
  ) async {
    await home(t);
    await alongAndBack(t, 'Film');
  });

  testWidgets('and on a TV stick, which builds fewer of the posters out of sight', (t) async {
    lowMemory = true;
    await home(t);
    await alongAndBack(t, 'Film');
  });

  testWidgets('and on the week\'s most watched, whose posters are far apart', (t) async {
    Trending.items.value = [
      for (var i = 0; i < _tops; i++)
        Trend(series: false, tmdbId: i, title: 'Top $i', originalTitle: 'Top $i', year: 2020),
    ];
    await home(t);
    await alongAndBack(t, 'Top', steps: 9); // the row has the top ten
  });

  testWidgets('and on Continue watching, whose cards are wider', (t) async {
    for (var i = _seen - 1; i >= 0; i--) {
      await library.record(
        MediaRef(kind: MediaKind.movie, id: 's$i', title: 'Seen $i'),
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 100),
      );
    }
    await home(t);
    await alongAndBack(t, 'Seen', steps: 12);
  });

  testWidgets('and on a row of the Movies tab', (t) async {
    await home(t);
    await t.tap(find.text('Movies').first);
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await alongAndBack(t, 'Film');
  });

  testWidgets('a row further down Home starts at its first poster, not where Home or another row was left', (t) async {
    lowMemory = true; // builds a row further down only as the remote nears it, after the list has moved
    for (var i = _seen - 1; i >= 0; i--) {
      await library.record(
        MediaRef(kind: MediaKind.movie, id: 's$i', title: 'Seen $i'),
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 100),
      );
      await library.toggleFavorite(MediaRef(kind: MediaKind.movie, id: 'fav$i', title: 'Fav $i'));
      await library.record(MediaRef(kind: MediaKind.live, id: 'c$i', title: 'Chan $i'));
    }
    await home(t);
    expect(_where('Seen'), 'Seen 0');
    for (var i = 0; i < 12 && !_where('Chan').startsWith('Chan '); i++) {
      await _press(t, LogicalKeyboardKey.arrowDown);
    }
    expect(_where('Chan'), 'Chan 0');
    expect(_row!.position.pixels, 0);
  });
}
