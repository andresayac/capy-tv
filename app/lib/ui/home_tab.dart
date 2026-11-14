import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/kids.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/new_episodes.dart';
import '../data/profiles.dart';
import '../data/recommender.dart';
import '../data/source.dart';
import '../data/trending.dart';
import '../device.dart';
import '../l10n/app_localizations.dart';
import '../player/play.dart';
import 'catalog.dart';
import 'common.dart';
import 'detail_screens.dart';
import 'profiles_screen.dart';
import 'surprise_screen.dart';
import 'theme.dart';

/// Personal start page, movies and series first: continue watching, what is trending this week
/// and the provider has, "My list", what is new; then recent and favorite channels.
class HomeTab extends StatelessWidget {
  const HomeTab({
    super.key,
    required this.source,
    required this.catalog,
    required this.title,
    required this.onAccount,
    required this.onProfiles,
    required this.onBrowse,
  });

  final ContentSource source;
  final Catalog catalog;
  final String title;
  final VoidCallback onAccount; // settings
  final VoidCallback onProfiles; // "Who's watching?"
  final ValueChanged<int> onBrowse; // jump to another tab, such as [movies]

  // The tabs, movies and series before live TV
  static const movies = 1, series = 2, live = 3, search = 4;

  @override
  Widget build(BuildContext context) => StatefulBuilder(
    // Retry builds it again: a catalog that failed is asked for anew by its next load
    builder: (context, setState) => FutureBuilder<CatalogData>(
      future: catalog.load(),
      // Built again as it scrolls back into view: with what is there from the first frame, not empty
      // for one frame, which made everything below it jump
      initialData: catalog.loaded,
      builder: (context, snap) => _home(
        context,
        snap.data,
        loading: snap.connectionState != ConnectionState.done,
        error: snap.error,
        retry: () => setState(() {}),
      ),
    ),
  );

