// Choosing a stream's audio language, and its volume, on whichever player can do it.
//
// Native (mpv): the player itself, which reads the file's tracks and switches them.
// Browser: the player cannot (a <video> plays one track). There a hidden <movi-player> holds the
// sound and does the switching; see movi_sound.dart. If it has no sound for this player (nothing
// read yet, or a stream it could not open), there is nothing to switch and the call is a no-op.
import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'movi_sound.dart';

Future<void> chooseAudio(Player player, AudioTrack track) async {
  if (await selectMoviAudio(player, track)) return;
  await player.setAudioTrack(track);
}

/// Sets the sound to [volume] (0 to 100) on whatever is playing it. When movi has taken the
/// sound over, the picture's own stays silent: two copies of a stream's audio would be heard
/// slightly apart.
Future<void> setAudioVolume(Player player, double volume) async {
  if (volume > 0) unawaited(_keepVolume(volume));
  if (soundTookOver(player)) {
    setMoviVolume(player, volume);
    if (player.state.volume != 0) await player.setVolume(0);
    return;
  }
  await player.setVolume(volume);
}

/// The volume last chosen on this device, for the next title to start at; a device's own, as its
/// speakers are, so not among the synced settings. Never 0: a title muted and left does not make
/// the next one start silent.
Future<double> savedVolume() async {
  try {
    final v = (await SharedPreferences.getInstance()).getDouble(_volumeKey);
    return v != null && v > 0 && v <= 100 ? v : 100;
  } on Object {
    return 100;
  }
}

const _volumeKey = 'player.volume';

Future<void> _keepVolume(double volume) async {
  try {
    await (await SharedPreferences.getInstance()).setDouble(_volumeKey, volume.clamp(1, 100).toDouble());
  } on Object {
    // Not kept: the next title starts where it would have
  }
}
