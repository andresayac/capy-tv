import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/player/sleep_timer.dart';

void main() {
  test('a sleep timer is due once its minutes are up, and counts down till then', () {
    var now = DateTime(2026, 11, 7, 23);
    final sleep = SleepTimer(clock: () => now);
    expect(sleep.on, isFalse);
    sleep.after(30);
    expect((sleep.on, sleep.minutes, sleep.due), (true, 30, false));
    now = now.add(const Duration(minutes: 29, seconds: 30));
    expect(sleep.left, const Duration(seconds: 30));
    now = now.add(const Duration(seconds: 30));
    expect(sleep.due, isTrue);
    now = now.add(const Duration(minutes: 5));
    expect(sleep.left, Duration.zero, reason: 'never below zero');
  });

  test('it says so a minute before, once, and someone still there starts the wait again', () {
    var now = DateTime(2026, 11, 7, 23);
    final sleep = SleepTimer(clock: () => now)..after(15);
    now = now.add(const Duration(minutes: 13, seconds: 59));
    expect(sleep.warnNow, isFalse, reason: 'over a minute left');
    now = now.add(const Duration(seconds: 1));
    expect(sleep.warnNow, isTrue);
    sleep.warned = true;
    expect(sleep.warnNow, isFalse, reason: 'once');
    sleep.again();
    expect((sleep.minutes, sleep.left, sleep.warned), (15, const Duration(minutes: 15), false));
    now = now.add(const Duration(minutes: 14));
    expect(sleep.warnNow, isTrue, reason: 'and again before the new end');
  });

  test('"when it ends" is not a wait, and either choice replaces the other', () {
    final sleep = SleepTimer()..after(15);
    sleep.whenItEnds();
    expect((sleep.on, sleep.atEnd, sleep.left, sleep.due), (true, true, null, false));
    sleep.after(45);
    expect((sleep.atEnd, sleep.minutes), (false, 45));
    sleep.off();
    expect((sleep.on, sleep.minutes, sleep.left), (false, null, null));
  });
}
