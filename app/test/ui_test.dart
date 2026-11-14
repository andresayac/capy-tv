import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/catalog.dart';
import 'package:iptv_player/ui/common.dart';
import 'package:iptv_player/ui/detail_screens.dart';
import 'package:iptv_player/ui/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSource implements ContentSource {
  var failLive = false;

  @override
  Future<List<Category>> liveCategories() async => const [
    Category(id: '1', name: 'News'),
    Category(id: '2', name: 'Sports'),
  ];

  @override
  Future<List<LiveChannel>> liveChannels([String? categoryId]) async {
    if (failLive) throw const SourceException(SourceError.timeout);
    return [
      LiveChannel(
        id: '10',
        name: 'Channel $categoryId',
        number: 1,
        epgId: 'one.tv',
        archiveDays: categoryId == '1' ? 2 : 0,
      ),
    ];
  }

  @override
  Future<List<Category>> movieCategories() async => const [Category(id: 'm', name: '🎬 VOD | BLOCKBUSTERS')];

  @override
  Future<List<Movie>> movies([String? categoryId]) async => const [
    Movie(
      id: '5',
      name: 'A Film',
      year: 2024,
      rating: 7.5,
      poster: 'http://x/p.jpg',
      plot: 'A plot',
      genre: 'Action, Drama',
    ),
  ];

  @override
  Future<List<Category>> seriesCategories() async => const [];

  @override
  Future<List<Series>> series([String? categoryId]) async => const [];

  @override
  Future<SeriesDetail> seriesDetail(Series s) async => SeriesDetail(
    series: s,
    seasons: const {
      1: [Episode(id: 'e1', season: 1, number: 1, title: 'Pilot')],
      2: [Episode(id: 'e2', season: 2, number: 1, title: 'Return')],
    },
  );

  @override
  Future<List<EpgEntry>> shortEpg(LiveChannel c, {int limit = 4}) async => const [];

  @override
  Future<EpgGuide> guide() async => EpgGuide({
    'one.tv': [
      EpgEntry(
        title: 'Morning News',
        start: DateTime.now().subtract(const Duration(minutes: 30)),
        end: DateTime.now().add(const Duration(minutes: 30)),
      ),
    ],
  });

  @override
  String liveUrl(LiveChannel c) => 'http://x/live/${c.id}.ts';

  @override
  String movieUrl(Movie m) => 'http://x/movie/${m.id}.mkv';

  @override
  String episodeUrl(Episode e) => 'http://x/series/${e.id}.mkv';

  @override
  String? catchupUrl(LiveChannel c, DateTime start, Duration duration) => null;

  @override
  Map<String, String> headersFor(String url) => const {};

  @override
  bool hideAdult = false;
}

late AppSettings settings;
late Library library;

