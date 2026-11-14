import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/library.dart';
import '../data/playlists.dart';
import '../data/profiles.dart';
import '../data/secrets.dart';
import '../device.dart';
import 'app_update.dart';
import 'cast.dart';
import 'sync_client.dart';
import 'sync_crypto.dart';

enum SyncStatus {
  off, // no account on this device
  syncing,
  synced,
  offline, // the server could not be reached; it retries on its own
  expired, // the session ended (signed out elsewhere, account deleted): sign in again
}

/// Keeps playlists, profiles, favorites and watch history the same on every device of an account.
///
/// Everything is encrypted here before it goes to the server (see [SyncKeys]). Each playlist is
/// one item, named after the playlist's sync id: its id on the device that added it, which the
/// other devices take on. So is each library (a playlist's favorites and history for one
/// profile), and the profiles with the parental PIN. Changes are sent a moment after they happen
/// (progress noted during playback, a while later); the server's socket says when another device
/// sent some, and they are fetched at once. Playlists go by "latest change wins"; libraries merge
/// (see [Library]). Writes are based on the last revision fetched, so a device that missed
/// another's change fetches it before writing.
///
/// Joining an account (the first sync of this device with it) goes the other way round: what the
/// account has comes first, a provider account that is both here and there becomes one playlist,
/// and playlists only here are added to the account.
class SyncService extends ChangeNotifier {
  SyncService._();

  static final instance = SyncService._();

  /// Lighter key derivation, for tests only.
  @visibleForTesting
  static var kdf = (memoryKiB: 65536, passes: 3);

  /// How long local changes wait for more before going out.
  @visibleForTesting
  static var delay = const Duration(seconds: 2);

  /// How long quiet changes (progress during playback) may wait.
  @visibleForTesting
  static var quietDelay = const Duration(minutes: 2);

  static const _accountKey = 'sync.account';
  static const _stateKey = 'sync.state';
  static const _secrets = appSecrets;

  SyncStatus _status = SyncStatus.off;
  Uri? _server;
  String? _email;
  SyncKeys? _keys;
  SyncClient? _client;
  var _state = _SyncState();
  DateTime? _lastSync;

  SyncStatus get status => _status;

  /// Whether this device is in an account, its session still good.
  bool get signedIn => _status != SyncStatus.off && _status != SyncStatus.expired;

  /// The language model the account's server offers for recommendations; null when it offers
  /// none, or when signed out.
  final aiModel = ValueNotifier<String?>(null);

  /// Why the last sync failed, while [status] is offline; null for no answer at all.
  SyncProblem? get problem => _problem;
  SyncProblem? _problem;
  Uri? get server => _server;
  String? get email => _email;
  DateTime? get lastSync => _lastSync;

  /// As the app closing does: what is in memory goes, what was saved on the device stays for
  /// [start] to pick up again. For tests of what a restart finds.
  @visibleForTesting
  Future<void> closeForTests() async {
    await _running;
    _stop();
    _status = SyncStatus.off;
    _server = _email = null;
    _keys = null;
    _state = _SyncState();
    _lastSync = null;
  }

  /// Picks up the account this device was signed in to, if any. Call once at startup.
  Future<void> start() async {
    final String? raw;
    try {
      raw = await _secrets.read(key: _accountKey);
    } on Object catch (e) {
      // The system's secure storage failed (no keyring, a key lost in a restore): start without
      // sync rather than not at all; signing in again fixes it
      debugPrint('sync: the account could not be read: $e');
      return;
    }
    if (raw == null) return;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    _server = Uri.parse(j['server'] as String);
    _email = j['email'] as String;
    final token = j['token'] as String?;
    // What this device knows of the account, also while signed out: signing in again keeps it, and
    // with it what was deleted elsewhere meanwhile, which an empty one would send back
    _state = _SyncState.fromJson((await SharedPreferences.getInstance()).getString(_stateKey));
    if (token == null) {
      _setStatus(SyncStatus.expired);
      return;
    }
    _keys = SyncKeys.fromJson(j['keys'] as Map<String, dynamic>);
    _client = SyncClient(_server!, token: token);
    unawaited(_begin());
  }

