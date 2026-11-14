import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chromecast/cast_discovery.dart';
import '../chromecast/cast_plan.dart';
import '../chromecast/cast_session.dart';
import '../chromecast/chromecast_service.dart';
import '../device.dart';
import '../l10n/app_localizations.dart';
import '../player/play.dart';
import 'common.dart';
import 'send_to.dart';
import 'theme.dart';

/// What casts to a Chromecast, and its remote. The player and a movie's page open it to start a
/// cast; Home's chip comes back to the one on now. Back leaves it casting.
class CastScreen extends StatefulWidget {
  const CastScreen({super.key, this.device, this.item, this.from, this.queue = const [], this.index = 0});

  /// What to cast and where, from where; without them, the cast on now.
  final ChromecastDevice? device;
  final PlayItem? item;
  final Duration? from;

  /// What it came from, for "Play here" to go on with it (the episodes, the channels).
  final List<PlayItem> queue;
  final int index;

  @override
  State<CastScreen> createState() => _CastScreenState();
}

class _CastScreenState extends State<CastScreen> {
  ChromecastCast? _cast;
  Object? _error; // could not start: refused, or the device did not answer
  Timer? _tick; // the position moves on between statuses
  final _playFocus = FocusNode(debugLabel: 'cast play');
  double? _drag; // where the finger has the progress bar, in ms, until it lets go

  @override
  void initState() {
    super.initState();
    if (widget.device != null && widget.item != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start()); // its words come from above
    } else {
      _cast = ChromecastService.instance.current.value;
    }
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _playFocus.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final l = context.l10n;
      final cast = await ChromecastService.instance.cast(
        widget.device!,
        widget.item!,
        from: widget.from,
        words: (
          castingTo: l.castingTo(widget.device!.name),
          labels: {'channel': l.playback, 'play': l.play, 'pause': l.pause, 'stop': l.stopCasting},
        ),
      );
      if (mounted) setState(() => _cast = cast);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  PlayItem? get _item => _cast?.item ?? widget.item;
  ChromecastDevice? get _device => _cast?.device ?? widget.device;

  bool get _live => _item?.isLive ?? false;

  Future<void> _togglePlay() async {
    final session = _cast?.session;
    if (session == null) return;
    session.status.value.phase == CastPhase.playing ? await session.pause() : await session.play();
  }

  Future<void> _seekBy(Duration d) async {
    final session = _cast?.session;
    if (session == null || _live) return;
    final st = session.status.value;
    var to = st.position + d;
    if (to < Duration.zero) to = Duration.zero;
    if (st.duration case final length? when to > length) to = length;
    await session.seek(to);
  }

  Future<void> _volume(double by) async {
    final session = _cast?.session;
    final level = session?.status.value.volume;
    if (session == null || level == null) return;
    await session.setVolume((level + by).clamp(0, 1));
  }

  /// Back to this device, from where the TV was.
  Future<void> _playHere() async {
    final item = _item;
    if (item == null) return;
    final at = _cast?.status.value.position ?? widget.from ?? Duration.zero;
    await ChromecastService.instance.stop();
    if (!mounted) return;
    final queue = widget.queue.isEmpty ? [item] : widget.queue;
    final index = widget.queue.isEmpty ? 0 : widget.index;
    unawaited(
      playQueue(
        context,
        [for (final (i, q) in queue.indexed) i == index && !item.isLive ? q.startingAt(at) : q],
        index: index,
        replace: true,
      ),
    );
  }

