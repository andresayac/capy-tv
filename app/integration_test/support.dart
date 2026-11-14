// Helpers shared by the integration tests.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

/// The provider account from ../.env. A device cannot read that file, so there it comes as
/// defines (--dart-define-from-file=../.env).
Map<String, String> readEnv() {
  final file = File('../.env');
  if (!file.existsSync()) {
    return {
      for (final (key, value) in [
        ('XTREAM_CODE', const String.fromEnvironment('XTREAM_CODE')),
        ('XTREAM_USERNAME', const String.fromEnvironment('XTREAM_USERNAME')),
        ('XTREAM_PASSWORD', const String.fromEnvironment('XTREAM_PASSWORD')),
      ])
        if (value.isNotEmpty) key: value,
    };
  }
  return {
    for (final line in file.readAsLinesSync())
      if (line.contains('=')) line.substring(0, line.indexOf('=')).trim(): line.substring(line.indexOf('=') + 1).trim(),
  };
}

/// Pumps real frames until [ok] holds or [timeout] expires.
Future<bool> waitFor(WidgetTester t, bool Function() ok, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (ok()) return true;
    await t.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return ok();
}

Future<void> settle(WidgetTester t, [Duration d = const Duration(seconds: 2)]) => waitFor(t, () => false, timeout: d);

bool shown(Finder f) => f.evaluate().isNotEmpty;

/// Numbered screenshots of what is under [root], for design review: build/screenshots/ on the
/// desktop, the app's external files folder on Android (tool/test_android.sh pulls them).
class Shots {
  Shots(this.prefix);

  final String prefix;
  final root = GlobalKey();
  var _count = 0;
  var _dir = 'build/screenshots';

  /// Picks the folder; on Android, also clears the shots of earlier runs.
  Future<void> init() async {
    if (!Platform.isAndroid) return;
    _dir = '${(await getExternalStorageDirectory())!.path}/screenshots';
    final old = Directory(_dir);
    if (old.existsSync()) {
      for (final f in old.listSync().whereType<File>().where((f) => f.path.contains('$prefix-'))) {
        f.deleteSync();
      }
    }
  }

  /// Whether shots showing a real account (its panel's address, its user) are taken too: these
  /// are shared for design review, and stay on an Android device. --dart-define=PRIVATE_SHOTS=true
  static const takePrivate = bool.fromEnvironment('PRIVATE_SHOTS');

  /// [private]: it shows the real account, and is taken only with [takePrivate].
  Future<void> take(WidgetTester t, String name, {bool private = false}) async {
    if (private && !takePrivate) return;
    await settle(t, const Duration(milliseconds: 1500)); // let images fade in
    final boundary = root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    _count++;
    File('$_dir/$prefix-${_count.toString().padLeft(2, '0')}-$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  }
}
