import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../device.dart';
import 'catalog.dart';
import 'common.dart';
import 'theme.dart';

/// A poster card that, kept under the mouse or the remote's focus a moment, opens a larger card
/// over it ([_PreviewCard]): the title's backdrop slowly coming closer, what it is, and with the
/// mouse the ways to watch it. No trailer here: going along a row should cost no data, and
/// trailers play on Home's carousel and on each title's page. With a remote it only shows: the arrows keep moving along the row and OK
/// opens the title as ever. One at a time; any scroll, another screen or leaving closes it.
class PreviewedPoster extends StatefulWidget {
  const PreviewedPoster({super.key, required this.item, this.autofocus = false, this.rank});

  final CatalogItem item;
  final bool autofocus;
  final int? rank; // see PosterCard.rank

  static const _mouseDelay = Duration(milliseconds: 700);
  static const _focusDelay = Duration(milliseconds: 1500); // a remote passing by does not open it

  /// The one open, anywhere.
  static _PreviewedPosterState? _open;

  @override
  State<PreviewedPoster> createState() => _PreviewedPosterState();
}

class _PreviewedPosterState extends State<PreviewedPoster> {
  Timer? _timer;
  OverlayEntry? _entry;
  ScrollPosition? _scroll;
  var _inCard = false; // the mouse is on the preview itself

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scroll?.removeListener(_close);
    _scroll = Scrollable.maybeOf(context)?.position?..addListener(_close);
    // Another screen on top, or another tab: it goes
    if (!TickerMode.valuesOf(context).enabled) _close();
  }

  @override
  void dispose() {
    _scroll?.removeListener(_close);
    _timer?.cancel();
    _remove();
    super.dispose();
  }

  void _arm({required bool mouse}) {
    // With little memory (a 1 GB TV stick), none: the poster grows when focused, and OK opens its page
    if (lowMemory) return;
    // Touch focuses a grid's first poster by itself: that is no one looking at it, as a remote's
    // focus or a mouse over it is
    if (!mouse && FocusManager.instance.highlightMode != FocusHighlightMode.traditional) return;
    _timer?.cancel();
    _timer = Timer(mouse ? PreviewedPoster._mouseDelay : PreviewedPoster._focusDelay, () => _show(mouse: mouse));
  }

  void _close() {
    _timer?.cancel();
    _remove();
  }

  /// When the mouse leaves the poster: a moment to reach the preview over it.
  void _leaving() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 250), () {
      if (!_inCard) _remove();
    });
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
    if (PreviewedPoster._open == this) PreviewedPoster._open = null;
  }

  void _show({required bool mouse}) {
    if (!mounted || _entry != null) return;
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (box == null || !box.attached || overlay == null) return;
    PreviewedPoster._open?._remove();
    PreviewedPoster._open = this;

    final card = box.localToGlobal(Offset.zero) & box.size;
    final screen = MediaQuery.sizeOf(context);
    final width = min(max(card.width * 2.3, 320.0), 440.0);
    final height = width * 9 / 16 + (mouse ? 190 : 140);
    // Within the content, clear of the side navigation: from where the row's own scroll view starts
    final row = Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    final from = row == null ? 16.0 : row.localToGlobal(Offset.zero).dx + 8;
    final left = (card.center.dx - width / 2).clamp(from, max(from, screen.width - width - 16)).toDouble();
    final top = (card.top - 24).clamp(16.0, max(16.0, screen.height - height - 16)).toDouble();

    void open(void Function(BuildContext) action) {
      _close();
      action(context);
    }

    _entry = OverlayEntry(
      builder: (_) => Positioned(
        left: left,
        top: top,
        width: width,
        child: MouseRegion(
          onEnter: (_) => _inCard = true,
          onExit: (_) {
            _inCard = false;
            _leaving();
          },
          child: IgnorePointer(
            ignoring: !mouse, // with a remote it only shows
            child: _PreviewCard(
              item: widget.item,
              actions: mouse,
              onOpen: () => open(widget.item.open),
              onPlay: widget.item.play == null ? null : () => open(widget.item.play!),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => focused ? _arm(mouse: false) : _close(),
      child: MouseRegion(
        onEnter: (_) => _arm(mouse: true),
        onExit: (_) => _leaving(),
        child: PosterCard(
          autofocus: widget.autofocus,
          rank: widget.rank,
          title: item.title,
          poster: item.poster,
          rating: item.rating,
          note: item.note,
          onTap: () {
            _close();
            item.open(context);
          },
        ),
      ),
    );
  }
}

/// The larger card over a poster: backdrop; title, facts, synopsis; and with the mouse, play and
/// details.
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.item, required this.actions, required this.onOpen, this.onPlay});

  final CatalogItem item;
  final bool actions;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final meta = [
      ?item.year?.toString(),
      if ((item.rating ?? 0) > 0) '★ ${item.rating!.toStringAsFixed(1)}',
      ...item.genres.take(2),
    ].join('  ·  ');
    // Slowly closer, as the welcome screen's backdrops
    // Reduced motion: the backdrop stays still
    final still = MediaQuery.disableAnimationsOf(context);
    Widget art(String? backdrop) => TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: still ? 1.0 : 1.12),
      duration: const Duration(seconds: 12),
      curve: Curves.easeOut,
      builder: (_, scale, image) => Transform.scale(scale: scale, child: image),
      child: NetImage(backdrop ?? item.poster, icon: null),
    );
    return Material(
      color: AppColors.surface,
      elevation: 16,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
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
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                  if (item.plot != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      item.plot!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(height: 1.4, fontSize: 13),
                    ),
                  ],
                  if (actions) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        if (onPlay != null)
                          PrimaryButton(icon: Icons.play_arrow_rounded, label: l.play, onPressed: onPlay),
                        SecondaryButton(icon: Icons.info_outline_rounded, label: l.details, onPressed: onOpen),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
