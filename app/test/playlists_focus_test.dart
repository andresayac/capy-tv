// The playlists screen with a remote: each card's edit and delete buttons are reached with Right.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/common.dart';
import 'package:iptv_player/ui/playlists_screen.dart';
import 'package:iptv_player/ui/remote_keys.dart';
import 'package:iptv_player/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => isTv = true);
  tearDown(() => isTv = false);

  testWidgets('with a remote, a stop switched off as it is pressed keeps the focus', (t) async {
    var on = true;
    late StateSetter set;
    await t.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return Scaffold(
              body: Focusable(autofocus: true, onTap: on ? () {} : null, child: const Text('Open')),
            );
          },
        ),
      ),
    );
    await t.pump();
    expect(FocusManager.instance.primaryFocus?.context?.widget, isNot(isNull));
    final before = FocusManager.instance.primaryFocus;
    set(() => on = false); // busy: pressed, opening
    await t.pump();
    expect(FocusManager.instance.primaryFocus, same(before), reason: 'still where the remote was');
    expect(before!.hasPrimaryFocus, isTrue);
  });

  testWidgets('on a playlist\'s card, Right goes to editing it, and on to deleting it', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    // Two, so that neither opens by itself; with their passwords, so no keystore is asked
    SharedPreferences.setMockInitialValues({
      'playlists':
          '[{"id":"a","name":"One","type":"m3u","url":"http://lists.example/a.m3u","password":"x"},'
          '{"id":"b","name":"Two","type":"m3u","url":"http://lists.example/b.m3u","password":"x"}]',
    });
    final settings = await AppSettings.load();
    await ProfileStore.instance.load();
    await t.pumpWidget(
      SettingsScope(
        settings: settings,
        child: MaterialApp(
          theme: buildTheme(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) => Shortcuts(shortcuts: tvShortcuts, child: child!),
          home: const PlaylistsScreen(),
        ),
      ),
    );
    for (var i = 0; i < 20 && find.text('One').evaluate().isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
    }
    await t.pump(const Duration(milliseconds: 500));
    String? tooltip() =>
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<IconButton>()?.tooltip;
    final l = await AppLocalizations.delegate.load(const Locale('en'));

    expect(tooltip(), isNull, reason: 'the first card has the remote');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump(const Duration(milliseconds: 300));
    expect(tooltip(), l.editPlaylist);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump(const Duration(milliseconds: 300));
    expect(tooltip(), l.delete);
    await t.pumpWidget(const SizedBox());
  });
}
