// What comes without a name is named in the app's language, also when it is read off the screen's
// thread, where an isolate starts with its own copy of every global.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/models.dart';
import 'package:iptv_player/data/off_thread.dart';

void main() {
  tearDown(() => untitledName = untitled);

  test('a movie, a series or a channel with no name takes the app language one, off-thread too', () async {
    untitledName = 'Sin título';
    expect(Movie.fromJson({'stream_id': 1}).name, 'Sin título');
    expect(Series.fromJson({'series_id': 2}).name, 'Sin título');
    expect(await runOffThread(() => Movie.fromJson({'stream_id': 3}).name), 'Sin título');
    expect(await runOffThread(() => LiveChannel.fromJson({'stream_id': 4}).name), 'Sin título');
  });
}