  Future<void> _stopCasting() async {
    await ChromecastService.instance.stop();
    if (mounted) Navigator.maybePop(context);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
    } else if (key == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(const Duration(seconds: 10));
    } else if (key == LogicalKeyboardKey.mediaRewind) {
      _seekBy(const Duration(seconds: -10));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// What the status line says; empty while it plays.
  String _statusText(AppLocalizations l, CastStatus? st, int copies) {
    final name = _device?.name ?? '';
    final error = _error;
    if (error is ChromecastRefused) return castRefusalText(l, error.plan);
    if (error is CastException) return _endText(l, error.end, name, _cast?.trouble);
    if (error != null) return l.castConnectFailed(name);
    return switch (st?.phase) {
      null || CastPhase.connecting => l.castConnecting(name),
      // Each copy may take half a minute to fail: from the second on, say it goes on trying
      CastPhase.launching ||
      CastPhase.loading => st!.candidate > 0 ? l.castTrying(st.candidate + 1, copies) : l.castStarting(name),
      CastPhase.buffering => l.castBuffering,
      CastPhase.paused => l.castPaused,
      CastPhase.reconnecting => l.castLost(name),
      CastPhase.ended => _endText(l, st!.end ?? CastEnd.stopped, name, _cast?.trouble),
      CastPhase.playing || CastPhase.idle => '',
    };
  }

  static String _endText(AppLocalizations l, CastEnd end, String name, CastTrouble? trouble) => switch (end) {
    CastEnd.stopped => l.castStopped,
    CastEnd.connectFailed => l.castConnectFailed(name),
    CastEnd.launchFailed => l.castLaunchFailed(name),
    // Said why, when the relay knows: a firewall or the provider, not the TV
    CastEnd.cannotPlay => switch (trouble) {
      CastTrouble.unreached => l.castRelayUnreachable(name),
      CastTrouble.refused => l.castProviderRefused(name),
      null => l.castCannotPlay(name),
    },
    CastEnd.takenOver => l.castTakenOver(name),
    CastEnd.lost => l.castLostEnded(name),
    CastEnd.finished => l.castFinished,
  };

  static String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cast = _cast;
    final item = _item;
    final name = _device?.name ?? '';
    return ValueListenableBuilder<CastStatus?>(
      valueListenable: cast?.status ?? ValueNotifier<CastStatus?>(null),
      builder: (context, st, _) {
        final ended = _error != null || st?.phase == CastPhase.ended;
        final playing = st?.phase == CastPhase.playing;
        final length = st?.duration;
        final status = _statusText(l, st, cast?.plan.candidates.length ?? 0);
        final candidates = cast?.plan.candidates ?? const <CastCandidate>[];
        final mkv = st != null && st.candidate < candidates.length && candidates[st.candidate].isMatroska;
        return Scaffold(
          backgroundColor: AppColors.black,
          // Back without stopping what plays on the TV: a computer has no Back button of its own (a
          // remote and a phone do), and the other buttons stop it or bring it here
          appBar: isTv
              ? null
              : AppBar(
                  backgroundColor: Colors.transparent,
                  leading: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Panel(
                      radius: AppRadius.pill,
                      color: AppColors.scrim,
                      child: BackButton(onPressed: () => Navigator.maybePop(context)),
                    ),
                  ),
                ),
          // Hears the media keys from whatever has the focus; never takes it itself
          body: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onKey,
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Row(
                      children: [
                        if (item?.ref?.image case final image?) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              width: 160,
                              height: 240,
                              child: NetImage(image, fit: item!.isLive ? BoxFit.contain : BoxFit.cover),
                            ),
                          ),
                          const SizedBox(width: 32),
                        ],
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.cast_connected_rounded, size: 18, color: AppColors.muted),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(l.castingTo(name), style: const TextStyle(color: AppColors.muted)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  item?.title ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                if (item?.subtitle case final sub?) ...[
                                  const SizedBox(height: 4),
                                  Text(sub, style: const TextStyle(color: AppColors.muted)),
                                ],
                                if (status.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  // Connecting, playing, lost: said as it changes
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(status, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  ),
                                ],
                                if (mkv && !ended) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    l.castMkvMayFail(name),
                                    style: const TextStyle(color: AppColors.muted, fontSize: 13),
                                  ),
                                ],
                                if (!_live && length != null && length > Duration.zero && !ended) ...[
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      Text(_fmt(st!.position), style: const TextStyle(fontSize: 13)),
                                      Expanded(
                                        // A remote seeks with the buttons below: the bar would keep its arrows
                                        child: ExcludeFocus(
                                          excluding: isTv,
                                          child: Slider(
                                            value:
                                                _drag ??
                                                st.position.inMilliseconds.clamp(0, length.inMilliseconds).toDouble(),
                                            max: length.inMilliseconds.toDouble(),
                                            // A screen reader says where, as a time, not a number of milliseconds
                                            semanticFormatterCallback: (v) => _fmt(Duration(milliseconds: v.round())),
                                            onChanged: (v) => setState(() => _drag = v),
                                            onChangeEnd: (v) {
                                              setState(() => _drag = null);
                                              cast?.session.seek(Duration(milliseconds: v.round()));
                                            },
                                          ),
                                        ),
                                      ),
                                      Text(_fmt(length), style: const TextStyle(fontSize: 13)),
                                    ],
                                  ),
                                ],
                                if (_live && !ended) ...[
                                  const SizedBox(height: 12),
                                  Text(l.castKeepOn, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                                ],
                                const SizedBox(height: 22),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (!ended) ...[
                                      if (!_live)
                                        _CastButton(
                                          icon: Icons.replay_10_rounded,
                                          label: l.back10,
                                          onTap: () => _seekBy(const Duration(seconds: -10)),
                                        ),
                                      _CastButton(
                                        icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                        label: playing ? l.pause : l.play,
                                        focusNode: _playFocus,
                                        autofocus: true,
                                        onTap: _togglePlay,
                                      ),
                                      if (!_live)
                                        _CastButton(
                                          icon: Icons.forward_10_rounded,
                                          label: l.forward10,
                                          onTap: () => _seekBy(const Duration(seconds: 10)),
                                        ),
                                      _CastButton(
                                        icon: Icons.volume_down_rounded,
                                        label: l.volumeDown,
                                        onTap: () => _volume(-0.05),
                                      ),
                                      _CastButton(
                                        icon: Icons.volume_up_rounded,
                                        label: l.volumeUp,
                                        onTap: () => _volume(0.05),
                                      ),
                                    ],
                                    if (item != null)
                                      SecondaryButton(
                                        icon: Icons.smartphone_rounded,
                                        label: l.castPlayHere,
                                        autofocus: ended,
                                        onPressed: _playHere,
                                      ),
                                    if (!ended)
                                      SecondaryButton(
                                        icon: Icons.cast_rounded,
                                        label: l.stopCasting,
                                        onPressed: _stopCasting,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A round control of the cast's remote, focusable by a TV remote.
class _CastButton extends StatelessWidget {
  const _CastButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.autofocus = false,
    this.focusNode,
  });

  final IconData icon;
  final String label; // what it does, for screen readers and a hovering mouse
  final VoidCallback onTap;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Focusable(
      radius: 32,
      scale: 1.08,
      autofocus: autofocus,
      focusNode: focusNode,
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        width: 56,
        height: 56,
        decoration: const BoxDecoration(color: AppColors.surfaceHigh, shape: BoxShape.circle),
        child: Icon(icon, size: 28),
      ),
    ),
  );
}
