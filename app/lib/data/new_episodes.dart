import 'catalog.dart';
import 'library.dart';
import 'matching.dart';
import 'models.dart';
import 'source.dart';

/// A series a profile follows with episodes after the last one it watched.
typedef NewEpisodes = ({Series series, Episode next, int count});

/// The series a profile has been watching whose provider added episodes since: those the listing
/// says changed after the profile's last episode ([Series.updated]), then their episodes after
/// that one. Only a few series are asked about at a time, each once a session, so nothing is
/// asked of the provider for series that did not change.
class NewEpisodeFinder {
  NewEpisodeFinder(this.source);

  final ContentSource source;
  final _details = <String, Future<SeriesDetail?>>{};

  /// With [upNext], instead: the series whose last episode watched was seen to the end, whatever
  /// the provider changed, for the next one waiting ("Up next").
  Future<List<NewEpisodes>> find(Library library, CatalogData data, {int max = 8, bool upNext = false}) async {
    final series = {for (final s in data.series) s.id: s};
    // The latest episode watched of each series, newest first
    // By title: two copies of a series (4K, another provider) are one, at the latest episode in either
    final last = <String, HistoryEntry>{};
    for (final h in library.history) {
      if (h.ref.kind != MediaKind.episode || h.ref.seriesId == null) continue;
      // For what comes next, one only opened (the next episode starting by itself, left within
      // seconds) is passed over: the one seen to the end before it still says what is next
      if (upNext && !h.resumable && h.progress < 0.95) continue;
      last.putIfAbsent(seriesKey(h.ref), () => h);
    }
    final changed = [
      for (final h in last.values)
        // Still in the middle of the last one: that is "Continue watching", not news
        if (series[h.ref.seriesId] case final s?
            when !h.resumable &&
                (upNext
                    ? h.progress >= 0.95 && !(s.updated?.isAfter(h.updated) ?? false)
                    : s.updated != null && s.updated!.isAfter(h.updated)))
          (s, h),
    ].take(max);
    final found = <NewEpisodes>[];
    for (final (s, h) in changed) {
      final d = await (_details[s.id] ??= source.seriesDetail(s).then<SeriesDetail?>((d) => d, onError: (_) => null));
      if (d == null) continue;
      final after = [
        for (final e in [for (final list in d.seasons.values) ...list])
          if (e.season > (h.ref.season ?? 0) || (e.season == h.ref.season && e.number > (h.ref.number ?? 0))) e,
      ];
      if (after.isEmpty) continue;
      found.add((series: s, next: after.first, count: after.length));
    }
    return found;
  }
}
