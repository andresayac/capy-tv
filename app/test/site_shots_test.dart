// Renders the screens the public site shows to ../site/src/assets/shots, headless, from the
// made-up catalog in site/demo (never a real provider's).
//   cd site && npm run demo:provider     (in another terminal)
//   SITE_SHOTS=1 flutter test test/site_shots_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/data/surprise.dart';
import 'package:iptv_player/data/trending.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/remote/companion_server.dart';
import 'package:iptv_player/ui/detail_screens.dart';
import 'package:iptv_player/ui/guide_screen.dart';
import 'package:iptv_player/ui/home_screen.dart';
import 'package:iptv_player/ui/movie_night_screen.dart';
import 'package:iptv_player/ui/profiles_screen.dart';
import 'package:iptv_player/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _panel = 'http://127.0.0.1:8091';
const _tv = Size(1920, 1080), _phone = Size(915, 412);
const _tvRatio = 1.5, _phoneRatio = 2.0;

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

/// The demo panel's lists, fetched up front and served from memory: real network futures and the
/// test clock do not mix, so widgets get already-completed futures instead.
class _Demo implements ContentSource {
  _Demo(this.panel);

  final XtreamSource panel;
  late List<Category> live, movieCats, seriesCats;
  late List<LiveChannel> channels;
  late List<Movie> films;
  late List<Series> shows;
  final details = <String, SeriesDetail>{};
  EpgGuide epg = EpgGuide.empty;

  Future<void> load() async {
    live = await panel.liveCategories();
    movieCats = await panel.movieCategories();
    seriesCats = await panel.seriesCategories();
    channels = await panel.liveChannels();
    films = await panel.movies();
    shows = await panel.series();
    for (final s in shows) {
      details[s.id] = await panel.seriesDetail(s);
    }
    epg = await panel.guide();
  }

  @override
  Future<List<Category>> liveCategories() async => live;
  @override
  Future<List<LiveChannel>> liveChannels([String? id]) async => [
    for (final c in channels)
      if (id == null || c.categoryId == id) c,
  ];
  @override
  Future<List<Category>> movieCategories() async => movieCats;
  @override
  Future<List<Movie>> movies([String? id]) async => [
    for (final m in films)
      if (id == null || m.categoryId == id) m,
  ];
  @override
  Future<List<Category>> seriesCategories() async => seriesCats;
  @override
  Future<List<Series>> series([String? id]) async => [
    for (final s in shows)
      if (id == null || s.categoryId == id) s,
  ];
  @override
  Future<SeriesDetail> seriesDetail(Series s) async => details[s.id] ?? SeriesDetail(series: s, seasons: const {});
  @override
  Future<List<EpgEntry>> shortEpg(LiveChannel c, {int limit = 4}) async => const [];
  @override
  Future<EpgGuide> guide() async => epg;
  @override
  String liveUrl(LiveChannel c) => panel.liveUrl(c);
  @override
  String movieUrl(Movie m) => panel.movieUrl(m);
  @override
  String episodeUrl(Episode e) => panel.episodeUrl(e);
  @override
  String? catchupUrl(LiveChannel c, DateTime start, Duration duration) => null;
  @override
  Map<String, String> headersFor(String url) => const {};
  @override
  bool hideAdult = false;
}

