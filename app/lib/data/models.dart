// IPTV content models. Xtream servers mix types freely (ids as numbers or
// strings, "rating": 8 or "8", null or ""), so every field is read through the
// lenient helpers below.
import 'dart:convert';

/// Fallback name for items the server sends without one. A marker, not a text: the screens say it
/// in the app's language (categoryLabel, episodeName), as these are read where there is none.
const untitled = 'Untitled';

/// The name of a channel, movie or series that came without one, in the app's language: set as the
/// language is known (see followAppLanguage), and taken along off the screen's thread (runOffThread).
var untitledName = untitled;

/// An M3U entry's group when it has none; also its category's id, so it never changes.
const ungrouped = 'Ungrouped';

/// An episode's title when the panel sends none.
const untitledEpisode = 'Episode';

int? asInt(Object? v) => switch (v) {
  int i => i,
  bool b => b ? 1 : 0, // a panel or bridge that sends auth, is_adult, tv_archive as true/false
  String s when s.trim().toLowerCase() == 'true' => 1,
  String s when s.trim().toLowerCase() == 'false' => 0,
  double d => d.isFinite ? d.toInt() : null, // "NaN" from a panel: none, not an error
  String s => int.tryParse(s.trim()) ?? asInt(double.tryParse(s.trim())),
  _ => null,
};

/// A rating as panels write it: 8, "8.2", "7,5" (a decimal comma), "8.2/10"; none for what is not a
/// finite number.
double? asDouble(Object? v) {
  final d = switch (v) {
    num n => n.toDouble(),
    String s => double.tryParse(RegExp(r'^\d+([.,]\d+)?').stringMatch(s.trim())?.replaceFirst(',', '.') ?? ''),
    _ => null,
  };
  return d != null && d.isFinite ? d : null;
}

/// A text, or none: an empty one, a list or an object sent where a text goes (plot: []), or the
/// words panels write for nothing ("null", "N/A").
String? asStr(Object? v) {
  if (v == null || v is List || v is Map) return null;
  final s = '$v'.trim();
  return s.isEmpty || const {'null', 'n/a'}.contains(s.toLowerCase()) ? null : s;
}

DateTime? fromUnix(Object? v) {
  final secs = asInt(v);
  // Out of DateTime's range (a panel's typo) is no date either
  return secs == null || secs == 0 || secs.abs() > 8640000000000
      ? null
      : DateTime.fromMillisecondsSinceEpoch(secs * 1000);
}

// Dates as listings keep them. A big catalog has a date or two in each of its tens of thousands of
// items, and a DateTime takes over a hundred bytes: the VM keeps it broken down into its parts too.
// A local time in whole seconds, what panels send, is kept as its seconds from 2020 instead: an int
// that small (decades either side) takes no room of its own, on 32-bit ARM too. Any other DateTime
// is kept as it is.
const _epoch = 1577836800; // 2020-01-01 UTC, in seconds

Object? _packDate(DateTime? d) {
  if (d == null || d.isUtc || d.microsecondsSinceEpoch % Duration.microsecondsPerSecond != 0) return d;
  return d.microsecondsSinceEpoch ~/ Duration.microsecondsPerSecond - _epoch;
}

DateTime? _unpackDate(Object? v) =>
    v is int ? DateTime.fromMillisecondsSinceEpoch((v + _epoch) * Duration.millisecondsPerSecond) : v as DateTime?;

int? _microsOf(Object? v) =>
    v is int ? (v + _epoch) * Duration.microsecondsPerSecond : (v as DateTime?)?.microsecondsSinceEpoch;

// Ids as listings keep them: most panels number their items, and the int of an id that reads as
// one takes no room of its own (or 16 bytes past a billion on 32-bit), where its text takes 20 and
// more. Any other id is kept as it is.
Object _packId(String id) {
  final n = int.tryParse(id);
  return n != null && '$n' == id ? n : id;
}

String _unpackId(Object id) => id is int ? '$id' : id as String;

/// One copy of each value the items of a listing repeat. A big catalog repeats its category ids,
/// extensions, genres and artwork, and a title's versions their plot, cast and rating, tens of
/// thousands of times; read from JSON, each item would keep copies of its own.
class ValuePool {
  final _texts = <String, String>{};
  final _numbers = <double, double>{};
  final _durations = <int, Duration>{};

  String? text(String? s) => s == null ? null : _texts[s] ??= s;

