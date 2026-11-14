// The screensaver: after the minutes set without input, not while something plays, gone at a key.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/remote/remote_input.dart';
import 'package:iptv_player/ui/screensaver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> app(WidgetTester t, {int minutes = 2}) async {
    SharedPreferences.setMockInitialValues({'screensaverMinutes': minutes});
    final settings = await AppSettings.load();
    final navigator = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      SettingsScope(
        settings: settings,
        child: MaterialApp(
          navigatorKey: navigator,
          builder: (_, child) => IdleWatcher(navigator: navigator, child: child!),
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
  }

  testWidgets('after the minutes set without input, and gone at a key', (t) async {
    await app(t);
    await t.pump(const Duration(seconds: 110));
    expect(find.byType(ScreenSaver, skipOffstage: false), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown); // a key starts the count again
    await t.pump(const Duration(seconds: 110));
    expect(find.byType(ScreenSaver, skipOffstage: false), findsNothing);
    await t.pump(const Duration(seconds: 20));
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(ScreenSaver), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.select);
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100)); // its fade out
    }
    expect(find.byType(ScreenSaver, skipOffstage: false), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('Back (Escape here) leaves it, and is not taken by the screen behind as it comes up', (t) async {
    await app(t);
    await t.pump(const Duration(seconds: 121));
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(ScreenSaver), findsOneWidget);
    expect(await t.sendKeyDownEvent(LogicalKeyboardKey.escape), isTrue);
    await t.pump();
    expect(find.byType(ScreenSaver), findsOneWidget, reason: 'it waits for the key to come up');
    // Not taken as it comes up, Android would go back too: Home, or out of the app
    expect(await t.sendKeyUpEvent(LogicalKeyboardKey.escape), isTrue);
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ScreenSaver, skipOffstage: false), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('never while something plays, nor when it is off', (t) async {
    nowPlaying.value = (title: 'Heat', subtitle: null);
    addTearDown(() => nowPlaying.value = null);
    await app(t);
    await t.pump(const Duration(minutes: 5));
    expect(find.byType(ScreenSaver, skipOffstage: false), findsNothing);

    nowPlaying.value = null;
    await app(t, minutes: 0);
    await t.pump(const Duration(minutes: 30));
    expect(find.byType(ScreenSaver, skipOffstage: false), findsNothing);
  });
}
