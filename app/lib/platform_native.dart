// The device, through dart:io. See platform.dart.
import 'dart:io';

/// Running as a web app (always false here, so branches that only make sense in a browser are
/// left out of every native build).
const isWeb = false;

/// Whether a raw MPEG-TS live stream can be opened, without knowing its length in advance.
/// mpv reads one straight off the socket; a browser cannot (see platform_web.dart).
const opensRawLiveTs = true;

bool get isAndroid => Platform.isAndroid;
bool get isIOS => Platform.isIOS;
bool get isWindows => Platform.isWindows;
bool get isLinux => Platform.isLinux;
bool get isMacOS => Platform.isMacOS;

/// The computer's name, for the devices list; a blank one on the platforms that do not say.
String get localHostname {
  try {
    return Platform.localHostname;
  } on Object {
    return '';
  }
}

/// This platform's path separator, for the few places the app names files by hand.
String get pathSeparator => Platform.pathSeparator;

/// For the diagnostics screen: what this runs on, as dart:io names it.
String get operatingSystem => Platform.operatingSystem;
String get operatingSystemVersion => Platform.operatingSystemVersion;
