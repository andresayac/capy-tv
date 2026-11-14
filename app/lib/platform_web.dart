// The device, in a browser. See platform.dart.
//
// There is no file system and no Android here, so everything the desktop and the phones ask is
// answered "no": the screens that depend on it (recording, the companion server, background
// playback, picture-in-picture by Android's window) hide themselves instead of throwing.
const isWeb = true;

/// A raw MPEG-TS live stream is one HTTP response that never ends and has no length. mpv reads
/// it off the socket as it arrives; a browser player needs to know how big a thing is before it
/// starts (it fetches by ranges), so it waits forever and shows nothing. HLS is the way in: the
/// pieces are small files with a length each. Hence `liveFormat` defaults to m3u8 here.
const opensRawLiveTs = false;

const isAndroid = false;
const isIOS = false;
const isWindows = false;
const isLinux = false;
const isMacOS = false;

/// A browser has no name of its own to give.
const localHostname = '';

/// The one separator there is.
const pathSeparator = '/';

/// What to show on the diagnostics screen instead of dart:io's answer.
const operatingSystem = 'web';
const operatingSystemVersion = '';
