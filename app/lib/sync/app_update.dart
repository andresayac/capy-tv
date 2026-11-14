import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../platform.dart';
import 'abi.dart';
import 'sync_client.dart';

/// A newer build of the app than this one, on the account's sync server: the file for this
/// device's processor.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.build,
    required this.abi,
    required this.name,
    required this.size,
    required this.sha256,
    this.notes = '',
  });

  final String version, notes;
  final int build;

  /// As people see it: builds of one version differ by their number.
  String get label => '$version ($build)';
  final String abi; // as the server names it: arm64-v8a, armeabi-v7a... or universal
  final String name; // the file on the server
  final int size;
  final String sha256; // hex

  /// The file for [abi] (else the one for all) in what the server sent ([SyncClient.release]), if
  /// it is a newer build than [installed].
  static AppRelease? pick(Map<String, dynamic>? server, {required int installed, required String? abi}) {
    final build = (server?['build'] as num?)?.toInt() ?? 0;
    final files = server?['files'];
    if (build <= installed || files is! Map) return null;
    // The APK for all processors is no Windows program
    final key = files.containsKey(abi) ? abi! : (abi?.startsWith('windows') ?? false ? null : 'universal');
    if (key == null) return null;
    final file = files[key];
    if (file is! Map || file['name'] is! String || file['size'] is! num || file['sha256'] is! String) return null;
    return AppRelease(
      version: server!['version'] as String? ?? '$build',
      build: build,
      abi: key,
      name: file['name'] as String,
      size: (file['size'] as num).toInt(),
      sha256: file['sha256'] as String,
      notes: server['notes'] as String? ?? '',
    );
  }
}

/// A download that is not what the server has: it is thrown away.
class UpdateDamaged implements Exception {
  const UpdateDamaged();
}

/// Updates from the account's sync server (server/README.md, "App updates"), on Android and
/// Windows: its owner leaves there the APKs of each new build and the Windows installer, this
/// device downloads its own, and Android's installer installs it, asking the user; on Windows the
/// installer runs on its own and opens the app again. Sideloaded apps have no store to do it.
abstract final class AppUpdate {
  static const _channel = MethodChannel('iptv_player/update');

  /// The newer release the server has; null while there is none.
  static final available = ValueNotifier<AppRelease?>(null);

  /// How far its download is, 0 to 1, while one goes on.
  static final downloaded = ValueNotifier<double?>(null);
  static Future<File>? _download;

  static ({String name, int build})? _installed;
  static DateTime? _checked, _offered;

  /// This app's version and build; null where updates don't come this way (neither Android nor
  /// Windows).
  static Future<({String name, int build})?> installed() async {
    if (_installed case final known?) return known;
    if (isAndroid) {
      final m = await _channel.invokeMapMethod<String, Object?>('version');
      return _installed = (name: m?['name'] as String? ?? '', build: (m?['build'] as num?)?.toInt() ?? 0);
    }
    if (isWindows) {
      // As the build wrote them in the program's version ("0.1.0+384")
      final info = await PackageInfo.fromPlatform();
      return _installed = (name: info.version, build: int.tryParse(info.buildNumber) ?? 0);
    }
    return null;
  }

  /// This processor, by Android's ABI names, as the server's files are.
  static String? get _abi => currentAbi;

  /// Asks [client]'s server for a newer build than this one. At most every few hours, unless
  /// [now]: TVs keep the app open for days.
  static Future<void> check(SyncClient client, {bool now = false}) async {
    final last = _checked;
    if (!now && last != null && DateTime.now().difference(last) < const Duration(hours: 6)) return;
    _checked = DateTime.now();
    try {
      final own = await installed();
      if (own == null) return;
      final release = AppRelease.pick(await client.release(), installed: own.build, abi: _abi);
      available.value = release;
      if (release == null) await _folder(clear: true); // what an update left there, installed by now
    } on Object catch (e) {
      // Offline, or an answer of another shape: no update this time
      _checked = null;
      debugPrint('update: $e');
    }
  }

