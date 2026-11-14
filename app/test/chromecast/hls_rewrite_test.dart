// Rewriting HLS playlists so every address in them points at the relay.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/chromecast/hls_rewrite.dart';

/// Rewrites [text] from [base], naming each address by its kind and where it resolved to.
String _rewrite(String text, String base, [List<(String, HlsKind)>? seen, List<String>? tags]) =>
    rewriteHls(text, Uri.parse(base), (url, kind, tag) {
      seen?.add(('$url', kind));
      tags?.add(tag);
      return '${kind.name}:$url';
    });

void main() {
  // Where the provider's redirect landed: relative addresses resolve against this, not the address
  // that was asked for
  const base = 'https://edge7.cdn.example/hls/abc/master.m3u8?token=1';

  test('a master playlist: variants, renditions and I-frame lists are playlists', () {
    const master =
        '#EXTM3U\n'
        '#EXT-X-VERSION:6\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English, main",LANGUAGE="en",URI="audio/en.m3u8"\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Muxed",DEFAULT=YES\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="aud"\n'
        'low/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3000000,CODECS="avc1.640028,mp4a.40.2"\n'
        '/abs/high.m3u8?b=3\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=6000000\n'
        'http://other.example/uhd.m3u8\n'
        '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="iframes.m3u8"\n'
        '#EXT-X-SESSION-KEY:METHOD=AES-128,URI="../keys/k1"\n';
    final seen = <(String, HlsKind)>[];
    final out = _rewrite(master, base, seen);
    expect(seen, [
      ('https://edge7.cdn.example/hls/abc/audio/en.m3u8', HlsKind.playlist),
      ('https://edge7.cdn.example/hls/abc/low/index.m3u8', HlsKind.playlist),
      ('https://edge7.cdn.example/abs/high.m3u8?b=3', HlsKind.playlist),
      ('http://other.example/uhd.m3u8', HlsKind.playlist),
      ('https://edge7.cdn.example/hls/abc/iframes.m3u8', HlsKind.playlist),
      ('https://edge7.cdn.example/hls/keys/k1', HlsKind.media),
    ]);
    expect(
      out,
      contains(
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English, main",LANGUAGE="en",'
        'URI="playlist:https://edge7.cdn.example/hls/abc/audio/en.m3u8"\n',
      ),
    );
    expect(out, contains('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Muxed",DEFAULT=YES\n'));
    expect(out, contains('#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="aud"\n'));
    expect(out, contains('#EXT-X-STREAM-INF:BANDWIDTH=3000000,CODECS="avc1.640028,mp4a.40.2"\n'));
    expect(out, contains('#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="playlist:'));
    expect(out, startsWith('#EXTM3U\n#EXT-X-VERSION:6\n'));
  });

  test('a media playlist: segments, keys and init sections are media; the rest as it was', () {
    const media =
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-MEDIA-SEQUENCE:120\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key.php?id=5",IV=0x0123456789ABCDEF0123456789ABCDEF\n'
        '#EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"\n'
        '#EXTINF:4.0,Title, with a comma URI="x"\n'
        'seg_120.ts\n'
        '#EXT-X-BYTERANGE:1000@720\n'
        '#EXTINF:4.0,\n'
        'https://cdn2.example/seg_121.ts?sig=a%2Fb\n'
        '# a comment\n'
        '#EXT-X-DISCONTINUITY\n'
        '#EXTINF:4.0,\n'
        '?seg=122\n'
        '#EXT-X-ENDLIST\n';
    final seen = <(String, HlsKind)>[];
    final out = _rewrite(media, base, seen);
    expect(seen, [
      ('https://edge7.cdn.example/hls/abc/key.php?id=5', HlsKind.media),
      ('https://edge7.cdn.example/hls/abc/init.mp4', HlsKind.media),
      ('https://edge7.cdn.example/hls/abc/seg_120.ts', HlsKind.media),
      ('https://cdn2.example/seg_121.ts?sig=a%2Fb', HlsKind.media),
      ('https://edge7.cdn.example/hls/abc/master.m3u8?seg=122', HlsKind.media),
    ]);
    expect(
      out,
      '#EXTM3U\n'
      '#EXT-X-TARGETDURATION:4\n'
      '#EXT-X-MEDIA-SEQUENCE:120\n'
      '#EXT-X-KEY:METHOD=AES-128,URI="media:https://edge7.cdn.example/hls/abc/key.php?id=5",'
      'IV=0x0123456789ABCDEF0123456789ABCDEF\n'
      '#EXT-X-MAP:URI="media:https://edge7.cdn.example/hls/abc/init.mp4",BYTERANGE="720@0"\n'
      '#EXTINF:4.0,Title, with a comma URI="x"\n'
      'media:https://edge7.cdn.example/hls/abc/seg_120.ts\n'
      '#EXT-X-BYTERANGE:1000@720\n'
      '#EXTINF:4.0,\n'
      'media:https://cdn2.example/seg_121.ts?sig=a%2Fb\n'
      '# a comment\n'
      '#EXT-X-DISCONTINUITY\n'
      '#EXTINF:4.0,\n'
      'media:https://edge7.cdn.example/hls/abc/master.m3u8?seg=122\n'
      '#EXT-X-ENDLIST\n',
    );
  });

  test('a URI="…" inside another quoted attribute, and addresses that are not http, stay', () {
    const text =
        '#EXTM3U\n'
        '#EXT-X-MEDIA:TYPE=SUBTITLES,NAME="a,URI=no.m3u8",GROUP-ID="s",URI="subs.m3u8"\n'
        '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key-id",KEYFORMAT="com.apple.streamingkeydelivery"\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="data:text/plain;base64,AAECAwQFBgcICQoLDA0ODw=="\n'
        '#EXT-X-KEY:METHOD=NONE\n'
        '#EXT-X-CONTENT-STEERING:SERVER-URI="https://steer.example/s.json"\n'
        '#EXTINF:2,\n'
        'a.ts\n';
    final seen = <(String, HlsKind)>[];
    final out = _rewrite(text, 'http://h.example/x/', seen);
    expect(seen.map((s) => s.$1), ['http://h.example/x/subs.m3u8', 'http://h.example/x/a.ts']);
    expect(out, contains('#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key-id",'));
    expect(out, contains('URI="data:text/plain;base64,AAECAwQFBgcICQoLDA0ODw=="'));
    expect(out, contains('#EXT-X-KEY:METHOD=NONE\n'));
    expect(out, isNot(contains('STEERING')), reason: 'it would send the player to the provider');
  });

  test('CRLF, a BOM, blank lines and stray spaces', () {
    const text = '﻿#EXTM3U\r\n\r\n#EXT-X-TARGETDURATION:6\r\n#EXTINF:6,\r\n  s1.ts  \r\n\r\n#EXTINF:6,\r\ns2.ts';
    expect(
      _rewrite(text, 'http://h.example/live/index.m3u8'),
      '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nmedia:http://h.example/live/s1.ts\n'
      '#EXTINF:6,\nmedia:http://h.example/live/s2.ts\n',
    );
    expect(isHls('﻿\r\n#EXTM3U\r\n'), isTrue);
  });

  test('what is no playlist is said', () {
    expect(isHls('<html>blocked</html>'), isFalse);
    expect(() => _rewrite('<html>blocked</html>', base), throwsFormatException);
    expect(() => _rewrite('', base), throwsFormatException);
  });

  test('a playlist is told the tag that named it, without the address', () {
    final tags = <String>[];
    _rewrite(
      '#EXTM3U\n'
      '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="en.m3u8",NAME="en"\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=800000\n'
      'low.m3u8?t=1\n'
      '#EXT-X-MAP:URI="init.mp4"\n'
      '#EXTINF:4,\n'
      'a.ts\n',
      base,
      null,
      tags,
    );
    expect(tags, [
      '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en"',
      '#EXT-X-STREAM-INF:BANDWIDTH=800000',
      '#EXT-X-MAP:',
      '',
    ]);
  });

  group('ids', () {
    const at = 'http://h.example/live/index.m3u8';

    /// The ids [links] gives the addresses of [text], rewritten as playlist [owner].
    List<String> rewrite(HlsLinks links, String owner, String text, [String base = at]) => [
      for (final line in links.rewrite(owner, text, Uri.parse(base), (id, kind, _) => '${kind.name} $id').split('\n'))
        if (line.isNotEmpty && !line.startsWith('#')) line.split(' ').last,
    ];
    List<String> keys(HlsLinks links, String owner, String text) => [
      for (final line in links.rewrite(owner, text, Uri.parse(at), (id, _, _) => id).split('\n'))
        for (final m in RegExp(r'URI="([^"]+)"').allMatches(line)) m[1]!,
    ];
    String window(int from, int count) =>
        '#EXTM3U\n${[for (var i = from; i < from + count; i++) '#EXTINF:4,\ns$i.ts\n'].join()}';

    test('the same address gets the same id across refreshes; a new one a new id', () {
      final links = HlsLinks();
      final first = rewrite(links, '', '#EXTM3U\n#EXTINF:4,\ns1.ts\n#EXTINF:4,\ns2.ts\n');
      final again = rewrite(links, '', '#EXTM3U\n#EXTINF:4,\ns2.ts\n#EXTINF:4,\ns3.ts\n');
      expect(first[1], again[0], reason: 's2 both times');
      expect({...first, ...again}, hasLength(3));
      expect(links[again[0]]?.url, Uri.parse('http://h.example/live/s2.ts'));
      expect(links[again[0]]?.kind, HlsKind.media);
      expect(links['nope'], isNull);
    });

    test('a playlist and media at one address are told apart', () {
      final links = HlsLinks();
      const text = '#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI="a"\n#EXT-X-STREAM-INF:BANDWIDTH=1\na\n';
      final [key] = keys(links, '', text);
      final [variant] = rewrite(links, '', text);
      expect(variant, isNot(key));
      expect(links[variant]?.kind, HlsKind.playlist);
      expect(links[key]?.kind, HlsKind.media);
      expect(links[variant]?.url, links[key]?.url);
    });

    test('a long film keeps every id it names, however many', () {
      final links = HlsLinks(margin: 3);
      final video = rewrite(links, 'v', '${window(0, 2400)}#EXT-X-ENDLIST\n');
      expect(video.toSet(), hasLength(2400));
      expect([video.first, video.last].map((id) => links[id]?.url.pathSegments.last), ['s0.ts', 's2399.ts']);
      // Its audio, as long, beside it
      final audio = rewrite(links, 'a', '${window(5000, 1200)}#EXT-X-ENDLIST\n');
      expect([video.first, audio.first].map((id) => links[id]), everyElement(isNotNull));
    });

    test('a variant named once lives on while its refreshes name segment after segment', () {
      final links = HlsLinks(margin: 10);
      final [variant] = rewrite(links, '', '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlow.m3u8\n');
      var latest = <String>[], before = <String>[];
      for (var refresh = 0; refresh < 1000; refresh++) {
        before = latest;
        latest = rewrite(links, variant, window(refresh * 6, 6), 'http://h.example/live/low.m3u8');
      }
      expect(links[variant]?.url, Uri.parse('http://h.example/live/low.m3u8'));
      expect([...latest, ...before].map((id) => links[id]), everyElement(isNotNull), reason: 'a player behind may ask');
      expect(links.length, 1 + 6 + 10, reason: 'the rest forgotten');
    });

    test('what slid out goes, oldest first, past the margin; what two playlists name stays while one does', () {
      final links = HlsLinks(margin: 1);
      const key = '#EXT-X-KEY:METHOD=AES-128,URI="k.bin"\n';
      final [s1, s2] = rewrite(links, 'v', '#EXTM3U\n$key#EXTINF:4,\ns1.ts\n#EXTINF:4,\ns2.ts\n');
      final [k] = keys(links, 'v', '#EXTM3U\n$key#EXTINF:4,\ns1.ts\n#EXTINF:4,\ns2.ts\n');
      expect(keys(links, 'a', '#EXTM3U\n$key#EXTINF:4,\na1.ts\n'), [k], reason: 'one key, one id');
      rewrite(links, 'v', '#EXTM3U\n#EXTINF:4,\ns3.ts\n'); // k.bin, s1 and s2 drop out of v
      expect(links[k], isNotNull, reason: 'a still names the key');
      expect(links[s1], isNull, reason: 's1: the oldest past the margin');
      expect(links[s2], isNotNull);
      expect(rewrite(links, 'v', '#EXTM3U\n#EXTINF:4,\ns1.ts\n'), [isNot(s1)], reason: 'back: a new id');
      rewrite(links, 'a', '#EXTM3U\n#EXTINF:4,\na2.ts\n');
      rewrite(links, 'v', '#EXTM3U\n#EXTINF:4,\ns4.ts\n');
      expect(links[k], isNull, reason: 'no playlist names it any more');
    });

    test('a fresh master: the playlist that stands where one stood, by its tag, else by its place', () {
      final links = HlsLinks();
      String master(String token, [int low = 800000]) =>
          '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en",URI="/tok/$token/en.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=$low,AUDIO="a"\n'
          '/tok/$token/low.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3000000,AUDIO="a"\n'
          '/tok/$token/high.m3u8\n';
      final [audio] = keys(links, '', master('A'));
      final [low, high] = rewrite(links, '', master('A'));
      expect([links.standIn('', audio), links.standIn('', low)], [audio, low], reason: 'nothing new yet');

      final [audio2] = keys(links, '', master('B'));
      final [low2, high2] = rewrite(links, '', master('B'));
      expect({audio, low, high}.intersection({audio2, low2, high2}), isEmpty);
      expect(
        [
          for (final id in [audio, low, high]) links.standIn('', id),
        ],
        [audio2, low2, high2],
      );

      // Its bandwidth measured anew: still the first of the variants
      final [low3, high3] = rewrite(links, '', master('C', 812345));
      expect([links.standIn('', low), links.standIn('', high)], [low3, high3]);
      expect(links[low3]?.url.path, '/tok/C/low.m3u8');

      expect(links.standIn('', 'nope'), isNull);
      expect(links.standIn('other', low), isNull);
      rewrite(links, '', '#EXTM3U\n#EXTINF:4,\nseg.ts\n');
      expect(links.standIn('', low), isNull, reason: 'it names no variant any more');
    });
  });

  group('the format a receiver is told', () {
    test('Transport Stream unless the playlist says otherwise', () {
      expect(hlsFormatOf('#EXTM3U\n#EXTINF:6,\nseg1.ts\n'), HlsFormat.ts);
      expect(hlsFormatOf('#EXTM3U\n#EXTINF:6,\nhttp://cdn.test/chunk?n=1\n'), HlsFormat.ts, reason: 'no extension');
      expect(hlsFormatOf('#EXTM3U\n#EXT-X-ENDLIST\n'), HlsFormat.ts, reason: 'no segment');
    });

    test('fMP4 with an init section or .m4s segments, packed audio by its extension', () {
      expect(hlsFormatOf('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:6,\nseg1.m4s\n'), HlsFormat.fmp4);
      expect(hlsFormatOf('#EXTM3U\n#EXTINF:6,\nseg1.m4s?token=x\n'), HlsFormat.fmp4);
      expect(hlsFormatOf('#EXTM3U\n#EXTINF:6,\nseg1.cmfv\n'), HlsFormat.fmp4);
      expect(hlsFormatOf('#EXTM3U\n#EXTINF:6,\nsegment1.aac\n'), const HlsFormat('aac'));
      expect(hlsFormatOf('#EXTM3U\n#EXTINF:6,\nsegment1.ec3\n'), const HlsFormat('e_ac3'));
    });

    test('a master: its first variant, and its audio when it comes apart', () {
      final base = Uri.parse('http://p.test/hls/master.m3u8');
      const master =
          '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",URI="en/index.m3u8"\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="es",DEFAULT=YES,URI="es/index.m3u8"\n'
          '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="es",URI="subs.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aud",SUBTITLES="sub"\n'
          'low/index.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3000000,AUDIO="aud"\n'
          'high/index.m3u8\n';
      final got = hlsFirstVariant(master, base);
      expect(got.variant, Uri.parse('http://p.test/hls/low/index.m3u8'));
      expect(got.audio, Uri.parse('http://p.test/hls/es/index.m3u8'), reason: 'the default of its group');
      final muxed = hlsFirstVariant('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n', base);
      expect(muxed.variant, Uri.parse('http://p.test/hls/v.m3u8'));
      expect(muxed.audio, isNull);
      expect(hlsFirstVariant('#EXTM3U\n#EXTINF:6,\nseg.ts\n', base).variant, isNull, reason: 'a media playlist');
    });
  });
}
