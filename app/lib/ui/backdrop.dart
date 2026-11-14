import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../data/poster_wall.dart';
import '../data/trending.dart';
import '../device.dart';
import 'common.dart';
import 'theme.dart';

/// The background of the screens outside a playlist: a wall of posters drifting slowly upwards
/// (see [PosterWall]) under a dark veil that keeps text legible. With [hero], the welcome screen,
/// the backdrops of what is trending this week follow one another instead, each slowly coming
/// closer. Plain black until there is anything to show. [child] is usually a [Scaffold]; it and
/// its app bar are made see-through.
class PosterBackdrop extends StatelessWidget {
  const PosterBackdrop({super.key, required this.child, this.hero = false, this.slideVeil = heroVeil});

  final Widget child;
  final bool hero;

  /// Dark enough for muted text on the brightest posters, light enough to tell them apart.
  static const veil = Color(0xC7000000);

  /// The backdrops are larger and calmer than a wall of posters, and the welcome screen has less on it.
  static const heroVeil = Color(0xB0000000);

  /// Over the backdrops of [hero]: lighter where little is written on them, as on the screensaver.
  final Color slideVeil;

  /// Off in tests that wait for the screen to settle: a moving background never does.
  static var motion = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final moving = motion && !MediaQuery.disableAnimationsOf(context);
    // A 1 GB stick recomposes the whole screen each frame for a moving wall: it keeps it still
    final light = deviceTier != DeviceTier.low;
    return ColoredBox(
      color: AppColors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ListenableBuilder(
            listenable: PosterWall.changes,
            builder: (context, _) {
              final slides = hero
                  ? [
                      for (final t in Trending.items.value)
                        if (t.backdrop != null && t.mature == false) t,
                    ]
                  : const <Trend>[];
              final posters = PosterWall.wall;
              if (slides.isEmpty && posters.isEmpty) return const SizedBox.shrink();
              return ExcludeSemantics(
                child: Stack(
                  fit: StackFit.expand,
                  children: slides.isNotEmpty
                      ? [_Slides(slides, moving: moving, zoom: moving && light, veil: slideVeil)]
                      : [_Wall(posters, moving: moving && light), const ColoredBox(color: veil)],
                ),
              );
            },
          ),
          Theme(
            data: theme.copyWith(
              scaffoldBackgroundColor: Colors.transparent,
              appBarTheme: theme.appBarTheme.copyWith(backgroundColor: Colors.transparent),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// Posters about 150 wide in columns, each drifting upwards at its own pace and coming round
/// again, filling the space. The same ones come back when there are fewer than places; the order
/// changes once a day.
class _Wall extends StatefulWidget {
  const _Wall(this.urls, {required this.moving});

  final List<String> urls;
  final bool moving;

  @override
  State<_Wall> createState() => _WallState();
}

class _WallState extends State<_Wall> with SingleTickerProviderStateMixin {
  static const gap = 6.0;

  // Seconds of drift. Only the columns' offsets change: the posters are painted once
  final _seconds = ValueNotifier(0.0);
  late final Ticker _ticker = createTicker((t) => _seconds.value = t.inMicroseconds / 1e6);

  @override
  void initState() {
    super.initState();
    if (widget.moving) _ticker.start();
  }

  @override
  void didUpdateWidget(_Wall old) {
    super.didUpdateWidget(old);
    if (widget.moving && !_ticker.isActive) _ticker.start();
    if (!widget.moving && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now().difference(DateTime(2020)).inDays;
    final posters = [...widget.urls]..shuffle(Random(today));
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, box) {
          final columns = max(4, (box.maxWidth / 150).ceil());
          final width = (box.maxWidth - gap * (columns - 1)) / columns, height = width * 1.5;
          // Enough per column to cover the screen while a whole round of them goes by
          final perColumn = (box.maxHeight / (height + gap)).ceil() + 1;
          final round = perColumn * (height + gap);
          return ClipRect(
            child: Stack(
              children: [
                for (var c = 0; c < columns; c++)
                  Positioned(
                    left: c * (width + gap),
                    top: 0,
                    width: width,
                    child: ValueListenableBuilder(
                      valueListenable: _seconds,
                      builder: (context, seconds, column) {
                        // Between 5 and 11 points a second, the columns set off from each other
                        final speed = 5.0 + (c * 7 % 4) * 2, start = (c % 3) * height / 3 + c * 37;
                        return Transform.translate(
                          offset: Offset(0, -((start + seconds * speed) % round)),
                          child: column,
                        );
                      },
                      child: RepaintBoundary(
                        child: Column(
                          children: [
                            // Twice, so the second round follows the first without a seam
                            for (var r = 0; r < perColumn * 2; r++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: gap),
                                child: SizedBox(
                                  width: width,
                                  height: height,
                                  child: _Poster(posters[(c * perColumn + r % perColumn) % posters.length], width),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Poster extends StatefulWidget {
  const _Poster(this.url, this.width);

  final String url;
  final double width;

  @override
  State<_Poster> createState() => _PosterState();
}

class _PosterState extends State<_Poster> {
  late Future<Uint8List?> _bytes = PosterWall.image(widget.url);

  @override
  void didUpdateWidget(_Poster old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _bytes = PosterWall.image(widget.url);
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: ColoredBox(
      color: AppColors.surface,
      child: FutureBuilder(
        future: _bytes,
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null) return const SizedBox.expand();
          return _FadeInImage(bytes, width: widget.width);
        },
      ),
    ),
  );
}

/// [bytes] decoded at the size shown (a wall of full-size images would not fit a TV stick's
/// memory), fading in the first time.
class _FadeInImage extends StatelessWidget {
  const _FadeInImage(this.bytes, {required this.width});

  final Uint8List bytes;
  final double width;

  @override
  Widget build(BuildContext context) => Image.memory(
    bytes,
    fit: BoxFit.cover,
    width: double.infinity,
    height: double.infinity,
    cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => const SizedBox.expand(),
    frameBuilder: (_, child, frame, sync) => sync
        ? child
        : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 400), child: child),
  );
}

/// The trending backdrops, one after another: each comes slowly closer for a few seconds, then
/// fades into the next, which is fetched before it is due. A line in a corner says what it is.
class _Slides extends StatefulWidget {
  const _Slides(this.trends, {required this.moving, required this.zoom, required this.veil});

  final List<Trend> trends;
  final Color veil;
  final bool moving; // one after another
  final bool zoom; // each slowly coming closer

  @override
  State<_Slides> createState() => _SlidesState();
}

class _SlidesState extends State<_Slides> with SingleTickerProviderStateMixin {
  static const shown = Duration(seconds: 8);

  // Times each slide; a ticker, so it pauses while another screen covers this one
  late final AnimationController _clock = AnimationController(vsync: this, duration: shown)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });
  var _index = 0;
  Uint8List? _bytes;

  Trend get _trend => widget.trends[_index % widget.trends.length];

  @override
  void initState() {
    super.initState();
    _show(0);
  }

  @override
  void didUpdateWidget(_Slides old) {
    super.didUpdateWidget(old);
    if (widget.moving && !old.moving && _bytes != null) _clock.forward(from: 0);
    if (!widget.moving) _clock.stop();
  }

  /// Shows slide [i] once its image is here; one that cannot be fetched is skipped.
  Future<void> _show(int i) async {
    for (var tries = 0; tries < widget.trends.length; tries++, i++) {
      final bytes = await PosterWall.image(widget.trends[i % widget.trends.length].backdrop!);
      if (!mounted) return;
      if (bytes == null) continue;
      setState(() {
        _index = i;
        _bytes = bytes;
      });
      if (widget.moving && widget.trends.length > 1) _clock.forward(from: 0);
      return;
    }
  }

  void _next() => _show(_index + 1);

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return const SizedBox.shrink();
    final t = _trend;
    // A phone on its side has no room for the line, nor a TV's 540 points
    final tall = MediaQuery.sizeOf(context).height >= shortHeight;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 1200),
          child: _Slide(key: ValueKey(_index), bytes: bytes, moving: widget.zoom, toLeft: _index.isEven),
        ),
        ColoredBox(color: widget.veil),
        if (tall)
          Positioned(
            left: 48,
            right: 48,
            bottom: 28,
            child: SafeArea(
              // Under no Scaffold: the text needs its style from here
              child: Material(
                type: MaterialType.transparency,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 600),
                  layoutBuilder: (current, previous) =>
                      Stack(alignment: Alignment.bottomLeft, children: [...previous, ?current]),
                  child: _Caption(key: ValueKey(_index), trend: t),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One backdrop, slowly coming closer and sideways.
class _Slide extends StatefulWidget {
  const _Slide({super.key, required this.bytes, required this.moving, required this.toLeft});

  final Uint8List bytes;
  final bool moving, toLeft;

  @override
  State<_Slide> createState() => _SlideState();
}

class _SlideState extends State<_Slide> with SingleTickerProviderStateMixin {
  // Longer than a slide is shown, so it still moves while it fades out
  late final _zoom = AnimationController(vsync: this, duration: const Duration(seconds: 11));

  @override
  void initState() {
    super.initState();
    if (widget.moving) _zoom.forward();
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _zoom,
    builder: (context, image) => Transform.scale(
      scale: 1.04 + 0.1 * Curves.easeOut.transform(_zoom.value),
      alignment: widget.toLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: image,
    ),
    child: RepaintBoundary(child: _FadeInImage(widget.bytes, width: MediaQuery.sizeOf(context).width)),
  );
}

class _Caption extends StatelessWidget {
  const _Caption({super.key, required this.trend});

  final Trend trend;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          (trend.series ? l.trendingSeries : l.trendingMovie).toUpperCase(),
          style: const TextStyle(color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2),
        ),
        const SizedBox(height: 4),
        Text(
          [
            trend.title,
            if (trend.year != null) '${trend.year}',
            if ((trend.rating ?? 0) > 0) '★ ${trend.rating!.toStringAsFixed(1)}',
          ].join('  ·  '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
