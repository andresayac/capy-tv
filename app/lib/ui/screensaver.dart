import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/profiles.dart';
import '../data/settings.dart';
import '../remote/remote_input.dart';
import 'backdrop.dart';
import 'common.dart' show clockText;
import 'profiles_screen.dart';
import 'theme.dart';
import 'title_bar.dart';

/// Watches for a while without a key, a tap or the mouse, outside the player, and then shows the
/// screensaver ([ScreenSaver]) over whatever screen is open: an idle TV is not left on one still
/// picture. The minutes come from the settings; 0 is never.
class IdleWatcher extends StatefulWidget {
  const IdleWatcher({super.key, required this.navigator, required this.child});

  /// Off in the integration tests: their long waits have no keys in them.
  static var enabled = true;

  /// After this long in the background, a profile behind a PIN asks for it again.
  @visibleForTesting
  static var relockAfter = const Duration(minutes: 20);

  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  State<IdleWatcher> createState() => _IdleWatcherState();
}

class _IdleWatcherState extends State<IdleWatcher> with WidgetsBindingObserver {
  DateTime? _left; // when the app went to the background
  var _relocking = false;
  Timer? _timer;
  var _showing = false;
  Route<void>? _saver; // the screensaver's route, while it shows
  Offset? _mouse; // where the mouse was when it came
  AppSettings? _settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_key);
    nowPlaying.addListener(_restart);
    remoteWakes = _remote;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings?.removeListener(_restart);
    _settings = SettingsScope.maybeOf(context)?..addListener(_restart);
    _restart();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    HardwareKeyboard.instance.removeHandler(_key);
    nowPlaying.removeListener(_restart);
    if (remoteWakes == _remote) remoteWakes = null;
    _settings?.removeListener(_restart);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) _left ??= DateTime.now();
    if (state != AppLifecycleState.resumed) return;
    final left = _left;
    _left = null;
    if (left != null && DateTime.now().difference(left) >= IdleWatcher.relockAfter) unawaited(_relock());
  }

  /// Whoever comes back to a device left alone may not be who opened this profile: only over what
  /// is open, as "Who's watching?" only shows at the root. A movie going on is someone there.
  Future<void> _relock() async {
    final navigator = widget.navigator.currentState;
    final store = ProfileStore.instance;
    if (navigator == null || _relocking || !store.current.locked || store.choosing || nowPlaying.value != null) return;
    _relocking = true;
    final ok = await confirmProfilePin(navigator.context, store.current, forgot: false);
    _relocking = false;
    if (!ok && navigator.mounted) switchProfile(navigator.context);
  }

  /// The phone used as a remote is someone there: it leaves the screensaver (true: that is all the
  /// key did), or the wait starts again.
  bool _remote() {
    final saver = _saver;
    if (saver != null && saver.isCurrent) {
      saver.navigator?.pop();
      return true;
    }
    _restart();
    return false;
  }

  bool _key(KeyEvent _) {
    _restart();
    return false; // seen, not taken: the screen gets it as always
  }

  void _restart() {
    _timer?.cancel();
    final minutes = _settings?.screensaverMinutes ?? 0;
    // Not while something plays: a movie is no still picture
    if (!IdleWatcher.enabled || minutes <= 0 || nowPlaying.value != null || _showing) return;
    _timer = Timer(Duration(minutes: minutes), _show);
  }

  Future<void> _show() async {
    final navigator = widget.navigator.currentState;
    if (navigator == null || nowPlaying.value != null || _showing) return;
    _showing = true;
    _mouse = null;
    final saver = _saver = PageRouteBuilder<void>(
      opaque: true,
      settings: TitleBar.noPlaylist, // the desktop title bar keeps only the logo and its buttons
      transitionDuration: const Duration(milliseconds: 900),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => const ScreenSaver(),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
    );
    await navigator.push(saver);
    _saver = null;
    _showing = false;
    _restart();
    await _relock();
  }

  /// The mouse is no idle time. While the screensaver shows, a tap, a scroll or a mouse moved on
  /// purpose on what it leaves uncovered (the desktop title bar) leaves it too; on it, it leaves
  /// by itself first.
  void _pointer(PointerEvent e) {
    final saver = _saver;
    if (saver == null || !saver.isCurrent) return _restart();
    final leave = switch (e) {
      PointerHoverEvent() => (e.position - (_mouse ??= e.position)).distance > _onPurpose,
      PointerSignalEvent() => e is PointerScrollEvent,
      _ => true,
    };
    if (leave) saver.navigator?.pop();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _pointer,
    onPointerHover: _pointer,
    onPointerSignal: _pointer,
    child: widget.child,
  );
}

/// How far a mouse goes to leave the screensaver: on purpose, not nudged by the desk.
const _onPurpose = 24.0;

/// What an idle screen shows: this week's trending backdrops, one after another, slowly coming
/// closer, and the time. Any key, tap or move of the mouse goes back to where it was.
class ScreenSaver extends StatefulWidget {
  const ScreenSaver({super.key});

  @override
  State<ScreenSaver> createState() => _ScreenSaverState();
}

class _ScreenSaverState extends State<ScreenSaver> {
  late final Timer _clock = Timer.periodic(const Duration(seconds: 20), (_) => setState(() {}));
  Offset? _mouse; // where the mouse was when the screensaver came

  @override
  void initState() {
    super.initState();
    _clock; // started
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  void _leave() {
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    // Any key leaves, and does nothing else: the screen behind should not move. It leaves as the
    // key comes up, both halves taken here: Android goes back on a Back that nobody takes as it
    // comes up, which left at its going down would close the screen behind, or the app
    onKeyEvent: (_, event) {
      if (event is KeyUpEvent) _leave();
      return KeyEventResult.handled;
    },
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _leave(),
      onPointerHover: (e) {
        // A mouse that moves on purpose, not one nudged by the desk
        final from = _mouse ??= e.position;
        if ((e.position - from).distance > _onPurpose) _leave();
      },
      onPointerSignal: (e) => e is PointerScrollEvent ? _leave() : null,
      child: PosterBackdrop(
        hero: true,
        slideVeil: const Color(0x4D000000), // only the time and a line on it: the pictures can shine
        child: Scaffold(
          body: SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(48, 36, 48, 0),
                child: Text(
                  clockText(context, DateTime.now()),
                  style: const TextStyle(
                    fontSize: 56,
                    fontWeight: FontWeight.w300,
                    color: AppColors.text,
                    letterSpacing: -1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
