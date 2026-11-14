// The main screens at the sizes they meet, with the text at its usual size and larger: a phone on
// its side (the app runs landscape on phones), a small one, a tablet, a TV and a computer. Nothing
// may spill out of its place: Flutter reports any overflow as an error, and the test fails on it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/ui/account_screen.dart';
import 'package:iptv_player/ui/detail_screens.dart';
import 'package:iptv_player/ui/guide_screen.dart';
import 'package:iptv_player/ui/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_test.dart' show FakeSource, app, playlist;
import 'ui_test.dart' as ui;

/// Logical sizes, as the devices give them.
const _sizes = <String, (Size, {bool tv})>{
  'phone on its side': (Size(844, 390), tv: false),
  'small phone on its side': (Size(667, 320), tv: false),
  'tablet': (Size(1280, 800), tv: false),
  'TV': (Size(960, 540), tv: true),
  'computer': (Size(1366, 768), tv: false),
};

const _textScales = [1.0, 1.5, 2.0]; // 2 is as far as the app lets it grow (main.dart)

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ui.settings = await AppSettings.load();
    ui.library = await Library.load('test', mainProfileId);
  });
  tearDown(() => isTv = false);

  final screens = <String, Widget Function()>{
    'Home': () => HomeScreen(playlist: playlist, source: FakeSource()),
    'a movie': () => MovieDetailScreen(
      source: FakeSource(),
      movie: const Movie(
        id: '5',
        name: 'A Film With A Rather Long Name To See Where It Goes',
        year: 2024,
        rating: 7.5,
        plot: 'A plot that goes on for a while, as synopses do, so that it takes a few lines on any screen.',
        genre: 'Action, Drama',
      ),
    ),
    'the guide': () => GuideScreen(
      source: FakeSource(),
      guide: ValueNotifier(EpgGuide.loading),
      categories: const [
        Category(id: '1', name: 'News'),
        Category(id: '2', name: 'Sports'),
      ],
    ),
    'Settings': () => AccountScreen(playlist: playlist, onSwitchPlaylist: () {}),
  };

  for (final MapEntry(key: device, value: (size, :tv)) in _sizes.entries) {
    for (final scale in _textScales) {
      for (final MapEntry(key: screen, value: build) in screens.entries) {
        testWidgets('$screen on a $device, text at ${scale}x, fits', (t) async {
          isTv = tv;
          t.view.physicalSize = size * 2;
          t.view.devicePixelRatio = 2;
          t.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(t.view.reset);
          addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
          await t.pumpWidget(app(build()));
          // Not pumpAndSettle: a carousel moves on by itself; a few seconds are enough to lay out
          for (var i = 0; i < 6; i++) {
            await t.pump(const Duration(milliseconds: 500));
          }
          // An overflow is reported as an error: the test fails on it, saying where
        });
      }
    }
  }
}
