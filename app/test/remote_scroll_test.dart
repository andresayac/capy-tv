// With a remote, an arrow with nowhere to go scrolls the page: text under the last button is read.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/ui/remote_keys.dart';

void main() {
  testWidgets('Down past the last button scrolls to what is below it, and Up comes back to it', (t) async {
    t.view.physicalSize = const Size(960, 540);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        builder: (_, child) => Shortcuts(
          shortcuts: tvShortcuts,
          child: Actions(actions: {DirectionalFocusIntent: ScrollWhenStuckAction()}, child: child!),
        ),
        home: Scaffold(
          body: ListView(
            children: [
              TextButton(autofocus: true, onPressed: () {}, child: const Text('Play')),
              for (var i = 0; i < 20; i++) SizedBox(height: 60, child: Text('Line $i')),
            ],
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.text('Line 15').hitTestable(), findsNothing);
    for (var i = 0; i < 4; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
    }
    expect(find.text('Line 15').hitTestable(), findsOneWidget, reason: 'scrolled down to it');
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextButton>(), isNotNull);
    for (var i = 0; i < 6; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
    }
    expect(find.text('Play').hitTestable(), findsOneWidget, reason: 'and back up');
  });
}
