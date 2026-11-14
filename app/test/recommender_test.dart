// Recommendations from a language model: what is sent, what can be picked, what is kept.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/recommender.dart';
import 'package:iptv_player/data/trending.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _service = AiService(baseUrl: 'https://ai.test/v1/', model: 'small', apiKey: 'secret');

final _data = CatalogData(
  live: const [],
  movies: [
    for (final (id, name, genre) in [
      ('1', 'Ozark', 'Crime'),
      ('2', 'Heat', 'Crime, Action'),
      ('3', 'Paddington', 'Family'),
      ('4', 'The Town', 'Crime'),
    ])
      Movie(id: id, name: name, rating: 8, year: 2024, genre: genre, poster: 'https://img.test/$id.jpg'),
  ],
  series: const [Series(id: 's1', name: 'MobLand', rating: 8.5, year: 2025, cover: 'https://img.test/s1.jpg')],
  now: DateTime(2026, 11, 6),
);

/// A model that picks [ids] (candidate codes), and the requests it got.
(MockClient, List<http.Request>) _model(String Function(List<Map<String, dynamic>> messages) answer) {
  final requests = <http.Request>[];
  final client = MockClient((req) async {
    requests.add(req);
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final messages = [for (final m in body['messages'] as List) m as Map<String, dynamic>];
    return http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': answer(messages)},
            },
          ],
        }),
      ),
      200,
    );
  });
  return (client, requests);
}

