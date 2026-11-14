// Anywhere but a browser, mpv plays the sound itself and switches its track: nothing to add.
// See movi_sound.dart.
import 'package:media_kit/media_kit.dart';

/// Starts nothing: the player's own sound is the one heard.
Future<void> startMoviSound(Player player, String url, {double volume = 100, int tries = 8}) async {}

/// Nothing to stop.
void stopMoviSound(Player player) {}

/// No tracks of its own: mpv reports them, through the player.
List<AudioTrack> moviAudioTracks(Player player) => const [];

/// The picture's own sound is always the one heard here.
bool soundTookOver(Player player) => false;

/// Nothing to switch: the player does it.
Future<bool> selectMoviAudio(Player player, AudioTrack track) async => false;

/// Nothing to set: the player's own volume is used.
void setMoviVolume(Player player, double volume) {}
