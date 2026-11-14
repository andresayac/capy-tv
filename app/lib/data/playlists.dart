import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../device.dart';
import 'combined.dart';
import 'm3u.dart';
import 'secrets.dart';
import 'source.dart';
import 'storage_health.dart';
import 'xtream.dart';
import 'xtream_paths.dart';

enum PlaylistType { xtream, m3u, combined }

/// The server's name in [url], for a list given none: "host:8080" or a bare IP has no scheme, and
/// read as it is would give an empty name.
String _hostOf(String url) {
  final host = Uri.tryParse(url.contains('://') ? url : 'http://$url')?.host;
  return host == null || host.isEmpty ? url : host;
}

/// A playlist configured by the user.
class Playlist {
  /// The server's address for the screens: a link may carry the account in its path or query.
  String get address => Uri.tryParse(url)?.host ?? '';

  const Playlist({
    this.extra = const {},
    required this.id,
    required this.name,
    required this.type,
    required this.url,
    this.username = '',
    this.password = '',
    this.userAgent = '',
    this.members = const [],
    this.guideShift = 0,
  });

  /// Several playlists as one ([CombinedSource]): [members] are their ids, in order.
  factory Playlist.combine({required String name, required List<String> members, String? id}) => Playlist(
    id: id ?? newId(),
    name: name.trim(),
    type: PlaylistType.combined,
    url: '',
    members: List.unmodifiable(members),
  );

  /// A new playlist from what the user typed: trimmed, with a name taken from the server when
  /// none was given.
  factory Playlist.create({
    required PlaylistType type,
    required String url,
    String name = '',
    String username = '',
    String password = '',
    String userAgent = '',
  }) {
    // The link a provider hands out carries a whole Xtream account: better as one than as M3U
    if (xtreamLink(url) case final x? when username.trim().isEmpty) {
      return Playlist.create(
        type: PlaylistType.xtream,
        url: x.server,
        name: name,
        username: x.username,
        password: x.password,
        userAgent: userAgent,
      );
    }
    final u = url.trim();
    return Playlist(
      id: newId(),
      name: name.trim().isEmpty ? _hostOf(u) : name.trim(),
      type: type,
      url: u,
      username: username.trim(),
      password: password.trim(), // pasted from a chat, it often carries a space at the end
      userAgent: type == PlaylistType.xtream ? userAgent.trim() : '',
    );
  }

