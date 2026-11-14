// The app's player: mpv everywhere but in a browser, where files play in movi-player and streams in
// the browser's own <video>. See movi_player_web.dart.
export 'movi_player_none.dart' if (dart.library.js_interop) 'movi_player_web.dart';
