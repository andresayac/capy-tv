// The welcome's and the screensaver's posters stay in memory up to a size, the least recently
// shown going first, and one too heavy to be a poster is not kept. Without the widget binding,
// which turns every real request away: these come from a server of the test's own.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/poster_wall.dart';

void main() {
  late HttpServer server;
  final asked = <String>[];

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      asked.add(req.uri.path);
      final name = req.uri.pathSegments.last;
      final mb = int.parse(name.split('-').first);
      // A JPEG's first bytes, but for the page some servers send with a 200
      final bytes = Uint8List(mb << 20);
      if (!name.endsWith('page')) bytes.setAll(0, const [0xFF, 0xD8, 0xFF]);
      req.response
        ..add(bytes)
        ..close();
    });
  });
  tearDownAll(() => server.close(force: true));

  String url(String name) => 'http://127.0.0.1:${server.port}/$name';

  test('kept up to 16 MB, the least recently asked for going first; one over 12 MB not at all', () async {
    for (final name in ['6-a', '6-b', '6-c']) {
      expect(await PosterWall.image(url(name)), hasLength(6 << 20));
    }
    expect(asked, ['/6-a', '/6-b', '/6-c']);

    await PosterWall.image(url('6-c')); // in memory still
    await PosterWall.image(url('6-b'));
    expect(asked, hasLength(3));
    await PosterWall.image(url('6-a')); // gone to make room: asked again
    expect(asked.last, '/6-a');
    expect(asked, hasLength(4));

    expect(await PosterWall.image(url('13-huge')), isNull);
  });

  test('the same poster asked for by many at once comes once; a page is no poster, nor asked again', () async {
    asked.clear();
    final all = await Future.wait([for (var i = 0; i < 5; i++) PosterWall.image(url('1-twice'))]);
    expect(all.every((b) => b?.length == 1 << 20), isTrue);
    expect(asked, ['/1-twice']);

    expect(await PosterWall.image(url('1-page')), isNull);
    expect(await PosterWall.image(url('1-page')), isNull);
    expect(asked, ['/1-twice', '/1-page']);
  });
}
