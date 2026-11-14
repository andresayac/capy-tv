// One playlist is nothing to choose: as the app starts it opens by itself.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/ui/playlists_screen.dart';

void main() {
  test('the only one opens by itself', () {
    expect(opensByItself(1, onTop: true, busy: false), isTrue);
  });

  test('with none, or several, there is something to do here', () {
    expect(opensByItself(0, onTop: true, busy: false), isFalse);
    expect(opensByItself(2, onTop: true, busy: false), isFalse);
    expect(opensByItself(null, onTop: true, busy: false), isFalse, reason: 'not read yet');
  });

  test('not under something else, nor over one already opening', () {
    expect(opensByItself(1, onTop: false, busy: false), isFalse, reason: 'a link from another device');
    expect(opensByItself(1, onTop: true, busy: true), isFalse, reason: 'a profile changed from inside it');
  });
}
