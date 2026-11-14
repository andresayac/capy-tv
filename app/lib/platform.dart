// What the device is, without dart:io throwing.
//
// dart:io's Platform compiles on the web but throws the moment it is read: every
// `Platform.isAndroid` in the app therefore had to move here, behind an implementation picked
// when the app is compiled. The native one is dart:io itself (platform_native.dart); the web one
// (platform_web.dart) answers for the browser: no phone, no desktop, a "/" separator.
//
// Nothing about the app's behaviour changes on the platforms it already ran on.
export 'platform_native.dart' if (dart.library.js_interop) 'platform_web.dart';
