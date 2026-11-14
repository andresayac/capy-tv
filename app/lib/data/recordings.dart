import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform.dart';

/// A channel recorded from the player: the stream as it came in (mpv's stream-record), not
/// converted, so recording costs next to nothing. One file per recording, named after the channel
/// and when it started.
class Recording {
  const Recording(this.file, this.title, this.at, this.bytes);

  final File file;
  final String title;
  final DateTime at;
  final int bytes;
}

abstract final class Recordings {
  /// Where tests keep theirs, away from the user's.
  @visibleForTesting
  static Directory? folderForTests;

  /// On Android the app's own folder on the device's storage (no permission needed; it goes with
  /// the app); on Windows Videos, as OneDrive often uploads Documents, a film of gigabytes and all;
  /// elsewhere Documents.
  static Future<Directory> folder() async {
    if (folderForTests case final dir?) return dir;
    if (isWindows) {
      if (_videos() case final videos?) return _inCapy(videos);
    }
    if (isAndroid) {
      final base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      return Directory('${base.path}${pathSeparator}Recordings');
    }
    return _inCapy(await getApplicationDocumentsDirectory());
  }

  static Directory _inCapy(Directory base) =>
      Directory('${base.path}${pathSeparator}Capy TV${pathSeparator}Recordings');

  /// The user's Videos folder on Windows, when it is where it usually is. Only asked on Windows:
  /// dart:io's environment throws in a browser.
  static Directory? _videos() {
    final home = Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return null;
    final videos = Directory('$home\\Videos');
    return videos.existsSync() ? videos : null;
  }

  /// Where a version before Videos put them on Windows: still listed, so none is lost.
  static Future<Directory?> _before() async {
    if (folderForTests != null || !isWindows) return null;
    final old = _inCapy(await getApplicationDocumentsDirectory());
    return old.path == (await folder()).path ? null : old;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// A new file for recording [title] now: MPEG-TS, which keeps any codec a channel sends and
  /// takes the jumps in a live stream's times. A title of nothing a file name may have is named
  /// [untitled], in the app's language.
  static Future<File> newFile(String title, {DateTime? now, String untitled = 'Channel', String? owner}) async {
    final dir = await folder()
      ..createSync(recursive: true);
    final t = now ?? DateTime.now();
    var safe = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    // A guide that puts the synopsis in the title: names go to 255 bytes, and the date takes 23
    while (utf8.encode(safe).length > 200) {
      safe = safe.characters.skipLast(1).toString();
    }
    safe = safe.trim();
    final stamp = '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}.${_two(t.minute)}.${_two(t.second)}';
    final file = File('${dir.path}$pathSeparator${safe.isEmpty ? untitled : safe} $stamp.ts');
    if (owner != null) await _own(file, owner);
    return file;
  }

  /// Which profile made each recording, by file name; kept apart from the files, which any player
  /// may open. One not in it (made before this was kept) is every profile's.
  static const _ownersKey = 'recordings.owners';

  static Future<Map<String, String>> _owners() async {
    final raw = (await SharedPreferences.getInstance()).getString(_ownersKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } on Object {
      return {};
    }
  }

  static Future<void> _own(File file, String profile) async {
    final owners = await _owners();
    owners[file.uri.pathSegments.last] = profile;
    await (await SharedPreferences.getInstance()).setString(_ownersKey, jsonEncode(owners));
  }

  static final _name = RegExp(r'^(.*) (\d{4})-(\d\d)-(\d\d) (\d\d)\.(\d\d)\.(\d\d)\.ts$');

  /// The recordings there are, the latest first: with [profile], those it made and those no
  /// profile is noted for.
  static Future<List<Recording>> list({String? profile}) async {
    final dirs = [await folder(), ?await _before()].where((d) => d.existsSync());
    final owners = profile == null ? const <String, String>{} : await _owners();
    final found = <Recording>[];
    for (final f in [for (final d in dirs) ...d.listSync().whereType<File>()]) {
      final name = f.path.split(pathSeparator).last;
      if (owners[name] case final owner? when owner != profile) continue;
      final m = _name.firstMatch(name);
      final bytes = f.lengthSync();
      if (m == null || bytes == 0) continue;
      final at = DateTime(
        int.parse(m[2]!),
        int.parse(m[3]!),
        int.parse(m[4]!),
        int.parse(m[5]!),
        int.parse(m[6]!),
        int.parse(m[7]!),
      );
      found.add(Recording(f, m[1]!, at, bytes));
    }
    return found..sort((a, b) => b.at.compareTo(a.at));
  }
}
