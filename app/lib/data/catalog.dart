import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'matching.dart';
import 'models.dart';
import 'source.dart';

/// The whole catalog of a playlist, loaded once per session (Xtream has no search or sort
/// endpoints), with the derived views the UI is built from.
class Catalog {
  Catalog(this.source);

  final ContentSource source;
  Future<CatalogData>? _data;

  /// The catalog once loaded, for what cannot wait for it (a play button and its other versions).
  CatalogData? loaded;

  /// When a catalog that came with a list missing may be asked for again.
  DateTime? _retryAt;

  /// How long a catalog with a list missing is kept before that list is asked for again: screens
  /// load it as they are drawn, and each would ask the panel anew.
  static var retryAfter = const Duration(minutes: 5);

  Future<CatalogData> load() {
    if (_retryAt case final at? when !DateTime.now().isBefore(at)) {
      _retryAt = null;
      _data = null;
    }
    late final Future<CatalogData> loading;
    return loading = _data ??= () async {
      // One failing list (e.g. a panel without series) must not break the others, but it is not
      // kept for good either: a while later, the next load asks for it again
      Object? error;
      Future<List<T>> safe<T>(Future<List<T>> f) => f.catchError((Object e) {
        error ??= e;
        return <T>[];
      });
      final r = await Future.wait([safe(source.liveChannels()), safe(source.movies()), safe(source.series())]);
      if (r.every((l) => l.isEmpty) && error != null) {
        if (_data == loading) _data = null; // nothing came: Retry asks again at once
        throw error!;
      }
      if (error != null && _data == loading) _retryAt = DateTime.now().add(retryAfter);
      final movies = r[1] as List<Movie>, series = r[2] as List<Series>;
      // Which items are versions of one title: off the UI thread when there are a lot of names
      final names = [
        [for (final m in movies) (m.name, m.year)],
        [for (final s in series) (s.name, s.year)],
      ];
      final keys = movies.length + series.length < 2000 ? _versionKeys(names) : await compute(_versionKeys, names);
      return loaded = CatalogData(
        live: r[0] as List<LiveChannel>,
        movies: movies,
        series: series,
        movieKeys: keys[0],
        seriesKeys: keys[1],
      );
    }();
  }
}

List<List<String>> _versionKeys(List<List<(String, int?)>> lists) {
  final keys = <String, String>{};
  String shared(String key) => keys[key] ??= key; // one copy of each: a title's versions share it
  return [
    for (final list in lists) [for (final (name, year) in list) shared(versionKey(name, year))],
  ];
}

/// [items] (movies or series) with each title once, its first version: a provider may list a title
/// more than once in one category too, per format or quality. Its page has every version. [data]
/// has the key of every title worked out already, when loaded.
List<T> oneOfEachTitle<T extends Object>(Iterable<T> items, CatalogData? data) {
  final seen = <String>{};
  return [
    for (final x in items)
      if (seen.add(
        data?.keyOf(x) ??
            switch (x) {
              Movie m => versionKey(m.name, m.year),
              Series s => versionKey(s.name, s.year),
              _ => '$x',
            },
      ))
        x,
  ];
}

/// Catalog of the playlist currently open; detail screens use it for "More like this".
final currentCatalog = ValueNotifier<Catalog?>(null);

class CatalogData {
  CatalogData({
    required this.live,
    required this.movies,
    required this.series,
    DateTime? now,
    this._movieKeys,
    this._seriesKeys,
  }) : _now = now ?? DateTime.now();

  List<String>? _movieKeys, _seriesKeys; // versionKey of each, when worked out already, until in the maps

  // Versions: a provider may list a title once per language or quality ("Spider-Man", "Spider-Man
  // 4K"), and two providers combined list it twice. Rows show it once; its page lists them all.

  late final Map<Movie, String> _movieKey = () {
    final keys = _movieKeys;
    _movieKeys = null;
    return _keyed(
      movies,
      keys,
      (m) => versionKey(m.name, m.year),
      (m) => Object.hash(m.id, m.name),
      (a, b) => a.id == b.id && a.name == b.name,
    );
  }();
  late final Map<Series, String> _seriesKey = () {
    final keys = _seriesKeys;
    _seriesKeys = null;
    return _keyed(
      series,
      keys,
      (s) => versionKey(s.name, s.year),
      (s) => Object.hash(s.id, s.name),
      (a, b) => a.id == b.id && a.name == b.name,
    );
  }();
  late final Map<String, Object> _movieVersions = _group(movies, _movieKey);
  late final Map<String, Object> _seriesVersions = _group(series, _seriesKey);

  /// Each of [items] with its key: [keys] when worked out already. Found by [hash] and [same], so a
  /// copy of an item finds it too: the one a movie's page made with its full record, one made from
  /// a library entry (with no year). Not by identity, which on 32-bit the VM keeps in a table of
  /// its own.
  static Map<T, String> _keyed<T extends Object>(
    List<T> items,
    List<String>? keys,
    String Function(T) key,
    int Function(T) hash,
    bool Function(T, T) same,
  ) {
    final map = LinkedHashMap<T, String>(equals: (a, b) => identical(a, b) || same(a, b), hashCode: hash);
    for (var i = 0; i < items.length; i++) {
      map[items[i]] = keys?[i] ?? key(items[i]);
    }
    return map;
  }

