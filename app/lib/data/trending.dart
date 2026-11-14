import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'matching.dart';
import 'models.dart';

/// A movie or series trending this week on TMDB.
class Trend {
  const Trend({
    required this.series,
    required this.tmdbId,
    required this.title,
    required this.originalTitle,
    this.year,
    this.rating,
    this.poster,
    this.backdrop,
    this.overview,
    this.otherTitles = const [],
    this.mature,
    this.kidsSafe,
  });

  factory Trend.fromJson(Map<String, dynamic> j) => Trend(
    series: j['series'] == true,
    tmdbId: j['tmdbId'] as int,
    title: j['title'] as String,
    originalTitle: j['originalTitle'] as String,
    year: j['year'] as int?,
    rating: (j['rating'] as num?)?.toDouble(),
    poster: j['poster'] as String?,
    backdrop: j['backdrop'] as String?,
    overview: j['overview'] as String?,
    mature: j['mature'] as bool?,
    kidsSafe: j['kidsSafe'] as bool?,
  );

  /// [this] also known by [titles], such as its name in the language of a provider's catalog.
  Trend alsoKnownAs(Iterable<String> titles) => Trend(
    series: series,
    tmdbId: tmdbId,
    title: title,
    originalTitle: originalTitle,
    year: year,
    rating: rating,
    poster: poster,
    backdrop: backdrop,
    overview: overview,
    otherTitles: [
      for (final t in {...otherTitles, ...titles})
        if (t != title && t != originalTitle) t,
    ],
    mature: mature,
    kidsSafe: kidsSafe,
  );

  /// [this] with its age rating.
  Trend rated({required bool? mature, required bool? kidsSafe}) => Trend(
    series: series,
    tmdbId: tmdbId,
    title: title,
    originalTitle: originalTitle,
    year: year,
    rating: rating,
    poster: poster,
    backdrop: backdrop,
    overview: overview,
    otherTitles: otherTitles,
    mature: mature,
    kidsSafe: kidsSafe,
  );

  /// Where it is kept apart from the other trends: movies and series have ids of their own.
  String get key => '${series ? 'tv' : 'movie'}/$tmdbId';

  /// From a TMDB result of /trending/movie or /trending/tv.
  factory Trend.fromTmdb(Map<String, dynamic> r, {required bool series}) {
    String? image(String size, Object? path) =>
        path is String && path.startsWith('/') ? 'https://image.tmdb.org/t/p/$size$path' : null;
    final title = (series ? r['name'] : r['title']) as String? ?? '';
    return Trend(
      series: series,
      tmdbId: r['id'] as int,
      title: title,
      originalTitle: (series ? r['original_name'] : r['original_title']) as String? ?? title,
      year: int.tryParse(((series ? r['first_air_date'] : r['release_date']) as String? ?? '').split('-').first),
      rating: (r['vote_average'] as num?)?.toDouble(),
      // Sized for a poster wall and for a full screen
      poster: image('w342', r['poster_path']),
      backdrop: image('w1280', r['backdrop_path']),
      overview: switch (r['overview']) {
        final String o when o.trim().isNotEmpty => o.trim(),
        _ => null,
      },
    );
  }

  final bool series; // else a movie
  final int tmdbId;
  final String title, originalTitle; // title in the app's language
  final int? year;
  final double? rating; // out of 10
  final String? poster, backdrop;
  final String? overview; // in the app's language, when TMDB has it

  /// Its title in other languages, to find it in a catalog in another language than the app's.
  final List<String> otherTitles;

  /// Rated for adults only (R, NC-17, TV-MA, 18): never on the screens the whole family sees,
  /// nor in kids profiles. Null when TMDB could not tell: treated as if it were, and asked again.
  final bool? mature;

  /// Rated for children (G, PG, TV-Y, TV-Y7, TV-G, TV-PG): all that a kids profile is offered.
  final bool? kidsSafe;

  Map<String, dynamic> toJson() => {
    'series': series,
    'tmdbId': tmdbId,
    'title': title,
    'originalTitle': originalTitle,
    'year': year,
    'rating': rating,
    'poster': poster,
    'backdrop': backdrop,
    'overview': overview,
    if (mature != null) 'mature': mature,
    if (kidsSafe != null) 'kidsSafe': kidsSafe,
  };
}

