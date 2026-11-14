import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Why a call to the sync server failed, in terms the UI can explain.
enum SyncProblem {
  credentials, // wrong email or password
  exists, // an account with that email already exists
  rateLimited,
  signedOut, // the session is gone: signed out elsewhere or account deleted
  stale, // another device wrote first: fetch its changes and try again
  invite, // this server only creates accounts with its invitation code
  full, // this server has all the accounts it takes (MAX_ACCOUNTS)
  quota, // the account is full
  network,
  notFound, // the server does not have what was asked, such as a model for recommendations
  server,
}

class SyncException implements Exception {
  const SyncException(this.problem);

  final SyncProblem problem;

  @override
  String toString() => 'SyncException(${problem.name})';
}

/// An item as the server keeps it: an opaque id and, unless deleted, an encrypted payload.
class RemoteItem {
  const RemoteItem(this.id, this.payload);

  final String id;
  final String? payload;
}

/// A device signed in to the account.
typedef Device = ({String id, String name, DateTime seen, bool current});

/// Where an account stands: its latest [rev]ision, and its [epoch], which tells it apart from an
/// earlier account with the same email.
typedef Revision = ({int rev, int epoch});

/// The sync server's HTTP API (see server/README.md).
class SyncClient {
  SyncClient(this.server, {this.token, http.Client? client}) : _http = client ?? http.Client();

  final Uri server;
  String? token;
  final http.Client _http;

  /// How long the server may take to answer, and to send each piece of it.
  @visibleForTesting
  static var wait = const Duration(seconds: 20);