  /// Each title's versions: the one there is, as most titles have one, or the list of them.
  static Map<String, Object> _group<T extends Object>(List<T> items, Map<T, String> keys) {
    final groups = <String, Object>{};
    for (final x in items) {
      final key = keys[x]!;
      switch (groups[key]) {
        case null:
          groups[key] = x;
        case final List<T> several:
          several.add(x);
        case final one:
          groups[key] = <T>[one as T, x];
      }
    }
    return groups..updateAll((_, v) => v is List<T> ? List<T>.of(v, growable: false) : v);
  }

  static List<T> _versions<T>(Object? group, T x) => switch (group) {
    null => [x],
    final List<T> several => several,
    final one => [one as T],
  };

  /// What tells [x]'s title apart (see [versionKey]), worked out once for the whole catalog.
  String keyOf(Object x) => switch (x) {
    Movie m => _movieKey[m] ?? versionKey(m.name, m.year),
    Series s => _seriesKey[s] ?? versionKey(s.name, s.year),
    _ => '$x',
  };

  /// Every version of [m]'s title, [m] among them.
  List<Movie> versionsOf(Movie m) => _versions(_movieVersions[_movieKey[m] ?? versionKey(m.name, m.year)], m);

  /// Every version of [s]'s title, [s] among them.
  List<Series> seriesVersionsOf(Series s) => _versions(_seriesVersions[_seriesKey[s] ?? versionKey(s.name, s.year)], s);

  /// [items] with each title once: its first version.
  List<Movie> _oneEach(Iterable<Movie> items) {
    final seen = <String>{};
    return [
      for (final m in items)
        if (seen.add(_movieKey[m] ?? versionKey(m.name, m.year))) m,
    ];
  }

  List<Series> _oneEachSeries(Iterable<Series> items) {
    final seen = <String>{};
    return [
      for (final s in items)
        if (seen.add(_seriesKey[s] ?? versionKey(s.name, s.year))) s,
    ];
  }

  final List<LiveChannel> live;
  final List<Movie> movies;
  final List<Series> series;
  final DateTime _now;

  // Dates in microseconds since the epoch; one missing counts as the longest ago
  static final _never = DateTime(0).microsecondsSinceEpoch;
  static int _byDateDesc(int? a, int? b) => (b ?? _never).compareTo(a ?? _never);

  // Movies

  late final List<Movie> recentMovies = _oneEach(
    [...movies]..sort((a, b) => _byDateDesc(a.addedMicros, b.addedMicros)),
  );

  /// Well rated and fairly recent, so the row is not all decades-old classics.
  late final List<Movie> topMovies = _oneEach(
    movies.where((m) => (m.rating ?? 0) >= 7 && (m.year ?? 0) >= _now.year - 6 && m.poster != null).toList()
      ..sort((a, b) => b.rating!.compareTo(a.rating!)),
  );

  /// This year's (and late last year's) releases, newest first.
  late final List<Movie> newReleases = _oneEach(
    movies.where((m) => (m.year ?? 0) >= _now.year - (_now.month <= 2 ? 1 : 0) && m.poster != null).toList()
      ..sort((a, b) => _byDateDesc(a.releaseMicros ?? a.addedMicros, b.releaseMicros ?? b.addedMicros)),
  );

  late final List<String> movieGenres = _genresByCount(movies.map((m) => m.genres));

  /// The newest first; the list must not be changed.
  List<Movie> moviesIn(String genre) {
    final k = _genreKey(genre);
    return _moviesByGenre[k] ?? List.unmodifiable(recentMovies.where((m) => m.genres.any((g) => _genreKey(g) == k)));
  }

  /// The genres shown get their titles in one pass over the catalog, not one each time a tab is drawn.
  late final _moviesByGenre = _byGenre(recentMovies, movieGenres, (m) => m.genres);

  /// Picks for the hero: recent, rated, with artwork and a synopsis.
  late final List<Movie> featuredMovies = recentMovies
      .where((m) => (m.rating ?? 0) >= 6.5 && m.poster != null && m.plot != null)
      .take(6)
      .toList();