void main() {
  final enabled = Platform.environment['SITE_SHOTS'] == '1';

  setUpAll(() async {
    if (!enabled) return;
    HttpOverrides.global = null; // the artwork comes from the demo panel
    await _loadFonts();
  });

  for (final lang in const ['en', 'es']) {
    testWidgets(
      'site shots in $lang',
      (t) async {
        final l = lookupAppLocalizations(Locale(lang));
        final panel = XtreamSource(
          server: _panel,
          username: lang,
          password: 'demo',
          cacheDir: Directory.systemTemp.createTempSync('capy-site-shots'),
        );
        final source = _Demo(panel);
        final account = (await t.runAsync(panel.login))!;
        await t.runAsync(source.load);
        final playlist = Playlist(id: '1', name: 'Demo', type: PlaylistType.xtream, url: _panel, username: lang);

        SharedPreferences.setMockInitialValues({
          'playlists': jsonEncode([
            {'id': '1', 'name': 'Demo', 'type': 'xtream', 'url': _panel, 'username': lang, 'password': ''},
          ]),
        });
        final settings = (await t.runAsync(AppSettings.load))!;
        final store = ProfileStore.instance;
        final library = (await t.runAsync(() async {
          await store.load();
          await store.update(store.current.copyWith(name: 'Ana', avatar: 'notionists-5'));
          await store.add('Leo', avatar: 'lorelei-5');
          await store.add('Mia', kids: true, avatar: 'fun-emoji-21');
          await store.add('Tomás', avatar: 'open-peeps-7');
          return Library.load('1', mainProfileId);
        }))!;
        await t.runAsync(() async {
          final client = HttpClient();
          final request = await client.getUrl(Uri.parse('$_panel/trending?lang=$lang'));
          final answer = await utf8.decodeStream(await request.close());
          client.close();
          Trending.items.value = [
            for (final j in jsonDecode(answer) as List) Trend.fromJson(j as Map<String, dynamic>),
          ];
        });

        final films = {for (final m in source.films) m.name: m};
        final show = source.shows.firstWhere((s) => s.name == 'Ferry Line 12');
        final episode = source.details[show.id]!.seasons.values.first[2];
        await t.runAsync(() async {
          await library.record(
            MediaRef.movie(films['The Salt Orchard']!),
            position: const Duration(minutes: 47),
            duration: const Duration(minutes: 105),
          );
          await library.record(
            MediaRef.episode(show, episode),
            position: const Duration(minutes: 12),
            duration: const Duration(minutes: 44),
          );
          await library.record(
            MediaRef.movie(films['Paper Harbor']!),
            position: const Duration(minutes: 20),
            duration: const Duration(minutes: 100),
          );
          for (final c in source.channels.take(4)) {
            await library.record(MediaRef.channel(c));
          }
        });

        Future<void> shot(
          String name,
          Size size,
          double ratio,
          Widget home, {
          Future<void> Function()? then,
          int rounds = 8, // the artwork comes down a few at a time
        }) async {
          final key = GlobalKey();
          t.view.physicalSize = size * ratio;
          t.view.devicePixelRatio = ratio;
          await t.pumpWidget(
            RepaintBoundary(
              key: key,
              child: SettingsScope(
                settings: settings,
                child: MaterialApp(
                  builder: (_, child) => LibraryScope(library: library, child: child!),
                  debugShowCheckedModeBanner: false,
                  locale: Locale(lang),
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
            ),
          );
          Future<void> settle(int rounds) async {
            for (var i = 0; i < rounds; i++) {
              await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
              await t.pump(const Duration(milliseconds: 300));
            }
          }

          await settle(rounds);
          if (then != null) {
            await then();
            await settle(rounds);
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
          await settle(4);
          await t.runAsync(() async {
            final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: ratio);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final out = File('../site/src/assets/shots/$lang/$name.png')..createSync(recursive: true);
            out.writeAsBytesSync(png!.buffer.asUint8List());
          });
        }

        final catalog = Catalog(source);
        final data = (await t.runAsync(catalog.load))!;
        currentCatalog.value = catalog; // title pages take "More like this" from it

        final home = HomeScreen(playlist: playlist, source: source, account: account);
        await shot('home', _tv, _tvRatio, home, rounds: 30);
        await shot(
          'search',
          _tv,
          _tvRatio,
          home,
          then: () async {
            await t.tap(find.text(l.search).first);
            await t.pump(const Duration(seconds: 1));
            await t.enterText(find.byType(TextField).first, 'capy');
          },
        );
        final bloom = films['Static Bloom']!;
        await shot(
          'title',
          _tv,
          _tvRatio,
          MovieDetailScreen(
            source: source,
            movie: bloom,
            versions: [films['Static Bloom']!, films['Static Bloom LAT']!, films['Static Bloom 4K']!],
          ),
        );
        await shot(
          'guide',
          _tv,
          _tvRatio,
          GuideScreen(source: source, guide: ValueNotifier(source.epg), categories: source.live),
        );
        await shot('profiles', _tv, _tvRatio, const ProfilesScreen());
        await shot('phone-movies', _phone, _phoneRatio, home, rounds: 14, then: () => t.tap(find.byTooltip(l.movies)));

        // Left half watched on another device: Home offers to go on here
        await t.runAsync(
          () => library.record(
            MediaRef.episode(show, episode),
            position: const Duration(minutes: 12),
            duration: const Duration(minutes: 44),
            device: lang == 'es' ? 'Móvil de Ana' : "Ana's phone",
          ),
        );
        await shot(
          'handoff',
          _tv,
          _tvRatio,
          home,
          rounds: 14,
          then: () => t.drag(find.byKey(const PageStorageKey('home')), const Offset(0, -560)),
        );

        // Three phones have voted by the time the screen is seen; their votes go straight in, as a
        // request to the real server would never get its answer under the test clock
        CompanionServer.instance.bindOverride = InternetAddress.loopbackIPv4;
        await shot(
          'movie-night',
          _tv,
          _tvRatio,
          MovieNightScreen(source: source, data: data, mood: Mood.laugh, series: false, library: library),
          then: () async {
            final night = CompanionServer.instance.night!;
            for (final (n, voter) in const ['ana', 'leo', 'mia'].indexed) {
              for (final (i, title) in night.titles.indexed) {
                night.vote(voter, title.id, yes: (i + n).isEven || i == 1);
              }
            }
          },
        );

        await t.pumpWidget(const SizedBox());
        t.view.reset();
        panel.close();
        await t.pump(const Duration(minutes: 1)); // let request timeouts expire
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }
}