  /// Neither 0 nor NaN: 0.0 equals -0.0, and NaN equals nothing, itself included.
  double? number(double? d) => d == null || d == 0 || d.isNaN ? d : _numbers[d] ??= d;

  Duration? duration(Duration? d) => d == null ? null : _durations[d.inMicroseconds] ??= d;
}

class Category {
  const Category({required this.id, required this.name});

  factory Category.fromJson(Map<String, dynamic> j) =>
      Category(id: asStr(j['category_id']) ?? '', name: asStr(j['category_name']) ?? untitled);

  final String id;
  final String name;
}

class LiveChannel {
  const LiveChannel({
    required this.id,
    required this.name,
    this.number,
    this.icon,
    this.epgId,
    this.categoryId,
    this.archiveDays = 0,
    this.url,
  });

  /// An item of get_live_streams; [pool] shares what it repeats with the other items of its list.
  factory LiveChannel.fromJson(Map<String, dynamic> j, [ValuePool? pool]) {
    final p = pool ?? ValuePool();
    return LiveChannel(
      id: asStr(j['stream_id']) ?? '',
      name: p.text(asStr(j['name'])) ?? untitledName,
      number: asInt(j['num']),
      icon: p.text(asStr(j['stream_icon'])),
      // With none, its name: the guide's own names for its channels are matched by it (see GuideChannels)
      epgId: p.text(asStr(j['epg_channel_id']) ?? asStr(j['name'])),
      categoryId: p.text(asStr(j['category_id'])),
      archiveDays: asInt(j['tv_archive']) == 1 ? asInt(j['tv_archive_duration']) ?? 0 : 0,
    );
  }

  final String id;
  final String name;
  final int? number;
  final String? icon;
  final String? epgId;
  final String? categoryId;
  final int archiveDays; // catch-up days; 0 = no archive
  final String? url; // M3U only: the playlist carries the URL

  bool get hasArchive => archiveDays > 0;

  /// Whether the provider still keeps what aired until [end] for catch-up: over, and no older
  /// than the [archiveDays] the channel keeps.
  bool keeps(DateTime end, [DateTime? now]) {
    final t = now ?? DateTime.now();
    return hasArchive && end.isBefore(t) && end.isAfter(t.subtract(Duration(days: archiveDays)));
  }

  /// The same channel under other ids (a combined playlist tells providers apart by them).
  LiveChannel withIds(String id, String? categoryId, {String? epgId}) => LiveChannel(
    id: id,
    name: name,
    number: number,
    icon: icon,
    epgId: epgId ?? this.epgId,
    categoryId: categoryId,
    archiveDays: archiveDays,
    url: url,
  );
}

/// Splits "Acción, Comedia / Drama" into ["Acción", "Comedia", "Drama"]. Worked out once per text,
/// as titles share few of them; the list must not be changed.
List<String> splitGenres(String? genre) {
  if (genre == null) return const [];
  if (_genreSplits[genre] case final known?) return known;
  if (_genreSplits.length >= 4096) _genreSplits.clear(); // some panel writing a new one each time
  return _genreSplits[genre] = List.unmodifiable([
    for (final g in genre.split(_genreSeparators))
      if (g.trim().isNotEmpty) g.trim(),
  ]);
}

final _genreSeparators = RegExp(r'[,/|]');
final _genreSplits = <String, List<String>>{};

/// A date, or none: MySQL's empty "0000-00-00" (which Dart takes for the year -1) and anything before
/// films were made is none.
DateTime? asDate(Object? v) {
  final s = asStr(v);
  final d = s == null ? null : DateTime.tryParse(s);
  return d == null || d.year < 1870 ? null : d;
}

/// A year a title can have: from 1870 to a few years ahead. A panel's 0 (or 1) is none.
int? asYear(Object? v) {
  final y = asInt(v);
  return y != null && y >= 1870 && y <= DateTime.now().year + 5 ? y : null;
}

/// The year of a date as panels write it, also when it is the year alone ("2014").
int? yearOf(Object? date) => asDate(date)?.year ?? asYear(RegExp(r'^\d{4}$').stringMatch(asStr(date) ?? ''));

/// A rating out of 10: "rating", else "rating_5based" doubled (some panels fill only that one);
/// none outside 0 to 10.
double? ratingOf(Map<String, dynamic> j) {
  final ten = asDouble(j['rating']), five = asDouble(j['rating_5based']);
  final r = (ten ?? 0) <= 0 && (five ?? 0) > 0 ? five! * 2 : ten;
  return r != null && r >= 0 && r <= 10 ? r : null;
}

