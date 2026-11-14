import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_language.dart';
import '../data/clock.dart';
import '../data/combined.dart';
import '../data/free_space.dart';
import '../data/library.dart';
import '../data/playlists.dart';
import '../data/profiles.dart';
import '../data/recordings.dart';
import '../data/scheduled_recordings.dart';
import '../data/source.dart' show ContentSource, recordingsRunning;
import '../data/xtream.dart';
import '../device.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import 'background_recorder.dart';
import 'hls_recorder.dart' show HlsProblem, HlsRefused;
import 'power.dart';

/// Where a scheduled recording comes from: the channel's address now and the headers it needs.
typedef RecordingTarget = ({String url, Map<String, String> headers});

/// Makes [r]'s channel address again; null when its playlist or channel is no more. Throws when
/// that cannot be known now (no network): it is tried again a little later.
typedef ResolveChannel = Future<RecordingTarget?> Function(ScheduledRecording r);

/// The player, while it plays a live channel: a scheduled recording of that channel records from
/// what the player gets (its relay, see record_relay.dart) rather than on a connection of its own,
/// which the provider may not allow alongside (one connection per account is common).
abstract interface class LiveTap {
  String get playlistId;
  String get channelId;

  /// Writes the channel into [file], after what it has, until stopped; it ends
  /// [RecorderEnd.released] once the player no longer gets it. Null when it cannot (HLS).
  Future<ChannelRecorder?> recordInto(File file, {void Function(Object error)? onWriteError});
}

/// Records the programmes scheduled from the guide at their time, with no player: started with the
/// app, it looks every [every] (and when the app comes back, or is woken for one) for recordings
/// due to start or to stop. They happen while the app runs, in the background too; one whose time
/// passed with the app closed is marked missed. Overlapping ones each record, each a connection of
/// its own, except one of the channel the player plays, which records from what the player gets.
class RecordingScheduler with WidgetsBindingObserver {
  RecordingScheduler({
    ScheduledRecordings? store,
    DateTime Function()? clock,
    ResolveChannel? resolve,
    StartRecorder? Function(String url)? pickRecorder,
    StartRecorder? Function()? pickHls,
    Future<File> Function(ScheduledRecording r)? newFile,
    RecordingKeepAlive? keepAlive,
    Future<int?> Function()? roomLeft,
  }) : store = store ?? ScheduledRecordings.instance,
       _now = clock ?? DateTime.now,
       _resolve = resolve ?? channelFromPlaylist,
       _pick = pickRecorder ?? recorderFor,
       _pickHls = pickHls ?? (() => hlsRecorder),
       _newFile = newFile ?? ((r) => Recordings.newFile('${r.channel.title} - ${r.title}', owner: r.profile)),
       _keepAlive = keepAlive ?? RecordingKeepAlive.platform,
       _roomLeft = roomLeft ?? recordingsRoom;

  static final instance = RecordingScheduler();

  static const every = Duration(seconds: 20);

  /// The room a recording needs left on the device: with less none starts, and one under way stops
  /// (looked at every minute), keeping what it recorded, rather than fill the device.
  static const minRoom = 500 << 20;

  /// Waits before a recording that could not start is tried again, a little longer each time: not
  /// the whole playlist and the provider asked again every [every].
  static const retryWaits = [Duration(seconds: 30), Duration(minutes: 1), Duration(minutes: 2), Duration(minutes: 4)];

  /// Not known what the platform has: said again.
  static const _unknown = '\u0000';

  final ScheduledRecordings store;
  final DateTime Function() _now;
  final ResolveChannel _resolve;
  final StartRecorder? Function(String url) _pick;
  final StartRecorder? Function() _pickHls;
  final Future<File> Function(ScheduledRecording r) _newFile;
  final RecordingKeepAlive _keepAlive;
  final Future<int?> Function() _roomLeft;
  final _running = <String, ChannelRecorder>{};
  final _starting = <String>{};
  final _tries = <String, int>{}; // starts that failed in a row, by id
  final _retryAt = <String, DateTime>{}; // by id: not tried again before then
  DateTime? _awake; // since when this run of the app has looked: what was over before, it missed closed
  DateTime? _roomSeen; // when the room left was last looked at while recording
  Future<void> _queue = Future.value();
  Timer? _timer;
  // What the keep-alive says and when it wakes the app, to say them only when they change
  String? _shown = _unknown, _wakes = _unknown;
  LiveTap? _tap; // the channel the player plays
  final _tapped = <String>{}; // recording from what the player gets
  final _refused = <String, LiveTap>{}; // let go by the player while still on the channel: not again

