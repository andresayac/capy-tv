// Opening a playlist (and getting its lists again for an update) takes the same steps in one place:
// only what the profile may see, the account, the profile's library in that playlist.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/kids.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/playlist_session.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => dir.path,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
    currentLibrary.value = null;
    dir.deleteSync(recursive: true);
  });

  // A list with a channel for everyone and one for adults
  final list = MockClient(
    (_) async => http.Response(
      '#EXTM3U\n'
      '#EXTINF:-1 group-title="News",News 24\nhttp://tv.test/live/1.ts\n'
      '#EXTINF:-1 group-title="XXX Adultos",Late\nhttp://tv.test/live/2.ts\n',
      200,
    ),
  );
  final playlist = Playlist.create(type: PlaylistType.m3u, url: 'http://lists.test/list.m3u', name: 'Mine');
  const grown = Profile(id: 'ana', name: 'Ana');
  const kid = Profile(id: 'leo', name: 'Leo', kids: true);

  test('it opens with the profile\'s library in that playlist, and no account for an M3U', () async {
    final session = await http.runWithClient(() => PlaylistSession.open(playlist, grown, liveFormat: 'ts'), () => list);
    expect(session.account, isNull);
    expect(session.library.playlistId, playlist.id);
    expect(session.library.profileId, 'ana');
    expect(session.source.hideAdult, isTrue, reason: 'only what the profile may see');
    expect([for (final c in await session.source.liveChannels()) c.name], ['News 24']);
  });

  test('a kids profile\'s source keeps to what kids may see, opened or fresh', () async {
    final opened = await http.runWithClient(() => PlaylistSession.open(playlist, kid, liveFormat: 'ts'), () => list);
    expect((opened.source as KidsFilter).kidsOnly, isTrue);
    final fresh = await http.runWithClient(() => PlaylistSession.fresh(playlist, kid, liveFormat: 'ts'), () => list);
    expect((fresh as KidsFilter).kidsOnly, isTrue, reason: 'an update keeps to it too');
    expect(fresh.hideAdult, isTrue);
  });

  test('its library is the open one until it closes, unless another took its place', () async {
    final first = await http.runWithClient(() => PlaylistSession.open(playlist, grown, liveFormat: 'ts'), () => list);
    first.publish();
    expect(currentLibrary.value, same(first.library));
    // The same playlist opened again for another profile, before the first one's Home went
    final second = await http.runWithClient(() => PlaylistSession.open(playlist, kid, liveFormat: 'ts'), () => list);
    second.publish();
    first.close();
    expect(currentLibrary.value, same(second.library), reason: 'not the other\'s to take away');
    second.close();
    expect(currentLibrary.value, isNull);
  });
}
