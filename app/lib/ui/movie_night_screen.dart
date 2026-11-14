import 'dart:math';

import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/profiles.dart';
import '../data/settings.dart';
import '../data/source.dart';
import '../data/surprise.dart';
import '../device.dart';
import '../player/play.dart';
import '../remote/companion_server.dart';
import '../remote/companion_strings.dart';
import '../remote/movie_night.dart';
import 'backdrop.dart';
import 'common.dart';
import 'connect_screen.dart';
import 'detail_screens.dart';
import 'theme.dart';

/// Movie night on the TV: a few titles for a mood, a QR code for everyone's phone, the votes as they
/// come, and the winner, ready to play.
class MovieNightScreen extends StatefulWidget {
  const MovieNightScreen({
    super.key,
    required this.source,
    required this.data,
    required this.mood,
    required this.series,
    this.library,
  });

  final ContentSource source;
  final CatalogData data;
  final Mood mood;
  final bool series;
  final Library? library;

  static const _titles = 6;

  @override
  State<MovieNightScreen> createState() => _MovieNightScreenState();
}

class _MovieNightScreenState extends State<MovieNightScreen> {
  final _server = CompanionServer.instance;
  late final List<Object> _picks; // the Movie or Series behind each title
  late final MovieNight _night;
  var _started = false;
  NightTitle? _winner;

  @override
  void initState() {
    super.initState();
    final surprise = Surprise(widget.data, widget.library, kids: ProfileStore.instance.current.kids);
    _picks = [for (var i = 0; i < MovieNightScreen._titles; i++) ?surprise.next(widget.mood, series: widget.series)];
    _night = MovieNight([
      for (final x in _picks)
        switch (x) {
          Movie m => NightTitle(
            id: m.id,
            title: m.name,
            year: m.year,
            rating: m.rating,
            poster: m.poster,
            plot: m.plot,
          ),
          _ => () {
            final s = x as Series;
            return NightTitle(id: s.id, title: s.name, year: s.year, rating: s.rating, poster: s.cover, plot: s.plot);
          }(),
        },
    ]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || _picks.length < 2) return;
    _started = true;
    _server.night = _night;
    _server
        .hold(settings: SettingsScope.maybeOf(context), strings: companionStrings(context.l10n))
        .then((_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    if (_started) {
      if (_server.night == _night) _server.night = null;
      _server.release();
    }
    super.dispose();
  }

  Object _pickOf(NightTitle t) => _picks[_night.titles.indexOf(t)];

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return PosterBackdrop(
      child: Scaffold(
        appBar: AppBar(title: Text(l.movieNight)),
        body: _picks.length < 2
            ? Center(
                child: Text(l.nightNotEnough, style: const TextStyle(color: AppColors.muted)),
              )
            : ListenableBuilder(
                listenable: Listenable.merge([_server, _night]),
                builder: (context, _) => _winner == null ? _voting(context) : _won(context, _winner!),
              ),
      ),
    );
  }

  Widget _voting(BuildContext context) {
    final l = context.l10n;
    final link = _server.votingLink;
    final top = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (link != null && _server.reachable) QrCard(data: link.toString(), size: isTv ? 160 : 200),
        const SizedBox(width: 32),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.nightTitle, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 10),
              Text(l.nightBodyTv, style: const TextStyle(color: AppColors.muted, height: 1.5)),
              const SizedBox(height: 16),
              Text(l.nightVoters(_night.voters), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 18),
              PrimaryButton(
                autofocus: true,
                icon: Icons.emoji_events_outlined,
                label: l.nightWinner,
                onPressed: _night.voters == 0 ? null : () => setState(() => _winner = _night.winner),
              ),
            ],
          ),
        ),
      ],
    );
    Widget poster(NightTitle t, double width) => SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: NetImage(t.poster, label: t.title),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            t.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          // As the votes come
          Text(
            '${l.nightYes} ${_night.yes(t.id)}   ·   ${l.nightNo} ${_night.no(t.id)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.muted, fontSize: 13),
          ),
        ],
      ),
    );
    const gap = 16.0;
    Widget all(double width) =>
        Wrap(spacing: gap, runSpacing: gap, children: [for (final t in _night.titles) poster(t, width)]);
    // A phone on its side has no room for both: it scrolls down to the posters
    if (isShort(context)) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(32, 8, 32, 40),
        children: [top, const SizedBox(height: 28), all(150)],
      );
    }
    // A TV or a computer: all on one screen, the posters in one row as large as fits under the code,
    // so their votes are in sight as they come
    final text = MediaQuery.textScalerOf(context);
    final under = 8 + text.scale(14) * 1.5 + text.scale(13) * 1.5; // the title and the votes
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          top,
          const SizedBox(height: 20),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final n = max(1, _night.titles.length);
                final width = [150.0, (box.maxWidth - gap * (n - 1)) / n, (box.maxHeight - under) * 2 / 3].reduce(min);
                // Too small to tell apart: as many rows as they take, scrolling
                if (width < 80) return SingleChildScrollView(child: all(150));
                return Align(alignment: Alignment.topLeft, child: all(width));
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _won(BuildContext context, NightTitle t) {
    final l = context.l10n;
    final pick = _pickOf(t);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 220,
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  child: NetImage(t.poster, label: t.title),
                ),
              ),
            ),
            const SizedBox(width: 36),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l.nightWinnerTitle.toUpperCase(),
                    style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700, letterSpacing: 2),
                  ),
                  const SizedBox(height: 8),
                  Text(t.title, style: Theme.of(context).textTheme.displaySmall),
                  const SizedBox(height: 10),
                  Text(
                    '${l.nightYes} ${_night.yes(t.id)}   ·   ${l.nightNo} ${_night.no(t.id)}',
                    style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (pick is Movie)
                        PrimaryButton(
                          autofocus: true,
                          icon: Icons.play_arrow_rounded,
                          label: l.play,
                          onPressed: () => playQueue(context, [movieItem(widget.source, pick)]),
                        ),
                      SecondaryButton(
                        autofocus: pick is! Movie,
                        icon: Icons.info_outline_rounded,
                        label: l.details,
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => pick is Movie
                                ? MovieDetailScreen(source: widget.source, movie: pick)
                                : SeriesDetailScreen(source: widget.source, series: pick as Series),
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
      ),
    );
  }
}