  Widget _home(BuildContext context, CatalogData? listed, {bool loading = false, Object? error, VoidCallback? retry}) {
    final l = context.l10n;
    final lib = LibraryScope.of(context);
    bool shows(MediaRef r) => libraryShows(r, listed, catalog.source);
    final cont = lib.continueWatching.where((e) => shows(e.ref)).toList();
    final recent = lib.recent(MediaKind.live).where(shows).take(20).toList();
    final favChannels = lib.favorites(MediaKind.live).where(shows).toList();
    final favMovies = lib.favorites(MediaKind.movie).where(shows).toList();
    final favSeries = lib.favorites(MediaKind.series).where(shows).toList();
    final empty = cont.isEmpty && recent.isEmpty && favChannels.isEmpty && favMovies.isEmpty && favSeries.isEmpty;
    final left = lib.leftElsewhere(here: deviceName);
    final away = left != null && shows(left.ref) ? left : null;

    // The trending artwork goes edge to edge, under a landscape phone's camera cutout too; the
    // rest keeps clear of it
    return SafeArea(
      bottom: false,
      left: false,
      right: false,
      child: ListView(
        key: const PageStorageKey('home'), // keeps its place while another tab is shown
        scrollCacheExtent: listReadAhead,
        padding: const EdgeInsets.only(bottom: 120),
        children: clearOfCutout(skip: 1, [
          // What is trending this week and the provider has, trailers playing behind it
          FutureBuilder<CatalogData>(
            future: catalog.load(),
            // Built again as it scrolls back into view: with what is there from the first frame, not empty
            // for one frame, which made everything below it jump
            initialData: catalog.loaded,
            builder: (context, snap) => ValueListenableBuilder(
              valueListenable: Trending.items,
              builder: (context, trends, _) {
                final data = snap.data;
                final hero = [
                  if (data != null)
                    for (final (:trend, :item) in Trending.available(data, trends, ProfileStore.instance.current.kids))
                      if (trend.backdrop != null)
                        switch (item) {
                          Movie m => CatalogItem.movie(source, m),
                          _ => CatalogItem.series(source, item as Series),
                        }.withTrend(trend),
                ].take(8).toList();
                final header = SafeArea(
                  top: false,
                  bottom: false,
                  child: _Header(
                    title: title,
                    onAccount: onAccount,
                    onProfiles: onProfiles,
                    source: source,
                    catalog: catalog,
                  ),
                );
                if (hero.isEmpty) return header;
                return Stack(
                  children: [
                    // Its text below the header over it: Home's title, the playlist's name, the buttons
                    HeroCarousel(
                      items: hero,
                      label: l.trendingNow,
                      topInset: 28 + math.max(MediaQuery.textScalerOf(context).scale(52), 48),
                    ),
                    header,
                  ],
                );
              },
            ),
          ),
          // The catalog on its way, or what went wrong with it: not "make it yours" over a failure
          if (listed == null && loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: ListLoading()),
            )
          else if (listed == null && error != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: CapyMessage(
                mood: capyMoodForError(error),
                text: errorText(l, error),
                style: null,
                action: SecondaryButton(
                  icon: Icons.refresh_rounded,
                  label: l.retry,
                  autofocus: true,
                  onPressed: retry ?? () {},
                ),
              ),
            )
          else if (empty)
            _EmptyHome(onBrowse: onBrowse),
          // Left half watched on another device a moment ago: go on with it here
          if (away != null)
            ValueListenableBuilder(
              valueListenable: _LeftElsewhere.dismissed,
              builder: (context, dismissed, _) => dismissed.contains(_LeftElsewhere.keyOf(away))
                  ? const SizedBox.shrink()
                  : _LeftElsewhere(entry: away, onPlay: () => playFromLibrary(context, source, away.ref)),
            ),
          if (cont.isNotEmpty) ...[
            SectionHeader(l.continueWatching),
            SizedBox(
              height: isShort(context) ? 156 : 196,
              child: MouseRail(
                builder: (controller) => ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  scrollCacheExtent: listReadAhead,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                  itemCount: cont.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 16),
                  itemBuilder: (context, i) => _ContinueCard(
                    entry: cont[i],
                    autofocus: i == 0 && away == null,
                    onTap: () => playFromLibrary(context, source, cont[i].ref),
                    onLongPress: () {
                      lib.forget(cont[i].ref);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.removeFromContinue)));
                    },
                  ),
                ),
              ),
            ),
          ],
          // Picked for this profile by the language model set up in Account
          // Series this profile follows that have episodes it has not seen
          // The episode after one watched to the end: it is not "Continue watching", which only has
          // those left half way
          _NewEpisodesRail(source: source, catalog: catalog, upNext: true),
          _NewEpisodesRail(source: source, catalog: catalog),
          _ForYou(source: source, catalog: catalog),
          // This week's top ten movies and series that the provider has, playable right away
          FutureBuilder<CatalogData>(
            future: catalog.load(),
            // Built again as it scrolls back into view: with what is there from the first frame, not empty
            // for one frame, which made everything below it jump
            initialData: catalog.loaded,
            builder: (context, snap) => ValueListenableBuilder(
              valueListenable: Trending.items,
              builder: (context, trends, _) {
                final data = snap.data;
                if (data == null) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (series, title) in [(false, l.mostWatchedMovies), (true, l.mostWatchedSeries)])
                      if ([
                            for (final x in Trending.ofKind(
                              data,
                              series: series,
                              trends: trends,
                              forKids: ProfileStore.instance.current.kids,
                            ))
                              x is Movie ? CatalogItem.movie(source, x) : CatalogItem.series(source, x as Series),
                          ]
                          case final items when items.length >= RankedRail.minimum)
                        RankedRail(title: title, items: items, onSeeAll: () => openItemGrid(context, title, items)),
                  ],
                );
              },
            ),
          ),
          // The first rail takes the focus, so a TV remote starts on Home's content
          if (favMovies.isNotEmpty)
            _PosterRail(
              title: l.favoriteMovies,
              refs: favMovies,
              open: (r) => MovieDetailScreen(source: source, movie: r.toMovie()),
              autofocus: cont.isEmpty,
              onSeeAll: () => openItemGrid(context, l.favoriteMovies, [
                for (final r in favMovies) CatalogItem.movie(source, r.toMovie()),
              ]),
            ),
          if (favSeries.isNotEmpty)
            _PosterRail(
              title: l.favoriteSeries,
              refs: favSeries,
              open: (r) => SeriesDetailScreen(source: source, series: r.toSeries()),
              autofocus: cont.isEmpty && favMovies.isEmpty,
              onSeeAll: () => openItemGrid(context, l.favoriteSeries, [
                for (final r in favSeries) CatalogItem.series(source, r.toSeries()),
              ]),
            ),
          // What is new, so Home is never empty
          FutureBuilder<CatalogData>(
            future: catalog.load(),
            // Built again as it scrolls back into view: with what is there from the first frame, not empty
            // for one frame, which made everything below it jump
            initialData: catalog.loaded,
            builder: (context, snap) {
              final data = snap.data;
              if (data == null) return const SizedBox.shrink();
              final movies = [for (final m in data.recentMovies.take(40)) CatalogItem.movie(source, m)];
              final series = [for (final x in data.recentSeries.take(40)) CatalogItem.series(source, x)];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (movies.isNotEmpty)
                    ItemRail(
                      title: l.newMovies,
                      items: movies,
                      onSeeAll: () => openItemGrid(context, l.newMovies, movies),
                    ),
                  if (series.isNotEmpty)
                    ItemRail(
                      title: l.newEpisodes,
                      items: series,
                      onSeeAll: () => openItemGrid(context, l.newEpisodes, series),
                    ),
                ],
              );
            },
          ),
          if (recent.isNotEmpty)
            _ChannelRail(
              title: l.recentChannels,
              source: source,
              channels: recent,
              autofocus: cont.isEmpty && favMovies.isEmpty && favSeries.isEmpty,
            ),
          if (favChannels.isNotEmpty)
            _ChannelRail(
              title: l.favoriteChannels,
              source: source,
              channels: favChannels,
              autofocus: cont.isEmpty && favMovies.isEmpty && favSeries.isEmpty && recent.isEmpty,
            ),
        ]).map(_outOfHomeKey).toList(),
      ),
    );
  }

  // Under the list's PageStorageKey every row inside it would keep its scroll offset in that one
  // slot, shared with the list: a row built later would start where another, or the list, was left
  static final _noBucket = PageStorageBucket();
  static Widget _outOfHomeKey(Widget child) => PageStorage(bucket: _noBucket, child: child);
}

