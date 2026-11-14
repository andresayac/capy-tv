// What a screen reader is told: a poster once with its rating, rows as headings, icon buttons
// with a name.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/common.dart';

Widget _app(Widget body) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: body),
);

void main() {
  testWidgets('a poster is one stop: its title and rating, said once', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(
      _app(
        SizedBox(
          width: 160,
          height: 300,
          child: PosterCard(title: 'Dune', rating: 8, onTap: () {}),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Dune, rated 8.0'), findsOneWidget);
    expect(find.bySemanticsLabel('Dune'), findsNothing, reason: 'not a second stop with the title alone');
    semantics.dispose();
  });

  testWidgets('a row\'s title is a heading', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(_app(const SectionHeader('Continue watching')));
    expect(t.getSemantics(find.text('Continue watching')).flagsCollection.isHeader, isTrue);
    semantics.dispose();
  });

  testWidgets('a setting with a few values says its name and its value together', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(
      _app(
        ChoiceRow<String>(
          label: 'Audio language',
          value: 'auto',
          options: const ['auto', 'spa'],
          text: (v) => v == 'auto' ? 'Automatic' : 'Spanish',
          onChanged: (_) {},
        ),
      ),
    );
    expect(find.bySemanticsLabel('Audio language, Automatic'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('an icon alone in a stop is said by the name it is given', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(
      _app(Focusable(onTap: () {}, semanticLabel: 'Volume up', child: const Icon(Icons.volume_up_rounded))),
    );
    expect(find.bySemanticsLabel('Volume up'), findsOneWidget);
    semantics.dispose();
  });
}
