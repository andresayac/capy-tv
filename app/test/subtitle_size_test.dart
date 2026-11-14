// Subtitles big enough to read from the sofa, on a TV as on a phone.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/player/player_screen.dart';

void main() {
  test('about the Samsung app\'s share of the screen, never below 16 dp', () {
    expect(subtitleSize(540, 100), closeTo(22.7, 0.1), reason: 'a TV: 45 px at 1080p');
    expect(subtitleSize(360, 100), 16, reason: 'a phone on its side');
    expect(subtitleSize(540, 200), closeTo(45.4, 0.1));
    expect(subtitleSize(2000, 100), 56);
  });
}