/// Titles picked for the profile on screen, with why ([Recommender]): the ones kept show at once,
/// fresh ones replace them when they are due. Nothing without a service set up, in kids
/// profiles, or before the profile has watched anything.
class _ForYou extends StatefulWidget {
  const _ForYou({required this.source, required this.catalog});

  final ContentSource source;
  final Catalog catalog;

  @override
  State<_ForYou> createState() => _ForYouState();
}

class _ForYouState extends State<_ForYou> {
  // What each library's row showed last: scrolled away and back, Home builds it anew, and an empty
  // row for a moment would make the page jump
  static final _shown = Expando<({int cleared, List<Pick> picks})>();

  List<Pick> _picks = const [];
  Library? _library;
  var _cleared = 0; // what _library had when its picks were loaded
  var _asking = false;

  @override
  void initState() {
    super.initState();
    Recommender.service.addListener(_serviceChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final library = LibraryScope.maybeOf(context);
    // Another library, or this one's history cleared: its picks went with it
    if (library != null && (library != _library || library.clearedAt != _cleared)) {
      _library = library;
      _cleared = library.clearedAt;
      final shown = _shown[library];
      setState(() => _picks = shown != null && shown.cleared == library.clearedAt ? shown.picks : const []);
      _load(library);
    }
  }

  @override
  void dispose() {
    Recommender.service.removeListener(_serviceChanged);
    super.dispose();
  }

  void _serviceChanged() {
    setState(() => _picks = const []);
    if (_library case final l?) {
      _shown[l] = null;
      _load(l);
    }
  }

  Future<void> _load(Library library) async {
    if (ProfileStore.instance.current.kids || Recommender.service.value == null) return;
    final data = await widget.catalog.load();
    final kept = await Recommender.kept(library, data);
    if (!mounted) return;
    _show(library, kept);
    if (_asking) return;
    _asking = true;
    try {
      final language = switch (Localizations.localeOf(context).languageCode) {
        'es' => 'Spanish',
        _ => 'English',
      };
      final fresh = await Recommender.refresh(library, data, language: language);
      if (fresh != null && mounted) _show(library, fresh);
    } on AiException catch (e) {
      debugPrint('Recommendations: $e'); // the ones kept stay
    } finally {
      _asking = false;
    }
  }

  void _show(Library library, List<Pick> picks) {
    _shown[library] = (cleared: library.clearedAt, picks: picks);
    setState(() => _picks = picks);
  }

  @override
  Widget build(BuildContext context) {
    if (_picks.isEmpty) return const SizedBox.shrink();
    final items = [
      for (final p in _picks)
        switch (p.item) {
          Movie m => CatalogItem.movie(widget.source, m),
          _ => CatalogItem.series(widget.source, p.item as Series),
        }.withNote(p.why.isEmpty ? null : p.why),
    ];
    // The main profile has no name of its own: not "Picked for You"
    final p = ProfileStore.instance.current, l = context.l10n;
    return ItemRail(title: p.name.isEmpty ? l.forYouMain : l.forYou(p.displayName(l)), items: items);
  }
}

/// The series the profile has been watching that got episodes since ([NewEpisodeFinder]).
class _NewEpisodesRail extends StatefulWidget {
  const _NewEpisodesRail({required this.source, required this.catalog, this.upNext = false});

