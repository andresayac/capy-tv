// The guide goes back a few days, for what channels with catch-up kept.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/guide_screen.dart';

import 'ui_test.dart' show FakeSource;

void main() {
  testWidgets("yesterday's programmes are a chip away, not past the start of today's grid", (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1, 0, 5);
    final guide = EpgGuide({
      'one.tv': [EpgEntry(title: 'Late film', start: yesterday, end: yesterday.add(const Duration(hours: 2)))],
    });
    await t.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GuideScreen(
          source: FakeSource(),
          guide: ValueNotifier(guide),
          categories: const [Category(id: '1', name: 'News')],
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Late film'), findsNothing, reason: 'today starts just before now');
    await t.tap(find.text('Yesterday'));
    await t.pumpAndSettle();
    expect(find.text('Late film'), findsOneWidget);
  });
}
