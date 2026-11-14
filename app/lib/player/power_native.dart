// What keeps Windows from sleeping through a recording, and wakes it for one. See power.dart.
// Elsewhere nothing yet: Android has its own service (RecordingService.kt), and Linux and macOS
// sleep only when told to, by default.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

const _continuous = 0x80000000, _systemRequired = 0x00000001; // ES_CONTINUOUS, ES_SYSTEM_REQUIRED

typedef _StateC = Uint32 Function(Uint32 flags);
typedef _StateDart = int Function(int flags);
typedef _CreateTimerC = IntPtr Function(Pointer<Void> attributes, Int32 manualReset, Pointer<Void> name);
typedef _CreateTimerDart = int Function(Pointer<Void> attributes, int manualReset, Pointer<Void> name);
typedef _SetTimerC = Int32 Function(
  IntPtr timer,
  Pointer<Int64> due,
  Int32 period,
  Pointer<Void> routine,
  Pointer<Void> arg,
  Int32 resume,
);
typedef _SetTimerDart = int Function(
  int timer,
  Pointer<Int64> due,
  int period,
  Pointer<Void> routine,
  Pointer<Void> arg,
  int resume,
);
typedef _CancelTimerC = Int32 Function(IntPtr timer);
typedef _CancelTimerDart = int Function(int timer);
typedef _LocalAllocC = Pointer<Void> Function(Uint32 flags, IntPtr bytes);
typedef _LocalAllocDart = Pointer<Void> Function(int flags, int bytes);
typedef _LocalFreeC = Pointer<Void> Function(Pointer<Void> memory);

DynamicLibrary? _kernel;
DynamicLibrary get _k32 => _kernel ??= DynamicLibrary.open('kernel32.dll');
bool? _awake;
int _timer = 0; // the wake-up timer, made once and kept for the app's life

/// Keeps the computer from sleeping while [on] (SetThreadExecutionState), as players do while
/// they play: a recording goes on with nobody at the keyboard. The screen may still go off.
void keepSystemAwake(bool on) {
  if (!Platform.isWindows || _awake == on) return;
  try {
    final set = _k32.lookupFunction<_StateC, _StateDart>('SetThreadExecutionState');
    if (set(on ? _continuous | _systemRequired : _continuous) != 0) _awake = on;
  } on Object catch (e) {
    debugPrint('power: $e');
  }
}

/// Wakes the computer from sleep at [at], for a recording that starts then (a waitable timer that
/// resumes the system, where its power plan allows wake timers, as it does by default plugged in);
/// null: no wake-up.
void wakeSystemAt(DateTime? at) {
  if (!Platform.isWindows) return;
  try {
    if (at == null) {
      if (_timer != 0) _k32.lookupFunction<_CancelTimerC, _CancelTimerDart>('CancelWaitableTimer')(_timer);
      return;
    }
    if (_timer == 0) {
      final create = _k32.lookupFunction<_CreateTimerC, _CreateTimerDart>('CreateWaitableTimerW');
      _timer = create(nullptr, 1, nullptr);
      if (_timer == 0) return;
    }
    final alloc = _k32.lookupFunction<_LocalAllocC, _LocalAllocDart>('LocalAlloc');
    final release = _k32.lookupFunction<_LocalFreeC, _LocalFreeC>('LocalFree');
    final set = _k32.lookupFunction<_SetTimerC, _SetTimerDart>('SetWaitableTimer');
    final due = alloc(0x40, 8).cast<Int64>();
    if (due == nullptr) return;
    try {
      // When, as a FILETIME: tenths of a microsecond since 1601, in UTC
      due.value = at.toUtc().microsecondsSinceEpoch * 10 + 116444736000000000;
      set(_timer, due, 0, nullptr, nullptr, 1);
    } finally {
      release(due.cast());
    }
  } on Object catch (e) {
    debugPrint('power: $e');
  }
}
