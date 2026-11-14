import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/matching.dart';
import 'package:iptv_player/data/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _movie = MediaRef(kind: MediaKind.movie, id: 'm1', title: 'Film', extension: 'mkv');
const _show = Series(id: 's1', name: 'Show (2021)');
MediaRef _ep(int n) =>
    MediaRef.episode(_show, Episode(id: 'e$n', season: 1, number: n, title: 'Show - S01E0$n - Part $n'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a favorite another device added with its clock ahead, taken out here, stays out', () async {
    final ahead = DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
    final there = {
      'favorites': [_movie.toJson()],
      'favAt': {_movie.key: ahead},
    };
    final lib = await Library.load('clock', mainProfileId);
    lib.merge(there);
    expect(lib.isFavorite(_movie), isTrue);
    await lib.toggleFavorite(_movie);
    expect(lib.isFavorite(_movie), isFalse);
    lib.merge(there); // the other device's copy comes again
    expect(lib.isFavorite(_movie), isFalse, reason: 'taken out after it was added, whatever the clocks say');
  });

  test('a long series keeps its last episodes, not the whole history: the movie left stays', () async {
    final lib = await Library.load('trim', mainProfileId);
    const hour = Duration(hours: 1);
    await lib.record(_movie, position: const Duration(minutes: 20), duration: hour);
    for (var n = 1; n <= 90; n++) {
      final e = MediaRef(
        kind: MediaKind.episode,
        id: 'e$n',
        title: 'Chapter $n',
        seriesId: 's',
        seriesTitle: 'Soap',
        season: 1,
        number: n,
      );
      await lib.record(e, position: hour, duration: hour);
    }
    expect([for (final h in lib.continueWatching) h.ref.id], [_movie.id]);
    expect(lib.history.where((h) => h.ref.kind == MediaKind.episode), hasLength(Library.episodesKept));
  });

  test('a series by its latest episode: one finished after the one left is where it is', () async {
    final lib = await Library.load('latest', mainProfileId);
    const hour = Duration(hours: 1);
    MediaRef e(int n) => MediaRef(
      kind: MediaKind.episode,
      id: 'e$n',
      title: 'E$n',
      seriesId: 's',
      seriesTitle: 'S',
      season: 1,
      number: n,
    );
    await lib.record(e(3), position: const Duration(minutes: 55), duration: hour);
    await lib.record(e(4), position: hour, duration: hour);
    expect(lib.continueWatching.where((h) => h.ref.kind == MediaKind.episode), isEmpty);
  });

  test('forgetting a movie forgets every copy of it', () async {
    final lib = await Library.load('forget', mainProfileId);
    const hour = Duration(hours: 1);
    const latino = MediaRef(kind: MediaKind.movie, id: 'lat', title: 'Heat (1995)', year: 1995);
    const uhd = MediaRef(kind: MediaKind.movie, id: '4k', title: 'Heat [4K]', year: 1995);
    await lib.record(latino, position: const Duration(minutes: 40), duration: hour);
    await lib.record(uhd, position: const Duration(minutes: 45), duration: hour);
    await lib.forget(uhd);
    expect(lib.continueWatching, isEmpty);
  });

  test('progress noted during playback is kept and synced but redraws no screen; leaving does', () async {
    final lib = await Library.load('quiet', mainProfileId);
    var told = 0;
    lib.addListener(() => told++);
    final saves = <bool>[];
    final sub = Library.saved.stream.listen((e) => saves.add(e.quiet));
    const hour = Duration(hours: 1);
    await lib.record(_movie, position: const Duration(minutes: 5), duration: hour, quiet: true);
    expect(told, 0);
    expect((await Library.load('quiet', mainProfileId)).entry(_movie)?.position, const Duration(minutes: 5));
    await lib.record(_movie, position: const Duration(minutes: 6), duration: hour);
    expect(told, 1);
    expect(saves, [true, false]);
    await sub.cancel();
  });

  test('favorites toggle and survive a reload', () async {
    final lib = await Library.load('p', mainProfileId);
    await lib.toggleFavorite(_movie);
    expect(lib.isFavorite(_movie), isTrue);
    expect((await Library.load('p', mainProfileId)).favorites(MediaKind.movie).single.title, 'Film');
    await lib.toggleFavorite(_movie);
    expect((await Library.load('p', mainProfileId)).favorites(MediaKind.movie), isEmpty);
  });

  test('My list and where it was left go by title: another copy of it counts as the same', () async {
    final lib = await Library.load('p', mainProfileId);
    const latino = MediaRef(kind: MediaKind.movie, id: 'lat', title: 'Heat (1995)', year: 1995);
    const uhd = MediaRef(kind: MediaKind.movie, id: '4k', title: 'Heat [4K]', year: 1995);
    const remake = MediaRef(kind: MediaKind.movie, id: 'new', title: 'Heat', year: 2026);
    await lib.toggleFavorite(latino);
    expect((lib.isFavorite(uhd), lib.isFavorite(remake)), (true, false), reason: 'another year, another film');
    await lib.toggleFavorite(uhd);
    expect(lib.isFavorite(latino), isFalse, reason: 'taken out from the other copy');
    expect(lib.favorites(MediaKind.movie), isEmpty);

    const hour = Duration(hours: 1);
    await lib.record(latino, position: const Duration(minutes: 40), duration: hour);
    expect(lib.entry(uhd)?.position, const Duration(minutes: 40), reason: 'goes on from there in 4K');
    expect(lib.entry(remake), isNull);
    await lib.record(uhd, position: const Duration(minutes: 45), duration: hour);
    expect([for (final h in lib.continueWatching) h.ref.id], ['4k'], reason: 'once, the latest copy');

    // An episode of another copy of the series
    const otherShow = Series(id: 's9', name: 'Show [4K] (2021)');
    final copy = MediaRef.episode(otherShow, const Episode(id: 'x2', season: 1, number: 2, title: 'Part 2'));
    await lib.record(_ep(2), position: const Duration(minutes: 7), duration: hour);
    expect(lib.entry(copy)?.position, const Duration(minutes: 7));
    expect(
      lib.entry(MediaRef.episode(otherShow, const Episode(id: 'x3', season: 1, number: 3, title: 'Part 3'))),
      isNull,
    );
  });

  test('what was left half watched on another device shows here, for a while', () async {
    final lib = await Library.load('p', mainProfileId);
    const hour = Duration(hours: 1), half = Duration(minutes: 30);
    await lib.record(_movie, position: half, duration: hour, device: 'Living room TV');
    final at = lib.entry(_movie)!.updated;
    expect(lib.entry(_movie)!.device, 'Living room TV');
    expect(lib.leftElsewhere(here: 'Laptop', now: at.add(const Duration(minutes: 20)))?.ref.key, _movie.key);
    expect(lib.leftElsewhere(here: 'Living room TV', now: at), isNull); // left here
    expect(lib.leftElsewhere(here: 'Laptop', now: at.add(const Duration(hours: 13))), isNull); // too long ago
    // The device travels with the history, through a reload and a merge
    final other = Library.fromJson({});
    other.merge((await Library.load('p', mainProfileId)).toJson());
    expect(other.entry(_movie)!.device, 'Living room TV');
    // Live TV does not count; watching something here since does
    await lib.record(
      const MediaRef(kind: MediaKind.live, id: 'c1', title: 'News'),
      device: 'Laptop',
    );
    expect(lib.leftElsewhere(here: 'Laptop', now: at), isNotNull);
    await lib.record(_ep(1), position: half, duration: hour, device: 'Laptop');
    expect(lib.leftElsewhere(here: 'Laptop', now: at), isNull);
    // Saved before devices were noted: nothing to say
    expect(
      Library.fromJson({
        'history': [
          {'ref': _movie.toJson(), 'pos': half.inMilliseconds, 'dur': hour.inMilliseconds, 'at': 1},
        ],
      }).leftElsewhere(here: 'Laptop', now: DateTime.fromMillisecondsSinceEpoch(1)),
      isNull,
    );
  });

  test('a device on an older version, which drops the device name, does not take it away', () async {
    final lib = await Library.load('p', mainProfileId);
    await lib.record(_movie, position: const Duration(minutes: 30), duration: const Duration(hours: 1), device: 'TV');
    final older = lib.toJson();
    for (final h in older['history'] as List) {
      (h as Map).remove('dev');
    }
    lib.merge(older);
    expect(lib.entry(_movie)!.device, 'TV');
  });

  test('only started, unfinished items are resumable', () async {
    final lib = await Library.load('p', mainProfileId);
    const hour = Duration(hours: 1);
    await lib.record(_movie, position: const Duration(seconds: 10), duration: hour);
    expect(lib.entry(_movie)!.resumable, isFalse); // barely started
    await lib.record(_movie, position: const Duration(minutes: 20), duration: hour);
    expect(lib.entry(_movie)!.resumable, isTrue);
    await lib.record(_movie, position: const Duration(minutes: 58), duration: hour);
    expect(lib.entry(_movie)!.resumable, isFalse); // practically finished
  });

  test('continue watching shows a series once, with its latest episode', () async {
    final lib = await Library.load('p', mainProfileId);
    const hour = Duration(hours: 1);
    await lib.record(_ep(1), position: const Duration(minutes: 10), duration: hour);
    await lib.record(_ep(2), position: const Duration(minutes: 5), duration: hour);
    await lib.record(_movie, position: const Duration(minutes: 30), duration: hour);
    final cont = lib.continueWatching;
    expect(cont.map((h) => h.ref.id), ['m1', 'e2']);
    expect(lib.lastEpisodeOf('s1')!.ref.number, 2);
    expect(_ep(2).title, 'Part 2'); // repeated series name and SxxExx are dropped
  });

  test('live channels go to "recent" but never to continue watching', () async {
    final lib = await Library.load('p', mainProfileId);
    const ch = MediaRef(kind: MediaKind.live, id: 'c1', title: 'News');
    await lib.record(ch);
    expect(lib.recent(MediaKind.live).single.id, 'c1');
    expect(lib.continueWatching, isEmpty);
  });

  test('history is capped and most recent first', () async {
    final lib = await Library.load('p', mainProfileId);
    for (var i = 0; i < Library.maxHistory + 5; i++) {
      await lib.record(MediaRef(kind: MediaKind.movie, id: '$i', title: '$i'));
    }
    expect(lib.history, hasLength(Library.maxHistory));
    expect(lib.history.first.ref.id, '${Library.maxHistory + 4}');
  });

  test('zapping through channels does not push titles out of the history', () async {
    final lib = await Library.load('p', mainProfileId);
    await lib.record(
      const MediaRef(kind: MediaKind.movie, id: 'film', title: 'Film'),
      position: const Duration(minutes: 5),
    );
    for (var i = 0; i < Library.maxHistory + 5; i++) {
      await lib.record(MediaRef(kind: MediaKind.live, id: '$i', title: '$i'));
    }
    expect(lib.recent(MediaKind.live), hasLength(Library.maxLive));
    expect(lib.recent(MediaKind.movie).single.id, 'film');
  });

  test('each profile has its own library', () async {
    final mine = await Library.load('p', mainProfileId);
    await mine.toggleFavorite(const MediaRef(kind: MediaKind.movie, id: '1', title: 'Mine'));
    final kids = await Library.load('p', 'kids');
    expect(kids.favorites(MediaKind.movie), isEmpty);
    await kids.toggleFavorite(const MediaRef(kind: MediaKind.movie, id: '2', title: 'Theirs'));
    await Library.dropProfile('kids');
    expect((await Library.load('p', 'kids')).favorites(MediaKind.movie), isEmpty);
    expect((await Library.load('p', mainProfileId)).favorites(MediaKind.movie).single.title, 'Mine');
  });

  test('search folding ignores case and accents', () {
    expect(fold('Acción ÉPICA'), 'accion epica');
    expect(fold('Pequeño'), 'pequeno');
  });
}
