import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/data/xtream.dart';

import 'support/stalled_body.dart';

// Responses shaped like a real XC_VM panel, mixed types included.
const _auth = {
  'user_info': {
    'username': 'demo',
    'password': 'secret',
    'auth': 1,
    'status': 'Active',
    'exp_date': '1808072805',
    'is_trial': '0',
    'active_cons': '0',
    'max_connections': '3',
    'allowed_output_formats': ['m3u8', 'ts'],
  },
  'server_info': {
    'url': 'example.com',
    'port': '80',
    'server_protocol': 'https',
    'timezone': 'America/Lima',
    'timestamp_now': 1793848408,
  },
};

final _responses = <String, Object>{
  '': _auth,
  'get_live_categories': [
    {'category_id': '10', 'category_name': 'Sports', 'parent_id': 0},
  ],
  'get_live_streams': [
    {
      'num': 1,
      'name': 'Channel One',
      'stream_id': 101,
      'stream_icon': '',
      'epg_channel_id': null,
      'tv_archive': 1,
      'tv_archive_duration': '3',
      'category_id': '10',
    },
    {'num': '2', 'name': 'Channel Two', 'stream_id': '102', 'tv_archive': 0, 'category_id': '10'},
  ],
  'get_vod_streams': [
    {
      'num': 1,
      'name': 'Film (2026)',
      'title': 'Film',
      'year': '2026',
      'stream_id': 201,
      'rating': 6.8,
      'added': '1783669690',
      'container_extension': 'mkv',
      'category_id': '20',
    },
  ],
  'get_series': [
    {
      'name': 'Show (2021)',
      'title': 'Show',
      'series_id': 301,
      'rating': '8',
      'backdrop_path': ['https://img/b.jpg'],
      'release_date': '2021-01-08',
      'category_id': '30',
    },
  ],
  'get_series_info': {
    'info': {'name': 'Show (2021)', 'plot': 'Plot'},
    'episodes': {
      '2': [
        {
          'id': '402',
          'episode_num': '1',
          'title': 'S02E01',
          'container_extension': 'mp4',
          'season': 2,
          'info': {'duration_secs': 2700},
        },
      ],
      '1': [
        {'id': '312', 'episode_num': 2, 'title': 'S01E02', 'container_extension': 'mkv', 'info': {}},
        {
          'id': '311',
          'episode_num': '1',
          'title': 'S01E01',
          'container_extension': 'mkv',
          'info': {'plot': 'Pilot'},
        },
      ],
    },
  },
  'get_short_epg': {
    'epg_listings': [
      {
        'title': base64.encode(utf8.encode('News')),
        'description': base64.encode(utf8.encode('Daily roundup')),
        'start_timestamp': '1793840000',
        'stop_timestamp': '1793843600',
      },
    ],
  },
};

XtreamSource _source({Map<String, Object>? responses}) => XtreamSource(
  server: 'https://example.com/',
  username: 'demo',
  password: 'p@ss/word',
  client: MockClient((req) async {
    expect(req.url.path, '/player_api.php');
    final body = (responses ?? _responses)[req.url.queryParameters['action'] ?? ''];
    return body == null ? http.Response('[]', 200) : http.Response(jsonEncode(body), 200);
  }),
)..hideAdult = false;

