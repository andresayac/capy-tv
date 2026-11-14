// The room left on a disk, asked of the system. See free_space.dart.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _device = MethodChannel('iptv_player/device');

/// Bytes the app may still write on the disk [path] (an existing folder) is on; null when the
/// system does not say (iOS) or could not be asked.
Future<int?> freeBytes(String path) async {
  try {
    if (Platform.isAndroid) return await _device.invokeMethod<int>('freeBytes', {'path': path});
    if (Platform.isWindows) return _windows(path);
    if (Platform.isLinux || Platform.isMacOS) return await _df(path);
  } on Object catch (e) {
    debugPrint('free space: $e');
  }
  return null;
}

typedef _LocalAllocC = Pointer<Void> Function(Uint32 flags, IntPtr bytes);
typedef _LocalAllocDart = Pointer<Void> Function(int flags, int bytes);
typedef _LocalFreeC = Pointer<Void> Function(Pointer<Void> memory);
typedef _FreeSpaceC = Int32 Function(
  Pointer<Uint16> dir,
  Pointer<Uint64> free,
  Pointer<Uint64> total,
  Pointer<Uint64> all,
);
typedef _FreeSpaceDart = int Function(
  Pointer<Uint16> dir,
  Pointer<Uint64> free,
  Pointer<Uint64> total,
  Pointer<Uint64> all,
);

/// GetDiskFreeSpaceExW: what this user may still write there (quotas taken into account). Its
/// memory comes from Windows itself (LocalAlloc), which needs no package.
int? _windows(String path) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final alloc = kernel.lookupFunction<_LocalAllocC, _LocalAllocDart>('LocalAlloc');
  final release = kernel.lookupFunction<_LocalFreeC, _LocalFreeC>('LocalFree');
  final ask = kernel.lookupFunction<_FreeSpaceC, _FreeSpaceDart>('GetDiskFreeSpaceExW');
  const zeroed = 0x40; // LPTR
  final units = [...path.codeUnits, 0];
  final name = alloc(zeroed, units.length * 2).cast<Uint16>();
  final free = alloc(zeroed, 8).cast<Uint64>();
  try {
    if (name == nullptr || free == nullptr) return null;
    for (final (i, u) in units.indexed) {
      name[i] = u;
    }
    return ask(name, free, nullptr, nullptr) == 0 ? null : free.value;
  } finally {
    for (final p in [name, free]) {
      if (p != nullptr) release(p.cast());
    }
  }
}

/// df in the POSIX format: its fourth column is what is available, in kilobytes.
Future<int?> _df(String path) async {
  final r = await Process.run('df', ['-Pk', path]);
  if (r.exitCode != 0) return null;
  final lines = '${r.stdout}'.trim().split('\n');
  if (lines.length < 2) return null;
  // From the end: the device's name may have spaces
  final m = RegExp(r'\s(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s').firstMatch(lines.last);
  final kb = m == null ? null : int.tryParse(m[3]!);
  return kb == null ? null : kb * 1024;
}
