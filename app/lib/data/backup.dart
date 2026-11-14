import 'library.dart';
import 'playlists.dart';
import 'profiles.dart';
import 'secrets.dart';
import 'settings.dart';

/// Everything a user would want on another device: playlists (with their credentials), profiles
/// (with the parental PIN), favorites, watch history and playback settings. It only ever travels between the user's own
/// devices, over their local network or as a file they keep.
abstract final class Backup {
  static const format = 'capy-tv-backup';
  static const version = 2;

  static Future<Map<String, dynamic>> export({AppSettings? settings}) async {
    final playlists = await PlaylistStore.instance.load();
    final profiles = ProfileStore.instance;
    return {
      'format': format,
      'version': version,
      'exported': DateTime.now().toUtc().toIso8601String(),
      'playlists': [for (final p in playlists) p.toJson()],
      // The main profile's, as in version 1
      'libraries': {for (final p in playlists) p.id: ?await Library.stored(p.id, mainProfileId)},
      'profiles': profiles.toJson(),
      'profileLibraries': {
        for (final profile in profiles.profiles)
          if (!profile.isMain) profile.id: {for (final p in playlists) p.id: ?await Library.stored(p.id, profile.id)},
      },
      if (settings != null) 'settings': settings.toJson(),
    };
  }

  /// Whether [data] looks like one of our backups. The app had other names before, and so did its
  /// backups' format ("…-backup"): those are taken too.
  static bool isBackup(Object? data) =>
      data is Map &&
      data['format'] is String &&
      (data['format'] as String).endsWith('-backup') &&
      data['playlists'] is List;

  /// Merges a backup into this device: a playlist for an account already here updates its
  /// password instead of appearing twice, favorites are added and, for the same item, the most
  /// recent progress wins. Settings are taken when [settings] is given.
  /// Throws [BackupTooNew] for one made by a newer version, and FormatException for one that does
  /// not read: both before anything is written, so a damaged one leaves this device as it was.
  static Future<ImportResult> import(Map<String, dynamic> data, {AppSettings? settings}) async {
    if (!isBackup(data)) throw const FormatException('Not a Capy TV backup');
    if (data['version'] case final int v when v > version) throw const BackupTooNew();
    // All of it read first: the playlists, and the libraries that would fail halfway through
    final List<Playlist> all;
    try {
      all = [for (final j in data['playlists'] as List) Playlist.fromJson(j as Map<String, dynamic>)];
      final profileLibraries = data['profileLibraries'];
      for (final libs in [data['libraries'], if (profileLibraries is Map) ...profileLibraries.values]) {
        if (libs is! Map) continue;
        for (final l in libs.values) {
          Library.check(l as Map<String, dynamic>);
        }
      }
    } on FormatException {
      rethrow;
    } on Object catch (e) {
      throw FormatException('A damaged backup: $e');
    }
    final store = PlaylistStore.instance;
    final existing = await store.load();
    var added = 0, updated = 0, noPassword = 0;
    // A password the device cannot keep safely: the list is saved all the same, and the rest go on
    Future<void> keeping(Future<void> saved) async {
      try {
        await saved;
      } on SecretsUnavailable {
        noPassword++;
      }
    }

    final targetId = <String, String>{}; // backup playlist id → id on this device
    // Combined playlists last, their members as this device has them: the same accounts may be
    // here already under other ids
    for (var p in [
      ...all.where((p) => p.type != PlaylistType.combined),
      ...all.where((p) => p.type == PlaylistType.combined),
    ]) {
      if (p.type == PlaylistType.combined) p = p.copyWith(members: [for (final m in p.members) targetId[m] ?? m]);
      final same = existing.where(p.sameAccount).firstOrNull;
      if (same != null) {
        targetId[p.id] = same.id;
        if (p.password.isNotEmpty && same.password != p.password) {
          await keeping(store.update(same.copyWith(password: p.password)));
          updated++;
        }
        continue;
      }
      final id = existing.any((x) => x.id == p.id) ? Playlist.newId() : p.id;
      await keeping(store.add(p.copyWith(id: id)));
      targetId[p.id] = id;
      added++;
    }
    final profiles = data['profiles'];
    if (profiles is Map<String, dynamic>) await ProfileStore.instance.merge(profiles);
    final known = {for (final p in ProfileStore.instance.profiles) p.id};
    var libraries = 0;
    final byProfile = {
      mainProfileId: data['libraries'],
      ...data['profileLibraries'] as Map<String, dynamic>? ?? const {},
    };
    for (final MapEntry(key: profileId, value: libs) in byProfile.entries) {
      if (!known.contains(profileId) || libs is! Map<String, dynamic>) continue;
      for (final MapEntry(key: id, value: lib) in libs.entries) {
        final target = targetId[id];
        if (target == null) continue;
        await Library.mergeInto(target, profileId, lib as Map<String, dynamic>);
        libraries++;
      }
    }
    final prefs = data['settings'];
    if (settings != null && prefs is Map<String, dynamic>) await settings.restore(prefs);
    return ImportResult(added: added, updated: updated, libraries: libraries, noPassword: noPassword);
  }
}

/// A backup made by a newer version of the app, whose contents this one may not know.
class BackupTooNew implements Exception {
  const BackupTooNew();
}

class ImportResult {
  const ImportResult({required this.added, required this.updated, required this.libraries, this.noPassword = 0});

  final int added, updated, libraries;

  /// Playlists saved without their password: the device's secure storage failed.
  final int noPassword;

  Map<String, int> toJson() => {
    'added': added,
    'updated': updated,
    'libraries': libraries,
    if (noPassword > 0) 'noPassword': noPassword,
  };
}