/// The TMDB id: the one id a title keeps with every provider (vod_info "tmdb_id", some panels "tmdb").
String? tmdbOf(Map<String, dynamic> j) {
  final t = asStr(j['tmdb_id']) ?? asStr(j['tmdb']);
  return t == null || t.isEmpty || t == '0' ? null : t;
}

String? _firstOf(Object? v) => v is List ? (v.isEmpty ? null : asStr(v.first)) : asStr(v);

class Movie {
  const Movie({
    required String this._id,
    required this.name,
    this.poster,
    this.backdrop,
    this.originalName,
    this.rating,
    this.year,
    this.plot,
    this.genre,
    this.cast,
    this.director,
    this.country,
    this.ageRating,
    this.trailer,
    this.duration,
    DateTime? this._releaseDate,
    this.bitrateKbps,
    this.sizeBytes,
    this.extension = 'mp4',
    this.categoryId,
    DateTime? this._added,
    this.url,
    this.tmdbId,
  });

  /// With its id and dates as listings keep them ([_packId], [_packDate]).
  const Movie._packed({
    required this._id,
    required this.name,
    required this.poster,
    required this.backdrop,
    required this.originalName,
    required this.rating,
    required this.year,
    required this.plot,
    required this.genre,
    required this.cast,
    required this.director,
    required this.country,
    required this.ageRating,
    required this.trailer,
    required this.duration,
    required this._releaseDate,
    required this.bitrateKbps,
    required this.sizeBytes,
    required this.extension,
    required this.categoryId,
    required this._added,
    required this.url,
    required this.tmdbId,
  });

  /// Reads both the catalog listing (get_vod_streams) and the full record (get_vod_info "info").
  /// [pool] shares what a listing's items repeat.
  factory Movie.fromJson(Map<String, dynamic> j, [ValuePool? pool]) {
    final p = pool ?? ValuePool();
    final secs = asInt(j['duration_secs']) ?? 0;
    final minutes = asInt(j['episode_run_time']) ?? 0;
    return Movie._packed(
      id: _packId(asStr(j['stream_id']) ?? ''),
      name: p.text(asStr(j['title']) ?? asStr(j['name'])) ?? untitledName,
      poster: p.text(asStr(j['stream_icon']) ?? asStr(j['cover_big']) ?? asStr(j['movie_image'])),
      backdrop: p.text(_firstOf(j['backdrop_path'])),
      originalName: p.text(asStr(j['o_name'])),
      rating: p.number(ratingOf(j)),
      year: asYear(j['year']) ?? yearOf(j['release_date']) ?? yearOf(j['releasedate']),
      plot: p.text(asStr(j['plot']) ?? asStr(j['description'])),
      genre: p.text(asStr(j['genre'])),
      cast: p.text(asStr(j['cast']) ?? asStr(j['actors'])),
      director: p.text(asStr(j['director'])),
      country: p.text(asStr(j['country'])),
      ageRating: p.text(asStr(j['mpaa_rating']) ?? asStr(j['age'])),
      trailer: p.text(asStr(j['youtube_trailer'])),
      duration: p.duration(secs > 0 ? Duration(seconds: secs) : (minutes > 0 ? Duration(minutes: minutes) : null)),
      releaseDate: _packDate(asDate(j['releasedate']) ?? asDate(j['release_date'])),
      bitrateKbps: asInt(j['bitrate']),
      sizeBytes: asInt(j['source_size']),
      extension: p.text(asStr(j['container_extension'])) ?? 'mp4',
      categoryId: p.text(asStr(j['category_id'])),
      added: _packDate(fromUnix(j['added'])),
      url: null,
      tmdbId: p.text(tmdbOf(j)),
    );
  }

  final Object _id; // a String, or packed ([_packId])
  String get id => _unpackId(_id);
  final String name;
  final String? tmdbId; // in the full record; listings rarely carry it
  final String? poster, backdrop, originalName;
  final double? rating; // out of 10
  final int? year;
  final String? plot, genre, cast, director, country, ageRating, trailer;
  final Duration? duration;
  final int? bitrateKbps, sizeBytes;
  final String extension;
  final String? categoryId;
  final String? url; // M3U only
  final Object? _releaseDate, _added; // a DateTime, or packed ([_packDate])

