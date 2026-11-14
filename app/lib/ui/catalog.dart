import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import '../data/catalog.dart';
import '../data/models.dart';
import '../data/profiles.dart';
import '../data/settings.dart';
import '../data/source.dart';
import '../data/trending.dart';
import '../device.dart';
import '../player/play.dart';
import 'common.dart';
import 'detail_screens.dart';
import 'preview.dart';
import 'theme.dart';
import 'trailer.dart';

/// What browsing needs to show a movie or a series.
abstract class CatalogItem {
  const factory CatalogItem({
    required String id,
    required String title,
    required void Function(BuildContext context) open,
    String? poster,
    String? backdrop,
    Future<String?> Function()? loadBackdrop,
    double? rating,
    int? year,
    String? plot,
    List<String> genres,
    void Function(BuildContext context)? play,
    Future<String?> Function()? trailer,
    String? note,
  }) = _Item;

  const CatalogItem._();

  // A provider's movie or series as it is: a category's rail may hold thousands of them, most never
  // on screen, so what a card shows and does is worked out from it when asked for
  factory CatalogItem.movie(ContentSource source, Movie m) = _MovieItem;
  factory CatalogItem.series(ContentSource source, Series s) = _SeriesItem;

  String get id;
  String get title;
  String? get poster;
  String? get backdrop;
  String? get plot;
  Future<String?> Function()? get loadBackdrop;
  double? get rating;
  int? get year;
  List<String> get genres;
  void Function(BuildContext context) get open; // details page
  void Function(BuildContext context)? get play; // direct playback, movies only

  /// The YouTube id of a trailer the hero plays behind the page, if any.
  Future<String?> Function()? get trailer;

  /// A line under the poster in rails, such as why it was picked for someone.
  String? get note;

  CatalogItem withNote(String? note) => CatalogItem(
    id: id,
    title: title,
    open: open,
    poster: poster,
    backdrop: backdrop,
    loadBackdrop: loadBackdrop,
    rating: rating,
    year: year,
    plot: plot,
    genres: genres,
    play: play,
    trailer: trailer,
    note: note,
  );

  /// This item with [trend]'s backdrop and synopsis where it lacks its own, and its trailer.
  CatalogItem withTrend(Trend trend) => CatalogItem(
    id: id,
    title: title,
    open: open,
    poster: poster,
    backdrop: trend.backdrop ?? backdrop,
    loadBackdrop: trend.backdrop == null ? loadBackdrop : null,
    rating: rating,
    year: year,
    plot: plot ?? trend.overview,
    genres: genres,
    play: play,
    trailer: () => Trending.trailer(trend),
  );
}

class _Item extends CatalogItem {
  const _Item({
    required this.id,
    required this.title,
    required this.open,
    this.poster,
    this.backdrop,
    this.loadBackdrop,
    this.rating,
    this.year,
    this.plot,
    this.genres = const [],
    this.play,
    this.trailer,
    this.note,
  }) : super._();

  @override
  final String id;
  @override
  final String title;
  @override
  final String? poster, backdrop, plot;
  @override
  final Future<String?> Function()? loadBackdrop;
  @override
  final double? rating;
  @override
  final int? year;
  @override
  final List<String> genres;
  @override
  final void Function(BuildContext context) open;
  @override
  final void Function(BuildContext context)? play;
  @override
  final Future<String?> Function()? trailer;
  @override
  final String? note;
}

class _MovieItem extends CatalogItem {
  const _MovieItem(this._source, this._m) : super._();

  final ContentSource _source;
  final Movie _m;

  @override
  String get id => 'movie:${_m.id}';
  @override
  String get title => _m.name;
  @override
  String? get poster => _m.poster;
  @override
  String? get backdrop => _m.backdrop;
  @override
  String? get plot => _m.plot;
  @override
  double? get rating => _m.rating;
  @override
  int? get year => _m.year;
  @override
  List<String> get genres => _m.genres;
  @override
  String? get note => null;

  // Movie listings carry no backdrop; the full record does
  @override
  Future<String?> Function()? get loadBackdrop => switch (_source) {
    final MovieDetails details => () {
      final kept = _backdrops[details] ??= {};
      return kept[_m.id] ??= details
          .movieDetail(_m)
          .then(
            (d) => d.backdrop,
            onError: (Object _) {
              kept.remove(_m.id); // asked again next time: it may have been the line
              return null;
            },
          );
    },
    _ => null,
  };

