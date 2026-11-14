import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/epg.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/profiles.dart';
import '../data/search.dart';
import '../data/trending.dart';
import '../device.dart';
import '../player/play.dart';
import '../remote/remote_input.dart';
import 'catalog.dart';
import 'common.dart';
import 'detail_screens.dart';
import 'guide_screen.dart' show openProgramme;
import 'preview.dart';
import 'remote_text_field.dart';
import 'theme.dart';

/// Search over the whole catalog, forgiving the way people type ([SearchQuery]), best matches
/// first: movies and series, then what the guide says is on TV, then channels. Before anything is
/// typed, what saves typing with a remote: recent searches, the week's top ten and genres.
class SearchTab extends StatefulWidget {
  const SearchTab({super.key, required this.catalog, required this.guide});

  final Catalog catalog;
  final ValueListenable<EpgGuide> guide;

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> with AutomaticKeepAliveClientMixin {
  final _query = TextEditingController();
  Timer? _debounce;
  var _q = SearchQuery('');

  /// The search whose channels are all shown, not only the first dozen.
  SearchQuery? _allChannelsOf;
  List<String> _recent = const [];

  /// Shown at first in each section; "see all" has the rest, in the same order.
  static const _shown = 18, _shownChannels = 12;

  @override
  bool get wantKeepAlive => true;

  String get _profile => ProfileStore.instance.current.id;

  @override
  void initState() {
    super.initState();
    remoteSearch.addListener(_remote);
    // Built anew when the lists are updated: from what the desktop title bar still shows
    if (remoteSearch.fromTitleBar && remoteSearch.text.isNotEmpty) {
      _query.text = remoteSearch.text;
      _q = SearchQuery(remoteSearch.text);
    }
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final recent = await RecentSearches.of(_profile);
    if (mounted) setState(() => _recent = recent);
  }

  /// A search typed on the phone remote
  void _remote() {
    _query.text = remoteSearch.text;
    _changed(remoteSearch.text);
  }

  @override
  void dispose() {
    remoteSearch.removeListener(_remote);
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => setState(() => _q = SearchQuery(v)));
  }

  void _fill(String text) {
    _query.text = text;
    _debounce?.cancel();
    setState(() => _q = SearchQuery(text));
  }

