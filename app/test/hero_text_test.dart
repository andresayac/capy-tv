// The hero with the system's text large: its Play button stays inside it, where a tap reaches it.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/catalog.dart';
import 'package:iptv_player/ui/theme.dart';

void main() {
  for (final (size, scale) in [(const Size(780, 360), 1.3), (const Size(780, 360), 1.5), (const Size(667, 320), 1.3)]) {
    testWidgets('on ${size.width.toInt()}×${size.height.toInt()} with text at $scale, Play can be tapped', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      var played = false;
      final item = CatalogItem(
        id: '1',
        title: 'A Film With A Rather Long Title',
        year: 2024,
        rating: 7.5,
        plot: 'A plot that goes on for a while, long enough to take its lines. ' * 3,
        genres: const ['Drama', 'Thriller'],
        open: (_) {},
        play: (_) => played = true,
      );
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: ListView(
                children: [
                  HeroCarousel(items: [item], label: 'Trending'),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pump();
      await t.tap(find.text('Play').hitTestable());
      expect(played, isTrue);
    });
  }
}
