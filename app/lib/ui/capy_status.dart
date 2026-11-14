import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/source.dart';
import '../device.dart';
import 'theme.dart';

/// The illustration is decorative: the surrounding text describes the actual state.
enum CapyMood { loading, offline, account, error, empty, video }

CapyMood capyMoodForError(Object error) {
  if (error is! SourceException) return CapyMood.error;
  return switch (error.error) {
    SourceError.unreachable ||
    SourceError.timeout ||
    SourceError.providerBusy ||
    SourceError.offline ||
    SourceError.dns => CapyMood.offline,
    SourceError.unauthorized || SourceError.inactiveAccount || SourceError.wrongServer => CapyMood.account,
    SourceError.notFound || SourceError.emptyPlaylist => CapyMood.empty,
    SourceError.httpStatus ||
    SourceError.badResponse ||
    SourceError.badAddress ||
    SourceError.noSpace ||
    SourceError.tls => CapyMood.error,
  };
}

/// How long a mood other than loading plays before it rests on its still drawing: two loops of
/// its animation (24 frames of 100 ms, the first one the still drawing, so no jump at the end).
/// An animated image decodes every frame again, each loop, and asks for a frame of the whole app
/// ten times a second (MultiFrameImageStreamCompleter) for as long as it shows, and an empty list
/// or an error can stay on screen for minutes.
const _lively = Duration(milliseconds: 2 * 24 * 100);

/// A gentle entrance for feedback, and a small breathing motion while work is in progress. Cheap
/// anywhere: the motion repaints only its own small layer, and only loading keeps moving. A 1 GB
/// device ([lowMemory]) or animations turned off get the still drawing and no looping motion.
class CapyStatus extends StatefulWidget {
  const CapyStatus({super.key, required this.mood, this.size = 76});

  final CapyMood mood;
  final double size;

  @override
  State<CapyStatus> createState() => _CapyStatusState();
}

class _CapyStatusState extends State<CapyStatus> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  Timer? _settle;
  bool? _reduceMotion;
  var _resting = false; // played its loops: the still drawing from now on

  bool get _loading => widget.mood == CapyMood.loading;

  // A 1 GB TV stick pays for every frame, and animations turned off ask for none
  bool get _still => lowMemory || _reduceMotion == true;

  void _start() {
    _controller.stop();
    _settle?.cancel();
    _resting = false;
    if (_loading && !_still) {
      _controller
        ..duration = const Duration(milliseconds: 1400)
        ..repeat(reverse: true);
    } else if (!_loading && _reduceMotion != true) {
      // The entrance is short and plays once, on a 1 GB device too
      _controller
        ..duration = const Duration(milliseconds: 360)
        ..forward(from: 0);
      if (!lowMemory) _settle = Timer(_lively, () => setState(() => _resting = true));
    } else {
      _controller.value = _loading ? 0 : 1; // at rest
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion != reduced) {
      _reduceMotion = reduced;
      _start();
    }
  }

  @override
  void didUpdateWidget(CapyStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mood != widget.mood) _start();
  }

  @override
  void dispose() {
    _settle?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _loading ? 'icon' : widget.mood.name;
    final size = widget.size;
    final still = SvgPicture.asset('assets/branding/capy-$name.svg', width: size, height: size);
    final animated = !_still && !_resting;
    final breathing = _loading && !_still;
    return ExcludeSemantics(
      // What moves repaints this small layer alone, not the screen around it
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          child: Stack(
            children: [
              // Loaded, unseen, while the animation plays, so handing over to it shows no gap
              Opacity(opacity: animated ? 0 : 1, child: still),
              if (animated)
                Image.asset(
                  'assets/branding/capy-$name.webp',
                  width: size,
                  height: size,
                  errorBuilder: (_, _, _) => still,
                ),
            ],
          ),
          builder: (context, child) {
            final value = Curves.easeInOut.transform(_controller.value);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.translate(
                  offset: Offset(0, _loading ? -3 * value : 4 * (1 - value)),
                  child: Opacity(opacity: _loading ? 1 : value, child: child),
                ),
                if (_loading) ...[
                  const SizedBox(height: 7),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < 3; i++)
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFE9AD67).withValues(
                              alpha: breathing ? (0.35 + 0.65 * (1 - (value * 2 - i).abs()).clamp(0.0, 1.0)) : 0.8,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Capy over a short message, where a list or a page has nothing to show: empty, or failed.
class CapyMessage extends StatelessWidget {
  const CapyMessage({super.key, required this.mood, required this.text, this.style = _muted, this.action});

  static const _muted = TextStyle(color: AppColors.muted);

  final CapyMood mood;
  final String text;

  /// Muted unless given; null for the body's own, as for a failure to act on.
  final TextStyle? style;

  /// Under the message, such as a retry button.
  final Widget? action;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      CapyStatus(mood: mood, size: 68),
      const SizedBox(height: 12),
      // Said as it comes: what went wrong in place of a list
      Semantics(
        liveRegion: true,
        child: Text(text, textAlign: TextAlign.center, style: style),
      ),
      if (action != null) ...[const SizedBox(height: 16), action!],
    ],
  );
}
