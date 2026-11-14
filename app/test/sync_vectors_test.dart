// Values sync must never change: every device derives the same keys from a password, names items
// and seals them the same way, and the Samsung TV's own code (tizen/src/sync/crypto.ts) gives these
// very values (checked on 2026-11-12). A change here locks everyone out of their account or
// their backups: it is never a test to update, only a change to undo.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/backup.dart';
import 'package:iptv_player/sync/sync_crypto.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('a password gives these keys, with the light settings tests use', () async {
    final k = await SignInKeys.password(' Ana@Example.com', 'correct horse', memoryKiB: 1024, passes: 1);
    expect(_hex(k.authKey), 'f7855bdd773821ae1e3c181a09cc1413f59845c1bab75e61e09998decb1dd5fe');
    expect(_hex(k.wrapKey), 'a141210ba5ed912e00e8afa7fbb2b4a624dacd27eb712a7907a42196b508ca3d');
  });

  test("a password gives these keys with the app's own settings (64 MiB, 3 passes)", () async {
    final k = await SignInKeys.password('ana@example.com', 'correct horse');
    expect(_hex(k.authKey), '28ad2e8bad83b346443b5dd592ea34a2a593a10d95145eec704ef283e675807a');
    expect(_hex(k.wrapKey), 'c9045b7ea0a704a7ce103dedf1b89603207d9e222591d0b6b6fb21b6e7eb6a95');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a recovery key gives these keys', () async {
    final k = await SignInKeys.recovery(RecoveryKey(List.generate(20, (i) => i)));
    expect(_hex(k.authKey), 'd26ee338c2ca0e9f36165588083290d7ac3effe57c80670edca3a3662a76f7bd');
    expect(_hex(k.wrapKey), '309ecb67e0dcf502d5cd160fc07aff7de6b2f20b12c507db6e1b8bcad8ce7251');
  });

  test('items are named, fingerprinted and opened as they always were', () async {
    final keys = SyncKeys(encKey: List.filled(32, 1), idKey: List.filled(32, 2));
    expect(await keys.itemId('playlist/abc'), 'p_JMqSIdO0eg5A_fYo2uf3lcTFXojsgPjqhAht4e_c4');
    expect(await keys.fingerprint('{"a":1}'), 'rtW3ejael94jjipgNoP6B8Yyc0Qyg92ASJVjqSdfHPk');
    // Sealed once, by this app; the TV opens it too
    const sealed = 'J1CMS2Ve4nQNMQgMU4+taClhm0/fR+i2zKtRljOcXBgDaXB4X+3jpdgQHf+H4grVxF6+EHHrCWuK0VVhAQfJSMWe6FvGOZXh';
    expect(await keys.open('item-1', sealed), {'name': 'Kitchen', 'n': 2});
    await expectLater(keys.open('item-2', sealed), throwsA(anything), reason: 'not as another item');
  });

  test("a backup says what it is, and those made under the app's earlier names are still taken", () {
    expect(Backup.format, 'capy-tv-backup');
    expect(Backup.isBackup({'format': 'an-earlier-name-backup', 'playlists': []}), isTrue);
    expect(Backup.isBackup({'format': 'something else', 'playlists': []}), isFalse);
  });
}
