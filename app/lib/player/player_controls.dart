// The player's controls over the video: progress bar, buttons, badges, stream info, the next
// episode's card. A part of player_screen.dart, which holds what they do.
part of 'player_screen.dart';

class _Time extends StatelessWidget {
  const _Time(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontWeight: FontWeight.w600, fontSize: 13),
  );
}

/// Gradient progress bar with buffer, hover/focus growth, drag preview and remote support.
class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onDrag,
    required this.onSeek,
    required this.onKeySkip,
    this.touch = false,
  });

  final Duration position, duration, buffered;
  final ValueChanged<Duration> onDrag, onSeek, onKeySkip;
  final bool touch; // a finger's: a taller strip to hit

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  var _hover = false, _focused = false, _dragging = false;

  double _frac(Duration d) =>
      widget.duration.inMilliseconds <= 0 ? 0 : (d.inMilliseconds / widget.duration.inMilliseconds).clamp(0.0, 1.0);

  Duration _at(double dx, double width) => widget.duration * (dx / width).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final active = _hover || _focused || _dragging;
    // To a screen reader a slider: where it is of how long, and its gesture skips as the arrows do
    return Semantics(
      slider: true,
      label: context.l10n.playbackPosition,
      value: '${_fmt(widget.position)} / ${_fmt(widget.duration)}',
      increasedValue: _fmt(widget.position + _skip),
      decreasedValue: _fmt(widget.position - _skip > Duration.zero ? widget.position - _skip : Duration.zero),
      onIncrease: () => widget.onKeySkip(_skip),
      onDecrease: () => widget.onKeySkip(-_skip),
      child: _bar(active),
    );
  }

  Widget _bar(bool active) {
    return Focus(
      debugLabel: 'progress',
      onFocusChange: (f) => setState(() => _focused = f),
      // On the bar, left/right skip 10 s like in TV apps
      onKeyEvent: (_, e) {
        if (e is KeyUpEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onKeySkip(-_skip);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
          widget.onKeySkip(_skip);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final played = _frac(widget.position);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => widget.onSeek(_at(d.localPosition.dx, w)),
              onHorizontalDragStart: (d) {
                setState(() => _dragging = true);
                widget.onDrag(_at(d.localPosition.dx, w));
              },
              onHorizontalDragUpdate: (d) => widget.onDrag(_at(d.localPosition.dx, w)),
              onHorizontalDragEnd: (_) {
                setState(() => _dragging = false);
                widget.onSeek(widget.position);
              },
              child: SizedBox(
                height: widget.touch ? 44 : 30,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.centerLeft,
                  children: [
                    // Reached with a remote or the keyboard: the ring every other focus stop has
                    if (_focused)
                      Positioned(
                        left: -10,
                        right: -10,
                        top: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: AppColors.text, width: 2),
                              borderRadius: BorderRadius.circular(AppRadius.button),
                            ),
                          ),
                        ),
                      ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      height: active ? 8 : 5,
                      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: w * _frac(widget.buffered),
                      height: active ? 8 : 5,
                      decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(4)),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: w * played,
                      height: active ? 8 : 5,
                      decoration: BoxDecoration(color: AppColors.text, borderRadius: BorderRadius.circular(4)),
                    ),
                    Positioned(
                      left: w * played - (active ? 9 : 6),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: active ? 18 : 12,
                        height: active ? 18 : 12,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [const BoxShadow(color: Colors.black54, blurRadius: 4)],
                        ),
                      ),
                    ),
                    // Where it is, as it moves: dragged, or skipped along with a remote
                    if (_dragging || _focused)
                      Positioned(
                        left: (w * played - 34).clamp(0, w - 68),
                        bottom: widget.touch ? 44 : 34,
                        child: Panel(
                          radius: 10,
                          color: AppColors.scrim,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          child: SizedBox(width: 48, child: Center(child: _Time(_fmt(widget.position)))),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.size, required this.onTap, this.focusNode});

  final bool playing;
  final double size;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Focusable(
    focusNode: focusNode,
    radius: size / 2,
    scale: 1.08,
    onTap: onTap,
    child: Semantics(
      button: true,
      label: playing ? context.l10n.pause : context.l10n.play,
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.text),
        child: Icon(
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: size * 0.52,
          color: AppColors.black,
        ),
      ),
    ),
  );
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onTap, required this.label, this.size = 44});

  final IconData icon;
  final String label; // what a screen reader says
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Focusable(
    radius: size / 2,
    scale: 1.08,
    onTap: onTap,
    child: Panel(
      radius: size,
      color: AppColors.scrim,
      child: SizedBox.square(
        dimension: size,
        child: Icon(icon, size: size * 0.5, semanticLabel: label),
      ),
    ),
  );
}

