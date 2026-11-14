// Several providers as one list: catalogs together, each title once with every copy, each
// stream asked of the provider it comes from, and one provider down leaves the rest working.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/combined.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/source.dart';

/// A provider with a few lists, or one that cannot be reached.
class _Fake implements ContentSource {
  _Fake(
    this.host, {
    this.movieList = const [],
    this.seriesList = const [],
    this.down = false,
    this.live = const [],
    EpgGuide? epg,
  }) : epg = epg ?? EpgGuide.empty;

  final String host;
  final List<LiveChannel> live;
  final EpgGuide epg;
  final List<Movie> movieList;
  final List<Series> seriesList;
  final bool down;

  Future<List<T>> _or<T>(List<T> v) async => down ? throw const SourceException(SourceError.unreachable) : v;

  @override
  bool hideAdult = false;
  @override
  Future<List<Category>> liveCategories() => _or(const []);
  @override
  Future<List<LiveChannel>> liveChannels([String? categoryId]) => _or(live);
  @override
  Future<List<Category>> movieCategories() => _or(const [Category(id: '7', name: 'Estrenos')]);
  @override
  Future<List<Movie>> movies([String? categoryId]) => _or([
    for (final m in movieList)
      if (categoryId == null || m.categoryId == categoryId) m,
  ]);
  @override
  Future<List<Category>> seriesCategories() => _or(const []);
  @override
  Future<List<Series>> series([String? categoryId]) => _or(seriesList);
  @override
  Future<SeriesDetail> seriesDetail(Series s) async => SeriesDetail(
    series: s,
    seasons: {
      1: [Episode(id: 'e-${s.id}', season: 1, number: 1, title: 'Pilot', extension: 'mkv')],
    },
  );
  @override
  Future<List<EpgEntry>> shortEpg(LiveChannel c, {int limit = 4}) async => const [];
  @override
  Future<EpgGuide> guide() async => epg;
  @override
  String liveUrl(LiveChannel c) => 'http://$host/live/${c.id}.ts';
  @override
  String movieUrl(Movie m) => 'http://$host/movie/${m.id}.${m.extension}';
  @override
  String episodeUrl(Episode e) => 'http://$host/series/${e.id}.${e.extension}';
  @override
  String? catchupUrl(LiveChannel c, DateTime start, Duration duration) => null;
  @override
  Map<String, String> headersFor(String url) => const {};
}

