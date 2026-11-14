import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'library.dart';
import 'models.dart';
import 'source.dart';

/// Lowercase without diacritics, so "accion" finds "Acción": written as one letter, or as a letter
/// and its accent apart (NFD, as some providers send them).
String fold(String s) {
  final out = StringBuffer();
  for (final ch in s.toLowerCase().replaceAll(_latinMarks, '').split('')) {
    out.write(_folded[ch] ?? ch);
  }
  return out.toString();
}

const _folded = {
  'á': 'a',
  'à': 'a',
  'ä': 'a',
  'â': 'a',
  'ã': 'a',
  'å': 'a',
  'é': 'e',
  'è': 'e',
  'ë': 'e',
  'ê': 'e',
  'ě': 'e',
  'í': 'i',
  'ì': 'i',
  'ï': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ö': 'o',
  'ô': 'o',
  'õ': 'o',
  'ø': 'o',
  'ő': 'o',
  'ú': 'u',
  'ù': 'u',
  'ü': 'u',
  'û': 'u',
  'ů': 'u',
  'ű': 'u',
  'ñ': 'n',
  'ń': 'n',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'ł': 'l',
  'ş': 's',
  'ś': 's',
  'š': 's',
  'ğ': 'g',
  'ý': 'y',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
  'ř': 'r',
  'đ': 'd',
  'ı': 'i',
  'ß': 'ss',
  'æ': 'ae',
  'œ': 'oe',
  'þ': 'th',
};

/// The accents Latin letters take apart from them. Other scripts' marks stay: some are vowels.
final _latinMarks = RegExp('[\u0300-\u036f]');

final _bracketed = RegExp(r'\(\d{4}\)|\[[^\]]*\]');
final _qualityTags = RegExp(r'\b(4k|uhd|fhd|hd|sd|1080p|720p|hevc|h265|x265)\b');
final _notAlnum = RegExp(r'[^a-z0-9]+');
final _notLetterOrDigit = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);

/// A title as compared across providers: folded, without punctuation, the year in brackets or
/// quality tags ("Arthur (2024) [4K]" and "ARTHUR" are the same). Latin letters only, unless
/// [anyScript]: the keys saved in libraries were made that way and must stay the same.
String looseTitle(String s, {bool anyScript = false}) =>
    fold(s)
        .replaceAll(_bracketed, ' ')
        .replaceAll(_qualityTags, ' ')
        .replaceAll(anyScript ? _notLetterOrDigit : _notAlnum, ' ')
        .trim();

/// The words of a title as search compares them: folded, without punctuation, the year in
/// brackets, quality, audio and language tags ("Spider-Man: No Way Home (2021) [4K]" → spider,
/// man, no, way, home; "Aeropuerto - ALTADEFINICION 1080p - ESP-AC3" → aeropuerto).
/// Any script: providers carry titles in Arabic, Korean, Japanese...
/// A title made only of words that are tags elsewhere ("Dual") keeps them: it is its title.
List<String> searchWords(String s) {
  final all = looseTitle(s, anyScript: true).split(' ').where((w) => w.isNotEmpty).toList();
  final words = all.where((w) => !_tags.contains(w)).toList();
  return words.isEmpty ? all : words;
}

/// What providers add to names besides the title.
const _tags = {
  'ac3', 'eac3', 'dts', 'aac', 'atmos', 'hdr', 'hdr10', 'dv', '2160p', '480p', 'x264', 'h264', 'web', 'webdl', //
  'bluray', 'altadefinicion', 'dual', 'vose', 'vos', 'sub', 'subs', 'subtitulado', 'esp', 'lat', 'cast', 'multi',
  'mp4', 'mkv', 'avi', 'ts', 'm3u8', // a file's extension left in the name: "Un nuevo universo (2018).mp4"
};

