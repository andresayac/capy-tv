/// When the player stops by itself, so nothing plays on all night: after a while, or when what is
/// playing ends instead of going on to the next episode.
class SleepTimer {
  SleepTimer({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// The waits offered, in minutes.
  static const choices = [15, 30, 45, 60, 90];

  DateTime? _at;
  int? _minutes;
  var _atEnd = false;

  /// The wait chosen, while it runs.
  int? get minutes => _minutes;

  bool get atEnd => _atEnd;

  bool get on => _at != null || _atEnd;

  /// Until it stops the player; null without a wait.
  Duration? get left {
    final at = _at;
    if (at == null) return null;
    final d = at.difference(_clock());
    return d.isNegative ? Duration.zero : d;
  }

  bool get due => _at != null && !_clock().isBefore(_at!);

  /// How long before stopping it says so.
  static const warning = Duration(minutes: 1);

  /// Said it stops soon: the next key or touch is someone still watching.
  bool warned = false;

  /// Time to say it stops soon (once).
  bool get warnNow => !warned && left != null && left! <= warning && left! > Duration.zero;

  /// Someone is still watching: the same wait again, from now.
  void again() {
    if (_minutes case final m?) after(m);
  }

  void after(int minutes) {
    off();
    _minutes = minutes;
    _at = _clock().add(Duration(minutes: minutes));
  }

  void whenItEnds() {
    off();
    _atEnd = true;
  }

  void off() {
    _at = null;
    _minutes = null;
    _atEnd = false;
    warned = false;
  }
}
