// A long press with a TV remote, which has none of its own: OK held a moment, or the ☰ / info
// button. A guide programme on now opens its details (and Record) this way.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/ui/common.dart';

void main() {
  late List<String> did;

  Widget app({bool long = true}) => MaterialApp(
    home: Scaffold(
      body: Focusable(
        autofocus: true,
        onTap: () => did.add('tap'),
        onLongPress: long ? () => did.add('long') : null,
        child: const SizedBox(width: 200, height: 60, child: Text('Match')),
      ),
    ),
  );

  setUp(() => did = []);

  testWidgets('OK pressed taps; held, its repeats do nothing until it is let go as a long press', (t) async {
    await t.pumpWidget(app());
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pump();
    expect(did, ['tap']);

    await t.sendKeyDownEvent(LogicalKeyboardKey.select);
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 60));
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    }
    expect(did, ['tap'], reason: 'nothing while held');
    await t.sendKeyUpEvent(LogicalKeyboardKey.select);
    await t.pump();
    expect(did, ['tap', 'long']);

    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(did, ['tap', 'long', 'tap']);
  });

  testWidgets('the ☰ and info buttons are a long press', (t) async {
    await t.pumpWidget(app());
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await t.sendKeyEvent(LogicalKeyboardKey.info);
    await t.pump();
    expect(did, ['long', 'long']);
  });

  testWidgets('without a long press, OK taps as always', (t) async {
    await t.pumpWidget(app(long: false));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pump();
    expect(did, ['tap']);
  });
}
