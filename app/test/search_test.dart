// Search over a playlist: forgiving the way people type, best matches first, and the guide.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/matching.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/search.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<String> _names(List<List<Movie>> movies) => [for (final g in movies) g.first.name];
List<String> _seriesNames(List<List<Series>> series) => [for (final g in series) g.first.name];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final data = CatalogData(
    live: const [
      LiveChannel(id: '1', name: 'ES | ESPN 2 FHD', epgId: 'espn2.es'),
      LiveChannel(id: '2', name: 'ES | Movistar Liga de Campeones', epgId: 'mlc.es'),
      LiveChannel(id: '3', name: 'ES | Cocina TV', epgId: 'cocina.es'),
    ],
    movies: const [
      Movie(id: '1', name: 'Spider-Man: No Way Home (2021) [4K]', year: 2021, rating: 8),
      Movie(id: '2', name: 'Spider-Man (2002)', year: 2002, rating: 7.4),
      Movie(id: '3', name: 'Spider-Man: Across the Spider-Verse', year: 2023, rating: 8.6),
      Movie(id: '4', name: 'El hombre que desafió al rey', year: 2025, rating: 7.3),
      Movie(id: '5', name: 'Los Spiderwick', year: 2008),
      Movie(id: '6', name: 'Acción mutante', year: 1993),
    ],
    series: const [
      Series(id: '1', name: 'Breaking Bad', year: 2008, rating: 9.5),
      Series(id: '2', name: 'Lupin III', year: 1971),
      Series(id: '3', name: 'Lupin', year: 2021, rating: 7.5),
    ],
  );

  late SearchIndex index;
  setUpAll(() async => index = await SearchIndex.of(data));

  test('words in any order, without accents, punctuation or the provider tags', () {
    expect(_names(index.search(SearchQuery('spider man')).movies), contains('Spider-Man (2002)'));
    expect(_names(index.search(SearchQuery('rey hombre')).movies), ['El hombre que desafió al rey']);
    expect(_names(index.search(SearchQuery('ACCION')).movies), ['Acción mutante']);
    expect(_names(index.search(SearchQuery('no way home 4k')).movies), [
      'Spider-Man: No Way Home (2021) [4K]',
    ], reason: 'tags count on neither side');
    expect(_names(index.search(SearchQuery('no way home')).movies), ['Spider-Man: No Way Home (2021) [4K]']);
  });

  test('a word cut short, and a slip of one letter in a longer word', () {
    expect(_seriesNames(index.search(SearchQuery('brea bad')).series), ['Breaking Bad']);
    expect(_seriesNames(index.search(SearchQuery('braking bad')).series), ['Breaking Bad']);
    expect(_names(index.search(SearchQuery('spidr')).movies), contains('Spider-Man (2002)'));
    expect(_names(index.search(SearchQuery('xyz')).movies), isEmpty);
    // Audio and language tags are not words, and short words take no slips: no ESPN in "ESP-AC3"
    expect(searchWords('Aeropuerto - ALTADEFINICION 1080p - ESP-AC3'), ['aeropuerto']);
    expect(_names(index.search(SearchQuery('espn')).movies), isEmpty);
    // Any script
    expect(searchWords('Ｂｌｏｏｄ 狼血 (1998)'), isNotEmpty);
    expect(searchWords('가능한 사랑'), ['가능한', '사랑']);
  });

  test('best matches first: the whole title, its start, then the rest; then the newest', () {
    expect(_seriesNames(index.search(SearchQuery('lupin')).series), ['Lupin', 'Lupin III']);
    final spider = _names(index.search(SearchQuery('spider-man')).movies);
    expect(spider.first, 'Spider-Man (2002)', reason: 'the very title');
    expect(
      spider.sublist(1, 3),
      unorderedEquals(['Spider-Man: Across the Spider-Verse', 'Spider-Man: No Way Home (2021) [4K]']),
    );
    expect(spider, isNot(contains('Los Spiderwick')), reason: 'no "man" in it');
  });

  test('a title the provider lists once per language or quality comes once, with its versions', () async {
    final versions = await SearchIndex.of(
      CatalogData(
        live: const [],
        movies: const [
          Movie(id: 'lat', name: 'Spider-Man (2002)', year: 2002, categoryId: 'latino'),
          Movie(id: 'esp', name: 'Spider-Man', year: 2002, categoryId: 'castellano'),
          Movie(id: '4k', name: 'Spider-Man (2002) [4K]', year: 2002, categoryId: 'uhd'),
          Movie(id: 'new', name: 'Spider-Man', year: 2026),
        ],
        series: const [],
      ),
    );
    final found = versions.search(SearchQuery('spider man')).movies;
    // The 2026 one is another film, and the newest goes first
    expect([for (final g in found) g.length], [1, 3]);
    expect([for (final m in found.last) m.id], unorderedEquals(['lat', 'esp', '4k']));
  });

  test('titles written alike are found alike, and one of only tags never is', () async {
    final alike = await SearchIndex.of(
      CatalogData(
        live: const [
          LiveChannel(id: '9', name: 'HD 4K'),
          LiveChannel(id: '10', name: 'Dark TV'),
        ],
        movies: const [
          Movie(id: 'a', name: 'Dark (2017)', year: 2017),
          Movie(id: 'b', name: 'DARK [4K]', year: 2017),
          Movie(id: 'c', name: 'Dark - Latino', year: 2017),
          Movie(id: 'd', name: '4K HD', year: 2017),
          Movie(id: 'e', name: 'Dark City', year: 1998),
        ],
        series: const [
          Series(id: 's', name: 'Dark', year: 2017),
          Series(id: 't', name: ''),
        ],
      ),
    );
    final dark = alike.search(SearchQuery('dark'));
    expect(
      [for (final g in dark.movies) g.map((m) => m.id).join()],
      ['abc', 'e'],
      reason: 'the language written out is a version',
    );
    expect([for (final g in dark.series) g.single.id], ['s']);
    expect([for (final c in dark.channels) c.id], ['10']);
    expect(alike.search(SearchQuery('dark city')).movies.single.single.id, 'e');
    expect(alike.search(SearchQuery('hd')).isEmpty, isTrue, reason: 'tags are not words');
  });

  test('one word for a split title, articles it lacks, numbers either way', () {
    int? score(String q, String title) => SearchQuery(q).score(searchWords(title));
    expect(score('spiderman', 'Spider-Man: No Way Home (2021)'), isNotNull);
    expect(score('xmen', 'X-Men: Apocalypse'), isNotNull);
    expect(score('the matrix', 'Matrix (1999)'), isNotNull);
    expect(score('el padrino', 'Padrino'), isNotNull);
    expect(score('the', 'Matrix'), isNull, reason: 'an article alone is no match');
    expect(score('rocky 2', 'Rocky II'), isNotNull);
    expect(score('rocky ii', 'Rocky 2'), isNotNull);
    expect(score('rocky 3', 'Rocky II'), isNull);
  });

  test('accents written apart, letters outside the table and other scripts read as words', () {
    const nfd = 'Acción';
    expect(searchWords(nfd), ['accion']);
    expect(versionKey(nfd, 2020), versionKey('Acción', 2020));
    expect(SearchQuery('nino').score(searchWords('Niño')), isNotNull);
    expect(searchWords('Søren Łódź Straße'), ['soren', 'lodz', 'strasse']);
    expect(searchWords('हिंदी फिल्म'), ['हिंदी', 'फिल्म']);
    expect(searchWords('Dual (2022)'), ['dual'], reason: 'a title of tags alone is its title');
  });

  test('what a channel aired and keeps is found to watch again, after what is on; not what it does not keep', () {
    final now = DateTime(2026, 11, 6, 20);
    EpgEntry show(String title, int startHour, int endHour) => EpgEntry(
      title: title,
      start: now.add(Duration(hours: startHour)),
      end: now.add(Duration(hours: endHour)),
    );
    const keeping = LiveChannel(id: 'k', name: 'Archive TV', epgId: 'k.tv', archiveDays: 2);
    const forgetting = LiveChannel(id: 'f', name: 'Live only', epgId: 'f.tv');
    const later = LiveChannel(id: 'l', name: 'Later TV', epgId: 'l.tv');
    final guide = EpgGuide({
      'k.tv': [show('Mundial: Argentina - Francia', -30, -28)],
      'f.tv': [show('Mundial: resumen', -3, -2)],
      'l.tv': [show('Mundial: previa', 1, 2)],
    });
    final found = searchGuide(guide, const [keeping, forgetting, later], SearchQuery('mundial'), now: now);
    expect([for (final f in found) f.channel.id], ['l', 'k'], reason: 'coming first, then aired and kept');
    expect(found.last.programme.end.isBefore(now), isTrue);
  });

  test('what the guide says is on, now first, one per channel', () {
    final now = DateTime(2026, 11, 6, 20);
    EpgEntry show(String title, int startHour, int endHour) => EpgEntry(
      title: title,
      start: now.add(Duration(hours: startHour)),
      end: now.add(Duration(hours: endHour)),
    );
    final guide = EpgGuide({
      'espn2.es': [show('Champions League: Real Madrid - Milan', 2, 4)],
      'mlc.es': [show('Liga de Campeones: Bayern - PSG', -1, 1), show('Champions: resumen', 1, 2)],
      'cocina.es': [show('Recetas con champiñones', 0, 1)],
    });
    final found = searchGuide(guide, data.live, SearchQuery('champions'), now: now);
    expect([for (final f in found) f.channel.id], ['2', '1'], reason: 'on now first; not a word that only contains it');
    expect(found.first.programme.title, 'Champions: resumen');
    expect(
      searchGuide(guide, data.live, SearchQuery('champions'), now: now, ahead: const Duration(minutes: 30)),
      isEmpty,
    );
    // Inside a word is no match in the guide: "pion" is not "Champions", "ana" not "mañana"
    expect(searchGuide(guide, data.live, SearchQuery('pion'), now: now), isEmpty);
    expect(
      searchGuide(guide, data.live, SearchQuery('champ'), now: now),
      hasLength(3),
      reason: 'the start of a word is',
    );
  });

  test('channels tied by the match go by their number, those with none by name', () async {
    final many = CatalogData(
      live: [
        for (var n = 29; n >= 1; n--) LiveChannel(id: '${100 - n}', name: 'ESPN $n', number: n),
        const LiveChannel(id: '500', name: 'ESPN B'),
        const LiveChannel(id: '501', name: 'ESPN A'),
      ],
      movies: const [],
      series: const [],
    );
    final found = (await SearchIndex.of(many)).search(SearchQuery('espn')).channels;
    expect(found.take(3).map((c) => c.name), ['ESPN 1', 'ESPN 2', 'ESPN 3']);
    expect(found.reversed.take(2).map((c) => c.name), ['ESPN B', 'ESPN A']);
  });

  test('recent searches: per profile, newest first, the same search once', () async {
    SharedPreferences.setMockInitialValues({});
    await RecentSearches.add('ana', 'lupin');
    await RecentSearches.add('ana', 'Breaking Bad');
    await RecentSearches.add('ana', 'LUPIN ');
    await RecentSearches.add('ana', 'x');
    expect(await RecentSearches.of('ana'), ['LUPIN', 'Breaking Bad']);
    expect(await RecentSearches.of('bea'), isEmpty);
    for (var i = 0; i < 12; i++) {
      await RecentSearches.add('ana', 'search $i');
    }
    expect(await RecentSearches.of('ana'), hasLength(RecentSearches.max));
  });
}
