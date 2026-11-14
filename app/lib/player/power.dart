// What keeps a computer from sleeping through a recording, and wakes it for one (Windows).
//
// dart:ffi does not exist on the web: the implementation is picked when the app is compiled, as in
// platform.dart. A browser records nothing.
export 'power_native.dart' if (dart.library.js_interop) 'power_web.dart';
