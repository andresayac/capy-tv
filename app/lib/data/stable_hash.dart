// FNV-1a over 64 bits, the same value on every platform. See source.dart (stableHash).
//
// A native Dart int is 64 bits, so the plain loop is exact there. A JavaScript number carries 53:
// the web build would either refuse the literals or quietly lose the low bits, and the ids that
// carry a hash (an M3U list's items, which sync between a TV and a browser) would then be two
// different things on the two ends. So the web one does the same arithmetic in BigInt.
export 'stable_hash_native.dart' if (dart.library.js_interop) 'stable_hash_web.dart';