  /// The Xtream account in a link providers hand out: "http://host:8080/get.php?username=…&password=…
  /// &type=m3u_plus" (or player_api.php, xmltv.php), or a stream's address ".../live/user/pass/1.ts".
  /// Null when [text] is no such link.
  static ({String server, String username, String password})? xtreamLink(String text) {
    final u = Uri.tryParse(text.trim());
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) return null;
    // The authority keeps an IPv6 address's brackets; the panel's own folder stays too
    final server = '${u.scheme}://${u.authority}';
    final q = u.queryParameters;
    if ((q['username'] ?? '').isNotEmpty && (q['password'] ?? '').isNotEmpty) {
      final folder = u.path.replaceFirst(RegExp(r'/(get|player_api|xmltv)\.php$'), '').replaceFirst(RegExp(r'/+$'), '');
      return (server: '$server$folder', username: q['username']!, password: q['password']!);
    }
    // A panel's stream (see parseXtreamPath), which ends in its numeric id: a CDN's
    // /live/sports/us/playlist.m3u8 is no account
    if (parseXtreamPath(u.path) case final p? when p.type != null) {
      return (server: server, username: Uri.decodeComponent(p.user), password: Uri.decodeComponent(p.password));
    }
    // Or its catch-up: /timeshift/user/password/minutes/start/id.ts
    final s = u.pathSegments;
    if (s.length >= 4 && s[0] == 'timeshift' && RegExp(r'^\d+(\.\w+)?$').hasMatch(s.last)) {
      return (server: server, username: s[1], password: s[2]);
    }
    return null;
  }

  /// A new id: random, so playlists made on different devices never share one (sync tells them
  /// apart by it).
  static String newId() {
    final random = Random.secure();
    return [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
    id: j['id'] as String,
    name: j['name'] as String,
    type:
        PlaylistType.values.asNameMap()[j['type']] ??
        (throw const FormatException('A type this version does not know')),
    url: j['url'] as String,
    username: j['username'] as String? ?? '',
    password: j['password'] as String? ?? '',
    userAgent: j['userAgent'] as String? ?? '',
    members: [for (final m in (j['members'] as List?) ?? const []) m as String],
    guideShift: (j['guideShift'] as num?)?.toInt() ?? 0,
    extra: {
      for (final MapEntry(:key, :value) in j.entries)
        if (!_known.contains(key)) key: value,
    },
  );

  static const _known = {'id', 'name', 'type', 'url', 'username', 'password', 'userAgent', 'members', 'guideShift'};

  /// What a newer version wrote here: kept, so editing on this device does not take it away.
  final Map<String, dynamic> extra;

  final String id;
  final String name;
  final PlaylistType type;
  final String url; // server (Xtream) or playlist URL (M3U)
  final String username, password;

  /// What an Xtream panel that lets only some players in is told this one is; empty for the usual.
  final String userAgent;
  final List<String> members; // combined only: the playlists it joins, by id

  /// Minutes its guide's times are moved: a provider whose guide is on the wrong clock (it says
  /// programmes hours early or late) is put right by hand. Added to M3U's own tvg-shift.
  final int guideShift;

  /// Same account: what decides whether an imported playlist is new or an update.
  bool sameAccount(Playlist o) =>
      type == o.type && _server == o._server && username == o.username && listEquals(members, o.members);

  /// The server as it is reached: "host:8080", "http://host:8080/" and the like are one.
  String get _server {
    if (type != PlaylistType.xtream) return url.trim();
    try {
      return XtreamSource.normalizeServer(url).toString();
    } on Object {
      return url.trim();
    }
  }

  Playlist copyWith({
    String? id,
    String? name,
    String? password,
    List<String>? members,
    int? guideShift,
    Map<String, dynamic>? extra,
  }) => Playlist(
    extra: extra ?? this.extra,
    id: id ?? this.id,
    name: name ?? this.name,
    type: type,
    url: url,
    username: username,
    password: password ?? this.password,
    userAgent: userAgent,
    members: members ?? this.members,
    guideShift: guideShift ?? this.guideShift,
  );

  Map<String, dynamic> toJson({bool withPassword = true}) => {
    ...extra,
    'id': id,
    'name': name,
    'type': type.name,
    'url': url,
    'username': username,
    if (withPassword) 'password': password,
    if (userAgent.isNotEmpty) 'userAgent': userAgent,
    if (members.isNotEmpty) 'members': members,
    if (guideShift != 0) 'guideShift': guideShift,
  };

  /// Its source. With [refetch] (the list is being updated) its lists and guide come from the
  /// provider, not from the copies on disk however young.
  Future<ContentSource> open({String liveFormat = 'ts', bool refetch = false}) async {
    final shift = Duration(minutes: guideShift);
    return switch (type) {
      PlaylistType.xtream => XtreamSource(
        server: url,
        username: username,
        password: password,
        liveFormat: liveFormat,
        refetch: refetch,
        userAgent: userAgent.isEmpty ? null : userAgent,
      )..guideShift = shift,
      PlaylistType.m3u => (await M3uSource.load(url, refetch: refetch))..guideShift = shift,
      PlaylistType.combined => await _openCombined(liveFormat, refetch),
    };
  }

  /// The playlists it joins that still exist, each opened; one that does not open leaves its place
  /// empty (see [CombinedSource.slots]), said in [CombinedSource.failed].
  Future<ContentSource> _openCombined(String liveFormat, bool refetch) async {
    final all = await PlaylistStore.instance.load();
    Object? error;

    /// A member opened, or the name of one that failed.
    Future<({CombinedPart? part, String? failed})> open(String id) async {
      final p = all.where((x) => x.id == id && x.type != PlaylistType.combined).firstOrNull;
      if (p == null) return (part: null, failed: null);
      try {
        return (part: (name: p.name, source: await p.open(liveFormat: liveFormat, refetch: refetch)), failed: null);
      } on Object catch (e) {
        error ??= e;
        return (part: null, failed: p.name);
      }
    }

    // Together: two M3U lists of a minute each take a minute, not two. One after another where two
    // big lists at once would not fit in memory. Either way in the members' order
    final opened = lowMemory
        ? [for (final id in members) await open(id)]
        : await Future.wait([for (final id in members) open(id)]);
    final slots = [for (final o in opened) o.part];
    final failed = [for (final o in opened) ?o.failed];
    if (slots.nonNulls.isEmpty) throw error ?? const SourceException(SourceError.notFound);
    // Each panel's clock, for its catch-up: in the background, and one that fails only keeps ours
    for (final p in slots.nonNulls) {
      if (p.source case final XtreamSource x) unawaited(x.login().then((_) {}, onError: (Object _) {}));
    }
    return CombinedSource(slots)..failed.addAll(failed);
  }

  /// Throws a SourceException unless the playlist loads (M3U) or the account logs in (Xtream).
  Future<void> verify() async {
    if (type == PlaylistType.combined) {
      await open(); // at least one of its playlists opens
      return;
    }
    if (type == PlaylistType.m3u) {
      await M3uSource.load(url, refetch: true); // for real, not a copy from before; kept for its first opening
      return;
    }
    final source = await open();
    if (source is XtreamSource) {
      try {
        await source.login();
      } finally {
        source.close();
      }
    }
  }
}

