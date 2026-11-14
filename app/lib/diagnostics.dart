// What the app noted lately, for "Diagnostics" in Settings: when something fails on a relative's
// TV, the version, the device and the last errors, to be read out or pasted in a message. Kept in
// memory only, and with no address in it (an Xtream one carries the account): nothing leaves the
// device but what someone copies.
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'platform.dart';

abstract final class Diagnostics {
  static const _max = 500;
  static final _lines = ListQueue<String>();

  /// The commit the app was built from, when the build says (--dart-define=COMMIT=…).
  static const _commit = String.fromEnvironment('COMMIT');

  /// Notes everything debugPrint says, which is where the app reports what goes wrong, uncaught
  /// errors included. Call once, at startup.
  static void start() {
    final print = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) note(message);
      print(message, wrapWidth: wrapWidth);
    };
  }

  static void note(String line) {
    _lines.addLast('${DateTime.now().toIso8601String().substring(11, 23)}  ${clean(line)}');
    while (_lines.length > _max) {
      _lines.removeFirst();
    }
  }

  /// [text] with only the host of each address in it: no path, query or user, where an account is.
  static String clean(String text) => text.replaceAllMapped(_address, (m) => '${m[1]}${m[2]}/…');
  static final _address = RegExp(r'([a-z][a-z0-9+.-]*://)(?:[^@/\s]*@)?([^/\s?#@]+)[^\s]*', caseSensitive: false);

  /// "0.1.0 (132) · 7a7963b": the version and build, and the commit when known.
  static Future<String> version() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return ['${info.version} (${info.buildNumber})', if (_commit.isNotEmpty) _commit].join(' · ');
    } on Object {
      return _commit.isEmpty ? '?' : _commit;
    }
  }

  /// The report: what the app is and where it runs, [extra] lines, then what was noted, oldest first.
  static Future<String> report({List<String> extra = const []}) async => [
    'Capy TV ${await version()}',
    '$operatingSystem $operatingSystemVersion',
    ...extra,
    DateTime.now().toIso8601String(),
    '',
    ..._lines,
  ].join('\n');

  @visibleForTesting
  static void clear() => _lines.clear();
}