/// A control on the video: round with an icon, a pill with a text ("1x", "Fit"), or both.
class _RoundButton extends StatefulWidget {
  const _RoundButton({this.icon, this.text, required this.onTap, this.tooltip, this.size = 46});

  final IconData? icon;
  final String? text;
  final String? tooltip; // what it does: for screen readers, and shown beside an icon alone
  final VoidCallback? onTap; // null = disabled
  final double size;

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  final _tip = GlobalKey<TooltipState>();

  IconData? get icon => widget.icon;
  String? get text => widget.text;
  String? get tooltip => widget.tooltip;
  VoidCallback? get onTap => widget.onTap;
  double get size => widget.size;

  @override
  Widget build(BuildContext context) {
    final button = _button();
    final tip = tooltip;
    if (tip == null || text != null) return button;
    // An icon alone says what it does: pointed at, held, or reached with a remote or the keyboard
    return Tooltip(
      key: _tip,
      message: tip,
      excludeFromSemantics: true, // the button says it already
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
            _tip.currentState?.ensureTooltipVisible();
          }
        },
        child: button,
      ),
    );
  }

  Widget _button() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: Semantics(
      label: tooltip,
      button: true,
      child: Focusable(
        radius: AppRadius.pill,
        scale: 1.08,
        onTap: onTap,
        child: Container(
          height: size,
          constraints: BoxConstraints(minWidth: size),
          padding: EdgeInsets.symmetric(horizontal: text == null ? 0 : 16),
          decoration: BoxDecoration(
            color: const Color(0x8C000000),
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(size),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) Icon(icon, size: size * 0.48, color: onTap == null ? Colors.white30 : null),
              if (icon != null && text != null) const SizedBox(width: 8),
              if (text != null) Text(text!, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A small label over the video: "FHD", "24 FPS", the sleep timer.
class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0x8C000000),
      border: Border.all(color: Colors.white24),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14), const SizedBox(width: 5)],
        Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
      ],
    ),
  );
}

/// What the stream is, in rows of a label and a value, over the video while it plays.
class _StreamInfo extends StatelessWidget {
  const _StreamInfo(this.rows);

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Panel(
      radius: 12,
      color: AppColors.scrim,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                  ),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
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

/// The next episode, offered in this one's last seconds: now, or not at all.
class _NextCard extends StatelessWidget {
  const _NextCard({required this.next, required this.seconds, required this.onPlay, required this.onCancel});

  final PlayItem next;
  final int seconds;
  final VoidCallback onPlay, onCancel;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Panel(
      color: AppColors.scrim,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: SizedBox(
        width: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.nextEpisodeIn(seconds), style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 4),
            Text(
              next.subtitle ?? next.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                PrimaryButton(icon: Icons.play_arrow_rounded, label: l.playNow, onPressed: onPlay),
                SecondaryButton(label: l.cancel, onPressed: onCancel),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveBadge extends StatefulWidget {
  const _LiveBadge({required this.label});

  final String label;

  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion: a steady dot
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse
        ..stop()
        ..value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Panel(
    radius: AppRadius.pill,
    color: AppColors.scrim,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
          child: Container(
            width: 9,
            height: 9,
            decoration: const BoxDecoration(color: AppColors.live, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 8),
        Text(widget.label, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2, fontSize: 12)),
      ],
    ),
  );
}

/// The computer's small window (Pip on Windows), over the picture: dragged anywhere it moves, a
/// double click or its button brings the window back as it was, and while the pointer moves over
/// it, play/pause and its buttons show.
class _MiniControls extends StatefulWidget {
  const _MiniControls({required this.playing, required this.onPlayPause});

  final bool playing;
  final VoidCallback onPlayPause;

  @override
  State<_MiniControls> createState() => _MiniControlsState();
}

class _MiniControlsState extends State<_MiniControls> {
  var _shown = false;
  Timer? _hide;

  void _show() {
    if (!_shown) setState(() => _shown = true);
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 2500), () => mounted ? setState(() => _shown = false) : null);
  }

  void _gone() {
    _hide?.cancel();
    if (_shown) setState(() => _shown = false);
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onHover: (_) => _show(),
      onExit: (_) => _gone(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => DesktopWindow.instance.startDragging(),
            onDoubleTap: Pip.leave,
            onTap: _show,
          ),
          IgnorePointer(
            ignoring: !_shown,
            child: AnimatedOpacity(
              opacity: _shown ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: IgnorePointer(child: ColoredBox(color: Color(0x59000000))),
                  ),
                  Center(
                    child: _PlayButton(playing: widget.playing, size: 52, onTap: widget.onPlayPause),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RoundButton(icon: Icons.open_in_full_rounded, tooltip: l.pipBack, size: 36, onTap: Pip.leave),
                        _RoundButton(icon: Icons.close_rounded, tooltip: l.close, size: 36, onTap: Pip.close),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
