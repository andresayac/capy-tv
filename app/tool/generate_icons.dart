// Regenerates platform artwork from assets/branding/capy-icon.svg.
// Run from app/: flutter test tool/generate_icons.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const _res = 'android/app/src/main/res';
const _green = Color(0xFF2B4740);

Future<Uint8List> _png(int width, int height, void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final image = await recorder.endRecording().toImage(width, height);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void _drawLogo(Canvas canvas, ui.Picture picture, Rect bounds) {
  canvas.save();
  canvas.translate(bounds.left, bounds.top);
  canvas.scale(bounds.width / 156, bounds.height / 156);
  canvas.drawPicture(picture);
  canvas.restore();
}

Uint8List _ico(List<(int, Uint8List)> images) {
  final header = ByteData(6 + 16 * images.length)
    ..setUint16(2, 1, Endian.little)
    ..setUint16(4, images.length, Endian.little);
  var offset = header.lengthInBytes;
  for (final (i, (size, png)) in images.indexed) {
    final e = 6 + 16 * i;
    header
      ..setUint8(e, size >= 256 ? 0 : size)
      ..setUint8(e + 1, size >= 256 ? 0 : size)
      ..setUint16(e + 4, 1, Endian.little)
      ..setUint16(e + 6, 32, Endian.little)
      ..setUint32(e + 8, png.length, Endian.little)
      ..setUint32(e + 12, offset, Endian.little);
    offset += png.length;
  }
  return Uint8List.fromList([...header.buffer.asUint8List(), for (final (_, png) in images) ...png]);
}

void _write(String path, Uint8List data) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(data);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('generate Capy TV artwork', () async {
    final source = File('assets/branding/capy-icon.svg').readAsStringSync();
    final picture = (await vg.loadPicture(SvgStringLoader(source), null)).picture;
    Future<Uint8List> icon(int size, {bool opaque = false}) => _png(size, size, (canvas) {
      if (opaque) canvas.drawColor(_green, BlendMode.src);
      _drawLogo(canvas, picture, Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()));
    });

    for (final MapEntry(key: density, value: size) in {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    }.entries) {
      _write('$_res/mipmap-$density/ic_launcher.png', await icon(size));
    }
    _write('$_res/drawable-nodpi/capy_logo.png', await icon(512));
    _write('assets/branding/capy-icon.png', await icon(512));
    // Adaptive launchers crop the 108dp foreground to a central 72dp safe area.
    _write(
      '$_res/drawable-nodpi/capy_launcher_foreground.png',
      await _png(432, 432, (canvas) {
        _drawLogo(canvas, picture, const Rect.fromLTWH(72, 72, 288, 288));
      }),
    );

    final font = FontLoader('Inter')
      ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/Inter-700.ttf').readAsBytesSync())));
    await font.load();
    final text = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: 'Inter', fontSize: 30, fontWeight: FontWeight.w700))
      ..pushStyle(ui.TextStyle(color: Colors.white, fontFamily: 'Inter', fontSize: 30, fontWeight: FontWeight.w700))
      ..addText('Capy TV');
    final title = text.build()..layout(const ui.ParagraphConstraints(width: 4096));
    _write(
      '$_res/drawable-xhdpi/banner.png',
      await _png(320, 180, (canvas) {
        canvas.drawColor(const Color(0xFF101719), BlendMode.src);
        final left = (320 - 72 - 14 - title.maxIntrinsicWidth) / 2;
        _drawLogo(canvas, picture, Rect.fromLTWH(left, 54, 72, 72));
        canvas.drawParagraph(title, Offset(left + 86, (180 - title.height) / 2));
      }),
    );
    _write(
      'windows/runner/resources/app_icon.ico',
      _ico([
        for (final size in [16, 24, 32, 48, 64, 128, 256]) (size, await icon(size)),
      ]),
    );

    final ios = Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset');
    for (final file in ios.listSync().whereType<File>().where((file) => file.path.endsWith('.png'))) {
      final match = RegExp(r'Icon-App-([\d.]+)x[\d.]+@(\d)x\.png$').firstMatch(file.path)!;
      final size = (double.parse(match.group(1)!) * int.parse(match.group(2)!)).round();
      _write(file.path, await icon(size, opaque: true));
    }
    for (final size in [16, 32, 64, 128, 256, 512, 1024]) {
      _write('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png', await icon(size));
    }
    for (final scale in [1, 2, 3]) {
      final suffix = scale == 1 ? '' : '@${scale}x';
      _write('ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage$suffix.png', await icon(80 * scale));
    }
    picture.dispose();
  });
}
