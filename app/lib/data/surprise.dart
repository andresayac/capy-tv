import 'dart:math';

import 'catalog.dart';
import 'library.dart';
import 'matching.dart';
import 'models.dart';

/// What someone feels like watching, told by the genres providers write, in Spanish or English.
enum Mood {
  laugh({'comedia', 'comedy', 'humor'}),
  action({'accion', 'action', 'belic', 'guerra', 'war'}), // not adventure alone: that is often a cartoon
  suspense({'suspense', 'suspenso', 'thriller', 'crimen', 'crime', 'misterio', 'mystery', 'polici'}),
  family({'familia', 'family', 'animacion', 'animation', 'infantil', 'ninos', 'dibujos', 'kids', 'musical'}),
  romance({'romance', 'romantica', 'romantico'}),
  scary({'terror', 'horror'}),
  different({
    'documental',
    'documentary',
    'historia',
    'history',
    'ciencia ficcion',
    'science fiction',
    'sci fi',
    'fantasia',
    'fantasy',
    'western',
  });

  const Mood(this.genres);

  /// Words of the genres that fit, folded. Each is the start of a genre's word ("comedia" for
  /// "Comedias", "polici" for "Policiaca"), a short one the whole word ("war", not "Warner" nor
  /// "Award winners"), and one of several words those words in a row.
  final Set<String> genres;

  bool fits(List<String> itemGenres) {
    bool anyOf(Set<String> terms) => itemGenres.any((g) {
      final words = looseTitle(g).split(' ');
      return terms.any(
        (t) => t.contains(' ')
            ? ' ${words.join(' ')} '.contains(' $t ')
            : t.length < 4
            ? words.contains(t)
            : words.any((w) => w.startsWith(t)),
      );
    });
    // An animated horror is animation too
    return anyOf(genres) && !(this == family && anyOf(scary.genres));
  }
}

/// A title picked at random for a [Mood] among the provider's well rated ones that a profile has
/// not watched: "surprise me" for an evening without a plan. Each title once, whatever its copies.
/// A catalog that says neither genres nor ratings (M3U lists, some panels) gets one at random,
/// except for a [kids] profile, where nothing says what suits it.
class Surprise {
  Surprise(this.data, this.library, {Random? random, this.kids = false}) : _random = random ?? Random();

  final CatalogData data;
  final Library? library;
  final bool kids;
  final Random _random;
  final _shown = <String>{}; // titles offered already, not offered again

  /// Whether a title of these genres, as the provider writes them ("Drama, Comedia"), suits a mood:
  /// there are few such strings and many titles, and Movie night asks six times as it opens.
  final _fits = <Mood, Map<String, bool>>{};
  bool _suitsMood(Mood mood, String? genre) => (_fits[mood] ??= {})[genre ?? ''] ??= mood.fits(splitGenres(genre));

  /// Whether the provider says enough of its [series] or its movies to pick by mood: a genre and
  /// a rating on any of them.
  bool picksByMood({required bool series}) => series
      ? data.recentSeries.any((s) => (s.rating ?? 0) > 0 && s.genres.isNotEmpty)
      : data.recentMovies.any((m) => (m.rating ?? 0) > 0 && m.genres.isNotEmpty);

  /// A movie ([series] false) or a series for [mood], or null when none is left.
  Object? next(Mood mood, {required bool series}) {
    final byMood = picksByMood(series: series);
    if (!byMood && kids) return null;
    bool suits(double? rating, String? genre) => !byMood || ((rating ?? 0) >= 6.5 && _suitsMood(mood, genre));
    // By words only: an episode does not know its series' year
    String words(String key) => key.split('|').first;
    final watched = {
      // Opened for a few seconds, or one that failed to start, is still to be offered
      for (final h in library?.history ?? const <HistoryEntry>[])
        if (h.watched) words(versionKey(h.ref.seriesTitle ?? h.ref.title, null)),
    };
    bool fresh(Object x) {
      final key = data.keyOf(x);
      return !_shown.contains(key) && !watched.contains(words(key));
    }

    final List<Object> pool = series
        ? [
            for (final s in data.recentSeries)
              if (s.cover != null && suits(s.rating, s.genre) && fresh(s)) s,
          ]
        : [
            for (final m in data.recentMovies)
              if (m.poster != null && suits(m.rating, m.genre) && fresh(m)) m,
          ];
    if (pool.isEmpty) return null;
    // The best rated of the newest first, with a little chance for the rest
    double rating(Object x) => (x is Movie ? x.rating : (x as Series).rating) ?? 0;
    final top = (pool.take(400).toList()..sort((a, b) => rating(b).compareTo(rating(a)))).take(40).toList();
    final pick = top[_random.nextInt(top.length)];
    _shown.add(data.keyOf(pick));
    return pick;
  }
}
