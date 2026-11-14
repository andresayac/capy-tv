import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:url_launcher/url_launcher.dart';

import '../data/catalog.dart';
import '../data/epg.dart';
import '../data/kids.dart' show isAdultRating;
import '../data/library.dart';
import '../data/matching.dart';
import '../data/models.dart';
import '../data/profiles.dart';
import '../data/settings.dart';
import '../data/source.dart';
import '../data/trending.dart' show youtubeId;
import '../device.dart';
import '../l10n/app_localizations.dart';
import '../player/play.dart';
import 'cast_screen.dart';
import 'catalog.dart';
import 'common.dart';
import 'profiles_screen.dart' show adultActionsHidden, confirmPin;
import 'send_to.dart';
import 'theme.dart';
import 'trailer.dart';

/// "1 h 41 min", or "45 min" under an hour.
String formatRuntime(AppLocalizations l, Duration d) =>
    d.inHours > 0 ? l.hoursMinutes(d.inHours, d.inMinutes % 60) : l.minutes(math.max(1, d.inMinutes));

String _quality(Movie m) => [
  if ((m.bitrateKbps ?? 0) > 0) '${(m.bitrateKbps! / 1000).toStringAsFixed(1)} Mbps',
  if ((m.sizeBytes ?? 0) > 0) '${(m.sizeBytes! / (1 << 30)).toStringAsFixed(1)} GB',
  m.extension.toUpperCase(),
].join(' · ');

// Only YouTube: a provider can put any address there, and this leaves the app
Future<void> _openTrailer(String id) =>
    launchUrl(Uri.parse('https://www.youtube.com/watch?v=$id'), mode: LaunchMode.externalApplication);

bool get _kids => ProfileStore.instance.current.kids;

/// First names of a comma-separated cast list.
String _castList(String cast, {int count = 6}) =>
    cast.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).take(count).join(', ');

/// Detail page frame: wide artwork that fades into black with the title block on top of it,
/// followed by the page body.
class _DetailPage extends StatelessWidget {
  const _DetailPage({
    required this.backdrop,
    required this.poster,
    required this.title,
    this.body = const [],
    this.trailer,
  });

  final String? backdrop, poster;
  final Widget title;
  final List<Widget> body;

  /// The YouTube id of a trailer that plays once behind the title, silent, if any.
  final Future<String?> Function()? trailer;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wide = isWide(context);
    // Larger text needs a taller box, or its buttons end up outside it, drawn but untouchable
    final text = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0); // as far as text grows (main.dart)
    final heroHeight =
        text *
        (isShort(context)
            ? size.height *
                  0.92 // a landscape phone: the title block nearly fills the first screen
            : wide
            ? (size.height * 0.64).clamp(440.0, 620.0)
            : 470.0);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent, // the artwork shows through behind the back button
        leading: Padding(
          padding: const EdgeInsets.all(6),
          child: Panel(
            radius: AppRadius.pill,
            color: AppColors.scrim,
            child: BackButton(onPressed: () => Navigator.maybePop(context)),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 56),
        // A remote only goes down to what is built: past a long synopsis, "More like this" must be
        // there already. Touch and the mouse scroll to it whatever is built
        scrollCacheExtent: isTv ? const ScrollCacheExtent.pixels(1500) : null,
        children: [
          SizedBox(
            height: heroHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (backdrop != null) NetImage(backdrop, icon: null) else PosterInPlace(poster),
                if (trailer != null &&
                    TrailerBackdrop.supported &&
                    !MediaQuery.disableAnimationsOf(context) &&
                    SettingsScope.maybeOf(context)?.trailers != 'never')
                  TrailerBackdrop(key: const ValueKey('trailer'), load: trailer!, onPlaying: (_) {}, onEnd: () {}),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x80000000), Color(0x1A000000), Color(0xCC000000), AppColors.black],
                      stops: [0, 0.3, 0.75, 1],
                    ),
                  ),
                ),
                if (wide)
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Color(0xCC000000), Colors.transparent], stops: [0, 0.7]),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomLeft,
                  // The artwork goes edge to edge; the text keeps clear of a landscape phone's cutout
                  child: SafeArea(
                    top: false,
                    bottom: false,
                    child: Padding(padding: EdgeInsets.fromLTRB(wide ? 48 : 20, 0, wide ? 48 : 20, 8), child: title),
                  ),
                ),
              ],
            ),
          ),
          for (final section in body) SafeArea(top: false, bottom: false, child: section),
        ],
      ),
    );
  }
}

