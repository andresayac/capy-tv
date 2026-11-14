import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/m3u.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/data/xtream.dart';

// "now" for every test: 2026-11-05 15:00 UTC
final _now = DateTime.utc(2026, 11, 5, 15);

const _xml = '''<?xml version="1.0" encoding="utf-8"?>
<tv generator-info-name="XUI.one">
  <channel id="News.TV"><display-name>News TV</display-name><icon src="http://x/n.png"/></channel>
  <programme start="20261105090000 -0500" stop="20261105100000 -0500" channel="News.TV">
    <title lang="es">Noticias &amp; Más</title><title lang="en">News &amp; More</title>
    <desc lang="es"><![CDATA[Resumen <del> día]]></desc>
  </programme>
  <programme start="20261105100000 -0500" stop="20261105113000 -0500" channel="news.tv">
    <title>Deportes</title>
  </programme>
  <programme start="20261105160000 +0000" stop="20261105170000 +0000" channel="Movies.TV">
    <title>Film</title>
  </programme>
  <programme start="20261020100000 +0000" stop="20261020110000 +0000" channel="News.TV">
    <title>Too old</title>
  </programme>
  <programme start="20261105120000 +0000" stop="20261105130000 +0000" channel="News.TV">
    <desc>No title: skipped</desc>
  </programme>
</tv>''';

Future<EpgGuide> _parse() => parseXmltv(Stream.value(_xml), now: _now);

