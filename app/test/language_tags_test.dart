// What a preferred language reaches in the tracks providers mark.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/settings.dart';

void main() {
  test("Spanish reaches the tags providers use for it, Spain's and Latin America's", () {
    expect(languageTagsFor('spa').split(','), containsAll(['spa', 'es', 'esp', 'esa', 'lat', 'cas']));
    expect(languageTagsFor('kor'), 'kor', reason: 'one not in the table goes as it is');
  });
}