  @override
  void Function(BuildContext context) get open =>
      (c) => Navigator.of(c).push(
        MaterialPageRoute(
          builder: (_) => MovieDetailScreen(source: _source, movie: _m),
        ),
      );

  // With its other versions, should this one fail
  @override
  void Function(BuildContext context) get play =>
      (c) => playQueue(c, [movieItem(_source, _m)]);

  @override
  Future<String?> Function() get trailer =>
      () => movieTrailer(_source, _m);
}

class _SeriesItem extends CatalogItem {
  const _SeriesItem(this._source, this._s) : super._();

  final ContentSource _source;
  final Series _s;

  @override
  String get id => 'series:${_s.id}';
  @override
  String get title => _s.name;
  @override
  String? get poster => _s.cover;
  @override
  String? get backdrop => _s.backdrop;
  @override
  String? get plot => _s.plot;
  @override
  double? get rating => _s.rating;
  @override
  int? get year => _s.year;
  @override
  List<String> get genres => _s.genres;
  @override
  String? get note => null;
  @override
  Future<String?> Function()? get loadBackdrop => null;

  @override
  void Function(BuildContext context) get open =>
      (c) => Navigator.of(c).push(
        MaterialPageRoute(
          builder: (_) => SeriesDetailScreen(source: _source, series: _s),
        ),
      );

  @override
  void Function(BuildContext context)? get play => null;

  @override
  Future<String?> Function() get trailer =>
      () => seriesTrailer(_s);
}

/// Movie backdrops fetched for the hero, kept for as long as their playlist is: by the source,
/// as ids are each provider's (another playlist's movie 12 is another movie).
final _backdrops = Expando<Map<String, Future<String?>>>();

enum CatalogKind { movies, series }

/// Movies or series: featured carousel, genres, curated rows from the whole catalog, then
/// the provider's own categories.
class CatalogTab extends StatefulWidget {
  const CatalogTab({super.key, required this.kind, required this.source, required this.catalog});

  final CatalogKind kind;
  final ContentSource source;
  final Catalog catalog;

  @override
  State<CatalogTab> createState() => _CatalogTabState();
}

class _CatalogTabState extends State<CatalogTab> with AutomaticKeepAliveClientMixin {
  // One request per provider category, shared by its row and "See all"; each title once
  final _cache = <String, Future<List<CatalogItem>>>{};

  // The whole catalog, once in: its hero, genres and rows are then items of the list, each built
  // as it comes into sight rather than all at once with their posters
  late CatalogData? _data = widget.catalog.loaded;

  @override
  void didUpdateWidget(CatalogTab old) {
    super.didUpdateWidget(old);
    if (old.catalog != widget.catalog) _data = widget.catalog.loaded;
  }

  bool get _movies => widget.kind == CatalogKind.movies;

  Future<List<CatalogItem>> _category(String id) {
    if (_cache[id] case final kept?) return kept;
    final f = _cache[id] = _load(id);
    // A failure is not kept: Retry asks again
    f.catchError((Object _) {
      if (_cache[id] == f) _cache.remove(id);
      return const <CatalogItem>[];
    });
    return f;
  }

  Future<List<CatalogItem>> _load(String id) async {
    if (_movies) {
      final movies = await widget.source.movies(id);
      return [for (final m in oneOfEachTitle(movies, widget.catalog.loaded)) CatalogItem.movie(widget.source, m)];
    }
    final series = await widget.source.series(id);
    return [for (final s in oneOfEachTitle(series, widget.catalog.loaded)) CatalogItem.series(widget.source, s)];
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AsyncView<List<Category>>(
      load: _movies ? widget.source.movieCategories : widget.source.seriesCategories,
      // Hiding adult content, the categories wait for the whole list too
      loading: const Center(child: ListLoading()),
      // A playlist without any (an M3U has no series): said, rather than a black tab
      isEmpty: (cats) => cats.isEmpty,
      empty: _movies ? context.l10n.noMoviesInPlaylist : context.l10n.noSeriesInPlaylist,
      builder: (context, cats) {
        final curated = switch (_data) {
          final data? => _curated(context, widget.kind, widget.source, data),
          null => null,
        };
        final top = curated?.length ?? 1;
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 120),
          itemCount: top + cats.length,
          // The provider's rows keep what they show when the catalog's come in above them
          findChildIndexCallback: (key) {
            if (key case ValueKey<(String,)>(value: (final id,))) {
              final i = cats.indexWhere((c) => c.id == id);
              if (i >= 0) return top + i;
            }
            return null;
          },
          itemBuilder: (context, i) {
            if (curated != null && i < top) return curated[i](context);
            if (i == 0) {
              return AsyncView<CatalogData>(
                load: widget.catalog.load,
                loading: const _HeroSkeleton(),
                builder: (context, data) {
                  // In (a retry included): its parts take this place, in the next frame
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _data == null) setState(() => _data = data);
                  });
                  return const _HeroSkeleton();
                },
              );
            }
            final cat = cats[i - top];
            final name = categoryLabel(context.l10n, cat.name);
            return SafeArea(
              key: ValueKey((cat.id,)),
              top: false,
              bottom: false,
              child: _LoadedRail(
                title: name,
                load: () => _category(cat.id),
                onSeeAll: (items) => openItemGrid(context, name, items),
              ),
            );
          },
        );
      },
    );
  }
}

