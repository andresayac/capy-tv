// Recordings scheduled from the guide: started and stopped on time with a fake clock and a fake
// recorder, kept across app starts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/scheduled_recordings.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:iptv_player/player/background_recorder.dart';
import 'package:iptv_player/player/hls_recorder.dart';
import 'package:iptv_player/player/recording_scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Writes a few bytes when it starts, so it has recorded something; [fail] ends it as a disk that
/// filled up would.
class _FakeRecorder implements ChannelRecorder {
  _FakeRecorder(this.url, this.file, this.headers) {
    file.writeAsBytesSync([1, 2, 3], mode: FileMode.append);
  }

  final String url;
  final File file;
  final Map<String, String> headers;
  final _done = Completer<RecorderEnd>();
  var stopped = false;

  @override
  int get bytes => 3;

  @override
  Future<RecorderEnd> get done => _done.future;

  @override
  Future<void> stop() async {
    stopped = true;
    if (!_done.isCompleted) _done.complete(RecorderEnd.stopped);
  }

  void fail() => _done.complete(RecorderEnd.writeFailed);

  /// Ends by itself: as an HLS channel, or as the player letting go.
  void end(RecorderEnd how) => _done.complete(how);
}

/// The notification's title each time it changes, null once hidden; and the wake-ups set.
class _FakeKeepAlive implements RecordingKeepAlive {
  final said = <String?>[];
  final waiting = <bool>[];
  final wakes = <DateTime?>[];
  var allowed = true; // Android lets it start
  late void Function() woken, stopped;

  @override
  Future<bool> show(
    String title,
    String text, {
    required bool waiting,
    required String channelName,
    required String pausedTitle,
    required String pausedText,
  }) async {
    if (!allowed) return false;
    said.add(title);
    this.waiting.add(waiting);
    return true;
  }

  @override
  Future<void> hide() async => said.add(null);

  @override
  Future<void> wakeAt(
    DateTime? at, {
    required String title,
    required String text,
    required String channelName,
    String closedText = '',
  }) async => wakes.add(at);

  @override
  void listen({
    required void Function() onWoken,
    required void Function() onStopped,
    Future<void> Function()? onClose,
  }) {
    woken = onWoken;
    stopped = onStopped;
  }
}

/// The player on a channel: what records it from what the player gets.
class _FakeTap implements LiveTap {
  _FakeTap(this.channelId);

  @override
  String get playlistId => 'p1';
  @override
  final String channelId;
  final recorders = <_FakeRecorder>[];
  var refuse = false; // cannot carry it (HLS)

  @override
  Future<ChannelRecorder?> recordInto(File file, {void Function(Object error)? onWriteError}) async {
    if (refuse) return null;
    final r = _FakeRecorder('player', file, const {});
    recorders.add(r);
    return r;
  }
}

