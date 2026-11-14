// While a catalog loads, the screens say how many channels, movies and series have come so far.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/json_items.dart';
import 'package:iptv_player/data/m3u.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/common.dart';

const _movie = {'num': 1, 'name': 'Heat', 'stream_id': 1, 'stream_icon': '', 'category_id': '1'};

List<int> _list(int n) => utf8.encode(jsonEncode([for (var i = 0; i < n; i++) _movie]));

/// [bytes] in pieces of [size].
List<List<int>> _pieces(List<int> bytes, int size) => [
  for (var i = 0; i < bytes.length; i += size) bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
];

Widget _app(String language) => MaterialApp(
  locale: Locale(language),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: const Scaffold(body: Center(child: ListLoading())),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late List<List<ListImportRow>> seen;
  void note() => seen.add(listImports.value);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('imports');
    ListDownloads.every = Duration.zero;
    seen = [];
    listImports.reset();
    listImports.addListener(note);
  });
  tearDown(() {
    listImports.removeListener(note);
    ListDownloads.every = const Duration(milliseconds: 300);
    ListImports.linger = const Duration(seconds: 30);
    dir.deleteSync(recursive: true);
  });

  group('counting what goes by, unread', () {
    int json(String text, int size) {
      final counter = JsonItemCounter();
      _pieces(utf8.encode(text), size).forEach(counter.add);
      return counter.count;
    }

    test('whatever pieces the list comes in', () {
      const list = '[{"a":1},{"b":{"c":[1,{"d":2}]}},{"e":[]}]';
      for (final size in [1, 2, 3, 7, 64]) {
        expect(json(list, size), 3, reason: 'in pieces of $size');
      }
    });

    test('nothing in a name counts, quotes and braces included', () {
      expect(json(r'[{"name":"a } b"},{"name":"say \"}\" now"},{"name":"back\\"}]', 4), 3);
    });

    test('some panels send an object of objects', () {
      expect(json('{"0":{"a":1},"1":{"a":2}}', 5), 2);
    });

    test('a list of lists holds no items', () {
      expect(json('[[1,2],[3]]', 3), 0);
    });

    int m3u(String text, int size) {
      final counter = M3uEntryCounter();
      _pieces(utf8.encode(text), size).forEach(counter.add);
      return counter.count;
    }

    test('a playlist: each address, not its comments nor the blank lines', () {
      const list =
          '﻿#EXTM3U\r\n#EXTINF:-1,One\r\nhttp://a/1\r\n\r\n   \n#EXTINF:-1,Two\nhttp://a/2\n#EXTGRP:x\nhttp://a/3';
      for (final size in [1, 3, 64]) {
        expect(m3u(list, size), 3, reason: 'in pieces of $size');
      }
    });
  });

  group('an Xtream list', () {
    XtreamSource panel(http.StreamedResponse Function(String? action) answer) => XtreamSource(
      server: 'https://example.com/',
      username: 'demo',
      password: 'pw',
      cacheDir: dir,
      client: MockClient.streaming((request, _) async => answer(request.url.queryParameters['action'])),
    )..hideAdult = false;

    http.StreamedResponse send(List<int> body, {int piece = 40}) =>
        http.StreamedResponse(Stream.fromIterable(_pieces(body, piece)), 200);

    test('counts up as it downloads, then says it is all here', () async {
      await panel((_) => send(_list(5))).movies();

      final movies = [for (final rows in seen) rows.single];
      expect(movies.map((r) => r.kind).toSet(), {ListKind.movies});
      final counts = [for (final r in movies) r.items];
      expect(counts, orderedEquals([...counts]..sort()), reason: 'it never goes back');
      expect(counts, containsAll([1, 3, 5]), reason: 'as the bytes come');
      expect(movies.first.done, isFalse);
      expect(movies.last, (kind: ListKind.movies, items: 5, read: 1.0, done: true));
    });

    test('its categories, a few and in a moment, are not counted', () async {
      await panel((_) => send(utf8.encode('[{"category_id":"1","category_name":"Drama"}]'))).movieCategories();
      expect(seen, isEmpty);
    });

    test('a big list read back says how far the reading has got, with the isolate out of the way', () async {
      final big = _list(4000); // past what is read on the UI isolate
      expect(big.length, greaterThan(256 * 1024));
      await panel((_) => send(big, piece: 16 * 1024)).movies();
      seen.clear();

      await panel((_) => throw StateError('from the disk, not the line')).movies();

      final reading = [for (final rows in seen) rows.single].where((r) => !r.done && r.read != null).toList();
      expect(reading, isNotEmpty);
      expect(reading.first.items, 1024);
      expect(reading.first.read, inExclusiveRange(0, 1));
      expect(seen.last.single, (kind: ListKind.movies, items: 4000, read: 1.0, done: true));
    });

    test('one that fails says nothing any more, and the others stay', () async {
      final fine = listImports.start(ListKind.series)..counted(7);
      await expectLater(
        panel((_) => http.StreamedResponse(const Stream.empty(), 500)).movies(),
        throwsA(isA<SourceException>()),
      );
      expect(listImports.current.map((r) => r.kind), [ListKind.series]);
      fine.finish(7);
    });

    test('two playlists combined add up in one row', () {
      final one = listImports.start(ListKind.movies)..counted(10);
      final two = listImports.start(ListKind.movies)..counted(5);
      expect(listImports.value.single.items, 15);
      one.finish(10);
      expect(listImports.value.single.done, isFalse, reason: 'until both are here');
      two.finish(5);
      expect(listImports.value.single.done, isTrue);
    });

    test('a new load starts over; those of the one before do not stay under it', () {
      listImports.start(ListKind.movies).finish(10);
      expect(listImports.value.single.items, 10);
      final next = listImports.start(ListKind.live);
      expect(listImports.value.single.kind, ListKind.live);
      next.fail();
    });

    test('long after they all came, nothing is left to say', () {
      listImports.start(ListKind.movies).finish(10);
      expect(listImports.current, isNotEmpty, reason: 'what is made of them takes a while');
      ListImports.linger = Duration.zero;
      expect(listImports.current, isEmpty);
    });
  });

  test('a playlist counts its entries as it downloads', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );
    final list = utf8.encode('#EXTM3U\n${[for (var i = 0; i < 6; i++) '#EXTINF:-1,Channel $i\nhttp://a/$i\n'].join()}');
    await M3uSource.load(
      'http://list.test/a.m3u',
      client: MockClient.streaming((_, _) async => http.StreamedResponse(Stream.fromIterable(_pieces(list, 10)), 200)),
    );
    final rows = [for (final r in seen) r.single];
    expect(rows.map((r) => r.kind).toSet(), {ListKind.playlist});
    expect(rows.map((r) => r.items), contains(3), reason: 'as the bytes come');
    expect(rows.last.items, 6);
    expect(rows.last.done, isTrue);
  });

  group('the loading screen', () {
    tearDown(() {
      listDownloads.value = null;
      listImports.reset();
    });

    testWidgets('says how many of each kind have come, in the language of the app', (t) async {
      await t.pumpWidget(_app('es'));
      final live = listImports.start(ListKind.live);
      final movies = listImports.start(ListKind.movies)..counted(45120);
      final series = listImports.start(ListKind.series);
      live.finish(9328);
      await t.pump();

      expect(find.text('9.328'), findsOneWidget);
      expect(find.text('TV'), findsOneWidget);
      expect(find.text('45.120'), findsOneWidget);
      expect(find.text('Películas'), findsOneWidget);
      expect(find.text('–'), findsOneWidget, reason: 'nothing of the series yet');
      expect(find.text('Series'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget, reason: 'only the channels are all here');

      movies.finish(97422);
      series.finish(13158);
      await t.pump();
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(3));
      expect(find.text('97.422'), findsOneWidget);
    });

    testWidgets('goes on saying what it downloads, with the counts under it', (t) async {
      await t.pumpWidget(_app('es'));
      final movies = listImports.start(ListKind.movies)..counted(120);
      listDownloads.value = (received: 27000000, total: 60000000);
      await t.pump();
      expect(find.text('Descargando el catálogo… 45 %'), findsOneWidget);
      expect(find.text('120'), findsOneWidget);
      movies.fail();
    });

    testWidgets('once downloaded, says it is putting it in order and how far, with no number going back', (t) async {
      await t.pumpWidget(_app('es'));
      final movies = listImports.start(ListKind.movies)..counted(97422);
      movies.reading(10240, 0.25);
      await t.pump();
      expect(find.text('Organizando tu catálogo…'), findsOneWidget);
      expect(
        find.text('97.422'),
        findsOneWidget,
        reason: 'all of them came: reading them does not start again from none',
      );
      expect(t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.25, 0.001));
      movies.fail();
    });

    testWidgets('all here and still being put together, the counts stay and nothing fills again', (t) async {
      await t.pumpWidget(_app('en'));
      listImports.start(ListKind.movies).finish(97422);
      await t.pump();
      expect(find.text('97,422'), findsOneWidget);
      expect(find.text('Movies'), findsOneWidget);
      expect(find.text('Putting your catalog in order…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('fits on a phone held sideways', (t) async {
      t.view.physicalSize = const Size(640, 320);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app('es'));
      listImports
        ..start(ListKind.live).counted(9328)
        ..start(ListKind.movies).counted(97422)
        ..start(ListKind.series).counted(13158);
      await t.pump();
      expect(t.takeException(), isNull, reason: 'no overflow');
    });
  });

  testWidgets('one line for a playlist being opened: what came and how many', (t) async {
    late BuildContext context;
    await t.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    addTearDown(() {
      listDownloads.value = null;
      listImports.reset();
    });
    expect(listProgressText(context), isNull);

    final list = listImports.start(ListKind.playlist)..counted(12345);
    expect(listProgressText(context), '12.345 importados');
    listDownloads.value = (received: 14000000, total: null);
    expect(listProgressText(context), 'Descargando el catálogo… 14 MB · 12.345 importados');
    list.fail();
  });
}
