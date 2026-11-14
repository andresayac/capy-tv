// Recommendations from a real language model over the real provider's catalog. Skipped unless
// both are given, as environment variables or in the git-ignored ../.env file:
//   XTREAM_CODE / XTREAM_USERNAME / XTREAM_PASSWORD   (the provider)
//   AI_BASE_URL=https://ollama.com/v1                  (any OpenAI-compatible service)
//   AI_MODEL=…
//   AI_API_KEY=…
// Never commit real credentials.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/recommender.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, String> _config() {
  final file = File('../.env');
  return {
    if (file.existsSync())
      for (final line in file.readAsLinesSync())
        if (line.contains('=') && !line.trimLeft().startsWith('#'))
          line.substring(0, line.indexOf('=')).trim(): line.substring(line.indexOf('=') + 1).trim(),
    ...Platform.environment,
  };
}

void main() {
  final env = _config();
  final missing = [
    for (final k in ['XTREAM_CODE', 'XTREAM_USERNAME', 'XTREAM_PASSWORD', 'AI_MODEL', 'AI_API_KEY'])
      if ((env[k] ?? '').isEmpty) k,
  ];

  test(
    'a real model picks from the real catalog, with reasons',
    () async {
      SharedPreferences.setMockInitialValues({});
      final source = XtreamSource(
        server: env['XTREAM_CODE']!,
        username: env['XTREAM_USERNAME']!,
        password: env['XTREAM_PASSWORD']!,
      );
      final data = await Catalog(source).load();
      // Someone who watches crime dramas
      final library = await Library.load('live', 'someone');
      for (final name in ['peaky', 'ozark', 'narcos', 'breaking bad']) {
        final s = data.series.where((s) => s.name.toLowerCase().contains(name)).firstOrNull;
        if (s != null) await library.toggleFavorite(MediaRef.series(s));
      }
      final m = data.movies.where((m) => (m.genre ?? '').toLowerCase().contains('crim')).firstOrNull;
      if (m != null) {
        await library.record(
          MediaRef.movie(m),
          position: const Duration(minutes: 90),
          duration: const Duration(minutes: 100),
        );
      }

      final service = AiService(
        baseUrl: env['AI_BASE_URL'] ?? AiService.defaultUrl,
        model: env['AI_MODEL']!,
        apiKey: env['AI_API_KEY']!,
      );
      final watch = Stopwatch()..start();
      final picks = await Recommender.refresh(library, data, language: 'Spanish', using: service);
      // ignore: avoid_print
      print('taste: ${Recommender.tasteOf(library).watched} ${Recommender.tasteOf(library).listed}');
      for (final p in picks!) {
        // ignore: avoid_print
        print('${p.item is Series ? 'series' : 'movie '} ${(p.item as dynamic).name} — ${p.why}');
      }
      // ignore: avoid_print
      print('answered in ${watch.elapsed.inSeconds} s');
      expect(picks.length, greaterThanOrEqualTo(6));
      expect(picks.every((p) => p.why.isNotEmpty), isTrue, reason: 'each with why');
      source.close();
    },
    skip: Platform.environment['LIVE_TESTS'] != '1'
        ? 'touches a real model: set LIVE_TESTS=1'
        : missing.isEmpty
        ? false
        : 'not set: ${missing.join(', ')}',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