void openItemGrid(BuildContext context, String title, List<CatalogItem> items, {String? order}) => Navigator.of(context)
    .push(
      MaterialPageRoute(
        builder: (_) => ItemGridScreen(title: title, items: items, order: order),
      ),
    );

/// Hero, genres and the rows computed from the full catalog: a builder for each, as items of the
/// tab's list. A row's items are made when it is built, not before.
List<WidgetBuilder> _curated(BuildContext context, CatalogKind kind, ContentSource source, CatalogData data) {
  final l = context.l10n;
  final movies = kind == CatalogKind.movies;
  List<CatalogItem> m(Iterable<Movie> list) => [for (final x in list) CatalogItem.movie(source, x)];
  List<CatalogItem> s(Iterable<Series> list) => [for (final x in list) CatalogItem.series(source, x)];
  final featured = movies ? m(data.featuredMovies) : s(data.featuredSeries);
  final genres = (movies ? data.movieGenres : data.seriesGenres).take(CatalogData.genresShown).toList();
  // Clear of a phone's cutout, but the hero, which goes under it
  Widget clear(Widget child) => SafeArea(top: false, bottom: false, child: child);
  // Each row: its title, the 60 its rail shows, and all of them for "See all" (worked out then)
  WidgetBuilder? row<T>(String title, List<T> all, List<CatalogItem> Function(Iterable<T>) make) => all.isEmpty
      ? null
      : (context) => clear(
          ItemRail(title: title, items: make(all.take(60)), onSeeAll: () => openItemGrid(context, title, make(all))),
        );
  return [
    if (featured.isNotEmpty) (_) => HeroCarousel(items: featured, label: movies ? l.movies : l.series),
    if (genres.isNotEmpty)
      (context) => clear(
        ChipBar(
          genres: genres,
          onTap: (g) => openItemGrid(context, g, movies ? m(data.moviesIn(g)) : s(data.seriesIn(g))),
        ),
      ),
    (context) => clear(
      ValueListenableBuilder(
        valueListenable: Trending.items,
        builder: (context, trends, _) {
          final title = movies ? l.mostWatchedMovies : l.mostWatchedSeries;
          final items = [
            for (final x in Trending.ofKind(
              data,
              series: !movies,
              trends: trends,
              forKids: ProfileStore.instance.current.kids,
            ))
              x is Movie ? CatalogItem.movie(source, x) : CatalogItem.series(source, x as Series),
          ];
          return items.length < RankedRail.minimum
              ? const SizedBox.shrink()
              : RankedRail(title: title, items: items, onSeeAll: () => openItemGrid(context, title, items));
        },
      ),
    ),
    ...[
      if (movies) ...[
        row(l.recentlyAdded, data.recentMovies, m),
        row(l.topRated, data.topMovies, m),
        row(l.newReleases, data.newReleases, m),
        for (final g in genres.take(5)) row(g, data.moviesIn(g), m),
      ] else ...[
        row(l.newEpisodes, data.recentSeries, s),
        row(l.topRated, data.topSeries, s),
        for (final g in genres.take(5)) row(g, data.seriesIn(g), s),
      ],
    ].nonNulls,
  ];
}

/// A row of chips to tap, such as genres or recent searches.
class ChipBar extends StatelessWidget {
  const ChipBar({super.key, required this.genres, required this.onTap});