  /// Opening a result is what makes a search worth remembering.
  Future<void> _remember() async {
    await RecentSearches.add(_profile, _query.text);
    await _loadRecent();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l = context.l10n;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // On a phone on its side the field says it all, and the results need the height
          if (!isShort(context))
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(l.search, style: Theme.of(context).textTheme.headlineMedium),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            // With a remote the field shows what is searched and OK opens its keyboard, rather than
            // the keyboard coming up by itself over the recent searches each time the focus passes,
            // and not coming back once closed; what is typed there is cleared there too
            child: isTv
                ? RemoteTextFormField(
                    controller: _query,
                    onChanged: _changed,
                    onFieldSubmitted: (_) => _remember(),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(hintText: l.searchHint, prefixIcon: const Icon(Icons.search_rounded)),
                  )
                : TextField(
                    controller: _query,
                    onChanged: _changed,
                    onSubmitted: (_) => _remember(),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: l.searchHint,
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _query.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded),
                              tooltip: l.clearSearch,
                              onPressed: () => _fill(''),
                            ),
                    ),
                  ),
          ),
          Expanded(
            child: AsyncView(
              load: () async => SearchIndex.of(await widget.catalog.load()),
              loading: const Center(child: ListLoading()),
              builder: (context, index) => _q.isEmpty ? _start(context, index.data) : _results(context, index),
            ),
          ),
        ],
      ),
    );
  }

  /// The version of a title to show it by: the best match that has artwork, as some copies have none.
  static Object _cover(List<Object> versions) {
    // Not firstWhere: these lists are of movies or of series, and orElse would have to be typed so
    for (final x in versions) {
      if ((x is Movie ? x.poster : (x as Series).cover) != null) return x;
    }
    return versions.first;
  }

  /// [x], a movie or series; with its [versions] when the provider lists it more than once.
  CatalogItem _item(Object x, [List<Object> versions = const []]) {
    final source = widget.catalog.source;
    final item = x is Movie ? CatalogItem.movie(source, x) : CatalogItem.series(source, x as Series);
    return CatalogItem(
      id: item.id,
      title: item.title,
      poster: item.poster,
      rating: item.rating,
      year: item.year,
      genres: item.genres,
      note: versions.length > 1 ? context.l10n.versionsCount(versions.length) : null,
      open: (c) {
        _remember();
        if (versions.length < 2) return item.open(c);
        Navigator.of(c).push(
          MaterialPageRoute(
            builder: (_) => x is Movie
                ? MovieDetailScreen(source: source, movie: x, versions: versions.cast<Movie>())
                : SeriesDetailScreen(source: source, series: x as Series, versions: versions.cast<Series>()),
          ),
        );
      },
    );
  }

  /// Before anything is typed: recent searches, the week's top ten, genres.
  Widget _start(BuildContext context, CatalogData data) {
    final l = context.l10n;
    return ValueListenableBuilder(
      valueListenable: Trending.items,
      builder: (context, trends, _) => ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          if (_recent.isNotEmpty) ...[
            SectionHeader(
              l.recentSearches,
              action: l.clearRecent,
              onAction: () async {
                await RecentSearches.clear(_profile);
                await _loadRecent();
              },
            ),
            ChipBar(genres: _recent, onTap: _fill),
          ],
          for (final (series, title) in [(false, l.mostWatchedMovies), (true, l.mostWatchedSeries)])
            if ([
                  for (final x in Trending.ofKind(
                    data,
                    series: series,
                    trends: trends,
                    forKids: ProfileStore.instance.current.kids,
                  ))
                    _item(x),
                ]
                case final items when items.isNotEmpty)
              RankedRail(title: title, items: items),
          if (data.movieGenres.isNotEmpty) ...[
            SectionHeader(l.browseGenres),
            ChipBar(
              genres: data.movieGenres.take(CatalogData.genresShown).toList(),
              onTap: (g) => openItemGrid(context, g, [for (final m in data.moviesIn(g)) _item(m)]),
            ),
          ],
          if (_recent.isEmpty && data.movieGenres.isEmpty)
            Padding(
              padding: const EdgeInsets.all(48),
              child: Center(
                child: Text(l.typeToSearch, style: const TextStyle(color: AppColors.muted)),
              ),
            ),
        ],
      ),
    );
  }

  // What a search found, kept while the search and what it looks in are the same: the screen is
  // drawn again for much else (the recent searches, "see all"), and a big catalog takes a while
  (SearchQuery, SearchIndex, SearchResults)? _found;
  (SearchQuery, SearchIndex, EpgGuide, DateTime, List<OnAir>)? _onAir;

  SearchResults _search(SearchIndex index) {
    if (_found case (final q, final i, final found) when identical(q, _q) && identical(i, index)) return found;
    final found = index.search(_q);
    _found = (_q, index, found);
    return found;
  }

  /// Again a minute later: what is on changes.
  List<OnAir> _searchGuide(SearchIndex index, EpgGuide guide) {
    final now = DateTime.now();
    if (_onAir case (final q, final i, final g, final at, final onAir)
        when identical(q, _q) && identical(i, index) && identical(g, guide) && now.difference(at).inMinutes < 1) {
      return onAir;
    }
    final onAir = searchGuide(guide, index.data.live, _q, now: now).take(_shownChannels).toList();
    _onAir = (_q, index, guide, now, onAir);
    return onAir;
  }

  Widget _results(BuildContext context, SearchIndex index) {
    final l = context.l10n;
    final found = _search(index);
    final source = widget.catalog.source;
    return ValueListenableBuilder(
      valueListenable: widget.guide,
      builder: (context, guide, _) {
        final onAir = _searchGuide(index, guide);
        if (found.isEmpty && onAir.isEmpty) {
          return Center(
            child: CapyMessage(mood: CapyMood.empty, text: l.noResults),
          );
        }
        Widget posters(String title, List<List<Object>> all) {
          final items = [for (final g in all.take(_shown)) _item(_cover(g), g)];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                '$title · ${all.length}',
                action: all.length > _shown ? l.seeAllCount(all.length) : null,
                onAction: () =>
                    openItemGrid(context, title, [for (final g in all) _item(_cover(g), g)], order: l.bestMatch),
              ),
              _ResultGrid(items: items),
            ],
          );
        }

        final now = DateTime.now();
        final coming = [
          for (final x in onAir)
            if (x.programme.end.isAfter(now)) x,
        ];
        final aired = [
          for (final x in onAir)
            if (!x.programme.end.isAfter(now)) x,
        ];
        void play(List<LiveChannel> queue, int i) {
          _remember();
          playQueue(context, [
            for (final c in queue) PlayItem(url: source.liveUrl(c), title: c.name, ref: MediaRef.channel(c)),
          ], index: i);
        }

        return ListView(
          padding: const EdgeInsets.only(bottom: 120),
          children: [
            if (found.movies.isNotEmpty) posters(l.movies, found.movies),
            if (found.series.isNotEmpty) posters(l.series, found.series),
            if (coming.isNotEmpty) ...[
              SectionHeader(l.onTvNow),
              for (final (i, (:channel, :programme)) in coming.indexed)
                _ChannelRow(
                  channel: channel,
                  title: programme.title,
                  subtitle: [
                    programme.isNow() ? l.onNow : clockText(context, programme.start),
                    channel.name,
                  ].join(' · '),
                  live: programme.isNow(),
                  onTap: () => play([for (final x in coming) x.channel], i),
                ),
            ],
            // Aired, and kept by the channel: watched again from where it began
            if (aired.isNotEmpty) ...[
              SectionHeader(l.watchAgain),
              for (final (:channel, :programme) in aired)
                _ChannelRow(
                  channel: channel,
                  title: programme.title,
                  subtitle: [dayAndClock(context, programme.start), channel.name].join(' · '),
                  onTap: () {
                    _remember();
                    openProgramme(context, source, [channel], 0, programme);
                  },
                ),
            ],
            if (found.channels.isNotEmpty) ...[
              SectionHeader(
                '${l.liveTv} · ${found.channels.length}',
                action: found.channels.length > _shownChannels && _allChannelsOf != _q
                    ? l.seeAllCount(found.channels.length)
                    : null,
                onAction: () => setState(() => _allChannelsOf = _q),
              ),
              for (final (i, c)
                  in (_allChannelsOf == _q ? found.channels : found.channels.take(_shownChannels)).indexed)
                _ChannelRow(
                  channel: c,
                  title: c.name,
                  subtitle: guide.nowOn(c.epgId)?.title,
                  // Zapping goes through all those found
                  onTap: () => play(found.channels, i),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// A channel in the results: its logo, a title, and what is on or when.
class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    required this.channel,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.live = false,
  });

  final LiveChannel channel;
  final String title;
  final String? subtitle;
  final bool live; // on now: a red dot, the one colour live TV has
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
    child: Focusable(
      scale: 1.02,
      onTap: onTap,
      child: ColoredBox(
        color: AppColors.surface,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 40,
                child: NetImage(channel.icon, fit: BoxFit.contain, icon: Icons.tv_rounded),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (subtitle != null)
                      Row(
                        children: [
                          if (live) ...[
                            const DecoratedBox(
                              decoration: BoxDecoration(color: AppColors.live, shape: BoxShape.circle),
                              child: SizedBox.square(dimension: 7),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppColors.muted, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ResultGrid extends StatelessWidget {
  const _ResultGrid({required this.items});

  final List<CatalogItem> items;

  @override
  Widget build(BuildContext context) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    padding: const EdgeInsets.symmetric(horizontal: 24),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 160,
      childAspectRatio: 2 / 3.6, // room for "3 versions" under the title
      crossAxisSpacing: 14,
      mainAxisSpacing: 18,
    ),
    itemCount: items.length,
    itemBuilder: (context, i) => PreviewedPoster(item: items[i]),
  );
}