  /// The recorder of [id], while it records.
  @visibleForTesting
  ChannelRecorder? recorderOf(String id) => _running[id];

  /// After each change to [_running]: lists refreshed in the background wait while one records.
  void _counted() => recordingsRunning.value = _running.length;

  Future<void> start() async {
    if (_timer != null) return;
    WidgetsBinding.instance.addObserver(this);
    // Closed (with no screen, as the app opens): what records stops, to go on there in the same files
    _keepAlive.listen(onWoken: _onWoken, onStopped: _onStopped, onClose: close);
    _timer = Timer.periodic(every, (_) => check());
    await check();
  }

  /// Stops looking and stops what records, as closing the app would: what was under way goes on
  /// in the same file at the next [start], if its time has not passed.
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    await _serial(() async {
      for (final r in _running.values.toList()) {
        await r.stop();
      }
      _running.clear();
      _counted();
      _tapped.clear();
      await _show();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // In front, Android lets the app start what keeps it running: said again, in case it went
    _shown = _wakes = _unknown;
    unawaited(check());
  }

  /// The wake-up for the next one came: the platform keeps the app running from now on.
  void _onWoken() {
    _shown = _wakes = _unknown;
    unawaited(check());
  }

  /// Android stopped what kept the app running (its time for it used up): started again when
  /// Android lets the app, at the latest once it is in front again.
  void _onStopped() => _shown = null;

  /// The player plays [tap]'s channel now, or (null) none: what records that channel moves to what
  /// the player gets; what recorded through the player goes back to a connection of its own as the
  /// player lets go of it.
  /// A recording from the player ([who], of [channel]) is under way: the app is kept running for it
  /// too, as for a scheduled one, until [playerRecordingEnded]. [onNoRoom] is called when the device
  /// gets too full for it, as scheduled ones stop then.
  void playerRecording(Object who, {required String channel, void Function()? onNoRoom}) {
    _fromPlayer[who] = channel;
    if (onNoRoom != null) _playerNoRoom[who] = onNoRoom;
    unawaited(_serial(_show));
  }

  void playerRecordingEnded(Object who) {
    _playerNoRoom.remove(who);
    if (_fromPlayer.remove(who) != null) unawaited(_serial(_show));
  }

  final _fromPlayer = <Object, String>{}; // recordings from the player, by who records, their channel
  final _playerNoRoom = <Object, void Function()>{};

  /// Whether something records or is still to be recorded: closing the app now would lose it (a
  /// computer's window asks first).
  final busy = ValueNotifier(false);

  /// Whether the device has the room a recording needs ([minRoom]); yes when it does not say.
  Future<bool> hasRoom() async => !await _noRoom();

  void watching(LiveTap? tap) {
    if (tap == _tap) return;
    _tap = tap;
    if (tap != null) unawaited(_serial(_moveToTap));
  }

  /// The player that played [tap]'s channel left it; another may have come meanwhile.
  void left(LiveTap tap) {
    if (_tap == tap) watching(null);
  }

  /// Schedules a programme; one that is on now starts recording at once.
  Future<ScheduledRecording> schedule({
    required String playlistId,
    required MediaRef channel,
    required String title,
    required DateTime start,
    required DateTime end,
  }) async {
    // Android's questions one after the other: notifications, then running unhindered
    unawaited(RecordingKeepAlive.askNotifications().then((_) => RecordingKeepAlive.askBattery()));
    // The profile on screen schedules it: Recordings shows it to that one
    final r = await store.add(
      playlistId: playlistId,
      channel: channel,
      title: title,
      start: start,
      end: end,
      profile: ProfileStore.instance.current.id,
    );
    await check();
    return r;
  }

  /// Cancels one still to come; one under way stops, what it recorded kept; a finished one leaves
  /// the list.
  Future<void> cancel(String id) => _serial(() async {
    final r = store.items.where((x) => x.id == id).firstOrNull;
    if (r == null) return;
    if (r.state == ScheduleState.recording) {
      await _finish(r);
    } else {
      _forget(id);
      await store.remove(id);
    }
    await _show();
  });

  /// Starts what is due and stops what is over.
  Future<void> check() async {
    final starts = <Future<void>>[];
    await _serial(() async {
      await store.load();
      final now = _now();
      _awake ??= now;
      for (final r in store.items) {
        if (!r.pending || _starting.contains(r.id)) continue;
        final running = _running.containsKey(r.id);
        if (!now.isBefore(r.to)) {
          // Over: stopped, or cut short (the app closed, the channel dropped), or never started
          await (running || r.state == ScheduleState.recording || r.file != null ? _finish(r) : _missed(r));
        } else if (!running && !now.isBefore(r.from) && !(_retryAt[r.id]?.isAfter(now) ?? false)) {
          starts.add(_begin(r)); // also one cut short by the app closing: on in the same file
        }
      }
      await _checkRoom(now);
      await _show();
    });
    await Future.wait(starts);
  }

  /// [r] is over and nothing of it was recorded. Not tried at all (nothing said why): the app
  /// looked only after it began, so it was closed; or looked since before, and the device slept.
  Future<void> _missed(ScheduledRecording r) {
    _forget(r.id);
    final why = r.problem ?? (_awake!.isAfter(r.from) ? RecordingProblem.appClosed : RecordingProblem.asleep);
    return store.put(r.copyWith(state: ScheduleState.missed, problem: why));
  }

  /// While something records, the room left is looked at every minute: with less than [minRoom],
  /// what records stops, keeping what it has.
  Future<void> _checkRoom(DateTime now) async {
    if (_running.isEmpty && _playerNoRoom.isEmpty) return;
    // Not again within the minute; a clock set back looks at once
    if (_roomSeen case final seen? when !now.isBefore(seen) && now.difference(seen) < const Duration(minutes: 1)) {
      return;
    }
    _roomSeen = now;
    if (!await _noRoom()) return;
    for (final id in _running.keys.toList()) {
      final recorder = _running.remove(id)!;
      _counted();
      _tapped.remove(id);
      await recorder.stop();
      await _failed(id, RecordingProblem.noSpace);
    }
    for (final stop in _playerNoRoom.values.toList()) {
      stop();
    }
  }

  /// Whether the device has less room left than a recording needs; not when it does not say.
  Future<bool> _noRoom() async {
    try {
      final room = await _roomLeft();
      return room != null && room < minRoom;
    } on Object catch (e) {
      debugPrint('recording scheduler: room left unknown: $e');
      return false;
    }
  }

  /// The room left where recordings go; null when this platform does not say.
  static Future<int?> recordingsRoom() async {
    var dir = await Recordings.folder();
    while (!dir.existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent; // the folder comes with the first recording: the disk it will be on
    }
    return freeBytes(dir.path);
  }

  /// Runs [f] after whatever else changes the recordings, never alongside.
  Future<void> _serial(Future<void> Function() f) => _queue = _queue.then((_) async {
    try {
      await f();
    } on Object catch (e, s) {
      debugPrint('recording scheduler: $e\n$s');
    }
  });

  /// [id], if it is still to be recorded now.
  ScheduledRecording? _current(String id) =>
      store.items.where((x) => x.id == id && x.pending && _now().isBefore(x.to)).firstOrNull;

  /// Whether [r] is to record from what the player gets.
  bool _viaTap(ScheduledRecording r) {
    final tap = _tap;
    return tap != null && tap.playlistId == r.playlistId && tap.channelId == r.channel.id && _refused[r.id] != tap;
  }

  Future<File> _fileOf(ScheduledRecording r) async => r.file != null ? File(r.file!) : await _newFile(r);

  void Function(Object error) _writeError(File file) =>
      (e) => debugPrint('recording scheduler: ${file.path} could not be written: $e');

  Future<void> _begin(ScheduledRecording r) async {
    _starting.add(r.id);
    try {
      // Not started where it would fill the device; tried again, as room may be made meanwhile
      if (await _noRoom()) {
        await _serial(() => _later(r.id, RecordingProblem.noSpace));
        return;
      }
      if (_viaTap(r)) {
        var done = false;
        await _serial(() async => done = await _beginTapped(r.id));
        if (done) return;
      }
      final RecordingTarget? target;
      try {
        target = await _resolve(r);
      } on Object catch (e) {
        debugPrint('recording scheduler: ${r.channel.title} not reachable now, tried again later: $e');
        await _serial(() => _later(r.id, RecordingProblem.noNetwork));
        return;
      }
      await _serial(() async {
        final current = _current(r.id);
        if (current == null) return; // cancelled or over
        final t = target;
        if (t == null) return _failed(current.id, RecordingProblem.channelGone);
        final start = _pick(t.url);
        if (start == null) return _failed(current.id, RecordingProblem.unsupported);
        final file = await _fileOf(current);
        // Marked first: if the app closes now, the next start goes on in this file
        await store.put(current.copyWith(state: ScheduleState.recording, file: file.path, problem: null));
        if (await _open(current.id, start, t, file) case final recorder?) _watch(current.id, recorder, target: t);
      });
    } finally {
      _starting.remove(r.id);
      await _serial(_show);
    }
  }

  /// Starts [start] on [t] into [file] for [id]. Null when it could not now: failed, for a channel
  /// that cannot be recorded; else tried again a little later.
  Future<ChannelRecorder?> _open(String id, StartRecorder start, RecordingTarget t, File file) async {
    try {
      final recorder = await start(t.url, file, headers: t.headers, onWriteError: _writeError(file));
      _forget(id);
      return recorder;
    } on HlsRefused catch (e) {
      await (e.problem == HlsProblem.unreachable
          ? _later(id, RecordingProblem.noNetwork)
          : _failed(id, RecordingProblem.unsupported));
    } on Object catch (e) {
      debugPrint('recording scheduler: $id did not start, tried again later: $e');
      await _later(id, RecordingProblem.noNetwork);
    }
    return null;
  }

  /// [id] could not start now, for [why]: still to come, saying why, and tried again a little later
  /// each time ([retryWaits]). What it recorded before stays its file, to go on in.
  Future<void> _later(String id, RecordingProblem why) async {
    final tries = _tries[id] = (_tries[id] ?? 0) + 1;
    _retryAt[id] = _now().add(retryWaits[min(tries, retryWaits.length) - 1]);
    final r = _current(id);
    if (r != null) await store.put(r.copyWith(state: ScheduleState.scheduled, problem: why));
  }

  void _forget(String id) {
    _tries.remove(id);
    _retryAt.remove(id);
  }

  /// [id] from what the player gets; false when it is to go on a connection of its own instead.
  Future<bool> _beginTapped(String id) async {
    final current = _current(id), tap = _tap;
    if (current == null) return true; // cancelled or over: nothing to do
    if (tap == null || !_viaTap(current)) return false;
    final file = await _fileOf(current);
    await store.put(current.copyWith(state: ScheduleState.recording, file: file.path, problem: null));
    _forget(id);
    final recorder = await tap.recordInto(file, onWriteError: _writeError(file));
    if (recorder == null) {
      _refused[id] = tap;
      return false;
    }
    _tapped.add(id);
    _watch(id, recorder);
    return true;
  }

  /// What records on a connection of its own the channel the player now plays goes on from what the
  /// player gets, in the same file.
  Future<void> _moveToTap() async {
    for (final r in store.items) {
      final recorder = _running[r.id];
      if (recorder == null || _tapped.contains(r.id) || !_viaTap(r)) continue;
      _running.remove(r.id);
      _counted();
      await recorder.stop(); // first: the provider may allow one connection only
      if (!await _beginTapped(r.id)) unawaited(check()); // back on a connection of its own
    }
  }

  void _watch(String id, ChannelRecorder recorder, {RecordingTarget? target, bool hls = false}) {
    _running[id] = recorder;
    _counted();
    unawaited(recorder.done.then((how) => _serial(() => _ended(id, recorder, how, target, hls))));
  }

  /// [recorder] of [id] ended by itself.
  Future<void> _ended(String id, ChannelRecorder recorder, RecorderEnd how, RecordingTarget? target, bool hls) async {
    if (_running[id] != recorder || how == RecorderEnd.stopped) return; // stopped here
    _running.remove(id);
    _counted();
    _tapped.remove(id);
    final r = _current(id);
    final startHls = _pickHls();
    if (r == null) {
      // Over or cancelled meanwhile: finished as any other
    } else if (how == RecorderEnd.released) {
      // The player let go of the channel: on a connection of its own. Let go while still on it
      // (it could not carry it), it is not handed to the player again
      if (_tap case final tap? when tap.playlistId == r.playlistId && tap.channelId == r.channel.id) {
        _refused[id] = tap;
      }
      unawaited(check());
    } else if (how == RecorderEnd.dropped) {
      // The provider stopped giving it for a long while: asked for anew, in the same file
      unawaited(check());
    } else if (how == RecorderEnd.finished) {
      await _finish(r); // the channel ended, written to its end
    } else if (how == RecorderEnd.hls && !hls && target != null && startHls != null) {
      // HLS, as only asking for it showed: the HLS recorder goes on in the same file
      final file = await _fileOf(r);
      if (await _open(id, startHls, target, file) case final hlsRecorder?) {
        _watch(id, hlsRecorder, target: target, hls: true);
      }
    } else if (how == RecorderEnd.writeFailed) {
      await _failed(id, await _noRoom() ? RecordingProblem.noSpace : RecordingProblem.writeFailed);
    } else {
      // A channel no recorder here can write down (any more)
      await _failed(id, RecordingProblem.unsupported);
    }
    await _show();
  }

  /// Stops [r]: recorded if its file has something (in part, still saying why, if it ended while
  /// being tried again), else failed (and the empty file goes).
  Future<void> _finish(ScheduledRecording r) async {
    _forget(r.id);
    _tapped.remove(r.id);
    _refused.remove(r.id);
    final recorder = _running.remove(r.id);
    _counted();
    await recorder?.stop();
    final file = r.file == null ? null : File(r.file!);
    final saved = file != null && file.existsSync() && file.lengthSync() > 0;
    if (!saved && file != null && file.existsSync()) file.deleteSync();
    await store.put(
      saved
          ? r.copyWith(state: ScheduleState.done)
          : r.copyWith(state: ScheduleState.failed, problem: r.problem ?? RecordingProblem.nothingCame),
    );
  }

  /// [id] can go no further, for [why]: what it recorded is kept (recorded in part), else failed.
  Future<void> _failed(String id, RecordingProblem why) async {
    _forget(id);
    _refused.remove(id);
    final r = store.items.where((x) => x.id == id).firstOrNull;
    if (r == null) return;
    final file = r.file == null ? null : File(r.file!);
    final kept = file != null && file.existsSync() && file.lengthSync() > 0;
    if (!kept && file != null && file.existsSync()) file.deleteSync();
    await store.put(r.copyWith(state: kept ? ScheduleState.done : ScheduleState.failed, problem: why));
  }

  /// Keeps the app running while something records or is about to, saying what; and wakes it for
  /// the next one still to come, which the platform may also keep it running for meanwhile.
  Future<void> _show() async {
    busy.value = _fromPlayer.isNotEmpty || store.items.any((r) => r.pending);
    final l = _strings(), now = _now();
    // Recording, or due to: starting, or waiting for the network
    final recording = [
      for (final r in store.items)
        if (_running.containsKey(r.id) || (r.pending && !now.isBefore(r.from) && now.isBefore(r.to))) r,
    ];
    final next = store.items.where((r) => r.state == ScheduleState.scheduled && now.isBefore(r.from)).firstOrNull;

    // Set first: whether the platform keeps the app running until then depends on it
    final wake = next == null ? null : (at: next.from, title: l.recordingChannel(next.channel.title), text: next.title);
    final wakes = wake == null ? null : '${wake.at.millisecondsSinceEpoch}\n${wake.title}\n${wake.text}';
    if (wakes != _wakes) {
      _wakes = wakes;
      await _keepAlive.wakeAt(
        wake?.at,
        title: wake?.title ?? '',
        text: wake?.text ?? '',
        channelName: l.recordings,
        closedText: l.recordingAppClosedNote,
      );
    }

    final ({String title, String text, bool waiting})? say;
    // The player's recordings count too: they are channels as they come, no programme to say
    final channels = [for (final r in recording) r.channel.title, ..._fromPlayer.values];
    if (channels.isNotEmpty) {
      say = (
        title: channels.length == 1 ? l.recordingChannel(channels.single) : l.recordingChannels(channels.length),
        text: [for (final r in recording) r.title, ..._fromPlayer.values].join(' · '),
        waiting: false,
      );
    } else if (next != null) {
      say = (
        title: l.recordingScheduled,
        text: '${next.title} · ${next.channel.title} · ${_when(l, next.from)}',
        waiting: true,
      );
    } else {
      say = null;
    }
    final key = say == null ? null : '${say.waiting}\n${say.title}\n${say.text}';
    if (key == _shown) return;
    if (say == null) {
      _shown = null;
      return _keepAlive.hide();
    }
    final ok = await _keepAlive.show(
      say.title,
      say.text,
      waiting: say.waiting,
      channelName: l.recordings,
      pausedTitle: l.recordingPaused,
      pausedText: l.recordingPausedNote,
    );
    // Android refused it (an app in the background may not start one): asked again later
    _shown = ok ? key : null;
  }

  String _when(AppLocalizations l, DateTime t) {
    final now = _now();
    final today = t.year == now.year && t.month == now.month && t.day == now.day;
    try {
      final clock = clockFormat(l.localeName).format(t);
      return today ? clock : '${DateFormat.MMMEd(l.localeName).format(t)} $clock';
    } on Object {
      return '${t.hour}:${t.minute.toString().padLeft(2, '0')}'; // the language's dates not loaded
    }
  }

  static AppLocalizations _strings() => lookupAppLocalizations(Locale(appLocale.languageCode));

  /// The channel's address now, from its playlist as saved on this device.
  static Future<RecordingTarget?> channelFromPlaylist(ScheduledRecording r) async {
    final playlist = (await PlaylistStore.instance.load()).where((p) => p.id == r.playlistId).firstOrNull;
    if (playlist == null) return null;
    // Xtream gives each channel as one stream (ts) or as HLS: the one stream, which records as it comes
    final source = await playlist.open(liveFormat: 'ts')
      ..hideAdult = false; // it was chosen in the guide
    try {
      return await targetIn(source, r.channel.id);
    } finally {
      switch (source) {
        case final XtreamSource x:
          x.close();
        case final CombinedSource x:
          x.close();
        default:
      }
    }
  }

  /// [channelId]'s address in [source] now, and the headers it needs; null when it has no such
  /// channel. An Xtream panel is asked first what the account allows: one that only allows HLS
  /// refuses the one stream (ts) asked for otherwise.
  @visibleForTesting
  static Future<RecordingTarget?> targetIn(ContentSource source, String channelId) async {
    final panels = switch (source) {
      final XtreamSource x => [x],
      final CombinedSource c => [
        for (final p in c.parts)
          if (p.source case final XtreamSource x) x,
      ],
      _ => const <XtreamSource>[],
    };
    // One that does not answer now keeps the address as it was: its stream says the rest
    await Future.wait([for (final x in panels) x.login().then<void>((_) {}, onError: (Object _) {})]);
    final c = (await source.liveChannels()).where((c) => c.id == channelId).firstOrNull;
    if (c == null) return null;
    final url = source.liveUrl(c);
    return (url: url, headers: source.headersFor(url));
  }
}

/// What keeps the app running while recordings are scheduled or under way. On Android a foreground
/// service (RecordingService.kt) with a notification saying so: without it Android stops or freezes
/// an app in the background. Waiting for one, an exact alarm wakes the app at its time and starts
/// the service; one that comes after Android ended the app says to open it. On Windows the computer
/// is kept from sleeping while something records, and woken for the next one (power.dart). Linux and
/// macOS sleep only when told to. An iPhone stops an app in the background: see [survivesBackground].
class RecordingKeepAlive {
  const RecordingKeepAlive();

