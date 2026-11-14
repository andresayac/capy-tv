import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// The preferences of Windows and Linux, in the same file and form as the plugin's, written whole or
/// not at all. The plugin empties the file and then writes it: a power cut or a full disk at that
/// moment, and with a movie going that is every ten seconds, took every list and profile with it, or
/// left a file that stopped the app from starting at all.
class AtomicPrefsStore extends SharedPreferencesStorePlatform {
  AtomicPrefsStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  Future<Map<String, Object>>? _loading;
  Future<void> _last = Future.value();

  Future<File> get _file async => File('${(await _directory()).path}/shared_preferences.json');

  Future<Map<String, Object>> get _values => _loading ??= _read();

  Future<Map<String, Object>> _read() async {
    final file = await _file;
    if (!file.existsSync()) return {};
    final backup = File('${file.path}.bak');
    final values = _parse(file);
    if (values != null) {
      try {
        file.copySync(backup.path); // once per start, of one known to be good
      } on FileSystemException {
        // Only a copy
      }
      return values;
    }
    try {
      file.renameSync('${file.path}.corrupt');
    } on FileSystemException {
      // Overwritten at the next save, then
    }
    return _parse(backup) ?? {};
  }

  static Map<String, Object>? _parse(File file) {
    try {
      final text = file.readAsStringSync();
      if (text.trim().isEmpty) return null;
      return {
        for (final MapEntry(:key, :value) in (jsonDecode(text) as Map<String, dynamic>).entries)
          if (value != null) key: value is List ? value.cast<String>() : value as Object,
      };
    } on Object {
      return null; // cut short, or full of zeros, or not ours
    }
  }

  /// In the order they were asked for; false when it could not be written.
  Future<bool> _save() {
    final done = _last.then((_) => _write());
    _last = done.then((_) {});
    return done;
  }

  Future<bool> _write() async {
    try {
      final file = await _file;
      final part = File('${file.path}.tmp');
      await part.writeAsString(jsonEncode(await _values), flush: true);
      for (var attempt = 0; ; attempt++) {
        try {
          await part.rename(file.path);
          return true;
        } on FileSystemException {
          if (attempt == 4) rethrow; // an antivirus holding it, usually for a moment
          await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
        }
      }
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<Map<String, Object>> getAll() async => Map.of(await _values);

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(GetAllParameters(filter: PreferencesFilter(prefix: prefix)));

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters parameters) async {
    final filter = parameters.filter;
    return {
      for (final MapEntry(:key, :value) in (await _values).entries)
        if (key.startsWith(filter.prefix) && (filter.allowList?.contains(key) ?? true)) key: value,
    };
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    (await _values)[key] = value;
    return _save();
  }

  @override
  Future<bool> remove(String key) async {
    (await _values).remove(key);
    return _save();
  }

  @override
  Future<bool> clear() async {
    (await _values).clear();
    return _save();
  }

  @override
  Future<bool> clearWithPrefix(String prefix) =>
      clearWithParameters(ClearParameters(filter: PreferencesFilter(prefix: prefix)));

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final filter = parameters.filter;
    (await _values).removeWhere((key, _) => key.startsWith(filter.prefix) && (filter.allowList?.contains(key) ?? true));
    return _save();
  }
}
