// Search with a remote: the keyboard comes when OK asks for it, not by itself each time.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/remote_keys.dart';
import 'package:iptv_player/ui/search_tab.dart';
import 'package:iptv_player/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_test.dart' show FakeSource;

/// Frames for a while: the list loading animates for as long as it shows
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    isTv = true;
  });
  tearDown(() => isTv = false);

  testWidgets('the field has the remote with no keyboard up; OK brings it, and what is typed searches', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
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
        home: Scaffold(
          body: SearchTab(catalog: Catalog(FakeSource()), guide: ValueNotifier(EpgGuide.empty)),
        ),
      ),
    );
    await settle(t);
    // The remote comes into the tab, on its field
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(t);
    expect(find.byType(EditableText), findsNothing, reason: 'no keyboard by itself');
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(t);
    expect(find.byType(EditableText), findsOneWidget, reason: 'OK opens it');
    await t.enterText(find.byType(EditableText), 'film');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await settle(t);
    expect(find.byType(EditableText), findsNothing);
    expect(find.text('film'), findsOneWidget, reason: 'the field shows what is searched');
  });
}
