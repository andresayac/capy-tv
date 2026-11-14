// With a remote, Right on a row's last item stays there: the nearest stop that way is on the row
// below, diagonally, which is not where anyone pressing Right means to go.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/ui/remote_keys.dart';

void main() {
  testWidgets('Right at the end of a short row stays; within it, it moves on', (t) async {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
    final top = [for (var i = 0; i < 3; i++) FocusNode(debugLabel: 'top $i')];
    final below = [for (var i = 0; i < 6; i++) FocusNode(debugLabel: 'below $i')];
    Widget row(List<FocusNode> nodes) => SizedBox(
      height: 60,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [for (final n in nodes) Focus(focusNode: n, child: const SizedBox(width: 100, height: 60))],
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(TraversalDirection.right),
          },
          child: Actions(
            actions: {DirectionalFocusIntent: ScrollWhenStuckAction()},
            child: Scaffold(body: Column(children: [row(top), row(below)])),
          ),
        ),
      ),
    );
    top[1].requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(top[2].hasPrimaryFocus, isTrue, reason: 'on along the row');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(top[2].hasPrimaryFocus, isTrue, reason: 'its end: not down to the row below');
  });
}