  /// Signs in to the account [email] on [server]. Throws a [SyncException] when the server says
  /// no. What is on this device is kept and merged.
  Future<void> signIn({required Uri server, required String email, required String password}) async {
    final mail = SignInKeys.normalizeEmail(email);
    final secret = await _password(mail, password);
    await _session(server, mail, (client) async {
      final (:at, keys: wrapped) = await client.signIn(mail, secret.authKey, deviceName);
      return (at, await _unwrap(secret, wrapped));
    });
  }

  /// Creates the account [email] on [server] and signs in. Returns the account's recovery key,
  /// for the user to keep: the only way in if the password is forgotten.
  Future<RecoveryKey> createAccount({
    required Uri server,
    required String email,
    required String password,
    String invite = '',
  }) async {
    final mail = SignInKeys.normalizeEmail(email);
    final secret = await _password(mail, password);
    final keys = SyncKeys.random(), recoveryKey = RecoveryKey.random();
    final recovery = await SignInKeys.recovery(recoveryKey);
    await _session(server, mail, (client) async {
      final at = await client.signUp(
        mail,
        secret.authKey,
        deviceName,
        passwordKeys: await keys.wrap(secret.wrapKey),
        recoveryKey: recovery.authKey,
        recoveryKeys: await keys.wrap(recovery.wrapKey),
        invite: invite.trim(),
      );
      return (at, keys);
    });
    return recoveryKey;
  }

  /// Sets a new [password] for a forgotten one with the [recoveryKey], and signs in. Every other
  /// device of the account is signed out, until it signs in with the new password.
  Future<void> recover({
    required Uri server,
    required String email,
    required RecoveryKey recoveryKey,
    required String password,
  }) async {
    final mail = SignInKeys.normalizeEmail(email);
    final recovery = await SignInKeys.recovery(recoveryKey);
    final secret = await _password(mail, password);
    await _session(server, mail, (client) async {
      final (:at, keys: wrapped) = await client.signIn(mail, recovery.authKey, deviceName, recovery: true);
      final keys = await _unwrap(recovery, wrapped);
      await client.setPassword(recovery.authKey, secret.authKey, await keys.wrap(secret.wrapKey));
      return (at, keys);
    });
  }

  /// Throws a [SyncException] unless [password] is the account's. By signing in apart and out again:
  /// the ways of changing something with it would sign the other devices out.
  Future<void> verifyPassword(String password) async {
    final secret = await _password(_email!, password);
    final client = SyncClient(_server!);
    await client.signIn(_email!, secret.authKey, deviceName);
    await client.signOut();
  }

  /// Changes the password of the account this device is signed in to. Every other device of the
  /// account is signed out, until it signs in with the new password.
  Future<void> changePassword({required String current, required String password}) async {
    final proof = await _password(_email!, current), secret = await _password(_email!, password);
    await _client!.setPassword(proof.authKey, secret.authKey, await _keys!.wrap(secret.wrapKey));
  }

  /// Makes a new recovery key in place of the account's, which stops working. Takes the password.
  Future<RecoveryKey> newRecoveryKey(String password) async {
    final proof = await _password(_email!, password);
    final recoveryKey = RecoveryKey.random();
    final recovery = await SignInKeys.recovery(recoveryKey);
    await _client!.setRecoveryKey(proof.authKey, recovery.authKey, await _keys!.wrap(recovery.wrapKey));
    return recoveryKey;
  }

  static Future<SignInKeys> _password(String email, String password) =>
      SignInKeys.password(email, password, memoryKiB: kdf.memoryKiB, passes: kdf.passes);

  static Future<SyncKeys> _unwrap(SignInKeys secret, String wrapped) async {
    try {
      return await SyncKeys.unwrap(secret.wrapKey, wrapped);
    } on Object {
      throw const SyncException(SyncProblem.server); // what the server keeps is damaged
    }
  }

