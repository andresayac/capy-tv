// The posters behind the screens outside a playlist: which ones, and when they are noted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/poster_wall.dart';
import 'package:iptv_player/ui/backdrop.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 11, 5);

Movie _m(String id, {double rating = 8, String? genre, String? poster}) => Movie(
  id: id,
  name: 'Movie $id',
  rating: rating,
  year: 2025,
  genre: genre,
  poster: poster ?? 'https://img.test/m$id.jpg',
  added: DateTime(2026, 10, 1),
);

Series _s(String id) => Series(id: id, name: 'Series $id', rating: 8, year: 2025, cover: 'https://img.test/s$id.jpg');

CatalogData _catalog({List<Movie> movies = const [], List<Series> series = const []}) =>
    CatalogData(live: const [], movies: movies, series: series, now: _now);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PosterWall.posters.value = const [];
  });

  test('best rated first, two movies for each series, each once, no horror, no broken art', () {
    final picked = PosterWall.pick(
      _catalog(
        movies: [
          _m('1', rating: 9),
          _m('2', rating: 7.5),
          _m('3', rating: 8, genre: 'Horror, Thriller'),
          _m('4', rating: 8.5, genre: 'Terror'),
          _m('5', poster: 'not-a-url'),
          _m('6', rating: 7.2, poster: 'https://img.test/m1.jpg'), // the same art as 1
        ],
        series: [_s('1'), _s('2')],
      ),
    );
    expect(picked, [
      'https://img.test/m1.jpg',
      'https://img.test/m2.jpg',
      'https://img.test/s1.jpg',
      'https://img.test/s2.jpg',
    ]);
  });

  test('what the whole family should not see, by genre or age, and those without a genre last', () {
    final picked = PosterWall.pick(
      _catalog(
        movies: [
          _m('1', rating: 9),
          _m('2', rating: 8.8, genre: 'Thriller'),
          _m('3', rating: 8.7, genre: 'Crimen'),
          _m('4', rating: 8.6, genre: 'Bélica'),
          _m('5', rating: 8.5, genre: 'Erótico'),
          _m('6', rating: 8.4, genre: 'Comedia'),
        ],
      ),
    );
    expect(picked, ['https://img.test/m6.jpg', 'https://img.test/m1.jpg']);
  });

  test('never more than a wall holds', () {
    final picked = PosterWall.pick(_catalog(movies: [for (var i = 0; i < 100; i++) _m('$i')]));
    expect(picked, hasLength(PosterWall.size));
  });

  test('noted from catalogs without adult content only, and kept for the next start', () async {
    final data = _catalog(movies: [for (var i = 0; i < 20; i++) _m('$i')]);
    await PosterWall.remember(data, adultHidden: false);
    expect(PosterWall.posters.value, isEmpty, reason: 'a catalog that shows adult content');
    await PosterWall.remember(_catalog(movies: [_m('1'), _m('2')]), adultHidden: true);
    expect(PosterWall.posters.value, isEmpty, reason: 'too few for a wall');
    await PosterWall.remember(data, adultHidden: true);
    expect(PosterWall.posters.value, hasLength(20));

    PosterWall.posters.value = const [];
    await PosterWall.load();
    expect(PosterWall.posters.value, hasLength(20));
  });

  testWidgets('the screen goes on top, see-through, with or without posters', (t) async {
    Future<void> show() => t.pumpWidget(
      MaterialApp(
        theme: ThemeData(scaffoldBackgroundColor: Colors.black),
        home: PosterBackdrop(
          child: Scaffold(
            appBar: AppBar(title: const Text('Sync')),
            body: const Text('Hello'),
          ),
        ),
      ),
    );

    await show();
    expect(find.text('Hello'), findsOneWidget);
    final scaffold = t.element(find.byType(Scaffold));
    expect(Theme.of(scaffold).scaffoldBackgroundColor, Colors.transparent);
    expect(
      find.byType(ColoredBox).evaluate().where((e) => (e.widget as ColoredBox).color == PosterBackdrop.veil),
      isEmpty,
    );

    PosterWall.posters.value = ['https://img.test/m1.jpg', 'https://img.test/m2.jpg'];
    await t.pump();
    expect(find.text('Hello'), findsOneWidget);
    expect(
      find.byType(ColoredBox).evaluate().where((e) => (e.widget as ColoredBox).color == PosterBackdrop.veil),
      hasLength(1),
      reason: 'the posters, under the veil',
    );

    // Drifting: the columns move, the screen on top stays
    double column() => t.widget<Transform>(find.byType(Transform).first).transform.getTranslation().y;
    final before = column();
    await t.pump(const Duration(seconds: 3));
    expect(column(), isNot(before));
    expect(find.text('Hello'), findsOneWidget);
  });
}
