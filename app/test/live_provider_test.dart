// Smoke test against a real Xtream provider. Skipped unless credentials are given,
// either as environment variables or in the git-ignored ../.env file:
//   XTREAM_CODE=http://host:port   (server URL)
//   XTREAM_USERNAME=…
//   XTREAM_PASSWORD=…
// Never commit real credentials.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/matching.dart';
import 'package:iptv_player/data/xtream.dart';

/// Environment variables, falling back to KEY=VALUE lines from the repository's .env.
Map<String, String> _config() {
  final file = File('../.env');
  final fromFile = <String, String>{
    if (file.existsSync())
      for (final line in file.readAsLinesSync())
        if (line.contains('=') && !line.trimLeft().startsWith('#'))
          line.substring(0, line.indexOf('=')).trim(): line.substring(line.indexOf('=') + 1).trim(),
  };
  return {...fromFile, ...Platform.environment};
}

void main() {
  final env = _config();
  final url = env['XTREAM_CODE'], user = env['XTREAM_USERNAME'], pass = env['XTREAM_PASSWORD'];
  final skip = Platform.environment['LIVE_TESTS'] != '1'
      ? 'touches a real provider: set LIVE_TESTS=1'
      : url == null || user == null || pass == null
      ? 'XTREAM_CODE/USERNAME/PASSWORD not set'
      : false;

  test(
    'real provider: login, catalog and a playable stream URL',
    () async {
      final s = XtreamSource(server: url!, username: user!, password: pass!);
      final account = await s.login();
      expect(account.status.toLowerCase(), 'active');

      final liveCats = await s.liveCategories();
      final movieCats = await s.movieCategories();
      final seriesCats = await s.seriesCategories();
      expect(liveCats, isNotEmpty);

      final channels = await s.liveChannels(liveCats.first.id);
      final movies = movieCats.isEmpty ? const [] : await s.movies(movieCats.first.id);
      final series = seriesCats.isEmpty ? const [] : await s.series(seriesCats.first.id);
      final detail = series.isEmpty ? null : await s.seriesDetail(series.first);

      // The stream endpoint must answer (redirects to the load balancer are fine)
      if (movies.isNotEmpty) {
        final req = http.Request('GET', Uri.parse(s.movieUrl(movies.first)))..headers['Range'] = 'bytes=0-1023';
        final res = await http.Client().send(req);
        expect(res.statusCode, anyOf(200, 206));
      }

      // ignore: avoid_print
      print(
        'live categories: ${liveCats.length}, channels in first: ${channels.length}, '
        'movie categories: ${movieCats.length}, movies in first: ${movies.length}, '
        'series categories: ${seriesCats.length}, series in first: ${series.length}, '
        'seasons in first series: ${detail?.seasons.length}, expires: ${account.expires}',
      );
      s.close();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'real provider: titles and channels are found again by name, as with another provider',
    () async {
      final s = XtreamSource(server: url!, username: user!, password: pass!);
      final data = await Catalog(s).load();
      final rnd = Random(7);
      List<T> pick<T>(List<T> l, int n) => [for (var i = 0; i < n; i++) l[rnd.nextInt(l.length)]];
      // The same items as another provider would list them: unknown ids, so only names (and,
      // for some movies, the TMDB id from the full record) can find them
      final movies = pick(data.movies, 40);
      final refs = <(MediaRef, String)>[
        for (final (i, m) in movies.indexed)
          (
            MediaRef(
              kind: MediaKind.movie,
              id: 'other-$i',
              title: m.name,
              year: m.year,
              tmdb: i.isEven ? (await s.movieDetail(m)).tmdbId : null,
            ),
            m.id,
          ),
        for (final x in pick(data.series, 10))
          (MediaRef(kind: MediaKind.series, id: 'other', title: x.name, year: x.year), x.id),
        for (final c in pick(data.live, 20))
          (MediaRef(kind: MediaKind.live, id: 'other', title: c.name, epgId: c.epgId), c.id),
      ];
      final migration = LibraryMigration(source: s, catalog: data);
      var right = 0, missing = 0, sameName = 0;
      for (final (ref, id) in refs) {
        final found = await migration.find(ref);
        if (found == null) {
          missing++;
        } else if (found.id == id) {
          right++;
        } else {
          sameName++; // a duplicate entry of the same title or channel (another quality, a copy)
        }
      }
      // ignore: avoid_print
      print('of ${refs.length}: $right same item, $sameName a namesake, $missing not found');
      expect(missing, 0, reason: 'everything a provider lists can be found by its own name');
      expect(right + sameName, refs.length);
      s.close();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