  DateTime? get releaseDate => _unpackDate(_releaseDate);
  DateTime? get added => _unpackDate(_added);

  /// [releaseDate] and [added] in microseconds since the epoch, as sorting compares them: without
  /// making a DateTime of each.
  int? get releaseMicros => _microsOf(_releaseDate);
  int? get addedMicros => _microsOf(_added);

  List<String> get genres => splitGenres(genre);

  /// This listing entry completed with whatever the full record adds.
  Movie withDetail(Movie d) => Movie._packed(
    id: _id,
    name: name,
    poster: poster ?? d.poster,
    backdrop: backdrop ?? d.backdrop,
    originalName: originalName ?? d.originalName,
    rating: (rating ?? 0) > 0 ? rating : d.rating,
    year: year ?? d.year,
    plot: plot ?? d.plot,
    genre: genre ?? d.genre,
    cast: cast ?? d.cast,
    director: director ?? d.director,
    country: country ?? d.country,
    ageRating: ageRating ?? d.ageRating,
    trailer: trailer ?? d.trailer,
    duration: d.duration ?? duration, // the full record measures the actual file
    releaseDate: _releaseDate ?? d._releaseDate,
    bitrateKbps: bitrateKbps ?? d.bitrateKbps,
    sizeBytes: sizeBytes ?? d.sizeBytes,
    extension: extension,
    categoryId: categoryId,
    added: _added,
    url: url,
    tmdbId: tmdbId ?? d.tmdbId,
  );

  /// The same movie under other ids (a combined playlist tells providers apart by them).
  Movie withIds(String id, String? categoryId) => Movie._packed(
    id: id,
    name: name,
    poster: poster,
    backdrop: backdrop,
    originalName: originalName,
    rating: rating,
    year: year,
    plot: plot,
    genre: genre,
    cast: cast,
    director: director,
    country: country,
    ageRating: ageRating,
    trailer: trailer,
    duration: duration,
    releaseDate: _releaseDate,
    bitrateKbps: bitrateKbps,
    sizeBytes: sizeBytes,
    extension: extension,
    categoryId: categoryId,
    added: _added,
    url: url,
    tmdbId: tmdbId,
  );
}

class Series {
  const Series({
    required String this._id,
    required this.name,
    this.cover,
    this.backdrop,
    this.rating,
    this.year,
    this.plot,
    this.genre,
    this.cast,
    this.director,
    this.trailer,
    this.episodeRuntime,
    DateTime? this._updated,
    this.categoryId,
    this.tmdbId,
  });

  /// With its id and date as listings keep them ([_packId], [_packDate]).
  const Series._packed({
    required this._id,
    required this.name,
    required this.cover,
    required this.backdrop,
    required this.rating,
    required this.year,
    required this.plot,
    required this.genre,
    required this.cast,
    required this.director,
    required this.trailer,
    required this.episodeRuntime,
    required this._updated,
    required this.categoryId,
    required this.tmdbId,
  });

  /// An item of get_series, or the "info" of get_series_info; [pool] shares what a listing's items
  /// repeat.
  factory Series.fromJson(Map<String, dynamic> j, [ValuePool? pool]) {
    final p = pool ?? ValuePool();
    final minutes = asInt(j['episode_run_time']) ?? 0;
    return Series._packed(
      id: _packId(asStr(j['series_id']) ?? ''),
      name: p.text(asStr(j['title']) ?? asStr(j['name'])) ?? untitledName,
      cover: p.text(asStr(j['cover'])),
      backdrop: p.text(_firstOf(j['backdrop_path'])),
      rating: p.number(ratingOf(j)),
      year: asYear(j['year']) ?? yearOf(j['release_date']) ?? yearOf(j['releaseDate']),
      plot: p.text(asStr(j['plot'])),
      genre: p.text(asStr(j['genre'])),
      cast: p.text(asStr(j['cast'])),
      director: p.text(asStr(j['director'])),
      trailer: p.text(asStr(j['youtube_trailer'])),
      episodeRuntime: p.duration(minutes > 0 ? Duration(minutes: minutes) : null),
      updated: _packDate(fromUnix(j['last_modified'])),
      categoryId: p.text(asStr(j['category_id'])),
      tmdbId: p.text(tmdbOf(j)),
    );
  }

