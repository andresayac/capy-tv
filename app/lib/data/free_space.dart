// The room left on the disk a folder is on, so a recording stops before it fills the device.
//
// dart:ffi, which asks Windows, does not exist on the web: the implementation is picked when the
// app is compiled, as in platform.dart. In a browser nothing is recorded, and nothing is known.
export 'free_space_native.dart' if (dart.library.js_interop) 'free_space_web.dart';