  static const platform = RecordingKeepAlive();
  static const _channel = MethodChannel('iptv_player/recording');

  /// Whether the app goes on in the background: not on an iPhone, where a recording (or a live
  /// channel sent to a Chromecast, which the app relays) stops once the app leaves the screen.
  static bool get survivesBackground => !isIOS;

  /// Asks for leave to show notifications, which Android 13 on keeps off until asked: as a
  /// recording is first made, never at start. Not on a TV, which shows none.
  static Future<void> askNotifications() async {
    if (!isAndroid || isTv) return;
    try {
      await _channel.invokeMethod<bool>('askNotifications');
    } on Object {
      // Recorded all the same
    }
  }

  /// Says [title] and [text], keeping the app running; [waiting] for one still to come, which the
  /// platform may leave to the wake-up. [pausedTitle] and [pausedText] say that Android stopped it.
  /// False when Android did not let it start: an app in the background may not.
  Future<bool> show(
    String title,
    String text, {
    required bool waiting,
    required String channelName,
    required String pausedTitle,
    required String pausedText,
  }) async {
    if (isWindows) keepSystemAwake(!waiting); // waiting, the wake-up sees to it
    if (!isAndroid) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('show', {
        'title': title,
        'text': text,
        'waiting': waiting,
        'channel': channelName,
        'pausedTitle': pausedTitle,
        'pausedText': pausedText,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      debugPrint('recording keep-alive: $e');
      return false;
    }
  }

  Future<void> hide() async {
    if (isWindows) keepSystemAwake(false);
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod('hide');
    } on PlatformException catch (e) {
      debugPrint('recording keep-alive: $e');
    }
  }

