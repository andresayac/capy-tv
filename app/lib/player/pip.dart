import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../desktop_window.dart';
import '../device.dart';
import '../platform.dart';

/// Picture in picture: the player in a small window over other apps. On Android phones and tablets,
/// Android's, by its button or by leaving the app while something plays; not on TVs, where a remote
/// has no way to the window. On Windows the app's own window made small (DesktopWindow.enterMini),
/// by its button or the P key.
abstract final class Pip {
  static const _channel = MethodChannel('iptv_player/pip');

  /// Whether the player is in the small window now.
  static final active = ValueNotifier(false);

  /// The window's play/pause button.
  static VoidCallback? onPlayPause;

  /// The window was closed (not opened back to the whole screen).
  static VoidCallback? onClosed;

  static Future<bool>? _supported;

  /// Whether the small window is the computer's own window (Windows), not Android's.
  static bool get desktop => isWindows && DesktopWindow.instance.ownTitleBar;

  static Future<bool> supported() => _supported ??= () async {
    if (desktop) return true;
    if (!isAndroid || isTv) return false;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'changed':
          active.value = call.arguments as bool;
        case 'playPause':
          onPlayPause?.call();
        case 'closed':
          onClosed?.call();
      }
    });
    try {
      return await _channel.invokeMethod<bool>('supported') ?? false;
    } on Object {
      return false;
    }
  }();

  /// The picture's shape, width to height; 16:9 while it is not known.
  static double _ratio(int? width, int? height) =>
      width != null && height != null && width > 0 && height > 0 ? width / height : 16 / 9;

  /// Opens the small window now, shaped like the picture. False when Android would not: switched
  /// off for this app in its settings. [pause] and [play] name its button for screen readers.
  static Future<bool> enter({int? width, int? height, String? pause, String? play}) async {
    if (!await supported()) return false;
    if (desktop) {
      final ok = await DesktopWindow.instance.enterMini(_ratio(width, height));
      if (ok) active.value = true;
      return ok;
    }
    try {
      return await _channel.invokeMethod<bool>('enter', {
            'width': width,
            'height': height,
            'pause': pause,
            'play': play,
          }) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Back from the small window to the whole screen, as a tap on it does (a double click on a
  /// computer).
  static Future<void> leave() async {
    if (!active.value) return;
    if (desktop) {
      await DesktopWindow.instance.leaveMini();
      active.value = false;
      return;
    }
    await _channel.invokeMethod('leave');
  }

  /// The computer's small window closed by its own button: back to the window as it was, the
  /// player paused, as Android's closed window leaves it.
  static Future<void> close() async {
    await leave();
    onClosed?.call();
  }

  /// What the window needs to know: whether leaving the app opens it ([auto], while something
  /// plays), the picture's shape, and whether its button pauses or plays. On a computer only the
  /// shape counts, while it is small.
  static Future<void> update({
    required bool auto,
    required bool playing,
    int? width,
    int? height,
    String? pause,
    String? play,
  }) async {
    if (!await supported()) return;
    if (desktop) {
      if (active.value && width != null && height != null && width > 0 && height > 0) {
        await DesktopWindow.instance.fitMini(_ratio(width, height));
      }
      return;
    }
    await _channel.invokeMethod('update', {
      'auto': auto,
      'playing': playing,
      'width': width,
      'height': height,
      'pause': pause,
      'play': play,
    });
  }
}
