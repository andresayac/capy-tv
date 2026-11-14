// "Diagnostics": what the app noted, with no account in it.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/diagnostics.dart';

void main() {
  test('addresses keep only their host: no path, query or user, where an account is', () {
    expect(
      Diagnostics.clean('open http://tv.example:8080/live/ana/s3cret/1.ts failed'),
      'open http://tv.example:8080/… failed',
    );
    expect(Diagnostics.clean('get https://tv.example/get.php?username=ana&password=x'), 'get https://tv.example/…');
    expect(Diagnostics.clean('rtmp://ana:s3cret@cdn.example/live'), 'rtmp://cdn.example/…');
    expect(Diagnostics.clean('sync: offline'), 'sync: offline');
  });

  test('what debugPrint says goes in the report, cleaned, the oldest going past 500', () async {
    Diagnostics.clear();
    Diagnostics.start();
    debugPrint('player: http://tv.example/movie/ana/s3cret/9.mkv did not start');
    for (var i = 0; i < 600; i++) {
      Diagnostics.note('line $i');
    }
    final report = await Diagnostics.report(extra: ['sync: synced']);
    expect(report, startsWith('Capy TV '));
    expect(report, contains('sync: synced'));
    expect(report, isNot(contains('s3cret')));
    expect(report, isNot(contains('line 99\n')), reason: 'the oldest are gone');
    expect(report, contains('line 599'));
  });
}
