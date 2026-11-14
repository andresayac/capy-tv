// While a list has to come over the line, the loading screens say how much of it has come.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/catalog.dart';
import 'package:iptv_player/ui/common.dart';
import 'package:iptv_player/ui/guide_screen.dart';
import 'package:iptv_player/ui/home_screen.dart';
import 'package:iptv_player/ui/playlists_screen.dart';
import 'package:iptv_player/ui/search_tab.dart';
import 'package:iptv_player/ui/surprise_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_test.dart' show FakeSource;

/// A provider whose full list of movies is still on its way, and whatever else it is told to.
class _Downloading extends FakeSource {
  _Downloading({this.movieGroups = false, this.liveGroups = false, this.channels = false});

  final bool movieGroups, liveGroups, channels;

  Future<T> _never<T>() => Completer<T>().future;

  @override
  Future<List<Movie>> movies([String? categoryId]) => _never();

  @override
  Future<List<Category>> movieCategories() => movieGroups ? _never() : super.movieCategories();

  @override
  Future<List<Category>> liveCategories() => liveGroups ? _never() : super.liveCategories();

  @override
  Future<List<LiveChannel>> liveChannels([String? categoryId]) => channels ? _never() : super.liveChannels(categoryId);
}

const _reading = 'Cargando el catálogo completo…', _got = 'Descargando el catálogo… 45 %';
final _guide = ValueNotifier(EpgGuide.empty);

