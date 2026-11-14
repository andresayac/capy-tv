// Every real provider in the git-ignored ../.env, alone and combined: logs in, lists, and how much
// their catalogs share. Nothing is played. Skipped without them. Providers are numbered:
//   XTREAM_CODE / XTREAM_USERNAME / XTREAM_PASSWORD        (the first)
//   XTREAM_CODE_2 / XTREAM_USERNAME_2 / XTREAM_PASSWORD_2  (and _3, _4...; or from _1)
// Never commit real credentials.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/combined.dart';
import 'package:iptv_player/data/source.dart';
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

/// The providers in [env], in order: XTREAM_CODE, then XTREAM_CODE_1 (or _2), _2, _3... as numbered.
List<({String name, String server, String user, String password})> _providers(Map<String, String> env) {
  final suffixes = ['', for (var n = 1; n < 10; n++) '_$n'].where((s) => (env['XTREAM_CODE$s'] ?? '').isNotEmpty);
  return [
    for (final (i, suffix) in suffixes.indexed)
      // The server is the one that is an address, whichever of the two it was written under
      if ((env['XTREAM_CODE$suffix']!, env['XTREAM_USERNAME$suffix'] ?? '') case (final code, final user))
        (
          name: 'Provider ${i + 1}',
          server: code.startsWith('http') || !user.startsWith('http') ? code : user,
          user: code.startsWith('http') || !user.startsWith('http') ? user : code,
          password: env['XTREAM_PASSWORD$suffix'] ?? '',
        ),
  ];
}

void main() {
  final providers = _providers(_config());

  test(
    'each provider logs in and lists; together, how much they share',
    () async {
      final parts = <CombinedPart>[];
      for (final p in providers) {
        final s = XtreamSource(server: p.server, username: p.user, password: p.password);
        final watch = Stopwatch()..start();
        try {
          final account = await s.login();
          final data = await Catalog(s).load();
          // ignore: avoid_print
          print(
            '${p.name}: ${account.status}, until ${account.expires?.toIso8601String().split('T').first ?? 'never'}, '
            '${account.maxConnections ?? '?'} connections · ${data.movies.length} movies, ${data.series.length} series, '
            '${data.live.length} channels · ${watch.elapsed.inSeconds} s',
          );
          parts.add((name: p.name, source: s));
        } on SourceException catch (e) {
          // Only what went wrong: an error's text carries the server's address
          // ignore: avoid_print
          print('${p.name}: does not open: ${e.error.name}');
        } on Object catch (e) {
          // ignore: avoid_print
          print('${p.name}: does not open: ${e.runtimeType}');
        }
      }
      expect(parts, isNotEmpty, reason: 'at least one provider opens');
      if (parts.length < 2) return;

      final watch = Stopwatch()..start();
      final data = await Catalog(CombinedSource(parts)).load();
      final movies = data.movies.length, titles = {for (final m in data.movies) data.versionsOf(m).first}.length;
      final shared = {
        for (final m in data.movies)
          if ({for (final v in data.versionsOf(m)) v.id.split('~').first}.length > 1) data.versionsOf(m).first,
      }.length;
      // ignore: avoid_print
      print(
        'Together: $movies movies as $titles titles, $shared of them in more than one provider; '
        '${data.series.length} series, ${data.live.length} channels · ${watch.elapsed.inSeconds} s',
      );
      for (final p in parts) {
        (p.source as XtreamSource).close();
      }
    },
    skip: Platform.environment['LIVE_TESTS'] != '1'
        ? 'touches real providers: set LIVE_TESTS=1'
        : providers.isEmpty
        ? 'no XTREAM_CODE in ../.env'
        : false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
