// Finding the same titles and channels with another provider, where every id is different.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/matching.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The new provider: two films called "Dune" (a remake), and one series.
XtreamSource _newProvider() => XtreamSource(
  server: 'http://new.example',
  username: 'u',
  password: 'p',
  client: MockClient((req) async {
    final q = req.url.queryParameters;
    final body = switch (q['action']) {
      'get_vod_info' => {
        'info': {
          'tmdb_id': q['vod_id'] == '900'
              ? '841'
              : q['vod_id'] == '999'
              ? ''
              : '438631',
        }, // 999: none it knows
      },
      'get_series_info' => {
        'episodes': {
          '1': [
            {
              'id': '7001',
              'episode_num': 1,
              'season': 1,
              'title': 'Pilot',
              'info': {'tmdb_id': 62085},
            },
            {'id': '7002', 'episode_num': 2, 'season': 1, 'title': 'Two', 'info': <String, dynamic>{}},
          ],
        },
      },
      _ => const <String, dynamic>{},
    };
    return http.Response(jsonEncode(body), 200);
  }),
);

final _catalog = CatalogData(
  live: const [
    LiveChannel(id: 'c1', name: 'ES | Movistar La Liga FHD', epgId: 'laliga.es'),
    LiveChannel(id: 'c2', name: 'CNN International HD'),
  ],
  movies: const [
    Movie(id: '900', name: 'Dune (1984)', year: 1984),
    Movie(id: '901', name: 'Dune', year: 2021),
    Movie(id: '902', name: 'Amélie [4K]', year: 2001),
  ],
  series: const [Series(id: 's9', name: 'Breaking Bad', year: 2008)],
);