  /// Runs [open] with a new client to sign in to [server] as [mail], and switches to that account.
  Future<void> _session(Uri server, String mail, Future<(Revision, SyncKeys)> Function(SyncClient) open) async {
    final client = SyncClient(server);
    final (Revision, SyncKeys) opened;
    try {
      opened = await open(client);
    } on Object {
      // Signed in, then something failed: no session left behind
      if (client.token != null) await client.signOut().then((_) {}, onError: (Object _) {});
      client.close();
      rethrow;
    }
    final (at, keys) = opened;
    // Signing in again after the session ended keeps what this device knows of the account
    if (server != _server || mail != _email) _state = _SyncState();
    _check(at);
    _stop();
    _me = null; // a new session is a new device to the account: requests go to its id
    _server = server;
    _email = mail;
    _keys = keys;
    _client = client;
    _setStatus(SyncStatus.syncing); // no longer expired, if it was
    try {
      await _saveAccount();
    } on Object {
      // Signed in only until the app closes would be worse than saying so
      _server = _email = _keys = _client = null;
      _setStatus(SyncStatus.off);
      throw const SyncException(SyncProblem.server);
    }
    await _saveState();
    await _begin();
  }

  /// Leaves the account on this device. Playlists, favorites and history stay here.
  Future<void> signOut() async {
    try {
      await _client?.signOut();
    } on Object {
      // Gone already, offline, or no sync server: the session is forgotten here either way
    }
    await _forget();
  }

  /// Deletes the account and everything synced from the server. Devices keep their own copy.
  Future<void> deleteAccount(String password) async {
    await verifyPassword(password); // a server older than the proof below would take any
    final proof = await _password(_email!, password);
    await _client!.deleteAccount(proof.authKey);
    await _forget();
  }

  Future<List<Device>> devices() => _client!.devices();

  // Send to: an item addressed to a device of the account, which plays what it says. Sealed like
  // the rest, and of its own version, which devices on an older version of the app leave alone

  Device? _me; // this device, as the account knows it
  var _castAt = 0; // the last request played here, so none plays twice

  /// How long a request stays good: one found later (a device that was off) is not played.
  static const castFor = Duration(minutes: 2);

  Future<Device?> _thisDevice() async {
    final client = _client;
    if (_me != null || client == null) return _me;
    return _me = (await client.devices()).where((d) => d.current).firstOrNull;
  }

  /// Has device [to] play [ref] of the playlist [playlistId] (this device's id), from [position].
  Future<void> cast({
    required String to,
    required String playlistId,
    required MediaRef ref,
    Duration position = Duration.zero,
  }) async {
    final client = _client, keys = _keys;
    if (client == null || keys == null) throw const SyncException(SyncProblem.signedOut);
    final playlists = await PlaylistStore.instance.load();
    final playlist = playlists.where((p) => p.id == playlistId).firstOrNull;
    if (playlist == null) throw StateError('no playlist $playlistId');
    final key = 'cast/$to', itemId = await keys.itemId(key);
    final envelope = {
      'v': _castVersion,
      'key': key,
      'at': DateTime.now().millisecondsSinceEpoch,
      'data': {
        'playlist': _syncId(playlist),
        'ref': ref.toJson(),
        'position': position.inMilliseconds,
        'from': (await _thisDevice())?.name ?? deviceName,
      },
    };
    // Not on top of anything: it takes the place of the last request to that device
    await client.put([RemoteItem(itemId, await keys.seal(itemId, envelope))]);
  }

