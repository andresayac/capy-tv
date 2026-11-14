// Live TV's and the guide's own groups, ahead of the provider's categories: the channels this
// profile keeps in Favorites, and those it watched last.
import '../data/catalog.dart';
import '../data/kids.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/source.dart';
import '../l10n/app_localizations.dart';

/// Ids no provider's category has (they start with a character no panel sends).
const favoriteChannelsGroup = '\u0000favorites', recentChannelsGroup = '\u0000recent';

/// The groups [lib] has channels for, in the app's language.
List<Category> liveGroups(AppLocalizations l, Library? lib, ContentSource source) {
  if (lib == null) return const [];
  final listed = currentCatalog.value?.loaded;
  bool shows(MediaRef r) => libraryShows(r, listed, source);
  return [
    if (lib.favorites(MediaKind.live).any(shows)) Category(id: favoriteChannelsGroup, name: l.favoriteChannels),
    if (lib.recent(MediaKind.live).any(shows)) Category(id: recentChannelsGroup, name: l.recentChannels),
  ];
}

/// The channels of [category]: one of [liveGroups], else the provider's own.
Future<List<LiveChannel>> liveChannelsIn(ContentSource source, Library? lib, String category) async {
  final refs = switch (category) {
    favoriteChannelsGroup => lib?.favorites(MediaKind.live),
    recentChannelsGroup => lib?.recent(MediaKind.live).take(30).toList(),
    _ => null,
  };
  if (refs == null) return source.liveChannels(category);
  // As the list has them (their guide, catch-up and number), else as they were kept
  final listed = currentCatalog.value?.loaded;
  final byId = {for (final c in listed?.live ?? const <LiveChannel>[]) c.id: c};
  return [
    for (final r in refs)
      if (libraryShows(r, listed, source))
        byId[r.id] ?? LiveChannel(id: r.id, name: r.title, icon: r.image, url: r.url, epgId: r.epgId),
  ];
}
