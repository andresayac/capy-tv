import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../device.dart';
import 'matching.dart';
import 'models.dart';
import 'storage_health.dart';

enum MediaKind { live, movie, series, episode }

/// The profile whose libraries are the ones from before there were profiles (see profiles.dart).
const mainProfileId = 'main';

/// Just enough about an item to show it again and rebuild its stream URL later.
/// URLs are rebuilt through the source (credentials may change); only M3U items keep theirs.
/// Ids belong to the provider; [tmdb], [year] and [epgId] are what finds the same title or
/// channel with another one (see matching.dart).
class MediaRef {
  const MediaRef({
    required this.kind,
    required this.id,
    required this.title,
    this.image,
    this.extension,
    this.url,
    this.seriesId,
    this.seriesTitle,
    this.season,
    this.number,
    this.tmdb,
    this.year,
    this.epgId,
  });

  factory MediaRef.channel(LiveChannel c) =>
      MediaRef(kind: MediaKind.live, id: c.id, title: c.name, image: c.icon, url: c.url, epgId: c.epgId);

  factory MediaRef.movie(Movie m) => MediaRef(
    kind: MediaKind.movie,
    id: m.id,
    title: m.name,
    image: m.poster,
    extension: m.extension,
    url: m.url,
    tmdb: m.tmdbId,
    year: m.year,
  );

  factory MediaRef.series(Series s) =>
      MediaRef(kind: MediaKind.series, id: s.id, title: s.name, image: s.cover, tmdb: s.tmdbId, year: s.year);

  factory MediaRef.episode(Series s, Episode e) => MediaRef(
    kind: MediaKind.episode,
    id: e.id,
    title: e.cleanTitle(s.name),
    image: e.image ?? s.backdrop ?? s.cover,
    extension: e.extension,
    seriesId: s.id,
    seriesTitle: s.name,
    season: e.season,
    number: e.number,
    tmdb: e.tmdbId,
    year: s.year, // the series' year, to find the series again
  );

  factory MediaRef.fromJson(Map<String, dynamic> j) => MediaRef(
    kind: MediaKind.values.asNameMap()[j['kind']] ?? (throw const FormatException('A kind this version does not know')),
    id: j['id'] as String,
    title: j['title'] as String,
    image: j['image'] as String?,
    extension: j['ext'] as String?,
    url: j['url'] as String?,
    seriesId: j['seriesId'] as String?,
    seriesTitle: j['seriesTitle'] as String?,
    season: j['season'] as int?,
    number: j['number'] as int?,
    tmdb: j['tmdb'] as String?,
    year: j['year'] as int?,
    epgId: j['epg'] as String?,
  );

  final MediaKind kind;
  final String id, title;
  final String? image, extension, url;
  final String? seriesId, seriesTitle; // episodes only
  final int? season, number; // episodes only
  final String? tmdb, epgId;
  final int? year;

  String get key => '${kind.name}:$id';

  MediaRef withTmdb(String tmdb) => MediaRef(
    kind: kind,
    id: id,
    title: title,
    image: image,
    extension: extension,
    url: url,
    seriesId: seriesId,
    seriesTitle: seriesTitle,
    season: season,
    number: number,
    tmdb: tmdb,
    year: year,
    epgId: epgId,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'id': id,
    'title': title,
    'image': ?image,
    'ext': ?extension,
    'url': ?url,
    'seriesId': ?seriesId,
    'seriesTitle': ?seriesTitle,
    'season': ?season,
    'number': ?number,
    'tmdb': ?tmdb,
    'year': ?year,
    'epg': ?epgId,
  };

  LiveChannel toChannel() => LiveChannel(id: id, name: title, icon: image, url: url);
  Movie toMovie() => Movie(id: id, name: title, poster: image, extension: extension ?? 'mp4', url: url);
  Series toSeries() =>
      Series(id: seriesId ?? id, name: seriesTitle ?? title, cover: kind == MediaKind.series ? image : null);
  Episode toEpisode() =>
      Episode(id: id, season: season ?? 0, number: number ?? 0, title: title, extension: extension ?? 'mp4');
}