/// Playlists saved on this device. Names and servers live in the app preferences; passwords
/// in the system's secure storage (Android Keystore, Apple Keychain, Windows DPAPI, libsecret).
/// Nothing is stored anywhere else.
class PlaylistStore extends ChangeNotifier {
  PlaylistStore._();

  static final instance = PlaylistStore._();

  static const _key = 'playlists';
  static const _secrets = appSecrets;
  static String _passwordKey(String id) => 'playlist.$id.password';

  List<Playlist>? _playlists;
  Future<List<Playlist>>? _loading;
  var _unreadable = const <Object?>[]; // what a newer version wrote: kept as it is
  final _kept = <String, String>{}; // the password in secure storage, by playlist
  final _lostPasswords = <String>{}; // those it would not give back
  Future<void> _last = Future.value();

  /// The playlists whose password could not be read: empty here, but not necessarily on the system
  /// or in the account, so nothing is written over it from them.
  Set<String> get lostPasswords => Set.unmodifiable(_lostPasswords);

  /// Null until [load] completes.
  List<Playlist>? get playlists => _playlists;

  /// The current list, read from storage the first time.
  Future<List<Playlist>> load() async {
    await (_loading ??= _read());
    return _playlists!;
  }

  /// Forgets what was loaded (tests, or after the storage changed underneath).
  @visibleForTesting
  void reset() {
    _playlists = null;
    _loading = null;
    _kept.clear();
    _lostPasswords.clear();
    _unreadable = const [];
  }

  Future<List<Playlist>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final stored = <Playlist>[];
    final unreadable = <Object?>[];
    for (final j in _entries(raw)) {
      try {
        stored.add(Playlist.fromJson(j as Map<String, dynamic>));
      } on Object {
        unreadable.add(j);
      }
    }
    _unreadable = unreadable;
    // Earlier versions kept passwords in the preferences: move them to secure storage
    final legacy = stored.any((p) => p.password.isNotEmpty);
    final list = [
      for (final p in stored)
        p.password.isNotEmpty
            ? p
            : p.copyWith(
                password: await _password(p.id, needed: p.type == PlaylistType.xtream && p.username.isNotEmpty),
              ),
    ];
    _playlists = list;
    if (legacy) await _write();
    return list;
  }

  static List<Object?> _entries(String? raw) {
    if (raw == null) return const [];
    try {
      return jsonDecode(raw) as List;
    } on Object {
      return const [];
    }
  }

  /// The password kept for playlist [id]; empty if the system's secure storage cannot give it
  /// back (no keyring, a key lost in a restore): the playlist stays, and editing it sets it again.
  /// One [needed] (an Xtream account has one) that comes back as none was lost too: Android drops
  /// an entry it cannot open any more, rather than say so. Either way it is noted as lost, not
  /// taken for an empty password, which sync would send over the other devices' good one.
  Future<String> _password(String id, {bool needed = false}) async {
    try {
      final kept = await _secrets.read(key: _passwordKey(id));
      if (kept == null && needed) {
        debugPrint('playlists: password of $id is gone from secure storage');
        _lostPasswords.add(id);
        return '';
      }
      return _kept[id] = kept ?? '';
    } on Object catch (e) {
      debugPrint('playlists: password of $id could not be read: ${e.runtimeType}');
      _lostPasswords.add(id);
      return '';
    }
  }

  /// One at a time, in order. The list first: it is saved even when its password cannot be
  /// ([SecretsUnavailable]), and it is there for the screens at once.
  Future<void> _write() {
    final done = _last.then((_) => _save());
    _last = done.catchError((Object _) {});
    return done;
  }

  Future<void> _save() async {
    final list = _playlists ?? const <Playlist>[];
    await saveOrFlag(
      (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode([for (final p in list) p.toJson(withPassword: false), ..._unreadable]),
      ),
    );
    notifyListeners();
    var failed = false;
    for (final p in list) {
      // Only what changed: one that could not be read must not be overwritten with nothing
      if ((_kept[p.id] ?? '') == p.password || (p.password.isEmpty && _lostPasswords.contains(p.id))) continue;
      try {
        await _secrets.write(key: _passwordKey(p.id), value: p.password);
        _kept[p.id] = p.password;
        _lostPasswords.remove(p.id);
      } on Object {
        failed = true;
      }
    }
    if (failed) throw const SecretsUnavailable();
  }

  Future<void> add(Playlist p) async {
    await load();
    _playlists = [..._playlists!, p];
    await _write();
  }

  /// Replaces the playlist with the same id.
  Future<void> update(Playlist p) async {
    await load();
    _playlists = [for (final x in _playlists!) x.id == p.id ? p : x];
    await _write();
  }

  Future<void> remove(Playlist p) async {
    await load();
    _playlists = _playlists!.where((x) => x.id != p.id).toList();
    _kept.remove(p.id);
    _lostPasswords.remove(p.id);
    try {
      await _secrets.delete(key: _passwordKey(p.id));
    } on Object {
      // Nothing can be read back from there either
    }
    await _write();
  }
}
