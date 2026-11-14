// The ABI of this build, through dart:ffi. See abi.dart.
import 'dart:ffi' show Abi;

String? get currentAbi => switch (Abi.current()) {
  Abi.androidArm64 => 'arm64-v8a',
  Abi.androidArm => 'armeabi-v7a',
  Abi.androidX64 => 'x86_64',
  Abi.androidIA32 => 'x86',
  // Windows on ARM runs the x64 installer too
  Abi.windowsX64 || Abi.windowsArm64 => 'windows-x64',
  _ => null,
};