  /// A request found in the account: played here if it is for this device, and new.
  Future<void> _applyCast(Map<String, dynamic> e) async {
    final at = e['at'] as int, data = e['data'] as Map<String, dynamic>;
    if (at <= _castAt || DateTime.now().millisecondsSinceEpoch - at > castFor.inMilliseconds) return;
    final me = await _thisDevice();
    if (me == null || e['key'] != 'cast/${me.id}') return;
    final playlist = (await PlaylistStore.instance.load()).where((p) => _syncId(p) == data['playlist']).firstOrNull;
    if (playlist == null) return;
    _castAt = at;
    castRequest.value = CastRequest(
      playlistId: playlist.id,
      ref: MediaRef.fromJson(data['ref'] as Map<String, dynamic>),
      position: Duration(milliseconds: data['position'] as int? ?? 0),
      from: data['from'] as String? ?? '',
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }

  Future<void> signOutDevice(String id) => _client!.signOutDevice(id);

  Future<void> _forget() async {
    _stop();
    aiModel.value = null;
    AppUpdate.available.value = null;
    _server = _email = _keys = _client = _lastSync = _me = null;
    _state = _SyncState();
    await _secrets.delete(key: _accountKey);
    await (await SharedPreferences.getInstance()).remove(_stateKey);
    _setStatus(SyncStatus.off);
  }

  Future<void> _saveAccount() => _secrets.write(
    key: _accountKey,
    value: jsonEncode({
      'server': _server.toString(),
      'email': _email,
      'token': ?_client?.token,
      'keys': ?_keys?.toJson(),
    }),
  );

  Future<void> _saveState() async =>
      (await SharedPreferences.getInstance()).setString(_stateKey, jsonEncode(_state.toJson()));

  /// Makes sure what this device knows still matches the account on the server. Returns whether
  /// it had to start over, so everything must be fetched again.
  bool _check(Revision at) {
    if (_state.epoch != 0 && at.epoch != _state.epoch) {
      // Another account under this email (deleted and created again): join it afresh
      _state = _SyncState()..epoch = at.epoch;
      return true;
    }
    _state.epoch = at.epoch;
    if (at.rev < _state.rev) {
      // The server lost changes (restored from a backup): everything goes to it again
      _state.rebase();
      return true;
    }
    return false;
  }

  // Running

  StreamSubscription<Object>? _librarySaves;
  AppLifecycleListener? _lifecycle;
  Timer? _debounce, _lazy, _reconnect;
  WebSocket? _socket;
  var _socketFailures = 0;
  var _applying = false; // changes made by sync itself are not local changes

  /// Starts listening for changes here and elsewhere; completes after the first sync.
  Future<void> _begin() {
    unawaited(_askForAi());
    unawaited(_askForUpdate());
    PlaylistStore.instance.addListener(_changed);
    ProfileStore.instance.addListener(_changed);
    _librarySaves = Library.saved.stream.listen((e) => e.quiet ? _changedQuietly() : _changed());
    // Leaving the app sends what was waiting
    _lifecycle = AppLifecycleListener(
      onResume: () {
        syncNow();
        _askForUpdate();
      },
      onPause: () => _lazy != null ? syncNow() : null,
    );
    _connect();
    return syncNow();
  }

  /// Notes whether the server offers a model; an offline server is asked again on the next start.
  Future<void> _askForAi() async {
    final client = _client;
    if (client == null) return;
    try {
      final model = await client.aiModel();
      if (client == _client) aiModel.value = model;
    } on SyncException catch (e) {
      debugPrint('sync: recommendations: $e');
    }
  }

  /// Whether the server has a newer app (see [AppUpdate]).
  Future<void> _askForUpdate() async {
    final client = _client;
    if (client != null) await AppUpdate.check(client);
  }

  /// Asks the server for a newer app now, whenever it was asked last.
  Future<void> checkForUpdate() async {
    final client = _client;
    if (client != null) await AppUpdate.check(client, now: true);
  }

  /// Downloads the update [AppUpdate.available] found; see [AppUpdate.download].
  Future<File> downloadUpdate(AppRelease release) async {
    final client = _client;
    if (client == null) throw const SyncException(SyncProblem.signedOut);
    return AppUpdate.download(client, release);
  }

  /// An install link for a device with no session (see [SyncClient.appLink]): the page's address
  /// and when it ends; null when the server has no release. Throws a [SyncException].
  Future<({Uri address, DateTime expires})?> installLink() async {
    final client = _client;
    if (client == null) throw const SyncException(SyncProblem.signedOut);
    final link = await client.appLink();
    return link == null ? null : (address: client.installPage(link.code), expires: link.expires);
  }

  /// The answer of the server's model to [messages] (see [aiModel]). Throws a [SyncException].
  Future<String> aiChat(List<Map<String, String>> messages, {bool json = false}) {
    final client = _client;
    if (client == null) throw const SyncException(SyncProblem.signedOut);
    return client.aiChat(messages, json: json);
  }

  void _stop() {
    PlaylistStore.instance.removeListener(_changed);
    ProfileStore.instance.removeListener(_changed);
    _librarySaves?.cancel();
    _lifecycle?.dispose();
    _debounce?.cancel();
    _lazy?.cancel();
    _reconnect?.cancel();
    _socket?.close();
    _client?.close();
    _client = _librarySaves = _lifecycle = _debounce = _lazy = _reconnect = _socket = null;
  }

  void _changed() {
    if (_applying || _client == null) return;
    _debounce?.cancel();
    _debounce = Timer(delay, syncNow);
  }

  /// Unlike [_changed], more of these do not push it back: it goes [quietDelay] after the first.
  void _changedQuietly() {
    if (_applying || _client == null) return;
    _lazy ??= Timer(quietDelay, syncNow);
  }

  /// Listens for changes from other devices, reconnecting with growing pauses when it drops.
  Future<void> _connect() async {
    final client = _client;
    if (client == null || _status == SyncStatus.expired) return;
    try {
      final socket = await client.live();
      if (client != _client) {
        await socket.close();
        return;
      }
      _socket = socket..pingInterval = const Duration(seconds: 30);
      _socketFailures = 0;
      socket.listen(
        (m) {
          final rev = (jsonDecode(m as String) as Map<String, dynamic>)['rev'];
          if (rev is int && rev != _state.rev) unawaited(syncNow());
        },
        onDone: () => _dropped(client),
        onError: (Object _) => _dropped(client),
        cancelOnError: true,
      );
    } on Object {
      _dropped(client);
    }
  }

  void _dropped(SyncClient client) {
    if (client != _client || _status == SyncStatus.expired) return;
    _socket = null;
    final wait = Duration(seconds: min(60, 2 << min(_socketFailures++, 5)));
    _reconnect?.cancel();
    _reconnect = Timer(wait, () {
      _connect();
      unawaited(syncNow()); // whatever happened while it was down
    });
  }

  Future<void>? _running;
  var _again = false;

  /// Sends what changed here and fetches what changed elsewhere. Calls while one is running
  /// make it go once more when done.
  Future<void> syncNow() {
    if (_client == null || _status == SyncStatus.expired) return Future.value();
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    for (var round = 0; round < 5; round++) {
      _again = false;
      await _syncOnce();
      if (!_again || _client == null || _status == SyncStatus.expired) return;
    }
    _changed(); // still more to do: a little later
  }

  Future<void> _syncOnce() async {
    final client = _client!, keys = _keys!;
    _debounce?.cancel();
    _lazy?.cancel();
    _debounce = _lazy = null;
    _setStatus(SyncStatus.syncing);
    try {
      final joining = !_state.joined;
      // Changes here are noted before fetching, so they are not taken for older ones; when
      // joining, what the account has comes first
      if (!joining) await _scan(keys);
      await _pull(client, keys);
      if (joining) await _scan(keys);
      await _push(client, keys);
      if (client != _client) return; // signed out meanwhile
      _lastSync = DateTime.now();
      _setStatus(SyncStatus.synced);
    } on SyncException catch (e) {
      if (client != _client) return;
      if (e.problem == SyncProblem.stale) {
        _again = true; // another device wrote first: fetch that, then try again
      } else if (e.problem == SyncProblem.signedOut) {
        client.token = null;
        await _saveAccount();
        unawaited(_socket?.close());
        _setStatus(SyncStatus.expired);
      } else {
        _problem = e.problem == SyncProblem.network ? null : e.problem;
        _setStatus(SyncStatus.offline);
      }
    } on Object catch (e, stack) {
      // Not the server's doing (storage, a bug): report it, and let the next change try again
      debugPrint('sync failed: $e\n$stack');
      if (client == _client) _setStatus(SyncStatus.offline);
    }
  }

  // Playlists: one item each, the latest change wins

  String _syncId(Playlist p) => _state.ids[p.id] ?? p.id;

  static String _content(Playlist p) => jsonEncode({
    'name': p.name,
    'type': p.type.name,
    'url': p.url,
    'username': p.username,
    'password': p.password,
    if (p.members.isNotEmpty) 'members': p.members,
  });

  /// [p] as the account knows it: a combined playlist names the playlists it joins by their sync
  /// ids, which may not be their ids on this device.
  Playlist _outgoing(Playlist p) =>
      p.members.isEmpty ? p : p.copyWith(members: [for (final m in p.members) _state.ids[m] ?? m]);

  /// [p] from the account as this device knows it: the reverse of [_outgoing].
  Playlist _incoming(Playlist p, List<Playlist> here) => p.members.isEmpty
      ? p
      : p.copyWith(members: [for (final m in p.members) here.where((x) => _syncId(x) == m).firstOrNull?.id ?? m]);

  /// Notes what changed in the playlists since the last look.
  Future<void> _scan(SyncKeys keys) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final playlists = await PlaylistStore.instance.load();
    final here = <String>{};
    for (final p in playlists) {
      final id = _syncId(p);
      here.add(id);
      // Its password could not be read here: an empty one is no change to send to everyone
      if (PlaylistStore.instance.lostPasswords.contains(p.id)) continue;
      final fp = await keys.fingerprint(_content(_outgoing(p)));
      final known = _state.playlists[id];
      if (known == null || known.deleted || known.fp != fp) {
        _state.playlists[id] = _Known(at: max(now, (known?.at ?? 0) + 1), fp: fp, dirty: true);
      }
    }
    for (final MapEntry(key: id, value: known) in _state.playlists.entries.toList()) {
      if (!known.deleted && !here.contains(id)) {
        _state.playlists[id] = _Known(at: max(now, known.at + 1), deleted: true, dirty: true);
      }
    }
    _state.ids.removeWhere((local, _) => !playlists.any((p) => p.id == local));
  }

