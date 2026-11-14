// What a kids profile is offered: only what a category or a genre says is for children.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/kids.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/m3u.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/surprise.dart';
import 'package:iptv_player/data/xtream.dart';

void main() {
  test('a category is for children by its words, not by what they are part of', () {
    for (final name in ['Infantiles', 'KIDS', '▶ Niños HD', 'Dibujos animados', '24/7 Infantiles', 'Cine familiar']) {
      expect(isKidsCategory(name), isTrue, reason: name);
    }
    // The last ones as real panels have them: adult cartoons and superheroes go under those names
    for (final name in [
      'Acción',
      'Kidnapping',
      'Anime',
      'Noticias',
      '',
      'Películas de Animación',
      '🎞️ VOD | DISNEY+',
      '⚽ EVENTOS ESPN DISNEY+',
      '24/7 Animadas +16',
      'Infantiles +16',
      'Infantiles Anime',
    ]) {
      expect(isKidsCategory(name), isFalse, reason: name);
    }
  });

  group('what may be seen', () {
    Movie movie(String? genre, {String? age}) => Movie(id: '1', name: 'M', genre: genre, ageRating: age);

    test('by its category or its genre; with neither, nothing vouches for it', () {
      expect(kidsMaySee(movie(null), inKidsCategory: true), isTrue);
      expect(kidsMaySee(movie('Familia, Comedia'), inKidsCategory: false), isTrue);
      expect(kidsMaySee(movie(null), inKidsCategory: false), isFalse);
      expect(kidsMaySee(movie('Comedia'), inKidsCategory: false), isFalse);
      expect(kidsMaySee(movie('Animación'), inKidsCategory: false), isFalse, reason: 'series for adults have it too');
    });

    test('a genre or an age that rules it out wins, even in a category for children', () {
      expect(kidsMaySee(movie('Familia, Terror'), inKidsCategory: true), isFalse);
      expect(kidsMaySee(movie('Thriller'), inKidsCategory: true), isFalse);
      expect(kidsMaySee(movie('Familia', age: 'R'), inKidsCategory: true), isFalse);
      expect(kidsMaySee(movie('Familia', age: '+18'), inKidsCategory: true), isFalse);
      expect(kidsMaySee(movie('Familia', age: 'PG'), inKidsCategory: true), isTrue);
    });

    test('a channel has only its category', () {
      const channel = LiveChannel(id: '1', name: 'C');
      expect(kidsMaySee(channel, inKidsCategory: true), isTrue);
      expect(kidsMaySee(channel, inKidsCategory: false), isFalse);
    });
  });

  group('a source', () {
    XtreamSource xtream() => XtreamSource(
      server: 'https://example.com/',
      username: 'demo',
      password: 'pw',
      client: MockClient((req) async {
        final body = switch (req.url.queryParameters['action']) {
          'get_vod_categories' => [
            {'category_id': '1', 'category_name': 'Infantiles'},
            {'category_id': '2', 'category_name': 'Comedia'},
            {'category_id': '3', 'category_name': 'Terror'},
          ],
          'get_vod_streams' => [
            {'name': 'Bunny', 'stream_id': 1, 'category_id': '1'},
            {'name': 'Scary toy', 'stream_id': 2, 'category_id': '1', 'genre': 'Horror'},
            {'name': 'Family trip', 'stream_id': 3, 'category_id': '2', 'genre': 'Family'},
            {'name': 'Office', 'stream_id': 4, 'category_id': '2', 'genre': 'Comedy'},
            {'name': 'Night', 'stream_id': 5, 'category_id': '3'},
          ],
          _ => <Object>[],
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );

    test('Xtream: its lists hold what may be seen, its categories only those with something left', () async {
      final s = xtream()..kidsOnly = true;
      expect([for (final m in await s.movies()) m.name], ['Bunny', 'Family trip']);
      expect([for (final m in await s.movies('2')) m.name], ['Family trip']);
      expect(await s.movies('3'), isEmpty);
      expect([for (final c in await s.movieCategories()) c.name], ['Infantiles', 'Comedia']);
    });

    test('Xtream: everybody else sees it all', () async {
      final s = xtream();
      expect(await s.movies(), hasLength(5));
      expect(await s.movieCategories(), hasLength(3));
    });

    test('M3U: by its groups, all it has to go by', () async {
      final s = M3uSource(
        parseM3u(
          '#EXTM3U\n'
          '#EXTINF:-1 group-title="Kids",Bunny\nhttp://x/movie/1.mp4\n'
          '#EXTINF:-1 group-title="Drama",Office\nhttp://x/movie/2.mp4\n'
          '#EXTINF:-1 group-title="Kids",Bunny TV\nhttp://x/live/3.ts\n'
          '#EXTINF:-1 group-title="News",Today\nhttp://x/live/4.ts\n',
        ),
      )..kidsOnly = true;
      expect([for (final m in await s.movies()) m.name], ['Bunny']);
      expect([for (final c in await s.liveChannels()) c.name], ['Bunny TV']);
      expect([for (final c in await s.movieCategories()) c.name], ['Kids']);
    });

    test('a profile sets it: kids only for a kids profile', () {
      final s = M3uSource(const []);
      limitTo(s, const Profile(id: 'k', name: 'Leo', kids: true));
      expect((s.kidsOnly, s.hideAdult), (true, true));
      limitTo(s, const Profile(id: 'a', name: 'Ana', adult: true));
      expect((s.kidsOnly, s.hideAdult), (false, false));
      limitTo(s, const Profile(id: 'b', name: 'Bo'));
      expect((s.kidsOnly, s.hideAdult), (false, true));
    });
  });

  group('a library, remembering what was allowed before', () {
    const kept = Movie(id: '1', name: 'Bunny'), gone = Movie(id: '2', name: 'Night');
    final data = CatalogData(
      live: const [],
      movies: const [kept],
      series: const [Series(id: '7', name: 'S')],
    );
    const episode = MediaRef(kind: MediaKind.episode, id: '70', title: 'E', seriesId: '7');
    const otherEpisode = MediaRef(kind: MediaKind.episode, id: '80', title: 'E', seriesId: '8');
    final channel = MediaRef.channel(const LiveChannel(id: '3', name: 'C'));

    test('shows only what the lists have now, an episode by its series', () {
      final s = M3uSource(const []);
      expect(libraryShows(MediaRef.movie(kept), data, s), isTrue);
      expect(libraryShows(MediaRef.movie(gone), data, s), isFalse);
      expect(libraryShows(episode, data, s), isTrue);
      expect(libraryShows(otherEpisode, data, s), isFalse);
    });

    test('whoever sees it all keeps it all', () {
      final s = M3uSource(const [])..hideAdult = false;
      expect(libraryShows(MediaRef.movie(gone), data, s), isTrue);
      expect(libraryShows(MediaRef.movie(gone), null, s), isTrue);
    });

    test('with no lists yet, or an empty one, a kids profile waits and anyone else keeps their rows', () {
      final others = M3uSource(const []);
      final kids = M3uSource(const [])..kidsOnly = true;
      expect(libraryShows(MediaRef.movie(gone), null, others), isTrue);
      expect(libraryShows(MediaRef.movie(gone), null, kids), isFalse);
      expect(libraryShows(channel, data, others), isTrue, reason: 'the channels may be what failed');
      expect(libraryShows(channel, data, kids), isFalse);
    });
  });

  test('the family mood refuses a horror that is also animation', () {
    expect(Mood.family.fits(['Animación', 'Terror']), isFalse);
    expect(Mood.family.fits(['Animación', 'Comedia']), isTrue);
    expect(Mood.scary.fits(['Terror']), isTrue);
  });
}
