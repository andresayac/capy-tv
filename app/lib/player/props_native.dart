// mpv properties on the platforms where the player is media_kit's native one (libmpv): Android,
// iOS, Windows, Linux and macOS. Chosen when the app is compiled; web uses props_web.dart.
import 'package:media_kit/media_kit.dart';

/// The native player behind [player], or null (a test's own, or one still opening).
NativePlayer? nativeOf(Player player) => switch (player.platform) {
  final NativePlayer n => n,
  _ => null,
};

Future<void> setProperty(Player player, String name, String value) async {
  final native = nativeOf(player);
  if (native == null) return;
  try {
    await native.setProperty(name, value);
  } on Object {
    // A build of libmpv without that property: the viewing goes on without it
  }
}

Future<String> getProperty(Player player, String name) async {
  final native = nativeOf(player);
  if (native == null) return '';
  try {
    return await native.getProperty(name);
  } on Object {
    return '';
  }
}

Future<({String audio, String sub})> selectedTracks(Player player) async {
  final native = nativeOf(player);
  if (native == null) return (audio: '', sub: '');
  var audio = '', sub = '';
  try {
    final count = int.tryParse(await native.getProperty('track-list/count')) ?? 0;
    for (var i = 0; i < count; i++) {
      if (await native.getProperty('track-list/$i/selected') != 'yes') continue;
      final type = await native.getProperty('track-list/$i/type');
      final id = await native.getProperty('track-list/$i/id');
      if (type == 'audio') audio = id;
      if (type == 'sub') sub = id;
    }
  } on Object {
    // A player that closed meanwhile: nothing is reported selected
  }
  return (audio: audio, sub: sub);
}
