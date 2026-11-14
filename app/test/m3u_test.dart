import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/m3u.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/source.dart';

import 'support/stalled_body.dart';

const _list =
    '﻿#EXTM3U x-tvg-url="http://epg.example/guide.xml"\r\n'
    '#EXTINF:-1 tvg-id="uno.es" tvg-name="Uno" tvg-logo="http://logo/uno.png" group-title="General" catchup-days="7",Channel One, HD\r\n'
    '#EXTVLCOPT:http-user-agent=MyPlayer/1.0\r\n'
    'http://srv/live/u/p/1.ts\r\n'
    '\r\n'
    '#EXTINF:-1 group-title="Sports",Sports 1\n'
    'http://srv/live/u/p/2.ts\n'
    '#EXTINF:-1,No group\n'
    '#EXTGRP:Other\n'
    'http://srv/live/u/p/3.m3u8\n'
    '#EXTINF:-1 tvg-logo="http://img/p.jpg" group-title="Cinema",Film (2024)\n'
    'http://srv/movie/u/p/9.mkv\n';

void main() {
  test('reads attributes, names with commas and VLC options', () {
    final e = parseM3u(_list);
    expect(e, hasLength(4));
    expect(e.first.name, 'Channel One, HD');
    expect(e.first.attrs['tvg-id'], 'uno.es');
    expect(e.first.logo, 'http://logo/uno.png');
    expect(e.first.group, 'General');
    expect(e.first.userAgent, 'MyPlayer/1.0');
    expect(e[1].userAgent, isNull);
    expect(e[2].group, 'Other');
    expect(e[3].isMovie, isTrue);
  });

  test('M3uSource splits live channels and movies by group', () async {
    final s = M3uSource(parseM3u(_list));
    expect((await s.liveCategories()).map((c) => c.name), ['General', 'Sports', 'Other']);
    final live = await s.liveChannels('General');
    expect(live.single.archiveDays, 7);
    expect(s.liveUrl(live.single), 'http://srv/live/u/p/1.ts');
    expect((await s.movies()).single.name, 'Film (2024)');
    expect(await s.series(), isEmpty);
  });

  test('a series or a video file outside a panel is on demand, a stream elsewhere live', () async {
    M3uEntry entry(String url) => M3uEntry(name: url, url: url);
    // A panel's on-demand path, not any address with /movie/ or /series/ in it
    expect(entry('http://srv/series/u/p/77.mkv').isMovie, isTrue);
    expect(entry('http://srv/movie/u/p/78').isMovie, isTrue);
    expect(
      entry('http://cdn.example/series/channel/index.m3u8').isMovie,
      isFalse,
      reason: 'a stream, with the channels',
    );
    expect(entry('http://cdn.example/movie/hbo/index.m3u8').isMovie, isFalse);
    expect(entry('http://cdn.example/vod/film.MP4').isMovie, isTrue);
    expect(entry('http://cdn.example/vod/film.mkv?token=abc').isMovie, isTrue);
    expect(entry('http://cdn.example/news/index.m3u8').isMovie, isFalse);
    expect(entry('http://srv/live/u/p/1.ts').isMovie, isFalse);
    expect(entry('http://cdn.example/play.php?file=/movie/x').isMovie, isFalse, reason: 'the path, not the query');
    final s = M3uSource([entry('http://cdn.example/series/a/s01e01.mp4'), entry('http://cdn.example/news/index.m3u8')]);
    expect((await s.movies()).single.url, 'http://cdn.example/series/a/s01e01.mp4');
    expect((await s.liveChannels()).single.url, 'http://cdn.example/news/index.m3u8');
  });

  test('a channel behind DRM is left out, and only that one', () {
    final reader = M3uReader();
    for (final line in [
      '#EXTM3U',
      '#EXTINF:-1,Locked',
      '#KODIPROP:inputstreamaddon=inputstream.adaptive',
      '#KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha',
      '#KODIPROP:inputstream.adaptive.license_key=https://lic.example/wv',
      'https://cdn.example/locked.mpd',
      '#EXTINF:-1,Dash',
      '#KODIPROP:inputstream.adaptive.manifest_type=mpd',
      'https://cdn.example/open.mpd',
      '#EXTINF:-1,Plain',
      'https://cdn.example/plain.m3u8',
    ]) {
      reader.add(line);
    }
    expect(reader.entries.map((e) => e.name), ['Dash', 'Plain']);
    expect(reader.locked, 1);
  });

  test("a channel's stream given as the list is that channel, not a download that never ends", () async {
    for (final (type, body) in [
      ('video/mp2t', [for (var i = 0; i < 400; i++) i % 188 == 0 ? 0x47 : 0]),
      ('application/octet-stream', [for (var i = 0; i < 400; i++) i % 188 == 0 ? 0x47 : 0]),
      ('video/mp4', utf8.encode('....ftypisom')),
    ]) {
      final client = MockClient((_) async => http.Response.bytes(body, 200, headers: {'content-type': type}));
      final s = await M3uSource.load('http://tv.example/live/stream', client: client);
      expect(s.entries.single.url, 'http://tv.example/live/stream', reason: type);
    }
    final list = MockClient(
      (_) async => http.Response.bytes(utf8.encode(_list), 200, headers: {'content-type': 'audio/x-mpegurl'}),
    );
    expect((await M3uSource.load('http://lists.example/list.m3u', client: list)).entries.length, 4);
  });

  test('from the library it plays at the address the list has now', () {
    final s = M3uSource(
      parseM3u(
        '#EXTM3U\n#EXTINF:-1,One\nhttp://srv/u/new-pass/1.ts\n#EXTINF:-1,Film\nhttp://srv/movie/u/new-pass/9.mkv\n'
        '#EXTINF:-1,Other\nhttp://cdn.example/hls/a/1.m3u8\n',
      ),
    );
    expect(
      s.liveUrl(const LiveChannel(id: '1', name: 'One', url: 'http://srv/u/old-pass/1.ts')),
      'http://srv/u/new-pass/1.ts',
    );
    expect(
      s.movieUrl(const Movie(id: '9', name: 'Film', url: 'http://srv/movie/u/old-pass/9.mkv')),
      'http://srv/movie/u/new-pass/9.mkv',
    );
    expect(
      s.liveUrl(const LiveChannel(id: '1', name: 'Other', url: 'http://cdn.example/hls/a/1.m3u8')),
      'http://cdn.example/hls/a/1.m3u8',
      reason: 'an address still in the list plays itself, though its id is another entry\'s too',
    );
    expect(s.liveUrl(const LiveChannel(id: 'gone', name: 'Gone', url: 'http://srv/x.m3u8')), 'http://srv/x.m3u8');
  });

  test('ids stay when the provider reorders the list or the password changes', () async {
    final s = M3uSource(parseM3u(_list));
    final ids = {for (final c in await s.liveChannels()) c.name: c.id};
    expect(ids, {'Channel One, HD': '1', 'Sports 1': '2', 'No group': '3'}, reason: 'panel URLs carry the stream id');
    expect((await s.movies()).single.id, '9');
    expect(m3uId('http://srv/live/u/new-password/1.ts'), '1');
    expect(m3uId('http://srv/u/p/1'), '1', reason: 'live URLs without /live/');
    final other = m3uId('https://cdn.example/news/index.m3u8');
    expect(other, m3uId('https://cdn.example/news/index.m3u8'));
    expect(other, isNot(m3uId('https://cdn.example/sports/index.m3u8')));
  });

  test('a stream asks for the user agent its entry declares', () async {
    final s = M3uSource(parseM3u(_list));
    expect(s.headersFor('http://srv/live/u/p/1.ts'), {'User-Agent': 'MyPlayer/1.0'});
    expect(s.headersFor('http://srv/live/u/p/2.ts'), isEmpty);
  });

  test('a web page, an "account expired" or an HLS manifest is no playlist', () {
    expect(parseM3u('<html>\n<head><title>Login</title></head>\n<body>Sign in</body>\n</html>'), isEmpty);
    expect(parseM3u('Account expired, contact your reseller'), isEmpty);
    expect(parseM3u('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg-1.ts\n#EXTINF:6.0,\nseg-2.ts'), isEmpty);
    expect(parseM3u('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlow/index.m3u8'), isEmpty);
    const relative = '#EXTM3U\nhttp://srv/a.ts\n#EXTINF:-1,B\nb.ts';
    expect(parseM3u(relative, list: 'http://srv/lists/all.m3u').map((e) => (e.name, e.url)), [
      ('http://srv/a.ts', 'http://srv/a.ts'),
      ('B', 'http://srv/lists/b.ts'),
    ], reason: 'relative to the list');
    expect(parseM3u(relative).map((e) => e.name), ['http://srv/a.ts'], reason: 'with no list to go by, a path');
  });

  test('two addresses that would share an id each have their own; a token that changes keeps it', () async {
    final s = M3uSource(
      parseM3u(
        '#EXTM3U\n#EXTINF:-1,One\nhttp://a.example/hls/news/1\n#EXTINF:-1,Two\nhttp://b.example/hls/sport/1\n'
        '#EXTINF:-1,Three\nhttp://c.example/play.php?ch=3&token=abc&expires=99',
      ),
    );
    final live = await s.liveChannels();
    expect(live.map((c) => c.id).toSet(), hasLength(3));
    expect(live.first.id, '1', reason: 'the first keeps the id it had');
    expect(s.liveUrl(live[1]), 'http://b.example/hls/sport/1');
    expect(m3uId('http://c.example/play.php?ch=3&token=xyz&expires=100'), live[2].id);
    expect(m3uId('http://c.example/play.php?ch=4&token=abc&expires=99'), isNot(live[2].id));
  });

  test('what the library kept plays only if it is a stream, and a gone one says so', () async {
    final s = M3uSource(parseM3u('#EXTM3U\n#EXTINF:-1,One\nhttp://a.example/1.ts'));
    const gone = LiveChannel(id: 'gone', name: 'Gone');
    expect(() => s.liveUrl(gone), throwsA(isA<SourceException>()));
    expect(
      s.liveUrl(const LiveChannel(id: 'x', name: 'Kept', url: 'http://old.example/2.ts')),
      'http://old.example/2.ts',
    );
    expect(
      () => s.liveUrl(const LiveChannel(id: 'y', name: 'File', url: '/sdcard/x.ts')),
      throwsA(isA<SourceException>()),
    );
  });

  test("a channel's number is the list's own, tvg-chno, when it says one", () async {
    final s = M3uSource(const [
      M3uEntry(name: 'One', url: 'http://srv/1.ts', attrs: {'tvg-chno': '101'}),
      M3uEntry(name: 'Two', url: 'http://srv/2.ts'),
      M3uEntry(name: 'Bad', url: 'http://srv/3.ts', attrs: {'tvg-chno': 'x'}),
    ]);
    expect((await s.liveChannels()).map((c) => c.number), [101, 2, 3]);
  });

  test('categories come from what was worked out once, again when what is hidden changes', () async {
    final s = M3uSource(const [
      M3uEntry(name: 'News', url: 'http://srv/1.ts', attrs: {'group-title': 'News'}),
      M3uEntry(name: 'Late', url: 'http://srv/2.ts', attrs: {'group-title': 'XXX'}),
      M3uEntry(name: 'Sport', url: 'http://srv/3.ts', attrs: {'group-title': 'News'}),
    ]);
    expect((await s.liveCategories()).map((c) => c.id), ['News']);
    // Numbered among all the list's channels: the same whatever the profile hides
    expect((await s.liveChannels('News')).map((c) => (c.name, c.number)), [('News', 1), ('Sport', 3)]);
    (await s.liveChannels('News')).clear(); // a caller's own copy
    expect(await s.liveChannels('News'), hasLength(2));
    s.hideAdult = false;
    expect((await s.liveCategories()).map((c) => c.id), ['News', 'XXX']);
    expect((await s.liveChannels()).map((c) => c.number), [1, 2, 3]);
    s.kidsOnly = true;
    expect(await s.liveChannels(), isEmpty);
  });

  test("an entry pointing at the device's files is no channel", () {
    final e = parseM3u(
      '#EXTM3U\n#EXTINF:-1,A\nfile:///etc/passwd\n#EXTINF:-1,B\nedl://x\n#EXTINF:-1,C\nRTSP://cam/1\n#EXTINF:-1,D\nhttps://srv/d.m3u8',
    );
    expect(e.map((e) => e.name), ['C', 'D']);
    expect(isStreamAddress('C:\\video.ts'), isFalse);
    expect(isStreamAddress('live/1.ts'), isTrue, reason: 'relative to the list');
  });

  test('attributes in either quotes or none, #EXTGRP first, lowercase #extinf, empty values', () {
    final e = parseM3u(
      [
        '#EXTM3U',
        "#EXTINF:-1 tvg-logo='http://l/a,b.png' group-title='News, Sports',Canal Uno",
        'http://s/1.ts',
        '#EXTGRP:Kids',
        '#extinf:-1 group-title=Toons tvg-name="L\'Equipe",Dos',
        'http://s/2.ts',
        '#EXTINF:-1 tvg-name="Tres" group-title="" tvg-logo="",',
        '#EXTGRP:Noticias',
        'http://s/3.ts',
      ].join('\n'),
    );
    expect(e.map((x) => x.name), ['Canal Uno', 'Dos', 'Tres']);
    expect(e[0].attrs['tvg-logo'], 'http://l/a,b.png');
    expect(e.map((x) => x.group), ['News, Sports', 'Toons', 'Noticias']);
    expect(e[1].attrs['tvg-name'], "L'Equipe");
    expect(e[2].logo, isNull, reason: "an empty logo is none: the guide's may be used");
  });

  test('what a stream asks to be sent with: VLC options, #EXTHTTP and the bar after the address', () {
    final e = parseM3u(
      [
        '#EXTM3U',
        '#EXTINF:-1,A',
        '#EXTVLCOPT:http-user-agent="VLC/3"',
        '#EXTVLCOPT:http-referrer=http://ref.test/',
        'http://s/a.m3u8',
        '#EXTINF:-1,B',
        '#EXTHTTP:{"cookie":"k=v"}',
        'http://s/b.m3u8|User-Agent=Kodi&Referer=http%3A%2F%2Fy.test%2F',
      ].join('\n'),
    );
    expect(e[0].headers, {'User-Agent': 'VLC/3', 'Referer': 'http://ref.test/'});
    expect(e[1].url, 'http://s/b.m3u8', reason: 'the address alone');
    expect(e[1].headers, {'Cookie': 'k=v', 'User-Agent': 'Kodi', 'Referer': 'http://y.test/'});
    expect(M3uSource(e).headersFor('http://s/b.m3u8')['Referer'], 'http://y.test/');
  });

  test('guides declared as tvg-url, several of them, after a blank line', () {
    expect(m3uGuideUrls('\n#EXTM3U tvg-url="http://e/a.xml"\n'), ['http://e/a.xml']);
    expect(m3uGuideUrls('#EXTM3U url-tvg="http://e/a.xml http://e/b.xml"'), ['http://e/a.xml', 'http://e/b.xml']);
    expect(m3uGuideUrls('#EXTM3U X-TVG-URL="a,b,c,d"'), ['a', 'b', 'c'], reason: 'three at most');
  });

  test('stable hashes are the same on every run', () {
    expect(stableHash(''), 'cbf29ce484222325', reason: 'the FNV-1a offset basis');
    expect(stableHash('a'), 'af63dc4c8601ec8c');
  });

  test('a list sent packed (.gz) without saying so is unpacked where there is no disk too', () async {
    final packed = MockClient((_) async => http.Response.bytes(gzip.encode(utf8.encode(_list)), 200));
    expect((await M3uSource.load('http://lists.example/list.m3u.gz', client: packed)).entries.length, 4);
  });

  group('downloaded', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const url = 'http://lists.example/list.m3u';
    late Directory dir;
    var requests = 0;
    var down = false;
    var answer = _list; // what the server has
    var status = 200;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('m3u-cache');
      requests = 0;
      down = false;
      answer = _list;
      status = 200;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationCacheDirectory' ? dir.path : null,
      );
    });
    tearDown(() async {
      await backgroundRefreshes();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      dir.deleteSync(recursive: true);
    });

    final client = MockClient((_) async {
      requests++;
      if (down) throw const SocketException('down');
      return http.Response.bytes(utf8.encode(answer), status);
    });
    List<String> files() => [for (final f in dir.listSync()) f.uri.pathSegments.last];

    test('goes to disk as it arrives, is read back line by line, and is kept', () async {
      final s = await M3uSource.load(url, client: client);
      expect(s.entries.map((e) => e.name), ['Channel One, HD', 'Sports 1', 'No group', 'Film (2024)']);
      expect(s.guideUrls, ['http://epg.example/guide.xml'], reason: 'from the header, past the BOM');
      expect(files(), ['m3u-${stableHash(url)}.m3u'], reason: 'kept, nothing half-written beside it');

      expect((await M3uSource.load(url, client: client)).entries.length, 4);
      expect(requests, 1, reason: 'fresh on disk: no request');

      File('${dir.path}/${files().single}').setLastModifiedSync(DateTime.now().subtract(M3uSource.fresh * 2));
      down = true;
      expect((await M3uSource.load(url, client: client)).entries.length, 4, reason: 'unreachable: the last copy');
    });

    test('a list sent packed (.gz) without saying so is unpacked, kept packed and read back so', () async {
      Future<M3uSource> load(String url, List<int> bytes) =>
          M3uSource.load(url, client: MockClient((_) async => http.Response.bytes(gzip.encode(bytes), 200)));
      expect((await load(url, utf8.encode(_list))).entries.map((e) => e.name), contains('Channel One, HD'));
      expect((await M3uSource.load(url, client: client)).entries.length, 4, reason: 'the copy on disk, still packed');
      expect(requests, 0);
      final latin = await load(
        'http://other.example/list.m3u.gz',
        latin1.encode('#EXTM3U\n#EXTINF:-1,España\nhttp://srv/1.ts\n'),
      );
      expect(latin.entries.single.name, 'España', reason: 'Latin-1 is told from what is inside, not from the packing');
    });

    test("one channel's HLS address given as the list is that channel", () async {
      const hls = 'http://live.example/ch/index.m3u8';
      answer = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n720p/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\n1080p/index.m3u8';
      final s = await M3uSource.load(hls, client: client);
      expect(s.entries.map((e) => (e.name, e.url)), [('live.example', hls)]);
    });

    test('a check reads the playlist for real and keeps nothing', () async {
      final s = await M3uSource.load(url, client: client, cached: false);
      expect(s.entries.length, 4);
      expect(files(), isEmpty);
    });

    test('a web page sent with a 200 is neither checked as one nor taken instead of the copy there is', () async {
      await M3uSource.load(url, client: client);
      final copy = File('${dir.path}/${files().single}').readAsStringSync();
      answer = '<html>\n<body>Account expired, contact your reseller</body>\n</html>';
      await expectLater(
        M3uSource.load(url, client: client, cached: false),
        throwsA(isA<SourceException>().having((e) => e.error, 'error', SourceError.emptyPlaylist)),
      );
      await expectLater(M3uSource.load(url, client: client, refetch: true), throwsA(isA<SourceException>()));
      expect(File('${dir.path}/${files().single}').readAsStringSync(), copy);
    });

    test('an error from the server is said, and nothing is left behind', () async {
      final refused = MockClient((_) async => http.Response('Not here', 404));
      await expectLater(
        M3uSource.load(url, client: refused),
        throwsA(isA<SourceException>().having((e) => e.detail, 'detail', '404')),
      );
      expect(files(), isEmpty);
    });

    group('an old copy', () {
      // One entry, as long as the four there were: much less would not be taken
      final newer =
          '#EXTM3U\n#EXTINF:-1 tvg-logo="http://logo/${'x' * 400}.png" group-title="News",Extra\nhttp://srv/live/u/p/7.ts\n';
      File saved() => File('${dir.path}/m3u-${stableHash(url)}.m3u');
      void makeOld() => saved().setLastModifiedSync(DateTime.now().subtract(M3uSource.fresh * 2));
      List<String> parts() => [
        for (final f in files())
          if (f.endsWith('.part')) f,
      ];

      test('shows at once, and a new one comes in the background for the next load', () async {
        await M3uSource.load(url, client: client);
        makeOld();
        answer = newer;
        final s = await M3uSource.load(url, client: client);
        expect(s.entries.length, 4, reason: 'the old copy, without waiting for the server');
        await backgroundRefreshes();
        expect(requests, 2);
        expect(files(), ['m3u-${stableHash(url)}.m3u'], reason: 'nothing half-written beside it');
        expect(s.entries.length, 4, reason: 'this session keeps the copy it read');
        expect((await M3uSource.load(url, client: client)).entries.single.name, 'Extra');
        expect(requests, 2, reason: 'fresh on disk now: no request');
      });

      for (final (what, body, code) in [
        ('refused', '', 401),
        ('not there', 'Not here', 404),
        ('an empty answer', '', 200),
        ('an error page', '<html>\n<body>${'Busy ' * 200}</body>\n</html>', 200),
        ('a message', 'Error: this account has expired, see http://x ${'please ' * 100}', 200),
      ]) {
        test('keeps its place when the new one is $what', () async {
          await M3uSource.load(url, client: client);
          makeOld();
          final before = saved().readAsStringSync(), modified = saved().lastModifiedSync();
          answer = body;
          status = code;
          expect((await M3uSource.load(url, client: client)).entries.length, 4);
          await backgroundRefreshes();
          expect(requests, 2);
          expect(saved().readAsStringSync(), before);
          expect(saved().lastModifiedSync(), modified, reason: 'still old: the next load tries again');
          expect(files(), hasLength(1));
        });
      }

      test('keeps its place when the new one is cut short', () async {
        await M3uSource.load(url, client: client);
        makeOld();
        final before = saved().readAsStringSync();
        final bytes = utf8.encode(newer);
        final short = MockClient.streaming(
          (_, _) async => http.StreamedResponse(Stream.value(bytes), 200, contentLength: bytes.length + 100),
        );
        expect((await M3uSource.load(url, client: short)).entries.length, 4);
        await backgroundRefreshes();
        expect(saved().readAsStringSync(), before);
        expect(files(), hasLength(1));
      });

      test('keeps its place when the new one is much smaller, with no size to tell it came whole', () async {
        await M3uSource.load(url, client: client);
        makeOld();
        final before = saved().readAsStringSync(), modified = saved().lastModifiedSync();
        final one = utf8.encode('#EXTM3U\n#EXTINF:-1,One\nhttp://srv/live/u/p/1.ts\n');
        final cut = MockClient.streaming((_, _) async => http.StreamedResponse(Stream.value(one), 200));
        expect((await M3uSource.load(url, client: cut)).entries.length, 4);
        await backgroundRefreshes();
        expect(saved().readAsStringSync(), before);
        expect(saved().lastModifiedSync(), modified);
        expect(files(), hasLength(1));
      });

      test('a list of bare addresses is a playlist like any other', () async {
        answer = 'http://x/live/1.ts\nhttp://x/live/2.ts\n';
        expect((await M3uSource.load(url, client: client)).entries.length, 2);
        makeOld();
        answer = 'http://x/live/1.ts\nhttp://x/live/2.ts\nhttp://x/live/3.ts\n';
        expect((await M3uSource.load(url, client: client)).entries.length, 2);
        await backgroundRefreshes();
        expect(requests, 2);
        expect((await M3uSource.load(url, client: client)).entries.length, 3);
      });

      test('keeps its place when the server is down', () async {
        await M3uSource.load(url, client: client);
        makeOld();
        final before = saved().readAsStringSync();
        down = true;
        expect((await M3uSource.load(url, client: client)).entries.length, 4);
        await backgroundRefreshes();
        expect(saved().readAsStringSync(), before);
        expect(files(), hasLength(1));
      });

      test('is not refreshed while something plays', () async {
        await M3uSource.load(url, client: client);
        makeOld();
        streamPlaying.value = true;
        addTearDown(() => streamPlaying.value = false);
        answer = newer;
        await M3uSource.load(url, client: client);
        await pumpEventQueue();
        expect(requests, 1, reason: 'the line is the stream\'s');
        streamPlaying.value = false;
        await backgroundRefreshes();
        expect(requests, 2);
      });

      test('is not refreshed while a recording records, though nothing plays', () async {
        await M3uSource.load(url, client: client);
        makeOld();
        recordingsRunning.value = 1;
        addTearDown(() => recordingsRunning.value = 0);
        answer = newer;
        await M3uSource.load(url, client: client);
        await pumpEventQueue();
        expect(requests, 1, reason: 'the line is the recording\'s');
        recordingsRunning.value = 0;
        await backgroundRefreshes();
        expect(requests, 2);
      });

      test('stops when something starts playing, its part gone, and starts over after', () async {
        await M3uSource.load(url, client: client);
        makeOld();
        final stalled = StalledBody(utf8.encode('#EXTINF:-1,Ex'));
        var asked = 0;
        List<String>? partsWhenAskedAgain;
        final slow = MockClient.streaming((_, _) async {
          if (++asked == 1) return http.StreamedResponse(stalled.stream, 200);
          partsWhenAskedAgain = parts();
          return http.StreamedResponse(Stream.value(utf8.encode(newer)), 200);
        });
        expect((await M3uSource.load(url, client: slow)).entries.length, 4);
        await stalled.listening.future;
        expect(parts(), hasLength(1), reason: 'it writes to a part of its own, not to the copy');
        streamPlaying.value = true;
        addTearDown(() => streamPlaying.value = false);
        await stalled.dropped.future;
        await pumpEventQueue();
        expect(asked, 1, reason: 'not again while it plays');
        streamPlaying.value = false;
        await backgroundRefreshes();
        expect(asked, 2);
        expect(partsWhenAskedAgain, isEmpty, reason: 'the part of the first try was dropped');
        expect(parts(), isEmpty);
        expect((await M3uSource.load(url, client: slow)).entries.single.name, 'Extra');
      });

      test('shows nothing of how far it has got', () async {
        await M3uSource.load(url, client: client);
        makeOld();
        final seen = <DownloadProgress?>[];
        void note() => seen.add(listDownloads.value);
        listDownloads.addListener(note);
        addTearDown(() => listDownloads.removeListener(note));
        answer = newer;
        await M3uSource.load(url, client: client);
        await backgroundRefreshes();
        expect(requests, 2);
        expect(seen, isEmpty);
      });

      test('an update of the list goes first, and the refresh it makes needless is left', () async {
        await M3uSource.load(url, client: client);
        makeOld();
        final stalled = StalledBody(utf8.encode('#EXTINF:-1,Ex'));
        var asked = 0;
        final slow = MockClient.streaming((_, _) async {
          asked++;
          return http.StreamedResponse(stalled.stream, 200);
        });
        expect((await M3uSource.load(url, client: slow)).entries.length, 4);
        await stalled.listening.future;
        answer = newer;
        expect((await M3uSource.load(url, client: client, refetch: true)).entries.single.name, 'Extra');
        expect(stalled.dropped.isCompleted, isTrue, reason: 'it took the line from the refresh');
        await backgroundRefreshes();
        expect(asked, 1, reason: 'the update brought it already');
        expect(parts(), isEmpty);
      });

      test('updating the list still waits for the server, and takes no old copy instead', () async {
        await M3uSource.load(url, client: client);
        makeOld();
        answer = newer;
        expect((await M3uSource.load(url, client: client, refetch: true)).entries.single.name, 'Extra');
        expect(requests, 2);
        down = true;
        await expectLater(M3uSource.load(url, client: client, refetch: true), throwsA(isA<SourceException>()));
      });
    });
  });
}