/// Title block over the artwork: poster (wide screens), title, facts, genres and actions.
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({
    required this.title,
    this.poster,
    this.originalTitle,
    this.facts = const [],
    this.genres = const [],
    this.actions = const [],
  });

  final String title;
  final String? poster, originalTitle;
  final List<String> facts, genres;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final short = isShort(context);
    final text = Theme.of(context).textTheme;
    final info = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: short ? 2 : 3,
          overflow: TextOverflow.ellipsis,
          style: wide && !short ? text.displaySmall : text.headlineMedium,
        ),
        if (originalTitle != null && originalTitle!.toLowerCase() != title.toLowerCase()) ...[
          const SizedBox(height: 6),
          Text(
            originalTitle!,
            style: const TextStyle(color: AppColors.muted, fontStyle: FontStyle.italic),
          ),
        ],
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(facts.join('   ·   '), style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
        if (genres.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final g in genres)
                Panel(
                  radius: 6,
                  color: const Color(0x33FFFFFF),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Text(g, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ),
            ],
          ),
        ],
        if (actions.isNotEmpty) ...[
          SizedBox(height: short ? 14 : 22),
          Wrap(spacing: 12, runSpacing: 12, children: actions),
        ],
      ],
    );
    if (!wide) return info;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          width: short ? 140 : 190,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppRadius.card)),
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: NetImage(poster, label: title),
          ),
        ),
        SizedBox(width: short ? 24 : 32),
        Expanded(child: info),
      ],
    );
  }
}

/// Synopsis on the left, a facts table on the right (stacked on phones).
class _Overview extends StatelessWidget {
  const _Overview({this.plot, this.facts = const []});

  final String? plot;
  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final synopsis = plot == null
        ? const SizedBox.shrink()
        : Text(plot!, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 17, height: 1.6));
    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in facts)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                const SizedBox(height: 3),
                Text(value, style: const TextStyle(fontWeight: FontWeight.w500, height: 1.4)),
              ],
            ),
          ),
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 48 : 20, 24, wide ? 48 : 20, 8),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: synopsis),
                const SizedBox(width: 56),
                Expanded(flex: 2, child: table),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [synopsis, const SizedBox(height: 24), table],
            ),
    );
  }
}

/// "More like this", from the catalog already in memory.
/// Worked out once per page from the catalog: going through every title, it would otherwise run
/// again each time the page rebuilds, every 10 seconds with the player over it saving progress.
class _MoreLikeThis extends StatefulWidget {
  const _MoreLikeThis({required this.items});

  final List<CatalogItem> Function(CatalogData data) items;

  @override
  State<_MoreLikeThis> createState() => _MoreLikeThisState();
}

class _MoreLikeThisState extends State<_MoreLikeThis> {
  List<CatalogItem> _list = const [];

