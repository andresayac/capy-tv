// Every text in the translations is used somewhere: by the app, by the TV's app (which builds
// its strings from the same files), by the pages they serve, or by the sync server's copy of the
// phone's page (its texts for while the device has not answered, named in companion_test.go). One
// left behind goes stale unseen.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every translation key is used by the app, the TV or their pages', () {
    final keys = (jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>).keys.where(
      (k) => !k.startsWith('@'),
    );
    final source = StringBuffer();
    for (final dir in ['lib', 'assets', '../tizen/src', '../tizen/scripts', '../server/internal/syncserver']) {
      if (!Directory(dir).existsSync()) continue;
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        final p = f.path.replaceAll('\\', '/');
        if (p.contains('/l10n/') || p.contains('/gen/') || p.contains('node_modules')) continue;
        if (RegExp(r'\.(dart|ts|tsx|html|js|mjs|go)$').hasMatch(p)) source.write(f.readAsStringSync());
      }
    }
    final all = source.toString();
    expect([
      for (final k in keys)
        if (!RegExp('\\b$k\\b').hasMatch(all)) k,
    ], isEmpty);
  });
}