  final Object _id; // a String, or packed ([_packId])
  String get id => _unpackId(_id);
  final String name;
  final String? tmdbId;
  final String? cover, backdrop;
  final double? rating;
  final int? year;
  final String? plot, genre, cast, director, trailer;
  final Duration? episodeRuntime;
  final String? categoryId;
  final Object? _updated; // a DateTime, or packed ([_packDate])

  /// The last time the panel added episodes.
  DateTime? get updated => _unpackDate(_updated);

  /// [updated] in microseconds since the epoch, as sorting compares it: without making a DateTime
  /// of each.
  int? get updatedMicros => _microsOf(_updated);

  List<String> get genres => splitGenres(genre);

  /// The same series under other ids (a combined playlist tells providers apart by them).
  Series withIds(String id, String? categoryId) => Series._packed(
    id: id,
    name: name,
    cover: cover,
    backdrop: backdrop,
    rating: rating,
    year: year,
    plot: plot,
    genre: genre,
    cast: cast,
    director: director,
    trailer: trailer,
    episodeRuntime: episodeRuntime,
    updated: _updated,
    categoryId: categoryId,
    tmdbId: tmdbId,
  );
}

/// Metadata of one season (get_series_info "seasons"), when the panel provides it.
class SeasonInfo {
  const SeasonInfo({required this.number, this.name, this.overview, this.airDate, this.rating});

  factory SeasonInfo.fromJson(Map<String, dynamic> j) => SeasonInfo(
    number: asInt(j['season_number']) ?? 0,
    name: asStr(j['name']),
    overview: asStr(j['overview']),
    airDate: asDate(j['air_date']),
    rating: asDouble(j['vote_average']),
  );

  final int number;
  final String? name, overview;
  final DateTime? airDate;
  final double? rating;
}

class Episode {
  const Episode({
    required this.id,
    required this.season,
    required this.number,
    required this.title,
    this.extension = 'mp4',
    this.plot,
    this.image,
    this.duration,
    this.rating,
    this.releaseDate,
    this.tmdbId,
  });

  factory Episode.fromJson(Map<String, dynamic> j, int season) {
    final info = j['info'] is Map<String, dynamic> ? j['info'] as Map<String, dynamic> : const <String, dynamic>{};
    final secs = asInt(info['duration_secs']) ?? 0;
    return Episode(
      id: asStr(j['id']) ?? '',
      // "season": 0 inside season 1's list is a panel's slip, not a season 0
      season: switch (asInt(j['season'])) {
        final n? when n > 0 => n,
        _ => season,
      },
      number: asInt(j['episode_num']) ?? 0,
      title: asStr(j['title']) ?? untitledEpisode,
      extension: asStr(j['container_extension']) ?? 'mp4',
      plot: asStr(info['plot']),
      image: asStr(info['movie_image']) ?? asStr(info['cover_big']),
      duration: secs > 0 ? Duration(seconds: secs) : null,
      rating: ratingOf(info),
      releaseDate: asDate(info['release_date']) ?? asDate(info['releasedate']),
      tmdbId: tmdbOf(info),
    );
  }

  final String id;
  final int season;
  final int number;
  final String title;
  final String extension;
  final String? plot, image;
  final Duration? duration;
  final double? rating;
  final DateTime? releaseDate;
  final String? tmdbId;

  /// Panels often name episodes "Show (2021) - S01E01 - Chapter 1"; the UI already shows the
  /// series and the episode number, so keep only "Chapter 1".
  String cleanTitle(String seriesName) {
    var t = title;
    final bare = seriesName.replaceFirst(RegExp(r'\s*\(\d{4}\)$'), '');
    for (final prefix in [seriesName, bare]) {
      if (prefix.isEmpty || !t.toLowerCase().startsWith(prefix.toLowerCase())) continue;
      // "House Training" in House, "Showdown" in Show: a word that only begins like the name stays
      final rest = t.substring(prefix.length);
      if (_afterName.hasMatch(rest) || _seasonMark.hasMatch(rest)) t = rest;
    }
    t = t.replaceFirst(_seasonMark, '');
    t = t.replaceFirst(RegExp(r'^[\s\-–—:|.]+'), '').trim();
    return t.isEmpty ? title : t;
  }

  /// What may follow a series' name in an episode's title for the name to come off: nothing, a
  /// separator or a year.
  static final _afterName = RegExp(r'^\s*($|[\-–—:|.]|\(\d{4}\))');