  @override
  void initState() {
    super.initState();
    final catalog = currentCatalog.value;
    if (catalog == null) return;
    final loaded = catalog.loaded;
    if (loaded != null) {
      _list = widget.items(loaded);
      return;
    }
    catalog.load().then((data) {
      if (mounted) setState(() => _list = widget.items(data));
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) =>
      _list.isEmpty ? const SizedBox.shrink() : ItemRail(title: context.l10n.moreLikeThis, items: _list);
}

class MovieDetailScreen extends StatelessWidget {
  const MovieDetailScreen({
    super.key,
    required this.source,
    required this.movie,
    this.versions = const [],
    this.picked = false,
  });

  /// Opened from its versions, this one chosen: it plays, not whichever copy is fastest.
  final bool picked;

  final ContentSource source;
  final Movie movie;

  /// The same title as the provider lists it again, per language or quality, [movie] among them;
  /// else those the open catalog knows.
  final List<Movie> versions;

  List<Movie> get _versions =>
      versions.isNotEmpty ? versions : currentCatalog.value?.loaded?.versionsOf(movie) ?? const [];

  /// Whether this profile may play [m]: a kids profile, and a movie its own page rates for adults
  /// (R, NC-17, TV-MA, 18), which the lists did not say, takes a grown-up's PIN; with no PIN set,
  /// nothing tells a grown-up apart, and it does not play.
  static Future<bool> _forThisProfile(BuildContext context, Movie m) async {
    if (!ProfileStore.instance.current.kids || !isAdultRating(m.ageRating)) return true;
    if (adultActionsHidden) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.kidsAdultTitle)));
      return false;
    }
    return confirmPin(context);
  }

  Widget _page(BuildContext context, Movie m, {bool loading = false}) {
    final l = context.l10n;
    final saved = LibraryScope.maybeOf(context)?.entry(MediaRef.movie(m));
    // One this list cannot play (saved from My list when the playlist was another kind, or gone
    // from it): the page still opens, and Play says why
    PlayItem? playable;
    Object? cannot;
    try {
      playable = movieItem(source, m);
    } on Object catch (e) {
      cannot = e;
    }
    return _DetailPage(
      backdrop: m.backdrop,
      poster: m.poster,
      trailer: _kids ? null : () => movieTrailer(source, movie),
      title: _TitleBlock(
        title: m.name,
        poster: m.poster,
        originalTitle: m.originalName,
        facts: [
          if (m.year != null) '${m.year}',
          if (m.duration != null) formatRuntime(l, m.duration!),
          if ((m.rating ?? 0) > 0) '★ ${m.rating!.toStringAsFixed(1)}',
          ?m.ageRating,
        ],
        genres: m.genres,
        actions: [
          PrimaryButton(
            autofocus: true,
            icon: Icons.play_arrow_rounded,
            label: saved != null && saved.resumable ? '${l.continueAction} · ${_clock(saved.position)}' : l.play,
            onPressed: () async {
              if (!await _forThisProfile(context, m)) return;
              if (!context.mounted) return;
              switch (playable) {
                // With its other versions, should this one fail
                case final item?:
                  await playQueue(context, [picked ? item.pinnedCopy() : item]);
                case null:
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(l, cannot!))));
              }
            },
          ),
          FavoriteButton(ref: MediaRef.movie(m)),
          if (playable case final item? when canSend(ref: MediaRef.movie(m), item: item))
            SecondaryButton(
              icon: Icons.cast_rounded,
              label: l.sendTo,
              onPressed: () async {
                if (!await _forThisProfile(context, m) || !context.mounted) return;
                final messenger = ScaffoldMessenger.of(context);
                final from = saved != null && saved.resumable ? saved.position : Duration.zero;
                final to = await sendTo(context, ref: MediaRef.movie(m), item: item, position: from);
                if (!context.mounted) return;
                switch (to) {
                  case SentToDevice(:final name):
                    messenger.showSnackBar(SnackBar(content: Text(l.sentToDevice(name))));
                  case CastToDevice(:final device):
                    // Straight to the TV: nothing plays here
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => CastScreen(device: device, item: item, from: from),
                      ),
                    );
                  case null:
                    break;
                }
              },
            ),
          if (youtubeId(m.trailer) case final id? when !_kids)
            SecondaryButton(icon: Icons.smart_display_outlined, label: l.trailer, onPressed: () => _openTrailer(id)),
        ],
      ),
      body: [
        if (saved != null && saved.resumable)
          Padding(
            padding: EdgeInsets.fromLTRB(isWide(context) ? 48 : 20, 4, 20, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(width: 300, child: ProgressLine(saved.progress)),
            ),
          ),
        _Overview(
          plot: m.plot,
          facts: [
            if (m.director != null) (l.director, m.director!),
            if (m.cast != null) (l.cast, _castList(m.cast!)),
            if (m.releaseDate != null) (l.releaseDate, formatDate(context, m.releaseDate!)),
            if (m.country != null) (l.country, m.country!),
            if (!loading && (m.bitrateKbps != null || m.sizeBytes != null)) (l.quality, _quality(m)),
          ],
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          ),
        if (_versions case final versions when versions.length > 1)
          _Versions(
            source: source,
            series: false,
            current: versions.indexWhere((v) => v.id == movie.id),
            versions: [for (final v in versions) (category: v.categoryId, detail: v.extension.toUpperCase())],
            open: (i) => MovieDetailScreen(source: source, movie: versions[i], versions: versions, picked: true),
          ),
        _MoreLikeThis(items: (data) => [for (final x in data.similarMovies(m)) CatalogItem.movie(source, x)]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = source;
    return AsyncView<Movie>(
      // The full record only adds to the listing's: without it the page is the listing's, and it
      // still plays (the stream needs nothing more)
      load: () async {
        if (s is! MovieDetails) return movie;
        try {
          return await (s as MovieDetails).movieDetail(movie);
        } on Object {
          return movie;
        }
      },
      // The listing already has most of the page; show it while the full record loads
      loading: _page(context, movie, loading: true),
      builder: (context, m) => _page(context, m),
    );
  }
}