/// What is trending this week in movies and series, from TMDB, so the app shows something worth
/// watching from its first start, before any playlist. Asked at most once a day and kept on the
/// device; nothing about the user goes with the request but the language.
///
/// Needs a TMDB key at build time (`--dart-define=TMDB_API_KEY=...`); without one, the app uses
/// the provider's posters only ([PosterWall]).
class Trending {
  Trending._();

  static const apiKey = String.fromEnvironment('TMDB_API_KEY');

  /// Movies and series in turns, most trending first. Empty without a key or before the first answer.
  static final items = ValueNotifier<List<Trend>>(const []);

  /// The language TMDB was last asked in, for the trailers too.
  static var language = 'en-US';

  static const _prefKey = 'trending', _altKey = 'trending.otherTitles';

  /// The trends' titles in the language of the catalog opened last, by [Trend.key].
  static Map<String, String> _otherTitles = const {};

  static List<Trend> _withOtherTitles(List<Trend> trends) => [
    for (final t in trends)
      if (_otherTitles[t.key] case final other?) t.alsoKnownAs([other]) else t,
  ];

  /// How many of a catalog's names [guessLanguage] reads.
  static const namesForLanguage = 5000;

  /// The language most of a catalog's [names] are in, by their small words ("el", "the", "der"...),
  /// as TMDB names it; null when it is not clear.
  static String? guessLanguage(Iterable<String> names) {
    const markers = {
      'es': {'el', 'los', 'las', 'del', 'y'},
      'en': {'the', 'of', 'and'},
      'pt': {'os', 'do', 'da', 'dos', 'das', 'uma'},
      'fr': {'le', 'les', 'des', 'du', 'et'},
      'de': {'der', 'die', 'das', 'und'},
      'it': {'il', 'gli', 'della', 'dei', 'delle'},
    };
    final counts = {for (final l in markers.keys) l: 0};
    for (final name in names.take(namesForLanguage)) {
      for (final w in looseTitle(name).split(' ')) {
        for (final MapEntry(key: l, value: words) in markers.entries) {
          if (words.contains(w)) counts[l] = counts[l]! + 1;
        }
      }
    }
    final ranked = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final (best, second) = (ranked[0], ranked[1]);
    return best.value >= 20 && best.value > second.value * 1.5 ? best.key : null;
  }

