import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'kids.dart' show isAdultRating;
import 'library.dart';
import 'matching.dart';
import 'models.dart';
import 'secrets.dart';
import 'source.dart';
import 'trending.dart';

/// A language model the app asks for recommendations, through the OpenAI chat completions API
/// that most services and servers speak (Ollama, OpenAI, OpenRouter, vLLM, LM Studio...).
class AiService {
  const AiService({required this.baseUrl, required this.model, this.apiKey = ''}) : _via = null;

  /// A service reached through [via], such as the account's sync server, which keeps the key.
  const AiService.through(this._via, {required this.model, required this.baseUrl}) : apiKey = '';

  final Future<String> Function(List<Map<String, String>> messages, bool json)? _via;

  /// Reached through the account's sync server.
  bool get viaServer => _via != null;

  /// Up to the API version, such as "https://ollama.com/v1".
  final String baseUrl;
  final String model;
  final String apiKey; // empty for servers that need none

  static const defaultUrl = 'https://ollama.com/v1';

  Uri get _completions => Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/chat/completions');

  /// The model's answer to [messages]; asks for JSON when [json]. Throws [AiException].
  Future<String> chat(List<Map<String, String>> messages, {bool json = false, http.Client? client}) async {
    if (_via case final via?) {
      try {
        return await via(messages, json);
      } on AiException {
        rethrow;
      } on Object catch (e) {
        throw AiException(AiProblem.service, '$e');
      }
    }
    final http.Client c = client ?? http.Client();
    try {
      Future<http.Response> send({required bool jsonFormat, bool temperature = true}) => c
          .post(
            _completions,
            headers: {'Content-Type': 'application/json', if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey'},
            body: jsonEncode({
              'model': model,
              'messages': messages,
              if (temperature) 'temperature': 0.7,
              if (jsonFormat) 'response_format': {'type': 'json_object'},
            }),
          )
          .timeout(const Duration(seconds: 90)); // large models in the cloud take their time
      var res = await send(jsonFormat: json);
      // Servers that do not know response_format: the prompt asks for JSON anyway
      if (json && res.statusCode == 400) res = await send(jsonFormat: false);
      // Models that take only their own temperature (some reasoning ones)
      if (res.statusCode == 400) res = await send(jsonFormat: false, temperature: false);
      if (res.statusCode == 401 || res.statusCode == 403) throw const AiException(AiProblem.key);
      if (res.statusCode == 404) throw const AiException(AiProblem.model);
      if (res.statusCode == 429 || res.statusCode >= 500) throw AiException(AiProblem.busy, '${res.statusCode}');
      if (res.statusCode != 200) throw AiException(AiProblem.service, '${res.statusCode}');
      final content = (((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['choices'] as List).first as Map)['message'];
      return (content as Map)['content'] as String? ?? '';
    } on AiException {
      rethrow;
    } on Object catch (e) {
      throw AiException(AiProblem.service, '$e');
    } finally {
      if (client == null) c.close();
    }
  }
}

/// [busy]: out of quota or down for now (429, 5xx); [service]: anything else, its detail the
/// status when there was one.
enum AiProblem { key, model, busy, service }

class AiException implements Exception {
  const AiException(this.problem, [this.detail = '']);

  final AiProblem problem;
  final String detail;

  @override
  String toString() => 'AiException($problem${detail.isEmpty ? '' : ': $detail'})';
}

/// A title picked for someone, with why in a few words.
class Pick {
  const Pick(this.item, this.why);

  final Object item; // a Movie or a Series of the playlist
  final String why;
}

/// Recommendations for each profile from a language model ([AiService]): the one set up on this
/// device in Account; else the one the account's sync server offers, which keeps its key; else
/// the one built into the app. Turned off in Account, none of them: it reads the titles the profile watched and keeps in its list, and picks from the
/// provider's catalog what that person has not seen, saying why. It can only pick from the titles
/// it is given, so it never suggests something the provider lacks. Only titles go out: no
/// credentials, no addresses, nothing about the device. Kids profiles do not use it.
///
/// Answers are kept per playlist and profile, and asked again after [maxAge], or sooner when
/// the profile watched something new.
class Recommender {
  Recommender._();

  /// The service in use, null when there is none or recommendations are off.
  static final service = ValueNotifier<AiService?>(null);

  static AiService? _own, _server, _builtIn;
  static var _off = false;

  /// Turned off in Account.
  static bool get off => _off;

  /// Whether there is a service to turn back on without setting one up.
  static bool get canTurnOn => _own != null || _server != null || _builtIn != null;

  static void _choose() => service.value = _off ? null : _own ?? _server ?? _builtIn;

  /// The sync server's service (see [AiService.through]), or null when it offers none.
  static void useServer(AiService? s) {
    _server = s;
    _choose();
  }

  static const maxAge = Duration(hours: 12);
  static const _minAge = Duration(minutes: 30); // between asks when only the taste changed
  static const _picks = 12;
  static const _secrets = appSecrets;

  /// The service built into the app (`--dart-define=AI_MODEL=...`, `AI_BASE_URL`, `AI_API_KEY`), so
  /// a family gets recommendations without setting anything up; null when there is none.
  static AiService? get builtIn => const String.fromEnvironment('AI_MODEL').isEmpty
      ? null
      : const AiService(
          baseUrl: String.fromEnvironment('AI_BASE_URL', defaultValue: AiService.defaultUrl),
          model: String.fromEnvironment('AI_MODEL'),
          apiKey: String.fromEnvironment('AI_API_KEY'),
        );

  /// Whether the service in use is the one built into the app.
  static bool get usingBuiltIn => service.value != null && identical(service.value, _builtIn);

  /// Whether the service in use is this device's own, set up in Account.
  static bool get usingOwn => service.value != null && identical(service.value, _own);

  /// Reads the service set up on this device and whether recommendations were turned off.
  /// Call once at startup.
  /// The service set up here had a key that can no longer be read: it is to be set up again.
  static var keyLost = false;

  static Future<void> load({AiService? builtIn}) async {
    _builtIn = builtIn ?? Recommender.builtIn;
    final prefs = await SharedPreferences.getInstance();
    _off = prefs.getBool('ai.off') ?? false;
    final url = prefs.getString('ai.baseUrl'), model = prefs.getString('ai.model');
    _own = null;
    keyLost = false;
    if (url != null && model != null) {
      String? key;
      try {
        key = await _secrets.read(key: 'ai.apiKey');
      } on Object {
        key = null; // no vault (tests): no key
      }
      if ((key == null || key.isEmpty) && (prefs.getBool('ai.hasKey') ?? false)) {
        // It had one, now gone (the vault reset): without it the service only fails, and would hide
        // the server's or the built-in one
        keyLost = true;
      } else {
        _own = AiService(baseUrl: url, model: model, apiKey: key ?? '');
      }
    }
    _choose();
  }

  /// Sets up [s] as this device's own service; null forgets it, for the server's or the built-in
  /// one. The recommendations of the one before are forgotten.
  static Future<void> configure(AiService? s) async {
    final prefs = await SharedPreferences.getInstance();
    if (s == null) {
      await prefs.remove('ai.baseUrl');
      await prefs.remove('ai.model');
      await prefs.remove('ai.hasKey');
      await _secrets.delete(key: 'ai.apiKey');
    } else {
      await prefs.setString('ai.baseUrl', s.baseUrl);
      await prefs.setString('ai.model', s.model);
      await _secrets.write(key: 'ai.apiKey', value: s.apiKey);
      await prefs.setBool('ai.hasKey', s.apiKey.isNotEmpty);
    }
    keyLost = false;
    await _forgetPicks(prefs);
    _own = s;
    _off = false;
    await prefs.setBool('ai.off', false);
    _choose();
  }

  /// Turns recommendations off ([on] false) or back on, whatever the service.
  static Future<void> turn({required bool on}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ai.off', !on);
    if (!on) await _forgetPicks(prefs);
    _off = !on;
    _choose();
  }

  static Future<void> _forgetPicks(SharedPreferences prefs) async {
    for (final k in prefs.getKeys().where((k) => k.startsWith('ai.picks.')).toList()) {
      await prefs.remove(k);
    }
  }

  /// Checks that [s] answers, before it is set up. Throws [AiException].
  static Future<void> test(AiService s, {http.Client? client}) => s.chat([
    {'role': 'user', 'content': 'Reply with the word OK.'},
  ], client: client);

  /// The picks kept for [library]'s playlist and profile, found again in [data]; empty when
  /// there are none. Quick: for Home to show at once.
  static Future<List<Pick>> kept(Library library, CatalogData data) async {
    final saved = await _current(library);
    return saved == null ? const [] : _resolve(saved['picks'] as List, data);
  }

  /// Picks from before the history was cleared say what was watched: never shown again.
  static Future<Map<String, dynamic>?> _current(Library library) async {
    final saved = await _saved(library);
    final at = DateTime.tryParse(saved?['at'] as String? ?? '');
    if (saved == null || at == null || at.millisecondsSinceEpoch >= library.clearedAt) return saved;
    await (await SharedPreferences.getInstance()).remove(_key(library));
    return null;
  }

  /// Fresh picks when the kept ones are old or the taste changed, else null (nothing to change).
  /// [language] is the one of the reasons, such as "Spanish". Throws [AiException].
  static Future<List<Pick>?> refresh(
    Library library,
    CatalogData data, {
    required String language,
    AiService? using,
    http.Client? client,
    DateTime? now,
  }) async {
    final s = using ?? service.value;
    if (s == null) return null;
    now ??= DateTime.now();
    final taste = tasteOf(library);
    if (taste.watched.isEmpty && taste.listed.isEmpty) return null; // nothing to go on yet
    final saved = await _current(library);
    final at = DateTime.tryParse(saved?['at'] as String? ?? '');
    // From the future (a clock that was ahead): asked again, not kept for good
    final age = at == null || now.isBefore(at) ? null : now.difference(at);
    final sameTaste = saved?['taste'] == taste.hash;
    if (age != null && age < maxAge && (sameTaste || age < _minAge)) return null;

    final candidates = candidatesFor(data, taste);
    if (candidates.isEmpty) return null;
    final active = service.value;
    final answer = await s.chat(prompt(taste, candidates, language), json: true, client: client);
    if (!identical(active, service.value)) return null; // changed or turned off while it thought
    final picks = parse(answer, candidates);
    if (picks.isEmpty) throw const AiException(AiProblem.service, 'no picks in the answer');
    await (await SharedPreferences.getInstance()).setString(
      _key(library),
      jsonEncode({
        'at': now.toIso8601String(),
        'taste': taste.hash,
        'picks': [
          for (final p in picks) {'kind': p.item is Series ? 'series' : 'movie', 'id': _idOf(p.item), 'why': p.why},
        ],
      }),
    );
    return picks;
  }

  /// What a profile watched (newest first, a series once) and keeps in its list.
  /// A movie or series for adults: by its name, its age rating, or a genre that says so.
  static bool _forAdults(Object x) => switch (x) {
    Movie m => isAdultTitle(m.name) || isAdultRating(m.ageRating) || isAdultCategory(m.genre ?? ''),
    Series s => isAdultTitle(s.name) || isAdultCategory(s.genre ?? ''),
    _ => false,
  };

  @visibleForTesting
  static ({List<String> watched, List<String> listed, Set<String> known, String hash}) tasteOf(Library library) {
    String described(MediaRef r) =>
        '${r.kind == MediaKind.episode ? r.seriesTitle ?? r.title : r.title}${r.year == null ? '' : ' (${r.year})'}';
    // Titles for adults stay on the device, whatever the profile may watch
    bool forAdults(MediaRef r) => isAdultTitle(r.seriesTitle ?? r.title);
    final allWatched = <String>{
      for (final h in library.history)
        if (h.watched && !forAdults(h.ref)) described(h.ref),
    };
    final allListed = <String>{
      for (final r in [...library.favorites(MediaKind.movie), ...library.favorites(MediaKind.series)])
        if (!forAdults(r)) described(r),
    };
    // The prompt takes the latest; what is never to be offered as new is all of it
    final watched = allWatched.take(25).toList(), listed = allListed.take(15).toList();
    return (
      watched: watched,
      listed: listed,
      known: {
        for (final t in [...allWatched, ...allListed]) bareTitle(t),
      },
      hash: stableHash([...watched, '|', ...listed].join('\n')),
    );
  }

  /// Titles to pick from: trending this week, best rated and new, movies and series, that the
  /// profile has not watched nor listed.
  @visibleForTesting
  static List<Object> candidatesFor(
    CatalogData data,
    ({List<String> watched, List<String> listed, Set<String> known, String hash}) taste,
  ) {
    final known = taste.known;
    final seen = <Object>{};
    return [
      for (final x in [
        for (final (trend: _, :item) in Trending.available(data)) item,
        ...data.topMovies.take(60),
        ...data.topSeries.take(40),
        ...data.newReleases.take(30),
        ...data.recentSeries.take(30),
      ])
        // Another copy of one watched is no new title: its tags and language do not count. None
        // for adults goes to the model, whatever the profile may watch
        if (!known.contains(bareTitle(_nameOf(x))) && !_forAdults(x) && seen.add(x)) x,
    ].take(150).toList();
  }

  @visibleForTesting
  static List<Map<String, String>> prompt(
    ({List<String> watched, List<String> listed, Set<String> known, String hash}) taste,
    List<Object> candidates,
    String language,
  ) {
    String line(int i, Object x) {
      final (kind, year, genre) = switch (x) {
        Movie m => ('movie', m.year, m.genre),
        Series s => ('series', s.year, s.genre),
        _ => ('', null, null),
      };
      return 'c$i | $kind | ${_nameOf(x)}${year == null ? '' : ' ($year)'}${genre == null ? '' : ' | $genre'}';
    }

    return [
      {
        'role': 'system',
        'content':
            'You recommend movies and series to one member of a family, from what their IPTV '
            'provider offers. Pick only from the candidates, by their code. Choose $_picks that '
            'this person is likely to enjoy given what they watched and keep in their list, best '
            'first, mixing movies and series when both fit. For each, write why in $language, in '
            'at most 12 words, naming something they watched when that explains it. Answer only '
            'with JSON: {"picks":[{"id":"c3","why":"..."}]}',
      },
      {
        'role': 'user',
        'content': [
          'Watched, newest first:',
          ...taste.watched.map((t) => '- $t'),
          if (taste.listed.isNotEmpty) ...['', 'In their list:', ...taste.listed.map((t) => '- $t')],
          '',
          'Candidates:',
          for (final (i, x) in candidates.indexed) line(i, x),
        ].join('\n'),
      },
    ];
  }

  /// The picks in a model's [answer], in its order: only known codes, each once. Tolerates
  /// text, reasoning or code fences around the JSON.
  @visibleForTesting
  static List<Pick> parse(String answer, List<Object> candidates) {
    final text = answer.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    final start = text.indexOf('{'), end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return const [];
    try {
      final picks = (jsonDecode(text.substring(start, end + 1)) as Map)['picks'];
      if (picks is! List) return const [];
      final seen = <int>{};
      return [
        for (final p in picks.whereType<Map>())
          if (int.tryParse('${p['id']}'.replaceFirst(RegExp('^c'), '')) case final i?
              when i >= 0 && i < candidates.length && seen.add(i))
            Pick(candidates[i], '${p['why'] ?? ''}'.trim()),
      ].take(_picks).toList();
    } on FormatException {
      return const [];
    }
  }

  static String _key(Library l) => 'ai.picks.${l.playlistId}.${l.profileId}';

  static Future<Map<String, dynamic>?> _saved(Library l) async {
    final raw = (await SharedPreferences.getInstance()).getString(_key(l));
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
  }

  static List<Pick> _resolve(List<dynamic> saved, CatalogData data) {
    final movies = {for (final m in data.movies) m.id: m}, series = {for (final s in data.series) s.id: s};
    return [
      for (final p in saved.whereType<Map>())
        if ((p['kind'] == 'series' ? series[p['id']] : movies[p['id']]) case final Object item?)
          Pick(item, '${p['why'] ?? ''}'),
    ];
  }

  static String _nameOf(Object x) => switch (x) {
    Movie m => m.name,
    Series s => s.name,
    _ => '',
  };

  static String _idOf(Object x) => switch (x) {
    Movie m => m.id,
    Series s => s.id,
    _ => '',
  };
}