  /// The server address the user typed, or null if it is not usable. Plain http only for the
  /// local network, where there is no certificate to get; anything else must be https.
  static Uri? parseServer(String text) {
    var t = text.trim();
    if (t.isEmpty) return null;
    if (!t.contains('://')) t = 'https://$t';
    final uri = Uri.tryParse(t);
    if (uri == null || uri.host.isEmpty || !(uri.scheme == 'https' || uri.scheme == 'http')) return null;
    if (uri.scheme == 'http' && !isLocal(uri.host)) return null;
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path, query: null, fragment: null);
  }

  /// Whether [host] is on this network, Tailscale's addresses included.
  static bool isLocal(String host) {
    if (host == 'localhost' || host.endsWith('.local') || host.endsWith('.ts.net')) return true;
    final ip = InternetAddress.tryParse(host);
    if (ip == null) return false;
    if (ip.isLoopback || ip.isLinkLocal) return true;
    final b = ip.rawAddress;
    return ip.type == InternetAddressType.IPv4 &&
        (b[0] == 10 ||
            (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
            (b[0] == 192 && b[1] == 168) ||
            (b[0] == 100 && b[1] >= 64 && b[1] < 128));
  }

  /// Creates an account and signs in. [passwordKeys] are the account's keys wrapped with the
  /// password; [recoveryKey] proves the recovery key, and [recoveryKeys] are the keys wrapped
  /// with it. [invite] is the server's invitation code, if it asks for one.
  Future<Revision> signUp(
    String email,
    List<int> authKey,
    String device, {
    required String passwordKeys,
    required List<int> recoveryKey,
    required String recoveryKeys,
    String invite = '',
  }) async {
    final j = await _call(
      'POST',
      'v1/accounts',
      body: {
        'email': email,
        'authKey': base64.encode(authKey),
        'recoveryKey': base64.encode(recoveryKey),
        'passwordKeys': passwordKeys,
        'recoveryKeys': recoveryKeys,
        'device': device,
        if (invite.isNotEmpty) 'invite': invite,
      },
    );
    if (j case {'token': final String t, 'rev': final int rev, 'epoch': final int epoch}) {
      token = t;
      return (rev: rev, epoch: epoch);
    }
    throw const SyncException(SyncProblem.server); // a 200 that is no account
  }

  /// Signs in with the auth key of the password or, with [recovery], of the recovery key. Returns
  /// where the account stands and its keys, wrapped with that same secret.
  Future<({Revision at, String keys})> signIn(
    String email,
    List<int> authKey,
    String device, {
    bool recovery = false,
  }) async {
    final j = await _call(
      'POST',
      'v1/sessions',
      body: {'email': email, (recovery ? 'recoveryKey' : 'authKey'): base64.encode(authKey), 'device': device},
    );
    if (j case {'token': final String t, 'rev': final int rev, 'epoch': final int epoch}) {
      token = t;
      return (at: (rev: rev, epoch: epoch), keys: j['keys'] is String ? j['keys'] as String : '');
    }
    throw const SyncException(SyncProblem.server); // a 200 that is no session
  }

  /// Sets a new password: [authKey] proves it, [passwordKeys] are the account's keys wrapped with
  /// it. [proof] is the auth key of the current password or of the recovery key. Every other
  /// device of the account is signed out.
  Future<void> setPassword(List<int> proof, List<int> authKey, String passwordKeys) => _call(
    'PUT',
    'v1/account/password',
    body: {'proof': base64.encode(proof), 'authKey': base64.encode(authKey), 'passwordKeys': passwordKeys},
  );

  /// Replaces the recovery key, with the same [proof] as [setPassword]. The one before stops working.
  Future<void> setRecoveryKey(List<int> proof, List<int> recoveryKey, String recoveryKeys) => _call(
    'PUT',
    'v1/account/recovery',
    body: {'proof': base64.encode(proof), 'recoveryKey': base64.encode(recoveryKey), 'recoveryKeys': recoveryKeys},
  );

  Future<void> signOut() => _call('DELETE', 'v1/sessions/current');

  /// Deletes the account: [proof] is the auth key of the password, as a session alone must not do it.
  Future<void> deleteAccount(List<int> proof) => _call('DELETE', 'v1/account', body: {'proof': base64.encode(proof)});

  Future<List<Device>> devices() async {
    final j = await _call('GET', 'v1/devices');
    return [
      for (final d in j['devices'] as List)
        (
          id: d['id'] as String,
          name: d['device'] as String,
          seen: DateTime.parse(d['seen'] as String),
          current: d['current'] == true,
        ),
    ];
  }

  /// Signs another device of the account out: it keeps what it has, but gets nothing new.
  Future<void> signOutDevice(String id) => _call('DELETE', 'v1/devices/${Uri.encodeComponent(id)}');

  /// What changed after revision [since], and where the account stands now.
  Future<({Revision at, List<RemoteItem> items})> items(int since) async {
    final j = await _call('GET', 'v1/items?since=$since');
    return (
      at: (rev: j['rev'] as int, epoch: j['epoch'] as int),
      items: [
        for (final i in j['items'] as List)
          RemoteItem(i['id'] as String, i['deleted'] == true ? null : i['payload'] as String),
      ],
    );
  }

  /// Stores [items] as one new revision of the account, and returns it. With [base], only if
  /// the account is still at that revision; otherwise throws [SyncProblem.stale].
  Future<int> put(List<RemoteItem> items, {int? base}) async {
    final j = await _call(
      'PUT',
      'v1/items',
      body: {
        'base': ?base,
        'items': [
          for (final i in items) {'id': i.id, if (i.payload == null) 'deleted': true else 'payload': i.payload},
        ],
      },
    );
    return j['rev'] as int;
  }

  /// The language model the server offers for recommendations, or null when it offers none.
  Future<String?> aiModel() async {
    try {
      return (await _call('GET', 'v1/ai'))['model'] as String?;
    } on SyncException catch (e) {
      if (e.problem == SyncProblem.notFound) return null;
      rethrow;
    }
  }

  /// The server's model's answer to [messages]; a JSON one when [json].
  Future<String> aiChat(List<Map<String, String>> messages, {bool json = false}) async {
    final j = await _call(
      'POST',
      'v1/ai/chat',
      body: {'messages': messages, 'json': json},
      timeout: const Duration(minutes: 2), // large models take their time
    );
    return j['content'] as String? ?? '';
  }

  /// The app release the server has, as it sends it ({version, build, notes?, files: {abi: {name,
  /// size, sha256}}}), or null when it has none.
  Future<Map<String, dynamic>?> release() async {
    try {
      return await _call('GET', 'v1/app');
    } on SyncException catch (e) {
      if (e.problem == SyncProblem.notFound) return null;
      rethrow;
    }
  }

  /// A temporary code for a device with no session to install the app from the server's page at
  /// [installPage], and when it ends; null when the server has no release.
  Future<({String code, DateTime expires})?> appLink() async {
    try {
      final j = await _call('POST', 'v1/app/link');
      return (code: j['code'] as String, expires: DateTime.parse(j['expires'] as String));
    } on SyncException catch (e) {
      if (e.problem == SyncProblem.notFound) return null;
      rethrow;
    }
  }

  /// The page of the install link [code] (see [appLink]).
  Uri installPage(String code) => server.resolve('i/${Uri.encodeComponent(code)}');

  /// Downloads the release's file [name] into [to], going on from what [to] already has (a
  /// download that was cut). [progress] gets the bytes there so far.
  Future<void> download(String name, File to, {void Function(int bytes)? progress}) async {
    final have = to.existsSync() ? to.lengthSync() : 0;
    final req = http.Request('GET', server.resolve('v1/app/${Uri.encodeComponent(name)}'));
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (have > 0) req.headers['range'] = 'bytes=$have-';
    final http.StreamedResponse res;
    try {
      res = await _http.send(req).timeout(wait);
    } on Exception {
      throw const SyncException(SyncProblem.network);
    }
    final going = res.statusCode == 206;
    if (res.statusCode != 200 && !going) {
      throw SyncException(switch (res.statusCode) {
        401 => SyncProblem.signedOut,
        404 => SyncProblem.notFound,
        _ => SyncProblem.server,
      });
    }
    final sink = to.openWrite(mode: going ? FileMode.append : FileMode.write);
    var got = going ? have : 0;
    try {
      // A stream that stops coming is a cut download too
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        got += chunk.length;
        progress?.call(got);
      }
    } on Exception {
      throw const SyncException(SyncProblem.network);
    } finally {
      await sink.close();
    }
  }

  /// A socket that says when another device changed something: {"type": "changed", "rev": n}.
  Future<WebSocket> live() {
    final ws = server.resolve('v1/live').replace(scheme: server.scheme == 'https' ? 'wss' : 'ws');
    return WebSocket.connect(ws.toString(), headers: {'authorization': 'Bearer $token'}).timeout(wait);
  }

  Future<Map<String, dynamic>> _call(String method, String path, {Object? body, Duration? timeout}) async {
    timeout ??= wait;
    final req = http.Request(method, server.resolve(path));
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      final r = await _http.send(req).timeout(timeout);
      // The body too, a piece at a time: a line that drops after the headers, its connection left
      // open, would otherwise leave the sync waiting until the app closes. No limit on the whole: a
      // big answer on a slow line is fine while it comes
      res = await http.Response.fromStream(
        http.StreamedResponse(
          r.stream.timeout(timeout),
          r.statusCode,
          headers: r.headers,
          request: r.request,
          contentLength: r.contentLength,
        ),
      );
    } on Exception {
      throw const SyncException(SyncProblem.network);
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return const {};
      try {
        return jsonDecode(res.body) as Map<String, dynamic>;
      } on Object {
        throw const SyncException(SyncProblem.server); // a web page sent with a 200: no sync server
      }
    }
    throw SyncException(switch (res.statusCode) {
      401 when path.startsWith('v1/sessions') && method == 'POST' => SyncProblem.credentials,
      401 => SyncProblem.signedOut,
      409 when res.body.contains('"stale"') => SyncProblem.stale,
      409 => SyncProblem.exists,
      403 when res.body.contains('"invite"') => SyncProblem.invite,
      403 when res.body.contains('"full"') => SyncProblem.full,
      403 when res.body.contains('"credentials"') => SyncProblem.credentials, // the current password
      413 when res.body.contains('"quota"') => SyncProblem.quota,
      429 => SyncProblem.rateLimited,
      404 => SyncProblem.notFound,
      _ => SyncProblem.server,
    });
  }

  void close() => _http.close();
}
