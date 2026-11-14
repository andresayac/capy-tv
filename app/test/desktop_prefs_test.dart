// The preferences file of Windows and Linux: what a power cut can leave of it must not cost the
// lists, nor stop the app from starting.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/desktop_prefs.dart';

void main() {
  late Directory dir;
  late File file;

  AtomicPrefsStore store() => AtomicPrefsStore(directory: () async => dir);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('prefs');
    file = File('${dir.path}/shared_preferences.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('reads and writes the file as the plugin left it, lists included', () async {
    file.writeAsStringSync(
      jsonEncode({
        'flutter.name': 'Ana',
        'flutter.tags': ['a', 'b'],
        'flutter.n': 3,
      }),
    );
    final s = store();
    expect((await s.getAll())['flutter.tags'], ['a', 'b']);
    expect(await s.setValue('String', 'flutter.city', 'Quito'), isTrue);
    expect(jsonDecode(file.readAsStringSync()), containsPair('flutter.city', 'Quito'));
    expect(jsonDecode(file.readAsStringSync()), containsPair('flutter.n', 3));
    expect(File('${file.path}.tmp').existsSync(), isFalse, reason: 'renamed into place');
  });

  test('writes in the order they were asked for', () async {
    final s = store();
    await Future.wait([for (var i = 0; i < 20; i++) s.setValue('Int', 'flutter.n', i)]);
    expect(jsonDecode(file.readAsStringSync()), {'flutter.n': 19});
  });

  for (final (what, damage) in <(String, void Function())>[
    ('cut short', () => file.writeAsStringSync('{"flutter.name": "An')),
    ('empty', () => file.writeAsStringSync('')),
    ('full of zeros', () => file.writeAsBytesSync(List.filled(64, 0))),
  ]) {
    test('a file $what comes back from the copy of the last start', () async {
      file.writeAsStringSync(jsonEncode({'flutter.name': 'Ana'}));
      await store().getAll(); // a good start: the copy is made
      damage();
      expect(await store().getAll(), {'flutter.name': 'Ana'});
      expect(File('${file.path}.corrupt').existsSync(), isTrue, reason: 'kept, not thrown away');
    });

    test('a file $what and no copy starts empty rather than not at all', () async {
      damage();
      expect(await store().getAll(), isEmpty);
    });
  }
}
