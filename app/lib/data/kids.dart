import 'catalog.dart';
import 'library.dart';
import 'matching.dart';
import 'models.dart';
import 'profiles.dart';
import 'source.dart';

// What a kids profile is offered is a list of what may be seen, not of what may not: most panels
// send no genre nor age in their lists, and what nobody vouches for stays out.

/// A source that can keep to what a kids profile may see, wherever its lists end up.
abstract interface class KidsFilter {
  abstract bool kidsOnly;
}

/// Has [source] list only what [profile] may see.
void limitTo(ContentSource source, Profile profile) {
  source.hideAdult = !profile.showsAdult;
  if (source case final KidsFilter k) k.kidsOnly = profile.kids;
}

// Not animation nor a studio: real panels file adult cartoons and superheroes under those
const _categoryWords = {
  'infantil', 'infantiles', 'kid', 'kids', 'nino', 'ninos', 'nina', 'ninas', 'children', 'familia', 'familiar', //
  'family', 'dibujos', 'cartoon', 'cartoons', 'nickelodeon',
};
const _neverCategoryWords = {'anime', 'animes'};
final _olderAge = RegExp(r'\+\s?(1[3-9]|[2-9]\d)'); // "Animadas +16"
// Not animation: series for adults have it too
const _genres = {'familia', 'family', 'infantil', 'kids', 'ninos', 'children'};
const _neverGenres = {'terror', 'horror', 'erot', 'thriller', 'crimen', 'crime', 'belic', 'gore', 'slasher'};

/// Whether a category's name says it is for children ("Infantiles", "Kids", "Dibujos animados"...).
bool isKidsCategory(String name) {
  final words = looseTitle(name).split(' ');
  return !_olderAge.hasMatch(name) && words.any(_categoryWords.contains) && !words.any(_neverCategoryWords.contains);
}

bool _anyOf(List<String> genres, Set<String> words) => genres.any((g) {
  final f = looseTitle(g);
  return words.any(f.contains);
});

/// Whether an age rating, where a provider gives one, is for adults.
bool isAdultRating(String? rating) {
  final r = rating?.trim().toUpperCase() ?? '';
  return const {'R', 'NC-17', 'TV-MA'}.contains(r) || r.contains('18');
}

final _listed = Expando<Map<MediaKind, Set<String>>>();

/// Whether [source]'s profile may still see [r] of its library, which remembers what it saw when it
/// was allowed more: only what its lists have now. [data] is those lists, null until they are in or
/// when they failed: a kids profile waits, anyone else keeps their rows.
bool libraryShows(MediaRef r, CatalogData? data, ContentSource source) {
  if (!source.hideAdult) return true;
  final kids = switch (source) {
    final KidsFilter k => k.kidsOnly,
    _ => false,
  };
  if (data == null) return !kids;
  final listed = _listed[data] ??= {
    MediaKind.live: {for (final c in data.live) c.id},
    MediaKind.movie: {for (final m in data.movies) m.id},
    MediaKind.series: {for (final s in data.series) s.id},
  };
  final (kind, id) = r.kind == MediaKind.episode ? (MediaKind.series, r.seriesId) : (r.kind, r.id);
  final known = listed[kind]!;
  // An empty list may be one that failed; to a kids profile it can as well be all it may see
  return known.contains(id) || (known.isEmpty && !kids);
}

/// Whether a kids profile may see [item], a channel, movie or series: from a category for children
/// or of a genre for them, and in neither case of a genre or age rating that rules it out.
bool kidsMaySee(Object? item, {required bool inKidsCategory}) {
  final (genres, rating) = switch (item) {
    final Movie m => (m.genres, m.ageRating),
    final Series s => (s.genres, null),
    _ => (const <String>[], null),
  };
  if (_anyOf(genres, _neverGenres) || isAdultRating(rating)) return false;
  return inKidsCategory || _anyOf(genres, _genres);
}
