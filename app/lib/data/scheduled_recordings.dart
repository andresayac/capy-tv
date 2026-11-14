import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library.dart';
import 'playlists.dart';
import 'storage_health.dart';

enum ScheduleState { scheduled, recording, done, failed, missed }

/// Why a scheduled recording did not record, or only in part, or is being tried again.
enum RecordingProblem {
  /// The app was not running at its time: closed, or the device off.
  appClosed,

  /// The app was running, but the device slept through its time.
  asleep,

  /// Its channel could not be reached: no network, or the provider did not answer.
  noNetwork,

  /// Its playlist or its channel is no more.
  channelGone,

  /// The channel comes in a way no recorder here writes down: encrypted, fragmented MP4, sound
  /// apart from the picture, or not over HTTP.
  unsupported,

  /// The channel sent nothing.
  nothingCame,

  /// The device had too little room left: what came is kept.
  noSpace,

  /// The file could not be written further.
  writeFailed,
}

/// A programme from the guide to be recorded at its time, whether anyone watches or not. It keeps
/// which playlist and channel, never the stream's address: that carries the account, and is made
/// again from the playlist when the recording starts.
@immutable
class ScheduledRecording {
  const ScheduledRecording({
    required this.id,
    required this.playlistId,
    required this.channel,
    required this.title,
    required this.start,
    required this.end,
    this.state = ScheduleState.scheduled,
    this.file,
    this.early = defaultEarly,
    this.late = defaultLate,
    this.problem,
    this.profile,
  });

  factory ScheduledRecording.fromJson(Map<String, dynamic> j) => ScheduledRecording(
    id: j['id'] as String,
    playlistId: j['playlist'] as String,
    channel: MediaRef.fromJson((j['channel'] as Map).cast<String, dynamic>()),
    title: j['title'] as String,
    start: DateTime.fromMillisecondsSinceEpoch(j['start'] as int),
    end: DateTime.fromMillisecondsSinceEpoch(j['end'] as int),
    state: ScheduleState.values.asNameMap()[j['state']] ?? ScheduleState.failed,
    file: j['file'] as String?,
    // Ones kept from before the margins could be chosen had these
    early: Duration(seconds: j['early'] as int? ?? defaultEarly.inSeconds),
    late: Duration(seconds: j['late'] as int? ?? defaultLate.inSeconds),
    problem: RecordingProblem.values.asNameMap()[j['problem']],
    profile: j['profile'] as String?,
  );

  /// Recording starts this much before the guide says, and ends this much after: guides and
  /// channels are seldom on the minute. Chosen in Recordings (see [ScheduledRecordings.add]).
  static const defaultEarly = Duration(minutes: 1), defaultLate = Duration(minutes: 2);

  /// The margins this one was scheduled with: changing them later leaves it as it was.
  final Duration early, late;

  final String id;
  final String playlistId;
  final MediaRef channel; // without its address
  final String title; // the programme's
  final DateTime start, end; // as the guide gives them
  final ScheduleState state;
  final String? file; // the recording's path, once it started

  /// The profile that scheduled it: only that one sees it in Recordings. None for those from
  /// before profiles were noted, which every profile sees.
  final String? profile;

  /// Why it failed, was missed or recorded only in part (done, with one); while still to come, why
  /// it is being tried again.
  final RecordingProblem? problem;

  DateTime get from => start.subtract(early);
  DateTime get to => end.add(late);

  /// Still to come or under way.
  bool get pending => state == ScheduleState.scheduled || state == ScheduleState.recording;

  /// The same programme on the same channel of the same playlist.
  bool isFor(String playlistId, String channelId, DateTime start) =>
      this.playlistId == playlistId && channel.id == channelId && this.start == start;

  static const _same = Object();

