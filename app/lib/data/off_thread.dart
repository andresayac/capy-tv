// Work off the UI thread, on every platform.
//
// `Isolate.run` is the obvious way to parse a guide or a catalog without stalling a frame, but the
// web build has no isolates: it throws "Unsupported operation: new RawReceivePort" the moment it
// is called, which on a browser is every time a playlist is added (the list is parsed off-thread).
//
// `compute` is the portable one: an isolate on Android, Windows and the rest, and a plain call on
// the page's own thread on the web (there is nowhere else to go). Slower there, but it works, and
// every caller already treats the work as asynchronous.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform.dart';
import 'models.dart';

/// Runs [work] away from the UI thread where the platform has one.
Future<R> runOffThread<R>(FutureOr<R> Function() work) async {
  if (isWeb) return await work();
  return await compute(_call, (work, untitledName));
}

// Top-level so it can be sent to an isolate. An isolate starts with its own copy of every global:
// the name of what has none goes along, in the app's language
FutureOr<R> _call<R>((FutureOr<R> Function(), String) job) {
  untitledName = job.$2;
  return job.$1();
}
