// The window's size and place from last time are only put back where they are still usable; the
// player's small window is sized to the screen and the picture.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/desktop_window.dart';

void main() {
  const laptop = Rect.fromLTWH(0, 0, 1280, 672); // 1080p at 150 %, the taskbar left out
  const second = Rect.fromLTWH(1280, 0, 1920, 1040);

  test('back where it was when that is on a screen, its title bar to drag it by', () {
    expect(DesktopWindow.fitsOnAScreen(const Rect.fromLTWH(100, 80, 1000, 560), [laptop]), isTrue);
    expect(DesktopWindow.fitsOnAScreen(const Rect.fromLTWH(1500, 100, 1280, 720), [laptop, second]), isTrue);
  });

  test('not on a screen since unplugged, nor with its title bar out of reach, nor too small', () {
    expect(DesktopWindow.fitsOnAScreen(const Rect.fromLTWH(1500, 100, 1280, 720), [laptop]), isFalse);
    expect(DesktopWindow.fitsOnAScreen(const Rect.fromLTWH(100, -400, 1000, 560), [laptop]), isFalse);
    expect(DesktopWindow.fitsOnAScreen(const Rect.fromLTWH(100, 80, 200, 150), [laptop]), isFalse);
    expect(DesktopWindow.fitsOnAScreen(const Rect.fromLTWH(100, 80, 1000, 560), const []), isFalse);
  });

  test('the small window: a quarter of the screen wide, shaped like the picture', () {
    expect(DesktopWindow.miniSize(laptop.size, 16 / 9), const Size(320, 180));
    expect(DesktopWindow.miniSize(second.size, 16 / 9), const Size(480, 270));
    // 4K at 100 %: no wider than 520
    expect(DesktopWindow.miniSize(const Size(3840, 2120), 16 / 9).width, 520);
    // A tall picture (a phone's video) no taller than 45 % of the screen
    final tall = DesktopWindow.miniSize(second.size, 9 / 16);
    expect(tall.height, closeTo(1040 * 0.45, 0.01));
    expect(tall.width, closeTo(1040 * 0.45 * 9 / 16, 0.01));
  });
}