void main() {
  test('parses times with their offsets into the right instant', () {
    expect(parseXmltvTime('20261105090000 -0500')!.toUtc(), DateTime.utc(2026, 11, 5, 14));
    expect(parseXmltvTime('20261105090000 +0130')!.toUtc(), DateTime.utc(2026, 11, 5, 7, 30));
    expect(parseXmltvTime('202611050900')!.toUtc(), DateTime.utc(2026, 11, 5, 9)); // no seconds, no offset = UTC
    expect(parseXmltvTime('garbage'), isNull);
  });

  test('programmes per channel: case-insensitive ids, first title, CDATA and entities', () async {
    final g = await _parse();
    final news = g.forChannel('NEWS.TV');
    expect(news.map((e) => e.title), ['Noticias & Más', 'Deportes']);
    expect(news.first.description, 'Resumen <del> día');
    expect(g.has('Movies.TV'), isTrue);
    expect(g.has('Unknown'), isFalse);
    expect(g.forChannel(null), isEmpty);
    expect(g.iconOf('news.tv'), 'http://x/n.png'); // logo fallback from <channel><icon>
    expect(g.iconOf('Movies.TV'), isNull);
  });

  test('a programme with no stop (XMLTV allows it) ends where the next starts, the last in an hour', () async {
    final g = await parseXmltv(
      Stream.value(
        '<tv><programme start="20261105140000 +0000" channel="a"><title>One</title></programme>'
        '<programme start="20261105143000 +0000" channel="a"><title>Two</title></programme></tv>',
      ),
      now: _now,
    );
    final a = g.forChannel('a');
    expect(a.map((e) => e.title), ['One', 'Two']);
    expect(a[0].end.toUtc(), DateTime.utc(2026, 11, 5, 14, 30));
    expect(a[1].end.toUtc(), DateTime.utc(2026, 11, 5, 15, 30));
  });

  test('a programme repeated or overlapping in a channel is kept once, ending where the next starts', () async {
    String p(String start, String stop, String title) =>
        '<programme start="20261105${start}00 +0000" stop="20261105${stop}00 +0000" channel="a"><title>$title</title></programme>';
    final g = await parseXmltv(
      Stream.value(
        '<tv>${p('1400', '1500', 'One')}${p('1400', '1500', 'One')}${p('1400', '1430', 'Other')}'
        '${p('1430', '1530', 'Two')}${p('1530', '1600', 'Three')}</tv>',
      ),
      now: _now,
    );
    final a = g.forChannel('a');
    expect(a.map((e) => e.title), ['One', 'Two', 'Three']);
    expect(a[0].end.toUtc(), DateTime.utc(2026, 11, 5, 14, 30));
    expect(a[1].end.toUtc(), DateTime.utc(2026, 11, 5, 15, 30));
  });

  test("a programme in several languages is read in the app's, else in the first", () async {
    Future<EpgEntry> read(String? language) async =>
        (await parseXmltv(Stream.value(_xml), now: _now, language: language)).forChannel('News.TV').first;
    expect((await read('en')).title, 'News & More');
    expect((await read('es')).title, 'Noticias & Más');
    expect((await read('es')).description, 'Resumen <del> día');
    expect((await read('fr')).title, 'Noticias & Más', reason: 'none in French: the first');
  });

  test('drops programmes outside the window and those without a title', () async {
    final g = await _parse();
    expect(g.forChannel('News.TV').any((e) => e.title == 'Too old'), isFalse);
    expect(g.forChannel('News.TV'), hasLength(2));
  });

  test('a bare "<", a cut-off file or an element never closed loses only what is broken', () async {
    String programme(String title, int hour) =>
        '<programme start="202611051${hour}0000 +0000" stop="202611051${hour + 1}0000 +0000" channel="a">'
        '<title>$title</title></programme>';
    Future<List<String>> titles(String xml, {int pieces = 1}) async {
      final size = (xml.length / pieces).ceil();
      final chunks = [for (var i = 0; i < xml.length; i += size) xml.substring(i, (i + size).clamp(0, xml.length))];
      final g = await parseXmltv(Stream.fromIterable(chunks), now: _now);
      return [for (final e in g.forChannel('a')) e.title];
    }

    expect(await titles('<tv>${programme('A < B', 2)}${programme('Te amo <3', 3)}</tv>'), ['A < B', 'Te amo <3']);
    expect(await titles('<tv>${programme('First', 2)}<programme channel="a" start="2026'), [
      'First',
    ], reason: 'cut off');
    expect(await titles('<tv>${programme('First', 2)}<programme start="x">${programme('Third', 4)}</tv>', pieces: 7), [
      'First',
      'Third',
    ], reason: 'one broken element skipped, not the rest');
    expect(
      await titles('<html><script>if (a < b) {}</script></html>'),
      isEmpty,
      reason: 'a web page: no guide, no error',
    );
    expect(await titles('<tv>${programme('Fish &amp; chips &#8212; &#x1F600;', 2)}</tv>'), ['Fish & chips — 😀']);
  });

  test('now, upcoming and between', () async {
    final g = await _parse();
    expect(g.nowOn('News.TV', _now)!.title, 'Deportes'); // 15:00-16:30 UTC
    expect(g.nowOn('Movies.TV', _now), isNull);
    expect(g.upcoming('News.TV', at: _now).map((e) => e.title), ['Deportes']);
    expect(g.between('Movies.TV', _now, _now.add(const Duration(hours: 2))), hasLength(1));
  });

  test('reads gzipped guides from the cache', () async {
    final dir = await Directory.systemTemp.createTemp('epg');
    final cache = File('${dir.path}/guide.xml')..writeAsBytesSync(gzip.encode(_xml.codeUnits));
    final g = await loadXmltv(Uri.parse('http://127.0.0.1:9/never-used'), cache: cache, now: _now);
    expect(g.channelCount, 2);
    await dir.delete(recursive: true);
  });

  group('downloaded', () {
    late Directory dir;
    late File cache;
    var answer = '';
    var status = 200;
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response(answer, status);
    });
    setUp(() {
      dir = Directory.systemTemp.createTempSync('epg');
      cache = File('${dir.path}/epg-guide.xml');
      answer = _xml;
      status = 200;
      requests = 0;
    });
    tearDown(() async {
      await backgroundRefreshes();
      dir.deleteSync(recursive: true);
    });
    Future<EpgGuide> load({Duration maxAge = const Duration(hours: 6)}) =>
        loadXmltv(Uri.parse('http://epg.example/guide.xml'), cache: cache, client: client, maxAge: maxAge, now: _now);
    void makeOld(Duration age) => cache.setLastModifiedSync(DateTime.now().subtract(age));

    test('a guide is kept, and read from there while young', () async {
      expect((await load()).channelCount, 2);
      expect((await load()).channelCount, 2);
      expect(requests, 1);
    });

    for (final (what, body, code) in [
      ('a web page', '<html>Busy</html>', 200),
      ('empty', '', 200),
      ('a guide with no programmes', '<tv></tv>', 200),
      ('an error', 'Oops', 500),
    ]) {
      test('a copy stays when the new one is $what, and the next load asks again', () async {
        await load();
        makeOld(const Duration(days: 2));
        final when = cache.lastModifiedSync();
        answer = body;
        status = code;
        expect((await load()).channelCount, 2);
        expect(cache.lastModifiedSync(), when, reason: 'not taken for a fresh one');
      });
    }

    test('one from the last day shows at once, and a new one comes in the background', () async {
      await load();
      makeOld(const Duration(hours: 8));
      final before = cache.lastModifiedSync();
      answer = _xml.replaceAll('Deportes', 'Noticias');
      expect((await load()).nowOn('News.TV', _now)!.title, 'Deportes', reason: 'the copy there was');
      await backgroundRefreshes();
      expect(cache.lastModifiedSync().isAfter(before), isTrue);
      expect((await load()).nowOn('News.TV', _now)!.title, 'Noticias');
    });

    test('updating it waits for the new one', () async {
      await load();
      answer = _xml.replaceAll('Deportes', 'Noticias');
      expect((await load(maxAge: Duration.zero)).nowOn('News.TV', _now)!.title, 'Noticias');
    });

    test('one cut short is shown with no other, but never kept, nor in place of a whole one', () async {
      final cut = _xml.substring(0, _xml.indexOf('<programme start="20261105160000'));
      answer = cut;
      final first = await load();
      expect(first.complete, isFalse);
      expect(first.nowOn('News.TV', _now)!.title, 'Deportes', reason: 'what came is shown');
      expect(cache.existsSync(), isFalse, reason: 'the next load downloads it again');

      answer = _xml;
      expect((await load()).complete, isTrue);
      makeOld(const Duration(days: 2));
      final when = cache.lastModifiedSync();
      answer = cut.replaceAll('Deportes', 'Noticias');
      expect((await load()).nowOn('News.TV', _now)!.title, 'Deportes', reason: 'the whole copy stays');
      expect(cache.lastModifiedSync(), when);
    });
  });

  group("only the playlist's channels", () {
    const guide = '''<tv>
  <channel id="CanalUno"><display-name>Canal Uno</display-name><icon src="http://x/1.png"/></channel>
  <channel id="Other"><display-name>Canal Una</display-name></channel>
  <channel id="News.TV"><display-name>Noticias</display-name></channel>
  <programme start="20261105140000 +0000" stop="20261105160000 +0000" channel="CanalUno"><title>Uno</title></programme>
  <programme start="20261105140000 +0000" stop="20261105160000 +0000" channel="Other"><title>Una</title></programme>
  <programme start="20261105140000 +0000" stop="20261105160000 +0000" channel="News.TV"><title>News</title></programme>
  <programme start="20261104090000 +0000" stop="20261104100000 +0000" channel="News.TV"><title>Yesterday</title></programme>
</tv>''';

    Future<EpgGuide> read(GuideChannels channels, {Duration? shortPast}) =>
        parseXmltv(Stream.value(guide), now: _now, channels: channels, shortPast: shortPast);

    test("a channel with no id the guide has is matched by the guide's name for it, alike only in "
        'case, accents and quality', () async {
      final g = await read(
        GuideChannels(
          ids: ['Canal Uno HD', 'news.tv'],
          names: {
            'Canal Uno HD': ['Canal Uno HD'],
            'News': ['news.tv'],
          },
        ),
      );
      expect(g.nowOn('Canal Uno HD', _now)!.title, 'Uno');
      expect(g.iconOf('Canal Uno HD'), 'http://x/1.png');
      expect(g.nowOn('news.tv', _now)!.title, 'News', reason: 'by its id, never by a name');
      expect(g.channelCount, 2, reason: '"Canal Una" is another channel, and Other is not in the playlist');
    });

    test('channels the playlist does not have are not kept', () async {
      final g = await read(GuideChannels(ids: ['News.TV']));
      expect(g.channelCount, 1);
      expect(g.has('CanalUno'), isFalse);
    });

    test("a channel's tvg-shift moves its times", () async {
      final g = await read(GuideChannels(ids: ['News.TV'], shifts: {'news.tv': const Duration(hours: -2)}));
      expect(g.forChannel('News.TV').last.start.toUtc(), DateTime.utc(2026, 11, 5, 12));
      expect(g.nowOn('News.TV', _now), isNull, reason: 'it ended two hours earlier');
    });

    test('with little memory the past is kept only for the channels with catch-up', () async {
      final short = await read(GuideChannels(ids: ['News.TV']), shortPast: const Duration(hours: 2));
      expect([for (final e in short.forChannel('News.TV')) e.title], ['News']);
      final archive = await read(
        GuideChannels(ids: ['News.TV'], archive: ['News.TV']),
        shortPast: const Duration(hours: 2),
      );
      expect([for (final e in archive.forChannel('News.TV')) e.title], ['Yesterday', 'News']);
    });
  });

  test("the playlist's own time setting moves the whole guide, a channel's tvg-shift on top", () async {
    final g = await parseXmltv(
      Stream.value(_xml),
      now: _now,
      shift: const Duration(hours: 1),
      channels: GuideChannels(ids: ['News.TV'], shifts: {'News.TV': const Duration(minutes: 30)}),
    );
    expect(g.forChannel('News.TV').first.start.toUtc(), DateTime.utc(2026, 11, 5, 15, 30));
    final all = await parseXmltv(Stream.value(_xml), now: _now, shift: const Duration(hours: -2));
    expect(all.forChannel('Movies.TV').single.start.toUtc(), DateTime.utc(2026, 11, 5, 14));
    expect(
      Playlist.fromJson(
        Playlist.create(type: PlaylistType.m3u, url: 'http://x/l.m3u').copyWith(guideShift: -120).toJson(),
      ).guideShift,
      -120,
    );
    expect(Playlist.create(type: PlaylistType.m3u, url: 'http://x/l.m3u').toJson(), isNot(contains('guideShift')));
  });

  test("M3U's tvg-shift, the header's for every channel without one, in hours with a fraction", () {
    expect(parseTvgShift('-5'), const Duration(hours: -5));
    expect(parseTvgShift('+1.5'), const Duration(minutes: 90));
    expect(parseTvgShift('5,5'), const Duration(minutes: 330));
    expect(parseTvgShift('0'), isNull);
    expect(parseTvgShift('soon'), isNull);
    final reader = M3uReader();
    const LineSplitter()
        .convert('''#EXTM3U tvg-shift="-3"
#EXTINF:-1 tvg-id="a.tv",A
http://h/a.ts
#EXTINF:-1 tvg-id="b.tv" tvg-shift="2",B
http://h/b.ts''')
        .forEach(reader.add);
    expect([for (final e in reader.entries) e.attrs['tvg-shift']], ['-3', '2']);
  });

  test('a channel with no guide id goes by its name, to be matched by it', () async {
    final reader = M3uReader();
    const LineSplitter()
        .convert('#EXTM3U\n#EXTINF:-1,Canal Uno HD\nhttp://h/1.ts\n#EXTINF:-1 tvg-id="x.tv",X\nhttp://h/2.ts')
        .forEach(reader.add);
    final channels = await (M3uSource(reader.entries)..hideAdult = false).liveChannels();
    expect([for (final c in channels) c.epgId], ['Canal Uno HD', 'x.tv']);
    expect(LiveChannel.fromJson({'stream_id': 1, 'name': 'Canal Dos', 'epg_channel_id': ''}).epgId, 'Canal Dos');
    expect(LiveChannel.fromJson({'stream_id': 1, 'name': 'Canal Dos', 'epg_channel_id': 'dos.tv'}).epgId, 'dos.tv');
  });

  test("the short guide's times with no timestamp are on the panel's clock", () {
    final j = {'title': 'News', 'start': '2026-11-05 20:30:00', 'end': '2026-11-05 21:00:00'};
    final e = EpgEntry.fromXtream(j, serverOffset: const Duration(hours: -5))!;
    expect(e.start.toUtc(), DateTime.utc(2026, 11, 6, 1, 30), reason: '20:30 in UTC-5');
    // A timestamp says the instant itself
    final stamped = EpgEntry.fromXtream({
      ...j,
      'start_timestamp': '1793889000',
      'stop_timestamp': '1793890800',
    }, serverOffset: const Duration(hours: -5))!;
    expect(stamped.start.toUtc(), DateTime.fromMillisecondsSinceEpoch(1793889000 * 1000, isUtc: true));
  });

  test('a guide in Latin-1 says so, and its accents read right', () async {
    final dir = await Directory.systemTemp.createTemp('epg');
    // However the declaration is spaced
    for (final (i, declared) in ['encoding="ISO-8859-1"', "encoding = 'iso-8859-1'"].indexed) {
      final xml = _xml
          .replaceFirst(RegExp('encoding="utf-8"', caseSensitive: false), declared)
          .replaceAll('Deportes', 'Fútbol España');
      expect(xml, contains(declared));
      final cache = File('${dir.path}/guide$i.xml')..writeAsBytesSync(latin1.encode(xml));
      final g = await loadXmltv(Uri.parse('http://127.0.0.1:9/never-used'), cache: cache, now: _now);
      expect(g.nowOn('News.TV', _now)!.title, 'Fútbol España', reason: declared);
    }
    await dir.delete(recursive: true);
  });

  test('a guide that could not be downloaded, with no copy kept, is empty and says it failed', () async {
    final dir = await Directory.systemTemp.createTemp('epg');
    final g = await loadXmltv(Uri.parse('http://127.0.0.1:9/unreachable'), cache: File('${dir.path}/none.xml'));
    expect(g.isEmpty, isTrue);
    expect(
      identical(g, EpgGuide.failed),
      isTrue,
      reason: 'the guide offers Retry rather than "no guide" on every channel',
    );
    expect(identical(EpgGuide.merge([g, EpgGuide.failed]), EpgGuide.failed), isTrue);
    await dir.delete(recursive: true);
  });

  test('M3U header declares the guide', () {
    expect(
      m3uGuideUrl('#EXTM3U x-tvg-url="http://epg/a.xml.gz,http://epg/b.xml"\n#EXTINF:-1,A\nhttp://a'),
      'http://epg/a.xml.gz',
    );
    expect(m3uGuideUrl('#EXTM3U url-tvg="http://epg/c.xml"\n'), 'http://epg/c.xml');
    expect(m3uGuideUrl('#EXTM3U\n#EXTINF:-1,A\nhttp://a'), isNull);
  });

  test('server UTC offset from the login response drives catch-up URLs', () {
    final info = AccountInfo.fromJson({
      'user_info': {'status': 'Active'},
      // 22:13:28 in Lima when it was 03:13:28 UTC the next day: UTC-5
      'server_info': {'time_now': '2026-11-04 22:13:28', 'timestamp_now': 1793848408},
    });
    expect(info.serverUtcOffset, const Duration(hours: -5));

    final s = XtreamSource(server: 'http://host', username: 'u', password: 'p')..serverUtcOffset = info.serverUtcOffset;
    const c = LiveChannel(id: '7', name: 'News', archiveDays: 3);
    // A programme at 14:00 UTC is 09:00 on the server's clock
    expect(
      s.catchupUrl(c, DateTime.utc(2026, 11, 5, 14), const Duration(minutes: 90)),
      'http://host/timeshift/u/p/90/2026-11-05:09-00/7.ts',
    );
  });
}