  Future<void> _pull(SyncClient client, SyncKeys keys) async {
    var changes = await client.items(_state.rev);
    if (_check(changes.at)) {
      changes = await client.items(0);
      _again = true; // and look at what is here again, against the new start
    }
    final playlists = <Map<String, dynamic>>[], libraries = <Map<String, dynamic>>[], casts = <Map<String, dynamic>>[];
    Map<String, dynamic>? profiles;
    for (final item in changes.items) {
      if (item.payload == null) continue;
      try {
        final envelope = await keys.open(item.id, item.payload!) as Map<String, dynamic>;
        final key = envelope['key'] as String;
        if (envelope['v'] == _castVersion) {
          if (await keys.itemId(key) == item.id) casts.add(envelope);
          continue;
        }
        if (envelope['v'] != _version || await keys.itemId(key) != item.id) continue;
        if (key == _profilesKey) {
          profiles = envelope['data'] as Map<String, dynamic>;
        } else {
          (key.startsWith('playlist/') ? playlists : libraries).add(envelope);
        }
      } on Object catch (e) {
        debugPrint('sync: skipped an item that does not open: $e');
      }
    }
    // Playlists that are here under their own id first, so those found by provider account
    // (when joining) cannot take their place
    final here = {for (final p in await PlaylistStore.instance.load()) _syncId(p)};
    String id(Map<String, dynamic> e) => (e['key'] as String).substring((e['key'] as String).indexOf('/') + 1);
    playlists.sort((a, b) => (here.contains(id(a)) ? 0 : 1) - (here.contains(id(b)) ? 0 : 1));
    _applying = true;
    try {
      // Profiles first: libraries belong to them
      // Each on its own: one this device cannot take (a newer version's, or damaged) is left, and
      // the rest still come, and what is here still goes. Otherwise it would stop the sync for good
      if (profiles != null) {
        try {
          await ProfileStore.instance.merge(profiles);
          _state.profiles = await keys.fingerprint(canonicalJson(profiles)); // what the server has
        } on Object catch (e) {
          debugPrint('sync: skipped profiles it cannot take: $e');
        }
      }
      for (final e in playlists) {
        try {
          await _applyPlaylist(keys, id(e), e);
        } on Object catch (x) {
          debugPrint('sync: skipped a playlist it cannot take: $x');
        }
      }
      for (final e in libraries) {
        try {
          await _applyLibrary(keys, id(e), e['data'] as Map<String, dynamic>);
        } on Object catch (x) {
          debugPrint('sync: skipped a library it cannot take: $x');
        }
      }
    } finally {
      _applying = false;
    }
    // After the playlists: the one a request is in may have just come
    for (final e in casts) {
      try {
        await _applyCast(e);
      } on Object catch (x) {
        debugPrint('sync: skipped a request it cannot take: $x');
      }
    }
    _state.rev = changes.at.rev;
    _state.joined = true;
    await _saveState();
  }