void main() {
  test('a network failure keeps the account out of what it says', () {
    final failed = http.ClientException(
      'Connection refused',
      Uri.parse('http://x/player_api.php?username=u&password=p'),
    );
    expect(failed.toString(), contains('password=p'), reason: 'what the detail must not repeat');
    expect('${SourceException(SourceError.unreachable, networkDetail(failed))}', isNot(contains('password')));
    expect(networkDetail(const FormatException('http://x/?password=p')), 'FormatException');
  });

  test('normalizes the server URL', () {
    expect(XtreamSource.normalizeServer('host.tv:8080').toString(), 'http://host.tv:8080');
    expect(XtreamSource.normalizeServer('https://host.tv/').toString(), 'https://host.tv');
    expect(XtreamSource.normalizeServer('http://host.tv:80/player_api.php?username=a').toString(), 'http://host.tv');
  });

  test('login reads the account even when numbers come as strings', () async {
    final info = await _source().login();
    expect(info.status, 'Active');
    expect(info.maxConnections, 3);
    expect(info.expires, DateTime.fromMillisecondsSinceEpoch(1808072805 * 1000));
    expect(info.formats, ['m3u8', 'ts']);
    expect(info.serverTimezone, 'America/Lima');
  });

  test('a provider that says 0 connections states no limit (it may still have one)', () {
    final info = AccountInfo.fromJson({
      'user_info': {..._auth['user_info']!, 'max_connections': '0'},
    });
    expect(info.maxConnections, isNull);
  });

  test('login takes allowed_output_formats of any shape', () {
    List<String> formats(Object? f) => AccountInfo.fromJson({
      'user_info': {..._auth['user_info']!, 'allowed_output_formats': f},
    }).formats;
    expect(formats({'0': 'ts', '2': 'm3u8'}), ['ts', 'm3u8']);
    expect(formats('m3u8,ts'), ['m3u8', 'ts']);
    expect(formats(''), isEmpty);
    expect(formats(null), isEmpty);
  });

  test('an account that only allows HLS gets HLS, whatever the setting', () async {
    final s = _source(
      responses: {
        '': {
          'user_info': {
            ..._auth['user_info']!,
            'allowed_output_formats': ['m3u8'],
          },
        },
      },
    );
    await s.login();
    expect(s.liveUrl(const LiveChannel(id: '7', name: 'x')), endsWith('/7.m3u8'));
  });

  test('an account with no status of its own logs in; one with another status does not', () async {
    final user = {..._auth['user_info']!}..remove('status');
    expect(
      (await _source(
        responses: {
          '': {'user_info': user},
        },
      ).login()).status,
      'Unknown',
    );
    await expectLater(
      _source(
        responses: {
          '': {
            'user_info': {...user, 'status': 'Expired'},
          },
        },
      ).login(),
      throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.inactiveAccount)),
    );
  });

  test('a PHP warning before the answer is skipped', () async {
    const warning = '<br />\n<b>Warning</b>:  Undefined index in <b>/var/www/api.php</b> on line <b>12</b><br />\n';
    final s = XtreamSource(
      server: 'https://example.com/',
      username: 'demo',
      password: 'pw',
      client: MockClient((req) async {
        final body = _responses[req.url.queryParameters['action'] ?? ''];
        return http.Response('$warning${jsonEncode(body ?? [])}', 200);
      }),
    )..hideAdult = false;
    expect((await s.login()).maxConnections, 3);
    expect((await s.liveChannels('10')).map((c) => c.id), ['101', '102']);
  });

  test('a playlist with a User-Agent: the panel is told it on every request, and the streams too', () async {
    final agents = <String?>[];
    final s = XtreamSource(
      server: 'https://example.com/',
      username: 'demo',
      password: 'pw',
      userAgent: 'IPTVSmartersPro',
      client: MockClient((req) async {
        agents.add(req.headers['User-Agent']);
        return http.Response(jsonEncode(_responses[req.url.queryParameters['action'] ?? ''] ?? []), 200);
      }),
    )..hideAdult = false;
    await s.login();
    await s.liveChannels('10');
    expect(agents, everyElement('IPTVSmartersPro'));
    expect(agents, isNotEmpty);
    expect(s.headersFor('https://example.com/live/demo/pw/101.ts'), {'User-Agent': 'IPTVSmartersPro'});
    expect(_source().headersFor('x'), isEmpty, reason: 'without one, the usual');
  });

  test('login rejects wrong credentials', () async {
    final s = _source(
      responses: {
        '': {
          'user_info': {'auth': 0},
        },
      },
    );
    expect(s.login(), throwsA(isA<SourceException>()));
  });

  test('live: numeric or string ids, and catch-up', () async {
    final s = _source();
    final channels = await s.liveChannels('10');
    expect(channels.map((c) => c.id), ['101', '102']);
    expect(channels.first.archiveDays, 3);
    expect(channels.first.icon, isNull); // "" counts as no logo
    expect(channels[1].hasArchive, isFalse);
    expect(s.liveUrl(channels.first), 'https://example.com/live/demo/p%40ss%2Fword/101.ts');
    expect(
      s.catchupUrl(channels.first, DateTime(2026, 11, 4, 20, 5), const Duration(minutes: 60)),
      'https://example.com/timeshift/demo/p%40ss%2Fword/60/2026-11-04:20-05/101.ts',
    );
    expect(s.catchupUrl(channels[1], DateTime(2026), const Duration(minutes: 30)), isNull);
  });

  test('movies use their real container extension in the URL', () async {
    final s = _source();
    final m = (await s.movies()).single;
    expect(m.name, 'Film');
    expect(m.year, 2026);
    expect(m.rating, 6.8);
    expect(s.movieUrl(m), 'https://example.com/movie/demo/p%40ss%2Fword/201.mkv');
  });

  test("a list's items share the values they repeat, each read as it was", () async {
    final responses = {
      'get_vod_streams': [
        for (final (id, ext) in [(1, 'mkv'), (2, 'mkv'), (3, 'mp4')])
          {
            'name': 'Heat (1995)',
            'stream_id': id,
            'plot': 'A heist goes wrong.',
            'genre': 'Crime, Drama',
            'added': '${1783669690 + id}',
            'releasedate': '1995-12-15',
            'container_extension': ext,
            'category_id': '20',
          },
      ],
    };
    final s = _source(responses: responses);
    final movies = await s.movies();
    expect([for (final m in movies) m.id], ['1', '2', '3']);
    expect([for (final m in movies) s.movieUrl(m).split('/').last], ['1.mkv', '2.mkv', '3.mp4']);
    for (final m in movies.skip(1)) {
      for (final (a, b) in [
        (m.name, movies.first.name),
        (m.plot, movies.first.plot),
        (m.genre, movies.first.genre),
        (m.categoryId, movies.first.categoryId),
      ]) {
        expect(identical(a, b), isTrue, reason: '$a');
      }
    }
    expect(identical(movies[0].extension, movies[1].extension), isTrue);
    expect(movies[2].extension, 'mp4');
    expect(
      [for (final m in movies) m.added],
      [
        for (final id in [1, 2, 3]) DateTime.fromMillisecondsSinceEpoch((1783669690 + id) * 1000),
      ],
    );
    expect(movies.first.releaseDate, DateTime(1995, 12, 15));
    expect(movies.first.genres, ['Crime', 'Drama']);
  });

  test('series: seasons and episodes come back sorted', () async {
    final s = _source();
    final serie = (await s.series()).single;
    expect(serie.rating, 8);
    expect(serie.year, 2021);
    expect(serie.backdrop, 'https://img/b.jpg');
    final d = await s.seriesDetail(serie);
    expect(d.seasons.keys, [1, 2]);
    expect(d.seasons[1]!.map((e) => e.number), [1, 2]);
    expect(d.seasons[1]!.first.plot, 'Pilot');
    expect(d.seasons[2]!.single.duration, const Duration(minutes: 45));
    expect(d.series.plot, 'Plot');
    expect(s.episodeUrl(d.seasons[1]!.first), 'https://example.com/series/demo/p%40ss%2Fword/311.mkv');
  });

  test('a soap of thousands of episodes comes whole, read off the screen\'s thread', () async {
    final s = _source(
      responses: {
        'get_series_info': {
          'info': {'name': 'Soap'},
          'episodes': {
            '1': [
              for (var n = 1; n <= 2500; n++)
                {'id': '$n', 'episode_num': n, 'title': 'Soap - S01E$n - ${'A long episode title ' * 3}'},
            ],
          },
        },
      },
    );
    final d = await s.seriesDetail(const Series(id: '1', name: 'Soap'));
    expect(d.seasons[1], hasLength(2500));
    expect(d.seasons[1]!.last.number, 2500);
  });

  test('series: seasons sent as objects, flat or with no number of their own are all kept', () {
    const base = Series(id: '1', name: 'Show');
    Map<String, Object> ep(int n, [int? season]) => {'id': '$n', 'episode_num': n, 'title': 'E$n', 'season': ?season};
    var d = SeriesDetail.fromJson(base, {
      'episodes': {
        '1': {'0': ep(1), '1': ep(2)},
        '2': [ep(3)],
      },
    });
    expect(d.seasons.keys, [1, 2]);
    expect(d.seasons[1]!.map((e) => e.number), [1, 2]);
    d = SeriesDetail.fromJson(base, {
      'episodes': [ep(1, 1), ep(2, 1), ep(1, 2)],
    });
    expect({for (final s in d.seasons.entries) s.key: s.value.length}, {1: 2, 2: 1});
    d = SeriesDetail.fromJson(base, {
      'episodes': [
        [ep(1)],
        [ep(2)],
      ],
    });
    expect(d.seasons.keys, [1, 2], reason: 'the second no longer takes the place of the first');
    d = SeriesDetail.fromJson(base, {
      'episodes': {
        '1': [ep(1, 0)],
      },
    });
    expect(d.seasons[1]!.single.season, 1, reason: '"season": 0 in season 1 is a slip');
  });

  test('short EPG: titles in Latin-1 read, plain ones kept, and one with no time at all left', () async {
    final s = _source(
      responses: {
        'get_short_epg': {
          'epg_listings': [
            {
              'title': base64.encode(latin1.encode('Información')),
              'start': '2026-11-05 20:30:00',
              'end': '2026-11-05 21:30:00',
            },
            {'title': 'News', 'start_timestamp': '1793840000', 'stop_timestamp': '1793843600'},
            {'title': base64.encode(utf8.encode('Sin hora'))},
          ],
        },
      },
    );
    final epg = await s.shortEpg(const LiveChannel(id: '101', name: 'x'));
    expect(epg.map((e) => e.title), ['Información', 'News']);
  });

  test('short EPG decodes base64', () async {
    final epg = await _source().shortEpg(const LiveChannel(id: '101', name: 'x'));
    expect(epg.single.title, 'News');
    expect(epg.single.description, 'Daily roundup');
    expect(epg.single.end.difference(epg.single.start), const Duration(hours: 1));
  });

  test('episode titles drop the repeated series name and SxxExx', () {
    Episode e(String t) => Episode(id: '1', season: 1, number: 1, title: t);
    expect(e('Lupin - S01E01 - Capítulo 1').cleanTitle('Lupin (2021)'), 'Capítulo 1');
    expect(e('Lupin (2021) - S02E10 - The End').cleanTitle('Lupin (2021)'), 'The End');
    expect(e('S01 E03: Pilot').cleanTitle('Other'), 'Pilot');
    expect(e('Pilot').cleanTitle('Show'), 'Pilot');
    expect(e('Lupin - S01E01').cleanTitle('Lupin'), 'Lupin - S01E01'); // nothing left: keep original
    expect(e('House Training').cleanTitle('House'), 'House Training', reason: 'a word that only begins like it');
    expect(e("House's Head").cleanTitle('House'), "House's Head");
    expect(e('Showdown').cleanTitle('Show'), 'Showdown');
    expect(e('Lupin - T01E05 - Capítulo 5').cleanTitle('Lupin'), 'Capítulo 5');
    expect(e('Lupin 1x05 — Capítulo 5').cleanTitle('Lupin'), 'Capítulo 5');
    expect(e('Lupin — El robo').cleanTitle('Lupin'), 'El robo');
  });

  test('lenient helpers', () {
    expect(asInt('12'), 12);
    expect(asInt(12.7), 12);
    expect(asInt('8.0'), 8);
    expect(asInt(null), isNull);
    expect(asStr('  '), isNull);
    expect(asDouble('6.5'), 6.5);
  });

  group('full lists', () {
    const channels = [
      {'name': 'News', 'stream_id': 1, 'category_id': '10'},
      {
        'name': 'Sports',
        'stream_id': 2,
        'category_id': '20',
        'category_ids': [20, 10],
      },
    ];
    late Directory dir;
    var requests = 0;
    var down = false;
    String? answer; // what the panel says instead of [channels]
    var status = 200;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('xtream-cache');
      requests = 0;
      down = false;
      answer = null;
      status = 200;
    });
    tearDown(() async {
      await backgroundRefreshes();
      dir.deleteSync(recursive: true);
    });

    XtreamSource source({bool refetch = false}) => XtreamSource(
      server: 'https://example.com/',
      username: 'demo',
      password: 'pw',
      cacheDir: dir,
      refetch: refetch,
      client: MockClient((req) async {
        requests++;
        if (down) throw const SocketException('down');
        if (answer != null) return http.Response.bytes(utf8.encode(answer!), status);
        return http.Response(jsonEncode(req.url.queryParameters['action'] == 'get_live_streams' ? channels : []), 200);
      }),
    )..hideAdult = false;

    Future<List<String>> names(XtreamSource s, [String? category]) async => [
      for (final c in await s.liveChannels(category)) c.name,
    ];

    test('are fetched once and shared by their categories, items in several included', () async {
      final s = source();
      expect(await names(s), ['News', 'Sports']);
      expect(await names(s, '10'), ['News', 'Sports'], reason: 'Sports is also in 10 (category_ids)');
      expect(await names(s, '20'), ['Sports']);
      expect(await names(s, '99'), isEmpty);
      expect(requests, 1);
    });

    test("a panel's category_id sent as a list files the item under each", () async {
      answer = jsonEncode([
        {
          'name': 'Weather',
          'stream_id': 3,
          'category_id': [30, 10],
        },
      ]);
      final s = source();
      expect(await names(s, '30'), ['Weather']);
      expect(await names(s, '10'), ['Weather']);
    });

    test('let go of (a TV stick updating them), they come back from the copy on disk', () async {
      final s = source();
      expect(await names(s), ['News', 'Sports']);
      s.forgetLists();
      down = true;
      expect(await names(s, '10'), ['News', 'Sports']);
      expect(requests, 1);
    });

    test('come from the cache for a while, and from an old copy when the panel is down', () async {
      await names(source());
      final again = source();
      expect(await names(again), ['News', 'Sports']);
      expect(requests, 1, reason: 'fresh on disk: no request');

      for (final f in dir.listSync().whereType<File>()) {
        f.setLastModifiedSync(DateTime.now().subtract(XtreamSource.listsFresh * 2));
      }
      down = true;
      expect(await names(source()), ['News', 'Sports'], reason: 'the panel is down: the last copy');
      await backgroundRefreshes();
      expect(requests, 2, reason: 'and it was asked for a new one');
    });

    test('the panel down and the copy here empty or damaged: what went wrong is said, not an empty list', () async {
      answer = '[]'; // a list of nothing, kept
      await names(source());
      answer = null;
      for (final f in dir.listSync().whereType<File>()) {
        f.setLastModifiedSync(DateTime.now().subtract(XtreamSource.listsFresh * 2));
      }
      down = true;
      await expectLater(names(source()), throwsA(isA<SourceException>()), reason: 'old and empty');
      for (final f in dir.listSync().whereType<File>()) {
        f.writeAsStringSync('[{"stream_id": 1, "na'); // cut short
      }
      await expectLater(names(source()), throwsA(isA<SourceException>()), reason: 'damaged');
    });

    test('with the panel down, a list with its lists on disk opens without the account', () async {
      down = true;
      await expectLater(source().loginOrSaved(), throwsA(isA<SourceException>()), reason: 'nothing on disk');
      down = false;
      await names(source());
      down = true;
      expect(await source().loginOrSaved(), isNull);
      down = false;
      answer = '{"user_info": {"auth": 0}}';
      await expectLater(
        source().loginOrSaved(),
        throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.unauthorized)),
        reason: 'a copy is no reason to open a wrong login',
      );
      answer = '';
      status = 404;
      await expectLater(
        source().loginOrSaved(),
        throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.wrongServer)),
        reason: 'nor is a 404 to the login, which is how some panels say they do not know it',
      );
    });

    test('updating takes neither the panel\'s error nor an empty list instead of the copy there is', () async {
      await names(source());
      answer = '{"user_info": {"auth": 0}}';
      await expectLater(
        source(refetch: true).liveChannels(),
        throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.badResponse)),
      );
      answer = '[]';
      expect(await names(source(refetch: true)), ['News', 'Sports'], reason: 'a panel rebuilding its lists');
      answer = null;
      expect(await names(source()), ['News', 'Sports'], reason: 'kept on disk');
    });

    test('updating the list asks the panel whatever the copy on disk, and takes no old copy instead', () async {
      await names(source());
      expect(await names(source(refetch: true)), ['News', 'Sports']);
      expect(requests, 2, reason: 'fresh on disk, asked again all the same');
      down = true;
      await expectLater(source(refetch: true).liveChannels(), throwsA(isA<SourceException>()));
      expect(await names(source()), ['News', 'Sports'], reason: 'the copy there was stays for a normal open');
    });

    test('a big list, sent as an object, is put on disk and read back from there item by item', () async {
      answer = jsonEncode({
        for (var i = 0; i < 6000; i++) '$i': {'name': 'Channel $i 📺', 'stream_id': i, 'category_id': '${i % 3}'},
      });
      expect(answer!.length, greaterThan(256 * 1024), reason: 'big enough to be read off the UI isolate');
      final s = source();
      final all = await s.liveChannels();
      expect(all.length, 6000);
      expect(all.first.name, 'Channel 0 📺');
      expect((await s.liveChannels('1')).length, 2000);
      final files = [for (final f in dir.listSync()) f.uri.pathSegments.last];
      expect(files, contains(endsWith('get_live_streams.json')));
      expect(files.where((f) => f.endsWith('.part')), isEmpty, reason: 'nothing half-written left behind');
    });

    test('an answer cut short is an error, and neither kept nor left behind', () async {
      answer = '[{"name": "News", "stream_id": 1}, {"name": "Spo';
      await expectLater(
        source().liveChannels(),
        throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.badResponse)),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('a list the panel refuses for the login says so', () async {
      answer = '';
      status = 401;
      await expectLater(
        source().liveChannels(),
        throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.unauthorized)),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('a playlist left while its lists and guide come stops bringing them, and reads nothing', () async {
      final list = StalledBody(utf8.encode('[{"name": "Chan')), guide = StalledBody(utf8.encode('<tv><chan'));
      final s = XtreamSource(
        server: 'https://example.com/',
        username: 'demo',
        password: 'pw',
        cacheDir: dir,
        client: MockClient.streaming(
          (req, _) async => http.StreamedResponse(req.url.path.endsWith('xmltv.php') ? guide.stream : list.stream, 200),
        ),
      );
      final channels = s.liveChannels(), programmes = s.guide();
      await Future.wait([list.listening.future, guide.listening.future]);
      s.close();
      await Future.wait([list.dropped.future, guide.dropped.future]); // their connections let go
      await expectLater(channels, throwsA(isA<DownloadStopped>()));
      expect((await programmes).isEmpty, isTrue, reason: 'nobody waits for it: no guide, and no error');
      expect(dir.listSync(), isEmpty, reason: 'their parts gone, nothing kept');
    });

    test('two loads of one list at once each get it whole, each through a file of its own', () async {
      // A playlist opened again while its first load still runs: the same list into the same cache.
      // The second starts once the first is halfway, and is still behind when the first is done
      final list = utf8.encode(
        jsonEncode([
          for (var i = 0; i < 6000; i++) {'name': 'Channel $i', 'stream_id': i, 'category_id': '1'},
        ]),
      );
      final half = list.length ~/ 2;
      final firstHalfway = Completer<void>(), secondStarted = Completer<void>(), firstDone = Completer<void>();
      var asked = 0;
      XtreamSource load(Stream<List<int>> Function() body, {Future<void>? after}) => XtreamSource(
        server: 'https://example.com/',
        username: 'demo',
        password: 'pw',
        cacheDir: dir,
        client: MockClient.streaming((req, _) async {
          if (req.url.queryParameters['action'] != 'get_live_streams') {
            return http.StreamedResponse(Stream.value(utf8.encode('[]')), 200);
          }
          asked++;
          await after;
          return http.StreamedResponse(body(), 200);
        }),
      )..hideAdult = false;

      final first = load(() async* {
        yield list.sublist(0, half);
        firstHalfway.complete();
        await secondStarted.future;
        yield list.sublist(half);
      }).liveChannels();
      final second = load(() async* {
        yield list.sublist(0, 8192);
        if (!secondStarted.isCompleted) secondStarted.complete();
        await firstDone.future;
        yield list.sublist(8192);
      }, after: firstHalfway.future).liveChannels();
      expect((await first).length, 6000);
      firstDone.complete();
      expect((await second).length, 6000);
      expect(asked, 2, reason: 'once each: neither asked again, to hold the list whole in memory instead');
      final files = [for (final f in dir.listSync()) f.uri.pathSegments.last];
      expect(files.where((f) => f.endsWith('get_live_streams.json')), hasLength(1));
      expect(files.where((f) => f.endsWith('.part')), isEmpty);
    });

    test('a failure is not kept: the next call tries again', () async {
      final s = source();
      down = true;
      await expectLater(s.liveChannels(), throwsA(isA<SourceException>()));
      down = false;
      expect(await names(s), ['News', 'Sports']);
    });

    group('an old copy', () {
      // What the panel has by now, the copy on disk having [channels]
      final newer = jsonEncode([
        {'name': 'Cinema', 'stream_id': 3, 'category_id': '10'},
      ]);

      File saved() => dir.listSync().whereType<File>().singleWhere((f) => f.path.endsWith('get_live_streams.json'));
      void makeOld() => saved().setLastModifiedSync(DateTime.now().subtract(XtreamSource.listsFresh * 2));
      List<String> parts() => [
        for (final f in dir.listSync())
          if (f.path.endsWith('.part')) f.path,
      ];
      XtreamSource streaming(MockClientStreamHandler panel) => XtreamSource(
        server: 'https://example.com/',
        username: 'demo',
        password: 'pw',
        cacheDir: dir,
        client: MockClient.streaming(panel),
      )..hideAdult = false;

      tearDown(() => streamPlaying.value = false);

      test('shows at once, and a new one comes in the background for the next load', () async {
        await names(source());
        makeOld();
        answer = newer;
        final s = source();
        expect(await names(s), ['News', 'Sports'], reason: 'the old copy, without waiting for the panel');
        await backgroundRefreshes();
        expect(requests, 2);
        expect(parts(), isEmpty, reason: 'nothing half-written left behind');
        expect(jsonDecode(saved().readAsStringSync()), jsonDecode(newer), reason: 'the file is the new one');
        expect(await names(s), ['News', 'Sports'], reason: 'this session keeps the copy it read');
        expect(await names(source()), ['Cinema'], reason: 'the next load has the new one');
        expect(requests, 2, reason: 'fresh on disk now: no request');
      });

      test('a new one big enough to be read off the UI isolate takes its place all the same', () async {
        await names(source());
        makeOld();
        answer = jsonEncode([
          for (var i = 0; i < 6000; i++) {'name': 'Channel $i', 'stream_id': i, 'category_id': '1'},
        ]);
        expect(answer!.length, greaterThan(256 * 1024));
        expect(await names(source()), ['News', 'Sports']);
        await backgroundRefreshes();
        expect((await source().liveChannels()).length, 6000);
      });

      for (final (what, body, code) in [
        ('refused for the login', '', 401),
        ('forbidden', '', 403),
        ('a server error', 'oops', 500),
        ("the panel's error instead of a list", '{"user_info": {"auth": 0}}', 200),
        ('an empty answer', '', 200),
        ('an empty list', '[]', 200),
        ('cut short', '[{"name": "Cinema", "stream_id": 3}, {"name": "Spo', 200),
        ('no JSON', '<html>Busy</html>', 200),
      ]) {
        test('keeps its place when the new one is $what', () async {
          await names(source());
          makeOld();
          final before = saved().readAsStringSync(), modified = saved().lastModifiedSync();
          answer = body;
          status = code;
          expect(await names(source()), ['News', 'Sports']);
          await backgroundRefreshes();
          expect(requests, 2);
          expect(saved().readAsStringSync(), before);
          expect(saved().lastModifiedSync(), modified, reason: 'still old: the next load tries again');
          expect(parts(), isEmpty);
          status = 200;
          answer = newer;
          await names(source());
          await backgroundRefreshes();
          expect(requests, 3, reason: 'as it did');
          expect(jsonDecode(saved().readAsStringSync()), jsonDecode(newer));
        });
      }

      test('an old copy of nothing is not shown: the panel is asked, and waited for', () async {
        answer = '[]';
        expect(await names(source()), isEmpty);
        makeOld();
        answer = newer;
        expect(await names(source()), ['Cinema'], reason: 'an empty tab for the whole session otherwise');
        expect(requests, 2);
        await backgroundRefreshes();
        expect(requests, 2, reason: 'that was the new copy: no other behind it');
      });

      test('a young copy of nothing is asked for again: it may be a panel down for a moment', () async {
        answer = '[]';
        expect(await names(source()), isEmpty);
        answer = newer;
        expect(await names(source()), ['Cinema']);
        expect(requests, 2);
      });

      test('keeps its place when the panel is down', () async {
        await names(source());
        makeOld();
        final before = saved().readAsStringSync();
        down = true;
        expect(await names(source()), ['News', 'Sports']);
        await backgroundRefreshes();
        expect(saved().readAsStringSync(), before);
        expect(parts(), isEmpty);
      });

      test('is not refreshed while something plays, only once that ends', () async {
        await names(source());
        makeOld();
        streamPlaying.value = true;
        answer = newer;
        expect(await names(source()), ['News', 'Sports']);
        await pumpEventQueue();
        expect(requests, 1, reason: 'the line is the stream\'s');
        streamPlaying.value = false;
        await backgroundRefreshes();
        expect(requests, 2);
        expect(await names(source()), ['Cinema']);
      });

      test('refreshing stops when something starts playing, its part gone, and starts over after', () async {
        await names(source());
        makeOld();
        final stalled = StalledBody(utf8.encode('[{"name": "Cin'));
        var asked = 0;
        List<String>? partsWhenAskedAgain;
        final s = streaming((_, _) async {
          if (++asked == 1) return http.StreamedResponse(stalled.stream, 200);
          partsWhenAskedAgain = parts();
          return http.StreamedResponse(Stream.value(utf8.encode(newer)), 200);
        });
        expect(await names(s), ['News', 'Sports']);
        await stalled.listening.future;
        expect(parts(), hasLength(1), reason: 'it writes to a part of its own, not to the copy');
        streamPlaying.value = true;
        await stalled.dropped.future;
        await pumpEventQueue();
        expect(asked, 1, reason: 'not again while it plays');
        streamPlaying.value = false;
        await backgroundRefreshes();
        expect(asked, 2);
        expect(partsWhenAskedAgain, isEmpty, reason: 'the part of the first try was dropped');
        expect(parts(), isEmpty);
        expect(await names(source()), ['Cinema']);
      });

      test('still waiting for its answer, it stops too when something starts playing', () async {
        await names(source());
        makeOld();
        var asked = 0;
        final waiting = Completer<void>();
        final s = streaming((req, _) async {
          if (++asked > 1) return http.StreamedResponse(Stream.value(utf8.encode(newer)), 200);
          waiting.complete();
          await (req as http.Abortable).abortTrigger;
          throw http.RequestAbortedException(req.url);
        });
        expect(await names(s), ['News', 'Sports']);
        await waiting.future;
        streamPlaying.value = true;
        await pumpEventQueue();
        expect(asked, 1, reason: 'not again while it plays');
        streamPlaying.value = false;
        await backgroundRefreshes();
        expect(asked, 2);
        expect(await names(source()), ['Cinema']);
      });

      test('a request that never answers is closed when its time is up, not left open', () async {
        final closed = Completer<void>();
        final client = MockClient.streaming((req, _) {
          (req as http.Abortable).abortTrigger!.whenComplete(closed.complete);
          return Completer<http.StreamedResponse>().future;
        });
        final file = File('${dir.path}/list.json')..writeAsStringSync('old');
        refreshInBackground(file, (part, giveWay) async {
          await downloadTo(
            client,
            Uri.parse('https://example.com/list'),
            part,
            wait: const Duration(milliseconds: 1),
            giveWay: giveWay,
          );
          return true;
        });
        await backgroundRefreshes();
        await pumpEventQueue();
        expect(closed.isCompleted, isTrue);
        expect(file.readAsStringSync(), 'old');
      });

      test('a list someone waits for takes the line from it, and it starts over after', () async {
        await names(source());
        makeOld();
        final stalled = StalledBody(utf8.encode('[{"name": "Cin'));
        var asked = 0;
        final s = streaming((_, _) async {
          if (++asked == 1) return http.StreamedResponse(stalled.stream, 200);
          return http.StreamedResponse(Stream.value(utf8.encode(newer)), 200);
        });
        expect(await names(s), ['News', 'Sports']);
        await stalled.listening.future;

        // Another list, with no copy on disk: it is asked for, and the panel takes its time
        final answer = Completer<void>();
        final waited = streaming((_, _) async {
          await answer.future;
          return http.StreamedResponse(Stream.value(utf8.encode('[]')), 200);
        }).movies();
        await stalled.dropped.future;
        await pumpEventQueue();
        expect(asked, 1, reason: 'not again while that one downloads');
        answer.complete();
        await waited;
        await backgroundRefreshes();
        expect(asked, 2);
        expect(await names(source()), ['Cinema']);
      });

      test('none is asked for while an update brings that same file, nor the list twice', () async {
        await names(source());
        makeOld();
        final list = utf8.encode(newer);
        final started = Completer<void>(), finish = Completer<void>();
        Stream<List<int>> slow() async* {
          yield list.sublist(0, 1);
          started.complete();
          await finish.future;
          yield list.sublist(1);
        }

        final updating = names(
          XtreamSource(
            server: 'https://example.com/',
            username: 'demo',
            password: 'pw',
            cacheDir: dir,
            refetch: true,
            client: MockClient.streaming((_, _) async => http.StreamedResponse(slow(), 200)),
          )..hideAdult = false,
        );
        await started.future;

        var asked = 0;
        final reopened = streaming((_, _) async {
          asked++;
          return http.StreamedResponse(Stream.value(list), 200);
        });
        expect(await names(reopened), ['News', 'Sports'], reason: 'the file is still the old one');
        finish.complete();
        expect(await updating, ['Cinema']);
        await backgroundRefreshes();
        expect(asked, 0, reason: 'the update brought it already');

        makeOld();
        await names(
          streaming((_, _) async {
            asked++;
            return http.StreamedResponse(Stream.value(list), 200);
          }),
        );
        await backgroundRefreshes();
        expect(asked, 1, reason: 'the update is over: refreshes are back');
      });

      test('one per file at a time, whoever asks, and one after another', () async {
        final item = jsonEncode([
          {'category_id': '1', 'category_name': 'A', 'stream_id': 1, 'name': 'B'},
        ]);
        answer = item;
        final first = source();
        await first.liveCategories();
        await names(first);
        for (final f in dir.listSync().whereType<File>()) {
          f.setLastModifiedSync(DateTime.now().subtract(XtreamSource.listsFresh * 2));
        }
        final order = <String>[];
        final firstAsked = Completer<void>(), release = Completer<void>();
        var running = 0, most = 0;
        Future<http.StreamedResponse> panel(http.BaseRequest req, http.ByteStream _) async {
          order.add(req.url.queryParameters['action']!);
          running++;
          if (running > most) most = running;
          if (!firstAsked.isCompleted) firstAsked.complete();
          await release.future;
          running--;
          return http.StreamedResponse(Stream.value(utf8.encode(item)), 200);
        }

        final a = streaming(panel), b = streaming(panel);
        await a.liveCategories();
        await a.liveChannels();
        await b.liveCategories();
        await b.liveChannels();
        await firstAsked.future;
        await pumpEventQueue();
        expect(order, ['get_live_categories'], reason: 'the second waits for the first');
        release.complete();
        await backgroundRefreshes();
        expect(order, ['get_live_categories', 'get_live_streams'], reason: 'each file once');
        expect(most, 1);
      });

      test('an update of the list goes first, and the refresh it makes needless is left', () async {
        await names(source());
        makeOld();
        final stalled = StalledBody(utf8.encode('[{"name": "Cin'));
        var asked = 0;
        final s = streaming((_, _) async {
          asked++;
          return http.StreamedResponse(stalled.stream, 200);
        });
        expect(await names(s), ['News', 'Sports']);
        await stalled.listening.future;
        answer = newer;
        expect(await names(source(refetch: true)), ['Cinema'], reason: 'as blocking as ever');
        expect(stalled.dropped.isCompleted, isTrue, reason: 'it took the line from the refresh');
        await backgroundRefreshes();
        expect(asked, 1, reason: 'the update brought it already');
        expect(parts(), isEmpty);
        expect(await names(source()), ['Cinema']);
      });
    });

    group('how far a download got', () {
      late List<DownloadProgress?> seen;
      void note() => seen.add(listDownloads.value);

      setUp(() {
        ListDownloads.every = Duration.zero;
        seen = [];
        listDownloads.addListener(note);
      });
      tearDown(() {
        listDownloads.removeListener(note);
        ListDownloads.every = const Duration(milliseconds: 300);
      });

      XtreamSource panel(Stream<List<int>> Function() body, {int? length, Map<String, String> headers = const {}}) =>
          XtreamSource(
            server: 'https://example.com/',
            username: 'demo',
            password: 'pw',
            cacheDir: dir,
            client: MockClient.streaming(
              (_, _) async => http.StreamedResponse(body(), 200, contentLength: length, headers: headers),
            ),
          )..hideAdult = false;

      test('says the bytes so far and the total the server gave, then that it is over', () async {
        final list = utf8.encode(jsonEncode(channels));
        await panel(
          () => Stream.fromIterable([list.sublist(0, 10), list.sublist(10)]),
          length: list.length,
        ).liveChannels();
        expect(seen, [
          (received: 0, total: null),
          (received: 0, total: list.length),
          (received: 10, total: list.length),
          (received: list.length, total: list.length),
          null,
        ]);
      });

      test('pieces make no change within the least time between two', () async {
        ListDownloads.every = const Duration(hours: 1);
        final list = utf8.encode(jsonEncode(channels));
        await panel(
          () => Stream.fromIterable([list.sublist(0, 10), list.sublist(10, 20), list.sublist(20)]),
          length: list.length,
        ).liveChannels();
        expect(seen, [(received: 0, total: null), (received: 0, total: list.length), null]);
      });

      test('has no total when the server gives none, or the size of a compressed body', () async {
        final list = utf8.encode(jsonEncode(channels));
        await panel(() => Stream.value(list)).liveChannels();
        expect(seen.first, (received: 0, total: null));
        expect(seen[1], (received: list.length, total: null));

        seen.clear();
        for (final f in dir.listSync()) {
          f.deleteSync();
        }
        await panel(() => Stream.value(list), length: 5, headers: {'content-encoding': 'gzip'}).liveChannels();
        expect(seen.first, (received: 0, total: null));
        expect(seen[1], (received: list.length, total: null), reason: 'unpacked it is bigger than 5');
      });

      test('several at once count together, and one done stays counted', () async {
        final a = utf8.encode(jsonEncode(channels)), b = utf8.encode('[]');
        // Each sends a first piece and waits, so both are under way whichever starts first
        final both = Completer<void>(), finishA = Completer<void>(), finishB = Completer<void>();
        void check() {
          if (listDownloads.value?.received == 10 + 1 && !both.isCompleted) both.complete();
        }

        listDownloads.addListener(check);
        addTearDown(() => listDownloads.removeListener(check));
        Stream<List<int>> body(List<int> list, int first, Completer<void> finish) async* {
          yield list.sublist(0, first);
          await finish.future;
          yield list.sublist(first);
        }

        final s = XtreamSource(
          server: 'https://example.com/',
          username: 'demo',
          password: 'pw',
          cacheDir: dir,
          client: MockClient.streaming((req, _) async {
            final streams = req.url.queryParameters['action'] == 'get_live_streams';
            return http.StreamedResponse(
              streams ? body(a, 10, finishA) : body(b, 1, finishB),
              200,
              contentLength: streams ? a.length : b.length,
            );
          }),
        )..hideAdult = false;
        final live = s.liveChannels(), categories = s.liveCategories();
        await both.future;
        expect(listDownloads.value, (received: 11, total: a.length + b.length));
        finishB.complete();
        await categories;
        expect(listDownloads.value, (
          received: 10 + b.length,
          total: a.length + b.length,
        ), reason: 'done, still counted');
        finishA.complete();
        await live;
        expect(listDownloads.value, isNull);
      });

      Future<void> until(bool Function(DownloadProgress p) met) async {
        final done = Completer<void>();
        void check() {
          final p = listDownloads.value;
          if (p != null && met(p) && !done.isCompleted) done.complete();
        }

        listDownloads.addListener(check);
        check();
        await done.future;
        listDownloads.removeListener(check);
      }

      test('the share waits for every list asked for: it never falls when a big one answers late', () async {
        final a = utf8.encode(jsonEncode(channels)), b = utf8.encode('[]');
        final answerB = Completer<void>(), finishA = Completer<void>();
        Stream<List<int>> bodyA() async* {
          yield a.sublist(0, 10);
          await finishA.future;
          yield a.sublist(10);
        }

        final s = XtreamSource(
          server: 'https://example.com/',
          username: 'demo',
          password: 'pw',
          cacheDir: dir,
          client: MockClient.streaming((req, _) async {
            if (req.url.queryParameters['action'] == 'get_live_streams') {
              return http.StreamedResponse(bodyA(), 200, contentLength: a.length);
            }
            await answerB.future;
            return http.StreamedResponse(Stream.value(b), 200, contentLength: b.length);
          }),
        )..hideAdult = false;
        final live = s.liveChannels(), categories = s.liveCategories();
        await until((p) => p.received == 10);
        expect(listDownloads.value, (received: 10, total: null), reason: 'one has not answered: no share yet');
        answerB.complete();
        await until((p) => p.total != null);
        expect(listDownloads.value?.total, a.length + b.length);
        finishA.complete();
        await Future.wait([live, categories]);
        final shares = [
          for (final p in seen.nonNulls)
            if (p.total case final total?) p.received / total,
        ];
        expect(shares, isNotEmpty);
        expect(shares, [...shares]..sort(), reason: 'never down');
      });

      test('a list done before another has answered does not end the count', () async {
        final a = utf8.encode(jsonEncode(channels)), b = utf8.encode('[]');
        final answerB = Completer<void>();
        final s = XtreamSource(
          server: 'https://example.com/',
          username: 'demo',
          password: 'pw',
          cacheDir: dir,
          client: MockClient.streaming((req, _) async {
            if (req.url.queryParameters['action'] == 'get_live_streams') {
              return http.StreamedResponse(Stream.value(a), 200, contentLength: a.length);
            }
            await answerB.future;
            return http.StreamedResponse(Stream.value(b), 200, contentLength: b.length);
          }),
        )..hideAdult = false;
        final live = s.liveChannels(), categories = s.liveCategories();
        await live;
        expect(listDownloads.value, (received: a.length, total: null));
        answerB.complete();
        await categories;
        expect(seen.where((p) => p == null), hasLength(1), reason: 'over once, at the end');
        expect(seen.last, isNull);
      });

      test('one that is refused, or never answers, does not hold back the share of the next', () async {
        for (final fail in [() => down = true, () => status = 500]) {
          answer = '[]';
          fail();
          await source(refetch: true).liveChannels().then((_) => null, onError: (Object _) => null);
          expect(listDownloads.value, isNull);
          down = false;
          status = 200;
          answer = null;
          seen.clear();
          final list = utf8.encode(jsonEncode(channels));
          await panel(() => Stream.value(list), length: list.length).liveChannels();
          expect(seen, contains((received: list.length, total: list.length)));
          for (final f in dir.listSync()) {
            f.deleteSync();
          }
        }
      });

      test('a body shorter than its size is an error, and not kept', () async {
        final list = utf8.encode(jsonEncode(channels));
        await expectLater(
          panel(() => Stream.value(list), length: list.length + 100).liveChannels(),
          throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.unreachable)),
        );
        expect(dir.listSync(), isEmpty);
      });

      test('a refresh in the background shows nothing', () async {
        await names(source());
        seen.clear();
        for (final f in dir.listSync().whereType<File>()) {
          f.setLastModifiedSync(DateTime.now().subtract(XtreamSource.listsFresh * 2));
        }
        await names(source());
        await backgroundRefreshes();
        expect(requests, 2);
        expect(seen, isEmpty);
      });
    });
  });

  test('a download has a file of its own; those left by downloads cut short go after an hour', () {
    final dir = Directory.systemTemp.createTempSync('parts');
    addTearDown(() => dir.deleteSync(recursive: true));
    final list = File('${dir.path}/catalog-x-get_vod_streams.json');
    final hourAgo = DateTime.now().subtract(const Duration(hours: 2));
    final cutShort = File('${list.path}.1-0.part')
      ..writeAsStringSync('the app closed meanwhile')
      ..setLastModifiedSync(hourAgo);
    final running = File('${list.path}.2-0.part')..writeAsStringSync('still coming');
    final otherList = File('${dir.path}/catalog-x-get_series.json.3-0.part')
      ..writeAsStringSync('another list')
      ..setLastModifiedSync(hourAgo);

    final a = partFile(list), b = partFile(list);
    expect(a.path, isNot(b.path));
    expect(a.path, startsWith('${list.path}.'));
    expect(cutShort.existsSync(), isFalse);
    expect(running.existsSync(), isTrue, reason: 'a download still writing it');
    expect(otherList.existsSync(), isTrue, reason: "another list's: its own downloads see to it");
  });

  test('a panel that answers an unknown login with 404 means wrong credentials, or address', () async {
    final source = XtreamSource(
      server: 'http://panel.test:55577',
      username: 'ana',
      password: 'wrong',
      client: MockClient((_) async => http.Response('', 404)),
    )..hideAdult = false;
    expect(source.login(), throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.wrongServer)));
  });

  test('an address that cannot be one, and a provider overloaded, are said as such', () async {
    for (final bad in ['host:80a', 'http://[bad', 'my server:8080', 'ftp://x.test']) {
      expect(
        () => XtreamSource.normalizeServer(bad),
        throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.badAddress)),
        reason: bad,
      );
    }
    for (final (status, error) in [
      (503, SourceError.providerBusy),
      (429, SourceError.providerBusy),
      (403, SourceError.unauthorized),
      (418, SourceError.httpStatus),
    ]) {
      final s = XtreamSource(
        server: 'http://panel.test',
        username: 'a',
        password: 'b',
        client: MockClient((_) async => http.Response('', status)),
      );
      await expectLater(s.login(), throwsA(isA<SourceException>().having((e) => e.error, 'error', error)));
    }
  });
}
