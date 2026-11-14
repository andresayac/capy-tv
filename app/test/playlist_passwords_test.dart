// A password the device's secure storage no longer gives back (Android drops an entry it cannot
// open, rather than say so) is noted as lost, not taken for an empty one that sync would spread.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an account whose password is gone from secure storage has it lost, not empty', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final store = PlaylistStore.instance..reset();
    await store.add(
      const Playlist(
        id: 'acc',
        name: 'Panel',
        type: PlaylistType.xtream,
        url: 'http://tv.example',
        username: 'ana',
        password: 's3cret',
      ),
    );
    await store.add(
      const Playlist(id: 'list', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.example/a.m3u'),
    );

    FlutterSecureStorage.setMockInitialValues({}); // the entry dropped, the preferences as they were
    store.reset();
    final loaded = await store.load();
    expect(loaded.firstWhere((p) => p.id == 'acc').password, '');
    expect(store.lostPasswords, {'acc'}, reason: 'an M3U list has no password to lose');
  });
}
