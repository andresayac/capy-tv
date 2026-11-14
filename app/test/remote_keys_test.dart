// A TV remote's OK held down presses once, not again and again.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/profiles_screen.dart';
import 'package:iptv_player/ui/remote_keys.dart';
import 'package:iptv_player/ui/theme.dart';

void main() {
  Future<String?> Function() pinPadOpenedWithOkHeld(WidgetTester t, {required bool tv}) {
    late BuildContext context;
    Future<String?>? typed;
    return () async {
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) => tv ? Shortcuts(shortcuts: tvShortcuts, child: child!) : child!,
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                autofocus: true,
                onPressed: () => typed = showPinPad(context = c, title: 'PIN'),
                child: const Text('Locked profile'),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      // OK goes down on the profile, which opens the pad, and stays down a moment
      await t.sendKeyDownEvent(LogicalKeyboardKey.select);
      await t.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await t.sendKeyRepeatEvent(LogicalKeyboardKey.select);
        await t.pump();
      }
      await t.sendKeyUpEvent(LogicalKeyboardKey.select);
      await t.pumpAndSettle();
      expect(find.text('PIN'), findsOneWidget);
      for (final key in [
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit5,
        LogicalKeyboardKey.digit8,
        LogicalKeyboardKey.digit0,
      ]) {
        await t.sendKeyEvent(key);
        await t.pump();
      }
      await t.pumpAndSettle();
      expect(context.mounted, isTrue);
      return typed;
    };
  }

  testWidgets('on a TV, OK held on a locked profile does not type into its PIN pad', (t) async {
    expect(await pinPadOpenedWithOkHeld(t, tv: true)(), '2580');
  });

  testWidgets('which is what it did: the pad\'s first key pressed by the held OK', (t) async {
    expect(await pinPadOpenedWithOkHeld(t, tv: false)(), isNot('2580'));
  });

  testWidgets('OK pressed again, not held, presses again', (t) async {
    var presses = 0;
    await t.pumpWidget(
      MaterialApp(
        builder: (_, child) => Shortcuts(shortcuts: tvShortcuts, child: child!),
        home: Scaffold(
          body: TextButton(autofocus: true, onPressed: () => presses++, child: const Text('Button')),
        ),
      ),
    );
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.sendKeyDownEvent(LogicalKeyboardKey.select);
    await t.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await t.sendKeyUpEvent(LogicalKeyboardKey.select);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(presses, 3);
  });

  testWidgets('on the PIN pad the remote goes down the keys, as it goes across', (t) async {
    Future<String?>? typed;
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
          builder: (c) => Scaffold(
            body: TextButton(
              autofocus: true,
              onPressed: () => typed = showPinPad(c, title: 'PIN'),
              child: const Text('Locked profile'),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pumpAndSettle();
    // 1, down to 4, across to 5, down to 8
    for (final key in [
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.select,
    ]) {
      await t.sendKeyEvent(key);
      await t.pumpAndSettle();
    }
    expect(find.text('PIN'), findsNothing, reason: 'all four typed, the pad gone');
    expect(await typed, '1458');
  });
}