/// What tells versions of one title apart from other titles: a provider may list a movie or a
/// series once per language or quality, with the same words and year.
String versionKey(String name, int? year) {
  // The language written out after the title ("Dark - Latino", "Dark (Latino)") is a version too;
  // search keeps it, so "dark latino" still finds it
  final words = searchWords(fold(name).replaceFirst(_languageSuffix, ''));
  // A year written after the title without brackets ("No Way Home.2022") is the year, not a word;
  // a number that cannot be a release year ("Blade Runner 2049") is part of the title
  final last = words.length > 1 ? int.tryParse(words.last) : null;
  if (last != null && last >= 1900 && last <= DateTime.now().year + 1) {
    words.removeLast();
    year ??= last;
  }
  return '${words.join(' ')}|${year ?? yearInTitle(name) ?? ''}';
}

/// A title's words alone, as [versionKey] has them: without its year, tags or the language written
/// out, in any script. "Aeropuerto - ALTADEFINICION 1080p - ESP-AC3" is "aeropuerto". For comparing
/// titles here and now; saved keys keep [looseTitle].
String bareTitle(String name) {
  final key = versionKey(name, null);
  return key.substring(0, key.lastIndexOf('|'));
}

final _languageSuffix = RegExp(
  r'(?:\s[-|:]\s*|\s*\()(?:latino|castellano|espanol|ingles|subtitulad[oa])\)?(?=\s*(?:\(\d{4}\)|\[[^\]]*\])*\s*$)',
);

