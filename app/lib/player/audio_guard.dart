// The player's sound on Android while the app is on screen and background play is off (with it on,
// BackgroundPlay's service does the same): the audio focus, so a call or another app's sound
// pauses the player rather than playing over it, and headphones coming out pause it rather than
// going on through the speaker. See AudioGuard.kt.
import 'package:flutter/services.dart';

import '../platform.dart';

abstract final class AudioGuard {
  static const _channel = MethodChannel('iptv_player/audio');

  /// The player holding the sound, told "pause" (for a while: a call), "play" (back from that)
  /// or "lost" (for good: another app, headphones out).
  static void Function(String change)? _holder;

  /// Takes the sound for [onChange]'s player; again after it was lost, as it plays once more.
  static Future<void> hold(void Function(String change) onChange) async {
    if (!isAndroid) return;
    _holder = onChange;
    _channel.setMethodCallHandler((call) async => _holder?.call(call.method));
    try {
      await _channel.invokeMethod<void>('hold', true);
    } on Object {
      // No guard: the sound goes on as before
    }
  }

  /// Lets go of the sound, if [onChange]'s player still holds it.
  static Future<void> release(void Function(String change) onChange) async {
    if (!isAndroid || _holder != onChange) return; // a method torn off again is equal, not identical
    _holder = null;
    try {
      await _channel.invokeMethod<void>('hold', false);
    } on Object {
      // Gone with the app
    }
  }
}
