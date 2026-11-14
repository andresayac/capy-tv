import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library.dart';
import 'storage_health.dart';

/// Someone who watches: their own favorites and history, and what they may see.
class Profile {
  const Profile({
    required this.id,
    required this.name,
    this.kids = false,
    this.locked = false,
    this.adult = false,
    this.at = 0,
    this.deleted = false,
    this.avatar,
    this.audioLanguage,
    this.subtitleLanguage,
    this.dailyMinutes,
    this.pin,
    this.extra = const {},
  });

  static const _known = {
    'id', 'name', 'kids', 'locked', 'adult', 'at', 'deleted', 'avatar', 'audio', 'subtitles', 'minutes', 'pin', //
  };
  static const _keep = Object();

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    kids: j['kids'] == true,
    // Whatever a device that does not know about a PIN of its own may have done to the lock
    locked: j['locked'] == true || _ownPin(j) != null,
    adult: j['adult'] == true,
    at: (j['at'] as num?)?.toInt() ?? 0,
    deleted: j['deleted'] == true,
    avatar: j['avatar'] as String?,
    audioLanguage: j['audio'] as String?,
    subtitleLanguage: j['subtitles'] as String?,
    dailyMinutes: (j['minutes'] as num?)?.toInt(),
    pin: _ownPin(j),
    extra: {
      for (final MapEntry(:key, :value) in j.entries)
        if (!_known.contains(key)) key: value,
    },
  );

  static Map<String, dynamic>? _ownPin(Map<String, dynamic> j) => switch (j['pin']) {
    final Map<String, dynamic> pin when pin['hash'] != null => pin,
    _ => null,
  };

  /// The first profile: its libraries are the ones from before there were profiles.
  static const mainId = mainProfileId;

  final String id;
  final String name; // empty for the main profile until someone names it
  final bool kids; // never shown adult content
  final bool locked; // opening it asks for its own PIN, or the parental one when it has none
  final bool adult; // shows adult content (never in a kids profile)
  final int at; // when it last changed (ms): between devices, the latest change wins
  final bool deleted; // kept as a marker, so other devices delete it too

  /// The picture chosen for it, one of those the app comes with ("notionists-8"); null for its
  /// initial.
  final String? avatar;

  /// Its own preferred audio and subtitle languages (as in the settings: 'off' for no subtitles);
  /// null for the settings' own.
  final String? audioLanguage, subtitleLanguage;

  /// How long a kids profile may watch each day, in minutes; null for no limit.
  final int? dailyMinutes;

  /// Its own PIN ({salt, hash}): what it watches is for whoever knows it, and the parental PIN does
  /// not open it. Null for none.
  final Map<String, dynamic>? pin;

  /// What a newer version of the app keeps in a profile and this one does not know: kept as it
  /// came and sent on, so syncing through this device loses none of it.
  final Map<String, dynamic> extra;

  bool get isMain => id == mainId;

  bool get showsAdult => adult && !kids;

  bool get hasOwnPin => pin != null;

  /// [noAvatar] goes back to the initial.
  Profile copyWith({
    String? name,
    bool? kids,
    bool? locked,
    bool? adult,
    int? at,
    bool? deleted,
    String? avatar,
    bool noAvatar = false,
    Object? audioLanguage = _keep,
    Object? subtitleLanguage = _keep,
    Object? dailyMinutes = _keep,
    Object? pin = _keep,
  }) => Profile(
    id: id,
    name: name ?? this.name,
    kids: kids ?? this.kids,
    locked: locked ?? this.locked,
    adult: adult ?? this.adult,
    at: at ?? this.at,
    deleted: deleted ?? this.deleted,
    avatar: noAvatar ? null : avatar ?? this.avatar,
    audioLanguage: identical(audioLanguage, _keep) ? this.audioLanguage : audioLanguage as String?,
    subtitleLanguage: identical(subtitleLanguage, _keep) ? this.subtitleLanguage : subtitleLanguage as String?,
    dailyMinutes: identical(dailyMinutes, _keep) ? this.dailyMinutes : dailyMinutes as int?,
    pin: identical(pin, _keep) ? this.pin : pin as Map<String, dynamic>?,
    extra: extra,
  );

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'name': name,
    if (kids) 'kids': true,
    if (locked) 'locked': true,
    if (adult) 'adult': true,
    'at': at,
    if (deleted) 'deleted': true,
    'avatar': ?avatar,
    'audio': ?audioLanguage,
    'subtitles': ?subtitleLanguage,
    'minutes': ?dailyMinutes,
    'pin': ?pin,
  };
}