  /// Same main genre, best rated first, excluding [m] itself.
  List<Movie> similarMovies(Movie m, {int limit = 20}) {
    final g = m.genres.firstOrNull;
    if (g == null) return const [];
    final own = versionsOf(m).toSet();
    return _oneEach(
      movies.where((x) => !own.contains(x) && x.poster != null && x.genres.contains(g)).toList()
        ..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0)),
    ).take(limit).toList();
  }

  // Series

  late final List<Series> recentSeries = _oneEachSeries(
    [...series]..sort((a, b) => _byDateDesc(a.updatedMicros, b.updatedMicros)),
  );

  late final List<Series> topSeries = _oneEachSeries(
    series.where((s) => (s.rating ?? 0) >= 7.5 && (s.year ?? 0) >= _now.year - 8 && s.cover != null).toList()
      ..sort((a, b) => b.rating!.compareTo(a.rating!)),
  );

  late final List<String> seriesGenres = _genresByCount(series.map((s) => s.genres));

  /// The newest first; the list must not be changed.
  List<Series> seriesIn(String genre) {
    final k = _genreKey(genre);
    return _seriesByGenre[k] ?? List.unmodifiable(recentSeries.where((s) => s.genres.any((g) => _genreKey(g) == k)));
  }

  late final _seriesByGenre = _byGenre(recentSeries, seriesGenres, (s) => s.genres);

  late final List<Series> featuredSeries = recentSeries
      .where((s) => (s.rating ?? 0) >= 6.5 && s.backdrop != null && s.plot != null)
      .take(6)
      .toList();

  List<Series> similarSeries(Series s, {int limit = 20}) {
    final g = s.genres.firstOrNull;
    if (g == null) return const [];
    final own = seriesVersionsOf(s);
    return _oneEachSeries(
      series.where((x) => !own.contains(x) && x.cover != null && x.genres.contains(g)).toList()
        ..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0)),
    ).take(limit).toList();
  }

  /// A genre however it is written: "Acción", "Accion" and "ACCIÓN" are one. Worked out once per
  /// spelling, as there are few.
  static String _genreKey(String g) => _genreKeys[g] ??= fold(g).trim();
  static final _genreKeys = <String, String>{};

  /// How many genres the tabs and search offer, most common first.
  static const genresShown = 14;

  /// [titles] in each of the first [genresShown] of [genres], in their order; each title once.
  static Map<String, List<T>> _byGenre<T>(List<T> titles, List<String> genres, List<String> Function(T) genresOf) {
    final lists = {for (final g in genres.take(genresShown)) _genreKey(g): <T>[]};
    for (final t in titles) {
      for (final g in genresOf(t)) {
        final list = lists[_genreKey(g)];
        // Once, even written twice ("Drama, drama")
        if (list != null && (list.isEmpty || !identical(list.last, t))) list.add(t);
      }
    }
    return lists.map((k, v) => MapEntry(k, List<T>.unmodifiable(v)));
  }

  /// The genres, most common first, each once as most of its titles write it.
  static List<String> _genresByCount(Iterable<List<String>> all) {
    final counts = <String, int>{};
    final spellings = <String, Map<String, int>>{};
    for (final list in all) {
      for (final g in list) {
        final k = _genreKey(g);
        counts[k] = (counts[k] ?? 0) + 1;
        final s = spellings[k] ??= {};
        s[g] = (s[g] ?? 0) + 1;
      }
    }
    String shown(String k) => spellings[k]!.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).map((e) => shown(e.key)).toList();
  }
}

/// Small words kept lowercase in titles, and acronyms kept uppercase.
const _minor = {
  'de',
  'del',
  'la',
  'las',
  'el',
  'los',
  'y',
  'e',
  'en',
  'a',
  'o',
  'of',
  'the',
  'and',
  'in',
  'for',
  'por',
  'con',
};
const _acronyms = {
  'TV',
  'HD',
  'FHD',
  'UHD',
  '4K',
  'VOD',
  'ESPN',
  'HBO',
  'NBA',
  'NFL',
  'MLB',
  'NHL',
  'UFC',
  'WWE',
  'PPV',
  'MMA',
  'F1',
  'USA',
  'UK',
  'VIP',
  'DC',
  'TNT',
  'AMC',
  'CNN',
  'BBC',
  'FX',
  'MTV',
  'LMP',
  'WBA',
  'LVBP',
  'DSPORTS',
};

/// Provider category names are often shouting, decorated and prefixed
/// ("🎞️ VOD | TOP 10 DE LA SEMANA"); this makes them read like titles ("Top 10 de la Semana").
String displayCategoryName(String raw) {
  var s = raw.trim();
  // Leading emoji/symbols and type prefixes such as "VOD |" or "SERIES |"
  s = s.replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '');
  s = s.replaceFirst(
    RegExp(r'^(VOD|SERIES|SERIE|MOVIES?|PEL[IÍ]CULAS?|LIVE|TV)\s*[|:\-–]\s*', caseSensitive: false),
    '',
  );
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return raw.trim();
  // Only retitle names written entirely in capitals; anything else is left as the provider wrote it
  if (s != s.toUpperCase()) return s;
  final words = s.split(' ');
  return [
    for (final (i, w) in words.indexed)
      if (_acronyms.contains(w.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '')) || RegExp(r'\d').hasMatch(w))
        w
      else if (i > 0 && _minor.contains(w.toLowerCase()))
        w.toLowerCase()
      else
        w.isEmpty ? w : w[0] + w.substring(1).toLowerCase(),
  ].join(' ');
}
