// What is cast and how: the plan for each kind of stream, from its address alone.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/chromecast/cast_plan.dart';
import 'package:iptv_player/chromecast/chromecast_service.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/m3u.dart';
import 'package:iptv_player/player/play.dart';

const _channel = MediaRef(kind: MediaKind.live, id: '7', title: 'News');
const _movie = MediaRef(kind: MediaKind.movie, id: '9', title: 'Film');
const _x = 'http://panel.example:8080';

PlayItem _live(String url, {Map<String, String> headers = const {}}) =>
    PlayItem(url: url, title: 'News', ref: _channel, headers: headers);

PlayItem _vod(String url, {Map<String, String> headers = const {}, List<String> alternates = const []}) => PlayItem(
  url: url,
  title: 'Film',
  ref: _movie,
  headers: headers,
  alternates: [for (final a in alternates) PlayItem(url: a, title: 'Film', headers: headers)],
);

CastCandidate _hls(String url, {Map<String, String> headers = const {}, bool live = true}) =>
    CastCandidate(url: url, contentType: 'application/x-mpegurl', route: CastRoute.hls, headers: headers, live: live);

CastCandidate _file(String url, String type, CastRoute route, {Map<String, String> headers = const {}}) =>
    CastCandidate(url: url, contentType: type, route: route, headers: headers);