class SeriesDetailScreen extends StatefulWidget {
  const SeriesDetailScreen({super.key, required this.source, required this.series, this.versions = const []});

  final ContentSource source;
  final Series series;

  /// The same series as the provider lists it again, per language or quality, [series] among them.
  final List<Series> versions;

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  int? _season;

  List<Series> get _versions => widget.versions.isNotEmpty
      ? widget.versions
      : currentCatalog.value?.loaded?.seriesVersionsOf(widget.series) ?? const [];

  /// Plays [e] with the rest of the series queued after it, so "next episode" just works.
  void _play(BuildContext context, SeriesDetail d, Episode e) {
    final all = [for (final list in d.seasons.values) ...list];
    playQueue(context, [
      for (final x in all)
        PlayItem(
          url: widget.source.episodeUrl(x),
          title: d.series.name,
          subtitle: ['S${x.season} · E${x.number}', ?episodeName(x, d.series.name)].join('  '),
          ref: MediaRef.episode(d.series, x),
        ),
    ], index: all.indexWhere((x) => x.id == e.id).clamp(0, all.length - 1));
  }

  /// Where "play" starts: the episode in progress, the one after the last finished, or the first.
  (Episode, bool)? _startPoint(SeriesDetail d, Library? lib) {
    final all = [for (final list in d.seasons.values) ...list];
    if (all.isEmpty) return null;
    // Of this series in any copy (another category, another provider): by title, not by id
    final key = seriesKey(MediaRef.episode(d.series, all.first));
    bool ofIt(HistoryEntry h) =>
        h.ref.kind == MediaKind.episode && (h.ref.seriesId == d.series.id || seriesKey(h.ref) == key);
    int at(HistoryEntry h) {
      final byId = all.indexWhere((x) => x.id == h.ref.id);
      return byId >= 0 ? byId : all.indexWhere((x) => x.season == h.ref.season && x.number == h.ref.number);
    }

    final last = lib?.history.where(ofIt).firstOrNull;
    final i = last == null ? -1 : at(last);
    // Never watched: the first real episode, specials (season 0) aside
    if (i < 0) return (all.firstWhere((x) => x.season > 0, orElse: () => all.first), false);
    if (last!.resumable) return (all[i], true);
    if (last.duration <= Duration.zero || last.progress < 0.95) {
      // Opened and left at once is not watched: the one left half way, else the same one again
      final open = lib!.history.where((h) => ofIt(h) && h.resumable).firstOrNull;
      final j = open == null ? -1 : at(open);
      return j >= 0 ? (all[j], true) : (all[i], false);
    }
    return i + 1 < all.length ? (all[i + 1], false) : (all[i], false);
  }