  /// Also asks for this week's trends in [catalogLanguage], the one a provider's catalog is in,
  /// when it is not the app's: their titles there are how the catalog names them. Once a day.
  static Future<void> alsoIn(String? catalogLanguage, {String key = apiKey, http.Client? client, DateTime? now}) async {
    if (key.isEmpty || catalogLanguage == null || language.split('-').first == catalogLanguage) return;
    now ??= DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(prefs.getString(_altKey) ?? '{}') as Map<String, dynamic>;
      final at = DateTime.tryParse(saved['at'] as String? ?? '');
      if (at != null && saved['language'] == catalogLanguage && _fresh(now.difference(at))) return;
    } on Object {
      // Asked again
    }
    final http.Client c = client ?? http.Client();
    try {
      Future<List<(String, String)>> page(String kind, int n) async {
        final res = await c
            .get(
              Uri.https('api.themoviedb.org', '/3/trending/$kind/week', {
                'api_key': key,
                'language': catalogLanguage,
                'page': '$n',
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) throw http.ClientException('TMDB ${res.statusCode}');
        return [
          for (final r in ((jsonDecode(res.body) as Map<String, dynamic>)['results'] as List).whereType<Map>())
            if ((r['title'] ?? r['name']) case final String title) ('$kind/${r['id']}', title),
        ];
      }

      final pages = await Future.wait([page('movie', 1), page('movie', 2), page('tv', 1), page('tv', 2)]);
      _otherTitles = {
        for (final list in pages)
          for (final (k, title) in list) k: title,
      };
      items.value = List.unmodifiable(_withOtherTitles(items.value));
      await prefs.setString(
        _altKey,
        jsonEncode({'at': now.toIso8601String(), 'language': catalogLanguage, 'titles': _otherTitles}),
      );
    } on Object catch (e) {
      debugPrint('Trending: ${e.runtimeType}'); // its message carries the address, and the key
    } finally {
      if (client == null) c.close();
    }
  }

  static const _maxAge = Duration(days: 1);

  /// Younger than [_maxAge], and not from the future: one saved while the clock was ahead would
  /// otherwise never be renewed.
  static bool _fresh(Duration age) => !age.isNegative && age < _maxAge;
  static const _horror = 27; // TMDB genre of movies: anyone in the family sees these screens. Series: matureSeries

  /// Reads what was fetched last time. Call once at startup, then [refresh].
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (saved == null) return;
    try {
      final j = jsonDecode(saved) as Map<String, dynamic>;
      language = j['language'] as String? ?? language;
      final alt = jsonDecode(prefs.getString(_altKey) ?? '{}') as Map<String, dynamic>;
      _otherTitles = {for (final e in ((alt['titles'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
      items.value = List.unmodifiable(
        _withOtherTitles([for (final t in j['items'] as List) Trend.fromJson(t as Map<String, dynamic>)]),
      );
    } on Object {
      // Fetched again
    }
  }

  /// Asks TMDB again when what is kept is a day old or in another [language] (such as "es-MX":
  /// titles differ between countries). Keeps the last answer when TMDB cannot be reached.
  static Future<void> refresh({
    required String language,
    String key = apiKey,
    http.Client? client,
    DateTime? now,
  }) async {
    if (key.isEmpty) return;
    Trending.language = language;
    now ??= DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(prefs.getString(_prefKey) ?? '{}') as Map<String, dynamic>;
      final at = DateTime.tryParse(saved['at'] as String? ?? '');
      if (at != null && saved['language'] == language && _fresh(now.difference(at)) && items.value.isNotEmpty) {
        return;
      }
    } on Object {
      // Asked again
    }
    final http.Client c = client ?? http.Client();
    try {
      Future<List<Map<String, dynamic>>> page(String kind, int n) async {
        final res = await c
            .get(
              Uri.https('api.themoviedb.org', '/3/trending/$kind/week', {
                'api_key': key,
                'language': language,
                'page': '$n',
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) throw http.ClientException('TMDB ${res.statusCode}');
        return [
          for (final r in (jsonDecode(res.body) as Map<String, dynamic>)['results'] as List) r as Map<String, dynamic>,
        ];
      }

      // Two pages of each: enough to find a good share of them in a provider's catalog
      final r = await Future.wait([page('movie', 1), page('movie', 2), page('tv', 1), page('tv', 2)]);
      final unrated = pick(movies: [...r[0], ...r[1]], series: [...r[2], ...r[3]]);
      if (unrated.isEmpty) return;
      final picked = await _rate(c, key, unrated);
      items.value = List.unmodifiable(_withOtherTitles(picked));
      await prefs.setString(_prefKey, jsonEncode({'at': now.toIso8601String(), 'language': language, 'items': picked}));
    } on Object catch (e) {
      debugPrint('Trending: ${e.runtimeType}'); // its message carries the address, and the key
    } finally {
      if (client == null) c.close();
    }
  }

  /// [trends] with their age rating: from what was known already, else asked of TMDB, ten at a time.
  /// One that cannot be asked stays unrated, shown to nobody who needs a rating, and is asked next time.
  static Future<List<Trend>> _rate(http.Client c, String key, List<Trend> trends) async {
    final known = {
      for (final t in items.value)
        if (t.mature != null && t.kidsSafe != null) t.key: t,
    };
    Future<Trend> rate(Trend t) async {
      if (known[t.key] case final k?) return t.rated(mature: k.mature, kidsSafe: k.kidsSafe);
      final path = t.series ? '/3/tv/${t.tmdbId}' : '/3/movie/${t.tmdbId}/release_dates';
      try {
        final res = await c
            .get(
              Uri.https('api.themoviedb.org', path, {
                'api_key': key,
                if (t.series) 'append_to_response': 'content_ratings,keywords',
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) return t;
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final mature = t.series ? matureSeries(j) : matureRating(j['results'] as List);
        final results = t.series ? _part(j, 'content_ratings') : j['results'] as List;
        return t.rated(mature: mature, kidsSafe: mature != true && kidsSafeRating(results));
      } on Object {
        return t;
      }
    }

    final rated = <Trend>[];
    for (var i = 0; i < trends.length; i += 10) {
      rated.addAll(await Future.wait([for (final t in trends.skip(i).take(10)) rate(t)]));
    }
    return rated;
  }

  /// Whether TMDB's ratings of a title (content_ratings of a series, release_dates of a movie) say
  /// adults only: R, NC-17 or TV-MA in the US; without a real US rating (none, NR or UR), 18 or more
  /// anywhere: Korea's top one is 19, Singapore's R21. Null when no country has a real one.
  @visibleForTesting
  static bool? matureRating(List<dynamic> results) {
    final ratings = _ratings(results);
    if (ratings.values.every((list) => list.isEmpty)) return null;
    if (ratings['US'] case final us? when us.isNotEmpty) return us.any(const {'R', 'NC-17', 'TV-MA'}.contains);
    return ratings.values.any((list) => list.any((r) => r.contains('18') || r == '19' || r.contains('21')));
  }

  /// Whether the US ratings of a title are all for children; other countries' scales say too little.
  @visibleForTesting
  static bool kidsSafeRating(List<dynamic> results) {
    final us = _ratings(results)['US'] ?? const [];
    return us.isNotEmpty && us.every(const {'G', 'PG', 'TV-Y', 'TV-Y7', 'TV-G', 'TV-PG'}.contains);
  }

  /// Each country's real ratings: an empty one, NR and UR say nothing.
  static Map<String, List<String>> _ratings(List<dynamic> results) => {
    for (final r in results.whereType<Map<String, dynamic>>())
      '${r['iso_3166_1']}': [
        for (final rating in [
          r['rating'],
          for (final d in (r['release_dates'] as List?) ?? const []) (d as Map)['certification'],
        ])
          if (rating is String && rating.isNotEmpty && rating != 'NR' && rating != 'UR') rating,
      ],
  };

  static List<dynamic> _part(Map<String, dynamic> details, String part) =>
      ((details[part] as Map?)?['results'] as List?) ?? const [];

  /// A series' details with its ratings and keywords: adults only by [matureRating], or horror,
  /// which only a keyword tells: TMDB has no such genre for series.
  @visibleForTesting
  static bool? matureSeries(Map<String, dynamic> details) {
    final horror = _part(details, 'keywords').any((k) => '${(k as Map)['name']}'.toLowerCase().contains('horror'));
    return horror ? true : matureRating(_part(details, 'content_ratings'));
  }

  /// TMDB results as the app shows them: with artwork, never adult content nor horror, movies and
  /// series in turns.
  @visibleForTesting
  static List<Trend> pick({required List<Map<String, dynamic>> movies, required List<Map<String, dynamic>> series}) {
    bool fit(Map<String, dynamic> r) =>
        r['adult'] != true &&
        !((r['genre_ids'] as List?) ?? const []).contains(_horror) &&
        r['poster_path'] is String &&
        r['backdrop_path'] is String;
    final m = movies.where(fit).map((r) => Trend.fromTmdb(r, series: false)).toList();
    final s = series.where(fit).map((r) => Trend.fromTmdb(r, series: true)).toList();
    final seen = <String>{};
    return [
      for (var i = 0; i < m.length || i < s.length; i++) ...[if (i < m.length) m[i], if (i < s.length) s[i]],
    ].where((t) => seen.add('${t.series}/${t.tmdbId}')).toList();
  }

  /// The trends [data], a playlist's catalog, has, with the [Movie] or [Series] that plays each:
  /// what can be watched right away. By TMDB id
  /// where the provider gives it, else by title (in the app's language or the original one) and
  /// year, give or take one: providers date some titles by their premiere, others by their release.
  static List<({Trend trend, Object item})> available(CatalogData data, [List<Trend>? trends, bool forKids = false]) {
    // No trends (no TMDB key, offline): nothing to look for, and no index of the whole catalog to
    // build on the UI's thread for it
    final wanted = trends ?? items.value;
    if (wanted.isEmpty) return const [];
    final index = _indexes[data] ??= _Index(data);
    final found = <({Trend trend, Object item})>[];
    final seen = <Object>{};
    for (final t in wanted) {
      if (forKids && t.kidsSafe != true) continue;
      final hit = t.series ? index.series(t) : index.movie(t);
      if (hit != null && seen.add(hit)) found.add((trend: t, item: hit));
    }
    return found;
  }

  static final _indexes = Expando<_Index>();

  /// The movies ([series] false) or series of [available], most trending first.
  static List<Object> ofKind(CatalogData data, {required bool series, List<Trend>? trends, bool forKids = false}) => [
    for (final (:trend, :item) in available(data, trends, forKids))
      if (trend.series == series) item,
  ];

  static final _trailers = <String, Future<String?>>{};

  /// The YouTube id of [t]'s trailer: in the app's language when there is one, else in English.
  /// Asked once per session; null when there is none or TMDB cannot be reached.
  static Future<String?> trailer(Trend t, {String key = apiKey, http.Client? client}) =>
      findTrailer(series: t.series, tmdbId: '${t.tmdbId}', title: t.title, key: key, client: client);

  /// The YouTube id of the trailer of a provider's movie or series: by its TMDB id when the
  /// provider gives it, else found on TMDB by [title] (or [originalTitle]) and [year]. Only a
  /// search result with the same title counts, so a namesake does not lend its trailer. Asked
  /// once per session; null when there is none or TMDB cannot be reached.
  static Future<String?> findTrailer({
    required bool series,
    String? tmdbId,
    required String title,
    String? originalTitle,
    int? year,
    String key = apiKey,
    http.Client? client,
  }) {
    final id = tmdbId != null ? '$series/$tmdbId' : '$series/${looseTitle(title)}/${year ?? ''}';
    return _trailers[id] ??= () async {
      if (key.isEmpty) return null;
      final http.Client c = client ?? http.Client();
      Future<Map<String, dynamic>> get(String path, Map<String, String> query) async {
        final res = await c
            .get(Uri.https('api.themoviedb.org', '/3/$path', {'api_key': key, ...query}))
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) throw http.ClientException('TMDB ${res.statusCode}');
        return jsonDecode(res.body) as Map<String, dynamic>;
      }

      final kind = series ? 'tv' : 'movie';
      try {
        var found = tmdbId;
        for (final name in {title, ?originalTitle}) {
          if (found != null) break;
          final wanted = bareTitle(name);
          if (wanted.isEmpty) continue;
          // TMDB's year is exact; when the provider's is one off, asked again without it, and only
          // a result a year apart at most counts
          for (final withYear in [if (year != null) true, false]) {
            if (found != null) break;
            final results =
                (await get('search/$kind', {
                      'query': wanted,
                      'language': language,
                      if (withYear) series ? 'first_air_date_year' : 'year': '$year',
                    }))['results']
                    as List;
            found = results
                .whereType<Map<String, dynamic>>()
                .where(
                  (r) => [
                    r[series ? 'name' : 'title'],
                    r[series ? 'original_name' : 'original_title'],
                  ].whereType<String>().any((t) => bareTitle(t) == wanted),
                )
                .where((r) {
                  if (withYear || year == null) return true;
                  final y = int.tryParse('${r[series ? 'first_air_date' : 'release_date'] ?? ''}'.split('-').first);
                  return y != null && (y - year).abs() <= 1;
                })
                .map((r) => '${r['id']}')
                .firstOrNull;
          }
        }
        if (found == null) return null;
        for (final lang in {language, 'en-US'}) {
          final videos = (await get('$kind/$found/videos', {'language': lang}))['results'] as List;
          if (pickTrailer(videos) case final trailer?) return trailer;
        }
        return null;
      } on Object catch (e) {
        debugPrint('Trailer: ${e.runtimeType}'); // not its text: the address in it has the TMDB key
        // ignore: unawaited_futures, the map's entry taken out, not a call
        _trailers.remove(id); // asked again next time
        return null;
      } finally {
        if (client == null) c.close();
      }
    }();
  }

  /// The best of TMDB's videos for a title: a trailer before a teaser, official ones first. Only
  /// YouTube, the one site the app can show.
  @visibleForTesting
  static String? pickTrailer(List<dynamic> videos) {
    int? rank(Map<String, dynamic> v) {
      if (v['site'] != 'YouTube' || v['key'] is! String) return null;
      final type = switch (v['type']) {
        'Trailer' => 0,
        'Teaser' => 2,
        _ => null,
      };
      return type == null ? null : type + (v['official'] == true ? 0 : 1);
    }

    // TMDB's order among equals
    final ranked = [
      for (final (i, v) in videos.whereType<Map<String, dynamic>>().indexed)
        if (rank(v) case final r?) (r * 1000 + i, v['key'] as String),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return ranked.firstOrNull?.$2;
  }
}

/// A catalog's movies and series by TMDB id and by loose title, built once per catalog. The titles
/// come from the keys the catalog worked out off the UI's thread when it loaded ([bareTitle] is
/// the words of [versionKey]), not worked out again here for every name.
class _Index {
  _Index(CatalogData data) {
    final titles = <String, String>{}; // a title's versions share one
    String bare(Object x) {
      final key = data.keyOf(x);
      return titles[key] ??= key.substring(0, key.lastIndexOf('|'));
    }

    for (final m in data.movies) {
      if (m.tmdbId != null) _moviesById[m.tmdbId!] = m;
      _add(_moviesByTitle, bare(m), m);
    }
    for (final s in data.series) {
      if (s.tmdbId != null) _seriesById[s.tmdbId!] = s;
      _add(_seriesByTitle, bare(s), s);
    }
    _moviesByTitle.updateAll(_fixed<Movie>);
    _seriesByTitle.updateAll(_fixed<Series>);
  }

  final _moviesById = <String, Movie>{}, _seriesById = <String, Series>{};

  // By title, the one movie (or series) of that title, as most have only one, or the list of them
  final _moviesByTitle = <String, Object>{}, _seriesByTitle = <String, Object>{};

  static void _add<T extends Object>(Map<String, Object> byTitle, String title, T x) {
    switch (byTitle[title]) {
      case null:
        byTitle[title] = x;
      case final List<T> several:
        several.add(x);
      case final one:
        byTitle[title] = <T>[one as T, x];
    }
  }

  static Object _fixed<T>(String _, Object v) => v is List<T> ? List<T>.of(v, growable: false) : v;

  Movie? movie(Trend t) =>
      _moviesById['${t.tmdbId}'] ?? _byTitle(t, _moviesByTitle, (m) => m.year ?? yearInTitle(m.name));

  Series? series(Trend t) =>
      _seriesById['${t.tmdbId}'] ?? _byTitle(t, _seriesByTitle, (s) => s.year ?? yearInTitle(s.name));

  static T? _byTitle<T>(Trend t, Map<String, Object> byTitle, int? Function(T) year) {
    // A copy with no year may be it, but one with the right year is: that one first
    T? undated;
    for (final title in {
      // As the catalog's: what a provider adds to a name ("- ESP-AC3") does not count
      bareTitle(t.title),
      bareTitle(t.originalTitle),
      for (final o in t.otherTitles) bareTitle(o),
    }) {
      if (title.isEmpty) continue;
      for (final x in switch (byTitle[title]) {
        null => <T>[],
        final List<T> several => several,
        final one => [one as T],
      }) {
        final y = year(x);
        if (t.year == null) return x;
        if (y == null) {
          undated ??= x;
        } else if ((y - t.year!).abs() <= 1) {
          // Same title, another film (a remake, an older series): the year tells them apart
          return x;
        }
      }
    }
    return undated;
  }
}

/// The YouTube id in what a provider gives as a trailer: an id, or a YouTube address.
String? youtubeId(String? v) {
  final t = v?.trim() ?? '';
  if (RegExp(r'^[\w-]{11}$').hasMatch(t)) return t;
  return RegExp(r'(?:v=|youtu\.be/|embed/|shorts/)([\w-]{11})').firstMatch(t)?.group(1);
}