Widget app(Widget home, {Locale locale = const Locale('en')}) => SettingsScope(
  settings: settings,
  child: MaterialApp(
    builder: (_, child) => LibraryScope(library: library, child: child!),
    locale: locale,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

const playlist = Playlist(id: 'p', name: 'My provider', type: PlaylistType.xtream, url: 'http://x', username: 'u');

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load();
    library = await Library.load('test', mainProfileId);
  });

  testWidgets('home tab starts empty and then shows "My list"', (t) async {
    await t.pumpWidget(app(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    expect(find.text('Make it yours'), findsOneWidget);
    final panel = find.ancestor(of: find.text('Make it yours'), matching: find.byType(Panel));
    expect(t.widget<CapyStatus>(find.descendant(of: panel, matching: find.byType(CapyStatus))).mood, CapyMood.empty);
    await library.toggleFavorite(const MediaRef(kind: MediaKind.movie, id: '5', title: 'A Film'));
    await t.pumpAndSettle();
    expect(find.text('Favorite movies'), findsOneWidget);
    expect(find.text('Make it yours'), findsNothing);
  });

  testWidgets('live tab opens on the first category and switches categories', (t) async {
    await t.pumpWidget(app(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    await t.tap(find.text('Live TV').first);
    await t.pumpAndSettle();
    expect(find.text('Channel 1'), findsOneWidget);
    expect(find.text('Morning News'), findsOneWidget); // what is on now, from the guide
    await t.tap(find.text('Sports'));
    await t.pumpAndSettle();
    expect(find.text('Channel 2'), findsOneWidget);
  });

  testWidgets('errors are shown translated, with retry', (t) async {
    final source = FakeSource()..failLive = true;
    await t.pumpWidget(
      app(
        HomeScreen(playlist: playlist, source: source),
        locale: const Locale('es'),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('TV').first);
    await t.pumpAndSettle();
    expect(find.text('El servidor no responde.'), findsOneWidget);
    source.failLive = false;
    await t.tap(find.text('Reintentar'));
    await t.pumpAndSettle();
    expect(find.text('Channel 1'), findsOneWidget);
  });

  testWidgets('movies tab: hero, genres, curated rows and clean provider categories', (t) async {
    await t.pumpWidget(app(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    await t.tap(find.text('Movies').first);
    await t.pumpAndSettle();
    expect(find.text('MOVIES'), findsOneWidget); // hero label
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Recently added'), findsOneWidget);
    // The rows further down are built as they come into sight
    final list = find
        .descendant(
          of: find.byType(CatalogTab),
          matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down),
        )
        .first;
    await t.scrollUntilVisible(find.text('Top rated'), 300, scrollable: list);
    expect(find.text('Top rated'), findsOneWidget);
    // The provider category, further down and with a readable name
    await t.scrollUntilVisible(find.text('Blockbusters'), 300, scrollable: list);
    // A genre chip, back up, opens every title of that genre
    final chips = find.descendant(of: find.byType(Focusable), matching: find.text('Action'));
    await t.scrollUntilVisible(chips, -300, scrollable: list);
    final chip = chips.first;
    await t.ensureVisible(chip);
    await t.pumpAndSettle();
    await t.tap(chip);
    await t.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Action'), findsOneWidget);
  });

  test('a card reads the movie or series it is of', () {
    const m = Movie(
      id: '5',
      name: 'A Film',
      year: 2024,
      rating: 7.5,
      poster: 'p',
      backdrop: 'b',
      plot: 'A plot',
      genre: 'Action, Drama',
    );
    final card = CatalogItem.movie(FakeSource(), m);
    expect(
      (card.id, card.title, card.poster, card.backdrop, card.rating, card.year, card.plot, card.note),
      ('movie:5', 'A Film', 'p', 'b', 7.5, 2024, 'A plot', null),
    );
    expect(card.genres, ['Action', 'Drama']);
    expect((card.play != null, card.trailer != null), (true, true));
    expect(card.loadBackdrop, isNull, reason: 'a source without full records');
    final xtream = XtreamSource(server: 'http://x', username: 'u', password: 'p');
    expect(CatalogItem.movie(xtream, m).loadBackdrop, isNotNull);

    const s = Series(
      id: 's',
      name: 'Show',
      cover: 'c',
      backdrop: 'b',
      plot: 'p',
      rating: 8,
      year: 2020,
      genre: 'Drama',
    );
    final show = CatalogItem.series(FakeSource(), s);
    expect(
      (show.id, show.title, show.poster, show.backdrop, show.plot, show.rating, show.year, show.note),
      ('series:s', 'Show', 'c', 'b', 'p', 8.0, 2020, null),
    );
    expect(show.genres, ['Drama']);
    expect((show.play, show.loadBackdrop, show.trailer != null), (null, null, true));

    final noted = card.withNote('Why');
    expect(
      (noted.id, noted.title, noted.poster, noted.note, noted.play != null),
      ('movie:5', 'A Film', 'p', 'Why', true),
    );
    expect(noted.genres, ['Action', 'Drama']);
    final plain = CatalogItem(id: 'x', title: 'X', open: (_) {});
    expect(plain.genres, isEmpty);
    expect((plain.play, plain.trailer, plain.loadBackdrop, plain.note), (null, null, null, null));
  });

  testWidgets("a card opens its movie's page", (t) async {
    final card = CatalogItem.movie(FakeSource(), const Movie(id: '5', name: 'A Film', year: 2024));
    await t.pumpWidget(
      app(
        Builder(
          builder: (c) => TextButton(onPressed: () => card.open(c), child: const Text('open')),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byType(MovieDetailScreen), findsOneWidget);
    expect(find.text('A Film'), findsWidgets);
  });

  testWidgets('a movie page lists its versions, numbered when two read the same', (t) async {
    const versions = [
      Movie(id: '1', name: 'Heat', year: 1995, categoryId: 'm', extension: 'mkv'),
      Movie(id: '2', name: 'Heat', year: 1995, categoryId: 'm', extension: 'mkv'),
      Movie(id: '3', name: 'Heat', year: 1995, categoryId: 'm', extension: 'mp4'),
    ];
    await t.pumpWidget(app(MovieDetailScreen(source: FakeSource(), movie: versions[1], versions: versions)));
    await t.pumpAndSettle();
    final page = find.byType(Scrollable).first;
    await t.scrollUntilVisible(find.text('Blockbusters · MP4'), 300, scrollable: page);
    expect(find.text('Blockbusters · MKV · 1'), findsOneWidget);
    expect(find.text('Blockbusters · MKV · 2'), findsOneWidget);
  });

  testWidgets('series page lists episodes per season', (t) async {
    await t.pumpWidget(
      app(
        SeriesDetailScreen(
          source: FakeSource(),
          series: const Series(id: 's', name: 'Show'),
        ),
      ),
    );
    await t.pumpAndSettle();
    final page = find.byType(Scrollable).first;
    await t.scrollUntilVisible(find.text('1. Pilot'), 300, scrollable: page);
    await t.tap(find.text('Season 2'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('1. Return'), 300, scrollable: page);
    expect(find.text('2 seasons'), findsOneWidget);
  });

  testWidgets('on a short screen the menu keeps to its icons, and opens for a remote', (t) async {
    // A phone in landscape, or a TV at 1080p (540 points high)
    t.view.physicalSize = const Size(960, 540);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    // Icons only: the names are for a long press and screen readers
    expect(find.byTooltip('Movies'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    expect(find.bySemanticsLabel('Series'), findsWidgets);
    // A remote going left from the content opens it, names and all, on the current section
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    // Back to the content, it closes
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
    // A touch on an icon goes there without opening it
    await t.tap(find.byTooltip('Live TV'));
    await t.pumpAndSettle();
    expect(find.text('Sports'), findsWidgets);
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('on a TV the menu keeps its names under the icons, all of it in sight, and never opens', (t) async {
    // A TV at 1080p: 540 points high
    isTv = true;
    addTearDown(() => isTv = false);
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    final settings = t.getRect(find.text('Settings'));
    expect(settings.bottom, lessThanOrEqualTo(540), reason: 'the last item fits, with the bigger logo');
    expect(find.text('Movies'), findsWidgets);
    final rail = t.getRect(find.text('Settings')).left;
    // A remote going left onto the menu: it stays as it is
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pumpAndSettle();
    expect(t.getRect(find.text('Settings')).left, rail, reason: 'not opened over the content');
    expect(t.getRect(find.text('Settings')).bottom, settings.bottom);
  });
}
