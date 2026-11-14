import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import 'epg.dart';
import 'library.dart' show MediaKind, MediaRef;
import 'models.dart';
import 'source.dart';

/// What is on now on a live channel, for the screens that say it: the full guide's programme, or,
/// when the guide has none for the channel at this time, what the provider says when asked about
/// that channel alone (Xtream's short guide, `get_short_epg`).
///
/// Why: providers leave out of their full guide (XMLTV) channels that their short guide does have,
/// and while a full guide fails the app keeps the last good copy, which runs out. Asked one channel
/// at a time and only for those on screen, so a list of thousands costs a few requests: [parallel]
/// at a time, the latest shown first, each answer kept until its programme ends ([nothingFor] when
/// there is none, [failedFor] when asking failed). Never for a channel with no guide id: the
/// provider has nothing for those either.
class Airing extends ChangeNotifier {
  Airing(this._ask);

  /// The one for [source]: one per playlist open, shared by its screens.
  factory Airing.of(ContentSource source) => _bySource[source] ??= Airing((c) => source.shortEpg(c));
  static final _bySource = Expando<Airing>();

  final Future<List<EpgEntry>> Function(LiveChannel) _ask;

  static const parallel = 3;
  static const waiting = 48; // channels scrolled past are dropped, the oldest first
  static const nothingFor = Duration(minutes: 30);
  static const failedFor = Duration(minutes: 10);
  static const remembered = 1000;

  final _known = <String, ({List<EpgEntry> entries, DateTime until})>{};
  final _queue = <LiveChannel>[];
  final _asking = <String>{};
  var _running = 0;
  Timer? _tell;

  /// What is on now on [c]: the guide's, else the provider's once known. Listeners hear when an
  /// answer comes.
  EpgEntry? now(LiveChannel? c, EpgGuide? guide) {
    if (c == null) return null;
    final t = clock.now();
    return guide?.nowOn(c.epgId, t) ?? _fromProvider(c, t).where((e) => e.isNow(t)).firstOrNull;
  }

  /// What is on now and what comes next on [c], [count] at most: the guide's when it has the one on
  /// now, else the provider's as [now] gets them.
  List<EpgEntry> upcoming(LiveChannel? c, EpgGuide? guide, {int count = 2}) {
    if (c == null) return const [];
    final t = clock.now();
    if (guide?.nowOn(c.epgId, t) != null) return guide!.upcoming(c.epgId, count: count, at: t);
    return _fromProvider(c, t).where((e) => e.end.isAfter(t)).take(count).toList();
  }

  List<EpgEntry> _fromProvider(LiveChannel c, DateTime t) {
    if ((c.epgId ?? '').isEmpty) return const [];
    final known = _known[c.id];
    if (known == null || !known.until.isAfter(t)) _want(c);
    return known?.entries ?? const [];
  }

  void _want(LiveChannel c) {
    if (_asking.contains(c.id)) return;
    _queue.removeWhere((q) => q.id == c.id);
    _queue.add(c);
    if (_queue.length > waiting) _queue.removeAt(0);
    _next();
  }

  void _next() {
    while (_running < parallel && _queue.isNotEmpty) {
      final c = _queue.removeLast(); // the latest shown first: what is on screen now
      _asking.add(c.id);
      _running++;
      unawaited(_fetch(c));
    }
  }

  Future<void> _fetch(LiveChannel c) async {
    List<EpgEntry>? got;
    try {
      got = await _ask(c);
    } on Object {
      got = null; // asked again after a while
    }
    final t = clock.now();
    final entries = [...?got]..sort((a, b) => a.start.compareTo(b.start));
    final on = entries.where((e) => e.isNow(t)).firstOrNull;
    final next = entries.where((e) => e.start.isAfter(t)).firstOrNull;
    final until = switch ((got, on, next)) {
      (null, _, _) => t.add(failedFor),
      (_, final on?, _) => on.end,
      (_, _, final next?) when next.start.isBefore(t.add(nothingFor)) => next.start,
      _ => t.add(nothingFor),
    };
    _known
      ..remove(c.id)
      ..[c.id] = (entries: entries, until: until);
    if (_known.length > remembered) _known.remove(_known.keys.first);
    _asking.remove(c.id);
    _running--;
    // Answers come a few at a time: the screens are told once for them
    _tell ??= Timer(const Duration(milliseconds: 150), () {
      _tell = null;
      notifyListeners();
    });
    _next();
  }
}

/// The open playlist's, for the player's screens, which have no source of their own: set and
/// cleared with [currentGuide].
final currentAiring = ValueNotifier<Airing?>(null);

/// The channel a live [ref] plays, as much of it as [Airing] needs.
LiveChannel? liveChannelOf(MediaRef? ref) =>
    ref == null || ref.kind != MediaKind.live ? null : LiveChannel(id: ref.id, name: ref.title, epgId: ref.epgId);
