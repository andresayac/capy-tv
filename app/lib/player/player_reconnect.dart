// A live channel that drops or freezes after it started (the provider restarts it, the network
// blips): watched for a picture that stopped moving although nobody paused it, and opened again
// with growing pauses before the "unavailable" panel shows. A part of player_screen.dart: the
// screen mixes it in, and gives it what it names below.
part of 'player_screen.dart';

mixin _PlayerReconnect on State<PlayerScreen> {
  // What it needs of the player screen
  Player get player;
  PlayItem get _item;
  bool get _live;
  bool get _started;
  bool get _failed;
  bool get _background; // sound on in the background: away, it still plays
  int get _session; // a new one per item opened: a late reopen knows it is stale
  bool get _paused; // by the user: a still picture is then no stall
  bool get _reconnecting;
  set _reconnecting(bool reconnecting);
  Media _mediaFor(PlayItem item);
  void _showFailure();

  // A live stream that drops or freezes after it started (the provider restarts the channel, the
  // network blips) is opened again, with growing pauses, before the "unavailable" panel shows
  static const _stallLimit = Duration(seconds: 12);
  static const _maxReopens = 5;
  var _reopens = 0; // since it last played for a while
  var _moved = clock.now(); // when the position last moved forward (clock: tests move it on)
  var _lastPosition = Duration.zero;
  DateTime? _reopened;

  /// The app is out of sight: not a window that only lost the focus, which on a computer is inactive.
  static bool get _hidden => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached => true,
    _ => false,
  };

  /// Live only: watches for a picture that stopped moving although nobody paused it.
  void _checkStall() {
    if (!_live || !_started || _failed) return;
    final now = clock.now();
    // Paused by the user, or by the video widget as the app went to the background: no stall. Not
    // by playing: mpv reports a frozen stream as not playing too
    final away = !_background && _hidden;
    if (_paused || away) {
      _moved = now;
      return;
    }
    if (now.difference(_moved) > _stallLimit) {
      _recover();
    } else if (_reopens > 0 && !_reconnecting && now.difference(_reopened ?? now) > const Duration(minutes: 1)) {
      _reopens = 0; // it has been playing fine again
    }
  }

  /// The live stream dropped or froze after it had started: opens it again after a pause that
  /// grows each time, and gives up after a few tries.
  Future<void> _recover() async {
    if (!mounted || _failed || (_reconnecting && _reopened == null)) return; // already on it
    if (_reopens >= _maxReopens) return _showFailure();
    final session = _session, item = _item;
    setState(() => _reconnecting = true);
    _reopened = null;
    await Future<void>.delayed(Duration(seconds: 1 << _reopens++));
    if (!mounted || session != _session) return; // zapped or retried meanwhile
    // Gone to the background meanwhile: a channel that starts again would play over the launcher
    if (!_background && _hidden) return;
    _lastPosition = Duration.zero;
    // Through the relay, if it is on: the player joins the stream the relay has, or one it asks for
    // anew (a provider gone quiet is let go after RecordRelay.stall), the recording in the same file
    await player.open(_mediaFor(item));
    _reopened = _moved = clock.now();
  }
}
