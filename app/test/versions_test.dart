// Versions of a title (per language, quality or provider): shown once, all a tap away, and the
// fastest server tried first, by the hour of the day.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/stream_stats.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:iptv_player/player/play.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final data = CatalogData(
    live: const [],
    movies: [
      Movie(id: 'lat', name: 'Heat (1995)', year: 1995, rating: 8, poster: 'p', added: DateTime(2026, 1, 3)),
      Movie(id: '4k', name: 'Heat [4K]', year: 1995, rating: 8, poster: 'p', added: DateTime(2026, 1, 2)),
      Movie(id: 'new', name: 'Heat', year: 2026, rating: 7, poster: 'p', added: DateTime(2026, 1, 1)),
    ],
    series: const [],
    now: DateTime(2026, 11, 6),
  );

  test('a title listed once per language or quality: once in rows, every copy on its page', () {
    expect([for (final m in data.recentMovies) m.id], ['lat', 'new']);
    expect([for (final m in data.versionsOf(data.movies[1])) m.id], ['lat', '4k']);
    expect(data.versionsOf(data.movies[2]), [data.movies[2]], reason: 'another year, another film');
  });

  test('a provider category with a title twice shows it once, before the catalog is in too', () {
    final category = [data.movies[1], data.movies[0], data.movies[2]];
    expect([for (final m in oneOfEachTitle(category, data)) m.id], ['4k', 'new'], reason: 'the copy listed there');
    expect([for (final m in oneOfEachTitle(category, null)) m.id], ['4k', 'new']);
    final series = [const Series(id: 'a', name: 'Dark (2017)'), const Series(id: 'b', name: 'Dark [4K] (2017)')];
    expect([for (final s in oneOfEachTitle(series, null)) s.id], ['a']);
  });

  test('messy names a provider writes are still versions of one title', () {
    final messy = CatalogData(
      live: const [],
      movies: const [
        Movie(id: 'a', name: 'Spider-Man: Un nuevo universo (2018)'),
        Movie(id: 'b', name: 'Spider-Man Un Nuevo Universo (2018).mp4'),
        Movie(id: 'c', name: 'Spider-Man: No Way Home', year: 2022),
        Movie(id: 'd', name: 'Spider-Man No Way Home.2022'),
        Movie(id: 'e', name: 'Blade Runner 2049'),
      ],
      series: const [],
    );
    expect([for (final m in messy.versionsOf(messy.movies[0])) m.id], ['a', 'b']);
    expect([for (final m in messy.versionsOf(messy.movies[2])) m.id], ['c', 'd']);
    expect(messy.versionsOf(messy.movies[4]), [messy.movies[4]], reason: '2049 is part of that title');
  });

  test('playing a title brings its other copies along', () {
    final source = XtreamSource(server: 'http://a.test', username: 'u', password: 'p');
    final catalog = Catalog(source)..loaded = data;
    currentCatalog.value = catalog;
    addTearDown(() => currentCatalog.value = null);
    final item = movieItem(source, data.movies.first);
    expect(item.url, contains('/lat.'));
    expect([for (final a in item.alternates) a.url], [contains('/4k.')]);
    expect(item.ref?.id, 'lat', reason: 'progress goes to the one chosen');
  });

  group('the fastest server first, at this hour', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      StreamStats.reset();
    });
    final morning = DateTime(2026, 11, 6, 9), night = DateTime(2026, 11, 6, 21);
    String url(String host) => 'http://$host:8080/movie/u/p/1.mkv';

    test('learnt by the hour: quick in the morning is not quick at night', () {
      StreamStats.started(url('a.test'), const Duration(seconds: 2), at: morning);
      StreamStats.started(url('a.test'), const Duration(seconds: 15), at: night);
      StreamStats.started(url('b.test'), const Duration(seconds: 5), at: morning);
      StreamStats.started(url('b.test'), const Duration(seconds: 4), at: night);
      final both = [url('a.test'), url('b.test')];
      expect(StreamStats.fastestFirst(both, (u) => u, at: morning), [url('a.test'), url('b.test')]);
      expect(StreamStats.fastestFirst(both, (u) => u, at: night), [url('b.test'), url('a.test')]);
      // An hour with nothing known takes the next one
      expect(StreamStats.fastestFirst(both, (u) => u, at: DateTime(2026, 11, 6, 22)), [url('b.test'), url('a.test')]);
    });

    test('one that failed goes last; one never tried keeps its place among the unknown', () {
      StreamStats.failed(url('a.test'), at: morning);
      expect(StreamStats.fastestFirst([url('a.test'), url('c.test')], (u) => u, at: morning), [
        url('c.test'),
        url('a.test'),
      ]);
      expect(StreamStats.fastestFirst([url('c.test'), url('d.test')], (u) => u, at: morning), [
        url('c.test'),
        url('d.test'),
      ]);
    });

    test('kept for the next start', () async {
      StreamStats.started(url('a.test'), const Duration(seconds: 3), at: morning);
      await Future<void>.delayed(const Duration(seconds: 3)); // saved a moment later
      StreamStats.reset();
      await StreamStats.load();
      expect(StreamStats.expected(url('a.test'), at: morning), const Duration(seconds: 3));
    });
  });
}
