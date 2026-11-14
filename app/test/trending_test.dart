// This week's trending movies and series from TMDB: which ones, how often they are asked for,
// and which of them a provider has.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/poster_wall.dart';
import 'package:iptv_player/data/trending.dart';
import 'package:iptv_player/ui/catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _movie(
  int id,
  String title, {
  String? original,
  String date = '2026-09-16',
  List<int> genres = const [28],
  bool adult = false,
  bool art = true,
}) => {
  'id': id,
  'title': title,
  'original_title': original ?? title,
  'release_date': date,
  'vote_average': 7.45,
  'genre_ids': genres,
  'adult': adult,
  'poster_path': art ? '/m$id.jpg' : null,
  'backdrop_path': art ? '/b$id.jpg' : null,
};

Map<String, dynamic> _show(int id, String name, {String date = '2025-03-30'}) => {
  'id': id,
  'name': name,
  'original_name': name,
  'first_air_date': date,
  'vote_average': 8.6,
  'genre_ids': [18],
  'poster_path': '/s$id.jpg',
  'backdrop_path': '/sb$id.jpg',
};

Trend _trend(String title, {bool series = false, int? year = 2026, String? original, int id = 1}) =>
    Trend(series: series, tmdbId: id, title: title, originalTitle: original ?? title, year: year);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Trending.items.value = const [];
    PosterWall.posters.value = const [];
  });

  test('with artwork, never adult content nor horror, movies and series in turns', () {
    final picked = Trending.pick(
      movies: [
        _movie(1, 'Heart of the Beast'),
        _movie(2, 'Resident Evil', genres: [27, 878]),
        _movie(3, 'Not for kids', adult: true),
        _movie(4, 'No art', art: false),
        _movie(5, 'Primetime'),
        _movie(1, 'Heart of the Beast'), // on both pages
      ],
      series: [_show(10, 'MobLand')],
    );
    expect([for (final t in picked) t.title], ['Heart of the Beast', 'MobLand', 'Primetime']);
    final first = picked.first;
    expect(first.year, 2026);
    expect(first.rating, 7.45);
    expect(first.poster, 'https://image.tmdb.org/t/p/w342/m1.jpg');
    expect(first.backdrop, 'https://image.tmdb.org/t/p/w1280/b1.jpg');
    expect(picked[1].series, isTrue);
    expect(Trend.fromJson(jsonDecode(jsonEncode(first)) as Map<String, dynamic>).toJson(), first.toJson());
  });

  test('asked once a day and per language, kept on the device, the last answer kept when TMDB fails', () async {
    final asked = <Uri>[];
    var fail = false;
    final client = MockClient((req) async {
      asked.add(req.url);
      if (fail) return http.Response('', 503);
      // Age ratings: the first show is for adults only, the movies are not
      if (req.url.queryParameters.containsKey('append_to_response')) {
        final adults = req.url.path.endsWith('/10');
        return http.Response(
          jsonEncode({
            'content_ratings': {
              'results': [
                {'iso_3166_1': 'US', 'rating': adults ? 'TV-MA' : 'TV-14'},
              ],
            },
            'keywords': {'results': <Object>[]},
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/release_dates')) {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'iso_3166_1': 'US',
                'release_dates': [
                  {'certification': 'PG-13'},
                ],
              },
            ],
          }),
          200,
        );
      }
      final movies = req.url.path.contains('/movie/');
      final page = req.url.queryParameters['page'];
      return http.Response(
        jsonEncode({
          'results': movies
              ? [_movie(page == '1' ? 1 : 2, 'Movie $page')]
              : [_show(page == '1' ? 10 : 11, 'Show $page')],
        }),
        200,
      );
    });
    final now = DateTime(2026, 11, 6, 10);
    int trending() => asked.where((u) => u.path.contains('/trending/')).length;
    int ratings() => asked.where((u) => !u.path.contains('/trending/')).length;

    await Trending.refresh(language: 'es-CO', key: 'k', client: client, now: now);
    expect(trending(), 4);
    expect(ratings(), 4, reason: 'each trend rated once');
    expect([for (final t in Trending.items.value) t.mature], [false, true, false, false]);
    expect(asked.first.queryParameters, containsPair('language', 'es-CO'));
    expect([for (final t in Trending.items.value) t.title], ['Movie 1', 'Show 1', 'Movie 2', 'Show 2']);

    await Trending.refresh(language: 'es-CO', key: 'k', client: client, now: now.add(const Duration(hours: 20)));
    expect(trending(), 4, reason: 'less than a day old');

    // Saved while the clock was ahead, now set right: asked again rather than kept for good
    await Trending.refresh(language: 'es-CO', key: 'k', client: client, now: now.subtract(const Duration(days: 3)));
    expect(trending(), 8, reason: 'saved in what is now the future');

    await Trending.refresh(language: 'en', key: 'k', client: client, now: now.add(const Duration(hours: 21)));
    expect(trending(), 12, reason: 'another language');
    expect(ratings(), 4, reason: 'ratings known already are not asked again');

    fail = true;
    await Trending.refresh(language: 'en', key: 'k', client: client, now: now.add(const Duration(days: 2)));
    expect(Trending.items.value, hasLength(4), reason: 'kept');

    Trending.items.value = const [];
    await Trending.load();
    expect(Trending.items.value, hasLength(4), reason: 'from the device, at the next start');
    expect(Trending.items.value[1].mature, isTrue, reason: 'the rating is kept too');

    await Trending.refresh(language: 'en', client: client);
    expect(trending(), 16, reason: 'only the failed attempt; no key, no request');
  });

  test('which trends a provider has: by TMDB id, else by title in either language and year', () {
    final data = CatalogData(
      live: const [],
      movies: const [
        Movie(id: 'a', name: 'En el corazón de la bestia (2026)'),
        Movie(id: 'b', name: 'Primetime', year: 2026),
        Movie(id: 'c', name: 'Godzilla', year: 1998),
        Movie(id: 'd', name: 'Some other title', tmdbId: '42'),
      ],
      series: const [Series(id: 's', name: 'MobLand', year: 2025)],
    );
    final found = Trending.available(data, [
      _trend('En el corazón de la bestia', original: 'Heart of the Beast'),
      _trend('Tierra de mafiosos', original: 'MobLand', series: true, year: 2025),
      _trend('Primetime', year: 2025), // dated a year apart: still the same
      _trend('Godzilla', year: 2026), // the 1998 one is another film
      _trend('Renamed upstream', id: 42),
      _trend('Not on this provider'),
    ]);
    expect(
      [for (final (:item, trend: _) in found) item is Movie ? item.id : (item as Series).id],
      ['a', 's', 'b', 'd'],
    );
    expect(found.first.trend.title, 'En el corazón de la bestia');
  });

  test('a title the provider lists several times: the first copy of the right year', () {
    final data = CatalogData(
      live: const [],
      movies: const [
        Movie(id: 'g98', name: 'Godzilla', year: 1998),
        Movie(id: 'g14', name: 'Godzilla (2014)'),
        Movie(id: 'g14-4k', name: 'GODZILLA', year: 2014),
        Movie(id: 'dune', name: 'Dune', year: 2021),
      ],
      series: const [
        Series(id: 'dark', name: 'Dark'),
        Series(id: 'dark-4k', name: 'Dark [4K]', year: 2017),
      ],
    );
    String? found(Trend t) => switch (Trending.available(data, [t]).firstOrNull?.item) {
      final Movie m => m.id,
      final Series s => s.id,
      _ => null,
    };
    expect(found(_trend('Godzilla', year: 2014)), 'g14');
    expect(found(_trend('Godzilla', year: 1999)), 'g98', reason: 'a year apart');
    expect(found(_trend('Godzilla', year: 2005)), isNull);
    expect(found(_trend('Godzilla', year: null)), 'g98');
    expect(found(_trend('Dune', year: 2022)), 'dune');
    expect(found(_trend('Dark', series: true, year: 2017)), 'dark-4k', reason: 'the right year before none');
    expect(found(_trend('Dark', series: true, year: 2030)), 'dark', reason: 'undated: it may be');
  });

  test('the trailer: YouTube only, a trailer before a teaser, official ones first', () {
    Map<String, dynamic> v(String key, String type, {bool official = false, String site = 'YouTube'}) => {
      'key': key,
      'type': type,
      'official': official,
      'site': site,
    };
    expect(
      Trending.pickTrailer([
        v('clip', 'Clip', official: true),
        v('teaser', 'Teaser', official: true),
        v('fan', 'Trailer'),
        v('vimeo', 'Trailer', official: true, site: 'Vimeo'),
        v('official', 'Trailer', official: true),
        v('second', 'Trailer', official: true),
      ]),
      'official',
    );
    expect(Trending.pickTrailer([v('teaser', 'Teaser'), v('clip', 'Clip')]), 'teaser');
    expect(Trending.pickTrailer([v('clip', 'Featurette')]), isNull);
  });

  test('a trailer in the app\'s language, else in English, asked once', () async {
    final asked = <String>[];
    final client = MockClient((req) async {
      final lang = req.url.queryParameters['language']!;
      asked.add('${req.url.path} $lang');
      return http.Response(
        jsonEncode({
          'results': [
            if (lang == 'en-US') {'key': 'abc', 'type': 'Trailer', 'site': 'YouTube', 'official': true},
          ],
        }),
        200,
      );
    });
    Trending.language = 'es-CO';
    final t = _trend('MobLand', series: true, id: 247718);
    expect(await Trending.trailer(t, key: 'k', client: client), 'abc');
    expect(await Trending.trailer(t, key: 'k', client: client), 'abc');
    expect(asked, ['/3/tv/247718/videos es-CO', '/3/tv/247718/videos en-US']);
  });

  test("the YouTube id in what providers give as a trailer", () {
    expect(youtubeId('Rh24D89hFMg'), 'Rh24D89hFMg');
    expect(youtubeId('https://www.youtube.com/watch?v=Rh24D89hFMg&t=3'), 'Rh24D89hFMg');
    expect(youtubeId('https://youtu.be/Rh24D89hFMg'), 'Rh24D89hFMg');
    expect(youtubeId('https://www.youtube.com/embed/Rh24D89hFMg'), 'Rh24D89hFMg');
    expect(youtubeId(''), isNull);
    expect(youtubeId(null), isNull);
    expect(youtubeId('not a trailer'), isNull);
  });

  test("a provider's title is found on TMDB by name and year, never a namesake", () async {
    final asked = <Uri>[];
    final client = MockClient((req) async {
      asked.add(req.url);
      if (req.url.path == '/3/search/movie') {
        return http.Response(
          jsonEncode({
            'results': [
              {'id': 7, 'title': 'Heat Wave', 'original_title': 'Heat Wave'},
              {'id': 949, 'title': 'Fuego contra fuego', 'original_title': 'Heat'},
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'results': [
            {'key': 'heat1995abc', 'type': 'Trailer', 'site': 'YouTube', 'official': true},
          ],
        }),
        200,
      );
    });
    Trending.language = 'es-CO';
    final found = await Trending.findTrailer(
      series: false,
      title: 'Heat (1995) [4K]',
      year: 1995,
      key: 'k',
      client: client,
    );
    expect(found, 'heat1995abc');
    expect(asked.first.queryParameters, containsPair('query', 'heat'));
    expect(asked.first.queryParameters, containsPair('year', '1995'));
    expect(asked[1].path, '/3/movie/949/videos', reason: 'the one titled Heat, not Heat Wave');

    final none = MockClient(
      (req) async => http.Response(
        jsonEncode({
          'results': [
            {'id': 7, 'title': 'Heat Wave', 'original_title': 'Heat Wave'},
          ],
        }),
        200,
      ),
    );
    expect(await Trending.findTrailer(series: true, title: 'Heat', key: 'k', client: none), isNull);

    // The provider says 2024, TMDB 2023: asked again with no year, and a namesake of 2010 does not count
    final years = <String?>[];
    final oneOff = MockClient((req) async {
      if (req.url.path == '/3/search/tv') {
        years.add(req.url.queryParameters['first_air_date_year']);
        return http.Response(
          jsonEncode({
            'results': req.url.queryParameters.containsKey('first_air_date_year')
                ? []
                : [
                    {'id': 1, 'name': 'Shogun', 'first_air_date': '2010-01-01'},
                    {'id': 2, 'name': 'Shogun', 'first_air_date': '2023-02-27'},
                  ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'results': [
            {'key': 'shogun${req.url.path.split('/')[3]}', 'type': 'Trailer', 'site': 'YouTube'},
          ],
        }),
        200,
      );
    });
    expect(await Trending.findTrailer(series: true, title: 'Shogun', year: 2024, key: 'k', client: oneOff), 'shogun2');
    expect(years, ['2024', null]);
  });

  testWidgets('the most watched: numbered from one, never more than ten, movies apart from series', (t) async {
    final data = CatalogData(
      live: const [],
      movies: [for (var i = 0; i < 12; i++) Movie(id: '$i', name: 'Movie $i', year: 2026)],
      series: const [Series(id: 's', name: 'Show', year: 2026)],
    );
    final trends = [for (var i = 0; i < 12; i++) _trend('Movie $i', id: i), _trend('Show', series: true, id: 99)];
    expect(Trending.ofKind(data, series: true, trends: trends), [data.series.single]);
    final movies = Trending.ofKind(data, series: false, trends: trends);
    expect(movies, hasLength(12));

    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RankedRail(
            title: 'Most watched',
            items: [for (final m in movies.cast<Movie>()) CatalogItem(id: m.id, title: m.name, open: (_) {})],
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Movie 0'), findsWidgets); // its title, and the name in place of the missing poster
    await t.drag(find.byType(ListView), const Offset(-4000, 0));
    await t.pump();
    expect(find.text('10'), findsOneWidget);
    expect(find.text('11'), findsNothing);
    expect(find.text('Movie 10'), findsNothing);
  });

  test("a catalog's language, by its small words", () {
    expect(
      Trending.guessLanguage([
        for (var i = 0; i < 30; i++) ...['El señor de los anillos', 'La casa de papel', 'Los Spiderwick'],
      ]),
      'es',
    );
    expect(Trending.guessLanguage([for (var i = 0; i < 30; i++) 'The Lord of the Rings']), 'en');
    expect(Trending.guessLanguage(['Heat', 'Ozark']), isNull, reason: 'too little to tell');
  });

  test("an app in English finds the trends in a Spanish catalog by their Spanish titles", () async {
    final asked = <String>[];
    final client = MockClient((req) async {
      asked.add(req.url.queryParameters['language']!);
      final movies = req.url.path.contains('/movie/');
      return http.Response(
        jsonEncode({
          'results': [
            if (movies && req.url.queryParameters['page'] == '1') {'id': 1, 'title': 'La mangosta'},
          ],
        }),
        200,
      );
    });
    Trending.language = 'en-US';
    Trending.items.value = [_trend('The Mongoose', id: 1)];
    final data = CatalogData(
      live: const [],
      movies: const [Movie(id: 'm', name: 'La mangosta', year: 2026)],
      series: const [],
    );
    expect(Trending.available(data), isEmpty);

    await Trending.alsoIn('es', key: 'k', client: client);
    expect(asked, ['es', 'es', 'es', 'es']);
    expect(Trending.items.value.single.otherTitles, ['La mangosta']);
    expect([for (final (trend: _, :item) in Trending.available(data)) (item as Movie).id], ['m']);

    await Trending.alsoIn('es', key: 'k', client: client);
    expect(asked, hasLength(4), reason: 'once a day');
    await Trending.alsoIn('en', key: 'k', client: client);
    expect(asked, hasLength(4), reason: "the app's own language: nothing to ask");
  });

  test("adults only, by TMDB's ratings: R, NC-17, TV-MA in the US, else 18 anywhere", () {
    Map<String, dynamic> tv(String country, String rating) => {'iso_3166_1': country, 'rating': rating};
    Map<String, dynamic> movie(String country, String cert) => {
      'iso_3166_1': country,
      'release_dates': [
        {'certification': cert},
      ],
    };
    expect(Trending.matureRating([tv('US', 'TV-MA'), tv('DE', '18')]), isTrue);
    expect(Trending.matureRating([tv('US', 'TV-14'), tv('DE', '18')]), isFalse, reason: 'the US one decides');
    expect(Trending.matureRating([movie('US', 'R'), movie('ES', '12')]), isTrue);
    expect(Trending.matureRating([movie('US', ''), movie('GB', '18')]), isTrue, reason: 'no US rating');
    expect(Trending.matureRating([movie('ES', '7')]), isFalse);
    expect(Trending.matureRating(const []), isNull, reason: 'nothing to go by');
    expect(Trending.matureRating([tv('US', ''), tv('FR', 'NR')]), isNull);
    expect(Trending.matureRating([tv('US', ''), tv('DE', '18')]), isTrue, reason: 'an empty one is no rating');
    expect(Trending.matureRating([tv('US', 'NR'), tv('DE', '18')]), isTrue, reason: 'nor is not rated');
    expect(Trending.matureRating([movie('US', 'UR'), movie('GB', '18')]), isTrue);
    expect(Trending.matureRating([tv('KR', '19')]), isTrue);
    expect(Trending.matureRating([movie('SG', 'R21')]), isTrue);
    expect(Trending.matureRating([tv('KR', '15'), movie('SG', 'PG13')]), isFalse);
  });

  test('a series with horror among its keywords counts as adults only, as TMDB has no such genre for them', () {
    Map<String, dynamic> details(String rating, List<String> keywords) => {
      'content_ratings': {
        'results': [
          {'iso_3166_1': 'US', 'rating': rating},
        ],
      },
      'keywords': {
        'results': [
          for (final k in keywords) {'name': k},
        ],
      },
    };
    expect(Trending.matureSeries(details('TV-14', ['small town', 'supernatural horror'])), isTrue);
    expect(Trending.matureSeries(details('TV-14', ['small town'])), isFalse);
    expect(Trending.matureSeries(details('TV-MA', const [])), isTrue);
    expect(Trending.matureSeries(const {}), isNull);
  });

  test('for children only by a US rating for children', () {
    Map<String, dynamic> tv(String country, String rating) => {'iso_3166_1': country, 'rating': rating};
    Map<String, dynamic> movie(String cert) => {
      'iso_3166_1': 'US',
      'release_dates': [
        {'certification': cert},
      ],
    };
    for (final r in ['TV-Y', 'TV-Y7', 'TV-G', 'TV-PG']) {
      expect(Trending.kidsSafeRating([tv('US', r)]), isTrue, reason: r);
    }
    expect(Trending.kidsSafeRating([movie('G')]), isTrue);
    expect(Trending.kidsSafeRating([movie('PG')]), isTrue);
    expect(Trending.kidsSafeRating([movie('PG-13')]), isFalse);
    expect(Trending.kidsSafeRating([tv('US', 'TV-14')]), isFalse);
    expect(Trending.kidsSafeRating([movie('PG'), movie('R')]), isFalse);
    expect(Trending.kidsSafeRating([tv('DE', '0')]), isFalse, reason: 'no US rating');
    expect(Trending.kidsSafeRating(const []), isFalse);
  });

  test('a rating that could not be asked is not taken for an answer: unseen, and asked next time', () async {
    var ratingsFail = true;
    var ratingsAsked = 0;
    final client = MockClient((req) async {
      if (req.url.path.contains('/trending/')) {
        final movies = req.url.path.contains('/movie/');
        return http.Response(
          jsonEncode({
            'results': movies ? [_movie(1, 'Movie')] : <Object>[],
          }),
          200,
        );
      }
      ratingsAsked++;
      if (ratingsFail) return http.Response('', 503);
      return http.Response(
        jsonEncode({
          'results': [
            {
              'iso_3166_1': 'US',
              'release_dates': [
                {'certification': 'R'},
              ],
            },
          ],
        }),
        200,
      );
    });
    final now = DateTime(2026, 11, 6, 10);
    await Trending.refresh(language: 'en', key: 'k', client: client, now: now);
    expect(ratingsAsked, 1);
    expect(Trending.items.value.single.mature, isNull);
    expect(Trending.items.value.single.kidsSafe, isNull);
    final data = CatalogData(
      live: const [],
      movies: const [Movie(id: 'a', name: 'Movie')],
      series: const [],
    );
    expect(Trending.ofKind(data, series: false), hasLength(1), reason: 'grown-ups still get it');
    expect(Trending.ofKind(data, series: false, forKids: true), isEmpty);

    ratingsFail = false;
    await Trending.refresh(language: 'en', key: 'k', client: client, now: now.add(const Duration(days: 2)));
    expect(ratingsAsked, 2, reason: 'not known yet, so asked again');
    expect(Trending.items.value.single.mature, isTrue);
    expect(Trending.items.value.single.kidsSafe, isFalse);

    Trending.items.value = const [];
    await Trending.load();
    expect(Trending.items.value.single.mature, isTrue, reason: 'kept on the device');
  });

  test('never on the screens the family sees, nor for kids', () {
    Trend t(int id, {bool mature = false, bool series = false}) => Trend(
      series: series,
      tmdbId: id,
      title: 'T$id',
      originalTitle: 'T$id',
      poster: 'https://image.test/$id.jpg',
      mature: mature,
      kidsSafe: !mature,
    );
    Trending.items.value = [for (var i = 0; i < 9; i++) t(i, mature: i == 0)];
    expect(PosterWall.wall, isNot(contains('https://image.test/0.jpg')));
    final data = CatalogData(
      live: const [],
      movies: const [
        Movie(id: 'a', name: 'T0'),
        Movie(id: 'b', name: 'T1'),
      ],
      series: const [],
    );
    expect(Trending.ofKind(data, series: false), hasLength(2));
    expect([for (final m in Trending.ofKind(data, series: false, forKids: true)) (m as Movie).id], ['b']);
  });

  test('the wall shows the trending posters when there are enough, else the provider\'s', () {
    PosterWall.posters.value = ['https://provider.test/p.jpg'];
    Trending.items.value = [for (var i = 0; i < 5; i++) _trend('T$i', id: i)];
    expect(PosterWall.wall, ['https://provider.test/p.jpg'], reason: 'trends without posters');
    Trending.items.value = [
      for (var i = 0; i < 8; i++)
        Trend(
          series: false,
          tmdbId: i,
          title: 'T$i',
          originalTitle: 'T$i',
          mature: false,
          poster: 'https://image.test/$i.jpg',
        ),
    ];
    expect(PosterWall.wall, hasLength(8));
    expect(PosterWall.wall.first, 'https://image.test/0.jpg');
  });
}
