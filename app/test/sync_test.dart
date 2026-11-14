// Account sync: the keys and encryption, how libraries from two devices merge, and the whole
// thing against the real sync server (built from ../server when Go is installed).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/sync/cast.dart';
import 'package:iptv_player/sync/sync_client.dart';
import 'package:iptv_player/sync/sync_crypto.dart';
import 'package:iptv_player/sync/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_server.dart';

const _movie = MediaRef(kind: MediaKind.movie, id: 'm1', title: 'Film');
const _show = Series(id: 's1', name: 'Show');
final _episode = MediaRef.episode(_show, const Episode(id: 'e1', season: 1, number: 1, title: 'Pilot'));

Future<SignInKeys> _password(String email, String password) =>
    SignInKeys.password(email, password, memoryKiB: 1024, passes: 1);

int _ago(Duration d) => DateTime.now().subtract(d).millisecondsSinceEpoch;

Map<String, dynamic> _history(MediaRef r, int at, {int minutes = 10}) => HistoryEntry(
  ref: r,
  position: Duration(minutes: minutes),
  duration: const Duration(hours: 1),
  updated: DateTime.fromMillisecondsSinceEpoch(at),
).toJson();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("what sync fingerprints is the content, not the order a device wrote it in (the TV's profiles)", () {
    final here = {
      'profiles': [
        {'id': 'kid', 'name': 'Kid', 'avatar': 2, 'audio': 'spa', 'minutes': 60, 'pin': null},
      ],
      'pin': 'x',
    };
    final tv = {
      'pin': 'x',
      'profiles': [
        {'audio': 'spa', 'minutes': 60, 'id': 'kid', 'avatar': 2, 'name': 'Kid', 'pin': null},
      ],
    };
    expect(jsonEncode(here), isNot(jsonEncode(tv)));
    expect(canonicalJson(here), canonicalJson(tv));
    expect(canonicalJson({'b': 1, 'a': 2}), '{"a":2,"b":1}');
    expect(canonicalJson(tv..['pin'] = 'y'), isNot(canonicalJson(here)), reason: 'a change is still one');
  });

  group('keys', () {
    test('a password gives the same sign-in keys on every device, and only that password', () async {
      final a = await _password(' Ana@Example.com', 'correct horse');
      final b = await _password('ana@example.com', 'correct horse');
      final other = await _password('ana@example.com', 'correct horsf');
      expect(a.authKey, b.authKey);
      expect(a.wrapKey, b.wrapKey);
      expect(other.authKey, isNot(a.authKey));
      expect({...a.authKey}.length, greaterThan(8));
      expect(a.wrapKey, isNot(a.authKey));
    });

    test('the account keys open only with the secret that wrapped them', () async {
      final keys = SyncKeys.random();
      expect(SyncKeys.random().toJson(), isNot(keys.toJson()));
      final password = await _password('ana@example.com', 'correct horse');
      final recovery = await SignInKeys.recovery(RecoveryKey.random());
      final wrapped = await keys.wrap(password.wrapKey);
      expect(wrapped, isNot(contains(base64.encode(keys.encKey))));
      expect((await SyncKeys.unwrap(password.wrapKey, wrapped)).toJson(), keys.toJson());
      await expectLater(SyncKeys.unwrap(recovery.wrapKey, wrapped), throwsA(isA<SecretBoxAuthenticationError>()));
      expect(recovery.authKey, isNot(password.authKey));
    });

    test('recovery keys read back as written, however they are typed', () {
      final key = RecoveryKey.random();
      expect(key.text, matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{4}-){7}[0-9A-HJKMNP-TV-Z]{4}$')));
      expect(RecoveryKey.parse(key.text), key);
      final typed = ' ${key.text.toLowerCase().replaceAll('-', ' ').replaceAll('0', 'o').replaceAll('1', 'l')} ';
      expect(RecoveryKey.parse(typed), key);
      expect(RecoveryKey.parse(key.text.substring(1)), isNull, reason: 'one short');
      expect(RecoveryKey.parse('${key.text.substring(1)}U'), isNull, reason: 'not in the alphabet');
      expect(RecoveryKey(List.filled(20, 0)).text, '0000-0000-0000-0000-0000-0000-0000-0000');
      expect(RecoveryKey(List.filled(20, 255)).text, 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ');
      expect(RecoveryKey.parse('0000-0000-0000-0000-0000-0000-0000-001Z')!.bytes.last, 0x3f);
    });

    test('items open only with the key and under the id they were sealed for', () async {
      final keys = SyncKeys.random();
      final id = await keys.itemId('playlist/xtream|http://p.test|ana');
      expect(id, await keys.itemId('playlist/xtream|http://p.test|ana'));
      expect(id, isNot(contains('p.test')));
      const secret = 'password-unica-de-prueba-8841'; // a short one could be in the ciphertext by chance
      final sealed = await keys.seal(id, {'password': secret});
      expect(utf8.decode(base64.decode(sealed), allowMalformed: true), isNot(contains(secret)));
      expect(() => gzip.decode(base64.decode(sealed)), throwsA(anything), reason: 'encrypted, not only compressed');
      expect(await keys.open(id, sealed), {'password': secret});
      await expectLater(keys.open('another-id', sealed), throwsA(isA<SecretBoxAuthenticationError>()));
      await expectLater(SyncKeys.random().open(id, sealed), throwsA(isA<SecretBoxAuthenticationError>()));
    });

    test('a write refused as stale is not taken for an account that exists', () async {
      Future<SyncProblem?> problem(String body) async {
        final client = SyncClient(
          Uri.parse('https://sync.test/'),
          client: MockClient((_) async => http.Response(body, 409)),
        );
        try {
          await client.put(const [RemoteItem('a', null)], base: 1);
          return null;
        } on SyncException catch (e) {
          return e.problem;
        }
      }

      expect(await problem('{"error":"stale"}'), SyncProblem.stale);
      expect(await problem('{"error":"exists"}'), SyncProblem.exists);
      final invite = SyncClient(
        Uri.parse('https://sync.test/'),
        client: MockClient((_) async => http.Response('{"error":"invite"}', 403)),
      );
      await expectLater(
        invite.signUp('a@b.c', [1], 'x', passwordKeys: '', recoveryKey: [1], recoveryKeys: ''),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.invite)),
      );
      final noRoom = SyncClient(
        Uri.parse('https://sync.test/'),
        client: MockClient((_) async => http.Response('{"error":"full"}', 403)),
      );
      await expectLater(
        noRoom.signUp('a@b.c', [1], 'x', passwordKeys: '', recoveryKey: [1], recoveryKeys: ''),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.full)),
        reason: "a server open to anyone that has all the accounts it takes (the server's MAX_ACCOUNTS)",
      );
      final full = SyncClient(
        Uri.parse('https://sync.test/'),
        client: MockClient((_) async => http.Response('{"error":"quota"}', 413)),
      );
      await expectLater(
        full.put(const [RemoteItem('a', 'x')]),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.quota)),
      );
    });

    test(
      'an answer that stops half way, or comes from no sync server, is said: neither waited for nor thrown raw',
      () async {
        SyncClient.wait = const Duration(milliseconds: 200);
        addTearDown(() => SyncClient.wait = const Duration(seconds: 20));
        Matcher problem(SyncProblem p) => throwsA(isA<SyncException>().having((e) => e.problem, 'problem', p));
        final stalled = SyncClient(
          Uri.parse('https://sync.test/'),
          client: MockClient.streaming(
            (_, _) async => http.StreamedResponse(StreamController<List<int>>().stream, 200),
          ),
        );
        await expectLater(stalled.items(0), problem(SyncProblem.network));
        for (final body in ['<html><body>Welcome</body></html>', '{"rev": 1}', '[]']) {
          final other = SyncClient(
            Uri.parse('https://sync.test/'),
            client: MockClient((_) async => http.Response(body, 200)),
          );
          await expectLater(other.signIn('a@b.c', [1], 'x'), problem(SyncProblem.server), reason: body);
        }
      },
    );

    test('server addresses: https, or plain http on the local network only', () {
      expect(SyncClient.parseServer('sync.example.com').toString(), 'https://sync.example.com/');
      expect(SyncClient.parseServer('https://example.com/iptv').toString(), 'https://example.com/iptv/');
      expect(SyncClient.parseServer('http://192.168.1.20:8080'), isNotNull);
      expect(SyncClient.parseServer('http://localhost:8080'), isNotNull);
      expect(SyncClient.parseServer('http://sync.example.com'), isNull);
      expect(SyncClient.parseServer('ftp://x'), isNull);
      expect(SyncClient.parseServer(''), isNull);
    });
  });

  group('merging libraries', () {
    final now = _ago(Duration.zero);
    final phone = {
      'favorites': [_movie.toJson()],
      'favAt': {_movie.key: now - 5000},
      'history': [_history(_movie, now - 4000)],
    };
    final tv = {
      'unfav': {_movie.key: now - 1000}, // removed later, on the TV
      'history': [_history(_movie, now - 2000, minutes: 40), _history(_episode, now - 3000)],
    };
    final laptop = {
      'forgot': {_episode.key: now - 500},
    };

    test('gives the same result in any order, and again', () {
      String merged(List<Map<String, dynamic>> docs) {
        final lib = Library.fromJson(const {});
        for (final d in docs) {
          lib.merge(d);
        }
        return jsonEncode(lib.toJson());
      }

      final a = merged([phone, tv, laptop]);
      expect(merged([laptop, tv, phone]), a);
      expect(merged([tv, phone, laptop, tv, phone]), a);
      final lib = Library.fromJson(jsonDecode(a) as Map<String, dynamic>);
      expect(lib.isFavorite(_movie), isFalse, reason: 'the later removal wins');
      expect(lib.entry(_movie)!.position, const Duration(minutes: 40), reason: 'the latest progress wins');
      expect(lib.entry(_episode), isNull, reason: 'forgotten on the laptop');
    });

    test('a favorite added again after a removal stays', () async {
      SharedPreferences.setMockInitialValues({});
      final lib = await Library.load('p', mainProfileId);
      lib.merge(tv); // knows the removal
      await lib.toggleFavorite(_movie);
      final other = Library.fromJson(phone)..merge(lib.toJson());
      expect(other.isFavorite(_movie), isTrue);
    });

    test('clearing the history wins over what was watched before, not after', () {
      final lib = Library.fromJson({
        'history': [_history(_movie, now - 3000), _history(_episode, now - 1000)],
      })..merge({'cleared': now - 2000});
      expect(lib.history.map((h) => h.ref.key), [_episode.key]);
    });

    test('two devices with the same moment settle the same way, so neither sends it back', () {
      final plain = {
        'favorites': [_movie.toJson()],
        'favAt': {_movie.key: now - 5000},
        'history': [_history(_movie, now - 4000)],
      };
      final described = {
        'favorites': [_movie.withTmdb('603').toJson()],
        'favAt': {_movie.key: now - 5000},
        'history': [_history(_movie.withTmdb('603'), now - 4000)],
      };
      final a = Library.fromJson(plain)..merge(described);
      final b = Library.fromJson(described)..merge(plain);
      expect(jsonEncode(a.toJson()), jsonEncode(b.toJson()));
    });

    test('a better described item wins over the old version', () async {
      SharedPreferences.setMockInitialValues({});
      final tv = await Library.load('p', mainProfileId);
      tv.merge({
        'favorites': [_movie.toJson()],
        'favAt': {_movie.key: now - 5000},
        'history': [_history(_movie, now - 4000)],
      });
      final phone = Library.fromJson(tv.toJson());
      await tv.updateRef(_movie.withTmdb('603'));
      phone.merge(tv.toJson());
      expect(phone.favorites(MediaKind.movie).single.tmdb, '603');
      expect(phone.entry(_movie)!.ref.tmdb, '603');
      expect(jsonEncode(phone.toJson()), jsonEncode(tv.toJson()));
    });

    test('old markers go by the library\'s own time, not the clock of each device', () {
      final old = now - const Duration(days: 200).inMilliseconds;
      final quiet = Library.fromJson({
        'unfav': {_movie.key: old},
      });
      expect(quiet.toJson()['unfav'], {_movie.key: old}, reason: 'nothing happened since: kept');
      final busy = Library.fromJson({
        'unfav': {_movie.key: old},
        'history': [_history(_episode, now)],
      });
      expect(busy.toJson()['unfav'], isEmpty, reason: 'long before the latest event: dropped');
    });

    test('libraries saved before markers existed still merge', () {
      final lib =
          Library.fromJson({
            'favorites': [_movie.toJson()],
            'history': [_history(_movie, now - 1000)],
          })..merge({
            'favorites': [_episode.toJson()],
          });
      expect([for (final f in lib.favorites(MediaKind.movie)) f.key], [_movie.key]);
      expect(lib.isFavorite(_episode), isTrue);
    });
  });

  group('with the sync server', () {
    TestSyncServer? server;
    late Uri url;

    setUpAll(() async {
      HttpOverrides.global = null; // real sockets, not the test binding's fake HTTP
      final (started, why) = await TestSyncServer.start();
      if (started == null) return markTestSkipped(why);
      server = started;
      url = started.url;
      SyncService.kdf = (memoryKiB: 1024, passes: 1);
      SyncService.delay = const Duration(milliseconds: 50);
      SyncService.quietDelay = const Duration(seconds: 1);
    });

    tearDownAll(() => server?.stop());

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      PlaylistStore.instance.reset();
      await ProfileStore.instance.load();
    });

    Future<void> eventually(Future<bool> Function() check) async {
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (!await check()) {
        if (DateTime.now().isAfter(end)) fail('did not happen in time');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    test('lists and libraries go between devices, encrypted, and live', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'ana@example.com', 'correct horse');

      const playlist = Playlist(
        id: 'x1',
        name: 'Provider',
        type: PlaylistType.xtream,
        url: 'http://provider.test',
        username: 'ana',
        password: 'password-unica-de-prueba-8841',
      );
      await other.put([
        await other.item('playlist/x1', {'at': _ago(const Duration(minutes: 5)), 'data': playlist.toJson()}),
        await other.item('library/x1', {
          'data': {
            'favorites': [_movie.toJson()],
            'favAt': {_movie.key: _ago(const Duration(minutes: 5))},
          },
        }),
      ]);
      // This device signs in and gets the playlist (with its password) and its favorites
      final sync = SyncService.instance;
      await expectLater(
        sync.signIn(server: url, email: 'ana@example.com', password: 'wrong'),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.credentials)),
      );
      await sync.signIn(server: url, email: 'ANA@example.com', password: 'correct horse');
      expect(sync.status, SyncStatus.synced);
      final mine = (await PlaylistStore.instance.load()).single;
      expect((mine.name, mine.password), ('Provider', 'password-unica-de-prueba-8841'));
      final library = await Library.load(mine.id, mainProfileId);
      expect(library.isFavorite(_movie), isTrue);

      // Watching here reaches the other device a moment later
      final libraryId = await other.keys.itemId('library/x1');
      Future<String?> sent() async =>
          (await other.client.items(0)).items.where((i) => i.id == libraryId).single.payload;
      final before = await sent();
      await library.record(_episode, position: const Duration(minutes: 12), duration: const Duration(hours: 1));
      final end = DateTime.now().add(const Duration(seconds: 15));
      while (await sent() == before && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await sent(), isNot(before), reason: 'the app sent its library');

      // Nothing readable on the server, of what this app sent too: not even unzipped, nor opened
      // with another key, and the ids say nothing
      for (final i in (await other.client.items(0)).items) {
        expect(i.id, isNot(contains('playlist')));
        expect(i.id, isNot(contains('library')));
        final raw = base64.decode(i.payload!);
        expect(() => gzip.decode(raw), throwsA(anything), reason: 'encrypted, not only compressed');
        expect(utf8.decode(raw, allowMalformed: true), isNot(contains('password-unica-de-prueba-8841')));
        await expectLater(SyncKeys.random().open(i.id, i.payload!), throwsA(isA<SecretBoxAuthenticationError>()));
      }
      await eventually(() async {
        final lib = await other.read('library/x1');
        return lib != null && (lib['data']['history'] as List).isNotEmpty;
      });
      final there = Library.fromJson((await other.read('library/x1'))!['data'] as Map<String, dynamic>);
      expect((there.isFavorite(_movie), there.entry(_episode)?.position), (true, const Duration(minutes: 12)));

      // A playlist added here goes too
      await PlaylistStore.instance.add(
        const Playlist(id: 'm3u', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u'),
      );
      await eventually(() async => await other.read('playlist/m3u') != null);

      // The other device removes the provider: the socket brings it here at once
      await other.put([
        await other.item('playlist/x1', {'at': _ago(Duration.zero) + 1000, 'deleted': true}),
      ]);
      await eventually(() async => (await PlaylistStore.instance.load()).map((p) => p.name).join() == 'Free');

      final devices = await sync.devices();
      expect(devices, hasLength(2));
      expect(
        [
          for (final d in devices)
            if (d.current) d.name,
        ],
        hasLength(1),
        reason: 'this device is marked',
      );
      await sync.signOut();
      expect(sync.status, SyncStatus.off);
      expect((await PlaylistStore.instance.load()).single.name, 'Free', reason: 'signing out keeps what is here');
      other.close();
    });

    test('send to: what another device sends plays here, and this one sends there', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'cast@example.com', 'correct horse');
      const playlist = Playlist(
        id: 'x1',
        name: 'Provider',
        type: PlaylistType.xtream,
        url: 'http://p.test',
        username: 'a',
      );
      await other.put([
        await other.item('playlist/x1', {'at': _ago(const Duration(minutes: 5)), 'data': playlist.toJson()}),
      ]);
      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'cast@example.com', password: 'correct horse');
      final mine = (await PlaylistStore.instance.load()).single;
      final devices = await sync.devices();
      final me = devices.firstWhere((d) => d.current).id, them = devices.firstWhere((d) => !d.current).id;
      castRequest.value = null;

      Future<RemoteItem> request(String to, int at) => other.item('cast/$to', {
        'v': 'cast-1',
        'at': at,
        'data': {'playlist': 'x1', 'ref': _movie.toJson(), 'position': 754000, 'from': 'Living room'},
      });
      // Not for this device, or from a while ago (a device that was off): nothing plays
      await other.put([await request(them, _ago(Duration.zero)), await request(me, _ago(const Duration(minutes: 5)))]);
      await sync.syncNow();
      expect(castRequest.value, isNull);

      // For this device, now: it comes live, in this device's playlist, from where it was
      await other.put([await request(me, _ago(Duration.zero))]);
      await eventually(() async => castRequest.value != null);
      final r = castRequest.value!;
      expect(
        (r.playlistId, r.ref.key, r.position, r.from),
        (mine.id, _movie.key, const Duration(minutes: 12, seconds: 34), 'Living room'),
      );

      // And this device sends to the other one
      await sync.cast(to: them, playlistId: mine.id, ref: _episode, position: const Duration(minutes: 3));
      final sent = (await other.read('cast/$them'))!;
      expect(sent['v'], 'cast-1', reason: 'devices on an older version leave it alone');
      expect((sent['data']['playlist'], sent['data']['ref']['id'], sent['data']['position']), ('x1', 'e1', 180000));

      // Signed in again without restarting the app: a new session, a new id, and it still comes
      await sync.signIn(server: url, email: 'cast@example.com', password: 'correct horse');
      final again = (await sync.devices()).firstWhere((d) => d.current).id;
      expect(again, isNot(me));
      castRequest.value = null;
      await other.put([await request(again, _ago(Duration.zero))]);
      await eventually(() async => castRequest.value != null);
      castRequest.value = null;
      await sync.signOut();
      other.close();
    });

    test('joining an account takes what it has, and adds what is only here', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'cleo@example.com', 'correct horse');
      const there = Playlist(
        id: 'x1',
        name: 'Provider',
        type: PlaylistType.xtream,
        url: 'http://provider.test',
        username: 'cleo',
        password: 'new password',
      );
      await other.put([
        await other.item('playlist/x1', {'at': _ago(const Duration(days: 1)), 'data': there.toJson()}),
        await other.item('library/x1', {
          'data': {
            'favorites': [_movie.toJson()],
            'favAt': {_movie.key: _ago(const Duration(days: 1))},
          },
        }),
      ]);
      // This device had the same provider account, with a password changed since, and a list of its own
      await PlaylistStore.instance.add(there.copyWith(id: 'old', name: 'My provider', password: 'old password'));
      await PlaylistStore.instance.add(
        const Playlist(id: 'own', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u'),
      );
      await (await Library.load('old', mainProfileId)).toggleFavorite(_episode);

      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'cleo@example.com', password: 'correct horse');
      final mine = {for (final p in await PlaylistStore.instance.load()) p.id: p};
      expect(mine.keys, unorderedEquals(['old', 'own']), reason: 'the same provider account is one playlist');
      expect((mine['old']!.name, mine['old']!.password), ('Provider', 'new password'));
      final library = await Library.load('old', mainProfileId);
      expect((library.isFavorite(_movie), library.isFavorite(_episode)), (true, true));

      await eventually(() async => await other.read('playlist/own') != null);
      expect((await other.read('playlist/x1'))!['data']['password'], 'new password', reason: 'not overwritten');
      expect(await other.read('playlist/old'), isNull);
      await eventually(() async {
        final lib = await other.read('library/x1');
        return lib != null && Library.fromJson(lib['data'] as Map<String, dynamic>).isFavorite(_episode);
      });
      await sync.signOut();
      other.close();
    });

    test('profiles and their libraries follow, and a profile deleted elsewhere goes here too', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'fay@example.com', 'correct horse');
      const playlist = Playlist(id: 'x1', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u');
      final now = _ago(Duration.zero);
      Map<String, dynamic> profiles({bool deleted = false}) => {
        'profiles': [
          {'id': 'main', 'name': 'Fay', 'at': now},
          {'id': 'kid', 'name': 'Leo', 'kids': true, 'at': deleted ? now + 1 : now, if (deleted) 'deleted': true},
        ],
      };
      await other.put([
        await other.item('playlist/x1', {'at': now, 'data': playlist.toJson()}),
        await other.item('profiles', {'data': profiles()}),
        await other.item('library/x1@kid', {
          'data': {
            'favorites': [_movie.toJson()],
            'favAt': {_movie.key: now},
          },
        }),
      ]);

      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'fay@example.com', password: 'correct horse');
      final store = ProfileStore.instance;
      expect(store.profiles.map((p) => p.name), ['Fay', 'Leo']);
      final kid = await Library.load('x1', 'kid');
      expect(kid.isFavorite(_movie), isTrue);
      expect((await Library.load('x1', mainProfileId)).isFavorite(_movie), isFalse, reason: "Leo's, not Fay's");

      // Leo watches something here: it goes to Leo's library on the server
      await kid.record(_episode, position: const Duration(minutes: 3), duration: const Duration(hours: 1));
      await eventually(() async {
        final lib = await other.read('library/x1@kid');
        return lib != null && (lib['data']['history'] as List).isNotEmpty;
      });

      // Deleted on the other device: gone here, library and all
      await other.put([
        await other.item('profiles', {'data': profiles(deleted: true)}),
      ]);
      await eventually(() async => store.profiles.length == 1);
      expect(await Library.stored('x1', 'kid'), isNull);
      await sync.signOut();
      other.close();
    });

    test('progress noted during playback goes a while later', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'dan@example.com', 'correct horse');
      await PlaylistStore.instance.add(
        const Playlist(id: 'own', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u'),
      );
      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'dan@example.com', password: 'correct horse');
      final library = await Library.load('own', mainProfileId);
      Future<Duration?> position() async {
        final lib = await other.read('library/own');
        return lib == null ? null : Library.fromJson(lib['data'] as Map<String, dynamic>).entry(_movie)?.position;
      }

      await library.record(_movie, duration: const Duration(hours: 1));
      await eventually(() async => await position() == Duration.zero);
      await library.record(
        _movie,
        position: const Duration(minutes: 5),
        duration: const Duration(hours: 1),
        quiet: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await position(), Duration.zero, reason: 'not yet');
      await eventually(() async => await position() == const Duration(minutes: 5));
      await sync.signOut();
      other.close();
    });

    test('an account deleted and created again gets everything again', () async {
      if (server == null) return markTestSkipped('no sync server');
      await PlaylistStore.instance.add(
        const Playlist(id: 'own', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u'),
      );
      final sync = SyncService.instance;
      await sync.createAccount(server: url, email: 'eve@example.com', password: 'correct horse');
      final secret = await _password('eve@example.com', 'correct horse');
      final gone = SyncClient(url);
      await gone.signIn('eve@example.com', secret.authKey, 'Other');
      await gone.deleteAccount(secret.authKey);
      gone.close();
      await sync.syncNow();
      expect(sync.status, SyncStatus.expired);

      final other = await _OtherDevice.create(url, 'eve@example.com', 'correct horse');
      await sync.signIn(server: url, email: 'eve@example.com', password: 'correct horse');
      await eventually(() async => await other.read('playlist/own') != null);
      await sync.signOut();
      other.close();
    });

    test('an item this device cannot take is left, and the rest still sync', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'jo@example.com', 'correct horse');
      const good = Playlist(id: 'ok', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u');
      await other.put([
        // A kind of list of a newer version, sent under the same item version
        await other.item('playlist/new', {
          'at': _ago(const Duration(minutes: 5)),
          'data': {...good.toJson(), 'id': 'new', 'type': 'stalker'},
        }),
        await other.item('library/bad', {'data': 'not a library'}),
        await other.item('playlist/ok', {'at': _ago(const Duration(minutes: 5)), 'data': good.toJson()}),
      ]);
      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'jo@example.com', password: 'correct horse');
      expect(sync.status, SyncStatus.synced, reason: 'not "offline" for ever');
      expect([for (final p in await PlaylistStore.instance.load()) p.name], ['Free']);
      await PlaylistStore.instance.add(
        const Playlist(id: 'own', name: 'Own', type: PlaylistType.m3u, url: 'http://lists.test/own.m3u'),
      );
      await eventually(() async => await other.read('playlist/own') != null);
      await sync.signOut();
      other.close();
    });

    test('a playlist removed here is removed on the others, and its library goes with it', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'ida@example.com', 'correct horse');
      const playlist = Playlist(id: 'gone', name: 'Old', type: PlaylistType.m3u, url: 'http://lists.test/old.m3u');
      await other.put([
        await other.item('playlist/gone', {'at': _ago(const Duration(minutes: 5)), 'data': playlist.toJson()}),
        await other.item('library/gone', {
          'data': {
            'favorites': [_movie.toJson()],
            'favAt': {_movie.key: _ago(const Duration(minutes: 5))},
          },
        }),
      ]);
      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'ida@example.com', password: 'correct horse');
      final here = (await PlaylistStore.instance.load()).single;
      expect((await Library.load(here.id, mainProfileId)).isFavorite(_movie), isTrue);

      await PlaylistStore.instance.remove(here);
      await eventually(() async => (await other.read('playlist/gone'))?['deleted'] == true);
      await eventually(() async => await other.read('library/gone') == null);
      await sync.signOut();
      other.close();
    });

    test('after a restart it carries on from what it saved, with what changed meanwhile', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'kai@example.com', 'correct horse');
      const first = Playlist(id: 'p1', name: 'First', type: PlaylistType.m3u, url: 'http://lists.test/1.m3u');
      await other.put([
        await other.item('playlist/p1', {'at': _ago(const Duration(minutes: 5)), 'data': first.toJson()}),
      ]);
      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'kai@example.com', password: 'correct horse');
      await sync.closeForTests();

      // While the app was closed: one added on the other device, and the first renamed here
      const second = Playlist(id: 'p2', name: 'Second', type: PlaylistType.m3u, url: 'http://lists.test/2.m3u');
      await other.put([
        await other.item('playlist/p2', {'at': _ago(const Duration(minutes: 1)), 'data': second.toJson()}),
      ]);
      final mine = (await PlaylistStore.instance.load()).single;
      await PlaylistStore.instance.update(mine.copyWith(name: 'First, renamed'));

      await sync.start();
      await sync.syncNow();
      expect(sync.status, SyncStatus.synced);
      expect({for (final p in await PlaylistStore.instance.load()) p.name}, {'First, renamed', 'Second'});
      await eventually(() async => (await other.read('playlist/p1'))?['data']?['name'] == 'First, renamed');
      await sync.signOut();
      other.close();
    });

    test('a server restored from an older backup gets again what it lost', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'lea@example.com', 'correct horse');
      const playlist = Playlist(id: 'r1', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u');
      await other.put([
        await other.item('playlist/r1', {'at': _ago(const Duration(minutes: 5)), 'data': playlist.toJson()}),
        await other.item('library/r1', {
          'data': {
            'favorites': [_movie.toJson()],
            'favAt': {_movie.key: _ago(const Duration(minutes: 5))},
          },
        }),
      ]);
      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'lea@example.com', password: 'correct horse');
      // The server, restored from a backup made before: the library is not there, and its
      // revisions are behind the one this device had caught up with
      await other.put([RemoteItem(await other.keys.itemId('library/r1'), null)]);
      await sync.closeForTests();
      final prefs = await SharedPreferences.getInstance();
      final state = jsonDecode(prefs.getString('sync.state')!) as Map<String, dynamic>;
      await prefs.setString('sync.state', jsonEncode({...state, 'rev': (state['rev'] as int) + 1000}));

      await sync.start();
      await sync.syncNow();
      await eventually(() async => await other.read('library/r1') != null);
      final back = Library.fromJson((await other.read('library/r1'))!['data'] as Map<String, dynamic>);
      expect(back.isFavorite(_movie), isTrue);
      await sync.signOut();
      other.close();
    });

    test('leaving the app sends the progress that was waiting', () async {
      if (server == null) return markTestSkipped('no sync server');
      final wait = SyncService.quietDelay;
      SyncService.quietDelay = const Duration(hours: 1);
      addTearDown(() => SyncService.quietDelay = wait);
      final other = await _OtherDevice.create(url, 'mia@example.com', 'correct horse');
      const playlist = Playlist(id: 'w1', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u');
      await other.put([
        await other.item('playlist/w1', {'at': _ago(const Duration(minutes: 5)), 'data': playlist.toJson()}),
      ]);
      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'mia@example.com', password: 'correct horse');
      final mine = (await PlaylistStore.instance.load()).single;
      final library = await Library.load(mine.id, mainProfileId);
      await library.record(
        _episode,
        position: const Duration(minutes: 12),
        duration: const Duration(hours: 1),
        quiet: true,
      );

      // It would wait an hour; the app goes to the background now
      final binding = TestWidgetsFlutterBinding.instance;
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        binding.handleAppLifecycleStateChanged(s);
      }
      addTearDown(() {
        for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
          binding.handleAppLifecycleStateChanged(s);
        }
      });
      await eventually(() async {
        final lib = await other.read('library/w1');
        return lib != null && (lib['data']['history'] as List).isNotEmpty;
      });
      await sync.signOut();
      other.close();
    });

    test('a device signed out from another one asks to sign in again', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'gil@example.com', 'correct horse');
      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'gil@example.com', password: 'correct horse');
      final here = (await other.client.devices()).firstWhere((d) => !d.current);
      await other.client.signOutDevice(here.id);
      await sync.syncNow();
      expect(sync.status, SyncStatus.expired);
      expect([for (final d in await other.client.devices()) d.name], ['Other']);
      await sync.signOut();
      other.close();
    });

    test('a session ended elsewhere asks to sign in again', () async {
      if (server == null) return markTestSkipped('no sync server');
      final sync = SyncService.instance;
      await sync.createAccount(server: url, email: 'bob@example.com', password: 'pass phrase');
      expect(sync.status, SyncStatus.synced);
      final secret = await _password('bob@example.com', 'pass phrase');
      final other = SyncClient(url);
      await other.signIn('bob@example.com', secret.authKey, 'Other');
      await other.deleteAccount(secret.authKey);
      await sync.syncNow();
      expect(sync.status, SyncStatus.expired);
      expect(sync.email, 'bob@example.com');
      await sync.signOut();
      other.close();
    });

    test('a new password keeps everything readable, and signs the other devices out', () async {
      if (server == null) return markTestSkipped('no sync server');
      final other = await _OtherDevice.create(url, 'hal@example.com', 'correct horse');
      const playlist = Playlist(id: 'm1', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u');
      await other.put([
        await other.item('playlist/m1', {'at': _ago(Duration.zero), 'data': playlist.toJson()}),
      ]);
      final sync = SyncService.instance;
      await sync.signIn(server: url, email: 'hal@example.com', password: 'correct horse');
      await expectLater(
        sync.changePassword(current: 'wrong', password: 'new pass phrase'),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.credentials)),
      );
      await sync.changePassword(current: 'correct horse', password: 'new pass phrase');
      await expectLater(
        other.client.items(0),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.signedOut)),
      );
      await sync.syncNow();
      expect(sync.status, SyncStatus.synced, reason: 'not this device');

      // The other device signs in with the new password, and what it reads is the same
      final secret = await _password('hal@example.com', 'new pass phrase');
      final again = SyncClient(url);
      final (:at, :keys) = await again.signIn('hal@example.com', secret.authKey, 'Other');
      expect((await SyncKeys.unwrap(secret.wrapKey, keys)).toJson(), other.keys.toJson());
      expect(at.rev, greaterThan(0));
      final old = await _password('hal@example.com', 'correct horse');
      await expectLater(
        SyncClient(url).signIn('hal@example.com', old.authKey, 'Other'),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.credentials)),
      );
      await sync.signOut();
      again.close();
      other.close();
    });

    test('the recovery key sets a new password for a forgotten one, and can be replaced', () async {
      if (server == null) return markTestSkipped('no sync server');
      const playlist = Playlist(id: 'm1', name: 'Free', type: PlaylistType.m3u, url: 'http://lists.test/free.m3u');
      await PlaylistStore.instance.add(playlist);
      final sync = SyncService.instance;
      final recoveryKey = await sync.createAccount(server: url, email: 'ivy@example.com', password: 'correct horse');
      await sync.signOut();

      // A new device, and the password is gone
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      PlaylistStore.instance.reset();
      await expectLater(
        sync.recover(
          server: url,
          email: 'ivy@example.com',
          recoveryKey: RecoveryKey.random(),
          password: 'new pass phrase',
        ),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.credentials)),
      );
      await sync.recover(
        server: url,
        email: 'ivy@example.com',
        recoveryKey: RecoveryKey.parse(recoveryKey.text.toLowerCase())!,
        password: 'new pass phrase',
      );
      expect(sync.status, SyncStatus.synced);
      expect((await PlaylistStore.instance.load()).single.name, 'Free', reason: 'nothing lost');
      final secret = await _password('ivy@example.com', 'new pass phrase');
      final other = SyncClient(url);
      await other.signIn('ivy@example.com', secret.authKey, 'Other');

      // A new recovery key: the one before stops working
      await expectLater(
        sync.newRecoveryKey('wrong'),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.credentials)),
      );
      final fresh = await sync.newRecoveryKey('new pass phrase');
      expect(fresh, isNot(recoveryKey));
      Future<String> recoverWith(RecoveryKey key) async {
        final recovery = await SignInKeys.recovery(key);
        final (:at, :keys) = await other.signIn('ivy@example.com', recovery.authKey, 'Other', recovery: true);
        return jsonEncode((await SyncKeys.unwrap(recovery.wrapKey, keys)).toJson());
      }

      await expectLater(
        recoverWith(recoveryKey),
        throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.credentials)),
      );
      expect(await recoverWith(fresh), isNotEmpty);
      await sync.signOut();
      other.close();
    });
  });
}

/// Another device of an account, speaking the protocol directly.
class _OtherDevice {
  _OtherDevice._(this.client, this.keys);

  static Future<_OtherDevice> create(Uri server, String email, String password) async {
    final client = SyncClient(server);
    return _OtherDevice._(client, await createAccountElsewhere(client, email, password, 'Other'));
  }

  final SyncClient client;
  final SyncKeys keys;

  Future<RemoteItem> item(String key, Map<String, dynamic> body) async {
    final id = await keys.itemId(key);
    return RemoteItem(id, await keys.seal(id, {'v': 2, 'key': key, ...body}));
  }

  Future<void> put(List<RemoteItem> items) => client.put(items);

  /// The item [key] as the server has it, opened; null if it has none.
  Future<Map<String, dynamic>?> read(String key) async {
    final id = await keys.itemId(key);
    final found = (await client.items(0)).items.where((i) => i.id == id && i.payload != null).firstOrNull;
    return found == null ? null : await keys.open(id, found.payload!) as Map<String, dynamic>;
  }

  void close() => client.close();
}