  Future<void> _applyPlaylist(SyncKeys keys, String id, Map<String, dynamic> e) async {
    final at = e['at'] as int;
    final known = _state.playlists[id];
    if (known != null && known.at >= at) return; // what is here is as new or newer
    final store = PlaylistStore.instance;
    final list = await store.load();
    var local = list.where((p) => _syncId(p) == id).firstOrNull;
    if (e['deleted'] == true) {
      _state.playlists[id] = _Known(at: at, deleted: true);
      // When joining, what is here stays, and goes back to the account
      if (local != null && _state.joined) await store.remove(local);
      return;
    }
    final remote = Playlist.fromJson(e['data'] as Map<String, dynamic>);
    _state.playlists[id] = _Known(at: at, fp: await keys.fingerprint(_content(remote)));
    final p = _incoming(remote, list);
    if (local == null && !_state.joined) {
      // Joining: the same provider account here is the same playlist, from now on under its id
      local = list
          .where((x) => x.sameAccount(p) && _syncId(x) == x.id && !_state.playlists.containsKey(x.id))
          .firstOrNull;
      if (local != null) _state.ids[local.id] = id;
    }
    if (local == null) {
      // Under the same id as elsewhere, unless a playlist here has it already
      final localId = list.any((x) => x.id == id) ? Playlist.newId() : id;
      if (localId != id) _state.ids[localId] = id;
      await store.add(p.copyWith(id: localId));
    } else if (_content(_outgoing(local)) != _content(remote)) {
      await store.update(p.copyWith(id: local.id)); // the local id keeps its library
    }
  }