/// The profiles of this device (and of its account, when it syncs), the one in use here, and the
/// parental PIN.
///
/// The parental PIN keeps children away from adult content and from the settings. A profile can
/// have a PIN of its own, for what it watches to stay its own. Four digits: they are not meant to
/// stop someone with the device in their hands and time to spare.
class ProfileStore extends ChangeNotifier {
  ProfileStore._() {
    _all[Profile.mainId] = const Profile(id: Profile.mainId, name: ''); // until [load]
  }

  static final instance = ProfileStore._();

  static const _key = 'profiles';
  static const _currentKey = 'profiles.current';
  static const _deviceKey = 'profiles.device';

  final _all = <String, Profile>{}; // by id, deleted ones included
  Map<String, dynamic>? _pin; // {salt, hash, at}; without hash once removed
  var _current = Profile.mainId;
  var _chosen = false;
  String? _device; // the profile this device opens with, without asking

  /// Reads what is saved. Call once at startup.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _all.clear();
    _pin = null;
    final raw = prefs.getString(_key);
    try {
      if (raw != null) _absorb(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      await prefs.setString('$_key.corrupt', raw!); // read as none, and kept for whoever can mend it
      _all.clear();
    }
    _all.putIfAbsent(Profile.mainId, () => const Profile(id: Profile.mainId, name: ''));
    _current = prefs.getString(_currentKey) ?? Profile.mainId;
    // With a single profile there is nothing to choose, also once a second one is added; unless
    // its PIN is to be asked for
    _chosen = profiles.length <= 1 && !current.locked && !current.hasOwnPin;
    _device = prefs.getString(_deviceKey);
    if (deviceProfile case final id?) {
      _current = id;
      _chosen = !current.hasOwnPin; // it may have got one after being set here
    }
    notifyListeners();
  }

  /// The profile this device opens with, without "Who's watching?" (a kids' TV) unless it has a PIN
  /// of its own; null to ask. Kept on this device only.
  String? get deviceProfile => profiles.any((p) => p.id == _device) ? _device : null;

  Future<void> setDeviceProfile(String? id) async {
    _device = id;
    final prefs = await SharedPreferences.getInstance();
    id == null ? await prefs.remove(_deviceKey) : await prefs.setString(_deviceKey, id);
    notifyListeners();
  }

