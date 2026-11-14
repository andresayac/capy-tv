// A browser's <video> plays the file's default audio and cannot be asked for another: there is no
// audioTracks API in Chrome, and the player built on it reports no tracks at all. See
// tracks_capable.dart.
const playerPicksTracks = false;
