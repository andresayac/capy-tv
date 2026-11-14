// A profile's time per day (Profile.dailyMinutes), as the player counts it: what is watched is
// noted, said ahead at 5 and 1 minute left, and stopped when it is up, with more time for the PIN.
// A part of player_screen.dart: the screen mixes it in, and gives it what it names below.
part of 'player_screen.dart';

mixin _PlayerTimeLimit on State<PlayerScreen> {
  // What it needs of the player screen
  Player get player;
  bool get _stopped;
  FocusNode get _focus; // the player's own: the remote is back on it
  FocusNode get _wakeFocus; // the stopped panel's first button
  void _flashText(String text, {Duration time});
  Future<void> _stopPlayback();
  Future<void> _open();

  var _timeUp = false; // stopped as the profile's time for today is up: its panel shows
  Duration? _timeLeft; // what the profile may still watch today; null without a limit
  var _unsaved = Duration.zero; // watched since that was last noted

  /// Counts what a profile with a time per day watches, and stops when it is up.
  void _countTime() {
    final left = _timeLeft;
    if (left == null || _stopped || !player.state.playing) return;
    _timeLeft = left - const Duration(seconds: 1);
    _unsaved += const Duration(seconds: 1);
    // Said ahead, so it does not end mid-scene without warning
    for (final m in const [5, 1]) {
      if (_timeLeft == Duration(minutes: m)) {
        _flashText(context.l10n.timeLeftToday(m), time: const Duration(seconds: 5));
      }
    }
    if (_unsaved >= const Duration(seconds: 15)) _noteTime();
    if (_timeLeft! <= Duration.zero) _stopForTime();
  }

  void _noteTime() {
    if (_unsaved == Duration.zero) return;
    WatchTime.add(ProfileStore.instance.current.id, _unsaved);
    _unsaved = Duration.zero;
  }

  Future<void> _stopForTime() async {
    if (_stopped) return;
    _timeUp = true;
    _noteTime();
    await _stopPlayback();
  }

  /// More time today, with the PIN: on from where it stopped.
  Future<void> _moreTime() async {
    if (!ProfileStore.instance.hasPin) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.moreTimeNeedsPin)));
      return;
    }
    if (!await confirmPin(context)) return;
    await WatchTime.addTime(ProfileStore.instance.current.id, 30);
    _timeLeft = await WatchTime.left(ProfileStore.instance.current);
    if (!mounted) return;
    setState(() => _timeUp = false);
    _focus.requestFocus();
    unawaited(_open());
  }

  /// Once the profile's time for today is up.
  Widget _timeUpPanel() {
    final l = context.l10n;
    return ColoredBox(
      color: const Color(0xEB000000),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hourglass_bottom_rounded, size: 44),
              const SizedBox(height: 14),
              Text(l.timeUp, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                l.timeUpHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  PrimaryButton(
                    icon: Icons.close_rounded,
                    label: l.exitPlayer,
                    // Not autofocus, which never applied: by then the focus was back on the player, the
                    // screen's first, and from the player no arrow leads anywhere
                    focusNode: _wakeFocus,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  SecondaryButton(icon: Icons.more_time_rounded, label: l.moreTime, onPressed: _moreTime),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