  final List<String> genres;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    // Taller with larger text, so a label is never cut
    height: 46 + MediaQuery.textScalerOf(context).scale(20),
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(21, 14, 24, 6),
      children: [
        for (final g in genres)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Focusable(
              radius: AppRadius.button,
              scale: 1.03,
              onTap: () => onTap(g),
              child: Container(
                color: AppColors.surfaceHigh,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(g, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ),
      ],
    ),
  );
}

double _heroHeight(BuildContext context) {
  final height = MediaQuery.sizeOf(context).height;
  // Larger text needs a taller box, or its Play button ends up outside it, drawn but untouchable
  final text = _textGrowth(context);
  if (isShort(context)) return (height * 0.74 * text).clamp(260.0, 380.0 * text); // rows peeking
  return isWide(context) ? (height * 0.68 * text).clamp(420.0, 640.0 * text) : 520 * text;
}

/// How much larger the system's text is than usual, within what a hero can grow by.
double _textGrowth(BuildContext context) => MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);

class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();

  // Focusable while the catalog loads, so a remote entering the tab waits here instead of landing
  // on a row further down that the hero then pushes off screen; the hero's main button takes over
  @override
  Widget build(BuildContext context) => Focus(
    child: SizedBox(
      height: _heroHeight(context),
      child: const Center(child: ListLoading()),
    ),
  );
}

/// Featured titles, one at a time, advancing on their own.
class HeroCarousel extends StatefulWidget {
  const HeroCarousel({super.key, required this.items, required this.label, this.topInset = 0});

  /// What lies over its top (Home's title): its text stays below it.
  final double topInset;