  final ContentSource source;
  final Catalog catalog;

  /// The next episode of series seen to their last one, rather than the provider's new ones.
  final bool upNext;

  // One per catalog: each series is asked about once a session
  static final _finders = Expando<NewEpisodeFinder>();

  @override
  State<_NewEpisodesRail> createState() => _NewEpisodesRailState();
}

class _NewEpisodesRailState extends State<_NewEpisodesRail> {
  // As For you: what the row showed last, by library and kind, for the row built anew
  static final _shown = Expando<Map<bool, List<NewEpisodes>>>();

  List<NewEpisodes> _found = const [];
  Library? _library;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final library = LibraryScope.maybeOf(context);
    if (library == null || library == _library) return;
    _library = library;
    _found = _shown[library]?[widget.upNext] ?? const [];
    _load(library);
  }

  Future<void> _load(Library library) async {
    final finder = _NewEpisodesRail._finders[widget.catalog] ??= NewEpisodeFinder(widget.source);
    try {
      final found = await finder.find(library, await widget.catalog.load(), upNext: widget.upNext);
      (_shown[library] ??= {})[widget.upNext] = found;
      if (mounted) setState(() => _found = found);
    } on Object catch (e) {
      debugPrint('New episodes: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_found.isEmpty) return const SizedBox.shrink();
    final l = context.l10n;
    return ItemRail(
      title: widget.upNext ? l.upNextForYou : l.newEpisodesForYou,
      items: [
        for (final (:series, :next, :count) in _found)
          CatalogItem.series(widget.source, series).withNote(l.newEpisodeNote(next.season, next.number, count - 1)),
      ],
    );
  }
}

/// Home's title, the playlist's name and the way to the account.
class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.onAccount,
    required this.onProfiles,
    required this.source,
    required this.catalog,
  });

  final String title;
  final VoidCallback onAccount, onProfiles;
  final ContentSource source;
  final Catalog catalog;

  void _surprise(BuildContext context) {
    final library = LibraryScope.maybeOf(context);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SurpriseScreen(source: source, catalog: catalog, library: library),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The screen's name to a screen reader, as an app bar's title is
                Semantics(
                  header: true,
                  namesRoute: true,
                  child: Text(l.home, style: Theme.of(context).textTheme.headlineMedium),
                ),
                Text(title, style: const TextStyle(color: AppColors.muted)),
              ],
            ),
          ),
          // For an evening without a plan
          SecondaryButton(icon: Icons.casino_outlined, label: l.surpriseMe, onPressed: () => _surprise(context)),
          const SizedBox(width: 8),
          // Who is watching, and a tap to someone else
          Tooltip(
            message: l.switchProfile,
            child: Focusable(
              radius: AppRadius.pill,
              onTap: onProfiles,
              child: ListenableBuilder(
                listenable: ProfileStore.instance,
                builder: (context, _) => ProfileAvatar(profile: ProfileStore.instance.current, size: 38),
              ),
            ),
          ),
          // Without the side menu (a narrow window), settings are here
          if (!isWide(context)) ...[
            const SizedBox(width: 4),
            IconButton(icon: const Icon(Icons.settings_rounded), tooltip: l.settings, onPressed: onAccount),
          ],
        ],
      ),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onBrowse});

  final ValueChanged<int> onBrowse;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Panel(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const CapyStatus(mood: CapyMood.empty, size: 56),
            const SizedBox(height: 16),
            Text(l.homeEmptyTitle, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(l.homeEmptyBody, style: const TextStyle(color: AppColors.muted, height: 1.5)),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                PrimaryButton(
                  autofocus: true,
                  icon: Icons.movie_rounded,
                  label: l.movies,
                  onPressed: () => onBrowse(HomeTab.movies),
                ),
                SecondaryButton(
                  icon: Icons.video_library_rounded,
                  label: l.series,
                  onPressed: () => onBrowse(HomeTab.series),
                ),
                SecondaryButton(icon: Icons.live_tv_rounded, label: l.liveTv, onPressed: () => onBrowse(HomeTab.live)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Landscape card with artwork and a progress bar.
/// "You left this on the living room TV 20 minutes ago": the title, how far it got, and a button
/// to go on right there on this device.
class _LeftElsewhere extends StatelessWidget {
  const _LeftElsewhere({required this.entry, required this.onPlay});

  final HistoryEntry entry;
  final VoidCallback onPlay;

  /// Put aside with "Not now" since the app started; a newer viewing elsewhere shows again.
  static final dismissed = ValueNotifier<Set<String>>({});

  static String keyOf(HistoryEntry h) => '${h.ref.key}@${h.updated.millisecondsSinceEpoch}';

  static String ago(AppLocalizations l, Duration d) => d.inMinutes < 1
      ? l.agoNow
      : d.inMinutes < 60
      ? l.agoMinutes(d.inMinutes)
      : l.agoHours(d.inHours);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final r = entry.ref;
    final since = DateTime.now().difference(entry.updated);
    final thumbnail = SizedBox(
      width: 168,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.button),
          child: Stack(
            fit: StackFit.expand,
            children: [
              NetImage(r.image, label: r.seriesTitle ?? r.title),
              Align(
                alignment: Alignment.bottomLeft,
                child: FractionallySizedBox(
                  widthFactor: entry.progress,
                  child: Container(height: 4, color: AppColors.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final about = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.leftOn(entry.device!, ago(l, since.isNegative ? Duration.zero : since)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.muted, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          r.seriesTitle ?? r.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        if (r.kind == MediaKind.episode)
          Text(
            'S${r.season} · E${r.number}  ${r.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        const SizedBox(height: 4),
        Text(
          l.minutesLeft((entry.duration - entry.position).inMinutes.clamp(1, 9999)),
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        PrimaryButton(autofocus: true, icon: Icons.play_arrow_rounded, label: l.goOnHere, onPressed: onPlay),
        SecondaryButton(label: l.notNow, onPressed: () => dismissed.value = {...dismissed.value, keyOf(entry)}),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.stroke),
        ),
        // Side by side when there is room, else the buttons go under the title. Large text needs
        // more of it, and the buttons may wrap rather than run out of the card
        child: LayoutBuilder(
          builder: (context, c) => c.maxWidth >= MediaQuery.textScalerOf(context).scale(640)
              ? Row(
                  children: [
                    thumbnail,
                    const SizedBox(width: 18),
                    Expanded(child: about),
                    const SizedBox(width: 18),
                    Flexible(child: actions),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [about, const SizedBox(height: 12), actions],
                ),
        ),
      ),
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.entry, required this.onTap, this.onLongPress, this.autofocus = false});

  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onLongPress; // off the row, without clearing the whole history
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final r = entry.ref;
    final left = entry.duration - entry.position;
    return SizedBox(
      width: isShort(context) ? 200 : 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Focusable(
              autofocus: autofocus,
              onTap: onTap,
              onLongPress: onLongPress,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetImage(r.image, label: r.seriesTitle ?? r.title),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xCC000000)],
                      ),
                    ),
                  ),
                  const Center(child: Icon(Icons.play_circle_fill_rounded, size: 44, color: Colors.white70)),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.minutesLeft(left.inMinutes.clamp(1, 9999)),
                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: Stack(
                            children: [
                              Container(height: 4, color: Colors.white24),
                              FractionallySizedBox(
                                widthFactor: entry.progress,
                                child: Container(height: 4, decoration: const BoxDecoration(color: AppColors.text)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            r.seriesTitle ?? r.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          // Always two lines, so movie and episode cards keep the same artwork height
          Text(
            r.kind == MediaKind.episode ? 'S${r.season} · E${r.number}  ${r.title}' : ' ',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ChannelRail extends StatelessWidget {
  const _ChannelRail({required this.title, required this.source, required this.channels, this.autofocus = false});

  final String title;
  final ContentSource source;
  final List<MediaRef> channels;
  final bool autofocus; // first card, when this is the first rail on Home

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader(title),
      SizedBox(
        height: isShort(context) ? 108 : 132,
        child: MouseRail(
          builder: (controller) => ListView.separated(
            controller: controller,
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            scrollCacheExtent: listReadAhead,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            itemCount: channels.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final c = channels[i];
              return SizedBox(
                width: isShort(context) ? 120 : 150,
                child: Focusable(
                  autofocus: autofocus && i == 0,
                  // The rail is the zapping queue, so up/down in the player moves along it
                  onTap: () => playRefs(context, source, channels, i),
                  child: ColoredBox(
                    color: AppColors.surface,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Expanded(
                            child: NetImage(c.image, fit: BoxFit.contain, icon: Icons.tv_rounded),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ],
  );
}

class _PosterRail extends StatelessWidget {
  const _PosterRail({
    required this.title,
    required this.refs,
    required this.open,
    this.autofocus = false,
    this.onSeeAll,
  });

  final String title;
  final List<MediaRef> refs;
  final Widget Function(MediaRef r) open;
  final bool autofocus; // first card, when this is the first rail on Home

  /// All of them in a grid: sixty saved titles are not to be gone through one by one.
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) => Column(
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
            itemCount: refs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) => SizedBox(
              width: posterWidth(context),
              child: PosterCard(
                autofocus: autofocus && i == 0,
                title: refs[i].title,
                poster: refs[i].image,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => open(refs[i]))),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
