// A big list read an item at a time, from pieces of any size, as whole decoding would read it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/json_items.dart';

List<Map<String, dynamic>> read(String json, {int piece = 1 << 20}) {
  final bytes = utf8.encode(json);
  return jsonItems([
    for (var i = 0; i < bytes.length; i += piece) Uint8List.sublistView(bytes, i, (i + piece).clamp(0, bytes.length)),
  ]).toList();
}

void main() {
  const tricky = [
    {'name': 'Braces } and { in a "quoted" name \\ with a backslash', 'num': 1},
    {
      'nested': {
        'list': [
          1,
          {'deep': '}]'},
        ],
        'empty': {},
      },
      'ñ': 'café 🎬 한국',
    },
    {'last': null},
  ];

  test('every item, whatever size the pieces come in', () {
    final json = jsonEncode(tricky);
    for (final piece in [1, 2, 3, 5, 7, 64, 1 << 20]) {
      expect(read(json, piece: piece), tricky, reason: 'pieces of $piece bytes');
    }
  });

  test('the values of an object, as some panels send the list', () {
    expect(read(jsonEncode({'0': tricky[0], '1': tricky[1]}), piece: 3), [tricky[0], tricky[1]]);
  });

  test('what is not an object is skipped', () {
    expect(read('[1, "a{", [2, {"x": 1}], null, {"y": 2}, true]'), [
      {'y': 2},
    ]);
  });

  test('a BOM and spaces around are fine', () {
    expect(read('﻿ \n [ {"a": 1} ] \r\n', piece: 2), [
      {'a': 1},
    ]);
  });

  test('nothing comes of an empty list or a bare value', () {
    for (final json in ['[]', '{}', 'null', ' 0 ', '"text"']) {
      expect(read(json), isEmpty, reason: json);
    }
  });

  test('a long answer that is no list is given up on, not read whole', () {
    var read = 0;
    Iterable<Uint8List> pieces() sync* {
      for (; read < 1000; read++) {
        yield Uint8List.fromList(utf8.encode('<br />${' ' * 65530}'));
      }
    }

    expect(() => jsonItems(pieces()).toList(), throwsFormatException);
    expect(read, lessThan(10), reason: 'tens of MB of it would not fit in a TV stick');
  });

  test('an item that is no JSON is skipped, and the rest are read', () {
    // A tab left unescaped in one title, as some panels send it
    expect(read('[{"a": 1}, {"name": "bad\ttab"}, {"b": 2}]', piece: 3), [
      {'a': 1},
      {'b': 2},
    ]);
  });

  test('a PHP warning before the list is skipped; a web page is still no list', () {
    const warning = '<br />\n<b>Warning</b>:  Undefined index: x in <b>/a.php</b> on line <b>3</b><br />\n';
    expect(read('$warning[{"a": 1}]', piece: 5), [
      {'a': 1},
    ]);
    expect(read('PHP Notice: something\n{"0": {"a": 1}}'), [
      {'a': 1},
    ]);
    expect(() => read('<!DOCTYPE html><html>[{"a": 1}]</html>'), throwsFormatException);
    expect(afterPhpNotice('$warning{"user_info": {}}'), warning.length);
    expect(afterPhpNotice('<html>{}</html>'), isNull);
  });

  test('what is not JSON, or is cut short, is an error', () {
    for (final json in [
      '',
      '   ',
      '<html>Error</html>',
      '[{"a": 1}',
      '[{"a": 1},',
      '[{"a": ',
      '[{"a": 1}] x',
      '[{"a": 1}}',
      '[{"a" 1}]',
      '[{"a" 1}, {"b" 2}]',
    ]) {
      expect(() => read(json, piece: 2), throwsFormatException, reason: json);
    }
  });
}
