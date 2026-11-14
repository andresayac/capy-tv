// The Chromecast wire format: CastMessage protobufs in length-prefixed frames, byte for byte, and
// read back however the chunks fall.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/chromecast/cast_link.dart';
import 'package:iptv_player/chromecast/cast_message.dart';
import 'package:iptv_player/chromecast/cast_session.dart';
import 'package:iptv_player/chromecast/hls_rewrite.dart';

List<int> _ascii(String s) => ascii.encode(s);

const _loadJson =
    '{"type":"LOAD","requestId":7,"sessionId":"S1","media":{"contentId":"http://192.168.1.5:8080/movie/u/p/42.mp4",'
    '"contentUrl":"http://192.168.1.5:8080/movie/u/p/42.mp4","contentType":"video/mp4","streamType":"BUFFERED",'
    '"metadata":{"metadataType":1,"title":"Film","images":[{"url":"http://img.test/42.jpg"}]}},"autoplay":true,'
    '"currentTime":1834.0}';

const _movie = CastMedia(
  url: 'http://192.168.1.5:8080/movie/u/p/42.mp4',
  contentType: 'video/mp4',
  title: 'Film',
  image: 'http://img.test/42.jpg',
  kind: CastMediaKind.movie,
  startAt: Duration(seconds: 1834),
);

CastMessage _text(String payload, {String ns = CastNs.receiver}) =>
    CastMessage(source: 'sender-0', destination: 'receiver-0', namespace: ns, payload: payload);

