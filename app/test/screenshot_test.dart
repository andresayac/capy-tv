// Renders key screens to PNG files under build/screenshots, headless, for design review.
// Uses the real provider from ../.env (see live_provider_test.dart) so artwork is realistic.
//   SCREENSHOTS=1 flutter test test/screenshot_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/data/trending.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/detail_screens.dart';
import 'package:iptv_player/ui/home_screen.dart';
import 'package:iptv_player/ui/playlists_screen.dart';
import 'package:iptv_player/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, String> _env() {
  final file = File('../.env');
  return {
    if (file.existsSync())
      for (final line in file.readAsLinesSync())
        if (line.contains('='))
          line.substring(0, line.indexOf('=')).trim(): line.substring(line.indexOf('=') + 1).trim(),
  };
}

Future<void> _loadFonts() async {
  final inter = FontLoader('Inter');
  for (final w in [400, 500, 600, 700, 800]) {
    inter.addFont(Future.value(ByteData.sublistView(File('assets/fonts/Inter-$w.ttf').readAsBytesSync())));
  }
  await inter.load();
  final flutterRoot = File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytesSync(),
        ),
      ),
    );
  await icons.load();
}

late AppSettings _settings;
Library? _library;

Widget _app(Widget home, GlobalKey key) => RepaintBoundary(
  key: key,
  child: SettingsScope(
    settings: _settings,
    child: MaterialApp(
      builder: (_, child) => LibraryScope(library: _library, child: child!),
      debugShowCheckedModeBanner: false,
      locale: const Locale('es'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(),
      home: home,
    ),
  ),
);

Future<void> _shot(
  WidgetTester t,
  String name,
  Size size,
  Widget home, {
  Future<void> Function()? then,
  FakeViewPadding cutout = FakeViewPadding.zero, // a landscape phone's camera cutout
}) async {
  final key = GlobalKey();
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.view.padding = cutout;
  t.view.viewPadding = cutout;
  await t.pumpWidget(_app(home, key));
  // Let network requests and image downloads finish in real time
  for (var i = 0; i < 8; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    await t.pump(const Duration(milliseconds: 300));
  }
  if (then != null) {
    await then();
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await t.pump(const Duration(milliseconds: 300));
    }
  }
  // Image decoding needs the real event loop; precache whatever is on screen, then repaint
  await t.runAsync(() async {
    await Future.wait([
      for (final e in find.byType(Image).evaluate().toList())
        precacheImage(
          (e.widget as Image).image,
          e,
          onError: (_, _) {},
        ).timeout(const Duration(seconds: 8), onTimeout: () {}),
    ]);
  });
  for (var i = 0; i < 3; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
  await t.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = File('build/screenshots/$name.png')..createSync(recursive: true);
    out.writeAsBytesSync(png!.buffer.asUint8List());
  });
}

/// Real provider data fetched up front, served from memory: real network futures and the
/// test clock do not mix, so widgets get already-completed futures instead.
class _Preloaded implements ContentSource {
  _Preloaded(this.real);

  final XtreamSource real;
  late List<Category> live, movieCats, seriesCats;
  final channels = <String, List<LiveChannel>>{};
  final movieLists = <String, List<Movie>>{};
  final seriesLists = <String, List<Series>>{};
  final details = <String, SeriesDetail>{};
  EpgGuide epg = EpgGuide.empty;

  Future<void> load() async {
    live = await real.liveCategories();
    movieCats = await real.movieCategories();
    seriesCats = await real.seriesCategories();
    channels[live.first.id] = await real.liveChannels(live.first.id);
    for (final c in movieCats.take(3)) {
      movieLists[c.id] = await real.movies(c.id);
    }
    for (final c in seriesCats.take(3)) {
      seriesLists[c.id] = await real.series(c.id);
    }
    final first = seriesLists[seriesCats.first.id]!.first;
    details[first.id] = await real.seriesDetail(first);
    epg = await real.guide();
  }

  @override
  Future<List<Category>> liveCategories() async => live;
  @override
  Future<List<LiveChannel>> liveChannels([String? id]) async => channels[id] ?? const [];
  @override
  Future<List<Category>> movieCategories() async => movieCats;
  @override
  Future<List<Movie>> movies([String? id]) async => movieLists[id] ?? const [];
  @override
  Future<List<Category>> seriesCategories() async => seriesCats;
  @override
  Future<List<Series>> series([String? id]) async => seriesLists[id] ?? const [];
  @override
  Future<SeriesDetail> seriesDetail(Series s) async => details[s.id] ?? SeriesDetail(series: s, seasons: const {});
  @override
  Future<List<EpgEntry>> shortEpg(LiveChannel c, {int limit = 4}) async => const [];
  @override
  Future<EpgGuide> guide() async => epg;
  @override
  String liveUrl(LiveChannel c) => real.liveUrl(c);
  @override
  String movieUrl(Movie m) => real.movieUrl(m);
  @override
  String episodeUrl(Episode e) => real.episodeUrl(e);
  @override
  String? catchupUrl(LiveChannel c, DateTime start, Duration duration) => null;

  @override
  Map<String, String> headersFor(String url) => const {};

