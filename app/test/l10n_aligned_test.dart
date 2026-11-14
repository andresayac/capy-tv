// The translations stay in step: Spanish has every text English has, with the same placeholders
// (a missing one falls back to English unnoticed, here and on the TV); and the phone's page takes
// the same texts from the app as from the TV, whose tables are kept by hand.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String language) =>
    jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync()) as Map<String, dynamic>;

/// The arguments a text takes: `{name}`, or `{name, plural, …}` and `{name, select, …}`. A
/// select's cases are `{text}` too, so a plain `{word}` counts only when it is a declared one.
Set<String> _arguments(String text, Set<String> declared) => {
  for (final m in RegExp(r'\{(\w+)(\}|,\s*(plural|select)\b)').allMatches(text))
    if (m[2] != '}' || declared.contains(m[1])) m[1]!,
};

void main() {
  test('Spanish has every English text, with the same placeholders, and no more', () {
    final en = _arb('en'), es = _arb('es');
    final keys = en.keys.where((k) => !k.startsWith('@')).toSet();
    expect(es.keys.where((k) => !k.startsWith('@')).toSet().difference(keys), isEmpty, reason: 'in Spanish only');
    expect(keys.difference(es.keys.toSet()), isEmpty, reason: 'missing in Spanish');
    final differ = <String, (Set<String>, Set<String>)>{};
    for (final k in keys) {
      final declared = ((en['@$k'] as Map<String, dynamic>?)?['placeholders'] as Map<String, dynamic>? ?? {}).keys
          .toSet();
      final inEn = _arguments(en[k] as String, declared), inEs = _arguments(es[k] as String, declared);
      if (inEn.length != declared.length || inEs.length != declared.length || !inEs.containsAll(declared)) {
        differ[k] = (inEn, inEs);
      }
    }
    expect(differ, isEmpty);
  });

  test("the phone's page takes the same texts from the app as from the TV", () {
    final app = {
      for (final m in RegExp(
        r"'(\w+)': l\.(\w+)",
      ).allMatches(File('lib/remote/companion_strings.dart').readAsStringSync()))
        if (m[1] != 'lang') m[1]!: m[2]!, // the language, not a text
    };
    final tv = {
      for (final m in RegExp(
        r"^\s*(\w+): \['(\w+)'",
        multiLine: true,
      ).allMatches(File('../tizen/src/remote/strings.ts').readAsStringSync()))
        m[1]!: m[2]!,
    };
    expect(app, isNotEmpty);
    // The TV reaches the phone through the server, not the Wi-Fi: these say so
    expect(tv, {...app, 'lostConnection': 'webRelayLostConnection', 'privacy': 'webRelayPrivacy'});
  });
}
