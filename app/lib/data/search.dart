import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'epg.dart';
import 'matching.dart';
import 'models.dart';

/// What someone typed, matched the way people type: words in any order, without accents or
/// punctuation, a word cut short counts ("bre bad"), and a slip of one letter in a word of five
/// letters or more.
class SearchQuery {
  SearchQuery(String text) : words = searchWords(text), phrase = searchWords(text).join(' ');

  final List<String> words;
  final String phrase;

  /// Too short to look for: fewer than two letters in all.
  bool get isEmpty => phrase.replaceAll(' ', '').length < 2;

  /// How well a title with these [title] words matches: null when it does not, higher when it
  /// matches better. The whole title, then its start, then every word whole, then the rest.
  int? score(List<String> title) {
    if (words.isEmpty) return null;
    var total = 0, matched = 0;
    for (final q in words) {
      var best = 0;
      for (final t in title) {
        final s = switch (t) {
          _ when t == q => 30,
          _ when t.startsWith(q) => 20,
          _ when q.length >= 3 && t.contains(q) => 8,
          _ when q.length >= 5 && t.length >= 4 && _nearly(q, t) => 6,
          _ => 0,
        };
        if (s > best) best = s;
      }
      // Written as one word what the title splits: "spiderman" for "Spider-Man", "xmen"
      if (best == 0 && q.length >= 4) {
        for (var i = 0; i < title.length - 1 && best == 0; i++) {
          if (title.sublist(i).join().startsWith(q)) best = 20;
        }
      }
      // A number written the other way: "rocky 2" for "Rocky II"
      if (best == 0 && title.contains(_sameNumber[q])) best = 30;
      if (best == 0) {
        if (_optional.contains(q)) continue; // an article the title does not carry: "the matrix"
        return null; // every other word must be there
      }
      matched++;
      total += best;
    }
    if (matched == 0) return null;
    final joined = title.join(' ');
    if (joined == phrase) {
      total += 200;
    } else if (joined.startsWith(phrase)) {
      total += 80;
    } else if (joined.contains(phrase)) {
      total += 30;
    }
    return total - (title.length - words.length).clamp(0, 20); // fewer other words, closer
  }

  /// Whether every word searched is a word of [title] or its start ("ana" is not in "mañana"): the
  /// guide's programme names are short and many, and a match inside a word would bring half of them.
  bool wholeWords(List<String> title) => words.every((q) => _optional.contains(q) || title.any((t) => t.startsWith(q)));

  /// Articles a search may carry and a title may not.
  static const _optional = {
    'the',
    'a',
    'an',
    'el',
    'la',
    'los',
    'las',
    'un',
    'una',
    'le',
    'les',
    'der',
    'die',
    'das',
    'il',
  };

  /// Numbers 2 to 10 in Roman numerals and digits, each to the other.
  static final _sameNumber = {
    for (final (i, r) in ['ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x'].indexed) ...{
      r: '${i + 2}',
      '${i + 2}': r,
    },
  };

  /// One letter changed, added or missing; or [q] so typed at the start of a longer [t].
  static bool _nearly(String q, String t) {
    bool oneEdit(String a, String b) {
      if ((a.length - b.length).abs() > 1) return false;
      var i = 0, j = 0, edits = 0;
      while (i < a.length && j < b.length) {
        if (a[i] == b[j]) {
          i++;
          j++;
          continue;
        }
        if (++edits > 1) return false;
        if (a.length > b.length) {
          i++;
        } else if (b.length > a.length) {
          j++;
        } else {
          i++;
          j++;
        }
      }
      return edits + (a.length - i) + (b.length - j) <= 1;
    }

    if (oneEdit(q, t)) return true;
    // A word cut short with a slip in it: "spidr" for "spiderman"
    return q.length >= 5 && t.length > q.length && oneEdit(q, t.substring(0, min(t.length, q.length)));
  }
}

/// A playlist's catalog made searchable: every title's words, worked out once off the UI thread.
class SearchIndex {
  SearchIndex._(this.data, this._movies, this._series, this._live);

  final CatalogData data;
  final List<List<String>> _movies, _series, _live;

  static final _built = Expando<Future<SearchIndex>>();

  /// The index of [data], built the first time it is asked for.
  static Future<SearchIndex> of(CatalogData data) => _built[data] ??= () async {
    final words = await compute(_wordsOf, [
      [for (final m in data.movies) m.name],
      [for (final s in data.series) s.name],
      [for (final c in data.live) c.name],
    ]);
    return SearchIndex._(data, words[0], words[1], words[2]);
  }();

  static List<List<List<String>>> _wordsOf(List<List<String>> names) {
    // One copy of each word and of each title's words: titles repeat, a version per language or
    // quality, and their words much more
    final words = <String, String>{}, titles = <String, List<String>>{};
    List<String> wordsOf(String name) {
      final found = searchWords(name);
      if (found.isEmpty) return const [];
      return titles[found.join(' ')] ??= List.generate(
        found.length,
        (i) => words[found[i]] ??= found[i],
        growable: false,
      );
    }

    return [for (final list in names) List.generate(list.length, (i) => wordsOf(list[i]), growable: false)];
  }

