// Where a series' opening titles are, kept by its title: titles in other scripts each have their
// own, and what was kept before stays.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/intro_marks.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const a = (start: Duration(seconds: 5), end: Duration(seconds: 65));
  const b = (start: Duration(seconds: 30), end: Duration(seconds: 90));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('series titled in other scripts each keep their own', () async {
    await IntroMarks.save('사랑의 불시착', a);
    await IntroMarks.save('Ведьмак', b);
    expect(await IntroMarks.of('사랑의 불시착'), a);
    expect(await IntroMarks.of('Ведьмак'), b);
    expect(await IntroMarks.of('Тьма'), isNull);
  });

  test('a mark kept by the Latin letters alone is still found; taken off, it stays off', () async {
    SharedPreferences.setMockInitialValues({'intro/the witcher': '{"start":5000,"end":65000}'});
    expect(await IntroMarks.of('Ведьмак (The Witcher)'), a);
    expect(await IntroMarks.of('The Witcher'), a);
    await IntroMarks.save('Ведьмак (The Witcher)', (start: null, end: null));
    expect(await IntroMarks.of('Ведьмак (The Witcher)'), isNull);
    expect(await IntroMarks.of('The Witcher'), a, reason: 'the Latin-only title keeps its own');
  });
}
