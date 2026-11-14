import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/source.dart';

final _now = DateTime(2026, 11, 5);

Movie _m(String id, {double? rating, int? year, String? genre, int addedDay = 1, String? poster = 'p', String? plot}) =>
    Movie(
      id: id,
      name: 'Movie $id',
      rating: rating,
      year: year,
      genre: genre,
      poster: poster,
      plot: plot,
      added: DateTime(2026, 10, addedDay),
    );

/// Movies fail until [fail] is turned off; the rest is empty.
class _Flaky implements ContentSource {
  var fail = true, movieAsks = 0;
  var live = const <LiveChannel>[];

  @override
  Future<List<Movie>> movies([String? categoryId]) async {
    movieAsks++;
    return fail ? throw const SourceException(SourceError.timeout) : [_m('a')];
  }

  @override
  Future<List<LiveChannel>> liveChannels([String? categoryId]) async => live;

  @override
  Future<List<Series>> series([String? categoryId]) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// These movies and series, and no channels.
class _Lists implements ContentSource {
  _Lists(this._movies, this._series);

  final List<Movie> _movies;
  final List<Series> _series;

  @override
  Future<List<Movie>> movies([String? categoryId]) async => _movies;

  @override
  Future<List<Series>> series([String? categoryId]) async => _series;

  @override
  Future<List<LiveChannel>> liveChannels([String? categoryId]) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a list that failed is asked for again on the next load', () async {
    final source = _Flaky(), catalog = Catalog(source);
    await expectLater(catalog.load(), throwsA(isA<SourceException>()), reason: 'nothing at all: an error');
    source.fail = false;
    expect((await catalog.load()).movies.single.id, 'a');
    source.fail = true;
    expect((await catalog.load()).movies, hasLength(1), reason: 'once loaded, it is kept');
  });

  test('with one list missing, the rest is kept a while: drawing Home again asks the panel nothing', () async {
    final source = _Flaky()..live = [const LiveChannel(id: '1', name: 'News')];
    final catalog = Catalog(source);
    expect((await catalog.load()).live, hasLength(1));
    await catalog.load();
    await catalog.load();
    expect(source.movieAsks, 1, reason: 'not once per load');
    final wait = Catalog.retryAfter;
    addTearDown(() => Catalog.retryAfter = wait);
    Catalog.retryAfter = Duration.zero;
    final again = Catalog(source..fail = true);
    await again.load();
    source.fail = false;
    expect((await again.load()).movies.single.id, 'a', reason: 'asked again once the while is over');
  });

  test('provider category names become readable titles', () {
    expect(displayCategoryName('🎞️ VOD | TOP 10 DE LA SEMANA'), 'Top 10 de la Semana');
    expect(displayCategoryName('🍿 SERIES | ESTRENOS 2026'), 'Estrenos 2026');
    expect(displayCategoryName('⚽ ESPN DEPORTES'), 'ESPN Deportes');
    expect(displayCategoryName('📺 TV° UNIVERSAL & HBO'), 'TV° Universal & HBO');
    expect(displayCategoryName('⭐ EVENTOS LIGAS DE SUDAMERICA'), 'Eventos Ligas de Sudamerica');
    expect(displayCategoryName('Cine Clásico'), 'Cine Clásico'); // already well written: untouched
    expect(displayCategoryName('🎬'), '🎬'); // nothing left: keep the original
  });

  test('genres split on commas and slashes', () {
    expect(splitGenres('Acción, Comedia / Drama'), ['Acción', 'Comedia', 'Drama']);
    expect(splitGenres(null), isEmpty);
  });

  test('curated movie rows', () {
    final data = CatalogData(
      now: _now,
      movies: [
        _m('old-classic', rating: 9, year: 1972, genre: 'Drama', addedDay: 1),
        _m('new-hit', rating: 8.1, year: 2026, genre: 'Acción, Drama', addedDay: 20, plot: 'p'),
        _m('recent-ok', rating: 7.2, year: 2024, genre: 'Comedia', addedDay: 25, plot: 'p'),
        _m('no-poster', rating: 8.5, year: 2025, genre: 'Drama', addedDay: 2, poster: null),
        _m('unrated', year: 2026, genre: 'Drama', addedDay: 30),
      ],
      series: const [],
      live: const [],
    );
    expect(data.recentMovies.map((m) => m.id).take(3), ['unrated', 'recent-ok', 'new-hit']);
    // Well rated, fairly recent and with artwork: no 1972 classic, no posterless title
    expect(data.topMovies.map((m) => m.id), ['new-hit', 'recent-ok']);
    expect(data.newReleases.map((m) => m.id), ['unrated', 'new-hit']);
    expect(data.movieGenres.first, 'Drama'); // most common first
    expect(data.moviesIn('Comedia').single.id, 'recent-ok');
    expect(data.featuredMovies.map((m) => m.id), ['recent-ok', 'new-hit']); // rated, with plot and poster
  });

  test('a genre written several ways is one chip, as most write it, and its row has them all', () {
    final data = CatalogData(
      live: const [],
      movies: const [
        Movie(id: '1', name: 'A', genre: 'Acción'),
        Movie(id: '2', name: 'B', genre: 'Accion, Drama'),
        Movie(id: '3', name: 'C', genre: 'ACCIÓN'),
        Movie(id: '4', name: 'D', genre: 'Acción'),
      ],
      series: const [],
    );
    expect(data.movieGenres, ['Acción', 'Drama']);
    expect(data.moviesIn('Acción').map((m) => m.id).toSet(), {'1', '2', '3', '4'});
  });

  test('a genre row lists a title once, newest first, past the genres shown too', () {
    final data = CatalogData(
      live: const [],
      movies: [
        for (var i = 0; i < CatalogData.genresShown + 1; i++)
          for (var n = 0; n < CatalogData.genresShown + 1 - i; n++) _m('g$i-$n', genre: 'Genre $i', addedDay: 1 + n),
        _m('twice', genre: 'Drama, drama / Genre 0', addedDay: 30),
        _m('older', genre: 'Drama', addedDay: 2),
      ],
      series: const [],
    );
    expect(data.moviesIn('DRAMA').map((m) => m.id), ['twice', 'older']);
    expect(data.moviesIn('Genre 0').first.id, 'twice');
    expect(data.moviesIn('Genre 0').map((m) => m.id).toSet(), hasLength(CatalogData.genresShown + 2));
    final rare = 'Genre ${CatalogData.genresShown}';
    expect(data.movieGenres.indexOf(rare), greaterThanOrEqualTo(CatalogData.genresShown));
    expect(data.moviesIn(rare).map((m) => m.id), ['g${CatalogData.genresShown}-0']);
    expect(identical(data.moviesIn('Genre 1'), data.moviesIn('genre 1')), isTrue, reason: 'worked out once');
  });

  test('newest first, undated last; new releases by their release, else by when they were added', () {
    final data = CatalogData(
      now: _now,
      movies: [
        const Movie(id: 'undated', name: 'Undated', year: 2026, poster: 'p'),
        Movie(id: 'old', name: 'Old', added: DateTime(2026, 1, 2), year: 2026, poster: 'p'),
        Movie(id: 'utc', name: 'Utc', added: DateTime.utc(2026, 3, 4), year: 2026, poster: 'p'),
        Movie.fromJson({'stream_id': 'json', 'name': 'Json', 'added': 1772000000, 'year': 2026, 'stream_icon': 'p'}),
        Movie(
          id: 'released',
          name: 'Released',
          added: DateTime(2025, 1, 1),
          releaseDate: DateTime(2026, 9, 1),
          year: 2026,
          poster: 'p',
        ),
      ],
      series: [
        const Series(id: 's-undated', name: 'A'),
        Series.fromJson({'series_id': 's-json', 'name': 'B', 'last_modified': 1772000000}),
        Series(id: 's-new', name: 'C', updated: DateTime(2026, 6, 1)),
      ],
      live: const [],
    );
    // 1772000000 is 25 February 2026
    expect([for (final m in data.recentMovies) m.id], ['utc', 'json', 'old', 'released', 'undated']);
    expect([for (final m in data.newReleases) m.id], ['released', 'utc', 'json', 'old', 'undated']);
    expect([for (final s in data.recentSeries) s.id], ['s-new', 's-json', 's-undated']);
  });

  test('versions: one or several, the catalog\'s own, for its movies and for copies of them', () {
    final data = CatalogData(
      now: _now,
      movies: [
        _m('heat', year: 1995),
        _m('dune', year: 2021),
        Movie(id: 'heat-4k', name: 'Movie heat [4K]', year: 1995),
        Movie(id: 'heat-hd', name: 'MOVIE HEAT', year: 1995),
      ],
      series: const [
        Series(id: 'dark', name: 'Dark (2017)'),
        Series(id: 'dark-4k', name: 'Dark [4K] (2017)'),
      ],
      live: const [],
    );
    final heat = data.movies[0], dune = data.movies[1];
    expect([for (final m in data.versionsOf(heat)) m.id], ['heat', 'heat-4k', 'heat-hd']);
    expect(data.versionsOf(data.movies[3]), same(data.versionsOf(heat)), reason: 'one list for the title');
    expect(data.versionsOf(dune).single, same(dune));
    final copy = dune.withIds('1~dune', null);
    expect(data.keyOf(copy), data.keyOf(dune));
    expect(data.versionsOf(copy).single, same(dune), reason: "a copy finds the catalog's own");
    expect([for (final m in data.versionsOf(heat.withIds('x', null))) m.id], ['heat', 'heat-4k', 'heat-hd']);
    final other = _m('not-here', year: 2001);
    expect(data.versionsOf(other).single, same(other), reason: 'a title the catalog does not have');
    expect([for (final s in data.seriesVersionsOf(data.series[1])) s.id], ['dark', 'dark-4k']);
    expect(data.seriesVersionsOf(const Series(id: 'x', name: 'Lost')).single.id, 'x');
    expect([for (final m in oneOfEachTitle(data.movies.reversed, data)) m.id], ['heat-hd', 'dune']);
  });

  test('version keys worked out apart are the same as those worked out by the catalog', () async {
    final movies = [for (var i = 0; i < 1500; i++) _m('$i', year: 1990 + i % 7)];
    final series = [for (var i = 0; i < 600; i++) Series(id: '$i', name: 'Show ${i % 40}', year: 2000 + i % 3)];
    final source = _Lists(movies, series);
    final loaded = await Catalog(source).load(); // over 2000 titles: worked out off the UI thread
    final here = CatalogData(movies: movies, series: series, live: const []);
    expect([for (final m in movies) loaded.keyOf(m)], [for (final m in movies) here.keyOf(m)]);
    expect([for (final s in series) loaded.keyOf(s)], [for (final s in series) here.keyOf(s)]);
    expect(loaded.recentSeries.length, 120, reason: '40 names, 3 years each');
  });

  test('more like this shares the main genre and excludes the title itself', () {
    final a = _m('a', rating: 7, genre: 'Terror, Misterio');
    final data = CatalogData(
      now: _now,
      movies: [
        a,
        _m('b', rating: 6, genre: 'Terror'),
        _m('c', rating: 9, genre: 'Misterio, Terror'),
        _m('d', rating: 8, genre: 'Comedia'),
      ],
      series: const [],
      live: const [],
    );
    expect(data.similarMovies(a).map((m) => m.id), ['c', 'b']);
  });

  test("a copy of a movie (its page's full record, a library entry with no year) finds its versions", () {
    final heat = _m('heat', year: 1995, genre: 'Crime');
    final data = CatalogData(
      now: _now,
      movies: [
        heat,
        Movie(id: 'heat-4k', name: 'Movie heat [4K]', year: 1995, genre: 'Crime'),
        _m('ronin', genre: 'Crime'),
      ],
      series: const [],
      live: const [],
    );
    final fromLibrary = MediaRef.movie(heat).toMovie(); // no year
    expect([for (final m in data.versionsOf(fromLibrary)) m.id], ['heat', 'heat-4k']);
    final detailed = heat.withDetail(Movie(id: 'heat', name: heat.name, year: 1996, plot: 'L.A.'));
    expect([for (final m in data.versionsOf(detailed)) m.id], ['heat', 'heat-4k']);
    expect(data.similarMovies(detailed).map((m) => m.id), ['ronin'], reason: 'not itself nor its versions');
  });

  test('full movie record completes the listing entry', () {
    final listing = Movie.fromJson({
      'stream_id': 7,
      'name': 'Film',
      'rating': '0',
      'episode_run_time': '100',
      'container_extension': 'mkv',
    });
    final detail = Movie.fromJson({
      'backdrop_path': ['https://img/b.jpg'],
      'o_name': 'Original',
      'duration_secs': 6073,
      'country': 'Spain',
      'rating': 7.4,
      'bitrate': 6164,
      'source_size': 4679492726,
      'releasedate': '2026-11-04',
    });
    final m = listing.withDetail(detail);
    expect(m.backdrop, 'https://img/b.jpg');
    expect(m.originalName, 'Original');
    expect(m.duration, const Duration(seconds: 6073)); // the measured file wins over the listed runtime
    expect(m.rating, 7.4); // a "0" rating in the listing means unknown
    expect(m.releaseDate, DateTime(2026, 11, 4));
    expect(m.extension, 'mkv');
  });
}