  @override
  bool hideAdult = false;
}

void main() {
  final env = _env();
  final enabled = Platform.environment['SCREENSHOTS'] == '1' && env['XTREAM_CODE'] != null;

  setUpAll(() async {
    if (!enabled) return;
    HttpOverrides.global = null; // allow real network for artwork
    await _loadFonts();
  });

  // Phones run the app on their side, full screen: their captures are landscape, as people see it
  const wide = Size(1440, 900), phone = Size(915, 412);

  testWidgets(
    'screenshots',
    (t) async {
      final real = XtreamSource(
        server: env['XTREAM_CODE']!,
        username: env['XTREAM_USERNAME']!,
        password: env['XTREAM_PASSWORD']!,
        cacheDir: Directory.systemTemp,
      );
      final source = _Preloaded(real);
      final account = await t.runAsync(real.login);
      await t.runAsync(source.load);
      final playlist = Playlist(
        id: '1',
        name: 'GoPlay',
        type: PlaylistType.xtream,
        url: env['XTREAM_CODE']!,
        username: env['XTREAM_USERNAME']!,
      );

      // Two made-up lists at a reserved address: the only one would open by itself and log in to
      // the real panel as no one, and the rows would show its address
      SharedPreferences.setMockInitialValues({
        'playlists':
            '[{"id":"1","name":"GoPlay","type":"xtream","url":"http://provider.invalid","username":"demo","password":""},'
            '{"id":"2","name":"Family","type":"xtream","url":"http://provider.invalid","username":"family","password":""}]',
      });
      _settings = (await t.runAsync(AppSettings.load))!;
      await _shot(t, 'welcome-wide', wide, const PlaylistsScreen());
      await _shot(t, 'welcome-phone', phone, const PlaylistsScreen());

      // A lived-in library: something half watched, recent channels and favorites
      _library = (await t.runAsync(() => Library.load('1', mainProfileId)))!;
      final movies0 = source.movieLists[source.movieCats.first.id]!;
      final show = source.seriesLists[source.seriesCats.first.id]!.first;
      final ep = source.details[show.id]!.seasons.values.first.first;
      final channels0 = source.channels[source.live.first.id]!;
      await t.runAsync(() async {
        await _library!.record(
          MediaRef.movie(movies0[1]),
          position: const Duration(minutes: 47),
          duration: const Duration(minutes: 105),
        );
        await _library!.record(
          MediaRef.episode(show, ep),
          position: const Duration(minutes: 12),
          duration: const Duration(minutes: 44),
          device: 'TV de la sala', // left on another device: Home offers to go on here
        );
        for (final c in channels0.take(4)) {
          await _library!.record(MediaRef.channel(c));
        }
        for (final m in movies0.skip(2).take(5)) {
          await _library!.toggleFavorite(MediaRef.movie(m));
        }
        await _library!.toggleFavorite(MediaRef.series(show));
      });

      final home = HomeScreen(playlist: playlist, source: source, account: account);
      if (Trending.apiKey.isNotEmpty) await t.runAsync(() => Trending.refresh(language: 'es-CO'));
      await _shot(t, 'home-wide', wide, home);
      await _shot(t, 'home-phone', phone, home);
      // Wide but short: the menu keeps to its icons, and opens over the content for a remote
      await _shot(t, 'home-phone-landscape', const Size(915, 412), home, cutout: const FakeViewPadding(right: 48));
      await _shot(t, 'home-phone-landscape-left', const Size(915, 412), home, cutout: const FakeViewPadding(left: 48));
      await _shot(
        t,
        'movies-phone-landscape',
        const Size(915, 412),
        home,
        cutout: const FakeViewPadding(right: 48),
        then: () => t.tap(find.byTooltip('Películas')),
      );
      // A row slid along passes under the see-through menu
      await _shot(
        t,
        'movies-phone-scrolled',
        const Size(915, 412),
        home,
        then: () async {
          await t.tap(find.byTooltip('Películas'));
          await t.pump(const Duration(seconds: 1));
          await t.dragFrom(const Offset(500, 150), const Offset(-180, 0));
        },
      );
      await _shot(
        t,
        'home-tv-menu',
        const Size(960, 540),
        home,
        then: () async {
          for (var i = 0; i < 4; i++) {
            await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          }
        },
      );
      await _shot(t, 'live-wide', wide, home, then: () => t.tap(find.text('TV').first));
      await _shot(t, 'movies-wide', wide, home, then: () => t.tap(find.text('Películas').first));
      await _shot(t, 'series-phone', phone, home, then: () => t.tap(find.text('Series').first));

      final movie = source.movieLists[source.movieCats.first.id]!.first;
      await _shot(t, 'movie-wide', wide, MovieDetailScreen(source: source, movie: movie));
      final series = source.seriesLists[source.seriesCats.first.id]!;
      await _shot(t, 'series-detail-wide', wide, SeriesDetailScreen(source: source, series: series.first));
      await _shot(t, 'series-detail-phone', phone, SeriesDetailScreen(source: source, series: series.first));
      t.view.reset();
      real.close();
      await t.pump(const Duration(minutes: 1)); // let request timeouts expire
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
