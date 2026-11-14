// Anywhere but a browser the player is media_kit's own, over mpv. See movi_player.dart.
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

/// A player for the app; [hardware] is the video output's business here (see play.dart).
Player newPlayer({required bool hardware}) =>
    Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));

/// mpv plays the sound and switches its tracks itself: nothing else is wanted.
bool playsFilesItself(Player player) => false;

/// Unused here: mpv starts files as fast as streams.
const moviStartTimeout = Duration(seconds: 45);

/// The picture: media_kit's Video widget, [video], as it is.
class MoviPicture extends StatelessWidget {
  const MoviPicture({super.key, required this.player, required this.video, required this.fit, this.aspect});

  final Player player;
  final Widget video;
  final String fit;
  final double? aspect;

  @override
  Widget build(BuildContext context) => video;
}
