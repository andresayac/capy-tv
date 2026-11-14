// A button whose label is wider than its place: it goes on to a second line, not cut off.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/ui/common.dart';

void main() {
  for (final (name, holder) in [
    ('in a wrap', (Widget b) => Wrap(children: [b])),
    (
      'in a row with no bound',
      (Widget b) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [b]),
      ),
    ),
  ]) {
    testWidgets('large text on a narrow phone, $name: the label wraps whole', (t) async {
      t.view.physicalSize = const Size(320, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      const label = 'Bring favorites and history from another list';
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(320, 640), textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: holder(PrimaryButton(icon: Icons.swap_horiz_rounded, label: label, onPressed: () {})),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull, reason: 'nothing overflows');
      final text = t.getRect(find.text(label));
      expect(text.right <= 320, isTrue, reason: 'within the screen: $text');
      expect(text.height > 40, isTrue, reason: 'on more than one line: $text');
    });
  }
}
