import 'package:flutter/foundation.dart';

/// A title put to the vote.
class NightTitle {
  const NightTitle({required this.id, required this.title, this.year, this.rating, this.poster, this.plot});

  final String id;
  final String title;
  final int? year;
  final double? rating;
  final String? poster, plot;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'year': ?year,
    'rating': ?rating,
    'poster': ?poster,
    'plot': ?plot,
  };
}

/// Movie night: a few titles, and everyone in the room says yes or no to each from their phone
/// (see CompanionServer). The title most wanted wins; at a tie, the best rated. A phone that votes
/// again on a title changes its vote, it does not count twice.
class MovieNight extends ChangeNotifier {
  MovieNight(this.titles);

  final List<NightTitle> titles;

  // Title id → phone → yes (true) or no
  final _votes = <String, Map<String, bool>>{};

  /// Notes [voter]'s [yes] or no to the title [id]; false when there is no such title.
  bool vote(String voter, String id, {required bool yes}) {
    if (voter.isEmpty || !titles.any((t) => t.id == id)) return false;
    (_votes[id] ??= {})[voter] = yes;
    notifyListeners();
    return true;
  }

  int yes(String id) => _votes[id]?.values.where((v) => v).length ?? 0;
  int no(String id) => _votes[id]?.values.where((v) => !v).length ?? 0;

  /// How many phones have voted.
  int get voters => {for (final v in _votes.values) ...v.keys}.length;

  /// The title most wanted (yes minus no), at a tie the best rated; null before any vote.
  NightTitle? get winner {
    if (_votes.isEmpty) return null;
    int score(NightTitle t) => yes(t.id) - no(t.id);
    return ([...titles]..sort((a, b) {
          final s = score(b).compareTo(score(a));
          return s != 0 ? s : (b.rating ?? 0).compareTo(a.rating ?? 0);
        }))
        .first;
  }

  Map<String, dynamic> toJson() => {
    'open': true,
    'titles': [for (final t in titles) t.toJson()],
  };
}
