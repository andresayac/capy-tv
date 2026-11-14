// On a computer, Esc and Alt+← go back, as the back arrow does; not while typing.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/ui/remote_keys.dart';

void main() {
  testWidgets('Esc and Alt+Left go back, a dialog first; in a text field they are the field\'s', (t) async {
    final navigator = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) => Shortcuts(
          shortcuts: desktopShortcuts,
          child: Actions(actions: {GoBackIntent: GoBackAction(navigator)}, child: child!),
        ),
        home: const Scaffold(body: Text('Home')),
      ),
    );
    void open(Widget body) =>
        navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: body)));

    open(const Focus(autofocus: true, child: Text('Details')));
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('Details'), findsNothing);

    open(const Focus(autofocus: true, child: Text('Details')));
    await t.pumpAndSettle();
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await t.pumpAndSettle();
    expect(find.text('Details'), findsNothing);

    open(const Column(children: [Text('Search'), TextField(autofocus: true)]));
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('Search'), findsOneWidget, reason: 'typing, Esc does not close the screen');
  });
}
