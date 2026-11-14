// A row of channels from the library plays even when one of them no longer can: it is left out of
// the queue, and choosing that one says why instead of doing nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/m3u.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/player/play.dart';

void main() {
  final source = M3uSource(const [M3uEntry(name: 'One', url: 'http://srv/1.ts')]);
  final good = MediaRef.channel(const LiveChannel(id: '0', name: 'One', url: 'http://srv/1.ts'));
  // Kept from a list that is no longer what it was: no address of its own, and none in the list
  final gone = MediaRef.channel(const LiveChannel(id: 'gone', name: 'Gone'));

  test('an item for what can play, none for what cannot', () {
    expect(tryPlayItemFor(source, good)?.url, 'http://srv/1.ts');
    expect(tryPlayItemFor(source, gone), isNull);
  });

  testWidgets('choosing the one that cannot play says so', (t) async {
    late BuildContext context;
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await playRefs(context, source, [good, gone], 1);
    await t.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
