import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// How fast each server starts a stream, by the hour of the day, learnt from what plays: a
/// provider may be quick in the morning and crawl at night. With several copies of a title (two
/// providers, or one with several servers), the player tries the one likely fastest first.
///
/// Kept on the device; a server is its address's host and port, nothing else is noted.
class StreamStats {
  StreamStats._();

  static const _prefKey = 'streamStats';

  /// Taken for a stream that never started: worse than any that did.
  static const _failure = Duration(seconds: 30);

  /// For a server nothing is known about yet: like a fairly slow one, so a fast one known wins.
  static const _unknown = Duration(seconds: 6);

  static const _most = 50; // servers kept

  // Server → milliseconds to start, per hour of the day; null where nothing is known
  static Map<String, List<double?>> _ms = {};
  static Timer? _save;

  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefKey);
      if (raw == null) return;
      _ms = {
        for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map<String, dynamic>).entries)
          // Earlier versions noted a whole path or address when they could not read the server
          if (!key.contains('/') && !key.contains(r'\')) key: [for (final v in value as List) (v as num?)?.toDouble()],
      };
    } on Object {
      _ms = {}; // learnt again
    }
  }

  static String _server(String url) {
    final u = Uri.tryParse(url);
    return u == null || u.host.isEmpty ? '' : '${u.host}:${u.port}';
  }

  /// The stream at [url] started after [took] at [at] (now).
  static void started(String url, Duration took, {DateTime? at}) => _note(url, took, at);

  /// The stream at [url] did not start at [at] (now).
  static void failed(String url, {DateTime? at}) => _note(url, _failure, at);

  static void _note(String url, Duration took, DateTime? at) {
    final server = _server(url);
    if (server.isEmpty) return; // a recording on disk, or nothing that says where it is from
    if (!_ms.containsKey(server) && _ms.length >= _most) _ms.remove(_ms.keys.first);
    final hours = _ms[server] ??= List.filled(24, null);
    final h = (at ?? DateTime.now()).hour;
    final ms = took.inMilliseconds.toDouble();
    // Recent viewings count more: a provider that got better (or worse) shows it soon
    hours[h] = hours[h] == null ? ms : hours[h]! * 0.6 + ms * 0.4;
    _save?.cancel();
    _save = Timer(const Duration(seconds: 2), () async {
      await (await SharedPreferences.getInstance()).setString(_prefKey, jsonEncode(_ms));
    });
  }

  /// How long the server of [url] is likely to take at [at] (now): that hour, else the hours
  /// around it, else any hour, else [_unknown].
  static Duration expected(String url, {DateTime? at}) {
    final hours = _ms[_server(url)];
    if (hours == null) return _unknown;
    final h = (at ?? DateTime.now()).hour;
    for (final d in [0, 1, 23, 2, 22]) {
      if (hours[(h + d) % 24] case final ms?) return Duration(milliseconds: ms.round());
    }
    final known = hours.whereType<double>().toList();
    if (known.isEmpty) return _unknown;
    return Duration(milliseconds: (known.reduce((a, b) => a + b) / known.length).round());
  }

  /// [items] by how fast their servers are likely to start at [at] (now), fastest first; equals
  /// keep their order.
  static List<T> fastestFirst<T>(List<T> items, String Function(T) url, {DateTime? at}) {
    final indexed = [for (final (i, x) in items.indexed) (i, x, expected(url(x), at: at))];
    indexed.sort((a, b) => a.$3 != b.$3 ? a.$3.compareTo(b.$3) : a.$1.compareTo(b.$1));
    return [for (final (_, x, _) in indexed) x];
  }

  /// Forgets everything learnt (tests).
  static void reset() => _ms = {};
}