  /// What matches [q], best first; at equal match, the most recent and best rated. Movies and
  /// series the provider lists more than once, a version per language or quality, come as one:
  /// the same words and year.
  SearchResults search(SearchQuery q) {
    List<List<T>> ranked<T>(
      List<T> items,
      List<List<String>> words,
      int? Function(T) year,
      double? Function(T) rating,
    ) {
      // At equal match, by year and rating: worked out once per hit, not in each comparison
      num tieBreak(T x) => (year(x) ?? 0) * 10 + (rating(x) ?? 0);
      final hits = <(T, int, String, num)>[];
      for (var i = 0; i < items.length; i++) {
        if (q.score(words[i]) case final s?) {
          final x = items[i];
          hits.add((x, s, data.keyOf(x as Object), tieBreak(x)));
        }
      }
      hits.sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : b.$4.compareTo(a.$4));
      final groups = <String, List<T>>{}; // in the order of their best version
      for (final (x, _, key, _) in hits) {
        (groups[key] ??= []).add(x);
      }
      return groups.values.toList();
    }

    return SearchResults(
      movies: ranked(data.movies, _movies, (m) => m.year ?? yearInTitle(m.name), (m) => m.rating),
      series: ranked(data.series, _series, (s) => s.year ?? yearInTitle(s.name), (s) => s.rating),
      channels: _channels(q),
    );
  }

  /// The channels that match [q], best first; at equal match by their number ("ESPN 1" before
  /// "ESPN 29"), and those with none by name.
  List<LiveChannel> _channels(SearchQuery q) {
    final hits = <(LiveChannel, int)>[];
    for (var i = 0; i < data.live.length; i++) {
      if (q.score(_live[i]) case final s?) hits.add((data.live[i], s));
    }
    hits.sort((a, b) {
      if (a.$2 != b.$2) return b.$2.compareTo(a.$2);
      final an = a.$1.number, bn = b.$1.number;
      if (an != null && bn != null && an != bn) return an.compareTo(bn);
      if ((an == null) != (bn == null)) return an == null ? 1 : -1;
      return a.$1.name.compareTo(b.$1.name);
    });
    return [for (final (c, _) in hits) c];
  }
}

class SearchResults {
  const SearchResults({required this.movies, required this.series, required this.channels});

  final List<List<Movie>> movies; // each title with its versions, the best match first
  final List<List<Series>> series;
  final List<LiveChannel> channels;

  bool get isEmpty => movies.isEmpty && series.isEmpty && channels.isEmpty;
}

/// A programme of the guide that matches a search, with the channel that shows it.
typedef OnAir = ({LiveChannel channel, EpgEntry programme});

/// Programmes on [channels] whose title matches [q], on now or starting within [ahead]: what is
/// on now first, then by start; then, for a channel with none of those, the latest it aired and
/// still keeps (catch-up), the latest first. One per channel.
List<OnAir> searchGuide(
  EpgGuide guide,
  List<LiveChannel> channels,
  SearchQuery q, {
  DateTime? now,
  Duration ahead = const Duration(hours: 12),
}) {
  final t = now ?? DateTime.now(), until = t.add(ahead);
  final found = <OnAir>[];
  final titles = <String, bool>{}; // the same programme name comes up on many days and channels
  for (final c in channels) {
    EpgEntry? aired; // the latest that matched and is kept
    var coming = false;
    // By start, so it stops at the first programme too late, with no list of the window made
    for (final e in guide.forChannel(c.epgId)) {
      if (!e.start.isBefore(until)) break;
      final ended = !e.end.isAfter(t);
      if (ended && !c.keeps(e.end, t)) continue;
      final hit = titles.putIfAbsent(e.title, () {
        final w = searchWords(e.title);
        return q.score(w) != null && q.wholeWords(w);
      });
      if (!hit) continue;
      if (ended) {
        aired = e;
        continue;
      }
      found.add((channel: c, programme: e));
      coming = true;
      break;
    }
    if (!coming && aired != null) found.add((channel: c, programme: aired));
  }
  // On now, then coming, then aired; the aired latest first
  int rank(EpgEntry e) => e.isNow(t) ? 0 : (e.end.isAfter(t) ? 1 : 2);
  found.sort((a, b) {
    final ra = rank(a.programme), rb = rank(b.programme);
    if (ra != rb) return ra - rb;
    return ra == 2 ? b.programme.start.compareTo(a.programme.start) : a.programme.start.compareTo(b.programme.start);
  });
  return found;
}

/// The last searches of a profile, newest first, kept on the device.
class RecentSearches {
  RecentSearches._();

  static const max = 8;
  static String _key(String profileId) => 'search.recent.$profileId';

  static Future<List<String>> of(String profileId) async =>
      (await SharedPreferences.getInstance()).getStringList(_key(profileId)) ?? const [];

  /// Notes [text] as searched, on top; the same search typed differently counts once.
  static Future<void> add(String profileId, String text) async {
    final t = text.trim();
    if (SearchQuery(t).isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = [
      t,
      for (final s in prefs.getStringList(_key(profileId)) ?? const <String>[])
        if (looseTitle(s, anyScript: true) != looseTitle(t, anyScript: true)) s,
    ].take(max).toList();
    await prefs.setStringList(_key(profileId), list);
  }

  static Future<void> clear(String profileId) async => (await SharedPreferences.getInstance()).remove(_key(profileId));
}
