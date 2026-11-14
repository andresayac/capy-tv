// A recording's file is named after its title: a guide that puts the synopsis there, or sends a
// control character, still gives a name the device accepts.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/recordings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;
  setUp(() => Recordings.folderForTests = dir = Directory.systemTemp.createTempSync('recordings'));
  tearDown(() {
    Recordings.folderForTests = null;
    dir.deleteSync(recursive: true);
  });

  test('a very long title, or one with control characters, still makes a file', () async {
    final now = DateTime(2026, 11, 11, 21, 5);
    final long = await Recordings.newFile('Película ${'ñ' * 300}\u0001: fin', now: now);
    final name = long.uri.pathSegments.last;
    expect(utf8.encode(name).length, lessThanOrEqualTo(255));
    expect(name, isNot(contains('\u0001')));
    expect(name, endsWith(' 2026-11-11 21.05.00.ts'));
    long.writeAsStringSync('x');
    expect(long.existsSync(), isTrue);
    expect(
      (await Recordings.newFile('News\u0007 at 9', now: now)).uri.pathSegments.last,
      'News at 9 2026-11-11 21.05.00.ts',
    );
  });

  test('each profile sees the recordings it made, and those from before profiles were noted', () async {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime(2026, 11, 11, 21, 5);
    Future<void> make(String title, String? owner) async =>
        (await Recordings.newFile(title, now: now, owner: owner)).writeAsStringSync('x');
    await make('Mine', 'ana');
    await make('Theirs', 'leo');
    await make('Old', null);
    Future<Set<String>> titles({String? profile}) async => {
      for (final r in await Recordings.list(profile: profile)) r.title,
    };
    expect(await titles(profile: 'ana'), {'Mine', 'Old'});
    expect(await titles(profile: 'leo'), {'Theirs', 'Old'});
    expect(await titles(), {'Mine', 'Theirs', 'Old'}, reason: 'with no profile, the device has all');
  });

  test('a title of nothing a file name may have is named in the app language', () async {
    final now = DateTime(2026, 11, 11, 21, 5);
    expect(
      (await Recordings.newFile(':/*?', now: now, untitled: 'Canal')).uri.pathSegments.last,
      'Canal 2026-11-11 21.05.00.ts',
    );
  });
}
