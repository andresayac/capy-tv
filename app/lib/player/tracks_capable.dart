// Whether this build's player can offer a stream's audio languages.
//
// Native (mpv): yes, always — it reads the file's tracks and switches them.
// Browser: no. Chrome has no HTMLVideoElement.audioTracks, and media_kit's web player reports an
// empty track list (so `setAudioTrack` has nothing to be given). A <video> plays one audio track,
// the file's default, and that is all.
//
// Saying so is the point of this file: the tracks panel then explains it, instead of showing an
// empty list that reads as "this file has no languages". See player_screen.dart.
export 'tracks_capable_native.dart' if (dart.library.js_interop) 'tracks_capable_web.dart';
