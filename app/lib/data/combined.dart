import '../device.dart' show lowMemory;
import 'catalog.dart';
import 'epg.dart';
import 'kids.dart';
import 'models.dart';
import 'source.dart';
import 'xtream.dart';

/// Updating a combined playlist when some of its providers did not answer: a catalog without them
/// would take the place of the whole one, their titles gone for the session.
class PartsMissing implements Exception {
  const PartsMissing(this.names);

  final List<String> names;
}

/// One of the providers a combined playlist joins, by the name the user gave its playlist.
typedef CombinedPart = ({String name, ContentSource source});

/// Several providers as one (a playlist the user combined): their channels, movies and series
/// together, each asked of the provider it comes from. A title several of them have is several
/// versions of it ([CatalogData.versionsOf]): one card, every copy on its page, and the player
/// tries the copies fastest first when one does not start.
///
/// Ids carry the provider: "1~2045" is item 2045 of the second one. Categories are named after
/// their provider ("Provider A · Movies 4K"). A provider that cannot be reached leaves the others
/// working.
class CombinedSource implements ContentSource, MovieDetails, KidsFilter, Closable, ListHolder {
  CombinedSource(this.slots) : assert(slots.nonNulls.isNotEmpty);

  /// Its providers in the places the playlist has them: null where one is missing (deleted, or it
  /// did not open). The others keep their places, so the ids saved in favorites and history (and
  /// synced) still point where they did, and not at another provider's.
  final List<CombinedPart?> slots;

  /// The providers there are.
  Iterable<CombinedPart> get parts => slots.nonNulls;

  /// The providers whose lists could not be had the last time they were asked for, by name: a
  /// catalog without them is not the whole one.
  final failed = <String>{};

  static const _sep = '~';

  static String wrap(int part, String id) => '$part$_sep$id';

  /// The provider an id is from, and the id there.
  (ContentSource, String) _unwrap(String id) {
    final i = id.indexOf(_sep);
    final part = i < 0 ? null : int.tryParse(id.substring(0, i));
    final p = part == null || part >= slots.length ? null : slots[part];
    if (p == null) throw const SourceException(SourceError.notFound);
    return (p.source, id.substring(i + 1));
  }

  String? _wrapOrNull(int part, String? id) => id == null ? null : wrap(part, id);
  String? _raw(String? id) => id == null ? null : _unwrap(id).$2;

  /// [ask] of every provider, together, in their order. One that fails is left out; only when all
  /// fail does this fail too.
  Future<List<T>> _all<T>(Future<List<T>> Function(int part, ContentSource s) ask) async {
    Object? error;
    final lists = await Future.wait([
      for (final (i, p) in slots.indexed)
        if (p != null)
          ask(i, p.source)
              .then((l) {
                failed.remove(p.name);
                return l;
              })
              .catchError((Object e) {
                error ??= e;
                failed.add(p.name);
                return <T>[];
              }),
    ]);
    if (error != null && lists.every((l) => l.isEmpty)) throw error!;
    return [for (final l in lists) ...l];
  }

  List<Category> _named(int part, List<Category> cats) => [
    for (final c in cats)
      Category(
        id: wrap(part, c.id),
        name: slots.length > 1 ? '${slots[part]!.name} · ${displayCategoryName(c.name)}' : c.name,
      ),
  ];

  // Categories and lists

  @override
  Future<List<Category>> liveCategories() => _all((i, s) async => _named(i, await s.liveCategories()));

  @override
  Future<List<Category>> movieCategories() => _all((i, s) async => _named(i, await s.movieCategories()));

  @override
  Future<List<Category>> seriesCategories() => _all((i, s) async => _named(i, await s.seriesCategories()));

  @override
  Future<List<LiveChannel>> liveChannels([String? categoryId]) => _list(
    categoryId,
    (s, c) => s.liveChannels(c),
    (i, x) => x.withIds(wrap(i, x.id), _wrapOrNull(i, x.categoryId), epgId: partEpgId(i, x.epgId)),
  );

  @override
  Future<List<Movie>> movies([String? categoryId]) =>
      _list(categoryId, (s, c) => s.movies(c), (i, x) => x.withIds(wrap(i, x.id), _wrapOrNull(i, x.categoryId)));

  @override
  Future<List<Series>> series([String? categoryId]) =>
      _list(categoryId, (s, c) => s.series(c), (i, x) => x.withIds(wrap(i, x.id), _wrapOrNull(i, x.categoryId)));