  /// A season and episode mark, after any separators: S01E05, T01E05 (Spanish), 1x05.
  static final _seasonMark = RegExp(r'^[\s\-–—:|.]*(?:[ST]\d{1,2}\s*E\d{1,4}|\d{1,2}x\d{1,4})\b', caseSensitive: false);

  /// The same episode under another id (a combined playlist tells providers apart by them).
  Episode withId(String id) => Episode(
    id: id,
    season: season,
    number: number,
    title: title,
    extension: extension,
    plot: plot,
    image: image,
    duration: duration,
    rating: rating,
    releaseDate: releaseDate,
    tmdbId: tmdbId,
  );
}

class SeriesDetail {
  const SeriesDetail({required this.series, required this.seasons, this.seasonInfo = const {}});

  /// get_series_info: "episodes" is a map {"1": [...], "2": [...]}, although
  /// some servers return a list of lists instead.
  factory SeriesDetail.fromJson(Series base, Map<String, dynamic> j) {
    final seasons = <int, List<Episode>>{};
    // A season with no number of its own (a key that is none, a list with no "season") takes the
    // next one free, rather than 0 over the one before
    int numberFor(Object? key) {
      if (asInt(key) case final n? when !seasons.containsKey(n)) return n;
      var n = 1;
      while (seasons.containsKey(n)) {
        n++;
      }
      return n;
    }

    void add(Object? key, Object? list) {
      // A season sent as an object of its episodes, as PHP makes a list with gaps
      if (list is Map) list = list.values.toList();
      if (list is! List) return;
      final n = numberFor(key);
      seasons[n] = [for (final e in list.whereType<Map<String, dynamic>>()) Episode.fromJson(e, n)]
        ..sort((a, b) => a.number.compareTo(b.number));
    }

    switch (j['episodes']) {
      case Map m:
        m.forEach(add);
      case List l when l.isNotEmpty && l.every((e) => e is Map && e['episode_num'] != null):
        // One flat list of episodes: grouped by their season
        final bySeason = <int, List<Object?>>{};
        for (final e in l.cast<Map>()) {
          (bySeason[asInt(e['season']) ?? 1] ??= []).add(e);
        }
        bySeason.forEach(add);
      case List l:
        for (final list in l) {
          if (list is Map) {
            add(null, list);
          } else if (list is List && list.isNotEmpty && list.first is Map) {
            add((list.first as Map)['season'], list);
          }
        }
    }
    final info = j['info'] is Map<String, dynamic> ? j['info'] as Map<String, dynamic> : const <String, dynamic>{};
    final merged = Series.fromJson({...info, 'series_id': base.id, 'category_id': base.categoryId});
    final seasonInfo = <int, SeasonInfo>{
      for (final s in (j['seasons'] is List ? j['seasons'] as List : const []).whereType<Map<String, dynamic>>())
        SeasonInfo.fromJson(s).number: SeasonInfo.fromJson(s),
    };
    return SeriesDetail(
      series: Series(
        id: base.id,
        name: merged.name == untitled || merged.name == untitledName ? base.name : merged.name,
        cover: merged.cover ?? base.cover,
        backdrop: merged.backdrop ?? base.backdrop,
        rating: (merged.rating ?? 0) > 0 ? merged.rating : base.rating,
        year: merged.year ?? base.year,
        plot: merged.plot ?? base.plot,
        genre: merged.genre ?? base.genre,
        cast: merged.cast ?? base.cast,
        director: merged.director ?? base.director,
        trailer: merged.trailer ?? base.trailer,
        episodeRuntime: merged.episodeRuntime ?? base.episodeRuntime,
        updated: merged.updated ?? base.updated,
        categoryId: base.categoryId,
        tmdbId: merged.tmdbId ?? base.tmdbId,
      ),
      // Specials (season 0) after the seasons: they are not where a series starts
      seasons: Map.fromEntries(
        seasons.entries.toList()
          ..sort((a, b) => (a.key == 0) != (b.key == 0) ? (a.key == 0 ? 1 : -1) : a.key.compareTo(b.key)),
      ),
      seasonInfo: seasonInfo,
    );
  }

  final Series series;
  final Map<int, List<Episode>> seasons;
  final Map<int, SeasonInfo> seasonInfo;
}

class EpgEntry {
  const EpgEntry({required this.title, required this.start, required this.end, this.description});

