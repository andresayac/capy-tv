// New episodes of the series a profile follows: found where the provider changed the series after
// the last episode watched, and nothing asked of it otherwise.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/new_episodes.dart';
import 'package:iptv_player/data/source.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Provider implements ContentSource {
  final asked = <String>[];

  @override
  Future<SeriesDetail> seriesDetail(Series s) async {
    asked.add(s.id);
    return SeriesDetail(
      series: s,
      seasons: {
        1: [for (var n = 1; n <= 4; n++) Episode(id: '${s.id}-1-$n', season: 1, number: n, title: 'E$n')],
        2: [Episode(id: '${s.id}-2-1', season: 2, number: 1, title: 'New season')],
      },
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  bool hideAdult = false;
  @override
  Future<EpgGuide> guide() async => EpgGuide.empty;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('after the last episode watched, only where the provider changed the series, once a session', () async {
    SharedPreferences.setMockInitialValues({});
    // Watched now (the history notes when); the provider changes a series after that, or did long before
    final later = DateTime.now().add(const Duration(hours: 1));
    final before = DateTime.now().subtract(const Duration(days: 30));
    final data = CatalogData(
      live: const [],
      movies: const [],
      series: [
        Series(id: 'news', name: 'Lupin', updated: later), // got episodes since
        Series(id: 'same', name: 'Dark', updated: before),
        Series(id: 'midway', name: 'Ozark', updated: later),
      ],
    );
    final library = await Library.load('p', 'me');
    Future<void> watched(Series s, int episode, {bool finished = true, Duration? at}) => library.record(
      MediaRef.episode(s, Episode(id: '${s.id}-1-$episode', season: 1, number: episode, title: 'E$episode')),
      position: at ?? Duration(minutes: finished ? 50 : 10),
      duration: const Duration(minutes: 50),
    );
    await watched(data.series[0], 3);
    await watched(data.series[1], 2);
    await watched(data.series[2], 1, finished: false);

    final provider = _Provider();
    final finder = NewEpisodeFinder(provider);
    final found = await finder.find(library, data);
    expect([for (final f in found) (f.series.id, f.next.number, f.count)], [('news', 4, 2)]);
    expect(provider.asked, ['news'], reason: 'Dark did not change, Ozark is in Continue watching: nothing asked');

    await finder.find(library, data);
    expect(provider.asked, hasLength(1), reason: 'once a session');

    // Up next: a series seen to its last episode, which the provider did not change
    final next = await NewEpisodeFinder(provider).find(library, data, upNext: true);
    expect(
      [for (final f in next) (f.series.id, f.next.number)],
      [('same', 3)],
      reason: 'Lupin is news, Ozark half way',
    );

    // The next one started by itself and was left within seconds: still the one up next
    await watched(data.series[1], 3, at: const Duration(seconds: 8));
    expect(
      [
        for (final f in await NewEpisodeFinder(provider).find(library, data, upNext: true))
          (f.series.id, f.next.number),
      ],
      [('same', 3)],
    );
  });
}
