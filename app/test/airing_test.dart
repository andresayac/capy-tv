import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/airing.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';

void main() {
  final t0 = DateTime(2026, 11, 14, 12);
  EpgEntry entry(String title, int fromMinute, int toMinute) => EpgEntry(
    title: title,
    start: t0.add(Duration(minutes: fromMinute)),
    end: t0.add(Duration(minutes: toMinute)),
  );
  const rcn = LiveChannel(id: '7', name: 'RCN', epgId: 'rcn.co');
  const espn = LiveChannel(id: '8', name: 'ESPN', epgId: 'espn');
  const lounge = LiveChannel(id: '9', name: 'Lounge'); // no guide id

  // The screens are told a moment after the answers come
  Future<void> told() => Future<void>.delayed(const Duration(milliseconds: 200));

  test('the guide first: the provider is not asked about a channel the guide has on now', () async {
    final asked = <String>[];
    final onAir = Airing((c) async {
      asked.add(c.id);
      return const [];
    });
    final guide = EpgGuide({
      'espn': [entry('Football', -30, 30)],
    });
    await withClock(Clock.fixed(t0), () async {
      expect(onAir.now(espn, guide)?.title, 'Football');
      expect(onAir.upcoming(espn, guide).map((e) => e.title), ['Football']);
      await told();
    });
    expect(asked, isEmpty);
  });

  test(
    'a channel the guide leaves out: asked of the provider once, the screens told, kept while its programme lasts',
    () async {
      var at = t0;
      final asked = <String>[];
      final onAir = Airing((c) async {
        asked.add(c.id);
        return [entry('El Chavo', -10, 20), entry('Noticias', 20, 80)];
      });
      var tellings = 0;
      onAir.addListener(() => tellings++);
      await withClock(Clock(() => at), () async {
        expect(onAir.now(rcn, EpgGuide.empty), isNull, reason: 'not known yet');
        expect(onAir.now(rcn, EpgGuide.empty), isNull, reason: 'asked once, not twice');
        await told();
        expect(tellings, 1);
        expect(onAir.now(rcn, EpgGuide.empty)?.title, 'El Chavo');
        expect(onAir.upcoming(rcn, null).map((e) => e.title), ['El Chavo', 'Noticias']);

        at = t0.add(const Duration(minutes: 19));
        expect(onAir.now(rcn, null)?.title, 'El Chavo');
        await told();
        expect(asked, ['7'], reason: 'not again while what is on goes on');

        at = t0.add(const Duration(minutes: 21));
        expect(onAir.now(rcn, null)?.title, 'Noticias', reason: 'the next one, from what was said');
        await told();
        expect(asked, ['7', '7'], reason: 'asked again once it ended');
      });
    },
  );

  test("a guide with nothing on now for the channel, such as a copy kept from before the provider's failed: "
      'the provider is asked', () async {
    final onAir = Airing((c) async => [entry('Live now', -5, 55)]);
    final stale = EpgGuide({
      'espn': [entry('Two days ago', -2900, -2840)],
    });
    await withClock(Clock.fixed(t0), () async {
      expect(onAir.now(espn, stale), isNull);
      await told();
      expect(onAir.now(espn, stale)?.title, 'Live now');
      expect(onAir.upcoming(espn, stale).map((e) => e.title), ['Live now']);
    });
  });

  test('a channel with no guide id is never asked about: the provider has nothing for it either', () async {
    final asked = <String>[];
    final onAir = Airing((c) async {
      asked.add(c.id);
      return const [];
    });
    await withClock(Clock.fixed(t0), () async {
      expect(onAir.now(lounge, EpgGuide.empty), isNull);
      await told();
    });
    expect(asked, isEmpty);
  });

  test('when asking fails, or the provider has nothing, it is asked again only after a while', () async {
    var at = t0;
    var asks = 0;
    var fail = true;
    final onAir = Airing((c) async {
      asks++;
      if (fail) throw Exception('down');
      return const [];
    });
    await withClock(Clock(() => at), () async {
      onAir.now(rcn, null);
      await told();
      at = t0.add(const Duration(minutes: 9));
      onAir.now(rcn, null);
      await told();
      expect(asks, 1, reason: 'a failure is kept ten minutes');
      at = t0.add(const Duration(minutes: 11));
      fail = false;
      onAir.now(rcn, null);
      await told();
      expect(asks, 2);
      at = t0.add(const Duration(minutes: 40));
      onAir.now(rcn, null);
      await told();
      expect(asks, 2, reason: 'nothing to say is kept half an hour');
    });
  });

  test('three at a time, the channel shown last asked first', () async {
    final asks = <String, Completer<List<EpgEntry>>>{};
    final onAir = Airing((c) => (asks[c.id] = Completer<List<EpgEntry>>()).future);
    for (var i = 0; i < 10; i++) {
      onAir.now(LiveChannel(id: '$i', name: 'Channel $i', epgId: 'g$i'), null);
    }
    expect(asks.keys, ['0', '1', '2']);
    asks['0']!.complete(const []);
    await Future<void>.delayed(Duration.zero);
    expect(asks.keys.last, '9', reason: 'what is on screen now goes first');
    for (final a in asks.values) {
      if (!a.isCompleted) a.complete(const []);
    }
  });

  test('a live item of the player is read as its channel; anything else is not a channel', () {
    final channel = liveChannelOf(MediaRef.channel(rcn));
    expect((channel?.id, channel?.epgId), ('7', 'rcn.co'));
    expect(liveChannelOf(null), isNull);
    expect(liveChannelOf(const MediaRef(kind: MediaKind.movie, id: '1', title: 'A film')), isNull);
  });
}