  final List<CatalogItem> items;
  final String label;

  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<HeroCarousel> {
  final _pages = PageController();
  var _index = 0;
  Timer? _timer;
  DateTime _touched = DateTime(0);
  var _focused = false; // a TV's remote is on the hero's buttons
  var _shownAt = DateTime.now(); // when the page on screen came
  var _trailer = false; // the page's trailer is playing
  var _paused = false; // asked to stand still, with its button
  var _noTrailer = false; // the page's trailer cannot play

  static const _page = Duration(seconds: 8);
  static const _waitForTrailer = Duration(seconds: 14); // its delay and its loading

  @override
  void initState() {
    super.initState();
    // Come in once the catalog did, above what already had the remote (Continue watching): that
    // is pushed down by the hero's height, nearly off the screen, and brought back into view
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (!mounted || focused == null || !focused.mounted) return;
      // The page's own scroll, not the row's the focused card may be in
      final page = Scrollable.maybeOf(context, axis: Axis.vertical);
      if (page != null && Scrollable.maybeOf(focused, axis: Axis.vertical) == page) {
        Scrollable.ensureVisible(focused, alignment: 0.5);
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Stand still while the user is on it, and for a while after they interact
      if (!mounted || _focused || _paused || DateTime.now().difference(_touched) < const Duration(seconds: 20)) {
        return;
      }
      // Out of sight (another tab, a screen over it) it waits: a page change left pending would play
      // as it comes back, and take the remote's focus from under it
      if (!TickerMode.valuesOf(context).enabled || ModalRoute.of(context)?.isCurrent == false) {
        _shownAt = DateTime.now();
        return;
      }
      if (_trailer) return; // it moves on when the trailer ends
      if (_still) return; // reduced motion, or a screen reader reading the page
      final withTrailer = widget.items[_index].trailer != null && TrailerBackdrop.supported && !_noTrailer && !_still;
      if (DateTime.now().difference(_shownAt) >= (withTrailer ? _waitForTrailer : _page)) _go(_index + 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  void _go(int i, {bool user = false}) {
    if (user) _touched = DateTime.now();
    final n = widget.items.length;
    if (n < 2 || !_pages.hasClients) return;
    final to = (i % n + n) % n;
    if (_still) return _pages.jumpToPage(to);
    _pages.animateToPage(to, duration: const Duration(milliseconds: 600), curve: Curves.easeInOutCubic);
  }

  /// Reduced motion, or a screen reader: no page goes by on its own, and no trailer plays.
  bool get _still =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context) ||
      SettingsScope.maybeOf(context)?.trailers == 'never';

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        // A click leaves the focus on a button with a mouse too: only a remote or the keyboard means
        // someone is on the hero, waiting for the page not to move (and for the focus to stay: the
        // page that goes takes its buttons with it)
        _focused = f && (isTv || FocusManager.instance.highlightMode == FocusHighlightMode.traditional);
        _touched = DateTime.now(); // and stay put a while after the remote leaves, e.g. to a detail page
      },
      child: SizedBox(
        height: _heroHeight(context),
        child: Stack(
          children: [
            // A swipe holds it a while, as a tap on its arrows does
            NotificationListener<ScrollStartNotification>(
              onNotification: (n) {
                if (n.dragDetails != null) _touched = DateTime.now();
                return false;
              },
              child: PageView.builder(
                controller: _pages,
                itemCount: widget.items.length,
                onPageChanged: (i) => setState(() {
                  _index = i;
                  _shownAt = DateTime.now();
                  _trailer = _noTrailer = false;
                }),
                // Only the page on screen can take the focus, never one sliding in or out
                itemBuilder: (context, i) => ExcludeFocus(
                  excluding: i != _index,
                  child: _HeroPage(
                    topInset: widget.topInset,
                    item: widget.items[i],
                    label: widget.label,
                    trailer:
                        i == _index &&
                            widget.items[i].trailer != null &&
                            TrailerBackdrop.supported &&
                            !_still &&
                            !ProfileStore.instance.current.kids
                        ? TrailerBackdrop(
                            key: ValueKey(widget.items[i].id),
                            load: widget.items[i].trailer!,
                            onPlaying: (playing) {
                              _trailer = playing;
                              if (!playing) _noTrailer = true;
                            },
                            onEnd: () {
                              if (!_focused && !_paused) _go(_index + 1);
                            },
                          )
                        : null,
                  ),
                ),
              ),
            ),
            if (widget.items.length > 1)
              Positioned(
                right: (wide ? 40 : 20) + MediaQuery.paddingOf(context).right,
                bottom: 28,
                child: Row(
                  children: [
                    // Pages that go by on their own can be stopped (none do with reduced motion)
                    if (!_still) ...[
                      RoundIcon(
                        icon: _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                        label: _paused ? context.l10n.play : context.l10n.pause,
                        onTap: () => setState(() => _paused = !_paused),
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (wide) ...[
                      RoundIcon(
                        icon: Icons.chevron_left_rounded,
                        label: context.l10n.previousTitle,
                        onTap: () => _go(_index - 1, user: true),
                      ),
                      const SizedBox(width: 4),
                      RoundIcon(
                        icon: Icons.chevron_right_rounded,
                        label: context.l10n.nextTitle,
                        onTap: () => _go(_index + 1, user: true),
                      ),
                      const SizedBox(width: 14),
                    ],
                    for (var i = 0; i < widget.items.length; i++)
                      Semantics(
                        button: true,
                        selected: i == _index,
                        label: widget.items[i].title,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque, // the space around the dot too
                          onTap: () => _go(i, user: true),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(5, 16, 1, 16),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              width: i == _index ? 22 : 8,
                              height: 4,
                              decoration: BoxDecoration(
                                color: i == _index ? AppColors.text : const Color(0x66FFFFFF),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A round button over artwork: the hero's arrows, a row's.
class RoundIcon extends StatelessWidget {
  const RoundIcon({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label; // what it does, for screen readers
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Focusable(
    radius: 20,
    scale: 1.06,
    onTap: onTap,
    semanticLabel: label,
    child: Container(
      width: 40,
      height: 40,
      color: AppColors.scrim,
      child: Icon(icon, color: AppColors.text),
    ),
  );
}

class _HeroPage extends StatelessWidget {
  const _HeroPage({required this.item, required this.label, this.trailer, this.topInset = 0});

  final CatalogItem item;
  final String label;
  final double topInset; // see HeroCarousel.topInset
  final Widget? trailer; // over the backdrop, under the fades

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final wide = isWide(context);
    final short = isShort(context);
    final meta = [
      if (item.year != null) '${item.year}',
      if ((item.rating ?? 0) > 0) '★ ${item.rating!.toStringAsFixed(1)}',
      ...item.genres.take(3),
    ];
    Widget art(String? backdrop) => backdrop != null ? NetImage(backdrop, icon: null) : PosterInPlace(item.poster);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (item.backdrop != null || item.loadBackdrop == null)
          art(item.backdrop)
        else
          FutureBuilder<String?>(
            future: item.loadBackdrop!(),
            builder: (context, snap) =>
                snap.connectionState == ConnectionState.done ? art(snap.data) : const SizedBox.shrink(),
          ),
        ?trailer,
        // Left and bottom fades keep the text legible on any artwork
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xF2000000), Color(0x80000000), Colors.transparent],
              stops: [0, 0.38, 0.75],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Colors.transparent, AppColors.black],
              stops: [0, 0.45, 1],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              wide ? 48 : 24,
              math.max(short ? 12 : 24, topInset),
              24,
              short ? 40 : (wide ? 64 : 56),
            ),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label.toUpperCase(),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2.5,
                        fontSize: 12,
                        color: AppColors.muted,
                      ),
                    ),
                    SizedBox(height: short ? 6 : 10),
                    Text(
                      item.title,
                      maxLines: short ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: wide && !short
                          ? Theme.of(context).textTheme.displaySmall
                          : Theme.of(context).textTheme.headlineMedium,
                    ),
                    if (meta.isNotEmpty) ...[
                      SizedBox(height: short ? 6 : 12),
                      Text(
                        meta.join('   ·   '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
                      ),
                    ],
                    // With large text, or Home's title over it, a phone on its side has no room for
                    // it: the page has it
                    if (item.plot != null && !(short && (_textGrowth(context) > 1.15 || topInset > 0))) ...[
                      SizedBox(height: short ? 8 : 12),
                      Text(
                        item.plot!,
                        maxLines: short ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(height: 1.5),
                      ),
                    ],
                    SizedBox(height: short ? 14 : 22),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        // The main button takes the focus when the tab has nothing else focused
                        if (item.play != null) ...[
                          PrimaryButton(
                            autofocus: isTv,
                            icon: Icons.play_arrow_rounded,
                            label: l.play,
                            onPressed: () => item.play!(context),
                          ),
                          SecondaryButton(
                            icon: Icons.info_outline_rounded,
                            label: l.details,
                            onPressed: () => item.open(context),
                          ),
                        ] else
                          PrimaryButton(
                            autofocus: isTv,
                            icon: Icons.info_outline_rounded,
                            label: l.details,
                            onPressed: () => item.open(context),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The titles most watched this week that the provider has, each numbered large beside its poster
/// ([Trending]), up to ten; only with [minimum] or more, as a ranking of one or two says little.
/// "See all" has every one of them.
class RankedRail extends StatelessWidget {
  const RankedRail({super.key, required this.title, required this.items, this.onSeeAll});

  final String title;
  final List<CatalogItem> items; // most trending first; the first ten are shown
  final VoidCallback? onSeeAll;

  // The room for the number, partly behind the poster, and its size: both follow the poster's
  static double _number(BuildContext context) => posterWidth(context) * 0.47;
  static const minimum = 3;

  @override
  Widget build(BuildContext context) {
    final top = items.take(10).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title, action: onSeeAll == null ? null : context.l10n.seeAll, onAction: onSeeAll),
        SizedBox(
          height: posterRailHeight(context),
          child: MouseRail(
            builder: (controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              scrollCacheExtent: listReadAhead,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
              itemCount: top.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) => SizedBox(
                width: _number(context) + posterWidth(context),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Outlined, so it stays quiet next to the artwork; aligned with the poster's foot
                    Positioned(
                      left: 0,
                      bottom: 26,
                      child: ExcludeSemantics(
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontSize: posterWidth(context),
                            height: 1,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -10,
                            foreground: Paint()
                              ..style = PaintingStyle.stroke
                              ..strokeWidth = 3
                              ..color = AppColors.muted,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: _number(context),
                      top: 0,
                      bottom: 0,
                      width: posterWidth(context),
                      child: PreviewedPoster(item: top[i], rank: i + 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A horizontal row, as [builder] makes it with the controller given, that a mouse can move too:
/// arrows show while it is over the row, each a screen's width further, and Shift with the wheel
/// moves it (the wheel alone scrolls the page). A remote or a finger never sees them.
class MouseRail extends StatefulWidget {
  const MouseRail({super.key, required this.builder});

  final Widget Function(ScrollController controller) builder;

  @override
  State<MouseRail> createState() => _MouseRailState();
}

class _MouseRailState extends State<MouseRail> {
  final _controller = ScrollController();
  var _over = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _move(double by) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    final to = (p.pixels + by).clamp(p.minScrollExtent, p.maxScrollExtent);
    _controller.animateTo(to, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
  }

  double get _page => _controller.hasClients ? _controller.position.viewportDimension * 0.8 : 0;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _over = true),
    onExit: (_) => setState(() => _over = false),
    child: Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent && HardwareKeyboard.instance.isShiftPressed && _controller.hasClients) {
          _controller.jumpTo((_controller.offset + e.scrollDelta.dy).clamp(0.0, _controller.position.maxScrollExtent));
        }
      },
      child: Stack(
        children: [
          widget.builder(_controller),
          if (_over)
            ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final p = _controller.hasClients ? _controller.position : null;
                if (p == null || !p.hasContentDimensions) return const SizedBox.shrink();
                final l = context.l10n;
                return Positioned.fill(
                  child: Row(
                    children: [
                      if (p.pixels > p.minScrollExtent + 1)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: RoundIcon(
                            icon: Icons.chevron_left_rounded,
                            label: l.rowEarlier,
                            onTap: () => _move(-_page),
                          ),
                        ),
                      const Spacer(),
                      if (p.pixels < p.maxScrollExtent - 1)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: RoundIcon(
                            icon: Icons.chevron_right_rounded,
                            label: l.rowLater,
                            onTap: () => _move(_page),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    ),
  );
}

/// A titled horizontal row of posters.
class ItemRail extends StatelessWidget {
  const ItemRail({super.key, required this.title, required this.items, this.onSeeAll});

  final String title;
  final List<CatalogItem> items;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader(title, action: onSeeAll == null ? null : context.l10n.seeAll, onAction: onSeeAll),
      SizedBox(
        // Two more lines when the cards say something under their title
        height: posterRailHeight(context) + (items.any((i) => i.note != null) ? 34 : 0),
        child: MouseRail(
          builder: (controller) => ListView.separated(
            controller: controller,
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            scrollCacheExtent: listReadAhead,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) => SizedBox(
              width: posterWidth(context),
              child: PreviewedPoster(item: items[i]),
            ),
          ),
        ),
      ),
    ],
  );
}

/// A row whose items come from the provider, loaded when it scrolls into view.
class _LoadedRail extends StatelessWidget {
  const _LoadedRail({required this.title, required this.load, required this.onSeeAll});

  final String title;
  final Future<List<CatalogItem>> Function() load;
  final ValueChanged<List<CatalogItem>> onSeeAll;

  @override
  Widget build(BuildContext context) => AsyncView<List<CatalogItem>>(
    load: load,
    loading: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title),
        SizedBox(
          height: posterRailHeight(context),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            children: [
              for (var i = 0; i < 8; i++)
                Container(
                  width: posterWidth(context),
                  margin: const EdgeInsets.only(right: 14, bottom: 34),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
    builder: (context, items) =>
        items.isEmpty ? const SizedBox.shrink() : ItemRail(title: title, items: items, onSeeAll: () => onSeeAll(items)),
  );
}

enum _Sort { recent, rating, title }

/// Every title of a row, category or genre, with sorting.
class ItemGridScreen extends StatefulWidget {
  const ItemGridScreen({super.key, required this.title, required this.items, this.order});

  final String title;
  final List<CatalogItem> items;

  /// What the order they arrive in is called, such as "Best match"; else they are the newest first.
  final String? order;

  @override
  State<ItemGridScreen> createState() => _ItemGridScreenState();
}

class _ItemGridScreenState extends State<ItemGridScreen> {
  var _sort = _Sort.recent;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final items = [...widget.items];
    switch (_sort) {
      case _Sort.recent:
        break; // lists already arrive newest first
      case _Sort.rating:
        items.sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
      case _Sort.title:
        items.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    String label(_Sort s) => switch (s) {
      _Sort.recent => widget.order ?? l.sortRecent,
      _Sort.rating => l.topRated,
      _Sort.title => l.sortTitle,
    };
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final s in _Sort.values)
                  AppChip(label: label(s), selected: s == _sort, onTap: () => setState(() => _sort = s)),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: CapyMessage(mood: CapyMood.empty, text: l.nothingHere),
                  )
                : GridView.builder(
                    scrollCacheExtent: listReadAhead,
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 170,
                      childAspectRatio: 2 / 3.35,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 20,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, i) => PreviewedPoster(autofocus: i == 0, item: items[i]),
                  ),
          ),
        ],
      ),
    );
  }
}
