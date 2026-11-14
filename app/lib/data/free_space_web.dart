// The room left on a disk, in a browser: not known. See free_space.dart.

/// Bytes the app may still write on the disk [path] is on: never known in a browser.
Future<int?> freeBytes(String path) async => null;