const _a = MediaRef(kind: MediaKind.live, id: '7', title: 'Channel A', url: 'http://host/u/p/7.ts', epgId: 'a.tv');
const _b = MediaRef(kind: MediaKind.live, id: '8', title: 'Channel B');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late DateTime now;
  late List<_FakeRecorder> recorders;
  late _FakeKeepAlive keepAlive;
  late Map<String, Object?> targets; // channel id → its address, null when gone, or an error to throw
  late List<_FakeRecorder> hlsRecorders;
  late bool hlsKnown; // a recorder for HLS is set
  Object? hlsRefusal; // what the HLS recorder throws as it starts, if anything
  int? room; // what the device has left; null: it does not say
  final store = ScheduledRecordings.instance;

  RecordingScheduler scheduler() => RecordingScheduler(
    clock: () => now,
    resolve: (r) async => switch (targets[r.channel.id]) {
      final String url => (url: url, headers: {'User-Agent': 'Agent/${r.channel.id}'}),
      final Exception e => throw e,
      _ => null,
    },
    pickRecorder: (url) => isHlsUrl(url)
        ? null
        : (url, file, {headers = const {}, onWriteError}) async {
            final r = _FakeRecorder(url, file, headers);
            recorders.add(r);
            return r;
          },
    pickHls: () => !hlsKnown
        ? null
        : (url, file, {headers = const {}, onWriteError}) async {
            if (hlsRefusal case final e?) throw e;
            final r = _FakeRecorder(url, file, headers);
            hlsRecorders.add(r);
            return r;
          },
    newFile: (r) async => File('${dir.path}/${r.channel.id}-${r.id}.ts'),
    keepAlive: keepAlive,
    roomLeft: () async => room,
  );

  /// Schedules [channel] from 19:00 to 21:00, on now (20:00).
  Future<void> onNow(RecordingScheduler s, MediaRef channel) => s.schedule(
    playlistId: 'p1',
    channel: channel,
    title: 'Show',
    start: DateTime(2026, 11, 7, 19),
    end: DateTime(2026, 11, 7, 21),
  );

  ScheduledRecording only() => store.items.single;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.reset();
    dir = Directory.systemTemp.createTempSync('schedule');
    now = DateTime(2026, 11, 7, 20);
    recorders = [];
    keepAlive = _FakeKeepAlive();
    hlsRecorders = [];
    hlsKnown = false;
    hlsRefusal = null;
    room = null;
    targets = {'7': 'http://host/live/u/p/7.ts', '8': 'http://host/live/u/p/8.ts'};
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('records from a minute early to two minutes late, from the address made at that time', () async {
    final s = scheduler();
    await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'News',
      start: DateTime(2026, 11, 7, 21),
      end: DateTime(2026, 11, 7, 22),
    );
    expect(only().state, ScheduleState.scheduled);
    expect(keepAlive.said, ['Recording scheduled']);
    expect(keepAlive.waiting, [true], reason: 'which the platform may leave to the wake-up');
    expect(keepAlive.wakes, [DateTime(2026, 11, 7, 20, 59)]);

    now = DateTime(2026, 11, 7, 20, 58, 59);
    await s.check();
    expect(recorders, isEmpty);

    now = DateTime(2026, 11, 7, 20, 59);
    await s.check();
    expect(recorders, hasLength(1));
    expect(recorders.single.url, 'http://host/live/u/p/7.ts');
    expect(recorders.single.headers, {'User-Agent': 'Agent/7'});
    expect(only().state, ScheduleState.recording);
    expect(only().file, recorders.single.file.path);
    expect(keepAlive.said.last, 'Recording Channel A');
    expect(keepAlive.waiting.last, isFalse);
    expect(keepAlive.wakes.last, isNull, reason: 'nothing more to wake the app for');

    now = DateTime(2026, 11, 7, 22, 1, 59);
    await s.check();
    expect(recorders.single.stopped, isFalse);

    now = DateTime(2026, 11, 7, 22, 2);
    await s.check();
    expect(recorders.single.stopped, isTrue);
    expect(only().state, ScheduleState.done);
    expect(File(only().file!).lengthSync(), 3);
    expect(keepAlive.said.last, isNull, reason: 'nothing left to keep the app running for');
    await s.close();
  });

  test("the player's own recordings keep the app running too, said until they end", () async {
    final sched = scheduler();
    final player = Object();
    sched.playerRecording(player, channel: 'News 24');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(keepAlive.said.last, 'Recording News 24');
    expect(keepAlive.waiting.last, isFalse);
    sched.playerRecordingEnded(player);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(keepAlive.said.last, isNull, reason: 'nothing records any more');
  });

  test('one on now starts at once', () async {
    final s = scheduler();
    await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'Match',
      start: DateTime(2026, 11, 7, 19, 30),
      end: DateTime(2026, 11, 7, 21),
    );
    expect(recorders, hasLength(1));
    expect(only().state, ScheduleState.recording);
    await s.close();
  });

  test('one whose time passed with the app closed is missed; one cut short keeps what it has', () async {
    await store.add(
      playlistId: 'p1',
      channel: _a,
      title: 'Earlier',
      start: DateTime(2026, 11, 7, 17),
      end: DateTime(2026, 11, 7, 18),
    );
    final cut = await store.add(
      playlistId: 'p1',
      channel: _b,
      title: 'Cut short',
      start: DateTime(2026, 11, 7, 18),
      end: DateTime(2026, 11, 7, 19),
    );
    final file = File('${dir.path}/cut.ts')..writeAsBytesSync([1]);
    await store.put(cut.copyWith(state: ScheduleState.recording, file: file.path));
    final s = scheduler();
    await s.start();
    expect([for (final r in store.items) r.state], [ScheduleState.missed, ScheduleState.done]);
    expect(store.items.first.problem, RecordingProblem.appClosed);
    expect(store.items.last.problem, isNull);
    expect(recorders, isEmpty);
    await s.close();

    // Said again after the app starts anew
    store.reset();
    await store.load();
    expect(store.items.first.problem, RecordingProblem.appClosed);
  });

  test('one whose time passed with the app open and nothing tried is missed as the device asleep', () async {
    final s = scheduler();
    await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'Night',
      start: DateTime(2026, 11, 7, 23),
      end: DateTime(2026, 11, 8, 1),
    );
    now = DateTime(2026, 11, 8, 7); // the clock went on while the device slept: no check in between
    await s.check();
    expect(only().state, ScheduleState.missed);
    expect(only().problem, RecordingProblem.asleep, reason: 'not "the app was closed": it was open');
    await s.close();
  });

  test('cancelled before it starts it never records; cancelled while it records it stops and keeps it', () async {
    final s = scheduler();
    final later = await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'Later',
      start: DateTime(2026, 11, 7, 22),
      end: DateTime(2026, 11, 7, 23),
    );
    await s.cancel(later.id);
    expect(store.items, isEmpty);
    now = DateTime(2026, 11, 7, 22, 30);
    await s.check();
    expect(recorders, isEmpty);

    final on = await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'On now',
      start: DateTime(2026, 11, 7, 22),
      end: DateTime(2026, 11, 7, 23),
    );
    expect(recorders.single.stopped, isFalse);
    await s.cancel(on.id);
    expect(recorders.single.stopped, isTrue);
    expect(only().state, ScheduleState.done);

    await s.cancel(on.id); // a finished one leaves the list
    expect(store.items, isEmpty);
    expect(File(on.file ?? recorders.single.file.path).existsSync(), isTrue, reason: 'the file stays');
    await s.close();
  });

  test('overlapping ones each record, each on its own', () async {
    final s = scheduler();
    await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'A',
      start: DateTime(2026, 11, 7, 21),
      end: DateTime(2026, 11, 7, 22),
    );
    await s.schedule(
      playlistId: 'p1',
      channel: _b,
      title: 'B',
      start: DateTime(2026, 11, 7, 21, 30),
      end: DateTime(2026, 11, 7, 22, 30),
    );
    await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'A again',
      start: DateTime(2026, 11, 7, 21, 45),
      end: DateTime(2026, 11, 7, 22, 15),
    );
    now = DateTime(2026, 11, 7, 21, 50);
    await s.check();
    expect(recorders, hasLength(3));
    expect({for (final r in recorders) r.file.path}, hasLength(3));
    expect(keepAlive.said.last, 'Recording 3 channels');
    now = DateTime(2026, 11, 7, 22, 3);
    await s.check();
    expect([for (final r in recorders) r.stopped], [true, false, false]);
    await s.close();
  });

  test('the margins chosen go with what is scheduled from then on; one kept from before has the old ones', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('recordEarly', 5);
    await prefs.setInt('recordLate', 30);
    await scheduler().schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'Match',
      start: DateTime(2026, 11, 7, 21),
      end: DateTime(2026, 11, 7, 23),
    );
    expect(only().from, DateTime(2026, 11, 7, 20, 55));
    expect(only().to, DateTime(2026, 11, 7, 23, 30));

    // Kept by a version before the margins: none in it
    final kept = (jsonDecode(prefs.getString('scheduledRecordings')!) as List).cast<Map<String, dynamic>>();
    await prefs.setString(
      'scheduledRecordings',
      jsonEncode([
        kept.single
          ..remove('early')
          ..remove('late'),
      ]),
    );
    store.reset();
    await store.load();
    expect(only().from, DateTime(2026, 11, 7, 20, 59));
    expect(only().to, DateTime(2026, 11, 7, 23, 2));
  });

  test('one kept entry that cannot be read loses that one alone, not those after it', () async {
    await scheduler().schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'Film',
      start: DateTime(2026, 11, 7, 21),
      end: DateTime(2026, 11, 7, 22),
    );
    final prefs = await SharedPreferences.getInstance();
    final kept = jsonDecode(prefs.getString('scheduledRecordings')!) as List;
    await prefs.setString(
      'scheduledRecordings',
      jsonEncode([
        {'id': 'broken'},
        ...kept,
      ]),
    );
    store.reset();
    await store.load();
    expect(only().title, 'Film');
  });

  test('kept across app starts: what was under way goes on in the same file', () async {
    final s = scheduler();
    await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'Film',
      start: DateTime(2026, 11, 7, 19),
      end: DateTime(2026, 11, 7, 21),
    );
    final first = only();
    await s.close(); // the app closes
    expect(recorders.single.stopped, isTrue);

    store.reset(); // and starts again
    await store.load();
    final back = only();
    expect(back.id, first.id);
    expect(back.playlistId, 'p1');
    expect(back.channel.id, '7');
    expect(back.channel.title, 'Channel A');
    expect(back.channel.epgId, 'a.tv');
    expect(back.channel.url, isNull, reason: 'the address may carry the account: never kept');
    expect(back.title, 'Film');
    expect(back.start, first.start);
    expect(back.end, first.end);
    expect(back.state, ScheduleState.recording);
    expect(back.file, first.file);
    final raw = (await SharedPreferences.getInstance()).getString('scheduledRecordings')!;
    expect(raw, isNot(contains('http')));

    now = DateTime(2026, 11, 7, 20, 30);
    final again = scheduler();
    await again.start();
    expect(recorders, hasLength(2));
    expect(recorders.last.file.path, first.file);
    expect(File(first.file!).lengthSync(), 6, reason: 'after what it had');
    await again.close();
  });

  test('a channel that cannot be had now is tried again a little later; one that is gone, or HLS, fails', () async {
    targets['7'] = Exception('no network');
    final s = scheduler();
    await onNow(s, _a);
    expect(recorders, isEmpty);
    expect(only().state, ScheduleState.scheduled);
    expect(only().problem, RecordingProblem.noNetwork, reason: 'said while it is tried again');
    targets['7'] = 'http://host/live/u/p/7.ts';
    await s.check();
    expect(recorders, isEmpty, reason: 'not the playlist and the provider asked again every 20 seconds');
    now = now.add(RecordingScheduler.retryWaits.first);
    await s.check();
    expect(recorders, hasLength(1));
    expect(only().state, ScheduleState.recording);
    expect(only().problem, isNull);

    targets['8'] = null;
    await onNow(s, _b);
    expect(store.items.last.state, ScheduleState.failed);
    expect(store.items.last.problem, RecordingProblem.channelGone);

    targets['8'] = 'http://host/live/u/p/8.m3u8';
    await onNow(s, _b);
    expect(store.items.last.state, ScheduleState.failed);
    expect(store.items.last.problem, RecordingProblem.unsupported);
    expect(recorders, hasLength(1));
    await s.close();
  });

  test('each try that fails waits longer before the next, up to a few minutes', () async {
    targets['7'] = Exception('no network');
    final s = scheduler();
    await onNow(s, _a);
    final tried = <DateTime>[];
    final start = now;
    var calls = 0;
    // Looked at every 20 seconds for a quarter of an hour, as the app does
    for (var t = Duration.zero; t < const Duration(minutes: 15); t += RecordingScheduler.every) {
      now = start.add(t);
      final before = store.items.single;
      await s.check();
      calls++;
      if (!identical(store.items.single, before)) tried.add(now);
    }
    final gaps = [for (var i = 1; i < tried.length; i++) tried[i].difference(tried[i - 1])];
    expect(gaps.take(4), [
      for (final w in RecordingScheduler.retryWaits.skip(1)) predicate<Duration>((g) => g >= w, 'at least $w'),
      predicate<Duration>((g) => g >= RecordingScheduler.retryWaits.last, 'no shorter'),
    ]);
    expect(tried.length, lessThan(calls ~/ 3), reason: 'far fewer tries than looks');
    await s.close();
  });

  test('a recording whose file cannot be written further stops, keeping what it has, and says why', () async {
    final s = scheduler();
    await onNow(s, _a);
    recorders.single.fail();
    await pumpEventQueue();
    await s.check();
    expect(only().state, ScheduleState.done, reason: 'recorded in part');
    expect(only().problem, RecordingProblem.writeFailed);
    expect(File(only().file!).lengthSync(), 3);
    expect(recorders, hasLength(1), reason: 'not started again');

    // The disk being full is what it says, when the device says so
    room = 1 << 20;
    await onNow(s, _b);
    room = null;
    expect(store.items.last.state, ScheduleState.scheduled, reason: 'not started with no room');
    expect(store.items.last.problem, RecordingProblem.noSpace);
    expect(recorders, hasLength(1));
    await s.close();
  });

  test('with the device near full a recording under way stops within the minute, keeping what it has', () async {
    final s = scheduler();
    room = RecordingScheduler.minRoom * 4;
    await onNow(s, _a);
    expect(only().state, ScheduleState.recording);
    await s.check(); // the room looked at: plenty
    room = RecordingScheduler.minRoom - 1;
    now = now.add(const Duration(seconds: 20));
    await s.check();
    expect(recorders.single.stopped, isFalse, reason: 'looked at once a minute');
    now = now.add(const Duration(minutes: 1));
    await s.check();
    expect(recorders.single.stopped, isTrue);
    expect(only().state, ScheduleState.done);
    expect(only().problem, RecordingProblem.noSpace);
    expect(File(only().file!).lengthSync(), 3);
    now = now.add(const Duration(minutes: 5));
    await s.check();
    expect(recorders, hasLength(1), reason: 'not started again to fill the device');
    await s.close();
  });

  test('busy while something is still to be recorded or records, the player\'s own too', () async {
    final s = scheduler();
    await s.check();
    expect(s.busy.value, isFalse);
    await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'Later',
      start: DateTime(2026, 11, 7, 22),
      end: DateTime(2026, 11, 7, 23),
    );
    expect(s.busy.value, isTrue, reason: 'closing the app now would miss it');
    await s.cancel(only().id);
    expect(s.busy.value, isFalse);
    final player = Object();
    s.playerRecording(player, channel: 'Channel A');
    await pumpEventQueue();
    expect(s.busy.value, isTrue);
    s.playerRecordingEnded(player);
    await pumpEventQueue();
    expect(s.busy.value, isFalse);
    await s.close();
  });

  test("the player's own recording is told to stop too when the device gets nearly full", () async {
    final s = scheduler();
    var told = 0;
    final player = Object();
    room = RecordingScheduler.minRoom * 4;
    expect(await s.hasRoom(), isTrue);
    s.playerRecording(player, channel: 'Channel A', onNoRoom: () => told++);
    await s.check();
    room = RecordingScheduler.minRoom - 1;
    expect(await s.hasRoom(), isFalse, reason: 'the player does not start one then');
    now = now.add(const Duration(minutes: 1));
    await s.check();
    expect(told, 1);
    s.playerRecordingEnded(player);
    now = now.add(const Duration(minutes: 1));
    await s.check();
    expect(told, 1, reason: 'ended: not told again');
    await s.close();
  });

  test(
    'an HLS recording the provider stops giving is asked for anew in the same file; one that ends is done',
    () async {
      hlsKnown = true;
      targets['7'] = 'http://host/live/u/p/7.ts';
      final s = scheduler();
      await onNow(s, _a);
      recorders.single.end(RecorderEnd.hls);
      await pumpEventQueue();
      final file = only().file;
      hlsRecorders.single.end(RecorderEnd.dropped);
      await pumpEventQueue();
      await s.check();
      expect(recorders, hasLength(2), reason: 'asked for anew rather than left saying "recording"');
      expect(recorders.last.file.path, file);
      expect(only().state, ScheduleState.recording);

      recorders.last.end(RecorderEnd.hls);
      await pumpEventQueue();
      hlsRecorders.last.end(RecorderEnd.finished);
      await pumpEventQueue();
      expect(only().state, ScheduleState.done);
      expect(only().problem, isNull);
      await s.close();
    },
  );

  test('an HLS channel that cannot be recorded fails at once, not tried every 20 seconds', () async {
    hlsKnown = true;
    hlsRefusal = const HlsRefused(HlsProblem.encrypted);
    final s = scheduler();
    await onNow(s, _a);
    File(only().file!).writeAsBytesSync(const []); // an HLS answer writes nothing
    recorders.single.end(RecorderEnd.hls);
    await pumpEventQueue();
    expect(only().state, ScheduleState.failed);
    expect(only().problem, RecordingProblem.unsupported);
    now = now.add(const Duration(minutes: 5));
    await s.check();
    expect(recorders, hasLength(1));

    // One that cannot be had now: still to come, tried again later
    hlsRefusal = const HlsRefused(HlsProblem.unreachable);
    await onNow(s, _b);
    recorders.last.end(RecorderEnd.hls);
    await pumpEventQueue();
    expect(store.items.last.state, ScheduleState.scheduled);
    expect(store.items.last.problem, RecordingProblem.noNetwork);
    hlsRefusal = null;
    now = now.add(RecordingScheduler.retryWaits.first);
    await s.check();
    expect(store.items.last.state, ScheduleState.recording);
    await s.close();
  });

  test('an Xtream account that allows HLS only is recorded as HLS', () async {
    Future<String?> urlFor(List<String> formats) async {
      final source = XtreamSource(
        server: 'http://panel.example/',
        username: 'u',
        password: 'p',
        client: MockClient((req) async {
          final body = switch (req.url.queryParameters['action']) {
            null => {
              'user_info': {'auth': 1, 'status': 'Active', 'allowed_output_formats': formats},
            },
            'get_live_streams' => [
              {'stream_id': 7, 'name': 'Channel A', 'category_id': '1'},
            ],
            _ => <Object>[],
          };
          return http.Response(jsonEncode(body), 200);
        }),
      )..hideAdult = false;
      return (await RecordingScheduler.targetIn(source, '7'))?.url;
    }

    expect(await urlFor(['m3u8']), endsWith('/7.m3u8'));
    expect(await urlFor(['ts', 'm3u8']), endsWith('/7.ts'));
  });

  test(
    'what keeps the app running is asked for again when Android refused it, stopped it, or the app is back',
    () async {
      final s = scheduler();
      await s.start();
      keepAlive.allowed = false; // in the background: Android does not let it start
      await s.schedule(
        playlistId: 'p1',
        channel: _a,
        title: 'Show',
        start: DateTime(2026, 11, 7, 19),
        end: DateTime(2026, 11, 7, 21),
      );
      expect(keepAlive.said, [null]);
      keepAlive.allowed = true;
      await s.check();
      expect(keepAlive.said, [null, 'Recording Channel A'], reason: 'not taken as said while refused');

      keepAlive.stopped(); // Android 15's time for it used up
      await s.check();
      expect(keepAlive.said, [null, 'Recording Channel A', 'Recording Channel A']);

      s.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(keepAlive.said, hasLength(4), reason: 'in front again: said again, in case it went');
      await s.close();
    },
  );

  test('woken at its time, it starts at once', () async {
    final s = scheduler();
    await s.start();
    await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'News',
      start: DateTime(2026, 11, 7, 21),
      end: DateTime(2026, 11, 7, 22),
    );
    now = DateTime(2026, 11, 7, 20, 59);
    keepAlive.woken();
    await pumpEventQueue();
    expect(recorders, hasLength(1));
    expect(keepAlive.said.last, 'Recording Channel A');
    await s.close();
  });

  test('a channel found to be HLS once asked for goes on with the HLS recorder, or fails without one', () async {
    hlsKnown = true;
    final s = scheduler();
    await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'Show',
      start: DateTime(2026, 11, 7, 19),
      end: DateTime(2026, 11, 7, 21),
    );
    recorders.single.end(RecorderEnd.hls);
    await pumpEventQueue();
    expect(only().state, ScheduleState.recording);
    expect(hlsRecorders.single.url, 'http://host/live/u/p/7.ts');
    expect(hlsRecorders.single.file.path, only().file);
    expect(hlsRecorders.single.headers, {'User-Agent': 'Agent/7'});

    hlsKnown = false;
    await s.schedule(
      playlistId: 'p1',
      channel: _b,
      title: 'Other',
      start: DateTime(2026, 11, 7, 19),
      end: DateTime(2026, 11, 7, 21),
    );
    File(store.items.last.file!).writeAsBytesSync(const []); // an HLS answer writes nothing
    recorders.last.end(RecorderEnd.hls);
    await pumpEventQueue();
    expect(store.items.last.state, ScheduleState.failed);
    expect(store.items.last.problem, RecordingProblem.unsupported);
    await s.close();
  });

  test('the channel the player plays records from what the player gets, on its own once the player lets go', () async {
    final s = scheduler();
    final tap = _FakeTap('7');
    s.watching(tap);
    await s.schedule(
      playlistId: 'p1',
      channel: _a,
      title: 'Match',
      start: DateTime(2026, 11, 7, 19),
      end: DateTime(2026, 11, 7, 21),
    );
    expect(tap.recorders, hasLength(1));
    expect(recorders, isEmpty, reason: 'no second connection to the provider');
    final file = only().file!;
    expect(tap.recorders.single.file.path, file);

    // The player goes to another channel: its relay lets go of this one
    s.watching(_FakeTap('9'));
    tap.recorders.single.end(RecorderEnd.released);
    await pumpEventQueue();
    expect(recorders, hasLength(1));
    expect(recorders.single.file.path, file);
    expect(only().state, ScheduleState.recording);

    // And comes back to it: the recording moves to it, the connection of its own let go first
    final back = _FakeTap('7');
    s.watching(back);
    await pumpEventQueue();
    expect(recorders.single.stopped, isTrue);
    expect(back.recorders, hasLength(1));
    expect(File(file).lengthSync(), 9, reason: 'all in the same file');

    // Let go while still on it (it could not carry it): on its own, not handed back to it
    back.recorders.single.end(RecorderEnd.released);
    await pumpEventQueue();
    await s.check();
    expect(recorders, hasLength(2));
    expect(back.recorders, hasLength(1));

    // Another channel records on its own; one the player cannot carry stays so
    await s.schedule(
      playlistId: 'p1',
      channel: _b,
      title: 'Other',
      start: DateTime(2026, 11, 7, 19),
      end: DateTime(2026, 11, 7, 21),
    );
    expect(recorders, hasLength(3));
    final hls = _FakeTap('8')..refuse = true;
    s.watching(hls);
    await pumpEventQueue();
    expect(recorders, hasLength(4), reason: 'back on a connection of its own');
    expect(recorders[2].stopped, isTrue);

    now = DateTime(2026, 11, 7, 21, 2);
    await s.check();
    expect([for (final r in store.items) r.state], [ScheduleState.done, ScheduleState.done]);
    await s.close();
  });
}