  Widget _page(BuildContext context, SeriesDetail? d, {(Object, VoidCallback)? failed}) {
    final l = context.l10n;
    final s = d?.series ?? widget.series;
    final lib = LibraryScope.maybeOf(context);
    final start = d == null ? null : _startPoint(d, lib);
    final wide = isWide(context);
    final pad = wide ? 48.0 : 20.0;
    final seasons = d?.seasons ?? const <int, List<Episode>>{};
    final season = _season ?? start?.$1.season ?? seasons.keys.firstOrNull;
    final episodes = seasons[season] ?? const <Episode>[];
    final info = d?.seasonInfo[season];
    return _DetailPage(
      backdrop: s.backdrop,
      poster: s.cover,
      // The provider's, else TMDB's: series records rarely carry a TMDB id, so by name and year
      trailer: _kids ? null : () => seriesTrailer(s),
      title: _TitleBlock(
        title: s.name,
        poster: s.cover,
        facts: [
          if (s.year != null) '${s.year}',
          if (seasons.isNotEmpty) l.seasonsCount(seasons.length),
          if ((s.rating ?? 0) > 0) '★ ${s.rating!.toStringAsFixed(1)}',
        ],
        genres: s.genres,
        actions: [
          if (start != null)
            PrimaryButton(
              autofocus: true,
              icon: Icons.play_arrow_rounded,
              label: '${start.$2 ? l.continueAction : l.play}  S${start.$1.season} · E${start.$1.number}',
              onPressed: () => _play(context, d!, start.$1),
            ),
          FavoriteButton(ref: MediaRef.series(s)),
          if (youtubeId(s.trailer) case final id? when !_kids)
            SecondaryButton(icon: Icons.smart_display_outlined, label: l.trailer, onPressed: () => _openTrailer(id)),
        ],
      ),
      body: [
        _Overview(
          plot: s.plot,
          facts: [
            if (s.director != null) (l.director, s.director!),
            if (s.cast != null) (l.cast, _castList(s.cast!)),
            if (s.episodeRuntime != null) (l.duration, formatRuntime(l, s.episodeRuntime!)),
          ],
        ),
        if (failed case (final error, final retry))
          Padding(
            padding: const EdgeInsets.all(24),
            child: CapyMessage(
              mood: capyMoodForError(error),
              text: errorText(l, error),
              style: null,
              action: SecondaryButton(icon: Icons.refresh_rounded, label: l.retry, onPressed: retry),
            ),
          )
        else if (d == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          ),
        if (seasons.length > 1)
          SizedBox(
            height: 60,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(pad, 12, pad, 8),
              children: [
                for (final n in seasons.keys)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: AppChip(
                      label: d?.seasonInfo[n]?.name ?? (n == 0 ? l.seasonSpecials : l.season(n)),
                      selected: n == season,
                      onTap: () => setState(() => _season = n),
                    ),
                  ),
              ],
            ),
          ),
        if (season != null) ...[
          SectionHeader(info?.name ?? (season == 0 ? l.seasonSpecials : l.season(season))),
          Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    if (info?.airDate != null) '${info!.airDate!.year}',
                    l.episodesCount(episodes.length),
                    if ((info?.rating ?? 0) > 0) '★ ${info!.rating!.toStringAsFixed(1)}',
                  ].join('   ·   '),
                  style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
                ),
                // Many panels repeat the series synopsis as the season overview
                if (info?.overview != null && info!.overview != s.plot) ...[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: Text(info.overview!, style: const TextStyle(color: AppColors.muted, height: 1.5)),
                  ),
                ],
              ],
            ),
          ),
        ],
        // Each worked out only when on screen: a soap may have a thousand in one season
        for (final e in episodes) _EpisodeRow(series: s, episode: e, pad: pad, onTap: () => _play(context, d!, e)),
        if (_versions case final versions when versions.length > 1)
          _Versions(
            source: widget.source,
            series: true,
            current: versions.indexWhere((v) => v.id == widget.series.id),
            versions: [for (final v in versions) (category: v.categoryId, detail: null)],
            open: (i) => SeriesDetailScreen(source: widget.source, series: versions[i], versions: versions),
          ),
        _MoreLikeThis(items: (data) => [for (final x in data.similarSeries(s)) CatalogItem.series(widget.source, x)]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AsyncView<SeriesDetail>(
    load: () => widget.source.seriesDetail(widget.series),
    loading: _page(context, null),
    // The series as listed, its seasons replaced by what went wrong and Retry
    failed: (context, error, retry) => _page(context, null, failed: (error, retry)),
    builder: (context, d) => _page(context, d),
  );
}