void main() {
  final a = _Fake(
    'a.test',
    movieList: const [
      Movie(id: '10', name: 'Heat', year: 1995, categoryId: '7'),
      Movie(id: '11', name: 'Only on A', year: 2020, categoryId: '7'),
    ],
    seriesList: const [Series(id: '5', name: 'Lupin', year: 2021)],
  );
  final b = _Fake(
    'b.test',
    movieList: const [Movie(id: '99', name: 'Heat (1995) [4K]', year: 1995, categoryId: '7')],
  );

  test("a guide id that is only a number is each provider's own; one in words is shared", () async {
    final now = DateTime.now();
    EpgGuide guide(String news, String bbc) => EpgGuide({
      '101': [
        EpgEntry(title: news, start: now.subtract(const Duration(minutes: 5)), end: now.add(const Duration(hours: 1))),
      ],
      'bbc1.uk': [
        EpgEntry(title: bbc, start: now.subtract(const Duration(minutes: 5)), end: now.add(const Duration(hours: 1))),
      ],
    });
    final one = _Fake(
      'one.test',
      live: const [
        LiveChannel(id: '1', name: 'News', epgId: '101'),
        LiveChannel(id: '2', name: 'BBC', epgId: 'bbc1.uk'),
      ],
      epg: guide('News here', 'BBC News'),
    );
    final two = _Fake(
      'two.test',
      live: const [LiveChannel(id: '1', name: 'Sport', epgId: '101')],
      epg: guide('Football', 'BBC two'),
    );
    final c = CombinedSource([(name: 'One', source: one), (name: 'Two', source: two)]);
    final g = await c.guide();
    final titles = {for (final ch in await c.liveChannels()) ch.name: g.nowOn(ch.epgId)?.title};
    expect(titles, {'News': 'News here', 'BBC': 'BBC News', 'Sport': 'Football'});
  });

  test('catalogs together, named by provider, each stream asked of its own provider', () async {
    final c = CombinedSource([(name: 'A', source: a), (name: 'B', source: b)]);
    final movies = await c.movies();
    expect([for (final m in movies) m.id], ['0~10', '0~11', '1~99']);
    expect([for (final cat in await c.movieCategories()) cat.name], ['A · Estrenos', 'B · Estrenos']);
    // The provider's own name for it, cleaned up as everywhere else
    expect(displayCategoryName('🎞️ VOD | MARVEL - DC'), 'Marvel - DC');
    expect(c.movieUrl(movies[0]), 'http://a.test/movie/10.mp4');
    expect(c.movieUrl(movies[2]), 'http://b.test/movie/99.mp4');
    // A category of one of them, from that one only
    expect([for (final m in await c.movies('1~7')) m.id], ['1~99']);
  });

  test('a title both have: one card, two copies, and playing it brings the other along', () async {
    final c = CombinedSource([(name: 'A', source: a), (name: 'B', source: b)]);
    final data = await Catalog(c).load();
    expect([for (final m in data.recentMovies) m.name], unorderedEquals(['Heat', 'Only on A']));
    final heat = data.movies.firstWhere((m) => m.id == '0~10');
    expect(
      [for (final v in data.versionsOf(heat)) c.movieUrl(v)],
      ['http://a.test/movie/10.mp4', 'http://b.test/movie/99.mp4'],
    );
  });

  test('series and their episodes go to their provider', () async {
    final c = CombinedSource([(name: 'A', source: a), (name: 'B', source: b)]);
    final lupin = (await c.series()).single;
    final d = await c.seriesDetail(lupin);
    expect(d.series.id, '0~5');
    final pilot = d.seasons[1]!.single;
    expect(pilot.id, '0~e-5');
    expect(c.episodeUrl(pilot), 'http://a.test/series/e-5.mkv');
  });

  test('one provider down leaves the others working; all down is an error', () async {
    final down = _Fake('down.test', down: true);
    final c = CombinedSource([(name: 'Down', source: down), (name: 'B', source: b)]);
    expect([for (final m in await c.movies()) m.id], ['1~99']);
    expect(CombinedSource([(name: 'Down', source: down)]).movies(), throwsA(isA<SourceException>()));
    expect(() => c.movieUrl(const Movie(id: '7~1', name: 'x')), throwsA(isA<SourceException>()));
  });

  test('a provider missing keeps the places of the others, and says it failed', () async {
    final down = _Fake('down.test', down: true);
    // A deleted between: what was the third is still the third
    final c = CombinedSource([(name: 'A', source: a), null, (name: 'B', source: b)]);
    expect([for (final m in await c.movies()) m.id], ['0~10', '0~11', '2~99']);
    expect(c.movieUrl(const Movie(id: '2~99', name: 'x')), 'http://b.test/movie/99.mp4');
    expect(() => c.movieUrl(const Movie(id: '1~99', name: 'x')), throwsA(isA<SourceException>()));
    expect(c.failed, isEmpty);
    final d = CombinedSource([(name: 'Down', source: down), (name: 'B', source: b)]);
    await d.movies();
    expect(d.failed, {'Down'});
  });

  test('a combined playlist keeps the playlists it joins, in order', () {
    final p = Playlist.combine(name: 'Todo', members: ['b', 'a']);
    final back = Playlist.fromJson(p.toJson());
    expect(back.type, PlaylistType.combined);
    expect(back.members, ['b', 'a']);
    expect(back.sameAccount(p), isTrue);
    expect(back.sameAccount(Playlist.combine(name: 'Todo', members: ['a', 'b'])), isFalse);
  });
}
