import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/profiles.dart';
import '../data/source.dart';
import '../data/surprise.dart';
import '../l10n/app_localizations.dart';
import '../player/play.dart';
import 'backdrop.dart';
import 'catalog.dart';
import 'common.dart';
import 'detail_screens.dart';
import 'movie_night_screen.dart';
import 'theme.dart';

/// "Surprise me": a mood and movie or series, then one title to watch, and another if not that one.
class SurpriseScreen extends StatefulWidget {
  const SurpriseScreen({super.key, required this.source, required this.catalog, this.library});

  final ContentSource source;

  /// May still be on its way: the screen opens at once and says how far it has got.
  final Catalog catalog;
  final Library? library;

  @override
  State<SurpriseScreen> createState() => _SurpriseScreenState();
}

class _SurpriseScreenState extends State<SurpriseScreen> {
  Surprise? _surprise;
  var _mood = Mood.laugh;
  var _series = false;
  Object? _pick;
  var _none = false; // nothing left for this mood

  void _next(CatalogData data) {
    final pick = _surpriseFor(data).next(_mood, series: _series && data.series.isNotEmpty);
    setState(() {
      _pick = pick;
      _none = pick == null;
    });
    // Below the moods and buttons, on a phone on its side it would be just off the screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final shown = _shown.currentContext;
      if (mounted && shown != null) Scrollable.ensureVisible(shown, duration: const Duration(milliseconds: 300));
    });
  }

  final _shown = GlobalKey(); // the pick, or the note that there is none

  Surprise _surpriseFor(CatalogData data) =>
      _surprise ??= Surprise(data, widget.library, kids: ProfileStore.instance.current.kids);

  static String _moodName(AppLocalizations l, Mood m) => switch (m) {
    Mood.laugh => l.moodLaugh,
    Mood.action => l.moodAction,
    Mood.suspense => l.moodSuspense,
    Mood.family => l.moodFamily,
    Mood.romance => l.moodRomance,
    Mood.scary => l.moodScary,
    Mood.different => l.moodDifferent,
  };

  @override
  Widget build(BuildContext context) => PosterBackdrop(
    child: Scaffold(
      appBar: AppBar(title: Text(context.l10n.surpriseMe)),
      body: AsyncView<CatalogData>(
        load: widget.catalog.load,
        loading: const Center(child: ListLoading()),
        builder: _choices,
      ),
    ),
  );

  Widget _choices(BuildContext context, CatalogData data) {
    final l = context.l10n;
    final kids = ProfileStore.instance.current.kids;
    final moods = [
      for (final m in Mood.values)
        if (!(kids && m == Mood.scary)) m,
    ];
    final series = _series && data.series.isNotEmpty; // none to choose from: movies
    // A list that says no genres nor ratings: no moods to choose from
    final byMood = _surpriseFor(data).picksByMood(series: series);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
      children: [
        if (byMood) ...[
          Text(l.surpriseQuestion, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (i, m) in moods.indexed)
                AppChip(
                  label: _moodName(l, m),
                  selected: _mood == m,
                  autofocus: i == 0,
                  onTap: () => setState(() => _mood = m),
                ),
            ],
          ),
        ] else
          Text(kids ? l.surpriseNoInfoKids : l.surpriseAtRandom, style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          children: [
            AppChip(
              label: l.movies,
              icon: Icons.movie_outlined,
              selected: !series,
              autofocus: !byMood,
              onTap: () => setState(() => _series = false),
            ),
            if (data.series.isNotEmpty)
              AppChip(
                label: l.series,
                icon: Icons.video_library_outlined,
                selected: series,
                onTap: () => setState(() => _series = true),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            PrimaryButton(
              icon: Icons.casino_outlined,
              label: _pick == null ? l.surpriseGo : l.surpriseAnother,
              onPressed: () => _next(data),
            ),
            // Everyone in the room votes from their phone
            SecondaryButton(
              icon: Icons.how_to_vote_outlined,
              label: l.movieNight,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MovieNightScreen(
                    source: widget.source,
                    data: data,
                    library: widget.library,
                    mood: _mood,
                    series: series,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        if (_none)
          Text(
            key: _shown,
            l.surpriseNone,
            style: const TextStyle(color: AppColors.muted),
          ),
        if (_pick case final pick?) _Pick(key: _shown, source: widget.source, pick: pick),
      ],
    );
  }
}

/// The title picked: its poster, what it is, and the way to watch it.
class _Pick extends StatelessWidget {
  const _Pick({super.key, required this.source, required this.pick});

  final ContentSource source;
  final Object pick;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final item = pick is Movie ? CatalogItem.movie(source, pick as Movie) : CatalogItem.series(source, pick as Series);
    final meta = [
      ?item.year?.toString(),
      if ((item.rating ?? 0) > 0) '★ ${item.rating!.toStringAsFixed(1)}',
      ...item.genres.take(3),
    ].join('   ·   ');
    return Panel(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 150, height: 225, child: NetImage(item.poster, label: item.title)),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  meta,
                  style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
                ),
                if (item.plot != null) ...[
                  const SizedBox(height: 12),
                  Text(item.plot!, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(height: 1.5)),
                ],
                const SizedBox(height: 18),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (pick is Movie)
                      PrimaryButton(
                        icon: Icons.play_arrow_rounded,
                        label: l.play,
                        onPressed: () => playQueue(context, [movieItem(source, pick as Movie)]),
                      ),
                    SecondaryButton(
                      icon: Icons.info_outline_rounded,
                      label: l.details,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => pick is Movie
                              ? MovieDetailScreen(source: source, movie: pick as Movie)
                              : SeriesDetailScreen(source: source, series: pick as Series),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
