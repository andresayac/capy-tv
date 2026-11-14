// The Recordings screen: a recording still being written is not offered as a finished file, and
// cancelling or stopping a scheduled one asks first.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/recordings.dart';
import 'package:iptv_player/data/scheduled_recordings.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/player/recording_scheduler.dart';
import 'package:iptv_player/ui/common.dart';
import 'package:iptv_player/ui/recordings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

const _channel = MediaRef(kind: MediaKind.live, id: '7', title: 'Channel A');

void main() {
  late Directory dir;
  final store = ScheduledRecordings.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.reset();
    Recordings.folderForTests = dir = Directory.systemTemp.createTempSync('recordings');
  });
  tearDown(() {
    Recordings.folderForTests = null;
    dir.deleteSync(recursive: true);
  });

  /// One scheduled recording, recording now into a file of its own, and one finished file.
  Future<(File, File)> twoFiles(WidgetTester t) async {
    final now = DateTime.now();
    final writing = await t.runAsync(() => Recordings.newFile('Channel A - Match', now: now))
      ?..writeAsBytesSync([1, 2, 3]);
    final done =
        await t.runAsync(() => Recordings.newFile('Channel B - News', now: now.subtract(const Duration(days: 1))))
          ?..writeAsBytesSync([4, 5, 6]);
    final r = await t.runAsync(
      () => store.add(
        playlistId: 'p1',
        channel: _channel,
        title: 'Match',
        start: now.subtract(const Duration(minutes: 10)),
        end: now.add(const Duration(hours: 1)),
      ),
    );
    await t.runAsync(() => store.put(r!.copyWith(state: ScheduleState.recording, file: writing!.path)));
    return (writing!, done!);
  }

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(_app(RecordingsScreen(scheduler: RecordingScheduler())));
    for (var i = 0; i < 5; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
  }

  testWidgets('a recording still being written has its row to stop it, not a file to play or delete', (t) async {
    await twoFiles(t);
    await open(t);
    expect(find.text('Match'), findsOneWidget, reason: 'its scheduled row');
    expect(find.text('Channel A - Match'), findsNothing, reason: 'not listed as a file while it is written');
    expect(find.text('Channel B - News'), findsOneWidget);
    expect(find.byTooltip('Delete'), findsOneWidget, reason: 'only the finished file');
  });

  testWidgets('stopping a recording under way asks first, keeping it is where the focus is', (t) async {
    await twoFiles(t);
    await open(t);
    await t.tap(find.text('Stop recording'));
    await t.pump();
    expect(find.text('Stop this recording? What was recorded is kept.'), findsOneWidget);
    final keep = find.widgetWithText(SecondaryButton, 'Keep it');
    expect(keep, findsOneWidget);
    await t.tap(keep);
    await t.pump();
    await t.pump();
    expect(store.items.single.state, ScheduleState.recording, reason: 'an OK too many keeps it');
  });

  testWidgets('cancelling one still to come asks first too', (t) async {
    final now = DateTime.now();
    await t.runAsync(
      () => store.add(
        playlistId: 'p1',
        channel: _channel,
        title: 'Later',
        start: now.add(const Duration(hours: 2)),
        end: now.add(const Duration(hours: 3)),
      ),
    );
    await open(t);
    await t.tap(find.text('Cancel'));
    await t.pump();
    expect(find.text('Cancel this scheduled recording?'), findsOneWidget);
    await t.tap(find.widgetWithText(PrimaryButton, 'Cancel recording'));
    await t.pump();
    for (var i = 0; i < 3; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    expect(store.items, isEmpty);
  });
}
