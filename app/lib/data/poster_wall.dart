import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../device.dart';
import 'catalog.dart';
import 'image_store.dart';
import 'kids.dart';
import 'source.dart';
import 'trending.dart';

/// Posters for the screens outside a playlist (welcome, who's watching, sync...), so they are not
/// bare black: what is trending this week ([Trending]) when the app has a TMDB key, else the best
/// rated recent movies and series of the playlist opened last, from the provider itself. Never
/// adult content, nor horror: anyone in the family sees these screens.
///
/// The images are kept on disk, so these screens show them at once from the next start on.
class PosterWall {
  PosterWall._();

  /// The provider's posters, best first; empty until a playlist has been opened.
  static final posters = ValueNotifier<List<String>>(const []);

  /// Changes when [wall] may have.
  static final changes = Listenable.merge([posters, Trending.items]);

  /// The posters to show: the trending ones when there are enough, else the provider's.
  static List<String> get wall {
    // Never one rated for adults only: anyone in the family sees these screens
    final trending = [
      for (final t in Trending.items.value)
        if (t.mature == false) ?t.poster,
    ];
    return trending.length >= 8 ? trending : posters.value;
  }

  static const size = 40;
  static const _prefKey = 'posterWall';
  static final _scary = RegExp(
    r'horror|terror|gore|slasher|thriller|suspens|crim|b[eé]lic|guerra|\bwar\b|er[oó]t|adult',
    caseSensitive: false,
  );

  /// Reads the posters noted last time. Call once at startup.
  static Future<void> load() async {
    final saved = (await SharedPreferences.getInstance()).getStringList(_prefKey);
    if (saved != null) posters.value = List.unmodifiable(saved);
    Trending.items.addListener(() => unawaited(_prune()));
  }

  /// Notes the posters of [data], a playlist's catalog. Only from a catalog without adult content
  /// ([adultHidden]): one that shows it could slip some in.
  static Future<void> remember(CatalogData data, {required bool adultHidden}) async {
    if (!adultHidden) return;
    final picked = pick(data);
    if (picked.length < 8 || listEquals(picked, posters.value)) return; // too few for a wall: keep the last
    posters.value = List.unmodifiable(picked);
    await (await SharedPreferences.getInstance()).setStringList(_prefKey, picked);
    unawaited(_prune());
  }

  /// Up to [size] posters of [data]: best rated recent movies and series, then the newest, two
  /// movies for each series. With artwork, without horror, each once.
  @visibleForTesting
  static List<String> pick(CatalogData data) {
    Iterable<String> art<T>(
      Iterable<T> items,
      String? Function(T) url,
      String? Function(T) genre, [
      String? Function(T)? age,
    ]) sync* {
      // Those with a genre first: one without it only makes up the numbers, as nothing vouches for it
      for (final known in [true, false]) {
        for (final i in items) {
          final u = url(i);
          final g = genre(i) ?? '';
          if (g.isNotEmpty != known || u == null || !u.startsWith('http')) continue;
          if (!_scary.hasMatch(g) && !isAdultRating(age?.call(i))) yield u;
        }
      }
    }

    final movies = art(
      data.topMovies.followedBy(data.newReleases).followedBy(data.recentMovies),
      (m) => m.poster,
      (m) => m.genre,
      (m) => m.ageRating,
    ).iterator;
    final series = art(data.topSeries.followedBy(data.recentSeries), (s) => s.cover, (s) => s.genre).iterator;
    final picked = <String>{};
    for (var turn = 0; picked.length < size; turn++) {
      final (first, then) = turn % 3 == 2 ? (series, movies) : (movies, series);
      if (first.moveNext()) {
        picked.add(first.current);
      } else if (then.moveNext()) {
        picked.add(then.current);
      } else {
        break;
      }
    }
    return picked.toList();
  }

  /// The images in memory, the least recently asked for first: up to [_mostInMemory] bytes. Kept,
  /// not read again from the disk, as each read is a new copy that every backdrop would decode anew.
  static final _images = <String, Uint8List>{};
  static var _inMemory = 0;

  /// 16 MB, 4 with little memory: a turn of the welcome's or the screensaver's backdrops is 80 of
  /// them, and a provider's posters may be 2000×3000.
  static int get _mostInMemory => lowMemory ? 4 << 20 : 16 << 20;

  static Uint8List _remember(String url, Uint8List bytes) {
    final old = _images.remove(url);
    if (old != null) _inMemory -= old.length;
    _images[url] = bytes;
    _inMemory += bytes.length;
    while (_inMemory > _mostInMemory && _images.length > 1) {
      final first = _images.keys.first;
      _inMemory -= _images.remove(first)!.length;
    }
    return bytes;
  }

  /// The poster at [url]: from memory, from the disk when fetched before, else from the network.
  /// Null when it cannot be had.
  static Future<Uint8List?> image(String url) async {
    final known = _images[url];
    if (known != null) return _remember(url, known); // now the most recently asked for
    _store.want(url);
    try {
      final bytes = await _store.bytes(url);
      if (!_looksLikeImage(bytes)) {
        _store.forget(url); // an error page sent as a 200: not kept, and left alone a while
        return null;
      }
      return _remember(url, bytes);
    } on ImageUnavailable {
      return null;
    } finally {
      _store.unwant(url);
    }
  }

  /// The wall's own: the same images for every tile and turn asked for once, a few at a time, one
  /// that failed left alone a while, in a folder that the catalog's images do not crowd out.
  static final _store = ImageStore(directory: () => _dir)
    ..maxDownloads = 4
    ..diskBytes = 64 << 20;

  static final Future<Directory?> _dir = () async {
    try {
      return await Directory('${(await getApplicationCacheDirectory()).path}/posters').create(recursive: true);
    } on Object {
      return null; // no platform to ask (tests): no disk cache
    }
  }();

  /// Whether [bytes] start as an image does (JPEG, PNG, GIF, WebP, BMP, AVIF or HEIC), not a page.
  static bool _looksLikeImage(Uint8List bytes) {
    bool at(int i, List<int> sign) {
      if (bytes.length < i + sign.length) return false;
      for (var k = 0; k < sign.length; k++) {
        if (bytes[i + k] != sign[k]) return false;
      }
      return true;
    }

    return at(0, const [0xFF, 0xD8, 0xFF]) ||
        at(0, const [0x89, 0x50, 0x4E, 0x47]) ||
        at(0, 'GIF8'.codeUnits) ||
        at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits) ||
        at(0, 'BM'.codeUnits) ||
        at(4, 'ftyp'.codeUnits);
  }

  /// Deletes the images on disk that are no longer shown: neither the provider's posters nor the
  /// trending posters and backdrops.
  static Future<void> _prune() async {
    final keep = {
      ...posters.value,
      for (final t in Trending.items.value) ...[?t.poster, ?t.backdrop],
    };
    if (keep.isEmpty) return;
    _images.removeWhere((url, bytes) {
      final gone = !keep.contains(url);
      if (gone) _inMemory -= bytes.length;
      return gone;
    });
    final dir = await _dir;
    if (dir == null) return;
    final names = {for (final url in keep) stableHash(url)};
    try {
      for (final f in dir.listSync().whereType<File>()) {
        if (!names.contains(f.uri.pathSegments.last)) f.deleteSync();
      }
    } on FileSystemException {
      // Next time
    }
  }
}