  /// Profiles in use: the main one, then by name.
  List<Profile> get profiles => [
    for (final p in _all.values)
      if (!p.deleted) p,
  ]..sort((a, b) => a.isMain != b.isMain ? (a.isMain ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Profile get current => switch (_all[_current]) {
    final p? when !p.deleted => p,
    _ => _all[Profile.mainId]!,
  };

  /// "Who's watching?" goes first: there is someone to pick, or a PIN to ask for, and it was not yet.
  bool get choosing => !_chosen && (profiles.length > 1 || current.locked || current.hasOwnPin);

  bool get hasPin => _pin?['hash'] != null;

  Future<void> select(String id) async {
    _current = id;
    _chosen = true;
    await (await SharedPreferences.getInstance()).setString(_currentKey, id);
    notifyListeners();
  }

  /// Back to "Who's watching?".
  void switchProfile() {
    _chosen = false;
    notifyListeners();
  }

  Future<Profile> add(String name, {bool kids = false, String? avatar}) async {
    final p = Profile(id: _newId(), name: name.trim(), kids: kids, at: _now(), avatar: avatar);
    _all[p.id] = p;
    await _save();
    return p;
  }

  /// Saves the changes in [p]; its time moves on, so they win over other devices' older ones.
  Future<void> update(Profile p) async {
    _all[p.id] = p.copyWith(at: max(_now(), (_all[p.id]?.at ?? 0) + 1));
    await _save();
  }

  /// Deletes a profile (never the main one), with its favorites and history on this device.
  Future<void> remove(String id) async {
    final p = _all[id];
    if (p == null || p.isMain) return;
    _all[id] = Profile(id: id, name: '', deleted: true, at: max(_now(), p.at + 1));
    if (id == _current) _chosen = false; // whoever was in it picks again, PINs and all
    await Library.dropProfile(id);
    await _save();
  }

  /// Sets the parental PIN, or with null removes it (and with it the lock of the profiles that
  /// depended on it; those with a PIN of their own keep theirs).
  Future<void> setPin(String? pin) async {
    final at = max(_now(), ((_pin?['at'] as num?)?.toInt() ?? 0) + 1);
    if (pin == null) {
      _pin = {'at': at};
      for (final p in profiles.where((p) => p.locked && !p.hasOwnPin)) {
        _all[p.id] = p.copyWith(locked: false, at: max(_now(), p.at + 1));
      }
    } else {
      final salt = _newSalt();
      _pin = {'salt': salt, 'hash': await _hash(salt, pin), 'at': at};
    }
    await _save();
  }

  /// Whether [pin] is the parental PIN; true when there is none.
  Future<bool> checkPin(String pin) async => !hasPin || await _hash(_pin!['salt'] as String, pin) == _pin!['hash'];

  /// Gives the profile [id] a PIN of its own and locks it, or with null takes both away.
  Future<void> setProfilePin(String id, String? pin) async {
    final salt = _newSalt();
    final hashed = pin == null ? null : {'salt': salt, 'hash': await _hash(salt, pin)};
    final p = _all[id];
    if (p == null) return;
    _all[id] = p.copyWith(pin: hashed, locked: pin != null, at: max(_now(), p.at + 1));
    await _save();
  }

  /// Whether [pin] is the PIN of [p], which has one.
  Future<bool> checkProfilePin(Profile p, String pin) async =>
      await _hash(p.pin!['salt'] as String, pin) == p.pin!['hash'];

  static String _newSalt() => base64.encode([for (var i = 0; i < 16; i++) Random.secure().nextInt(256)]);

  static Future<String> _hash(String salt, String pin) async =>
      base64.encode((await Sha256().hash(utf8.encode('$salt:$pin'))).bytes);

  /// Merges profiles from another device ([toJson] of it): for each profile and for the PIN, the
  /// latest change wins. Returns whether anything changed here.
  Future<bool> merge(Map<String, dynamic> j) async {
    final before = jsonEncode(toJson());
    final gone = _absorb(j);
    if (jsonEncode(toJson()) == before) return false;
    for (final id in gone) {
      await Library.dropProfile(id);
    }
    await _save();
    return true;
  }

  /// Returns the profiles that became deleted.
  List<String> _absorb(Map<String, dynamic> j) {
    final gone = <String>[];
    for (final x in j['profiles'] as List? ?? const []) {
      final p = Profile.fromJson(x as Map<String, dynamic>);
      final mine = _all[p.id];
      if (mine == null || p.at > mine.at || (p.at == mine.at && _wins(p.toJson(), mine.toJson()))) {
        if (p.deleted && !(mine?.deleted ?? true)) {
          gone.add(p.id);
          if (p.id == _current) _chosen = false;
        }
        _all[p.id] = p;
      }
    }
    final pin = j['pin'];
    if (pin is Map<String, dynamic>) {
      final mine = (_pin?['at'] as num?)?.toInt() ?? -1, theirs = (pin['at'] as num).toInt();
      if (theirs > mine || (theirs == mine && _wins(pin, _pin))) _pin = pin;
    }
    return gone;
  }

  static bool _wins(Map<String, dynamic> a, Map<String, dynamic>? b) => keepsOver(a, b);

  /// As saved and synced. Sorted, so the same profiles always encode the same way.
  Map<String, dynamic> toJson() => {
    'profiles': [for (final id in _all.keys.toList()..sort()) _all[id]!.toJson()],
    'pin': ?_pin,
  };

  Future<void> _save() async {
    await saveOrFlag((await SharedPreferences.getInstance()).setString(_key, jsonEncode(toJson())));
    notifyListeners();
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static String _newId() {
    final random = Random.secure();
    return [for (var i = 0; i < 8; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }
}

/// Tries at a PIN, kept over restarts: four digits fall to a patient child. Five go free, then each
/// wrong one waits longer, up to a quarter of an hour.
abstract final class PinTries {
  static const _fails = 'pin.fails', _until = 'pin.until';

  static Future<int> secondsLeft() async {
    final until = (await SharedPreferences.getInstance()).getInt(_until) ?? 0;
    return max(0, ((until - DateTime.now().millisecondsSinceEpoch) / 1000).ceil());
  }

  static Future<void> failed() async {
    final prefs = await SharedPreferences.getInstance();
    final fails = (prefs.getInt(_fails) ?? 0) + 1;
    await prefs.setInt(_fails, fails);
    if (fails < 5) return;
    final seconds = min(30 * (1 << min(fails - 5, 10)), 900);
    await prefs.setInt(_until, DateTime.now().millisecondsSinceEpoch + seconds * 1000);
  }

  static Future<void> passed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_fails);
    await prefs.remove(_until);
  }
}