  /// get_short_epg returns title and description base64-encoded: UTF-8 inside, or Latin-1 from
  /// some panels. Null when it has no time at all. A time with no timestamp is written on the
  /// panel's clock: with [serverOffset] (its time zone's, from its login) it is read as such; without,
  /// as this device's.
  static EpgEntry? fromXtream(Map<String, dynamic> j, {Duration? serverOffset}) {
    DateTime? onPanelClock(Object? text) {
      final s = asStr(text);
      if (s == null) return null;
      if (serverOffset == null) return DateTime.tryParse(s);
      // Written with no zone: as the panel's, moved to UTC by its offset
      final utc = DateTime.tryParse('${s.replaceFirst(' ', 'T')}Z');
      return utc?.subtract(serverOffset).toLocal() ?? DateTime.tryParse(s);
    }

    final start = fromUnix(j['start_timestamp']) ?? onPanelClock(j['start']);
    final end = fromUnix(j['stop_timestamp']) ?? onPanelClock(j['end'] ?? j['stop']);
    if (start == null || end == null) return null;
    return EpgEntry(title: _decoded(j['title']) ?? '', description: _decoded(j['description']), start: start, end: end);
  }

  static String? _decoded(Object? v) {
    final s = asStr(v);
    if (s == null) return null;
    if (s.length % 4 != 0 || !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(s)) return s; // plain text
    final List<int> bytes;
    try {
      bytes = base64.decode(s);
    } on FormatException {
      return s;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // Latin-1 if it reads as text (mostly plain letters, a few accents): plain words that only
      // look like base64 ("News") give bytes that do not
      final readable = bytes.where((b) => b >= 0x20 && b < 0x7f).length;
      return readable >= bytes.length * 0.8 ? latin1.decode(bytes) : s;
    }
  }

  final String title;
  final String? description;
  final DateTime start, end;

  bool isNow([DateTime? at]) {
    final t = at ?? DateTime.now();
    return !t.isBefore(start) && t.isBefore(end);
  }
}

class AccountInfo {
  const AccountInfo({
    required this.status,
    this.expires,
    this.maxConnections,
    this.activeConnections,
    this.isTrial = false,
    this.formats = const [],
    this.serverTimezone,
    this.serverUtcOffset,
    this.message,
  });

  factory AccountInfo.fromJson(Map<String, dynamic> j) {
    final u = j['user_info'] is Map<String, dynamic>
        ? j['user_info'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final s = j['server_info'] is Map<String, dynamic>
        ? j['server_info'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return AccountInfo(
      status: asStr(u['status']) ?? 'Unknown',
      expires: fromUnix(u['exp_date']),
      // Some providers send 0 when they state no limit, which is not saying there is none
      maxConnections: switch (asInt(u['max_connections'])) {
        final n? when n > 0 => n,
        _ => null,
      },
      activeConnections: asInt(u['active_cons']),
      isTrial: asInt(u['is_trial']) == 1,
      // A list, or what PHP makes of one with gaps ({"0": "ts", "2": "m3u8"}), or "m3u8,ts"
      formats: switch (u['allowed_output_formats']) {
        List l => [for (final f in l) '$f'],
        Map m => [for (final f in m.values) '$f'],
        String s => s.split(RegExp(r'[,\s]+')).where((f) => f.isNotEmpty).toList(),
        _ => const [],
      },
      serverTimezone: asStr(s['timezone']),
      serverUtcOffset: _serverOffset(asStr(s['time_now']), asInt(s['timestamp_now'])),
      message: asStr(u['message']),
    );
  }

  /// The panel reports its wall clock ("time_now") and the UTC epoch ("timestamp_now");
  /// their difference, rounded to 15 minutes, is the server's UTC offset.
  static Duration? _serverOffset(String? wall, int? epoch) {
    if (wall == null || epoch == null) return null;
    final local = DateTime.tryParse('${wall.replaceFirst(' ', 'T')}Z');
    if (local == null) return null;
    final diff = local.difference(DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true));
    return Duration(minutes: (diff.inMinutes / 15).round() * 15);
  }

  final String status;
  final DateTime? expires; // null = never expires
  final int? maxConnections, activeConnections; // max null = no limit stated
  final bool isTrial;
  final List<String> formats; // allowed outputs: ts, m3u8, rtmp
  final String? serverTimezone;
  final Duration? serverUtcOffset; // catch-up URLs are expressed in server time
  final String? message;
}