  /// A category's items, from its provider; or every provider's.
  Future<List<T>> _list<T>(
    String? categoryId,
    Future<List<T>> Function(ContentSource s, String? category) ask,
    T Function(int part, T x) rewrap,
  ) async {
    if (categoryId == null) return _all((i, s) async => [for (final x in await ask(s, null)) rewrap(i, x)]);
    final i = int.tryParse(categoryId.split(_sep).first) ?? -1;
    final p = i < 0 || i >= slots.length ? null : slots[i];
    if (p == null) return const [];
    return [for (final x in await ask(p.source, _raw(categoryId))) rewrap(i, x)];
  }

  // A title in full

  @override
  Future<SeriesDetail> seriesDetail(Series s) async {
    final (source, raw) = _unwrap(s.id);
    final part = int.parse(s.id.split(_sep).first);
    final d = await source.seriesDetail(s.withIds(raw, _raw(s.categoryId)));
    return SeriesDetail(
      series: d.series.withIds(s.id, s.categoryId),
      seasons: {
        for (final MapEntry(key: n, value: episodes) in d.seasons.entries)
          n: [for (final e in episodes) e.withId(wrap(part, e.id))],
      },
      seasonInfo: d.seasonInfo,
    );
  }

  @override
  Future<Movie> movieDetail(Movie m) async {
    final (source, raw) = _unwrap(m.id);
    if (source is! MovieDetails) return m;
    final d = await (source as MovieDetails).movieDetail(m.withIds(raw, _raw(m.categoryId)));
    return d.withIds(m.id, m.categoryId);
  }

  @override
  Future<List<EpgEntry>> shortEpg(LiveChannel c, {int limit = 4}) {
    final (source, raw) = _unwrap(c.id);
    return source.shortEpg(c.withIds(raw, _raw(c.categoryId)), limit: limit);
  }

  /// Every provider's guide as one; where two describe the same channel, the first one's. Read
  /// together, but one after another on a device with little memory: each is tens of MB as it is read.
  @override
  Future<EpgGuide> guide() async {
    Future<EpgGuide> of(int i, CombinedPart p) => p.source.guide().then(
      (g) => identical(g, EpgGuide.failed) ? g : g.numbersOf(i),
      onError: (Object _) => EpgGuide.failed,
    );
    final guides = lowMemory
        ? [
            for (final (i, p) in slots.indexed)
              if (p != null) await of(i, p),
          ]
        : await Future.wait([
            for (final (i, p) in slots.indexed)
              if (p != null) of(i, p),
          ]);
    return EpgGuide.merge(guides);
  }

  // Streams

  @override
  String liveUrl(LiveChannel c) {
    final (source, raw) = _unwrap(c.id);
    return source.liveUrl(c.withIds(raw, _raw(c.categoryId)));
  }

  @override
  String movieUrl(Movie m) {
    final (source, raw) = _unwrap(m.id);
    return source.movieUrl(m.withIds(raw, _raw(m.categoryId)));
  }

  @override
  String episodeUrl(Episode e) {
    final (source, raw) = _unwrap(e.id);
    return source.episodeUrl(e.withId(raw));
  }

  @override
  String? catchupUrl(LiveChannel c, DateTime start, Duration duration) {
    final (source, raw) = _unwrap(c.id);
    return source.catchupUrl(c.withIds(raw, _raw(c.categoryId)), start, duration);
  }

  @override
  Map<String, String> headersFor(String url) {
    for (final p in parts) {
      final h = p.source.headersFor(url);
      if (h.isNotEmpty) return h;
    }
    return const {};
  }

  @override
  bool get hideAdult => parts.first.source.hideAdult;

  @override
  set hideAdult(bool v) {
    for (final p in parts) {
      p.source.hideAdult = v;
    }
  }

  @override
  bool get kidsOnly => parts.any(
    (p) => switch (p.source) {
      final KidsFilter k => k.kidsOnly,
      _ => false,
    },
  );

  @override
  set kidsOnly(bool v) {
    for (final p in parts) {
      if (p.source case final KidsFilter k) k.kidsOnly = v;
    }
  }

  /// The live stream format for every Xtream provider in it.
  set liveFormat(String f) {
    for (final p in parts) {
      if (p.source case final XtreamSource x) x.liveFormat = f;
    }
  }

  @override
  void close() {
    for (final p in parts) {
      if (p.source case final Closable c) c.close();
    }
  }

  @override
  void forgetLists() {
    for (final p in parts) {
      if (p.source case final ListHolder h) h.forgetLists();
    }
  }
}