/// A channel name as compared across providers: separators, quality and backup tags do not count
/// ("ES | Movistar La Liga FHD" and "ES: MOVISTAR LA LIGA" are the same).
String looseChannel(String s, {bool anyScript = false}) => looseTitle(
  s,
  anyScript: anyScript,
).replaceAll(RegExp(r'\b(backup|alt|\d+fps)\b'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// The year a title carries in its name ("Arthur (2024)", "Arthur [2024]"), for providers that do
/// not give it apart. Only a year: "[1080]" is a quality.
int? yearInTitle(String s) => int.tryParse(_yearInTitle.firstMatch(s)?.group(1) ?? '');

final _yearInTitle = RegExp(r'[(\[]((?:19|20)\d{2})[)\]]');

final _titleKeys = Expando<String>();

/// What makes copies of one title the same here (another language or quality, another provider):
/// a movie's or series' words and year, as [versionKey]; an episode's series and its number in it.
/// Worked out once per reference.
String titleKey(MediaRef r) => _titleKeys[r] ??= switch (r.kind) {
  MediaKind.movie || MediaKind.series => '${r.kind.name}/${versionKey(r.title, r.year)}',
  MediaKind.episode => '${seriesKey(r)}/${r.season}x${r.number}',
  MediaKind.live => r.key,
};

/// An episode's series, as [titleKey] has it.
String seriesKey(MediaRef episode) => 'series/${versionKey(episode.seriesTitle ?? '', episode.year)}';

/// What identifies an item whatever the provider: its TMDB id when known; otherwise the title
/// and year of a movie or series, the number of an episode within its series, or a channel's
/// guide id or name. Provider ids ([MediaRef.id]) differ from one provider to the next.
String universalKey(MediaRef r) => switch (r.kind) {
  MediaKind.movie || MediaKind.series when r.tmdb != null => '${r.kind.name}/tmdb/${r.tmdb}',
  MediaKind.movie ||
  MediaKind.series => '${r.kind.name}/${looseTitle(r.title)}/${r.year ?? yearInTitle(r.title) ?? ''}',
  MediaKind.episode when r.tmdb != null => 'episode/tmdb/${r.tmdb}',
  MediaKind.episode => 'episode/${looseTitle(r.seriesTitle ?? '')}/${r.season}x${r.number}',
  MediaKind.live when (r.epgId ?? '').isNotEmpty => 'live/epg/${r.epgId!.toLowerCase()}',
  MediaKind.live => 'live/${looseChannel(r.title)}',
};

/// Fills in the TMDB id of the movies a library refers to: listings rarely carry it, the full
/// record does, and it is what finds them again with another provider. At most [max] lookups.
Future<int> addTmdbIds(Library library, MovieDetails source, {int max = 30, bool Function()? open}) async {
  // The movies the provider answered for without an id, and when: left alone a month, so the turn
  // reaches those after them (always the same first 30 otherwise)
  final prefs = await SharedPreferences.getInstance();
  final key = 'tmdbMisses.${library.playlistId}';
  final misses = <String, int>{};
  try {
    misses.addAll((jsonDecode(prefs.getString(key) ?? '{}') as Map).cast<String, int>());
  } on Object {
    // Unreadable: asked again, that is all
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  misses.removeWhere((_, at) => now - at > const Duration(days: 30).inMilliseconds);
  var done = 0, missed = false;
  final seen = <String>{}; // in favorites and in the history: one movie, asked once
  for (final r in library.refs.where((r) => r.kind == MediaKind.movie && r.tmdb == null).toList()) {
    if (!seen.add(r.key) || misses.containsKey(r.id)) continue;
    // Closed meanwhile, or another playlist open: its library is not this source's to touch
    if (done >= max || !(open?.call() ?? true)) break;
    done++;
    try {
      final tmdb = (await source.movieDetail(r.toMovie())).tmdbId;
      if (!(open?.call() ?? true)) continue;
      if (tmdb != null) {
        await library.updateRef(r.withTmdb(tmdb));
      } else {
        misses[r.id] = now;
        missed = true;
      }
    } catch (_) {
      // Unreachable or gone: maybe next time
    }
  }
  if (missed) await prefs.setString(key, jsonEncode(misses));
  return done;
}

class MigrationResult {
  const MigrationResult({required this.moved, required this.missing});

  final int moved;
  final List<String> missing; // titles the new provider does not seem to have
}

/// Carries favorites and history from one playlist to another, of a different provider, where
/// every id is different. Each item is looked for in [catalog], the new provider's: movies and
/// series by title and year (the TMDB id settles look-alikes such as remakes), episodes by TMDB id
/// or number within the series, channels by guide id or name. Positions, dates and the order of
/// favorites are kept.
class LibraryMigration {
  LibraryMigration({required this.source, required this.catalog});

  final ContentSource source;
  final CatalogData catalog;

  // In any script, or every Korean or Cyrillic title would share one key, the empty one
  late final _movies = _group(catalog.movies, (m) => _key(m.name));
  late final _series = _group(catalog.series, (s) => _key(s.name));
  late final _liveByEpg = {
    for (final c in catalog.live.reversed)
      if ((c.epgId ?? '').isNotEmpty) ...{
        // A combined list's "1~101" is found by the "101" of a list on its own too (partEpgId)
        c.epgId!.toLowerCase().replaceFirst(RegExp(r'^\d+~'), ''): c,
        c.epgId!.toLowerCase(): c,
      },
  };
  late final _liveByName = {
    for (final c in catalog.live.reversed)
      if (looseChannel(c.name, anyScript: true) case final k when k.isNotEmpty) k: c,
  };
  final _tmdbOfMovie = <String, Future<String?>>{};
  final _seriesDetail = <String, Future<SeriesDetail?>>{};

  static String _key(String title) => looseTitle(title, anyScript: true);

  /// [items] by [key]; none under an empty one (a title of nothing but tags or symbols).
  static Map<String, List<T>> _group<T>(List<T> items, String Function(T) key) {
    final map = <String, List<T>>{};
    for (final item in items) {
      final k = key(item);
      if (k.isNotEmpty) (map[k] ??= []).add(item);
    }
    return map;
  }

  static bool _sameYear(int? a, int? b) => a == null || b == null || (a - b).abs() <= 1;

  /// The same item in the new catalog, or null.
  Future<MediaRef?> find(MediaRef r) => switch (r.kind) {
    MediaKind.movie => _movie(r),
    MediaKind.series => Future.value(_findSeries(r.title, r.year).map(MediaRef.series).firstOrNull),
    MediaKind.episode => _episode(r),
    MediaKind.live => Future.value(_channel(r)),
  };

  Future<MediaRef?> _movie(MediaRef r) async {
    final year = r.year ?? yearInTitle(r.title);
    final candidates = [
      for (final m in _movies[_key(r.title)] ?? const <Movie>[])
        if (_sameYear(year, m.year ?? yearInTitle(m.name))) m,
    ].take(4).toList();
    if (candidates.isEmpty) return null;
    final x = switch (source) {
      final MovieDetails d => d,
      _ => null,
    };
    if (r.tmdb == null || x == null) return MediaRef.movie(candidates.first);
    // Same title is not always the same film: where the provider knows the TMDB id, it decides
    MediaRef? unknown;
    for (final m in candidates) {
      final tmdb = await (_tmdbOfMovie[m.id] ??= x.movieDetail(m).then((d) => d.tmdbId).catchError((Object _) => null));
      if (tmdb == r.tmdb) return MediaRef.movie(m).withTmdb(tmdb!);
      if (tmdb == null) unknown ??= MediaRef.movie(m);
    }
    return unknown;
  }

  Iterable<Series> _findSeries(String title, int? year) => [
    for (final s in _series[_key(title)] ?? const <Series>[])
      if (_sameYear(year ?? yearInTitle(title), s.year ?? yearInTitle(s.name))) s,
  ];

  Future<MediaRef?> _episode(MediaRef r) async {
    final series = _findSeries(r.seriesTitle ?? '', r.year).firstOrNull;
    if (series == null) return null;
    final detail = await (_seriesDetail[series.id] ??= source
        .seriesDetail(series)
        .then<SeriesDetail?>((d) => d)
        .catchError((Object _) => null));
    if (detail == null) return null;
    final episodes = detail.seasons.values.expand((e) => e);
    final episode =
        (r.tmdb == null ? null : episodes.where((e) => e.tmdbId == r.tmdb).firstOrNull) ??
        episodes.where((e) => e.season == r.season && e.number == r.number).firstOrNull;
    return episode == null ? null : MediaRef.episode(detail.series, episode);
  }

  MediaRef? _channel(MediaRef r) {
    final c =
        ((r.epgId ?? '').isEmpty ? null : _liveByEpg[r.epgId!.toLowerCase()]) ??
        _liveByName[looseChannel(r.title, anyScript: true)];
    return c == null ? null : MediaRef.channel(c);
  }

  /// Finds everything in [from] (a library as [Library.stored] returns it) and adds what was found
  /// to the library of [targetPlaylistId] and [profileId].
  Future<MigrationResult> run(
    Map<String, dynamic> from,
    String targetPlaylistId, {
    String profileId = mainProfileId,
  }) async {
    final favorites = <Map<String, dynamic>>[];
    final history = <Map<String, dynamic>>[];
    final missing = <String>[];
    for (final f in from['favorites'] as List? ?? const []) {
      final ref = MediaRef.fromJson(f as Map<String, dynamic>);
      final found = await find(ref);
      found == null ? missing.add(ref.title) : favorites.add(found.toJson());
    }
    for (final h in from['history'] as List? ?? const []) {
      final entry = HistoryEntry.fromJson(h as Map<String, dynamic>);
      final found = await find(entry.ref);
      if (found == null) {
        missing.add(entry.ref.seriesTitle ?? entry.ref.title);
        continue;
      }
      history.add(
        HistoryEntry(
          ref: found,
          position: entry.position,
          duration: entry.duration,
          updated: entry.updated,
          device: entry.device,
        ).toJson(),
      );
    }
    // Favorites count as added now to this list, in the order they had
    final now = DateTime.now().millisecondsSinceEpoch;
    await Library.mergeInto(targetPlaylistId, profileId, {
      'favorites': favorites,
      'favAt': {for (final (i, f) in favorites.indexed) '${f['kind']}:${f['id']}': now - i},
      'history': history,
    });
    return MigrationResult(moved: favorites.length + history.length, missing: missing.toSet().toList());
  }
}