class HistoryEntry {
  const HistoryEntry({
    required this.ref,
    required this.position,
    required this.duration,
    required this.updated,
    this.device,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
    ref: MediaRef.fromJson(j['ref'] as Map<String, dynamic>),
    position: Duration(milliseconds: j['pos'] as int),
    duration: Duration(milliseconds: j['dur'] as int),
    updated: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
    device: j['dev'] as String?,
  );

  final MediaRef ref;
  final Duration position, duration;
  final DateTime updated;

  /// The device it was watched on, as it calls itself; null when saved before devices were noted.
  final String? device;

  double get progress =>
      duration.inMilliseconds <= 0 ? 0 : (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);

  /// Seen for real, not only opened: a fifth of it, or ten minutes. A channel never is.
  bool get watched => ref.kind != MediaKind.live && (progress >= 0.2 || position >= const Duration(minutes: 10));

  /// Worth offering "continue": started for real and not (almost) finished.
  bool get resumable => ref.kind != MediaKind.live && position >= const Duration(seconds: 30) && progress < 0.95;

  Map<String, dynamic> toJson() => {
    'ref': ref.toJson(),
    'pos': position.inMilliseconds,
    'dur': duration.inMilliseconds,
    'at': updated.millisecondsSinceEpoch,
    'dev': ?device,
  };
}

/// The same thing changed at the same moment on two devices, as [a] and [b]: whether [a] is the one
/// kept. Every device settles it the same way. The fuller one wins, having all the other has and
/// more: a device on an older version of the app sends back what it got without what it does not
/// know, and must not take that away from the others. Else, the one that sorts last.
bool keepsOver(Map<String, dynamic> a, Map<String, dynamic>? b) {
  if (b == null) return true;
  if (a.length != b.length && (a.keys.toSet().containsAll(b.keys) || b.keys.toSet().containsAll(a.keys))) {
    return a.length > b.length;
  }
  return Library._byText(a, b);
}

/// Favorites and watch history of one playlist for one profile, stored on the device.
///
/// Two devices can change the same library apart and merge later (backups, account sync), so
/// every change carries a time: favorites keep when they were added, and removing a favorite,
/// forgetting an item or clearing the history leave a dated marker instead of just vanishing.
/// For each item the latest event wins, which makes merging give the same result in any order.
class Library extends ChangeNotifier {
  Library._(this.playlistId, this.profileId, Map<String, dynamic> j) {
    _absorb(j);
  }

  @visibleForTesting
  Library.fromJson(Map<String, dynamic> j, {String playlistId = 'test', String profileId = mainProfileId})
    : this._(playlistId, profileId, j);

  /// Movies and episodes kept in the history.
  static const maxHistory = 80;

  /// Channels kept in the history, apart: zapping does not push titles out.
  static const maxLive = 30;

  /// Markers this much older than the library's latest event are dropped; a device offline for
  /// longer may bring back what they hid.
  static const _markerAge = Duration(days: 180);

  /// Fires whenever a library is saved, so sync can send it. Progress noted during playback is
  /// [quiet]: it can wait a while.
  static final saved = StreamController<({String playlistId, String profileId, bool quiet})>.broadcast(sync: true);

  static String _prefKey(String playlistId, String profileId) =>
      profileId == mainProfileId ? 'library.$playlistId' : 'library.$playlistId@$profileId';

  static Future<Library> load(String playlistId, String profileId) async =>
      Library._(playlistId, profileId, await stored(playlistId, profileId) ?? const <String, dynamic>{});