void main() {
  group('live channels go through the relay as HLS', () {
    final ua = {'User-Agent': 'VLC/3.0'};
    for (final (what, item, formats, want) in [
      ('Xtream .ts, asked for as .m3u8', _live('$_x/live/u/p/7.ts'), null, [_hls('$_x/live/u/p/7.m3u8')]),
      ('Xtream .m3u8 as it is', _live('$_x/live/u/p/7.m3u8'), null, [_hls('$_x/live/u/p/7.m3u8')]),
      ('Xtream without extension', _live('$_x/live/u/p/7'), null, [_hls('$_x/live/u/p/7.m3u8')]),
      (
        'a panel under a path of its own',
        _live('https://proxy.example/iptv/live/u/p/7.ts'),
        null,
        [_hls('https://proxy.example/iptv/live/u/p/7.m3u8')],
      ),
      ('an account that allows m3u8', _live('$_x/live/u/p/7.ts'), {'ts', 'M3U8'}, [_hls('$_x/live/u/p/7.m3u8')]),
      ('formats unknown (empty)', _live('$_x/live/u/p/7.ts'), <String>{}, [_hls('$_x/live/u/p/7.m3u8')]),
      ('already m3u8, whatever the formats say', _live('$_x/live/u/p/7.m3u8'), {'ts'}, [_hls('$_x/live/u/p/7.m3u8')]),
      (
        'credentials kept as written',
        _live('$_x/live/me%40x.com/p%2Fw/7.ts'),
        null,
        [_hls('$_x/live/me%40x.com/p%2Fw/7.m3u8')],
      ),
      (
        'an Xtream path without the channel ref',
        PlayItem(url: '$_x/live/u/p/7.ts', title: 'News'),
        null,
        [_hls('$_x/live/u/p/7.m3u8')],
      ),
      (
        'another M3U .m3u8, with its headers',
        _live('https://cdn.example/a/index.m3u8?t=1', headers: ua),
        null,
        [_hls('https://cdn.example/a/index.m3u8?t=1', headers: ua)],
      ),
    ]) {
      test(what, () {
        final plan = castPlan(item, accountFormats: formats);
        expect(plan.candidates, want);
        expect(plan.refusal, isNull);
        expect(plan.castable, isTrue);
      });
    }

    test("the short /user/password/id is the panel's channel only in a panel's export", () {
      expect(castPlan(_live('$_x/u/p/7'), panelExport: true).candidates, [_hls('$_x/live/u/p/7.m3u8')]);
      expect(castPlan(_live('$_x/u/p/7.ts'), panelExport: true).candidates, [_hls('$_x/live/u/p/7.m3u8')]);
      // Some server's /news/hd/7: no /live/ made up for it
      expect(castPlan(_live('http://cdn.example/news/hd/7')).candidates, [_hls('http://cdn.example/news/hd/7')]);
      expect(castPlan(_live('http://cdn.example/news/hd/7.ts')).refusal, CastRefusal.liveFormat);
    });

    test("a list is a panel's export when most of its short addresses share one account", () {
      M3uSource list(List<String> urls) => M3uSource([for (final u in urls) M3uEntry(name: u, url: u)]);
      final export = list(['$_x/u/p/1.ts', '$_x/u/p/2.ts', '$_x/u/p/3.ts', 'http://other.example/x.m3u8']);
      expect(export.isPanelExport, isTrue);
      expect(ChromecastService.panelExportHas(export, '$_x/u/p/2.ts'), isTrue);
      expect(ChromecastService.panelExportHas(export, '$_x/u/p/9.ts'), isFalse, reason: 'not in the list');
      final cdn = list(['http://cdn.example/news/hd/7.ts', 'http://cdn.example/sport/sd/8.ts']);
      expect(cdn.isPanelExport, isFalse);
    });

    test('DASH goes straight as DASH, never through the relay; sound files as sound', () {
      final mpd = castPlan(_vod('https://cdn.example/f/manifest.mpd'));
      expect(mpd.candidates.single.contentType, 'application/dash+xml');
      expect(mpd.candidates.single.route, CastRoute.direct);
      expect(
        castPlan(_vod('https://cdn.example/f/manifest.mpd', headers: {'User-Agent': 'VLC'})).refusal,
        CastRefusal.file,
      );
      expect(castPlan(_vod('https://cdn.example/a/song.mp3')).candidates.first.contentType, 'audio/mpeg');
    });

    test('an account that does not allow m3u8 is refused', () {
      final plan = castPlan(_live('$_x/live/u/p/7.ts'), accountFormats: {'ts', 'rtmp'});
      expect(plan.castable, isFalse);
      expect(plan.refusal, CastRefusal.noHls);
    });

    for (final url in [
      'http://cdn.example/stream?id=7',
      'http://cdn.example/s.php?f=a',
      'http://cdn.example/ch/index.m3u',
    ]) {
      test('a live address that does not say what it is is tried as HLS: $url', () {
        final plan = castPlan(_live(url));
        expect(plan.castable, isTrue);
        expect(plan.candidates.single.route, CastRoute.hls);
      });
    }

    for (final url in ['http://cdn.example/ch/7.ts', 'rtmp://cdn.example/ch/7']) {
      test('other live formats are refused: $url', () {
        final plan = castPlan(_live(url));
        expect(plan.castable, isFalse);
        expect(plan.refusal, CastRefusal.liveFormat);
      });
    }
  });

  group('videos', () {
    for (final (ext, type) in [
      ('mp4', 'video/mp4'),
      ('m4v', 'video/mp4'),
      ('webm', 'video/webm'),
      ('MP4', 'video/mp4'),
    ]) {
      test('$ext goes direct, then through the relay', () {
        final url = '$_x/movie/u/p/9.$ext';
        final plan = castPlan(_vod(url));
        expect(plan.candidates, [_file(url, type, CastRoute.direct), _file(url, type, CastRoute.progressive)]);
        expect(plan.mkv, isFalse);
      });
    }

    test('episodes too', () {
      const url = '$_x/series/u/p/31.mp4';
      final item = PlayItem(
        url: url,
        title: 'Show',
        ref: const MediaRef(kind: MediaKind.episode, id: '31', title: 'Pilot'),
      );
      expect(castPlan(item).candidates.map((c) => c.route), [CastRoute.direct, CastRoute.progressive]);
    });

    test('one that needs headers only through the relay, which sends them', () {
      const url = 'http://cdn.example/f.mp4';
      final ua = {'User-Agent': 'Kodi'};
      expect(castPlan(_vod(url, headers: ua)).candidates, [
        _file(url, 'video/mp4', CastRoute.progressive, headers: ua),
      ]);
    });

    test('mkv after an mp4 alternate, and said', () {
      const mkv = '$_x/movie/u/p/9.mkv', mp4 = '$_x/movie/u/p/10.mp4';
      final plan = castPlan(_vod(mkv, alternates: [mp4]));
      expect(plan.candidates, [
        _file(mp4, 'video/mp4', CastRoute.direct),
        _file(mp4, 'video/mp4', CastRoute.progressive),
        _file(mkv, 'video/x-matroska', CastRoute.direct),
        _file(mkv, 'video/x-matroska', CastRoute.progressive),
      ]);
      expect(plan.mkv, isTrue);
    });

    test('alternates of the same rank keep their order, repeats dropped', () {
      const a = '$_x/movie/u/p/1.mp4', b = '$_x/movie/u/p/2.webm';
      final plan = castPlan(_vod(a, alternates: [b, a]));
      expect(plan.candidates.map((c) => c.url), [a, a, b, b]);
    });

    test('a video in HLS goes through the relay, not live', () {
      const url = 'http://cdn.example/vod/master.m3u8';
      expect(castPlan(_vod(url)).candidates, [_hls(url, live: false)]);
    });

    test('an unknown container is tried last, as MP4', () {
      const odd = 'http://cdn.example/get?id=9', mkv = 'http://cdn.example/9.mkv';
      final plan = castPlan(_vod(odd, alternates: [mkv]));
      expect(plan.candidates.map((c) => (c.url, c.contentType)), [
        (mkv, 'video/x-matroska'),
        (mkv, 'video/x-matroska'),
        (odd, 'video/mp4'),
        (odd, 'video/mp4'),
      ]);
    });

    for (final ext in ['avi', 'flv', 'wmv', 'mpg', 'ts']) {
      test('$ext is refused, with its format', () {
        final plan = castPlan(_vod('$_x/movie/u/p/9.$ext'));
        expect(plan.castable, isFalse);
        expect(plan.refusal, CastRefusal.file);
        expect(plan.format, ext);
      });
    }

    test('a refused file with a castable alternate casts the alternate', () {
      const mp4 = '$_x/movie/u/p/10.mp4';
      final plan = castPlan(_vod('$_x/movie/u/p/9.avi', alternates: [mp4]));
      expect(plan.refusal, isNull);
      expect(plan.candidates.map((c) => c.url).toSet(), {mp4});
    });
  });

  group('recordings and catch-up stay here', () {
    for (final (what, item) in [
      ('catch-up', PlayItem(url: '$_x/timeshift/u/p/60/2026-11-07:20-00/7.ts', title: 'News')),
      ('catch-up via timeshift.php', PlayItem(url: '$_x/streaming/timeshift.php?stream=7', title: 'News')),
      ('a recording on Windows', PlayItem(url: r'C:\Users\me\Videos\News 2026-11-07.ts', title: 'News')),
      ('a recording on Android', PlayItem(url: '/data/user/0/app/files/recordings/News.ts', title: 'News')),
      ('a file URL', PlayItem(url: 'file:///tmp/News.mp4', title: 'News')),
    ]) {
      test(what, () {
        final plan = castPlan(item);
        expect(plan.castable, isFalse);
        expect(plan.refusal, CastRefusal.local);
      });
    }
  });
}
