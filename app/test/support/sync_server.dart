import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:iptv_player/sync/sync_client.dart';
import 'package:iptv_player/sync/sync_crypto.dart';
import 'package:iptv_player/sync/sync_service.dart';

/// Creates an account as the app does, from another device speaking the protocol directly and
/// with the key derivation [SyncService] uses. Returns the account's keys.
Future<SyncKeys> createAccountElsewhere(SyncClient client, String email, String password, String device) async {
  final kdf = SyncService.kdf;
  final secret = await SignInKeys.password(email, password, memoryKiB: kdf.memoryKiB, passes: kdf.passes);
  final recovery = await SignInKeys.recovery(RecoveryKey.random());
  final keys = SyncKeys.random();
  await client.signUp(
    email,
    secret.authKey,
    device,
    passwordKeys: await keys.wrap(secret.wrapKey),
    recoveryKey: recovery.authKey,
    recoveryKeys: await keys.wrap(recovery.wrapKey),
  );
  return keys;
}

/// A sync server for tests, from ../server: a local Go build when that works, else a Docker
/// container (antivirus software sometimes blocks fresh Go executables on Windows); never one
/// elsewhere, whose fixed test accounts would stay. Null with the reason when neither Go nor
/// Docker is installed; throws when one is but the server does not build or start.
class TestSyncServer {
  TestSyncServer._(this.url, this._stop);

  final Uri url;
  final Future<void> Function() _stop;

  Future<void> stop() => _stop();

  static Future<(TestSyncServer?, String)> start() async {
    final problems = <String>[];
    for (final how in [_native, _docker]) {
      try {
        final server = await how();
        if (server != null) return (server, '');
      } on ProcessException catch (e) {
        problems.add('${e.executable}: ${e.message.trim()}');
      }
    }
    final missing = problems.every((p) => p.contains('cannot find') || p.contains('No such file'));
    if (missing) return (null, 'neither Go nor Docker found to run the sync server');
    throw StateError('Could not start the sync server:\n${problems.join('\n')}');
  }

  static Future<TestSyncServer?> _native() async {
    // A folder of its own (tests run side by side, and an .exe in use cannot be built over), gone
    // when it stops; on this machine only, so no firewall rule is asked for each new build
    final dir = Directory.systemTemp.createTempSync('sync-server');
    final bin = '${dir.path}/server${Platform.isWindows ? '.exe' : ''}';
    await _run('go', ['build', '-o', bin, '.']);
    // Tests sign in far more often than people: the attempts limit would get in the way
    final process = await Process.start(
      bin,
      [],
      // Open to anyone, as tests make accounts: with no code a server takes none
      environment: {'PORT': '0', 'HOST': '127.0.0.1', 'DATA': ':memory:', 'SIGNIN_LIMIT': '1000', 'SIGNUP_OPEN': '1'},
    );
    // Read to the end, not only up to the port: a pipe closed under it would kill the server at its
    // next log line on Linux and macOS (SIGPIPE)
    final port = Completer<String>();
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      final m = RegExp(r'server on :(\d+)').firstMatch(l);
      if (m != null && !port.isCompleted) port.complete(m[1]);
    });
    unawaited(process.stdout.drain<void>());
    final at = await port.future.timeout(const Duration(seconds: 20));
    return TestSyncServer._(Uri.parse('http://127.0.0.1:$at/'), () async {
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 10), onTimeout: () => -1);
      // Windows holds a program a moment after it ended (its antivirus too): tried again a while
      for (var i = 0; i < 20 && dir.existsSync(); i++) {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    });
  }

  static Future<TestSyncServer?> _docker() async {
    await _run('docker', ['build', '-q', '-t', 'capy-tv-sync:test', '.']);
    final id = (await _run('docker', [
      'run',
      '-d',
      '--rm',
      '-p',
      '127.0.0.1::8080',
      '-e',
      'DATA=:memory:',
      '-e',
      'SIGNIN_LIMIT=1000',
      '-e',
      'SIGNUP_OPEN=1', //
      'capy-tv-sync:test',
    ])).trim();
    final port = (await _run('docker', ['port', id, '8080/tcp'])).trim().split('\n').first.split(':').last;
    final url = Uri.parse('http://127.0.0.1:$port/');
    final client = HttpClient();
    for (var i = 0; i < 50; i++) {
      try {
        final res = await (await client.getUrl(url.resolve('healthz'))).close();
        if (res.statusCode == 200) break;
      } on IOException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    client.close();
    return TestSyncServer._(url, () => _run('docker', ['rm', '-f', id]));
  }

  static Future<String> _run(String executable, List<String> args) async {
    final r = await Process.run(executable, args, workingDirectory: '../server');
    if (r.exitCode != 0) throw ProcessException(executable, args, '${r.stderr}'.trim(), r.exitCode);
    return '${r.stdout}';
  }
}