  /// [id] is a playlist's sync id, followed by @profile for any profile but the main one.
  Future<void> _applyLibrary(SyncKeys keys, String id, Map<String, dynamic> remote) async {
    final (playlist, profile) = _libraryOf(id);
    final local = (await PlaylistStore.instance.load()).where((p) => _syncId(p) == playlist).firstOrNull;
    if (local == null) return; // the playlist was removed here
    if (!ProfileStore.instance.profiles.any((p) => p.id == profile)) return; // so was the profile
    _state.libraries[id] = await keys.fingerprint(canonicalJson(remote)); // what the server has
    await Library.mergeInto(local.id, profile, remote); // anything only here goes out in the push
  }

  static String _libraryId(String playlist, String profile) =>
      profile == Profile.mainId ? playlist : '$playlist@$profile';

  static (String playlist, String profile) _libraryOf(String id) => switch (id.indexOf('@')) {
    -1 => (id, Profile.mainId),
    final at => (id.substring(0, at), id.substring(at + 1)),
  };

  Future<void> _push(SyncClient client, SyncKeys keys) async {
    final items = <RemoteItem>[];
    final done = <void Function()>[];
    final playlists = await PlaylistStore.instance.load();
    for (final MapEntry(key: id, value: known) in _state.playlists.entries) {
      if (!known.dirty) continue;
      final p = known.deleted ? null : playlists.where((p) => _syncId(p) == id).firstOrNull;
      if (!known.deleted && p == null) continue;
      final key = 'playlist/$id', itemId = await keys.itemId(key);
      final envelope = {
        'v': _version,
        'key': key,
        'at': known.at,
        if (p == null) 'deleted': true else 'data': _outgoing(p).copyWith(id: id).toJson(),
      };
      items.add(RemoteItem(itemId, await keys.seal(itemId, envelope)));
      done.add(() => _state.playlists[id] = known.sent());
    }
    // Libraries of playlists or profiles that are gone go with them
    final profiles = ProfileStore.instance.profiles;
    for (final id in _state.libraries.keys.toList()) {
      final (playlist, profile) = _libraryOf(id);
      if (_state.playlists[playlist]?.deleted != true && profiles.any((p) => p.id == profile)) continue;
      items.add(RemoteItem(await keys.itemId('library/$id'), null));
      done.add(() => _state.libraries.remove(id));
    }
    for (final p in playlists) {
      for (final profile in profiles) {
        final id = _libraryId(_syncId(p), profile.id);
        final library = (await Library.load(p.id, profile.id)).toJson();
        final empty = (library['favorites'] as List).isEmpty && (library['history'] as List).isEmpty;
        if (empty && library['cleared'] == 0 && !_state.libraries.containsKey(id)) continue; // nothing to share yet
        final fp = await keys.fingerprint(canonicalJson(library));
        if (fp == _state.libraries[id]) continue;
        final key = 'library/$id', itemId = await keys.itemId(key);
        items.add(RemoteItem(itemId, await keys.seal(itemId, {'v': _version, 'key': key, 'data': library})));
        done.add(() => _state.libraries[id] = fp);
      }
    }
    // The profiles and the PIN, once there is anything to share: more than the untouched main one
    final mine = ProfileStore.instance.toJson();
    final fp = await keys.fingerprint(canonicalJson(mine));
    final untouched = profiles.length == 1 && profiles.single.at == 0 && mine['pin'] == null;
    if (fp != _state.profiles && !(untouched && _state.profiles == null)) {
      final itemId = await keys.itemId(_profilesKey);
      items.add(RemoteItem(itemId, await keys.seal(itemId, {'v': _version, 'key': _profilesKey, 'data': mine})));
      done.add(() => _state.profiles = fp);
    }
    if (items.isEmpty) return;
    // Only on top of what was fetched: if another device wrote since, this fails as stale
    final rev = await client.put(items, base: _state.rev);
    for (final f in done) {
      f();
    }
    _state.rev = rev;
    await _saveState();
  }