  /// Whether to offer [available] on screen now: once a day at most; Settings has it all along.
  static bool get offerDue {
    final last = _offered;
    return available.value != null && (last == null || DateTime.now().difference(last) > const Duration(hours: 20));
  }

  static void offered() => _offered = DateTime.now();

  /// Where downloads go: as android/app/src/main/res/xml/updates.xml says, for the installer to
  /// read them. A folder of their own in tests.
  @visibleForTesting
  static Future<Directory> Function() place = () async =>
      Directory('${(await getApplicationCacheDirectory()).path}/updates');

  static Future<Directory> _folder({bool clear = false}) async {
    final dir = await place();
    if (clear && dir.existsSync()) dir.deleteSync(recursive: true);
    return dir;
  }

  /// Downloads [release] from [client]'s server, going on from a download that was cut, and
  /// checks it is what the server has; see [downloaded]. Asked again while it goes on, the same
  /// download. Throws a [SyncException], or [UpdateDamaged].
  static Future<File> download(SyncClient client, AppRelease release) {
    downloaded.value ??= 0;
    return _download ??= _fetch(client, release).whenComplete(() {
      _download = null;
      downloaded.value = null;
    });
  }

  static Future<File> _fetch(SyncClient client, AppRelease offered) async {
    // What the server has now, not only what it had when this was offered: a check made while the
    // release was still being copied there (its list of files first, the installer after) described
    // the installer as far as it had come, and every try would be measured against that
    final release = AppRelease.pick(await client.release(), installed: offered.build - 1, abi: offered.abi);
    if (release == null) throw const SyncException(SyncProblem.notFound);
    available.value = release;
    final dir = await _folder();
    final name = '${release.build}-${release.abi}${release.name.endsWith('.exe') ? '.exe' : '.apk'}';
    final file = File('${dir.path}/$name');
    if (dir.existsSync()) {
      // Another build's download is of no use any more. By name: a path may be written with
      // either separator
      for (final other in dir.listSync()) {
        if (other.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull != name) other.deleteSync(recursive: true);
      }
    } else {
      dir.createSync(recursive: true);
    }
    if (file.existsSync() && file.lengthSync() > release.size) file.deleteSync();
    if (!file.existsSync() || file.lengthSync() < release.size) {
      await client.download(release.name, file, progress: (n) => downloaded.value = n / release.size);
    }
    if (file.lengthSync() != release.size || await sha256Of(file) != release.sha256.toLowerCase()) {
      file.deleteSync();
      throw const UpdateDamaged();
    }
    return file;
  }

  @visibleForTesting
  static Future<String> sha256Of(File file) async {
    final sink = Sha256().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    return [for (final b in (await sink.hash()).bytes) b.toRadixString(16).padLeft(2, '0')].join();
  }

  /// Whether Android lets this app install others (since Android 8, the user allows it once).
  /// Windows asks nothing of the kind.
  static Future<bool> canInstall() async => isWindows || (await _channel.invokeMethod<bool>('canInstall') ?? false);

  /// Opens Android's setting for it; false where the device has no such screen.
  static Future<bool> allowInstall() async => await _channel.invokeMethod<bool>('allowInstall') ?? false;

  /// Hands [apk] to Android's installer, which asks the user and closes this app to install it.
  /// On Windows it is the installer: it runs on its own, with only its progress on screen, closes
  /// this app, installs over it, keeps what is in it (it lives apart from the program) and opens it
  /// again.
  static Future<bool> install(File apk) async {
    if (isWindows) {
      try {
        await Process.start(apk.path, const [
          '/SILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
        ], mode: ProcessStartMode.detached);
        // Out of its way at once: it replaces this very program, and opens it again when done
        Timer(const Duration(milliseconds: 300), () => exit(0));
        return true;
      } on ProcessException catch (e) {
        debugPrint('update: ${e.message}');
        return false;
      }
    }
    return await _channel.invokeMethod<bool>('install', {'path': apk.path}) ?? false;
  }
}