/// The code of [name] among the candidates of a prompt; null when it is not one.
String? _code(List<Map<String, dynamic>> messages, String name) =>
    RegExp(r'(c\d+) \| \w+ \| ' + name).firstMatch(messages.last['content'] as String)?.group(1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Library library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    Trending.items.value = const [];
    library = await Library.load('p', mainProfileId);
    await library.record(
      MediaRef.movie(_data.movies.first),
      position: const Duration(minutes: 50),
      duration: const Duration(minutes: 60),
    );
  });

  test('what it is told: what the profile watched, and only titles it has not', () {
    final taste = Recommender.tasteOf(library);
    expect(taste.watched, ['Ozark (2024)']);
    final candidates = Recommender.candidatesFor(_data, taste);
    expect(candidates.whereType<Movie>().map((m) => m.name), isNot(contains('Ozark')));
    expect(candidates, contains(_data.series.first));
    final prompt = Recommender.prompt(taste, candidates, 'Spanish');
    expect(prompt.first['content'], contains('in Spanish'));
    expect(prompt.last['content'], contains('- Ozark (2024)'));
    expect(prompt.last['content'], contains('| movie | Heat (2024) | Crime, Action'));
  });

  test('a title watched long ago is not offered as new, though the prompt only tells the latest', () async {
    for (var i = 0; i < 30; i++) {
      await library.record(
        MediaRef.movie(Movie(id: 'x$i', name: 'Other $i')),
        position: const Duration(minutes: 50),
        duration: const Duration(minutes: 60),
      );
    }
    final taste = Recommender.tasteOf(library);
    expect(taste.watched, hasLength(25));
    expect(taste.watched, isNot(contains('Ozark (2024)')));
    expect(Recommender.candidatesFor(_data, taste).whereType<Movie>().map((m) => m.name), isNot(contains('Ozark')));
  });

  test('nothing for adults goes to the model, whatever the profile may watch', () async {
    final data = CatalogData(
      live: const [],
      movies: [
        for (final (id, name, genre, rating) in [
          ('a1', 'XXX Night', 'Drama', null),
          ('a2', 'Quiet Film', 'Adultos', null),
          ('a3', 'Rated', 'Drama', 'NC-17'),
          ('ok', 'Fine Film', 'Drama', 'PG'),
        ])
          Movie(id: id, name: name, rating: 8, year: 2026, genre: genre, ageRating: rating, poster: 'p$id'),
      ],
      series: const [],
      now: DateTime(2026, 11, 6),
    );
    await library.record(
      MediaRef.movie(const Movie(id: 'x', name: 'XXX Classics')),
      position: const Duration(minutes: 50),
      duration: const Duration(minutes: 60),
    );
    final taste = Recommender.tasteOf(library);
    expect(taste.watched.join(), isNot(contains('XXX')));
    expect(Recommender.candidatesFor(data, taste).whereType<Movie>().map((m) => m.id), ['ok']);
  });

  test('picks only known candidates, each once, whatever surrounds the JSON', () {
    final candidates = <Object>[..._data.movies, _data.series.first];
    final picks = Recommender.parse(
      '<think>They like crime.</think>\n```json\n{"picks":[{"id":"c1","why":"Like Ozark"},'
      '{"id":"c99","why":"made up"},{"id":"c1","why":"again"},{"id":"4","why":"No c"}]}\n```',
      candidates,
    );
    expect([for (final p in picks) (p.item as dynamic).name], ['Heat', 'MobLand']);
    expect(picks.first.why, 'Like Ozark');
    expect(Recommender.parse('Sorry, I cannot help.', candidates), isEmpty);
  });

  test('asks the service with the standard API, keeps the answer per profile, asks again when due', () async {
    final (client, requests) = _model(
      (m) => jsonEncode({
        'picks': [
          for (final (name, why) in [('Heat', 'Porque viste Ozark'), ('MobLand', 'Crimen y familia')])
            if (_code(m, name) case final code?) {'id': code, 'why': why},
        ],
      }),
    );
    final now = DateTime(2026, 11, 6, 20);

    final picks = await Recommender.refresh(
      library,
      _data,
      language: 'Spanish',
      using: _service,
      client: client,
      now: now,
    );
    expect([for (final p in picks!) p.why], ['Porque viste Ozark', 'Crimen y familia']);
    final req = requests.single;
    expect(req.url.toString(), 'https://ai.test/v1/chat/completions');
    expect(req.headers['Authorization'], 'Bearer secret');
    expect(jsonDecode(req.body), containsPair('model', 'small'));
    expect(jsonDecode(req.body)['response_format'], {'type': 'json_object'});

    // Kept: shown at once next time, found again in the catalog
    final kept = await Recommender.kept(library, _data);
    expect([for (final p in kept) (p.item as dynamic).id], ['2', 's1']);
    expect(await Recommender.kept(await Library.load('p', 'other-profile'), _data), isEmpty);

    // Not asked again while fresh and the taste is the same
    expect(
      await Recommender.refresh(
        library,
        _data,
        language: 'Spanish',
        using: _service,
        client: client,
        now: now.add(const Duration(hours: 2)),
      ),
      isNull,
    );
    // Saved while the clock was ahead, now set right: asked again rather than kept for good
    await Recommender.refresh(
      library,
      _data,
      language: 'Spanish',
      using: _service,
      client: client,
      now: now.subtract(const Duration(days: 1)),
    );
    expect(requests, hasLength(2), reason: 'saved in what is now the future');
    // Something new watched: asked again, once half an hour has passed
    await library.record(
      MediaRef.movie(_data.movies[1]),
      position: const Duration(minutes: 90),
      duration: const Duration(minutes: 100),
    );
    await Recommender.refresh(
      library,
      _data,
      language: 'Spanish',
      using: _service,
      client: client,
      now: now.add(const Duration(hours: 3)),
    );
    expect(requests, hasLength(3));
    // And after twelve hours anyway
    await Recommender.refresh(
      library,
      _data,
      language: 'Spanish',
      using: _service,
      client: client,
      now: now.add(const Duration(hours: 16)),
    );
    expect(requests, hasLength(4));
  });

  test('nothing watched yet: nothing to ask', () async {
    final (client, requests) = _model((_) => '{}');
    final empty = await Library.load('p', 'new-profile');
    expect(await Recommender.refresh(empty, _data, language: 'English', using: _service, client: client), isNull);
    expect(requests, isEmpty);
  });

  test('a wrong key, a missing model, a service down', () async {
    Future<AiProblem?> problem(int status) async {
      try {
        await Recommender.test(_service, client: MockClient((_) async => http.Response('', status)));
        return null;
      } on AiException catch (e) {
        return e.problem;
      }
    }

    expect(await problem(401), AiProblem.key);
    expect(await problem(404), AiProblem.model);
    expect(await problem(500), AiProblem.busy, reason: 'down for now: not the address to check');
    expect(await problem(429), AiProblem.busy, reason: 'out of quota');
    expect(await problem(418), AiProblem.service);
    expect(
      await Recommender.test(
        _service,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'OK'},
                },
              ],
            }),
            200,
          ),
        ),
      ).then((_) => 'fine'),
      'fine',
    );
  });

  test('a model that refuses a temperature is asked once more without one', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      bodies.add(body);
      if (body.containsKey('temperature')) return http.Response('', 400);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'OK'},
            },
          ],
        }),
        200,
      );
    });
    await Recommender.test(_service, client: client);
    expect(bodies.last.containsKey('temperature'), isFalse);
  });

  test('a key the vault lost: said, and the services that work take over', () async {
    const builtIn = AiService(baseUrl: 'https://ai.test/v1', model: 'family');
    await Recommender.load(builtIn: builtIn);
    await Recommender.configure(_service);
    expect(Recommender.usingOwn, isTrue);
    FlutterSecureStorage.setMockInitialValues({}); // the vault reset, as after a restore elsewhere
    await Recommender.load(builtIn: builtIn);
    expect(Recommender.keyLost, isTrue);
    expect(Recommender.service.value, same(builtIn), reason: 'not the own service, which would only fail');
    await Recommender.configure(null);
    expect(Recommender.keyLost, isFalse);
  });

  test("which service: this device's own, else the sync server's, else the built-in one; off is off", () async {
    const builtIn = AiService(baseUrl: 'https://ai.test/v1', model: 'family');
    await Recommender.load(builtIn: builtIn);
    expect(Recommender.service.value, same(builtIn), reason: 'nothing to set up');
    expect(Recommender.usingBuiltIn, isTrue);

    final asked = <List<Map<String, String>>>[];
    final server = AiService.through(
      (messages, json) async {
        asked.add(messages);
        return 'from the server';
      },
      model: 'server-model',
      baseUrl: 'sync.example',
    );
    Recommender.useServer(server);
    expect(Recommender.service.value, same(server), reason: "the server's, over the built-in one");
    expect(
      await Recommender.service.value!.chat([
        {'role': 'user', 'content': 'hi'},
      ]),
      'from the server',
    );
    expect(asked.single.single['content'], 'hi');

    await Recommender.configure(_service);
    expect(Recommender.service.value, same(_service), reason: "this device's own, over both");
    expect(Recommender.usingOwn, isTrue);

    await Recommender.turn(on: false);
    expect(Recommender.service.value, isNull);
    await Recommender.load(builtIn: builtIn);
    expect(Recommender.service.value, isNull, reason: 'off stays off after a restart');
    expect(Recommender.canTurnOn, isTrue);
    await Recommender.turn(on: true);
    // Read back from storage at the restart: the same service, another object
    expect(Recommender.service.value?.model, _service.model);
    expect(Recommender.usingOwn, isTrue);

    await Recommender.configure(null);
    expect(Recommender.service.value, same(server), reason: "without its own, the server's again");
    Recommender.useServer(null);
    expect(Recommender.service.value, same(builtIn), reason: 'signed out: the built-in one');
  });

  test("the server's troubles come back as the service's", () async {
    final down = AiService.through((_, _) async => throw Exception('502'), model: 'm', baseUrl: 's');
    expect(
      () => down.chat([
        {'role': 'user', 'content': 'hi'},
      ]),
      throwsA(isA<AiException>().having((e) => e.problem, 'problem', AiProblem.service)),
    );
  });

  test('a server that does not know the JSON format is asked again without it', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      bodies.add(body);
      if (body.containsKey('response_format')) return http.Response('unknown field', 400);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '{"picks":[]}'},
            },
          ],
        }),
        200,
      );
    });
    expect(
      await _service.chat(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        json: true,
        client: client,
      ),
      '{"picks":[]}',
    );
    expect(bodies, hasLength(2));
  });
}
