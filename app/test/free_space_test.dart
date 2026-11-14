// The room left on a disk, asked of the system the tests run on (Windows through its API, Linux
// and macOS through df).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/free_space.dart';

void main() {
  test('the room left on the disk a folder is on is known', () async {
    final free = await freeBytes(Directory.systemTemp.path);
    expect(free, isNotNull);
    expect(free!, greaterThan(0));
  });

  test('a folder that is not there says nothing rather than throw', () async {
    final gone =
        '${Directory.systemTemp.path}${Platform.pathSeparator}capy-none-${DateTime.now().microsecondsSinceEpoch}';
    expect(await freeBytes(gone), anyOf(isNull, greaterThan(0)));
  });
}