/// An episode of a series' page: its progress, title and date worked out only once it is built,
/// which the list does for those on screen.
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.series, required this.episode, required this.pad, required this.onTap});

  final Series series;
  final Episode episode;
  final double pad;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final wide = isWide(context);
    final s = series, e = episode;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad - 3, 0, pad - 3, 10),
      child: Focusable(
        scale: 1.01,
        onTap: onTap,
        child: ColoredBox(
          color: AppColors.surface,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: wide ? 220 : 128,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          NetImage(e.image ?? s.backdrop, icon: Icons.play_circle_outline_rounded),
                          if (LibraryScope.maybeOf(context)?.entry(MediaRef.episode(s, e)) case final h?
                              when h.progress > 0)
                            Positioned(left: 0, right: 0, bottom: 0, child: ProgressLine(h.progress, height: 4)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        switch (episodeName(e, s.name)) {
                          final name? => '${e.number}. $name',
                          null => l.episodeNumber(e.number),
                        },
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (e.duration != null) formatRuntime(l, e.duration!),
                          if (e.releaseDate != null) formatDate(context, e.releaseDate!),
                          if ((e.rating ?? 0) > 0) '★ ${e.rating!.toStringAsFixed(1)}',
                        ].join('   ·   '),
                        style: const TextStyle(color: AppColors.muted, fontSize: 13),
                      ),
                      if (e.plot != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          e.plot!,
                          maxLines: wide ? 3 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.muted, height: 1.45),
                        ),
                      ],
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
}

String _clock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return d.inHours > 0
      ? '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
      : '${d.inMinutes}:${two(d.inSeconds % 60)}';
}

/// "My list" toggle; hidden when no playlist library is open.
/// The versions of a title the provider lists more than once, by the category each is in (often
/// a language or a quality: "Latino", "4K"); the one shown is marked, the others a tap away.
class _Versions extends StatelessWidget {
  const _Versions({
    required this.source,
    required this.series,
    required this.versions,
    required this.current,
    required this.open,
  });