void main() {
  test('titles and channels compare loosely', () {
    expect(looseTitle('Arthur (2024) [4K]'), 'arthur');
    expect(looseTitle('AMÉLIE'), 'amelie');
    expect(looseChannel('ES | Movistar La Liga FHD'), looseChannel('es: MOVISTAR LA LIGA'));
    expect(yearInTitle('Arthur (2024)'), 2024);
    expect(yearInTitle('Arthur [2024]'), 2024);
    expect(yearInTitle('Arthur [1080]'), isNull, reason: 'a quality, not a year');
    expect(versionKey('Dune [1984]', null) == versionKey('Dune [2021]', null), isFalse);
    expect(versionKey('Dark - Latino (2017)', null), versionKey('Dark', 2017));
    expect(versionKey('Amor Latino', 2020), 'amor latino|2020');
    expect(bareTitle('Aeropuerto - ALTADEFINICION 1080p - ESP-AC3'), 'aeropuerto');
  });

  test('titles in other scripts are told apart when moving a library', () async {
    final migration = LibraryMigration(
      source: _newProvider(),
      catalog: CatalogData(
        live: const [],
        movies: const [
          Movie(id: 'k1', name: '기생충', year: 2019),
          Movie(id: 'r1', name: 'Брат', year: 1997),
        ],
        series: const [],
      ),
    );
    Future<String?> find(String title, int year) async =>
        (await migration.find(MediaRef(kind: MediaKind.movie, id: 'old', title: title, year: year)))?.id;
    expect(await find('Брат', 1997), 'r1');
    expect(await find('기생충', 2019), 'k1');
    expect(await find('Сталкер', 1997), isNull, reason: 'not the first non-Latin title of a close year');
  });

  test('the universal key prefers the TMDB id, then title and year', () {
    const withTmdb = MediaRef(kind: MediaKind.movie, id: '1', title: 'Arthur', tmdb: '618588');
    const byTitle = MediaRef(kind: MediaKind.movie, id: '2', title: 'Arthur (2024)');
    const otherProvider = MediaRef(kind: MediaKind.movie, id: '999', title: 'ARTHUR', year: 2024);
    expect(universalKey(withTmdb), 'movie/tmdb/618588');
    expect(universalKey(byTitle), universalKey(otherProvider), reason: 'different ids, same film');
    const episode = MediaRef(kind: MediaKind.episode, id: '5', title: 'x', seriesTitle: 'Lost', season: 1, number: 2);
    expect(universalKey(episode), 'episode/lost/1x2');
    expect(universalKey(const MediaRef(kind: MediaKind.live, id: '3', title: 'A', epgId: 'BBC.uk')), 'live/epg/bbc.uk');
  });

  group('moving a library to another provider', () {
    final migration = LibraryMigration(source: _newProvider(), catalog: _catalog);

    test('a remake with the same title is told apart by its TMDB id', () async {
      const dune2021 = MediaRef(kind: MediaKind.movie, id: 'old-1', title: 'Dune', year: 2021, tmdb: '438631');
      expect((await migration.find(dune2021))!.id, '901');
      const dune1984 = MediaRef(kind: MediaKind.movie, id: 'old-2', title: 'Dune (1984)', tmdb: '841');
      expect((await migration.find(dune1984))!.id, '900');
      const amelie = MediaRef(kind: MediaKind.movie, id: 'old-3', title: 'Amelie', year: 2001);
      expect((await migration.find(amelie))!.id, '902', reason: 'no TMDB id: title and year are enough');
      expect(await migration.find(const MediaRef(kind: MediaKind.movie, id: 'x', title: 'Not here')), isNull);
    });

    test('episodes by TMDB id or number, channels by guide id or name', () async {
      const pilot = MediaRef(
        kind: MediaKind.episode,
        id: 'old-ep',
        title: 'Pilot',
        seriesTitle: 'Breaking Bad',
        season: 1,
        number: 1,
        tmdb: '62085',
      );
      expect((await migration.find(pilot))!.id, '7001');
      const second = MediaRef(
        kind: MediaKind.episode,
        id: 'old-ep2',
        title: 'Two',
        seriesTitle: 'Breaking Bad',
        season: 1,
        number: 2,
      );
      final found = (await migration.find(second))!;
      expect((found.id, found.seriesId), ('7002', 's9'));
      const liga = MediaRef(kind: MediaKind.live, id: 'old-c', title: 'LaLiga TV', epgId: 'LALIGA.ES');
      expect((await migration.find(liga))!.id, 'c1');
      const cnn = MediaRef(kind: MediaKind.live, id: 'old-d', title: 'CNN INTERNATIONAL');
      expect((await migration.find(cnn))!.id, 'c2');
    });

    test('positions and favorites travel; what is missing is reported', () async {
      SharedPreferences.setMockInitialValues({});
      final watched = HistoryEntry(
        ref: const MediaRef(kind: MediaKind.movie, id: 'old-1', title: 'Dune', year: 2021, tmdb: '438631'),
        position: const Duration(minutes: 42),
        duration: const Duration(minutes: 155),
        updated: DateTime(2026, 11, 1),
      );
      final result = await migration.run({
        'favorites': [const MediaRef(kind: MediaKind.live, id: 'old-d', title: 'CNN International').toJson()],
        'history': [
          watched.toJson(),
          HistoryEntry(
            ref: const MediaRef(kind: MediaKind.movie, id: 'gone', title: 'Lost Film'),
            position: Duration.zero,
            duration: Duration.zero,
            updated: DateTime(2026, 10, 1),
          ).toJson(),
        ],
      }, 'new');
      expect(result.moved, 2);
      expect(result.missing, ['Lost Film']);
      final library = await Library.load('new', mainProfileId);
      expect(library.favorites(MediaKind.live).single.id, 'c2');
      final entry = library.entry(const MediaRef(kind: MediaKind.movie, id: '901', title: 'Dune'))!;
      expect(entry.position, const Duration(minutes: 42));
      expect(entry.updated, DateTime(2026, 11, 1));
    });
  });

  test('movies in a library get their TMDB id from the full record', () async {
    SharedPreferences.setMockInitialValues({});
    final library = await Library.load('p', mainProfileId);
    await library.toggleFavorite(const MediaRef(kind: MediaKind.movie, id: '901', title: 'Dune'));
    expect(await addTmdbIds(library, _newProvider()), 1);
    expect(library.favorites(MediaKind.movie).single.tmdb, '438631');
    expect(await addTmdbIds(library, _newProvider()), 0, reason: 'nothing left to look up');
  });

  test('a movie in favorites and in the history is asked once; one with no TMDB id is left alone a while', () async {
    SharedPreferences.setMockInitialValues({});
    final library = await Library.load('p', mainProfileId);
    const dune = MediaRef(kind: MediaKind.movie, id: '901', title: 'Dune');
    const unknown = MediaRef(kind: MediaKind.movie, id: '999', title: 'Nobody knows');
    await library.toggleFavorite(unknown);
    await library.record(unknown, position: const Duration(minutes: 5), duration: const Duration(minutes: 90));
    await library.toggleFavorite(dune);
    expect(await addTmdbIds(library, _newProvider()), 2, reason: 'the unknown one once, and Dune');
    expect(await addTmdbIds(library, _newProvider()), 0, reason: 'the one with no id is not asked again yet');
  });

  test('a playlist closed, or another one open, stops the TMDB lookups and writes nothing', () async {
    SharedPreferences.setMockInitialValues({});
    final library = await Library.load('p', mainProfileId);
    await library.toggleFavorite(const MediaRef(kind: MediaKind.movie, id: '901', title: 'Dune'));
    expect(await addTmdbIds(library, _newProvider(), open: () => false), 0);
    var answers = 0;
    // Closed while the record was on its way: what came is not written
    expect(await addTmdbIds(library, _newProvider(), open: () => answers++ == 0), 1);
    expect(library.favorites(MediaKind.movie).single.tmdb, isNull);
  });
}
