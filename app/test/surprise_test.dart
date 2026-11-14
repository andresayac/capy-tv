// "Surprise me": a title for a mood, well rated, not watched, never the same twice.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/surprise.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final data = CatalogData(
    live: const [],
    movies: [
      for (final (id, name, genre, rating) in [
        ('1', 'Superbad', 'Comedia', 7.6),
        ('2', 'The Mask', 'Comedy, Fantasy', 7.0),
        ('3', 'Heat', 'Acción, Crimen', 8.3),
        ('4', 'Bad comedy', 'Comedia', 4.1),
        ('5', 'Superbad [4K]', 'Comedia', 7.6),
      ])
        Movie(id: id, name: name, genre: genre, rating: rating, year: 2007, poster: 'p$id', added: DateTime(2026)),
    ],
    series: const [],
  );

  test('for a mood: its genres, well rated, each title once and never twice, then nothing', () async {
    SharedPreferences.setMockInitialValues({});
    final library = await Library.load('p', 'kid');
    final surprise = Surprise(data, library, random: Random(1));
    final picks = <String?>[for (var i = 0; i < 3; i++) (surprise.next(Mood.laugh, series: false) as Movie?)?.name];
    expect(picks.take(2), unorderedEquals(['Superbad', 'The Mask']), reason: 'Superbad once, whatever its copies');
    expect(picks.last, isNull, reason: 'nothing left; a badly rated one is never offered');
    expect((surprise.next(Mood.action, series: false) as Movie).name, 'Heat');
  });

  test('never what the profile watched', () async {
    SharedPreferences.setMockInitialValues({});
    final library = await Library.load('p', 'me');
    await library.record(
      MediaRef.movie(data.movies[0]),
      position: const Duration(minutes: 90),
      duration: const Duration(minutes: 100),
    );
    final surprise = Surprise(data, library, random: Random(1));
    expect((surprise.next(Mood.laugh, series: false) as Movie).name, 'The Mask');
    expect(surprise.next(Mood.laugh, series: false), isNull);
  });

  test('one only opened, or that failed to start, is still offered', () async {
    SharedPreferences.setMockInitialValues({});
    final library = await Library.load('p', 'me');
    for (final m in data.movies) {
      await library.record(MediaRef.movie(m), duration: const Duration(minutes: 100));
    }
    final surprise = Surprise(data, library, random: Random(1));
    expect(surprise.next(Mood.laugh, series: false), isNotNull);
  });

  test('a list with no genres nor ratings (an M3U) gets one at random, but not for a kids profile', () async {
    SharedPreferences.setMockInitialValues({});
    final library = await Library.load('p', 'me');
    final bare = CatalogData(
      live: const [],
      movies: [
        for (final (id, name) in [('1', 'Film A'), ('2', 'Film B')])
          Movie(id: id, name: name, poster: 'p$id', added: DateTime(2026)),
        const Movie(id: '3', name: 'No poster'),
      ],
      series: const [],
    );
    final surprise = Surprise(bare, library, random: Random(1));
    expect(surprise.picksByMood(series: false), isFalse);
    final picks = {for (var i = 0; i < 3; i++) (surprise.next(Mood.scary, series: false) as Movie?)?.name};
    expect(picks, {'Film A', 'Film B', null}, reason: 'whatever the mood, each once, only those with a poster');
    expect(
      Surprise(bare, library, kids: true).next(Mood.family, series: false),
      isNull,
      reason: 'nothing says what suits',
    );
    expect(Surprise(data, library).picksByMood(series: false), isTrue);
  });

  test('moods read genres in Spanish and English, without accents', () {
    expect(Mood.action.fits(['Acción']), isTrue);
    expect(Mood.suspense.fits(['Thriller']), isTrue);
    expect(Mood.family.fits(['Animación']), isTrue);
    expect(Mood.different.fits(['Ciencia ficción']), isTrue);
    expect(Mood.romance.fits(['Drama']), isFalse);
    // As Spanish panels write them
    expect(Mood.action.fits(['Bélica']), isTrue);
    expect(Mood.action.fits(['Guerra']), isTrue);
    expect(Mood.suspense.fits(['Policial']), isTrue);
    expect(Mood.family.fits(['Niños']), isTrue);
    expect(Mood.family.fits(['Dibujos animados']), isTrue);
    expect(Mood.laugh.fits(['Comedias']), isTrue);
    expect(Mood.different.fits(['Documentales']), isTrue);
    expect(Mood.family.fits(['Infantiles']), isTrue);
    expect(Mood.different.fits(['Sci-Fi & Fantasy']), isTrue);
    // Words that only start like a genre's
    expect(Mood.action.fits(['War']), isTrue);
    for (final g in ['Award winners', 'Warner', 'Warriors', 'Swarm']) {
      expect(Mood.action.fits([g]), isFalse, reason: g);
    }
  });
}
