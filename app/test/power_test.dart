// What keeps a computer awake for a recording and wakes it for one: on Windows these ask the
// system itself; elsewhere they do nothing. Either way they never throw.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/player/power.dart';

void main() {
  test('keeping the computer awake, and letting it sleep again, is asked without fail', () {
    keepSystemAwake(true);
    keepSystemAwake(true); // said once only
    keepSystemAwake(false);
  });

  test('a wake-up is set, moved and taken back without fail', () {
    final at = DateTime.now().add(const Duration(hours: 6));
    wakeSystemAt(at);
    wakeSystemAt(at.add(const Duration(minutes: 30)));
    wakeSystemAt(null);
  });
}
