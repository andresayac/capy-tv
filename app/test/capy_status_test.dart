// Capy in the app's states: which mood a failure gets, what moves and for how long, the still
// drawing on a 1 GB device or with animations off, and the places that show it.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/recordings.dart';
import 'package:iptv_player/data/scheduled_recordings.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/player/recording_scheduler.dart';
import 'package:iptv_player/ui/catalog.dart';
import 'package:iptv_player/ui/common.dart';
import 'package:iptv_player/ui/recordings_screen.dart';
import 'package:iptv_player/ui/search_tab.dart';
import 'package:iptv_player/ui/sync_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_test.dart' show FakeSource;

Widget _app(Widget home, {bool reduced = false}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: home,
    ),
  ),
);

Widget _capy(CapyMood mood, {bool reduced = false}) => _app(
  Scaffold(
    body: Center(child: CapyStatus(mood: mood)),
  ),
  reduced: reduced,
);

/// The animated drawing Capy shows, or null when it shows none.
String? _animated(WidgetTester t) {
  final image = find.descendant(of: find.byType(CapyStatus), matching: find.byType(Image));
  if (image.evaluate().isEmpty) return null;
  return (t.widget<Image>(image).image as AssetImage).assetName;
}

/// Whether the still drawing is the one seen.
bool _stillSeen(WidgetTester t) {
  final svg = find.descendant(of: find.byType(CapyStatus), matching: find.byType(SvgPicture));
  return t.widget<Opacity>(find.ancestor(of: svg, matching: find.byType(Opacity)).first).opacity == 1;
}

/// The one Capy on screen.
CapyStatus _onlyCapy(WidgetTester t) => t.widget<CapyStatus>(find.byType(CapyStatus));

/// The mood shown with [text].
CapyMood _moodWith(WidgetTester t, String text) => t.widget<CapyMessage>(find.widgetWithText(CapyMessage, text)).mood;

