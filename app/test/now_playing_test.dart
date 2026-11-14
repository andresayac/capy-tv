// What plays: a screen that goes does not unsay what the one replacing it has said, and lists
// refreshed in the background keep off the line for as long as something does.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/remote/remote_input.dart';
import 'package:iptv_player/ui/home_screen.dart';

void main() {
  const film = (title: 'Heat', subtitle: null);
  final multiview = Object(), player = Object();

  tearDown(() {
    sayStopped(multiview);
    sayStopped(player);
    nowPlaying.value = null;
    lowMemory = false;
  });

  group('back to the app', () {
    final old = XtreamSource.listsFresh + const Duration(minutes: 1);

    test('lists older than a session are brought again', () {
      expect(updatesListsOnReturn(old), isTrue);
      expect(updatesListsOnReturn(XtreamSource.listsFresh), isFalse);
    });

    test('but not over something playing', () {
      nowPlaying.value = film;
      expect(updatesListsOnReturn(old), isFalse);
    });

    test('nor where two catalogs at once do not fit', () {
      lowMemory = true;
      expect(updatesListsOnReturn(old), isFalse);
    });
  });

  test('the lists follow what plays, with nothing to wire up', () {
    expect(streamPlaying.value, isFalse);
    nowPlaying.value = film;
    expect(streamPlaying.value, isTrue);
    nowPlaying.value = null;
    expect(streamPlaying.value, isFalse);
  });

  test('a screen that goes, once another plays the same title, leaves it playing', () {
    sayPlaying(multiview, film);
    sayPlaying(player, film);
    sayStopped(multiview);
    expect(nowPlaying.value, film);
    expect(streamPlaying.value, isTrue);

    sayStopped(player);
    expect(nowPlaying.value, isNull);
    expect(streamPlaying.value, isFalse);
  });

  test('a screen that goes before the next one plays says nothing plays, and the next one corrects it', () {
    sayPlaying(player, film);
    sayStopped(player);
    expect(streamPlaying.value, isFalse);
    sayPlaying(multiview, film);
    expect(streamPlaying.value, isTrue);
  });

  test('the one that stopped has no say once another plays', () {
    sayPlaying(player, film);
    sayStopped(player);
    sayPlaying(multiview, film);
    sayStopped(player);
    expect(nowPlaying.value, film);
  });
}
