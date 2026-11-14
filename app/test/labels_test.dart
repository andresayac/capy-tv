// What the panel left unnamed is said in the app's language: a category with no name, an M3U
// entry with no group (or an empty one), an episode with no title.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/m3u.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/common.dart';

void main() {
  final es = lookupAppLocalizations(const Locale('es'));

  test('a category the provider did not name, in the app’s language; one it named, tidied', () {
    expect(categoryLabel(es, ungrouped), 'Sin categoría');
    expect(categoryLabel(es, untitled), 'Sin título');
    expect(categoryLabel(es, 'VOD | ACCIÓN'), 'Acción');
  });

  test('an M3U entry with no group, or an empty one, is in the unnamed category', () {
    expect(const M3uEntry(name: 'a', url: 'http://x/1').group, ungrouped);
    expect(const M3uEntry(name: 'a', url: 'http://x/1', attrs: {'group-title': ' '}).group, ungrouped);
    expect(const M3uEntry(name: 'a', url: 'http://x/1', attrs: {'group-title': 'News'}).group, 'News');
  });

  test('an episode with no title is said by its number', () {
    final none = Episode.fromJson({'id': '1', 'episode_num': 3}, 1);
    expect(episodeName(none, 'Show'), isNull);
    expect(es.episodeNumber(3), 'Episodio 3');
    final named = Episode.fromJson({'id': '2', 'episode_num': 4, 'title': 'Show - S01E04 - The Trip'}, 1);
    expect(episodeName(named, 'Show'), 'The Trip');
  });
}