  void _setStatus(SyncStatus s) {
    if (s != SyncStatus.offline) _problem = null;
    _status = s;
    notifyListeners();
  }
}

/// Version of the items' contents; items of other versions are left alone.
const _version = 2;

const _profilesKey = 'profiles';

/// Version of "send to" requests: not [_version], so devices that do not know them skip them.
const _castVersion = 'cast-1';

/// [v] as JSON with every object's keys in order. What sync fingerprints: the same content gives
/// the same text whatever order a device wrote it in (the TV writes a profile's fields in another
/// one), or two devices would each take the other's copy for a change and send theirs back, for
/// ever.
@visibleForTesting
String canonicalJson(Object? v) => jsonEncode(_inOrder(v));

Object? _inOrder(Object? v) => switch (v) {
  final Map<dynamic, dynamic> m => {for (final k in m.keys.map((k) => '$k').toList()..sort()) k: _inOrder(m[k])},
  final List<dynamic> l => [for (final x in l) _inOrder(x)],
  _ => v,
};

/// What this device knows of a playlist's item: when it last changed and a fingerprint of it.
class _Known {
  const _Known({required this.at, this.fp, this.deleted = false, this.dirty = false});

  factory _Known.fromJson(Map<String, dynamic> j) =>
      _Known(at: j['at'] as int, fp: j['fp'] as String?, deleted: j['deleted'] == true, dirty: j['dirty'] == true);

  final int at;
  final String? fp;
  final bool deleted;
  final bool dirty; // changed here, not sent yet

  _Known sent() => _Known(at: at, fp: fp, deleted: deleted);

  _Known unsent() => _Known(at: at, fp: fp, deleted: deleted, dirty: true);

  Map<String, dynamic> toJson() => {'at': at, 'fp': ?fp, if (deleted) 'deleted': true, if (dirty) 'dirty': true};
}

class _SyncState {
  _SyncState();

  factory _SyncState.fromJson(String? raw) {
    final j = raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    if (j == null || j['v'] != _version) return _SyncState(); // older: join again
    return _SyncState()
      ..epoch = j['epoch'] as int
      ..rev = j['rev'] as int
      ..joined = j['joined'] == true
      ..playlists.addAll({
        for (final MapEntry(:key, :value) in (j['playlists'] as Map<String, dynamic>).entries)
          key: _Known.fromJson(value as Map<String, dynamic>),
      })
      ..libraries.addAll((j['libraries'] as Map<String, dynamic>).cast())
      ..profiles = j['profiles'] as String?
      ..ids.addAll((j['ids'] as Map<String, dynamic>).cast());
  }

  var epoch = 0; // which account, among those that had this email
  var rev = 0; // the account's revision this device has caught up with
  var joined = false; // synced with the account at least once
  final playlists = <String, _Known>{}; // by sync id
  final libraries = <String, String>{}; // by sync id[@profile]: fingerprint of what the server has
  String? profiles; // fingerprint of the profiles the server has
  final ids = <String, String>{}; // local playlist id → sync id, where they differ

  /// The server lost changes: fetch everything and send everything again.
  void rebase() {
    rev = 0;
    libraries.clear();
    profiles = null;
    playlists.updateAll((_, known) => known.unsent());
  }

  Map<String, dynamic> toJson() => {
    'v': _version,
    'epoch': epoch,
    'rev': rev,
    'joined': joined,
    'playlists': {for (final MapEntry(:key, :value) in playlists.entries) key: value.toJson()},
    'libraries': libraries,
    'profiles': ?profiles,
    'ids': ids,
  };
}