  final ContentSource source;
  final bool series;
  final List<({String? category, String? detail})> versions;
  final int current;
  final Widget Function(int i) open;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return FutureBuilder<List<Category>>(
      future: (series ? source.seriesCategories() : source.movieCategories()).catchError((Object _) => <Category>[]),
      builder: (context, snap) {
        final names = {for (final c in snap.data ?? const <Category>[]) c.id: categoryLabel(context.l10n, c.name)};
        final labels = [
          for (final (i, v) in versions.indexed)
            [names[v.category] ?? l.versionNumber(i + 1), if ((v.detail ?? '').isNotEmpty) v.detail!].join(' · '),
        ];
        // Copies that read the same (two in one category, same format) are numbered apart
        final count = <String, int>{};
        for (final x in labels) {
          count[x] = (count[x] ?? 0) + 1;
        }
        final seen = <String, int>{};
        for (final (i, x) in labels.indexed) {
          if (count[x]! > 1) labels[i] = '$x · ${seen[x] = (seen[x] ?? 0) + 1}';
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(isWide(context) ? 48 : 20, 28, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.versionsCount(versions.length), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Focusable(
                      radius: AppRadius.button,
                      scale: 1.03,
                      selected: i == current,
                      onTap: i == current
                          ? null
                          : () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => open(i))),
                      child: Container(
                        color: i == current ? AppColors.text : AppColors.surfaceHigh,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: i == current ? AppColors.black : AppColors.text,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class FavoriteButton extends StatelessWidget {
  const FavoriteButton({super.key, required this.ref});

  final MediaRef ref;

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.maybeOf(context);
    if (lib == null) return const SizedBox.shrink();
    final on = lib.isFavorite(ref);
    return SecondaryButton(
      icon: on ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      label: on ? context.l10n.inMyList : context.l10n.myList,
      onPressed: () => lib.toggleFavorite(ref),
    );
  }
}

/// Bottom sheet with what is on now and next on a channel.
Future<void> showChannelGuide(BuildContext context, ContentSource source, LiveChannel c, {EpgGuide? guide}) =>
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.surfaceHigh,
      // As tall as the programmes need, up to most of the screen: they scroll, the buttons stay
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (sheet) {
        final l = sheet.l10n;
        String hm(DateTime d) => clockText(sheet, d);
        // What it aired and still keeps, the latest first: a tap watches it again
        final now = DateTime.now();
        final earlier = c.hasArchive && guide != null
            ? guide.forChannel(c.epgId).where((e) => c.keeps(e.end, now)).toList().reversed.take(12).toList()
            : const <EpgEntry>[];
        void again(EpgEntry e) {
          final url = source.catchupUrl(c, e.start, e.end.difference(e.start));
          if (url == null) return;
          Navigator.pop(sheet);
          playMedia(context, url: url, title: c.name, subtitle: '${e.title} · ${dayAndClock(context, e.start)}');
        }

        return AsyncView<List<EpgEntry>>(
          load: () async => guide != null && guide.has(c.epgId) ? guide.upcoming(c.epgId) : source.shortEpg(c),
          builder: (_, epg) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 56,
                      height: 40,
                      child: NetImage(c.icon, fit: BoxFit.contain, icon: Icons.tv_rounded),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(c.name, style: Theme.of(context).textTheme.titleLarge)),
                  ],
                ),
                if (c.hasArchive) ...[
                  const SizedBox(height: 6),
                  Text(l.catchupDays(c.archiveDays), style: const TextStyle(color: AppColors.text)),
                ],
                const SizedBox(height: 12),
                if (epg.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(l.noGuide, style: const TextStyle(color: AppColors.muted)),
                  ),
                // The programmes scroll between the channel and its buttons; with a remote each is
                // a stop, so the ones below come into view (on a TV a stop with nothing to do). All
                // built, a handful: a lazy list would leave the remote no way to those not yet built
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, e) in [...epg, ...earlier].indexed) ...[
                          if (i == epg.length && earlier.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
                              child: Semantics(
                                header: true,
                                child: Text(l.watchAgain, style: const TextStyle(fontWeight: FontWeight.w700)),
                              ),
                            ),
                          Focusable(
                            scale: 1,
                            radius: 10,
                            onTap: i < epg.length ? null : () => again(e),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 70,
                                    child: e.isNow()
                                        ? Text(
                                            l.nowPlaying.toUpperCase(),
                                            style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1),
                                          )
                                        : i >= epg.length
                                        ? const Icon(Icons.replay_rounded, size: 20, color: AppColors.muted)
                                        : Text(hm(e.start), style: const TextStyle(color: AppColors.muted)),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(e.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                                        Text(
                                          i >= epg.length
                                              ? '${dayAndClock(sheet, e.start)} – ${hm(e.end)}'
                                              : '${hm(e.start)} – ${hm(e.end)}',
                                          style: const TextStyle(color: AppColors.muted, fontSize: 12),
                                        ),
                                        if (e.description != null)
                                          Text(
                                            e.description!,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(color: AppColors.muted),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    PrimaryButton(
                      autofocus: true,
                      icon: Icons.play_arrow_rounded,
                      label: l.watchLive,
                      onPressed: () {
                        Navigator.pop(sheet);
                        // the screen's context, not the closed sheet's
                        playMedia(context, url: source.liveUrl(c), title: c.name, ref: MediaRef.channel(c));
                      },
                    ),
                    FavoriteButton(ref: MediaRef.channel(c)),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
