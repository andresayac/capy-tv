// Images decoded at the size they are shown, not the size the provider made them.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/ui/fitted_image.dart';

void main() {
  testWidgets('a 400×200 image fills or fits the box, and is never made bigger', (t) async {
    final png = (await t.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = Colors.white);
      final image = await recorder.endRecording().toImage(400, 200);
      return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    }))!;

    // Decoding takes real time: started and waited for outside the test's fake clock
    Future<Size> decoded(Size box, BoxFit fit) async => (await t.runAsync(() async {
      final shown = Completer<ui.Image>();
      fitted(
        MemoryImage(Uint8List.fromList(png)),
        box,
        fit,
      ).resolve(ImageConfiguration.empty).addListener(ImageStreamListener((info, _) => shown.complete(info.image)));
      final image = await shown.future.timeout(const Duration(seconds: 20));
      return Size(image.width.toDouble(), image.height.toDouble());
    }))!;

    expect(await decoded(const Size(100, 100), BoxFit.cover), const Size(200, 100), reason: 'covers the box');
    expect(await decoded(const Size(100, 100), BoxFit.contain), const Size(100, 50), reason: 'fits in the box');
    expect(await decoded(const Size(1000, 1000), BoxFit.cover), const Size(400, 200), reason: 'never bigger');

    final image = MemoryImage(png);
    expect(fitted(image, Size.infinite, BoxFit.cover), same(image), reason: 'no size to fit: as it is');
    expect(fitted(image, Size.zero, BoxFit.cover), same(image));
  });

  testWidgets('one that fails goes from the cache, to be asked for again', (t) async {
    final broken = fitted(MemoryImage(Uint8List.fromList([1, 2, 3])), const Size(100, 100), BoxFit.cover);
    final key = (await t.runAsync(() => broken.obtainKey(ImageConfiguration.empty)))!;
    await t.runAsync(() async {
      final failed = Completer<void>();
      broken
          .resolve(ImageConfiguration.empty)
          .addListener(ImageStreamListener((_, _) {}, onError: (_, _) => failed.complete()));
      await failed.future.timeout(const Duration(seconds: 20));
      await Future<void>.delayed(Duration.zero);
    });
    expect(PaintingBinding.instance.imageCache.containsKey(key), isFalse);
  });
}