  static const _batteryAskedKey = 'recordings.batteryAsked';

  /// Asks Android, once, to leave the app out of its battery optimization: a phone that saves
  /// battery hard (several makers' do) could end the app, or hold its wake-up, before a scheduled
  /// recording's time. Asked as the first one is scheduled, after the notifications; not again
  /// once answered, whatever the answer. Not on a TV, which is plugged in.
  static Future<void> askBattery() async {
    if (!isAndroid || isTv) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_batteryAskedKey) ?? false) return;
      await prefs.setBool(_batteryAskedKey, true);
      await _channel.invokeMethod<bool>('askBattery');
    } on Object {
      // Recorded all the same, as far as Android lets it
    }
  }

  /// Wakes the app at [at] to start a recording, saying [title] and [text] from then; null: no
  /// wake-up. [closedText] says to open the app, where the wake-up finds that Android ended it
  /// meanwhile (or the device started again): nothing can record without it.
  Future<void> wakeAt(
    DateTime? at, {
    required String title,
    required String text,
    required String channelName,
    String closedText = '',
  }) async {
    if (isWindows) wakeSystemAt(at);
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod('wakeAt', {
        'at': at?.millisecondsSinceEpoch,
        'title': title,
        'text': text,
        'channel': channelName,
        'closed': closedText,
      });
    } on PlatformException catch (e) {
      debugPrint('recording keep-alive: $e');
    }
  }

  /// [onWoken] when the wake-up came; [onStopped] when Android stopped what kept the app running;
  /// [onClose], recording with no screen ([recordWhileClosed] in main.dart), when the app opens.
  void listen({
    required void Function() onWoken,
    required void Function() onStopped,
    Future<void> Function()? onClose,
  }) {
    if (!isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'woken':
          onWoken();
        case 'stopped':
          onStopped();
        case 'close':
          await onClose?.call();
          return true;
      }
      return null;
    });
  }

  /// As the app opens, before its scheduler starts: what records with no screen (Android ended the
  /// app and woke it for a recording) stops and goes, to go on here in the same files. True when
  /// there was one: what it wrote in the preferences is to be read again.
  static Future<bool> takeOver() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('takeOver').timeout(const Duration(seconds: 20)) ?? false;
    } on Object catch (e) {
      debugPrint('recording keep-alive: $e');
      return false;
    }
  }
}
