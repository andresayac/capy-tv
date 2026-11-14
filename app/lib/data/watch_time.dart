import 'package:shared_preferences/shared_preferences.dart';

import 'profiles.dart';

/// How long each profile watched today on this device, for the kids profiles with a time per day
/// ([Profile.dailyMinutes]); and the time a grown-up added today with the PIN.
abstract final class WatchTime {
  static String _day(DateTime d) => '${d.year}-${d.month}-${d.day}';
  static String _used(String profile, DateTime day) => 'watch.$profile.${_day(day)}';
  static String _added(String profile, DateTime day) => 'watch.more.$profile.${_day(day)}';
  static String _seen(String profile) => 'watch.seen.$profile';

  /// How far the device's clock is behind a provider's, from its last login: a child who moves the
  /// date ahead does not get a new day for it. Zero until a provider has said.
  static Duration _skew = Duration.zero;

  /// A provider's clock, [epochSeconds] since 1970 as its panel reports it, at login.
  static void trustServerTime(int epochSeconds) {
    final skew = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).difference(DateTime.now());
    // A few minutes either way is two clocks being clocks
    _skew = skew.abs() < const Duration(minutes: 10) ? Duration.zero : skew;
  }

  /// Which day it is for [profile]: never one before the last it watched in, so moving the date
  /// back and forth gives no time back.
  static Future<DateTime> _today(SharedPreferences prefs, String profile, DateTime? now) async {
    final day = now ?? DateTime.now().add(_skew);
    final seen = prefs.getInt(_seen(profile));
    if (seen != null && day.millisecondsSinceEpoch < seen) return DateTime.fromMillisecondsSinceEpoch(seen);
    return day;
  }

  /// What [p] may still watch today; null when it has no limit.
  static Future<Duration?> left(Profile p, {DateTime? now}) async {
    final minutes = p.dailyMinutes;
    if (minutes == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final day = await _today(prefs, p.id, now);
    final used = prefs.getInt(_used(p.id, day)) ?? 0, added = prefs.getInt(_added(p.id, day)) ?? 0;
    return Duration(minutes: minutes + added) - Duration(seconds: used);
  }

  /// Notes that [profile] watched [d] more today; what other days noted goes.
  static Future<void> add(String profile, Duration d, {DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final day = await _today(prefs, profile, now);
    final key = _used(profile, day);
    await prefs.setInt(key, (prefs.getInt(key) ?? 0) + d.inSeconds);
    await prefs.setInt(_seen(profile), day.millisecondsSinceEpoch);
    for (final old in prefs.getKeys().where((k) => k.startsWith('watch.') && k.contains('.$profile.'))) {
      if (old != key && old != _added(profile, day) && old != _seen(profile)) await prefs.remove(old);
    }
  }

  /// [minutes] more for [profile] today (given with the PIN).
  static Future<void> addTime(String profile, int minutes, {DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _added(profile, await _today(prefs, profile, now));
    await prefs.setInt(key, (prefs.getInt(key) ?? 0) + minutes);
  }
}
