// A chip is drawn lower than a finger: a touch just above or below it, in its row, takes it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/ui/common.dart';

void main() {
  testWidgets('a touch a few pixels above or below a chip takes it; one further away does not', (t) async {
    var taps = 0;
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: AppChip(label: 'Sports', selected: false, onTap: () => taps++),
            ),
          ),
        ),
      ),
    );
    final box = t.getRect(find.byType(AppChip));
    await t.tapAt(Offset(box.center.dx, box.top - 5));
    await t.pump(const Duration(milliseconds: 400));
    await t.tapAt(Offset(box.center.dx, box.bottom + 5));
    await t.pump(const Duration(milliseconds: 400));
    expect(taps, 2);
    await t.tapAt(Offset(box.center.dx, box.top - 20));
    await t.pump(const Duration(milliseconds: 400));
    expect(taps, 2, reason: 'too far to be meant for it');
  });
}