  /// Deletes every library of a profile on this device.
  static Future<void> dropProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().where((k) => k.startsWith('library.') && k.endsWith('@$profileId'))) {
      await prefs.remove(k);
    }
    await dropTraces(profileId);
  }

  /// A profile's searches and AI picks, which tell what it watched as well as its history does.
  static Future<void> dropTraces(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().where(
      (k) => (k.startsWith('ai.picks.') && k.endsWith('.$profileId')) || k == 'search.recent.$profileId',
    )) {
      await prefs.remove(k);
    }
  }

  final String playlistId, profileId;
  final _favorites = <MediaRef>[]; // newest first
  final _favoriteAdded = <String, int>{}; // key → when it was added (ms)
  final _unfavorited = <String, int>{}; // key → when it stopped being a favorite
  final _history = <HistoryEntry>[]; // most recent first
  final _forgotten = <String, int>{}; // key → when it was removed from the history
  var _cleared = 0; // when the whole history was cleared

  /// What is stored for [playlistId] and [profileId], as saved (for backups and sync).
  static Future<Map<String, dynamic>?> stored(String playlistId, String profileId) async {
    final raw = (await SharedPreferences.getInstance()).getString(_prefKey(playlistId, profileId));
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Merges a library from elsewhere ([data] as [stored] returns it) into the library of
  /// [playlistId] and [profileId]. If that library is open, it is merged live, so its next save
  /// keeps both. Returns the merged library as stored.
  /// Throws if [data] would not read as a library: to know before taking anything of a backup.
  static void check(Map<String, dynamic> data) => Library._('check', mainProfileId, data);

  static Future<Map<String, dynamic>> mergeInto(String playlistId, String profileId, Map<String, dynamic> data) async {
    final open = currentLibrary.value;
    final library = open != null && open.playlistId == playlistId && open.profileId == profileId
        ? open
        : await Library.load(playlistId, profileId);
    final before = jsonEncode(library.toJson());
    library._absorb(data);
    if (jsonEncode(library.toJson()) != before) await library._save();
    return library.toJson();
  }

  @visibleForTesting
  void merge(Map<String, dynamic> data) => _absorb(data);

  /// One entry, or null when a newer version wrote something this one cannot read: only that goes.
  static T? _tryRead<T>(T Function() read) {
    try {
      return read();
    } on Object {
      return null;
    }
  }

  void _absorb(Map<String, dynamic> j) {
    final favorites = [
      for (final f in j['favorites'] as List? ?? const [])
        ?_tryRead(() => MediaRef.fromJson(f as Map<String, dynamic>)),
    ];
    final added = _times(j['favAt']);
    // Saved before favorites had times: keep their order, older than anything with a time
    for (var i = 0; i < favorites.length; i++) {
      added.putIfAbsent(favorites[i].key, () => favorites.length - i);
    }
    final pool = {for (final f in _favorites) f.key: f};
    for (final f in favorites) {
      final theirs = added[f.key]!, mine = _favoriteAdded[f.key] ?? -1;
      if (theirs > mine || (theirs == mine && _wins(f.toJson(), pool[f.key]?.toJson()))) {
        pool[f.key] = f;
        _favoriteAdded[f.key] = theirs;
      }
    }
    _latest(_unfavorited, _times(j['unfav']));
    _latest(_forgotten, _times(j['forgot']));
    _cleared = max(_cleared, (j['cleared'] as num?)?.toInt() ?? 0);
    final byKey = {for (final h in _history) h.ref.key: h};
    for (final x in j['history'] as List? ?? const []) {
      final h = _tryRead(() => HistoryEntry.fromJson(x as Map<String, dynamic>));
      if (h == null) continue;
      final mine = byKey[h.ref.key];
      if (mine == null || _newer(h, mine)) byKey[h.ref.key] = h;
    }
    _settle(pool.values, byKey.values);
  }

  /// Rebuilds what is shown from everything known: the latest event per item wins. Depends only
  /// on what is known, never on this device's clock, so every device settles the same way.
  void _settle(Iterable<MediaRef> favorites, Iterable<HistoryEntry> history) {
    final fav = [
      for (final f in favorites)
        if ((_favoriteAdded[f.key] ?? 0) > (_unfavorited[f.key] ?? -1)) f,
    ];
    _favorites
      ..clear()
      ..addAll(fav);
    final shown = {for (final f in fav) f.key};
    _favoriteAdded.removeWhere((k, _) => !shown.contains(k));
    _unfavorited.removeWhere((k, _) => shown.contains(k)); // added again since
    final kept = [
      for (final h in history)
        if (h.updated.millisecondsSinceEpoch > max(_cleared, _forgotten[h.ref.key] ?? 0)) h,
    ];
    _history
      ..clear()
      ..addAll(kept);
    _sort();
    _trim();
    final watched = {for (final h in _history) h.ref.key};
    _forgotten.removeWhere((k, at) => watched.contains(k) || at <= _cleared);
    final oldest = _latestEvent - _markerAge.inMilliseconds;
    _unfavorited.removeWhere((_, at) => at < oldest);
    _forgotten.removeWhere((_, at) => at < oldest);
  }

  /// Keeps the newest [maxHistory] titles and [maxLive] channels (the history is newest first). A
  /// series is one title, with its last [episodesKept] episodes: a soap opera's eighty chapters
  /// would push every movie out. By series id, as the TV does, or the two would trim differently
  /// and send each other their histories without end.
  void _trim() {
    var titles = 0, channels = 0;
    final kept = <String, int>{}; // episodes kept of each series; 0 for a series left out
    _history.retainWhere((h) {
      if (h.ref.kind == MediaKind.live) return channels++ < maxLive;
      final series = h.ref.kind == MediaKind.episode ? h.ref.seriesId : null;
      final n = series == null ? null : kept[series];
      if (n != null) {
        if (n == 0 || n >= episodesKept) return false;
        kept[series!] = n + 1;
        return true;
      }
      final ok = titles++ < maxHistory;
      if (series != null) kept[series] = ok ? 1 : 0;
      return ok;
    });
  }

  static const episodesKept = 5;

  /// Favorites and history newest first; the same moment goes by key.
  void _sort() {
    _favorites.sort((a, b) => _latestFirst(_favoriteAdded[a.key]!, a.key, _favoriteAdded[b.key]!, b.key));
    _history.sort(
      (a, b) => _latestFirst(a.updated.millisecondsSinceEpoch, a.ref.key, b.updated.millisecondsSinceEpoch, b.ref.key),
    );
  }

  int get _latestEvent => [
    _cleared,
    ..._favoriteAdded.values,
    ..._unfavorited.values,
    ..._forgotten.values,
    for (final h in _history) h.updated.millisecondsSinceEpoch,
  ].reduce(max);

  static bool _newer(HistoryEntry a, HistoryEntry b) =>
      a.updated != b.updated ? a.updated.isAfter(b.updated) : _wins(a.toJson(), b.toJson());

  static bool _wins(Map<String, dynamic> a, Map<String, dynamic>? b) => keepsOver(a, b);

  static bool _byText(Map<String, dynamic> a, Map<String, dynamic>? b) =>
      b == null || jsonEncode(a).compareTo(jsonEncode(b)) > 0;

  static int _latestFirst(int at1, String k1, int at2, String k2) => at1 != at2 ? at2.compareTo(at1) : k1.compareTo(k2);

  static Map<String, int> _times(Object? j) => {
    for (final MapEntry(:key, :value) in (j as Map? ?? const {}).entries) key as String: (value as num).toInt(),
  };

  static void _latest(Map<String, int> into, Map<String, int> from) {
    for (final MapEntry(:key, :value) in from.entries) {
      if (value > (into[key] ?? -1)) into[key] = value;
    }
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  List<MediaRef> favorites(MediaKind kind) => _favorites.where((f) => f.kind == kind).toList();

  /// [r] in My list: itself, or another copy of its title (another language or quality).
  bool isFavorite(MediaRef r) => _favoriteCopy(r) != null;

  MediaRef? _favoriteCopy(MediaRef r) {
    if (_favoriteAdded.containsKey(r.key)) return r;
    if (r.kind == MediaKind.live) return null;
    final title = titleKey(r);
    return _favorites.where((f) => f.kind == r.kind && titleKey(f) == title).firstOrNull;
  }

  /// Adds [r] to My list, or takes it out: the copy of its title there, whichever it is.
  Future<void> toggleFavorite(MediaRef r) async {
    if (_favoriteCopy(r) case final copy?) {
      _favorites.removeWhere((f) => f.key == copy.key);
      // After its own marker, which a device whose clock runs ahead may have put in the future
      _unfavorited[copy.key] = max(_now(), (_favoriteAdded.remove(copy.key) ?? 0) + 1);
    } else {
      // After any marker from another device whose clock runs ahead
      _favoriteAdded[r.key] = max(_now(), (_unfavorited.remove(r.key) ?? 0) + 1);
      _favorites.insert(0, r);
    }
    await _save();
  }

  List<HistoryEntry> get history => List.unmodifiable(_history);

  /// Everything this library refers to: favorites, then history.
  Iterable<MediaRef> get refs => [..._favorites, for (final h in _history) h.ref];

  /// Swaps in a better described [r] (same item, say now with its TMDB id) wherever it appears.
  /// Its times move on by a millisecond, so this version wins over the old one when merging.
  Future<void> updateRef(MediaRef r) async {
    for (var i = 0; i < _favorites.length; i++) {
      if (_favorites[i].key == r.key) {
        _favorites[i] = r;
        _favoriteAdded[r.key] = _favoriteAdded[r.key]! + 1;
      }
    }
    for (var i = 0; i < _history.length; i++) {
      final h = _history[i];
      if (h.ref.key == r.key) {
        final at = h.updated.add(const Duration(milliseconds: 1));
        _history[i] = HistoryEntry(ref: r, position: h.position, duration: h.duration, updated: at, device: h.device);
      }
    }
    await _save();
  }

  /// Where [r] was left: itself, or else the latest copy of its title watched (a movie started in
  /// one language goes on in another from there).
  HistoryEntry? entry(MediaRef r) {
    final own = _history.where((h) => h.ref.key == r.key).firstOrNull;
    if (own != null || r.kind == MediaKind.live || r.kind == MediaKind.series) return own;
    final title = titleKey(r);
    return _history.where((h) => h.ref.kind == r.kind && titleKey(h.ref) == title).firstOrNull;
  }

  /// Most recent resumable item per title: a series appears once, with its latest episode, and a
  /// title watched in two copies once too.
  List<HistoryEntry> get continueWatching {
    final seen = <String>{};
    return [
      for (final h in _history)
        // A series by its latest episode: one finished after it was left means it was not left there
        if (seen.add(h.ref.kind == MediaKind.episode ? seriesKey(h.ref) : titleKey(h.ref)) && h.resumable) h,
    ];
  }

  /// What was left half watched on another device a short while ago, to go on with here: the
  /// latest title watched anywhere, when that was elsewhere, within [within] of [now].
  HistoryEntry? leftElsewhere({required String here, DateTime? now, Duration within = const Duration(hours: 12)}) {
    final h = _history.where((h) => h.ref.kind != MediaKind.live).firstOrNull;
    if (h == null || !h.resumable || h.device == null || h.device == here) return null;
    final ago = (now ?? DateTime.now()).difference(h.updated);
    return ago > within || ago < const Duration(minutes: -5) ? null : h; // a clock a bit ahead is fine
  }

  /// Latest episode watched of a series, finished or not.
  HistoryEntry? lastEpisodeOf(String seriesId) =>
      _history.where((h) => h.ref.kind == MediaKind.episode && h.ref.seriesId == seriesId).firstOrNull;

  List<MediaRef> recent(MediaKind kind) => [
    for (final h in _history)
      if (h.ref.kind == kind) h.ref,
  ];

  /// Records that [r] was watched up to [position]; moves it to the top of the history. [quiet]
  /// for the progress noted every few seconds during playback.
  Future<void> record(
    MediaRef r, {
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    bool quiet = false,
    String? device,
  }) async {
    // Strictly after the latest entry and after any marker from a device whose clock runs ahead
    final latest = _history.firstOrNull?.updated.millisecondsSinceEpoch ?? 0;
    final at = max(_now(), [latest, _cleared, _forgotten.remove(r.key) ?? 0].reduce(max) + 1);
    _history.removeWhere((h) => h.ref.key == r.key);
    _history.insert(
      0,
      HistoryEntry(
        ref: r,
        position: position,
        duration: duration,
        updated: DateTime.fromMillisecondsSinceEpoch(at),
        device: device ?? deviceName,
      ),
    );
    _trim();
    await _save(quiet: quiet);
  }

  /// Takes [r] off Continue watching: every copy of a movie, and of a series the episodes left
  /// half watched (the finished ones say where it is up to).
  Future<void> forget(MediaRef r) async {
    bool goes(HistoryEntry h) => r.kind == MediaKind.episode
        ? h.ref.kind == MediaKind.episode && seriesKey(h.ref) == seriesKey(r) && h.resumable
        : h.ref.kind == r.kind && titleKey(h.ref) == titleKey(r);
    for (final h in _history.where(goes).toList()) {
      _forgotten[h.ref.key] = max(_now(), h.updated.millisecondsSinceEpoch + 1);
    }
    _history.removeWhere(goes);
    await _save();
  }

  /// When the whole history was last cleared (ms), here or on another device; 0 for never.
  int get clearedAt => _cleared;

  Future<void> clearHistory() async {
    final latest = _history.firstOrNull?.updated.millisecondsSinceEpoch ?? 0;
    _history.clear();
    _cleared = max(_now(), latest + 1);
    _forgotten.clear();
    await _save();
  }

  /// Nothing left of it, here or on other devices: its profile's PIN was forgotten, and whoever
  /// opens it next must not find what was watched.
  Future<void> forgetAll() async {
    for (final f in _favorites) {
      _unfavorited[f.key] = max(_now(), (_favoriteAdded.remove(f.key) ?? 0) + 1);
    }
    _favorites.clear();
    await clearHistory();
  }

  /// As stored. Maps are sorted so the same library always encodes the same way.
  Map<String, dynamic> toJson() {
    Map<String, int> sorted(Map<String, int> m) => {for (final k in m.keys.toList()..sort()) k: m[k]!};
    return {
      'favorites': [for (final f in _favorites) f.toJson()],
      'favAt': sorted(_favoriteAdded),
      'unfav': sorted(_unfavorited),
      'history': [for (final h in _history) h.toJson()],
      'forgot': sorted(_forgotten),
      'cleared': _cleared,
    };
  }

  /// A [quiet] save (progress noted during playback) tells no screen: the ones under the player
  /// would be rebuilt every few seconds for a card nobody sees. Leaving the player saves again.
  Future<void> _save({bool quiet = false}) async {
    _sort();
    if (!quiet) notifyListeners();
    await saveOrFlag(
      (await SharedPreferences.getInstance()).setString(_prefKey(playlistId, profileId), jsonEncode(toJson())),
    );
    saved.add((playlistId: playlistId, profileId: profileId, quiet: quiet));
  }
}

/// Library of the playlist currently open; null while on the playlists screen.
final currentLibrary = ValueNotifier<Library?>(null);

/// Exposes [currentLibrary] above the Navigator, so pushed routes (details, player) see it too,
/// and rebuilds dependents when it changes.
class LibraryScope extends InheritedNotifier<Library> {
  const LibraryScope({super.key, required Library? library, required super.child}) : super(notifier: library);

  static Library? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LibraryScope>()?.notifier;

  static Library of(BuildContext context) => maybeOf(context)!;
}
