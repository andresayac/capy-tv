// Search over a real provider's whole catalog: how long the index takes, and each search.
// Skipped unless the provider is given, as environment variables or in the git-ignored ../.env:
//   XTREAM_CODE / XTREAM_USERNAME / XTREAM_PASSWORD
// Never commit real credentials.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/search.dart';
import 'package:iptv_player/data/xtream.dart';

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
    for (final k in ['XTREAM_CODE', 'XTREAM_USERNAME', 'XTREAM_PASSWORD'])
      if ((env[k] ?? '').isEmpty) k,
  ];

  test(
    'the whole catalog: built once, searched in a few milliseconds',
    () async {
      final source = XtreamSource(
        server: env['XTREAM_CODE']!,
        username: env['XTREAM_USERNAME']!,
        password: env['XTREAM_PASSWORD']!,
      );
      final data = await Catalog(source).load();
      final watch = Stopwatch()..start();
      final index = await SearchIndex.of(data);
      final built = watch.elapsedMilliseconds;
      // ignore: avoid_print
      print(
        '${data.movies.length} movies, ${data.series.length} series, ${data.live.length} channels: index in $built ms',
      );
      for (final q in ['spider man', 'breakng bad', 'rey', 'la casa de papel', 'espn', 'a']) {
        watch.reset();
        final r = index.search(SearchQuery(q));
        // ignore: avoid_print
        print(
          '"$q": ${watch.elapsedMilliseconds} ms · ${r.movies.length} movies, ${r.series.length} series, '
          '${r.channels.length} channels · first: ${[...r.movies.take(2).map((g) => '${g.first.name} ×${g.length}'), ...r.series.take(2).map((g) => '${g.first.name} ×${g.length}')]}',
        );
      }
      expect(
        index.search(SearchQuery('breakng bad')).series.map((g) => g.first.name),
        anyElement(contains('Breaking Bad')),
      );
      source.close();
    },
    skip: Platform.environment['LIVE_TESTS'] != '1'
        ? 'touches a real provider: set LIVE_TESTS=1'
        : missing.isEmpty
        ? false
        : 'not set: ${missing.join(', ')}',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
