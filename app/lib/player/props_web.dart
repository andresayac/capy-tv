// mpv properties on the web, where there is no mpv: the player is media_kit's web one over an
// HTML <video>, which the browser drives. Picked when the app is compiled; the native platforms
// use props_native.dart.
//
// Only what the browser can actually be told is honoured. The rest is a no-op, and the player
// screen carries on: what those properties changed on mpv (the picture's track while only the
// sound plays, the demuxer's buffers, the User-Agent) has no meaning in a browser, which cannot
// change its User-Agent and decodes only what it knows.
//
// A file playing in movi (see movi_player_web.dart) says more: its decoder, codecs and frame rate
// for the stream info, and it starts on the languages the settings ask for (alang, slang).
import 'package:media_kit/media_kit.dart';

import 'movi_player_web.dart';

/// The properties whose answer the player screen actually reads, from the state media_kit
/// already keeps on web. Everything else answers '', as a property libmpv does not have.
String _fromState(Player player, String name) {
  final s = player.state;
  return switch (name) {
    'track-list/count' => '${s.tracks.audio.length + s.tracks.video.length + s.tracks.subtitle.length}',
    'container-fps' => s.width == null ? '' : '', // the browser does not expose a frame rate
    _ => '',
  };
}

Future<void> setProperty(Player player, String name, String value) async {
  final movi = player.platform;
  try {
    switch (name) {
      // The languages to start on, as mpv takes them: "spa,es,esp"
      case 'alang' when movi is CapyWebPlayer:
        movi.preferAudio(value.split(','));
      case 'slang' when movi is CapyWebPlayer:
        movi.preferSubtitles(value.split(','));
      case 'sid' when value == 'no' && movi is CapyWebPlayer && player.state.playlist.medias.isEmpty:
        movi.preferSubtitlesOff();
      // Subtitles off, and nothing else: the browser's <video> has text tracks of its own
      case 'sid' when value == 'no':
        await player.setSubtitleTrack(SubtitleTrack.no());
      // The picture's track while only the sound plays: the browser has one picture track only
      case 'vid':
        // Nothing to do: a <video> always shows its picture. The player screen keeps its own
        // notion of "sound only" and mutes instead.
        break;
      default:
        break;
    }
  } on Object {
    // A player that closed meanwhile
  }
}

Future<String> getProperty(Player player, String name) async {
  try {
    final movi = player.platform;
    if (movi is CapyWebPlayer) {
      final said = movi.property(name);
      if (said != null && said.isNotEmpty) return said;
    }
    return _fromState(player, name);
  } on Object {
    return '';
  }
}

Future<({String audio, String sub})> selectedTracks(Player player) async {
  try {
    final t = player.state.track;
    return (audio: t.audio.id, sub: t.subtitle.id);
  } on Object {
    return (audio: '', sub: '');
  }
}
