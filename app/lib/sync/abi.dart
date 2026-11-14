// The processor this build runs on, by Android's ABI names, as the sync server names its files;
// "windows-x64" for the Windows installer.
//
// dart:ffi is what says it, and dart:ffi does not exist on the web: so the answer is picked when
// the app is compiled. A browser is not Android either way: [currentAbi] answers null there, and
// app_update.dart stops before it asks for anything (see installed()).
import 'abi_native.dart' if (dart.library.js_interop) 'abi_web.dart' as impl;

/// arm64-v8a, armeabi-v7a, x86_64, x86, windows-x64; null where updates of this kind do not apply.
String? get currentAbi => impl.currentAbi;
