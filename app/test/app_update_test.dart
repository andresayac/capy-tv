// Updates from the sync server: which release a device takes, and its download.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/sync/app_update.dart';
import 'package:iptv_player/sync/sync_client.dart';

Map<String, dynamic> _file(String name) => {'name': name, 'size': 10, 'sha256': 'ab'};

void main() {
  final server = Uri.parse('https://sync.example/');

  group('which release', () {
    final release = <String, dynamic>{
      'version': '0.2.0',
      'build': 412,
      'notes': 'Pause live',
      'files': {'arm64-v8a': _file('CapyTV-64bit.apk'), 'armeabi-v7a': _file('CapyTV-32bit.apk')},
    };

    test("this processor's file, of a newer build", () {
      final r = AppRelease.pick(release, installed: 400, abi: 'armeabi-v7a')!;
      expect(
        (r.version, r.build, r.abi, r.name, r.size, r.notes),
        ('0.2.0', 412, 'armeabi-v7a', 'CapyTV-32bit.apk', 10, 'Pause live'),
      );
    });

    test('none of the same build or older, or without a server answer', () {
      expect(AppRelease.pick(release, installed: 412, abi: 'arm64-v8a'), isNull);
      expect(AppRelease.pick(release, installed: 500, abi: 'arm64-v8a'), isNull);
      expect(AppRelease.pick(null, installed: 1, abi: 'arm64-v8a'), isNull);
    });

    test('the one for all, for a processor without its own; else none', () {
      final universal = {
        ...release,
        'files': {'universal': _file('CapyTV.apk')},
      };
      expect(AppRelease.pick(universal, installed: 1, abi: 'x86_64')!.name, 'CapyTV.apk');
      expect(AppRelease.pick(release, installed: 1, abi: 'x86_64'), isNull);
    });

    test('Windows takes its installer, and never the APK for all', () {
      final both = {
        ...release,
        'files': {'universal': _file('CapyTV.apk'), 'windows-x64': _file('CapyTV-Setup.exe')},
      };
      expect(AppRelease.pick(both, installed: 1, abi: 'windows-x64')!.name, 'CapyTV-Setup.exe');
      final android = {
        ...release,
        'files': {'universal': _file('CapyTV.apk')},
      };
      expect(AppRelease.pick(android, installed: 1, abi: 'windows-x64'), isNull);
    });

    test('an answer of another shape is no update', () {
      expect(AppRelease.pick({'build': 9, 'files': 'x'}, installed: 1, abi: 'arm64-v8a'), isNull);
      expect(
        AppRelease.pick(
          {
            'build': 9,
            'files': {
              'arm64-v8a': {'name': 'a.apk'},
            },
          },
          installed: 1,
          abi: 'arm64-v8a',
        ),
        isNull,
      );
    });
  });

  test('the release the server has, or none', () async {
    SyncClient with_(int status, Object body) => SyncClient(
      server,
      token: 't',
      client: MockClient((req) async {
        expect(req.url.path, '/v1/app');
        expect(req.headers['authorization'], 'Bearer t');
        return http.Response(jsonEncode(body), status);
      }),
    );
    expect((await with_(200, {'build': 3}).release())!['build'], 3);
    expect(await with_(404, {'error': 'no_app'}).release(), isNull);
    expect(() => with_(401, {'error': 'auth'}).release(), throwsA(isA<SyncException>()));
  });

  group('the download', () {
    const apk = 'the whole APK file';
    late Directory dir;
    late File file;
    final asked = <String?>[];

    // What the server says of its release as the download starts (see AppUpdate.download)
    Map<String, Object>? manifest;

    // A server that answers ranges as the sync server does, unless [ranges] is off
    SyncClient serving({bool ranges = true, int status = 200}) => SyncClient(
      server,
      token: 't',
      client: MockClient((req) async {
        if (req.url.path == '/v1/app') {
          return manifest == null ? http.Response('{"error":"no_app"}', 404) : http.Response(jsonEncode(manifest), 200);
        }
        expect(req.url.path, '/v1/app/CapyTV-64bit.apk');
        expect(req.headers['authorization'], 'Bearer t');
        final range = req.headers['range'];
        asked.add(range);
        if (status != 200) return http.Response('{}', status);
        if (range != null && ranges) {
          final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
          return http.Response(apk.substring(from), 206);
        }
        return http.Response(apk, 200);
      }),
    );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('update');
      file = File('${dir.path}/update.apk');
      asked.clear();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('whole, saying how far it is', () async {
      final seen = <int>[];
      await serving().download('CapyTV-64bit.apk', file, progress: seen.add);
      expect(file.readAsStringSync(), apk);
      expect(asked, [null]);
      expect(seen.last, apk.length);
    });

    test('a cut one goes on from where it was', () async {
      file.writeAsStringSync(apk.substring(0, 6));
      await serving().download('CapyTV-64bit.apk', file);
      expect(asked, ['bytes=6-']);
      expect(file.readAsStringSync(), apk);
    });

    test('from the start, when the server sends it all again', () async {
      file.writeAsStringSync(apk.substring(0, 6));
      await serving(ranges: false).download('CapyTV-64bit.apk', file);
      expect(file.readAsStringSync(), apk);
    });

    test('signed out, or no such file', () async {
      Future<SyncProblem?> problem(int status) async {
        try {
          await serving(status: status).download('CapyTV-64bit.apk', file);
          return null;
        } on SyncException catch (e) {
          return e.problem;
        }
      }

      expect(await problem(401), SyncProblem.signedOut);
      expect(await problem(404), SyncProblem.notFound);
      expect(await problem(500), SyncProblem.server);
    });

    test('sha256Of gives the digest of the file', () async {
      file.writeAsStringSync('abc');
      expect(await AppUpdate.sha256Of(file), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    group('an update', () {
      late Directory updates;
      late String digest;
      final place = AppUpdate.place;

      AppRelease release({int? size, String? sha256}) => AppRelease(
        version: '1.2',
        build: 42,
        abi: 'arm64-v8a',
        name: 'CapyTV-64bit.apk',
        size: size ?? apk.length,
        sha256: sha256 ?? digest,
      );

      /// The server describing its file with [size] and [sha256] (by default, as it is).
      void describes({int? size, String? sha256}) => manifest = {
        'version': '1.2',
        'build': 42,
        'files': {
          'arm64-v8a': {'name': 'CapyTV-64bit.apk', 'size': size ?? apk.length, 'sha256': sha256 ?? digest},
        },
      };

      setUp(() async {
        updates = Directory('${dir.path}/updates');
        AppUpdate.place = () async => updates;
        file.writeAsStringSync(apk);
        digest = await AppUpdate.sha256Of(file);
        file.deleteSync();
        describes();
      });
      tearDown(() => manifest = null);
      tearDown(() => AppUpdate.place = place);

      test('is checked against the SHA-256 and size the server gives, and kept when it is right', () async {
        final got = await AppUpdate.download(serving(), release());
        expect(got.readAsStringSync(), apk);
        expect(got.path, endsWith('42-arm64-v8a.apk'));
      });

      test('that is not what the server has is thrown away, by its digest or its size', () async {
        for (final wrong in [() => describes(sha256: 'f' * 64), () => describes(size: apk.length + 1)]) {
          wrong();
          await expectLater(AppUpdate.download(serving(), release()), throwsA(isA<UpdateDamaged>()));
          expect(updates.listSync(), isEmpty, reason: 'nothing left to install');
        }
      });

      test('offered while the server still had half of it, it is measured against the whole one', () async {
        // Checked as the installer was being copied there: its size and digest as far as it had come
        final early = release(size: 6, sha256: '0' * 64);
        final got = await AppUpdate.download(serving(), early);
        expect(got.readAsStringSync(), apk);
        expect(AppUpdate.available.value?.size, apk.length, reason: 'what is offered is what the server has now');
      });

      test('gone from the server meanwhile, it is not downloaded', () async {
        manifest = null;
        await expectLater(
          AppUpdate.download(serving(), release()),
          throwsA(isA<SyncException>().having((e) => e.problem, 'problem', SyncProblem.notFound)),
        );
      });

      test('one already whole is not brought again; another build\'s download goes', () async {
        updates.createSync(recursive: true);
        File('${updates.path}/41-arm64-v8a.apk').writeAsStringSync('old');
        File('${updates.path}/42-arm64-v8a.apk').writeAsStringSync(apk);
        final got = await AppUpdate.download(serving(), release());
        expect(asked, isEmpty, reason: 'nothing downloaded');
        expect(got.readAsStringSync(), apk);
        expect(updates.listSync().map((f) => f.uri.pathSegments.last), ['42-arm64-v8a.apk']);
      });
    });
  });
}
