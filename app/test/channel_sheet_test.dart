// A channel's sheet (OK held on it): with a long guide, its buttons stay in sight with the remote on them.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/common.dart';
import 'package:iptv_player/ui/detail_screens.dart';
import 'package:iptv_player/ui/remote_keys.dart';
import 'package:iptv_player/ui/theme.dart';

import 'ui_test.dart' show FakeSource;

void main() {
  setUp(() => isTv = true);
  tearDown(() => isTv = false);

  testWidgets('a guide with descriptions: Watch live in sight with the remote, the programmes scroll', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final now = DateTime.now();
    final guide = EpgGuide({
      'news': [
        for (var i = 0; i < 6; i++)
          EpgEntry(
            title: 'Programme $i',
            start: now.add(Duration(hours: i - 1)),
            end: now.add(Duration(hours: i)),
            description: 'A long description of what happens in it, ' * 6,
          ),
      ],
    });
    const channel = LiveChannel(id: '1', name: 'News', epgId: 'news');
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (_, child) => Shortcuts(shortcuts: tvShortcuts, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showChannelGuide(context, FakeSource(), channel, guide: guide),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    final live = find.text('Watch live');
    expect(live.hitTestable(), findsOneWidget, reason: 'in sight, not under the edge of the screen');
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<PrimaryButton>(), isNotNull);
    // Up goes into the programmes, and down along them each comes into view, to the last
    String? on() {
      final f = FocusManager.instance.primaryFocus?.context;
      if (f == null) return null;
      return find
          .descendant(of: find.byElementPredicate((e) => e == f), matching: find.textContaining('Programme'))
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .firstOrNull;
    }

    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pumpAndSettle();
    expect(on(), isNotNull, reason: 'up from the buttons is a programme');
    for (var i = 0; i < 6 && on() != 'Programme 5'; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
    }
    expect(on(), 'Programme 5');
    expect(find.text('Programme 5').hitTestable(), findsOneWidget, reason: 'scrolled into view');
    expect(live.hitTestable(), findsOneWidget, reason: 'the buttons stay');
  });
}
