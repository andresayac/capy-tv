// The guide's programme sheet: Record schedules a programme, Cancel takes it back.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/scheduled_recordings.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/player/recording_scheduler.dart';
import 'package:iptv_player/ui/guide_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Quiet implements RecordingKeepAlive {
  @override
  Future<bool> show(
    String title,
    String text, {
    required bool waiting,
    required String channelName,
    required String pausedTitle,
    required String pausedText,
  }) async => true;

  @override
  Future<void> hide() async {}

  @override
  Future<void> wakeAt(
    DateTime? at, {
    required String title,
    required String text,
    required String channelName,
    String closedText = '',
  }) async {}

  @override
  void listen({
    required void Function() onWoken,
    required void Function() onStopped,
    Future<void> Function()? onClose,
  }) {}
}

Widget _sheet(EpgEntry e, {String? playlistId = 'p1', required RecordingScheduler scheduler}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: ProgrammeSheet(
      channel: const LiveChannel(id: '7', name: 'Channel A'),
      entry: e,
      playlistId: playlistId,
      scheduler: scheduler,
    ),
  ),
);

void main() {
  final store = ScheduledRecordings.instance;
  // Made in each test, in its zone: its queue of changes runs on the test's clock
  RecordingScheduler newScheduler() => RecordingScheduler(resolve: (_) async => null, keepAlive: _Quiet());

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.reset();
  });

  testWidgets('Record schedules a programme still to come; Cancel takes it back', (t) async {
    final scheduler = newScheduler();
    final start = DateTime.now().add(const Duration(hours: 2));
    await t.pumpWidget(
      _sheet(
        EpgEntry(title: 'News', start: start, end: start.add(const Duration(hours: 1))),
        scheduler: scheduler,
      ),
    );
    expect(find.text('Cancel recording'), findsNothing);
    await t.tap(find.text('Record'));
    await t.pumpAndSettle();
    final r = store.items.single;
    expect((r.playlistId, r.channel.id, r.title, r.start), ('p1', '7', 'News', start));
    expect(r.state, ScheduleState.scheduled);
    expect(find.textContaining('Recording starts at'), findsOneWidget);
    expect(find.textContaining('If it is closed at that time'), findsOneWidget, reason: 'honest about when it records');

    // Asked first: an OK too many keeps it
    await t.tap(find.text('Cancel recording'));
    await t.pumpAndSettle();
    expect(find.text('Cancel this scheduled recording?'), findsOneWidget);
    await t.tap(find.text('Keep it'));
    await t.pumpAndSettle();
    expect(store.items, hasLength(1));

    await t.tap(find.text('Cancel recording'));
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel recording').last); // the dialog's
    await t.pumpAndSettle();
    expect(store.items, isEmpty);
    expect(find.text('Record'), findsOneWidget);
  });

  testWidgets('a programme that ended, or with no playlist known, has nothing to record', (t) async {
    final scheduler = newScheduler();
    final start = DateTime.now().subtract(const Duration(hours: 3));
    await t.pumpWidget(
      _sheet(
        EpgEntry(title: 'Old', start: start, end: start.add(const Duration(hours: 1))),
        scheduler: scheduler,
      ),
    );
    expect(find.text('Old'), findsOneWidget);
    expect(find.text('Record'), findsNothing);

    final later = DateTime.now().add(const Duration(hours: 1));
    await t.pumpWidget(
      _sheet(
        EpgEntry(title: 'Later', start: later, end: later.add(const Duration(hours: 1))),
        playlistId: null,
        scheduler: scheduler,
      ),
    );
    expect(find.text('Record'), findsNothing);
  });
}
