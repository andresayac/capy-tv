// Tells web/index.html that Flutter's first frame is on screen, so it takes away the splash it
// draws meanwhile. On the native platforms there is no page and nothing to tell.
export 'ready_native.dart' if (dart.library.js_interop) 'ready_web.dart';
