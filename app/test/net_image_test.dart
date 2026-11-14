// Images kept at one size while their box changes a little, so a window being resized does not
// download them all again at each step.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/ui/common.dart';

void main() {
  testWidgets('a poster keeps its size while its box changes a little', (t) async {
    var size = const Size(150, 225);
    late StateSetter resize;
    await t.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: StatefulBuilder(
              builder: (_, set) {
                resize = set;
                return SizedBox.fromSize(size: size, child: const NetImage('http://posters.test/a.jpg'));
              },
            ),
          ),
        ),
      ),
    );
    Future<Object> key() => t.widget<Image>(find.byType(Image)).image.obtainKey(ImageConfiguration.empty);
    Future<Object> at(Size s) async {
      resize(() => size = s);
      await t.pump();
      return key();
    }

    final first = await key();
    expect(await at(const Size(160, 240)), first, reason: 'a little bigger: the same image');
    expect(await at(const Size(100, 150)), first, reason: 'smaller, but more than half: the same');
    expect(await at(const Size(400, 600)), isNot(first), reason: 'much bigger: decoded again, sharp');
    final big = await key();
    expect(await at(const Size(120, 180)), isNot(big), reason: 'under half: decoded again, smaller');
  });
}
