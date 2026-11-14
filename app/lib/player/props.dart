// mpv properties, asked for and set through one function on every platform.
//
// The player's own controls are mpv's: the audio and subtitle language to start on, which track
// is on, how much of the stream is kept ahead of the play head, what the container is. media_kit
// exposes all of that only on the native player (NativePlayer.setProperty / getProperty), which
// the web build does not have: there the player is the browser's, and a `<movi-player>` element.
//
// So each call goes through these two functions, and the implementation is picked when the app
// is compiled: props_native.dart talks to mpv, props_web.dart to the element. A call the web
// player has no use for answers null (or does nothing), which the callers already handle: they
// parse the answer with `int.tryParse(...) ?? 0` and friends.
//
// Nothing else in the app changes shape: `playerProperty(player, 'x')` reads as before.
import 'package:media_kit/media_kit.dart';

import 'props_native.dart' if (dart.library.js_interop) 'props_web.dart' as impl;

/// Sets mpv's [name] to [value] on [player]; nothing where the platform's player has no such
/// property. Never throws: a property a build does not know, or a player already gone, is not
/// worth failing a viewing over.
Future<void> setPlayerProperty(Player player, String name, String value) => impl.setProperty(player, name, value);

/// mpv's [name] on [player]; '' where the platform's player has no such property.
Future<String> playerProperty(Player player, String name) => impl.getProperty(player, name);

/// The tracks mpv is actually using (media_kit reports "auto" when mpv picked them itself).
/// Empty where the player does not expose its track list that way; the caller only compares the
/// answer with the one it asked for.
Future<({String audio, String sub})> selectedTracks(Player player) => impl.selectedTracks(player);