Widget _app(Widget body, String language) => MaterialApp(
  locale: Locale(language),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: body),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    listDownloads.value = null;
    listImports.reset(); // an M3U added leaves its row behind for the next
  });

  testWidgets('the movies tab says how far its list has got, and nothing when it comes from disk', (t) async {
    final source = _Downloading();
    await t.pumpWidget(_app(CatalogTab(kind: CatalogKind.movies, source: source, catalog: Catalog(source)), 'es'));
    await t.pump();
    expect(find.text(_reading), findsOneWidget, reason: 'read from disk: only that it loads');
    expect(find.textContaining('Descargando'), findsNothing, reason: 'read from disk: nothing to say');
    expect(find.byType(LinearProgressIndicator), findsNothing);

    listDownloads.value = (received: 27000000, total: 60000000);
    await t.pump();
    expect(find.text('Descargando el catálogo… 45 %'), findsOneWidget);
    expect(t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.45, 0.001));

    listDownloads.value = (received: 12000000, total: null);
    await t.pump();
    expect(find.text('Descargando el catálogo… 12 MB'), findsOneWidget, reason: 'no total: what has come');
    expect(find.byType(LinearProgressIndicator), findsNothing);

    listDownloads.value = null;
    await t.pump();
    expect(find.textContaining('Descargando'), findsNothing);
    expect(find.text(_reading), findsOneWidget, reason: 'all here, and tens of MB still to read');
  });

  for (final (what, screen) in <(String, Widget Function())>[
    (
      'the categories of movies',
      () {
        final source = _Downloading(movieGroups: true);
        return CatalogTab(kind: CatalogKind.movies, source: source, catalog: Catalog(source));
      },
    ),
    ('the live categories', () => LiveTab(source: _Downloading(liveGroups: true), guide: _guide)),
    ('the channels of a category', () => LiveTab(source: _Downloading(channels: true), guide: _guide)),
    (
      'the guide',
      () => GuideScreen(
        source: _Downloading(channels: true),
        guide: _guide,
        categories: const [Category(id: '1', name: 'News')],
      ),
    ),
    ('the search', () => SearchTab(catalog: Catalog(_Downloading()), guide: _guide)),
    ('surprise me', () => SurpriseScreen(source: FakeSource(), catalog: Catalog(_Downloading()))),
  ]) {
    testWidgets('$what: says it loads, and how far the list has got', (t) async {
      await t.pumpWidget(_app(screen(), 'es'));
      await t.pump();
      expect(find.text(_reading), findsOneWidget);

      listDownloads.value = (received: 27000000, total: 60000000);
      await t.pump();
      expect(find.text(_got), findsOneWidget);
      expect(find.text(_reading), findsNothing);

      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets('adding an M3U says how much of it has come', (t) async {
    final never = MockClient.streaming((_, _) => Completer<http.StreamedResponse>().future);
    await http.runWithClient(() async {
      final playlist = Playlist.create(type: PlaylistType.m3u, url: 'http://lists.example/old.m3u', name: 'Mine');
      await t.pumpWidget(_app(AddPlaylistScreen(initial: playlist), 'es'));
      await t.enterText(find.text('http://lists.example/old.m3u'), 'http://lists.example/list.m3u');
      await t.scrollUntilVisible(find.text('Guardar'), 200, scrollable: find.byType(Scrollable).first);
      await t.tap(find.text('Guardar'));
      await t.pump();
      expect(find.text('Conectando…'), findsOneWidget);

      listDownloads.value = (received: 27000000, total: 60000000);
      await t.pump();
      expect(find.text(_got), findsOneWidget);
      expect(find.text('Conectando…'), findsNothing);

      listDownloads.value = null;
      await t.pump(const Duration(seconds: 61)); // the wait for the server is up
    }, () => never);
  });

  testWidgets('a provider link whose panel API is closed is saved as the M3U list it also is', (t) async {
    const link = 'http://tv.example:8080/get.php?username=ana&password=s3cret&type=m3u_plus';
    for (final (api, saved) in [(404, PlaylistType.m3u), (403, PlaylistType.m3u), (200, null)]) {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('player_api.php')) {
          // 200: the panel answers, and says the account is no good: no list instead
          return http.Response(api == 200 ? '{"user_info":{"auth":0}}' : '', api);
        }
        return http.Response('#EXTM3U\n#EXTINF:-1,One\nhttp://tv.example:8080/ana/s3cret/1\n', 200);
      });
      Playlist? result;
      await http.runWithClient(() async {
        await t.pumpWidget(
          _app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await Navigator.of(context)
                        .push<Playlist>(MaterialPageRoute(builder: (_) => const AddPlaylistScreen())),
                child: const Text('open'),
              ),
            ),
            'en',
          ),
        );
        await t.tap(find.text('open'));
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextFormField).at(1), link);
        await t.scrollUntilVisible(find.text('Save'), 200, scrollable: find.byType(Scrollable).first);
        await t.pump();
        await t.tap(find.text('Save'));
        // The checks run on real time (the list is parsed off the UI isolate): until it is done
        for (var i = 0; i < 100; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await t.pump();
          if (result != null || find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
        }
      }, () => client);
      expect(result?.type, saved, reason: 'player_api answering $api');
      if (saved != null) expect(result!.url, link);
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('renamed only, it is saved without downloading the list again', (t) async {
    var asked = 0;
    final counting = MockClient.streaming((_, _) {
      asked++;
      return Completer<http.StreamedResponse>().future;
    });
    await http.runWithClient(() async {
      final playlist = Playlist.create(type: PlaylistType.m3u, url: 'http://lists.example/list.m3u', name: 'Mine');
      await t.pumpWidget(_app(AddPlaylistScreen(initial: playlist), 'es'));
      await t.enterText(find.text('Mine'), 'Ours');
      await t.scrollUntilVisible(find.text('Guardar'), 200, scrollable: find.byType(Scrollable).first);
      await t.tap(find.text('Guardar'));
      await t.pump();
      expect(find.text('Conectando…'), findsNothing);
      expect(asked, 0);
    }, () => counting);
  });

  testWidgets("its guide's time is put right in it, saved with it without downloading, what a newer "
      'version wrote kept', (t) async {
    var asked = 0;
    final counting = MockClient.streaming((_, _) {
      asked++;
      return Completer<http.StreamedResponse>().future;
    });
    Playlist? result;
    await http.runWithClient(() async {
      final playlist = Playlist.fromJson({
        ...Playlist.create(type: PlaylistType.m3u, url: 'http://lists.example/list.m3u', name: 'Mine').toJson(),
        'fromLater': 'kept',
      });
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await Navigator.of(context)
                      .push<Playlist>(MaterialPageRoute(builder: (_) => AddPlaylistScreen(initial: playlist))),
              child: const Text('open'),
            ),
          ),
          'es',
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('Hora de la guía'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Como la envía el proveedor'), findsOneWidget);
      await t.tap(find.text('Hora de la guía'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('−3 h'));
      await t.pumpAndSettle();
      await t.tap(find.text('−3 h'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('Guardar'), 200, scrollable: find.byType(Scrollable).first);
      await t.tap(find.text('Guardar'));
      await t.pumpAndSettle();
    }, () => counting);
    expect(result?.guideShift, -180);
    expect(result?.toJson()['fromLater'], 'kept');
    expect(asked, 0, reason: 'only the guide moved: nothing to check');
  });

  testWidgets('the text is in the language of the app, without going past the whole', (t) async {
    await t.pumpWidget(_app(const Center(child: ListLoading()), 'en'));

    listDownloads.value = (received: 3200000, total: null);
    await t.pump();
    expect(find.text('Downloading the catalog… 3.2 MB'), findsOneWidget);

    listDownloads.value = (received: 90, total: 60);
    await t.pump();
    expect(find.text('Downloading the catalog… 100%'), findsOneWidget);
    expect(t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 1);

    listDownloads.value = (received: 0, total: 0);
    await t.pump();
    expect(
      find.text('Downloading the catalog… 0.0 MB'),
      findsOneWidget,
      reason: 'an empty size says nothing of a share',
    );

    await t.pumpWidget(_app(const Center(child: ListLoading()), 'es'));
    listDownloads.value = (received: 3200000, total: null);
    await t.pump();
    expect(find.text('Descargando el catálogo… 3,2 MB'), findsOneWidget, reason: 'the decimal comma');
  });
}
