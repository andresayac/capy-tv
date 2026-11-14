import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'matching.dart';

/// Where a series' opening titles start and end, as marked once on one of its episodes: its other
/// episodes then offer to skip them. Kept on this device, by the series' title, so another
/// provider's copy of the series has them too.
typedef Intro = ({Duration? start, Duration? end});

abstract final class IntroMarks {
  /// By the title in any script: one in Korean or Russian, of no Latin letters, has its own. A
  /// title in Latin letters alone has the key it always had.
  static String _key(String seriesTitle) => 'intro/${looseTitle(seriesTitle, anyScript: true)}';

  /// As marks were kept before, by the Latin letters alone: every title without them shared one.
  static String? _oldKey(String seriesTitle) {
    final latin = looseTitle(seriesTitle);
    return latin.isEmpty || latin == looseTitle(seriesTitle, anyScript: true) ? null : 'intro/$latin';
  }

  static Future<Intro?> of(String seriesTitle) async {
    final prefs = await SharedPreferences.getInstance();
    final old = _oldKey(seriesTitle);
    final raw = prefs.getString(_key(seriesTitle)) ?? (old == null ? null : prefs.getString(old));
    if (raw == null) return null;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    Duration? at(String k) => j[k] == null ? null : Duration(milliseconds: j[k] as int);
    final (start, end) = (at('start'), at('end'));
    return start == null && end == null ? null : (start: start, end: end);
  }

  static Future<void> save(String seriesTitle, Intro intro) async {
    final prefs = await SharedPreferences.getInstance();
    if (intro.start == null && intro.end == null) {
      // Taken off. Where an old key could still answer (shared with a title in Latin letters, so
      // not removed), an empty mark says it is gone
      _oldKey(seriesTitle) == null
          ? await prefs.remove(_key(seriesTitle))
          : await prefs.setString(_key(seriesTitle), '{}');
      return;
    }
    await prefs.setString(
      _key(seriesTitle),
      jsonEncode({'start': ?intro.start?.inMilliseconds, 'end': ?intro.end?.inMilliseconds}),
    );
  }

  /// Whether [intro] is marked whole: a start, and an end after it.
  static bool complete(Intro? intro) => intro?.start != null && intro?.end != null && intro!.end! > intro.start!;
}