  /// [problem] stays as it was unless given; null clears it.
  ScheduledRecording copyWith({ScheduleState? state, String? file, Object? problem = _same}) => ScheduledRecording(
    id: id,
    playlistId: playlistId,
    channel: channel,
    title: title,
    start: start,
    end: end,
    state: state ?? this.state,
    file: file ?? this.file,
    early: early,
    late: late,
    problem: identical(problem, _same) ? this.problem : problem as RecordingProblem?,
    profile: profile,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'playlist': playlistId,
    'channel': channel.toJson(),
    'title': title,
    'start': start.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
    'state': state.name,
    'file': ?file,
    'early': early.inSeconds,
    'late': late.inSeconds,
    'problem': ?problem?.name,
    'profile': ?profile,
  };
}

/// The recordings scheduled on this device, kept in the app preferences. Finished ones stay a
/// week, so the user sees what became of them.
class ScheduledRecordings extends ChangeNotifier {
  ScheduledRecordings._();

  static final instance = ScheduledRecordings._();

  static const _key = 'scheduledRecordings';
  static const _keep = Duration(days: 7);

  var _items = <ScheduledRecording>[];
  Future<void>? _loading;

  /// By start time.
  List<ScheduledRecording> get items => List.unmodifiable(_items);

  Future<void> load() => _loading ??= _read();

  /// Forgets what was loaded (tests).
  @visibleForTesting
  void reset() {
    _items = [];
    _loading = null;
  }

  Future<void> _read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    final list = <ScheduledRecording>[];
    if (raw != null) {
      List<Object?> all;
      try {
        all = jsonDecode(raw) as List;
      } on Object catch (e) {
        debugPrint('scheduled recordings: unreadable, dropped: $e');
        all = const [];
      }
      for (final j in all) {
        try {
          list.add(ScheduledRecording.fromJson((j as Map).cast<String, dynamic>()));
        } on Object catch (e) {
          debugPrint('scheduled recordings: one unreadable, dropped: $e'); // not those after it
        }
      }
    }
    final old = DateTime.now().subtract(_keep);
    _items = list.where((r) => r.pending || r.end.isAfter(old)).toList()..sort((a, b) => a.start.compareTo(b.start));
  }

  Future<void> _write() async {
    _items.sort((a, b) => a.start.compareTo(b.start));
    await saveOrFlag(
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode([for (final r in _items) r.toJson()])),
    );
    notifyListeners();
  }

  /// The one for this programme, if it was scheduled.
  ScheduledRecording? find(String playlistId, String channelId, DateTime start) =>
      _items.where((r) => r.isFor(playlistId, channelId, start)).lastOrNull;

  /// Schedules a programme of [channel], or gives the one already scheduled for it.
  Future<ScheduledRecording> add({
    required String playlistId,
    required MediaRef channel,
    required String title,
    required DateTime start,
    required DateTime end,
    String? profile,
  }) async {
    await load();
    if (find(playlistId, channel.id, start) case final r? when r.pending) return r;
    final prefs = await SharedPreferences.getInstance();
    final r = ScheduledRecording(
      id: Playlist.newId(),
      playlistId: playlistId,
      // Never its address, which may carry the account (M3U)
      channel: MediaRef(
        kind: MediaKind.live,
        id: channel.id,
        title: channel.title,
        image: channel.image,
        epgId: channel.epgId,
      ),
      title: title,
      start: start,
      end: end,
      // As chosen in Recordings now: the same keys as AppSettings.recordEarly and recordLate
      early: Duration(minutes: prefs.getInt('recordEarly') ?? ScheduledRecording.defaultEarly.inMinutes),
      late: Duration(minutes: prefs.getInt('recordLate') ?? ScheduledRecording.defaultLate.inMinutes),
      profile: profile,
    );
    _items = [..._items.where((x) => !x.isFor(playlistId, channel.id, start)), r];
    await _write();
    return r;
  }

  /// Replaces the one with the same id, if it is still there.
  Future<void> put(ScheduledRecording r) async {
    await load();
    if (!_items.any((x) => x.id == r.id)) return;
    _items = [for (final x in _items) x.id == r.id ? r : x];
    await _write();
  }

  Future<void> remove(String id) async {
    await load();
    _items = _items.where((x) => x.id != id).toList();
    await _write();
  }
}