void main() {
  group('golden bytes', () {
    test('CONNECT', () {
      final frame = _text('{"type":"CONNECT"}', ns: CastNs.connection).frame();
      expect(frame, [
        0, 0, 0, 0x58, // 88 bytes follow
        0x08, 0x00, // protocol_version 0
        0x12, 0x08, ..._ascii('sender-0'),
        0x1a, 0x0a, ..._ascii('receiver-0'),
        0x22, 0x28, ..._ascii('urn:x-cast:com.google.cast.tp.connection'),
        0x28, 0x00, // payload_type: text
        0x32, 0x12, ..._ascii('{"type":"CONNECT"}'),
      ]);
    });

    test('PING', () {
      final frame = _text('{"type":"PING"}', ns: CastNs.heartbeat).frame();
      expect(frame, [
        0, 0, 0, 0x54, // 84 bytes follow
        0x08, 0x00, // protocol_version
        0x12, 0x08, ..._ascii('sender-0'), // source_id
        0x1a, 0x0a, ..._ascii('receiver-0'), // destination_id
        0x22, 0x27, ..._ascii('urn:x-cast:com.google.cast.tp.heartbeat'), // namespace
        0x28, 0x00, // payload_type
        0x32, 0x0f, ..._ascii('{"type":"PING"}'), // payload_utf8
      ]);
    });

    test('LOAD, whose payload length takes two varint bytes', () {
      final body = {
        'type': 'LOAD',
        'requestId': 7,
        'sessionId': 'S1',
        'media': _movie.toLoad(),
        'autoplay': true,
        'currentTime': _movie.startAt!.inMilliseconds / 1000,
      };
      expect(jsonEncode(body), _loadJson);
      final frame = CastMessage(
        source: 'sender-0',
        destination: 'web-1',
        namespace: CastNs.media,
        payload: jsonEncode(body),
      ).frame();
      expect(frame, [
        0, 0, 0x01, 0x91, // 401 bytes follow
        0x08, 0x00, // protocol_version
        0x12, 0x08, ..._ascii('sender-0'), // source_id
        0x1a, 0x05, ..._ascii('web-1'), // destination_id: the app's transport
        0x22, 0x20, ..._ascii('urn:x-cast:com.google.cast.media'), // namespace
        0x28, 0x00, // payload_type
        0x32, 0xd7, 0x02, ..._ascii(_loadJson), // payload_utf8, 343 bytes
      ]);
    });

    test('a live HLS channel and an episode, as LOAD media', () {
      const live = CastMedia(
        url: 'http://192.168.1.5:41000/t/live.m3u8',
        contentType: 'application/x-mpegurl',
        live: true,
        hls: true,
        title: 'News',
        subtitle: 'Evening',
        image: 'http://img.test/logo.png',
        kind: CastMediaKind.live,
        startAt: Duration(minutes: 3), // live has none: LOAD leaves it out
      );
      expect(
        jsonEncode(live.toLoad()),
        '{"contentId":"http://192.168.1.5:41000/t/live.m3u8",'
        '"contentUrl":"http://192.168.1.5:41000/t/live.m3u8","contentType":"application/x-mpegurl",'
        '"streamType":"LIVE","hlsSegmentFormat":"ts","hlsVideoSegmentFormat":"mpeg2_ts",'
        '"metadata":{"metadataType":0,"title":"News","subtitle":"Evening","images":[{"url":"http://img.test/logo.png"}]}}',
      );
      // F04-006: what the playlists said, when they were read
      const cmaf = CastMedia(
        url: 'http://192.168.1.5:41000/t/index.m3u8',
        contentType: 'application/x-mpegurl',
        hls: true,
        hlsFormat: HlsFormat.fmp4,
      );
      expect(cmaf.toLoad()['hlsSegmentFormat'], 'fmp4');
      expect(cmaf.toLoad()['hlsVideoSegmentFormat'], 'fmp4');
      const radio = CastMedia(
        url: 'http://192.168.1.5:41000/t/index.m3u8',
        contentType: 'application/x-mpegurl',
        hls: true,
        hlsFormat: HlsFormat('aac'),
      );
      expect(radio.toLoad()['hlsSegmentFormat'], 'aac');
      expect(radio.toLoad().containsKey('hlsVideoSegmentFormat'), isFalse, reason: 'audio alone');
      const episode = CastMedia(
        url: 'http://p.test/series/u/p/9.mkv',
        contentType: 'video/x-matroska',
        title: 'Pilot',
        seriesTitle: 'Show',
        season: 1,
        episode: 2,
        kind: CastMediaKind.episode,
      );
      expect(
        jsonEncode(episode.toLoad()['metadata']),
        '{"metadataType":2,"seriesTitle":"Show","season":1,"episode":2,"title":"Pilot"}',
      );
    });

    test('reads back what it writes', () {
      final m = CastMessage.decode(_text('{"type":"CONNECT"}', ns: CastNs.connection).encode());
      expect(m.source, 'sender-0');
      expect(m.destination, 'receiver-0');
      expect(m.namespace, CastNs.connection);
      expect(m.payload, '{"type":"CONNECT"}');
      expect(m.isBinary, isFalse);
      expect(m.json, {'type': 'CONNECT'});
    });
  });

  group('frames', () {
    final load = CastMessage(source: 'sender-0', destination: 'web-1', namespace: CastNs.media, payload: _loadJson);

    test('one fed a byte at a time comes out once, when complete', () {
      final bytes = load.frame();
      final decoder = CastFrameDecoder();
      final out = <CastMessage>[];
      for (var i = 0; i < bytes.length; i++) {
        final got = decoder.add([bytes[i]]);
        if (i < bytes.length - 1) expect(got, isEmpty, reason: 'byte $i');
        out.addAll(got);
      }
      expect(out, hasLength(1));
      expect(out.single.payload, _loadJson);
      expect(out.single.destination, 'web-1');
    });

    test('three in one chunk, and frames split across chunks', () {
      final ping = _text('{"type":"PING"}', ns: CastNs.heartbeat).frame();
      final connect = _text('{"type":"CONNECT"}', ns: CastNs.connection).frame();
      final all = [...connect, ...load.frame(), ...ping];
      expect(CastFrameDecoder().add(all).map((m) => m.json!['type']), ['CONNECT', 'LOAD', 'PING']);

      final decoder = CastFrameDecoder();
      final cut = connect.length + 10; // inside the LOAD
      expect(decoder.add(all.sublist(0, 2)), isEmpty, reason: 'half a length');
      expect(decoder.add(all.sublist(2, cut)).map((m) => m.json!['type']), ['CONNECT']);
      expect(decoder.add(all.sublist(cut)).map((m) => m.json!['type']), ['LOAD', 'PING']);
    });

    test('over 64 KiB is refused either way, before it is read', () {
      final big = _text('{"type":"LOAD","x":"${'a' * (64 * 1024)}"}');
      expect(big.frame, throwsFormatException);
      expect(big.frameSize, greaterThan(CastMessage.maxFrame));

      final at = Uint8List(4)..buffer.asByteData().setUint32(0, CastMessage.maxFrame - 4);
      expect(CastFrameDecoder().add(at), isEmpty, reason: 'exactly the limit: waits for the rest');
      final over = Uint8List(4)..buffer.asByteData().setUint32(0, CastMessage.maxFrame - 3);
      expect(() => CastFrameDecoder().add(over), throwsFormatException);
    });

    test('binary payloads are dropped, the frames around them kept', () {
      final binary = CastMessage(
        source: 'receiver-0',
        destination: 'sender-0',
        namespace: 'urn:x-cast:com.google.cast.tp.deviceauth',
        binary: Uint8List.fromList([1, 2, 3, 0, 255]),
      );
      expect(CastMessage.decode(binary.encode()).binary, [1, 2, 3, 0, 255]);
      final ping = _text('{"type":"PING"}', ns: CastNs.heartbeat).frame();
      final got = CastFrameDecoder().add([...ping, ...binary.frame(), ...ping]);
      expect(got.map((m) => m.namespace), [CastNs.heartbeat, CastNs.heartbeat]);
    });

    test('unknown fields are skipped by wire type, 8 and 9 included', () {
      final body = [
        ..._text('{"type":"PONG"}', ns: CastNs.heartbeat).encode(),
        0x40, 0x01, // 8: continued, varint
        0x48, 0xac, 0x02, // 9: remaining_length, varint 300
        0x79, 1, 2, 3, 4, 5, 6, 7, 8, // 15, 64-bit
        0x7a, 0x03, 9, 9, 9, // 15, length-delimited
        0x7d, 1, 2, 3, 4, // 15, 32-bit
      ];
      final m = CastMessage.decode(body);
      expect(m.json, {'type': 'PONG'});
      expect(m.namespace, CastNs.heartbeat);
    });

    test('a message cut short, or with a group, does not parse', () {
      final body = _text('{"type":"PONG"}').encode();
      expect(() => CastMessage.decode(body.sublist(0, body.length - 3)), throwsFormatException);
      expect(() => CastMessage.decode([...body, 0x7b]), throwsFormatException); // 15, start group
      final framed = Uint8List(4 + 3)
        ..buffer.asByteData().setUint32(0, 3)
        ..setRange(4, 7, [0x12, 0x09, 0x41]);
      expect(() => CastFrameDecoder().add(framed), throwsFormatException);
    });
  });
}