void main() {
  tearDown(() => lowMemory = false);

  test('source failures choose the appropriate Capy illustration', () {
    expect(capyMoodForError(const SourceException(SourceError.unreachable)), CapyMood.offline);
    expect(capyMoodForError(const SourceException(SourceError.timeout)), CapyMood.offline);
    expect(capyMoodForError(const SourceException(SourceError.unauthorized)), CapyMood.account);
    expect(capyMoodForError(const SourceException(SourceError.inactiveAccount)), CapyMood.account);
    expect(capyMoodForError(const SourceException(SourceError.notFound)), CapyMood.empty);
    expect(capyMoodForError(const SourceException(SourceError.emptyPlaylist)), CapyMood.empty);
    expect(capyMoodForError(const SourceException(SourceError.badResponse)), CapyMood.error);
    expect(capyMoodForError(const SourceException(SourceError.httpStatus)), CapyMood.error);
    expect(capyMoodForError(Exception()), CapyMood.error);
  });

  testWidgets('loading animates and respects the reduced motion setting', (tester) async {
    await tester.pumpWidget(_capy(CapyMood.loading));
    await tester.pump();
    final before = tester.getTopLeft(find.byType(CapyStatus));
    final transform = find.descendant(of: find.byType(CapyStatus), matching: find.byType(Transform)).first;
    final start = tester.widget<Transform>(transform).transform.getTranslation().y;
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.widget<Transform>(transform).transform.getTranslation().y, isNot(start));
    expect(tester.getTopLeft(find.byType(CapyStatus)), before);

    await tester.pumpWidget(_capy(CapyMood.loading, reduced: true));
    await tester.pump();
    final still = tester.widget<Transform>(transform).transform.getTranslation().y;
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.widget<Transform>(transform).transform.getTranslation().y, still);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('what moves repaints its own layer, not the screen around it', (t) async {
    await t.pumpWidget(_capy(CapyMood.loading));
    final boundary = find.descendant(of: find.byType(CapyStatus), matching: find.byType(RepaintBoundary)).first;
    expect(find.descendant(of: boundary, matching: find.byType(Transform)), findsWidgets);
    expect(find.descendant(of: boundary, matching: find.byType(Image)), findsOneWidget);
    expect(find.descendant(of: boundary, matching: find.byType(SvgPicture)), findsOneWidget);
  });

  testWidgets('loading moves for as long as it lasts; the other moods rest on the still drawing', (t) async {
    await t.pumpWidget(_capy(CapyMood.loading));
    expect(_animated(t), 'assets/branding/capy-icon.webp');
    expect(_stillSeen(t), isFalse);
    await t.pump(const Duration(seconds: 30));
    expect(_animated(t), 'assets/branding/capy-icon.webp');
    expect(t.binding.transientCallbackCount, greaterThan(0));

    await t.pumpWidget(_capy(CapyMood.empty));
    expect(_animated(t), 'assets/branding/capy-empty.webp');
    expect(_stillSeen(t), isFalse);
    await t.pump(const Duration(seconds: 4));
    expect(_animated(t), 'assets/branding/capy-empty.webp', reason: 'two loops of 2.4 s');
    await t.pump(const Duration(seconds: 1));
    expect(_animated(t), isNull);
    expect(_stillSeen(t), isTrue);
    expect(t.binding.transientCallbackCount, 0, reason: 'nothing asks for frames any more');

    // Another mood plays again
    await t.pumpWidget(_capy(CapyMood.error));
    expect(_animated(t), 'assets/branding/capy-error.webp');
  });

  testWidgets('a 1 GB device or animations turned off get the still drawing and no looping motion', (t) async {
    for (final (low, reduced) in [(true, false), (false, true)]) {
      lowMemory = low;
      for (final mood in [CapyMood.loading, CapyMood.offline]) {
        await t.pumpWidget(_capy(mood, reduced: reduced));
        await t.pump(const Duration(milliseconds: 400)); // past the entrance
        final what = '${mood.name}, ${low ? 'a 1 GB device' : 'animations off'}';
        expect(_animated(t), isNull, reason: what);
        expect(_stillSeen(t), isTrue, reason: what);
        expect(t.binding.transientCallbackCount, 0, reason: what);
        await t.pump(const Duration(seconds: 10));
        expect(t.binding.hasScheduledFrame, isFalse, reason: what);
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('a failed load shows the right Capy and retry still works', (tester) async {
    var attempt = 0;
    final pending = Completer<String>();
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: AsyncView<String>(
            load: () => ++attempt == 1 ? pending.future : Future.value('Recovered'),
            builder: (_, value) => Text(value),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.widget<CapyStatus>(find.byType(CapyStatus)).mood, CapyMood.loading);
    pending.completeError(const SourceException(SourceError.unreachable));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      _moodWith(
        tester,
        "Couldn't connect to the server. Check the address and your connection; if both are fine, "
        'the provider may be down.',
      ),
      CapyMood.offline,
    );
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Recovered'), findsOneWidget);
  });

  group('where it shows', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('a search that finds nothing', (t) async {
      await t.pumpWidget(
        _app(
          Scaffold(
            body: SearchTab(catalog: Catalog(FakeSource()), guide: ValueNotifier(EpgGuide.empty)),
          ),
        ),
      );
      expect(_onlyCapy(t).mood, CapyMood.loading, reason: 'while the catalog loads');
      await t.enterText(find.byType(TextField), 'zzzz');
      final nothing = find.text('No results');
      await t.pump(const Duration(milliseconds: 300)); // the search waits for the typing to pause
      for (var i = 0; i < 50 && nothing.evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(_moodWith(t, 'No results'), CapyMood.empty);
    });

    testWidgets('a row, category or genre with no titles', (t) async {
      await t.pumpWidget(_app(const ItemGridScreen(title: 'Action', items: [])));
      await t.pump();
      expect(_moodWith(t, 'Nothing here'), CapyMood.empty);
    });

    testWidgets('no recordings', (t) async {
      final dir = Directory.systemTemp.createTempSync('recordings');
      Recordings.folderForTests = dir;
      ScheduledRecordings.instance.reset();
      addTearDown(() {
        Recordings.folderForTests = null;
        dir.deleteSync(recursive: true);
      });
      await t.pumpWidget(_app(RecordingsScreen(scheduler: RecordingScheduler())));
      await t.pump();
      await t.pump();
      expect(
        _moodWith(t, 'Your recordings show here: those from the player and those scheduled from the guide.'),
        CapyMood.empty,
      );
    });

    testWidgets('the sync screen, signed out', (t) async {
      await t.pumpWidget(_app(const SyncScreen()));
      await t.pump();
      expect(_onlyCapy(t).mood, CapyMood.account);
    });
  });
}
