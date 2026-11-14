// The companion features: playlists in secure storage, backups, the local server a phone talks
// to, and the phone acting as a remote.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/backup.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/remote/companion_server.dart';
import 'package:iptv_player/remote/movie_night.dart';
import 'package:iptv_player/remote/remote_input.dart';
import 'package:iptv_player/sync/sync_client.dart';
import 'package:iptv_player/sync/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_server.dart';

const _xtream = Playlist(
  id: 'a',
  name: 'Home',
  type: PlaylistType.xtream,
  url: 'http://tv.example:8080',
  username: 'me',
  password: 'secret',
);

Future<void> _fresh([Map<String, Object> prefs = const {}, Map<String, String> secrets = const {}]) async {
  SharedPreferences.setMockInitialValues(prefs);
  FlutterSecureStorage.setMockInitialValues({...secrets}); // the mock writes into this map
  PlaylistStore.instance.reset();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('playlists', () {
    test('passwords live in secure storage, not in the preferences', () async {
      await _fresh();
      await PlaylistStore.instance.add(_xtream);
      final prefs = (await SharedPreferences.getInstance()).getString('playlists')!;
      expect(prefs, isNot(contains('secret')));
      expect(await const FlutterSecureStorage().read(key: 'playlist.a.password'), 'secret');
      PlaylistStore.instance.reset();
      expect((await PlaylistStore.instance.load()).single.password, 'secret');
    });

    test('passwords saved by earlier versions move to secure storage', () async {
      await _fresh({
        'playlists': jsonEncode([_xtream.toJson()]),
      });
      expect((await PlaylistStore.instance.load()).single.password, 'secret');
      expect((await SharedPreferences.getInstance()).getString('playlists'), isNot(contains('secret')));
      expect(await const FlutterSecureStorage().read(key: 'playlist.a.password'), 'secret');
    });

    test('removing a playlist forgets its password', () async {
      await _fresh();
      await PlaylistStore.instance.add(_xtream);
      await PlaylistStore.instance.remove(_xtream);
      expect(await const FlutterSecureStorage().read(key: 'playlist.a.password'), isNull);
    });
  });

  group('backups', () {
    HistoryEntry watched(String id, int minute) => HistoryEntry(
      ref: MediaRef(kind: MediaKind.movie, id: id, title: id),
      position: Duration(minutes: minute),
      duration: const Duration(minutes: 90),
      updated: DateTime(2026, 11, 5, 12, minute),
    );

    test('an import merges: same account updated, history keeps the latest progress', () async {
      await _fresh();
      SharedPreferences.setMockInitialValues({
        'library.a': jsonEncode({
          'favorites': [],
          'history': [watched('m1', 10).toJson()],
        }),
        'audioLanguage': 'eng',
        'decoder': 'software',
      });
      await PlaylistStore.instance.add(_xtream);
      final settings = await AppSettings.load();

      final incoming = {
        'format': Backup.format,
        'version': 1,
        'playlists': [
          _xtream.copyWith(id: 'other-id', password: 'new-secret').toJson(),
          const Playlist(id: 'b', name: 'M3U', type: PlaylistType.m3u, url: 'http://x/list.m3u').toJson(),
        ],
        'libraries': {
          'other-id': {
            'favorites': [const MediaRef(kind: MediaKind.live, id: 'c1', title: 'News').toJson()],
            'history': [watched('m1', 40).toJson(), watched('m2', 5).toJson()],
          },
        },
        'settings': {'audioLanguage': 'spa', 'decoder': 'hardware'},
      };
      final result = await Backup.import(incoming, settings: settings);

      expect((result.added, result.updated, result.libraries), (1, 1, 1));
      final list = PlaylistStore.instance.playlists!;
      expect(list.map((p) => p.id), ['a', 'b'], reason: 'the same account is not added twice');
      expect(list.first.password, 'new-secret');
      final lib = await Library.load('a', mainProfileId);
      expect(lib.favorites(MediaKind.live).single.id, 'c1');
      expect(lib.entry(const MediaRef(kind: MediaKind.movie, id: 'm1', title: 'm1'))!.position.inMinutes, 40);
      expect(lib.history.map((h) => h.ref.id), ['m1', 'm2']);
      expect(settings.audioLanguage, 'spa');
      expect(settings.decoder, 'software', reason: 'how a device decodes video is its own business');
    });

    test('an export has everything another device needs', () async {
      await _fresh();
      await PlaylistStore.instance.add(_xtream);
      final library = await Library.load('a', mainProfileId);
      await library.toggleFavorite(const MediaRef(kind: MediaKind.live, id: 'c1', title: 'News'));
      final data = await Backup.export();
      expect(Backup.isBackup(data), isTrue);
      expect((data['playlists'] as List).single['password'], 'secret');
      expect((data['libraries'] as Map)['a'], isNotNull);
      expect(Backup.isBackup({'format': 'something else'}), isFalse);
      expect(
        Backup.isBackup({'format': 'iptv-player-backup', 'playlists': []}),
        isTrue,
        reason: 'one made before the rename',
      );
    });
  });

  group('companion server', () {
    final server = CompanionServer.instance;
    late HttpClient client;
    late Uri base;

    setUpAll(() {
      HttpOverrides.global = null; // the test binding blocks real HTTP otherwise
      client = HttpClient();
    });

    setUp(() async {
      await _fresh();
      server.verify = (p) async {
        if (p.password == 'wrong') throw const SourceException(SourceError.unauthorized);
      };
      await server.hold(bind: InternetAddress.loopbackIPv4, strings: {'tabAdd': 'Add list'});
      base = server.url!;
    });

    tearDown(() => server.stop());

    /// What the page sends: sealed with the key from the QR.
    Future<Map<String, String>> sealed(String path, Object body) async => {
      'sealed': await server.seal.seal(path, body),
    };

    Future<(int, dynamic)> call(String method, String path, {Object? body, bool token = true}) async {
      final uri = base.replace(path: path, queryParameters: token ? {'t': server.token} : {});
      final req = await client.openUrl(method, uri);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      return (res.statusCode, res.headers.contentType?.mimeType == 'application/json' ? jsonDecode(text) : text);
    }

    test('nothing without the session code from the QR, and an address that guesses is locked out', () async {
      expect((await call('GET', '/api/info', token: false)).$1, 403);
      for (var i = 0; i < 30; i++) {
        await call('GET', '/api/info', token: false); // no code at all: no guess
      }
      expect((await call('GET', '/api/info')).$1, 200, reason: 'a page opened without its link guessed nothing');
      Future<int> guess() async {
        final req = await client.openUrl('GET', base.replace(path: '/api/info', queryParameters: {'t': 'wrong'}));
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      }

      for (var i = 0; i < 20; i++) {
        expect(await guess(), 403);
      }
      expect(
        (await call('GET', '/api/info')).$1,
        429,
        reason: 'that address, not even with the right code once locked',
      );
    });

    test('the code for voting opens the page and the vote, and nothing else', () async {
      final guest = server.votingLink!;
      expect(guest.fragment, 'night&guest', reason: 'and no key');
      Future<(int, dynamic)> ask(String method, String path) async {
        final req = await client.openUrl(method, base.replace(path: path, queryParameters: guest.queryParameters));
        final res = await req.close();
        final text = await utf8.decodeStream(res);
        return (res.statusCode, res.headers.contentType?.mimeType == 'application/json' ? jsonDecode(text) : text);
      }

      expect((await ask('GET', '/')).$1, 200);
      expect((await ask('GET', '/api/night')).$1, 200);
      final (status, info) = await ask('GET', '/api/info');
      expect(status, 200);
      expect((info as Map).keys.toSet(), {'device', 'night'}, reason: 'no account nor playlists');
      for (final (method, path) in [
        ('GET', '/api/backup'),
        ('POST', '/api/backup'),
        ('POST', '/api/playlists'),
        ('POST', '/api/sync'),
        ('GET', '/ws'),
      ]) {
        expect((await ask(method, path)).$1, 403, reason: '$method $path');
      }
      for (var i = 0; i < 25; i++) {
        await ask('GET', '/api/backup');
      }
      expect((await call('GET', '/api/info')).$1, 200, reason: 'a guest looking around locks nobody out');
    });

    test('a backup with no password keeps the one here', () async {
      await PlaylistStore.instance.add(
        Playlist.create(type: PlaylistType.xtream, url: 'http://k.test', username: 'keep', password: 'good', name: 'K'),
      );
      final saved = (await PlaylistStore.instance.load()).firstWhere((p) => p.username == 'keep');
      await Backup.import({
        'format': Backup.format,
        'playlists': [
          {...saved.toJson(), 'password': ''},
        ],
      });
      final now = (await PlaylistStore.instance.load()).firstWhere((p) => p.username == 'keep');
      expect(now.password, 'good');
      await PlaylistStore.instance.remove(now);
    });

    test('a backup from a newer version, or a damaged one, changes nothing here', () async {
      final store = PlaylistStore.instance;
      final before = (await store.load()).length;
      final one = Playlist.create(
        type: PlaylistType.xtream,
        url: 'http://n.test',
        username: 'n',
        password: 'p',
        name: 'N',
      );
      await expectLater(
        Backup.import({
          'format': Backup.format,
          'version': Backup.version + 1,
          'playlists': [one.toJson()],
        }),
        throwsA(isA<BackupTooNew>()),
      );
      await expectLater(
        Backup.import({
          'format': Backup.format,
          'playlists': [one.toJson()],
          'libraries': {
            one.id: {
              'favorites': 'not a list', // damaged
            },
          },
        }),
        throwsFormatException,
      );
      expect((await store.load()).length, before, reason: 'not the playlist either: read whole first');
    });

    test('a combined playlist in a backup joins the accounts as this device has them, once', () async {
      final store = PlaylistStore.instance;
      final here = [
        for (final u in ['ca', 'cb'])
          Playlist.create(type: PlaylistType.xtream, url: 'http://$u.test', username: u, password: 'p', name: u),
      ];
      for (final p in here) {
        await store.add(p);
      }
      final backup = {
        'format': Backup.format,
        'playlists': [
          {...here[0].toJson(), 'id': 'other-a'},
          {...here[1].toJson(), 'id': 'other-b'},
          Playlist.combine(name: 'Both', members: ['other-a', 'other-b']).toJson(),
        ],
      };
      await Backup.import(backup);
      await Backup.import(backup);
      final combined = (await store.load()).where((p) => p.type == PlaylistType.combined).toList();
      expect(combined, hasLength(1), reason: 'not twice');
      expect(combined.single.members, [for (final p in here) p.id]);
      for (final p in [...here, ...combined]) {
        await store.remove(p);
      }
    });

    test("movie night: the titles, and each phone's yes or no, counted once", () async {
      expect((await call('GET', '/api/night')).$2, {'open': false});
      expect((await call('POST', '/api/night/vote', body: {'voter': 'a', 'id': '1', 'yes': true})).$1, 409);

      final night = MovieNight(const [
        NightTitle(id: '1', title: 'Heat', year: 1995, rating: 8.3),
        NightTitle(id: '2', title: 'Ronin', year: 1998, rating: 7.2),
      ]);
      server.night = night;
      final (status, info) = await call('GET', '/api/night');
      expect(status, 200);
      expect([for (final t in (info as Map)['titles'] as List) t['title']], ['Heat', 'Ronin']);
      expect(((await call('GET', '/api/info')).$2 as Map)['night'], isTrue, reason: 'the page shows its tab');

      for (final (voter, id, yes) in [
        ('ana', '1', true),
        ('bea', '1', false),
        ('ana', '2', true),
        ('bea', '2', true),
      ]) {
        expect((await call('POST', '/api/night/vote', body: {'voter': voter, 'id': id, 'yes': yes})).$1, 200);
      }
      await call('POST', '/api/night/vote', body: {'voter': 'bea', 'id': '2', 'yes': true}); // again: once
      expect((night.yes('2'), night.no('1'), night.voters), (2, 1, 2));
      expect(night.winner?.title, 'Ronin');
      expect((await call('POST', '/api/night/vote', body: {'voter': 'ana', 'id': '9', 'yes': true})).$1, 400);
      expect(
        (await call('POST', '/api/night/vote', body: {'voter': 'eve', 'id': '1', 'yes': true}, token: false)).$1,
        403,
      );
      server.night = null;
    });

    test('movie night: at a tie, the best rated wins; nothing before a vote', () {
      final night = MovieNight(const [
        NightTitle(id: '1', title: 'Ronin', rating: 7.2),
        NightTitle(id: '2', title: 'Heat', rating: 8.3),
      ]);
      expect(night.winner, isNull);
      night.vote('ana', '1', yes: true);
      night.vote('ana', '2', yes: true);
      expect(night.winner?.title, 'Heat');
      night.vote('ana', '2', yes: false); // a change of mind
      expect(night.winner?.title, 'Ronin');
      expect(night.vote('', '1', yes: true), isFalse);
    });

    test('the page comes with its texts and the device name', () async {
      final (status, html) = await call('GET', '/');
      expect(status, 200);
      expect(html, contains('"tabAdd":"Add list"'));
      expect(html, isNot(contains('/*STRINGS*/')));
      expect(html, contains('const Seal'), reason: 'with its sealing code');
      expect(html, isNot(contains(server.seal.text)), reason: 'but never the key: only the QR carries it');
      expect(server.link('add')!.fragment, 'add&k=${server.seal.text}');
    });

    test('a playlist typed on the phone is checked and saved', () async {
      final received = server.events.first;
      final (status, body) = await call(
        'POST',
        '/api/playlists',
        body: await sealed('/api/playlists', {
          'type': 'xtream',
          'url': ' http://tv.example:8080 ',
          'username': 'me',
          'password': 'secret',
        }),
      );
      expect(status, 200);
      expect(body['name'], 'tv.example');
      expect(((await received) as PlaylistReceived).name, 'tv.example');
      expect(PlaylistStore.instance.playlists!.single.url, 'http://tv.example:8080');

      final (wrong, error) = await call(
        'POST',
        '/api/playlists',
        body: await sealed('/api/playlists', {
          'type': 'xtream',
          'url': 'http://x',
          'username': 'me',
          'password': 'wrong',
        }),
      );
      expect((wrong, error['error']), (422, 'unauthorized'));
      final missing = await sealed('/api/playlists', {'type': 'xtream', 'url': 'http://x'});
      expect((await call('POST', '/api/playlists', body: missing)).$1, 400);
    });

    test("a provider's link whose panel API is closed is saved as the M3U list it also is", () async {
      // The panel's API answers nothing useful; the link itself, as a list, works
      server.verify = (p) async {
        if (p.type == PlaylistType.xtream) throw const SourceException(SourceError.badResponse);
      };
      const link = 'http://tv.example:8080/get.php?username=me&password=secret&type=m3u_plus';
      final (status, _) = await call(
        'POST',
        '/api/playlists',
        body: await sealed('/api/playlists', {'type': 'm3u', 'url': link}),
      );
      expect(status, 200);
      final saved = PlaylistStore.instance.playlists!.single;
      expect((saved.type, saved.url), (PlaylistType.m3u, link));

      // The panel said the account is no good: that is what the phone hears, no list tried
      server.verify = (p) async => throw const SourceException(SourceError.unauthorized);
      final (refused, error) = await call(
        'POST',
        '/api/playlists',
        body: await sealed('/api/playlists', {'type': 'm3u', 'url': '$link&x=1'}),
      );
      expect((refused, error['error']), (422, 'unauthorized'));
    });

    test('nothing private is taken in clear, nor sealed for another path or with another key', () async {
      const plain = {'type': 'xtream', 'url': 'http://x', 'username': 'me', 'password': 'secret'};
      for (final body in [
        plain,
        await sealed('/api/backup', plain),
        {'sealed': 'not even base64'},
      ]) {
        final (status, answer) = await call('POST', '/api/playlists', body: body);
        expect((status, answer['error']), (400, 'sealed'));
      }
      expect(PlaylistStore.instance.playlists ?? const [], isEmpty);
    });

    test('backups go both ways, sealed', () async {
      await PlaylistStore.instance.add(_xtream);
      final (status, answer) = await call('GET', '/api/backup');
      expect(status, 200);
      expect(jsonEncode(answer), isNot(contains('secret')), reason: 'no password readable on the network');
      final backup = await server.seal.open('/api/backup', answer['sealed'] as String);
      await _fresh();
      final (imported, result) = await call('POST', '/api/backup', body: await sealed('/api/backup', backup!));
      expect((imported, result['added']), (200, 1));
      expect(PlaylistStore.instance.playlists!.single.password, 'secret');
      expect((await call('POST', '/api/backup', body: await sealed('/api/backup', {'hello': 1}))).$1, 400);
    });

    // Long enough for the sync server to be built from nothing (no Go cache), as on a new machine
    test('a phone signs this device in to the sync account', timeout: const Timeout(Duration(minutes: 5)), () async {
      final (sync, why) = await TestSyncServer.start();
      if (sync == null) return markTestSkipped(why);
      addTearDown(sync.stop);
      SyncService.kdf = (memoryKiB: 1024, passes: 1);
      final phone = SyncClient(sync.url);
      await createAccountElsewhere(phone, 'ana@example.com', 'correct horse', 'Phone');
      phone.close();

      Future<(int, dynamic)> signIn(String password) async => call(
        'POST',
        '/api/sync',
        body: await sealed('/api/sync', {
          'server': sync.url.toString(),
          'email': 'ana@example.com',
          'password': password,
        }),
      );
      final (wrong, error) = await signIn('wrong');
      expect((wrong, error['error']), (422, 'sync_credentials'));
      final event = server.events.firstWhere((e) => e is SyncSignedIn);
      final (status, answer) = await signIn('correct horse');
      expect((status, answer['email']), (200, 'ana@example.com'));
      expect(((await event) as SyncSignedIn).email, 'ana@example.com');
      expect(SyncService.instance.status, SyncStatus.synced);
      final (_, info) = await call('GET', '/api/info');
      expect(info['sync'], {'email': 'ana@example.com', 'server': sync.url.toString(), 'signedIn': true});
      await SyncService.instance.signOut();
    });

    test('a phone connects as a remote and hears what is playing', () async {
      final ws = await WebSocket.connect(
        base.replace(scheme: 'ws', path: '/ws', queryParameters: {'t': server.token}).toString(),
      );
      final messages = ws.map((m) => jsonDecode(m as String) as Map<String, dynamic>).asBroadcastStream();
      expect((await messages.first)['type'], 'hello');
      expect(server.remotes, 1);
      nowPlaying.value = (title: 'News 24', subtitle: null);
      expect((await messages.first)['nowPlaying']['title'], 'News 24');
      nowPlaying.value = null;
      await ws.close();
    });

    test('a phone open as a remote hears that a movie night began and ended', () async {
      final ws = await WebSocket.connect(
        base.replace(scheme: 'ws', path: '/ws', queryParameters: {'t': server.token}).toString(),
      );
      final messages = ws.map((m) => jsonDecode(m as String) as Map<String, dynamic>).asBroadcastStream();
      expect((await messages.first)['type'], 'hello');
      server.night = MovieNight(const [NightTitle(id: '1', title: 'Heat')]);
      expect(await messages.first, {'type': 'night', 'open': true});
      server.night = null;
      expect(await messages.first, {'type': 'night', 'open': false});
      await ws.close();
    });
  });

  group('phone remote', () {
    testWidgets('buttons move the focus and press, text goes into the focused field', (t) async {
      var pressed = '';
      await t.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigator,
          home: Scaffold(
            body: Column(
              children: [
                TextButton(autofocus: true, onPressed: () => pressed = 'first', child: const Text('first')),
                TextButton(onPressed: () => pressed = 'second', child: const Text('second')),
                const TextField(),
              ],
            ),
          ),
        ),
      );
      await t.pump();
      expect(pressRemoteKey('down'), isTrue);
      await t.pump();
      pressRemoteKey('ok');
      await t.pump();
      expect(pressed, 'second');

      pressRemoteKey('down');
      await t.pump();
      typeRemoteText('hello');
      await t.pump();
      expect(find.text('hello'), findsOneWidget);
      expect(pressRemoteKey('volume'), isFalse, reason: 'unknown buttons do nothing');
    });

    testWidgets('text with no field focused becomes a search', (t) async {
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      String? searched;
      void listener() => searched = remoteSearch.text;
      remoteSearch.addListener(listener);
      typeRemoteText('news');
      expect(searched, 'news');
      remoteSearch.removeListener(listener);
    });

    testWidgets('back goes back', (t) async {
      await t.pumpWidget(MaterialApp(navigatorKey: appNavigator, home: const Text('home')));
      appNavigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('page')));
      await t.pumpAndSettle();
      pressRemoteKey('back');
      await t.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
    });

    test('every remote button maps to a key', () {
      expect(remoteKeys.keys, containsAll(['up', 'down', 'left', 'right', 'ok', 'playpause', 'chup', 'chdown']));
      expect(remoteKeys['ok']!.$1, LogicalKeyboardKey.select);
    });
  });
}
