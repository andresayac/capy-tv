// Profiles, the parental PIN and adult content: what each profile keeps and may see.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/m3u.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/source.dart';
import 'package:iptv_player/data/watch_time.dart';
import 'package:iptv_player/data/xtream.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/common.dart';
import 'package:iptv_player/ui/profiles_screen.dart';
import 'package:iptv_player/ui/remote_keys.dart';
import 'package:iptv_player/ui/screensaver.dart';
import 'package:iptv_player/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

final store = ProfileStore.instance;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await store.load();
  });

  group('a PIN of its own', () {
    test('is its own: another profile\'s, or the parental one, is not it', () async {
      await store.setPin('1111');
      final bro = await store.add('Bro');
      await store.setProfilePin(bro.id, '7777');
      final saved = store.profiles.firstWhere((p) => p.id == bro.id);
      expect((saved.locked, saved.hasOwnPin), (true, true));
      expect(await store.checkProfilePin(saved, '7777'), isTrue);
      expect(await store.checkProfilePin(saved, '1111'), isFalse);
      expect(jsonEncode(saved.toJson()), isNot(contains('7777')), reason: 'only its hash is kept');
    });

    test('removing the parental PIN leaves it, and takes the locks that depended on it', () async {
      await store.setPin('1111');
      final bro = await store.add('Bro'), dad = await store.add('Dad');
      await store.setProfilePin(bro.id, '7777');
      await store.update(dad.copyWith(locked: true));
      await store.setPin(null);
      final after = {for (final p in store.profiles) p.name: p.locked};
      expect(after['Bro'], isTrue);
      expect(after['Dad'], isFalse);
    });

    test('removed, the profile opens without it', () async {
      final bro = await store.add('Bro');
      await store.setProfilePin(bro.id, '7777');
      await store.setProfilePin(bro.id, null);
      final p = store.profiles.firstWhere((p) => p.id == bro.id);
      expect((p.locked, p.hasOwnPin), (false, false));
    });

    test('a later change to the profile keeps it', () async {
      final bro = await store.add('Bro');
      await store.setProfilePin(bro.id, '7777');
      await store.update(store.profiles.firstWhere((p) => p.id == bro.id).copyWith(name: 'Brother'));
      expect(store.profiles.firstWhere((p) => p.id == bro.id).hasOwnPin, isTrue);
    });

    test('with a single profile, its own PIN is asked for all the same as the app starts', () async {
      expect(store.choosing, isFalse);
      await store.setProfilePin(Profile.mainId, '7777');
      expect(store.choosing, isFalse, reason: 'not in the middle of this session');
      await store.load();
      expect(store.choosing, isTrue);
    });

    test('a device set to open with a profile asks for it, once that profile has one', () async {
      final bro = await store.add('Bro'), ana = await store.add('Ana');
      await store.setDeviceProfile(ana.id);
      await store.load();
      expect((store.choosing, store.current.id), (false, ana.id), reason: 'without one it opens directly');

      await store.setDeviceProfile(bro.id);
      await store.setProfilePin(bro.id, '7777');
      await store.load();
      expect((store.choosing, store.current.id), (true, bro.id));
    });

    test('reaches another device, and survives one that does not know about it', () async {
      final bro = await store.add('Bro');
      await store.setProfilePin(bro.id, '7777');
      final sent = jsonDecode(jsonEncode(store.toJson())) as Map<String, dynamic>;

      SharedPreferences.setMockInitialValues({});
      await store.load();
      expect(await store.merge(sent), isTrue);
      final there = store.profiles.firstWhere((p) => p.id == bro.id);
      expect(await store.checkProfilePin(there, '7777'), isTrue);

      final unlocked = Profile.fromJson(there.toJson()..remove('locked'));
      expect(unlocked.locked, isTrue, reason: 'a device that does not know it may have taken the lock off');

      final old = Profile.fromJson(
        there.toJson()
          ..remove('pin')
          ..['pin'] = {'at': 1},
      );
      expect(old.hasOwnPin, isFalse, reason: 'nothing to check against is no PIN');
    });

    test('a library forgets everything, and says so to other devices', () async {
      final library = await Library.load('p', Profile.mainId);
      await library.toggleFavorite(MediaRef.channel(const LiveChannel(id: '1', name: 'One')));
      await library.forgetAll();
      expect(library.refs, isEmpty);
      expect(library.history, isEmpty);
      expect(library.toJson()['unfav'], isNotEmpty);
      expect(library.toJson()['cleared'], isNonZero);
    });
  });

  group('profiles', () {
    test('with one profile there is nothing to choose; with two, "Who\'s watching?" comes first', () async {
      expect(store.profiles.single.isMain, isTrue);
      expect(store.choosing, isFalse);
      final kid = await store.add(' Leo ', kids: true);
      expect(store.choosing, isFalse, reason: 'not in the middle of this session');
      await store.load();
      expect(store.choosing, isTrue, reason: 'next time the app starts');
      await store.select(kid.id);
      expect((store.choosing, store.current.name, store.current.kids), (false, 'Leo', true));
      await store.load();
      expect(store.current.id, kid.id, reason: 'the device remembers who was watching');
    });

    test('a device may open with a profile of its own, without asking; kept on that device only', () async {
      final leo = await store.add('Leo', kids: true);
      await store.load();
      expect(store.choosing, isTrue);
      await store.setDeviceProfile(leo.id);
      await store.load(); // the app starts again
      expect((store.choosing, store.current.id), (false, leo.id));
      expect(jsonEncode(store.toJson()), isNot(contains('device')), reason: 'not sent to other devices');
      await store.remove(leo.id);
      await store.load();
      expect((store.deviceProfile, store.choosing), (null, false), reason: 'gone with the profile');
    });

    test('a profile keeps its languages and time per day, and takes them to other devices', () async {
      final leo = await store.add('Leo', kids: true);
      await store.update(leo.copyWith(audioLanguage: 'eng', subtitleLanguage: 'off', dailyMinutes: 90));
      final there = Profile.fromJson(jsonDecode(jsonEncode(store.profiles.firstWhere((p) => p.id == leo.id).toJson())));
      expect((there.audioLanguage, there.subtitleLanguage, there.dailyMinutes), ('eng', 'off', 90));
      final back = there.copyWith(audioLanguage: null, dailyMinutes: null);
      expect(
        (back.audioLanguage, back.subtitleLanguage, back.dailyMinutes),
        (null, 'off', null),
        reason: 'cleared one by one',
      );
      expect(there.copyWith(name: 'Leito').dailyMinutes, 90, reason: 'other changes keep them');
    });

    test("a kids profile's time per day counts down, a day at a time, and the PIN adds more", () async {
      final day = DateTime(2026, 11, 7, 18);
      final leo = (await store.add('Leo', kids: true)).copyWith(dailyMinutes: 60);
      expect(await WatchTime.left(store.current, now: day), isNull, reason: 'no limit');
      await WatchTime.add(leo.id, const Duration(minutes: 45), now: day);
      expect(await WatchTime.left(leo, now: day), const Duration(minutes: 15));
      await WatchTime.addTime(leo.id, 30, now: day);
      expect(await WatchTime.left(leo, now: day), const Duration(minutes: 45));
      final tomorrow = day.add(const Duration(days: 1));
      expect(
        await WatchTime.left(leo, now: day.subtract(const Duration(days: 3))),
        const Duration(minutes: 45),
        reason: 'moving the date back gives no time back',
      );
      expect(await WatchTime.left(leo, now: tomorrow), const Duration(minutes: 60), reason: 'a new day');
      await WatchTime.add(leo.id, const Duration(minutes: 1), now: tomorrow);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((k) => k.startsWith('watch.') && !k.startsWith('watch.seen.')),
        hasLength(1),
        reason: 'yesterday is forgotten',
      );
    });

    test('the PIN is checked, never kept as typed, and removing it unlocks every profile', () async {
      expect(await store.checkPin('1234'), isTrue, reason: 'no PIN: nothing to check');
      await store.setPin('1234');
      expect((await store.checkPin('1234'), await store.checkPin('0000')), (true, false));
      expect(jsonEncode(store.toJson()), isNot(contains('1234')));
      final dad = await store.add('Dad');
      await store.update(dad.copyWith(locked: true));
      await store.setPin(null);
      expect(store.hasPin, isFalse);
      expect(store.profiles.where((p) => p.locked), isEmpty);
    });

    test('kids profiles never show adult content, whatever their setting', () {
      const kid = Profile(id: 'k', name: 'Leo', kids: true, adult: true);
      expect(kid.showsAdult, isFalse);
      expect(const Profile(id: 'a', name: 'Ana', adult: true).showsAdult, isTrue);
      expect(
        const Profile(id: 'a', name: 'Ana').showsAdult,
        isFalse,
        reason: 'hidden by default',
      );
    });

    test('a profile keeps its avatar, takes it to other devices, and can go back to its initial', () async {
      final ana = await store.add('Ana', avatar: 'notionists-8');
      expect(Profile.fromJson(ana.toJson()).avatar, 'notionists-8');
      expect(const Profile(id: 'x', name: 'X').toJson().containsKey('avatar'), isFalse);
      // Another device picks another one, later: it wins here
      final other = jsonDecode(jsonEncode(store.toJson())) as Map<String, dynamic>;
      (other['profiles'] as List)
        ..removeWhere((p) => (p as Map)['id'] == ana.id)
        ..add(ana.copyWith(avatar: 'lorelei-2', at: ana.at + 10).toJson());
      await store.merge(other);
      expect(store.profiles.firstWhere((p) => p.id == ana.id).avatar, 'lorelei-2');
      expect(ana.copyWith(noAvatar: true).avatar, isNull);
      expect(ana.copyWith(name: 'Anita').avatar, 'notionists-8', reason: 'other changes keep it');
    });

    test('profiles from two devices merge: the latest change of each wins, deletions included', () async {
      final leo = await store.add('Leo', kids: true);
      final other = jsonDecode(jsonEncode(store.toJson())) as Map<String, dynamic>;
      // The other device renames Leo later, and adds Mia; this one deletes nothing yet
      final later = DateTime.now().millisecondsSinceEpoch + 1000;
      (other['profiles'] as List).add(const Profile(id: 'mia', name: 'Mia', at: 1).toJson());
      for (final p in other['profiles'] as List) {
        if (p['id'] == leo.id) p['name'] = 'Leonardo';
        if (p['id'] == leo.id) p['at'] = later;
      }
      expect(await store.merge(other), isTrue);
      expect(store.profiles.map((p) => p.name), ['', 'Leonardo', 'Mia']);
      expect(await store.merge(other), isFalse, reason: 'nothing new the second time');

      final library = await Library.load('p', 'mia');
      await library.toggleFavorite(const MediaRef(kind: MediaKind.movie, id: '1', title: 'Film'));
      final gone = store.toJson();
      for (final p in gone['profiles'] as List) {
        if (p['id'] == 'mia') {
          p['deleted'] = true;
          p['at'] = later;
        }
      }
      await store.merge(gone);
      expect(store.profiles.map((p) => p.name), ['', 'Leonardo']);
      expect(await Library.stored('p', 'mia'), isNull, reason: 'its library goes too');
    });
  });

  group('adult content', () {
    test('categories named for adults', () {
      for (final name in [
        'XXX',
        'Adultos',
        'ADULT 24/7',
        '+18',
        'Canales 18+',
        'Eróticos',
        'VOD | XXX HD',
        'Sexo',
        'SEXY',
        'Playboy TV',
        'BRAZZERS',
        'Adulte',
        'Adultes',
        'Erwachsene',
        'Erotik',
        'Mayores de 18',
        'X-RATED',
        'R18',
        '🔞 VIP',
      ]) {
        expect(isAdultCategory(name), isTrue, reason: name);
      }
      for (final name in [
        'Sports',
        'Adulting 101 (comedy)',
        'Top 180',
        'Hot Wheels',
        'Deportes 2018',
        'Kids',
        'Essex',
        'R180',
      ]) {
        expect(isAdultCategory(name), isFalse, reason: name);
      }
    });

    test('titles that say so, and not those that only sound like it', () {
      for (final name in ['XXX Hot Channel', 'Brazzers TV', 'Playboy', 'Hentai 24/7', 'Pornhub']) {
        expect(isAdultTitle(name), isTrue, reason: name);
      }
      for (final name in ['xXx', 'Young Adult', 'Sex Education', 'Adult Swim', 'News']) {
        expect(isAdultTitle(name), isFalse, reason: name);
      }
    });

    test('a source hides adult content until it is told otherwise', () {
      expect(M3uSource(const []).hideAdult, isTrue);
      expect(XtreamSource(server: 'https://example.com/', username: 'u', password: 'p').hideAdult, isTrue);
    });

    test('Xtream: with the categories down the list fails, rather than showing what they would hide', () async {
      final s = XtreamSource(
        server: 'https://example.com/',
        username: 'demo',
        password: 'pw',
        client: MockClient((req) async {
          if (req.url.queryParameters['action'] == 'get_live_categories') return http.Response('', 503);
          return http.Response(
            jsonEncode([
              {'name': 'Spicy', 'stream_id': 20, 'category_id': '2'},
            ]),
            200,
          );
        }),
      );
      await expectLater(s.liveChannels(), throwsA(isA<SourceException>()));
    });

    test('Xtream: a channel whose own name says so, in an ordinary category', () async {
      final s = XtreamSource(
        server: 'https://example.com/',
        username: 'demo',
        password: 'pw',
        client: MockClient((req) async {
          final body = switch (req.url.queryParameters['action']) {
            'get_live_categories' => [
              {'category_id': '1', 'category_name': 'General'},
            ],
            'get_live_streams' => [
              {'name': 'World News', 'stream_id': 10, 'category_id': '1'},
              {'name': 'Sports', 'stream_id': 11, 'category_id': '1'},
              {'name': 'XXX Hot Channel', 'stream_id': 12, 'category_id': '1'},
            ],
            _ => [],
          };
          return http.Response(jsonEncode(body), 200);
        }),
      );
      expect([for (final c in await s.liveChannels()) c.name], ['World News', 'Sports']);
    });

    XtreamSource xtream() => XtreamSource(
      server: 'https://example.com/',
      username: 'demo',
      password: 'pw',
      client: MockClient((req) async {
        final body = switch (req.url.queryParameters['action']) {
          'get_live_categories' => [
            {'category_id': '1', 'category_name': 'News'},
            {'category_id': '2', 'category_name': 'XXX'},
            {'category_id': '3', 'category_name': 'Night'},
          ],
          'get_live_streams' => [
            {'name': 'World News', 'stream_id': 10, 'category_id': '1'},
            {'name': 'Late news', 'stream_id': 11, 'category_id': '1', 'is_adult': '1'},
            {'name': 'Spicy', 'stream_id': 20, 'category_id': '2'},
            {'name': 'Night 1', 'stream_id': 30, 'category_id': '3', 'is_adult': 1},
            {'name': 'Night 2', 'stream_id': 31, 'category_id': '3', 'is_adult': '1'},
            {
              'name': 'Cartoons',
              'stream_id': 40,
              'category_id': '1',
              'category_ids': [1, 2],
            },
          ],
          _ => [],
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );

    test('Xtream: by category name, by what the panel marks, and items in several categories', () async {
      final s = xtream()..hideAdult = false;
      expect((await s.liveCategories()).length, 3, reason: 'shown when asked');
      s.hideAdult = true;
      expect([for (final c in await s.liveCategories()) c.name], ['News'], reason: '"Night" is mostly marked adult');
      expect([for (final c in await s.liveChannels()) c.name], ['World News']);
      expect(await s.liveChannels('2'), isEmpty);
      expect([for (final c in await s.liveChannels('1')) c.name], ['World News']);
    });

    test('Xtream: an item in a hidden category is hidden from every other one it is in too', () async {
      final s = XtreamSource(
        server: 'https://example.com/',
        username: 'demo',
        password: 'pw',
        client: MockClient((req) async {
          final body = switch (req.url.queryParameters['action']) {
            'get_vod_categories' => [
              {'category_id': '1', 'category_name': 'Movies'},
              {'category_id': '2', 'category_name': 'Adultos'},
              {'category_id': '3', 'category_name': 'Late'},
            ],
            'get_vod_streams' => [
              {'name': 'Film', 'stream_id': 1, 'category_id': '1'},
              {
                'name': 'Also adult',
                'stream_id': 2,
                'category_id': '1',
                'category_ids': [1, 2],
              },
              {
                'name': 'Also late',
                'stream_id': 3,
                'category_id': '1',
                'category_ids': ['3'],
              },
              {'name': 'Late 1', 'stream_id': 4, 'category_id': '3', 'is_adult': 1},
              {'name': 'Late 2', 'stream_id': 5, 'category_id': '3', 'is_adult': '1'},
              {'name': 'Marked', 'stream_id': 6, 'category_id': '1', 'is_adult': 1},
              {
                'name': 'Elsewhere too',
                'stream_id': 7,
                'category_id': '4',
                'category_ids': [4, 1],
              },
            ],
            _ => [],
          };
          return http.Response(jsonEncode(body), 200);
        }),
      );
      Future<List<String>> names([String? category]) async => [for (final m in await s.movies(category)) m.name];
      s.hideAdult = false;
      expect(await names('1'), ['Film', 'Also adult', 'Also late', 'Marked', 'Elsewhere too']);
      expect(await names('3'), ['Also late', 'Late 1', 'Late 2']);
      s.hideAdult = true;
      expect(await names(), ['Film', 'Elsewhere too'], reason: '"Late" is mostly marked adult');
      expect(await names('1'), ['Film', 'Elsewhere too']);
      expect(await names('3'), isEmpty);
      expect(await names('4'), ['Elsewhere too']);
      expect([for (final c in await s.movieCategories()) c.name], ['Movies']);
    });

    test('M3U: by group name, by its own name and by adult="1"', () async {
      final s = M3uSource(
        parseM3u(
          '#EXTM3U\n'
          '#EXTINF:-1 group-title="News",World\nhttp://a/1.ts\n'
          '#EXTINF:-1 group-title="Adultos",Spicy\nhttp://a/2.ts\n'
          '#EXTINF:-1 group-title="News",XXX Hot Channel\nhttp://a/3.ts\n'
          '#EXTINF:-1 group-title="News" tvg-name="Brazzers",B\nhttp://a/4.ts\n'
          '#EXTINF:-1 group-title="News" adult="1",Marked\nhttp://a/5.ts\n',
        ),
      )..hideAdult = false;
      expect((await s.liveChannels()).length, 5);
      s.hideAdult = true;
      expect([for (final c in await s.liveCategories()) c.name], ['News']);
      expect([for (final c in await s.liveChannels()) c.name], ['World']);
    });
  });

  group('screens', () {
    Widget app(Widget home) => MaterialApp(
      theme: buildTheme(),
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

    testWidgets('"Who\'s watching?" asks for the PIN of a locked profile', (t) async {
      await t.runAsync(() async {
        await store.setPin('2580');
        final dad = await store.add('Dad');
        await store.update(dad.copyWith(locked: true));
        await store.add('Leo', kids: true);
        await store.load();
      });
      await t.pumpWidget(app(const ProfileGate(child: Text('the app'))));
      await t.pumpAndSettle();
      expect(find.text("Who's watching?"), findsOneWidget);
      expect(find.text('the app'), findsNothing);

      await t.tap(find.text('Dad'));
      await t.pumpAndSettle();
      expect(find.text('Enter the PIN'), findsOneWidget);
      // A keyboard or a remote's number keys
      for (final k in [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit1]) {
        await t.sendKeyEvent(k);
      }
      await t.runAsync(() async => t.sendKeyEvent(LogicalKeyboardKey.digit1));
      await t.pumpAndSettle();
      expect(find.text('Wrong PIN'), findsOneWidget);
      // Or the pad
      for (final d in ['2', '5', '8', '0']) {
        await t.runAsync(() async => t.tap(find.text(d)));
        await t.pump();
      }
      await t.pumpAndSettle();
      expect(find.text('the app'), findsOneWidget);
      expect(store.current.name, 'Dad');
    });

    group('a PIN of its own', () {
      Future<void> type(WidgetTester t, String pin) async {
        for (final d in pin.split('')) {
          await t.runAsync(() async => t.tap(find.text(d).last));
          await t.pump();
        }
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pumpAndSettle();
      }

      // The way out of a forgotten PIN wipes the profile, and a list open in it would bring all back
      Future<void> expectNoWayOutFromInside(WidgetTester t, Profile bro, Future<void> Function() openPad) async {
        addTearDown(() => currentLibrary.value = null);
        for (final (profile, offered) in [
          (null, findsOneWidget),
          (Profile.mainId, findsOneWidget),
          (bro.id, findsNothing),
        ]) {
          currentLibrary.value = profile == null
              ? null
              : Library.fromJson(const {}, playlistId: 'p', profileId: profile);
          await openPad();
          expect(find.text("Bro's PIN"), findsOneWidget);
          expect(find.text('I forgot the PIN'), offered, reason: 'with a list open in: $profile');
          await t.tap(find.byIcon(Icons.close_rounded));
          await t.pumpAndSettle();
        }
      }

      testWidgets('editing the profile with a list open does not offer forgetting its PIN', (t) async {
        late Profile bro;
        await t.runAsync(() async {
          bro = await store.add('Bro');
          await store.setProfilePin(bro.id, '7777');
        });
        await t.pumpWidget(app(const ManageProfilesScreen()));
        await t.pumpAndSettle();
        await expectNoWayOutFromInside(t, bro, () async {
          await t.tap(find.text('Bro'));
          await t.pumpAndSettle();
        });
      });

      testWidgets('setting the device to the profile with a list open does not offer forgetting its PIN', (t) async {
        late Profile bro;
        await t.runAsync(() async {
          bro = await store.add('Bro');
          await store.setProfilePin(bro.id, '7777');
          await store.add('Ana');
        });
        await t.pumpWidget(app(const ManageProfilesScreen()));
        await t.pumpAndSettle();
        final row = find
            .text(AppLocalizations.of(t.element(find.byType(ManageProfilesScreen))).deviceProfileTitle)
            .last;
        await t.scrollUntilVisible(row, 200);
        await t.pumpAndSettle();
        await expectNoWayOutFromInside(t, bro, () async {
          await t.tap(row);
          await t.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget, reason: 'through the device setting, not the list above it');
          await t.tap(find.text('Bro').last);
          await t.pumpAndSettle();
        });
      });

      testWidgets('only it opens the profile: the parental PIN does not', (t) async {
        late Profile bro;
        await t.runAsync(() async {
          await store.setPin('1111');
          bro = await store.add('Bro');
          await store.setProfilePin(bro.id, '7777');
          await store.add('Leo', kids: true);
          await store.load();
        });
        await t.pumpWidget(app(const ProfileGate(child: Text('the app'))));
        await t.pumpAndSettle();

        await t.tap(find.text('Bro'));
        await t.pumpAndSettle();
        expect(find.text("Bro's PIN"), findsOneWidget);
        await type(t, '1111');
        expect(find.text('Wrong PIN'), findsOneWidget, reason: 'the parental one is not it');
        expect(find.text('the app'), findsNothing);
        await type(t, '7777');
        expect(find.text('the app'), findsOneWidget);
        expect(store.current.id, bro.id);
      });

      testWidgets('a parental PIN forgotten without an account: told the way out, and the PIN stays', (t) async {
        await t.runAsync(() => store.setPin('1111'));
        await t.pumpWidget(
          app(
            Builder(
              builder: (context) => TextButton(onPressed: () => confirmPin(context), child: const Text('go')),
            ),
          ),
        );
        await t.tap(find.text('go'));
        await t.pumpAndSettle();
        await t.tap(find.text('I forgot the PIN'));
        await t.pumpAndSettle();
        expect(find.textContaining("clear this app's data"), findsOneWidget);
        expect(store.hasPin, isTrue, reason: 'or the button would be a way past it');
      });

      testWidgets('with a kids profile and no PIN, what is for grown-ups is not offered', (t) async {
        late Profile leo;
        await t.runAsync(() async {
          leo = await store.add('Leo', kids: true);
          await store.select(leo.id);
        });
        expect(adultActionsHidden, isTrue);
        await t.runAsync(() => store.setPin('1111'));
        expect(adultActionsHidden, isFalse, reason: 'behind the PIN instead');
        await t.runAsync(() => store.select(Profile.mainId));
        await t.runAsync(() => store.setPin(null));
        expect(adultActionsHidden, isFalse, reason: 'not a kids profile');
      });

      testWidgets('leaving a kids profile, or going to one with adult content, asks for the PIN', (t) async {
        late Profile leo, bo;
        Future<void> choosing(Profile from) => t.runAsync(() async {
          await store.select(from.id);
          store.switchProfile();
        });
        final pad = find.byIcon(Icons.backspace_outlined);
        await t.runAsync(() async {
          await store.setPin('1111');
          await store.update(store.current.copyWith(name: 'Ana', adult: true));
          bo = await store.add('Bo');
          leo = await store.add('Leo', kids: true);
          await store.load();
        });
        await choosing(leo);
        await t.pumpWidget(app(const ProfileGate(child: Text('the app'))));
        await t.pumpAndSettle();

        await t.tap(find.text('Bo'));
        await t.pumpAndSettle();
        expect(pad, findsOneWidget, reason: 'out of a kids profile');
        await type(t, '1111');
        expect(store.current.id, bo.id);

        await choosing(bo);
        await t.pumpAndSettle();
        await t.tap(find.text('Ana'));
        await t.pumpAndSettle();
        expect(pad, findsOneWidget, reason: 'adult content behind it');
        await type(t, '1111');
        expect(store.current.name, 'Ana');

        await choosing(bo);
        await t.pumpAndSettle();
        await t.tap(find.text('Leo'));
        await t.pumpAndSettle();
        expect(pad, findsNothing, reason: 'into a kids profile, nothing to guard');
        expect(store.current.id, leo.id);
      });

      testWidgets('the parental PIN gets to the settings, but not into a profile with its own', (t) async {
        await t.runAsync(() async {
          final bro = await store.add('Bro');
          await store.setProfilePin(bro.id, '7777');
        });
        await t.pumpWidget(app(const ManageProfilesScreen()));
        await t.pumpAndSettle();
        await t.tap(find.text('Bro'));
        await t.pumpAndSettle();
        expect(find.text("Bro's PIN"), findsOneWidget);
        await t.tap(find.byIcon(Icons.close_rounded));
        await t.pumpAndSettle();
        expect(find.byType(EditProfileScreen), findsNothing);
      });

      testWidgets('the way into the settings: the parental PIN opens it, and no profile with its own', (t) async {
        await t.runAsync(() async {
          await store.setPin('1111');
          final bro = await store.add('Bro');
          await store.setProfilePin(bro.id, '7777');
        });
        await t.pumpWidget(
          app(
            Builder(
              builder: (context) => TextButton(onPressed: () => openProfileSettings(context), child: const Text('go')),
            ),
          ),
        );
        await t.tap(find.text('go'));
        await t.pumpAndSettle();
        await type(t, '2222');
        expect(find.text('Wrong PIN'), findsOneWidget);
        expect(find.byType(ManageProfilesScreen), findsNothing);
        await type(t, '1111');
        await t.pumpAndSettle();
        expect(find.byType(ManageProfilesScreen), findsOneWidget);
        await t.tap(find.text('Bro'));
        await t.pumpAndSettle();
        await type(t, '1111');
        expect(find.text('Wrong PIN'), findsOneWidget, reason: 'the parental one does not open it');
        expect(find.byType(EditProfileScreen), findsNothing);
      });

      testWidgets('five wrong tries make the pad wait, and the right one clears them', (t) async {
        await t.runAsync(() async {
          await store.setPin('1111');
          for (var i = 0; i < 5; i++) {
            await PinTries.failed();
          }
          expect(await PinTries.secondsLeft(), inInclusiveRange(29, 30));
          await PinTries.passed();
          expect(await PinTries.secondsLeft(), 0);
          for (var i = 0; i < 5; i++) {
            await PinTries.failed();
          }
        });
        await t.pumpWidget(
          app(
            Builder(
              builder: (context) => TextButton(onPressed: () => confirmPin(context), child: const Text('go')),
            ),
          ),
        );
        await t.tap(find.text('go'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pump();
        expect(find.textContaining('Too many tries'), findsOneWidget);
        await t.runAsync(PinTries.passed);
        await t.pump(const Duration(seconds: 31));
      });

      testWidgets('back from the background after a long while, a profile behind a PIN asks again', (t) async {
        late Profile bro;
        final navigator = GlobalKey<NavigatorState>();
        await t.runAsync(() async {
          bro = await store.add('Bro');
          await store.setProfilePin(bro.id, '7777');
          await store.select(bro.id);
        });
        IdleWatcher.relockAfter = Duration.zero;
        addTearDown(() => IdleWatcher.relockAfter = const Duration(minutes: 20));
        await t.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: IdleWatcher(
              navigator: navigator,
              child: const Scaffold(body: Text('inside')),
            ),
          ),
        );
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pumpAndSettle();
        expect(find.text("Bro's PIN"), findsOneWidget);
        await type(t, '7777');
        expect(find.text("Bro's PIN"), findsNothing);
        expect(store.current.id, bro.id);
      });

      test('a locked profile with no PIN of its own is asked for too, alone or not', () async {
        await store.setPin('1111');
        await store.update(store.current.copyWith(locked: true));
        await store.load();
        expect(store.choosing, isTrue);
      });

      testWidgets('turning the profile in use into a kids one opens its list again for it', (t) async {
        await t.runAsync(() => store.setPin('1111'));
        currentLibrary.value = Library.fromJson(const {}, playlistId: 'open', profileId: store.current.id);
        addTearDown(() {
          currentLibrary.value = null;
          reopenAfterProfile.value = null;
        });
        await t.pumpWidget(app(EditProfileScreen(profile: store.current)));
        await t.pumpAndSettle();
        await t.tap(find.text('Kids'));
        await t.pumpAndSettle();
        await t.scrollUntilVisible(find.text('Save'), 200, scrollable: find.byType(Scrollable).first);
        await t.runAsync(() async => t.tap(find.text('Save')));
        await t.pumpAndSettle();
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        expect(reopenAfterProfile.value, 'open');
      });

      testWidgets('a device cannot be set to open with it, skipping the PIN', (t) async {
        late Profile bro;
        await t.runAsync(() async {
          bro = await store.add('Bro');
          await store.setProfilePin(bro.id, '7777');
          await store.add('Ana');
        });
        await t.pumpWidget(app(const ManageProfilesScreen()));
        await t.pumpAndSettle();
        final row = find
            .text(AppLocalizations.of(t.element(find.byType(ManageProfilesScreen))).deviceProfileTitle)
            .last;
        await t.scrollUntilVisible(row, 200);
        await t.tap(row);
        await t.pumpAndSettle();
        await t.tap(find.text('Bro').last);
        await t.pumpAndSettle();
        expect(find.text("Bro's PIN"), findsOneWidget);
        await t.tap(find.byIcon(Icons.close_rounded));
        await t.pumpAndSettle();
        expect(store.deviceProfile, isNull);
      });

      testWidgets('forgotten: the profile goes, with what it watched, and nobody gets in', (t) async {
        late Profile bro;
        await t.runAsync(() async {
          bro = await store.add('Bro');
          await store.setProfilePin(bro.id, '7777');
          await store.add('Leo');
          await store.load();
          await (await Library.load(
            'p',
            bro.id,
          )).toggleFavorite(MediaRef.channel(const LiveChannel(id: '1', name: 'One')));
        });
        await t.pumpWidget(app(const ProfileGate(child: Text('the app'))));
        await t.pumpAndSettle();
        await t.tap(find.text('Bro'));
        await t.pumpAndSettle();
        await t.tap(find.text('I forgot the PIN'));
        await t.pumpAndSettle();
        expect(find.textContaining('Bro must be deleted'), findsOneWidget);
        await t.runAsync(() async => t.tap(find.text('Delete')));
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pumpAndSettle();
        expect(store.profiles.map((p) => p.name), isNot(contains('Bro')));
        expect(find.text('the app'), findsNothing, reason: 'it does not open anybody');
        final left = (await t.runAsync(() => Library.load('p', bro.id)))!;
        expect(left.refs, isEmpty);
      });

      testWidgets('the pad with the way out still fits a phone on its side', (t) async {
        t.view.physicalSize = const Size(780, 360);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          app(
            Builder(
              builder: (c) => TextButton(
                onPressed: () => showPinPad(c, title: 'PIN', forgot: true),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await t.tap(find.text('open'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: 'nothing overflows');
        expect(find.text('I forgot the PIN'), findsOneWidget);
      });
    });

    testWidgets('on a phone on its side, Save far below an empty name says so, up there in sight', (t) async {
      t.view.physicalSize = const Size(900, 400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final before = ProfileStore.instance.profiles.length;
      await t.pumpWidget(app(const EditProfileScreen()));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('Save'), 200, scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(ProfileStore.instance.profiles.length, before, reason: 'no profile with no name');
      expect(find.text('Required').hitTestable(), findsOneWidget, reason: 'said where it can be seen');
    });

    testWidgets('with a remote, the arrows go through the settings of a new profile down to Save', (t) async {
      t.view.physicalSize = const Size(1920, 1080);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      isTv = true;
      addTearDown(() => isTv = false);
      await t.pumpWidget(app(const Shortcuts(shortcuts: tvShortcuts, child: EditProfileScreen())));
      await t.pumpAndSettle();
      // With its PIN on, as when the option below it appears
      await t.tap(find.text('Ask for the PIN'));
      await t.pumpAndSettle();
      for (var i = 0; i < 8; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.digit4);
        await t.pumpAndSettle();
      }
      expect(find.text('Change PIN'), findsOneWidget);
      bool onSave() =>
          FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<PrimaryButton>() != null;
      for (var i = 0; i < 12 && !onSave(); i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.pumpAndSettle();
      }
      expect(onSave(), isTrue);
    });

    testWidgets('the PIN pad fits a phone on its side, every key in sight', (t) async {
      t.view.physicalSize = const Size(780, 360);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        app(
          Builder(
            builder: (c) => TextButton(
              onPressed: () => showPinPad(c, title: 'PIN'),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: 'nothing overflows');
      final screen = Offset.zero & const Size(780, 360);
      for (final key in [for (var d = 0; d < 10; d++) find.text('$d'), find.byIcon(Icons.close_rounded)]) {
        final box = t.getRect(key);
        expect(screen.contains(box.topLeft) && screen.contains(box.bottomRight), isTrue, reason: '$key');
      }
    });

    testWidgets('profile screens start with something focused, for a remote', (t) async {
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
      String? focused() => FocusManager.instance.primaryFocus?.context?.widget.runtimeType.toString();

      await t.pumpWidget(app(const ManageProfilesScreen()));
      await t.pumpAndSettle();
      expect(focused(), isNotNull, reason: 'the list starts on the first profile');

      await t.pumpWidget(app(const EditProfileScreen()));
      await t.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(TextFormField), matching: find.byType(EditableText)).evaluate().single.widget,
        isA<EditableText>().having((e) => e.focusNode.hasFocus, 'focused', isTrue),
        reason: 'a new profile starts on its name',
      );

      await t.pumpWidget(app(EditProfileScreen(key: UniqueKey(), profile: store.current)));
      await t.pumpAndSettle();
      // At the top where it is seen: Save is below the screen, where an OK would leave unseen
      final button = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<SecondaryButton>();
      expect(button?.label, 'Change avatar', reason: 'an existing one starts on Change avatar');
    });

    testWidgets('a profile shows its avatar, or its initial for one this app does not have', (t) async {
      await t.pumpWidget(
        app(
          const Row(
            children: [
              ProfileAvatar(
                profile: Profile(id: 'a', name: 'Ana', avatar: 'notionists-8'),
              ),
              ProfileAvatar(
                profile: Profile(id: 'b', name: 'Bea', avatar: 'some-future-avatar'),
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(AvatarPicture), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('a new profile comes with an avatar of its kind, and another can be picked', (t) async {
      await t.pumpWidget(app(const EditProfileScreen()));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextFormField), 'Leo');
      expect(kidsAvatars, isNot(contains(t.widget<AvatarPicture>(find.byType(AvatarPicture)).name)));
      // Kids get a colourful one, until one is picked
      await t.tap(find.text('Kids'));
      await t.pumpAndSettle();
      final given = t.widget<AvatarPicture>(find.byType(AvatarPicture)).name;
      expect(kidsAvatars, contains(given));
      await t.tap(find.text('Change avatar'));
      await t.pumpAndSettle();
      final grid = find.descendant(of: find.byType(AlertDialog), matching: find.byType(AvatarPicture));
      expect(grid, findsNWidgets(avatars.length));
      // Far down the window, but brought into view
      final current = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byWidgetPredicate((w) => w is AvatarPicture && w.name == given),
      );
      expect(current.hitTestable(), findsOneWidget);
      await t.ensureVisible(grid.at(20));
      await t.tap(grid.at(20));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await t.tap(find.text('Kids'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('Save'), 200, scrollable: find.byType(Scrollable).first);
      await t.runAsync(() async => t.tap(find.text('Save')));
      await t.pumpAndSettle();
      final leo = store.profiles.firstWhere((p) => p.name == 'Leo');
      expect(leo.avatar, avatars[20], reason: 'picked, so it stays when the kids setting changes');
    });

    testWidgets('with a remote, the arrows reach every avatar in the window, scrolling to it', (t) async {
      await t.pumpWidget(app(const EditProfileScreen()));
      await t.pumpAndSettle();
      await t.tap(find.text('Change avatar'));
      await t.pumpAndSettle();
      // The avatar under the focus
      String? focused() {
        String? name;
        void visit(Element e) {
          if (e.widget case AvatarPicture(name: final n)) name = n;
          e.visitChildren(visit);
        }

        (FocusManager.instance.primaryFocus!.context! as Element).visitChildren(visit);
        return name;
      }

      bool shown(String name) =>
          find.byWidgetPredicate((w) => w is AvatarPicture && w.name == name).hitTestable().evaluate().isNotEmpty;

      expect(focused(), avatars.first, reason: "a new grown-up's, in focus");
      // Down, row after row, past the kids' title to the last one
      for (var i = 0; i < 20; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.pumpAndSettle();
        expect(shown(focused()!), isTrue);
      }
      expect(focused(), kidsAvatars.last);
      // And along a row, and back up
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
      final row = focused()!;
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      expect(avatars.indexOf(focused()!), avatars.indexOf(row) + 1);
      for (var i = 0; i < 20; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await t.pumpAndSettle();
      }
      expect(focused(), avatars[1], reason: 'one to the right of where it started');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pumpAndSettle();
      expect(focused(), avatars.first);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pumpAndSettle();
      expect(focused(), isNull, reason: 'the initial, first of all');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    test('the avatar stays on this device, through a restart', () async {
      final ana = await store.add('Ana', avatar: 'notionists-8');
      await store.update(store.profiles.firstWhere((p) => p.id == ana.id).copyWith(avatar: 'lorelei-2'));
      await store.load();
      expect(store.profiles.firstWhere((p) => p.id == ana.id).avatar, 'lorelei-2');
    });

    test('a device on an older version, which drops the avatar, does not take it away', () async {
      final ana = await store.add('Ana', avatar: 'notionists-8');
      // The older version sends the same profile back, as it understood it: no avatar, same time
      final older = jsonDecode(jsonEncode(store.toJson())) as Map<String, dynamic>;
      for (final p in older['profiles'] as List) {
        (p as Map).remove('avatar');
      }
      await store.merge(older);
      expect(store.profiles.firstWhere((p) => p.id == ana.id).avatar, 'notionists-8');
    });

    test('what a newer version adds to a profile survives this one', () async {
      final ana = await store.add('Ana');
      final newer = jsonDecode(jsonEncode(store.toJson())) as Map<String, dynamic>;
      for (final p in newer['profiles'] as List) {
        if ((p as Map)['id'] == ana.id) p['language'] = 'es';
      }
      await store.merge(newer);
      await store.update(store.profiles.firstWhere((p) => p.id == ana.id).copyWith(name: 'Anita'));
      final saved = (store.toJson()['profiles'] as List).firstWhere((p) => (p as Map)['id'] == ana.id) as Map;
      expect(saved['language'], 'es', reason: 'kept, and sent on to other devices');
    });

    test('new profiles get an avatar nobody has, of their kind', () async {
      expect(defaultAvatar(kids: false), startsWith('notionists'));
      expect(defaultAvatar(kids: true), kidsAvatars.first);
      await store.add('Ana', avatar: defaultAvatar(kids: false));
      expect(defaultAvatar(kids: false), isNot(store.profiles.firstWhere((p) => p.name == 'Ana').avatar));
      await store.add('Leo', kids: true, avatar: defaultAvatar(kids: true));
      expect(defaultAvatar(kids: true), kidsAvatars[1]);
    });

    test('the avatars: each one has its picture and credit, the TV has the same, and the names kept stay', () {
      // The first ones, which profiles keep and sync: never renamed or dropped
      const first = [
        ...['notionists-1', 'notionists-2', 'notionists-5', 'notionists-8', 'notionists-10', 'notionists-11'],
        ...['notionists-18', 'notionists-19', 'notionists-22', 'notionists-35', 'notionists-38', 'notionists-47'],
        ...['lorelei-2', 'lorelei-5', 'lorelei-6', 'lorelei-9', 'lorelei-15', 'lorelei-17'],
        ...['lorelei-20', 'lorelei-23', 'lorelei-26', 'lorelei-33', 'lorelei-40', 'lorelei-48'],
      ];
      expect(avatars, containsAll(first));
      expect(avatars.toSet(), hasLength(avatars.length), reason: 'no name twice');
      expect(avatars.skip(avatars.length - kidsAvatars.length), kidsAvatars, reason: "the kids' ones last");
      // The TV app offers the same ones, in the same order
      final tv = jsonDecode(File('../tizen/src/avatars.json').readAsStringSync()) as Map<String, dynamic>;
      expect(tv['avatars'], avatars, reason: 'tizen/src/avatars.json: the same list as the app');
      expect(tv['kids'], kidsAvatars);
      final files = {
        for (final f in Directory('assets/avatars').listSync()) f.uri.pathSegments.last.replaceAll('.svg', ''),
      };
      expect(files, avatars.toSet(), reason: 'a picture for each, and none left over');
      // Black and white drawings but for the kids' ones (drawn with DiceBear, credited in each)
      final credited = <String>{};
      for (final a in avatars) {
        final svg = File('assets/avatars/$a.svg').readAsStringSync();
        expect(svg, matches(RegExp(r'licensed under "CC(0 1\.0| BY 4\.0)"')), reason: a);
        // CC BY asks for the work and its artist where it shows: the About panel names them
        if (RegExp(r'Remix of "([^"]+)" \([^)]*\) by "([^"]+)", licensed under "CC BY 4\.0"').firstMatch(svg)
            case final by?) {
          credited.add(a.replaceAll(RegExp(r'-\d+$'), ''));
          for (final lang in ['en', 'es']) {
            final credits = lookupAppLocalizations(Locale(lang)).avatarCredits;
            expect(credits, stringContainsInOrder([by[1]!, by[2]!]), reason: '$a, $lang');
          }
        }
        final colours = [
          for (final m in RegExp(r'#([0-9a-fA-F]{6})\b').allMatches(svg))
            [for (var i = 0; i < 6; i += 2) int.parse(m[1]!.substring(i, i + 2), radix: 16)],
        ];
        final grey = colours.every((c) => c.reduce(max) - c.reduce(min) <= 8);
        expect(grey, !kidsAvatars.contains(a), reason: a);
      }
      expect(credited, {'croodles', 'fun-emoji'});
    });

    testWidgets('a kids profile opens without a PIN', (t) async {
      await t.runAsync(() async {
        await store.setPin('2580');
        await store.add('Leo', kids: true);
        await store.load();
      });
      await t.pumpWidget(app(const ProfileGate(child: Text('the app'))));
      await t.pumpAndSettle();
      await t.runAsync(() async => t.tap(find.text('Leo')));
      await t.pumpAndSettle();
      expect(find.text('the app'), findsOneWidget);
      expect(store.current.kids, isTrue);
    });

    testWidgets('from inside a playlist, "Who\'s watching?" switches right there', (t) async {
      late Profile leo;
      await t.runAsync(() async {
        leo = await store.add('Leo', kids: true);
        await store.select(Profile.mainId);
      });
      reopenAfterProfile.value = null;
      // The playlists screen at the bottom, a playlist's Home over it
      await t.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => Scaffold(
                    body: TextButton(onPressed: () => changeProfile(context, 'p1'), child: const Text('avatar')),
                  ),
                ),
              ),
              child: const Text('playlists'),
            ),
          ),
        ),
      );
      await t.tap(find.text('playlists'));
      await t.pumpAndSettle();

      // The same profile, or back: nothing changes, still in the playlist
      await t.tap(find.text('avatar'));
      await t.pumpAndSettle();
      expect(find.text("Who's watching?"), findsOneWidget);
      await t.tap(find.text('You'));
      await t.pumpAndSettle();
      expect(find.text('avatar'), findsOneWidget);
      expect(reopenAfterProfile.value, isNull);
      await t.tap(find.text('avatar'));
      await t.pumpAndSettle();
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      expect(find.text('avatar'), findsOneWidget);
      expect(store.current.isMain, isTrue);

      // Another one: out of the playlist, for the playlists screen to open it again for them
      await t.tap(find.text('avatar'));
      await t.pumpAndSettle();
      await t.runAsync(() async => t.tap(find.text('Leo')));
      await t.pumpAndSettle();
      expect(store.current.id, leo.id);
      expect(find.text('playlists'), findsOneWidget);
      expect(reopenAfterProfile.value, 'p1');
      reopenAfterProfile.value = null;
    });
  });
}
