// A backup carries the preferences that suit any device (languages, the live format, the
// subtitles' size and band, how the picture fills the screen), not those of each device, and a
// damaged one does not fail.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/data/source.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the subtitles and the picture go with a backup; the decoder stays on each device', () async {
    SharedPreferences.setMockInitialValues({});
    final here = await AppSettings.load();
    await here.set(subtitleScale: 130, subtitleBackground: true, videoFit: '16:9', decoder: 'software');
    final saved = here.toJson();
    expect(saved, containsPair('subtitleScale', 130));
    expect(saved.containsKey('decoder'), isFalse);

    SharedPreferences.setMockInitialValues({});
    final there = await AppSettings.load();
    await there.restore(saved);
    expect((there.subtitleScale, there.subtitleBackground, there.videoFit), (130, true, '16:9'));
    expect(there.decoder, 'hardware');

    await there.restore({'subtitleScale': 'big', 'subtitleBackground': 1, 'videoFit': 3});
    expect(
      (there.subtitleScale, there.subtitleBackground, there.videoFit),
      (130, true, '16:9'),
      reason: 'damaged: left',
    );
  });

  test('old cached copies go, the one kept stays, though Windows writes its path another way', () {
    final dir = Directory.systemTemp.createTempSync('stale');
    addTearDown(() => dir.deleteSync(recursive: true));
    final old = DateTime.now().subtract(const Duration(days: 40));
    File named(String n) => File('${dir.path}/$n')
      ..writeAsStringSync('x')
      ..setLastModifiedSync(old);
    final keep = named('catalog-a.json'), gone = named('catalog-b.json'), other = named('guide-a.xml');
    // The same file, its folder written with the other separator
    dropStaleCache(File(keep.path.replaceAll(Platform.pathSeparator, '/')), 'catalog-', const Duration(days: 30));
    expect((keep.existsSync(), gone.existsSync(), other.existsSync()), (true, false, true));
  });
}
