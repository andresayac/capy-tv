import 'package:flutter/services.dart';

import '../device.dart';
import '../platform.dart';

/// Playback that goes on with the app in the background, on Android phones and tablets, when the
/// setting is on ([AppSettings.backgroundPlay]): Android's controls for it in a notification, on
/// the lock screen and on headsets, while the player is open. A call or another app's sound pauses
/// it. Not on TVs, where leaving the app is leaving what plays. A cast to a Chromecast uses the
/// same controls, remote: its sound is on the TV. Code on Android: PlaybackService.kt.
///
/// The controls have one owner at a time, the last to [claim] them (the player playing here, or a
/// cast); when it lets go, the one before gets them back.
abstract final class BackgroundPlay {
  static const _channel = MethodChannel('iptv_player/media');

  static bool get available => isAndroid && !isTv;

  static final _claims = <({Object owner, void Function(String, Duration?) onAction, void Function()? onRegain})>[];
  static var _listening = false;

  /// [owner] takes the controls: what they ask ('play', 'pause', 'stop', or 'seek' to a position)
  /// goes to [onAction] until it lets go; [onRegain] when they come back to it.
  static void claim(Object owner, void Function(String action, Duration? at) onAction, {void Function()? onRegain}) {
    _claims
      ..removeWhere((c) => c.owner == owner)
      ..add((owner: owner, onAction: onAction, onRegain: onRegain));
  }

  /// [owner] lets go of the controls; the one before it gets them back.
  static void release(Object owner) {
    final had = owns(owner);
    _claims.removeWhere((c) => c.owner == owner);
    if (had && _claims.isNotEmpty) _claims.last.onRegain?.call();
  }

  static bool owns(Object owner) => _claims.isNotEmpty && identical(_claims.last.owner, owner);

  /// Shows what [owner] plays in Android's controls (they appear the first time); nothing when it
  /// does not have them. [remote]: it plays elsewhere, so no audio focus is taken here and headphones
  /// coming out do not pause it. False when Android would not start them: the app was in the
  /// background (from Android 12 on); true otherwise, or where there are none. [sameArt]: the
  /// picture is the one sent last time, not sent nor decoded again (a pause, a seek).
  static Future<bool> show(
    Object owner, {
    required String title,
    required String subtitle,
    Uint8List? art,
    bool sameArt = false,
    required bool playing,
    required Duration position,
    required Duration duration,
    required bool live,
    required double rate,
    required Map<String, String> labels,
    bool remote = false,
  }) async {
    if (!available || !owns(owner)) return true;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        final at = call.arguments;
        if (_claims.isNotEmpty) _claims.last.onAction(call.method, at is int ? Duration(milliseconds: at) : null);
      });
    }
    return await _channel.invokeMethod<bool>('show', {
          'title': title,
          'subtitle': subtitle,
          'art': art,
          'sameArt': sameArt,
          'playing': playing,
          'position': position.inMilliseconds,
          'duration': duration.inMilliseconds,
          'live': live,
          'rate': rate,
          'labels': labels,
          'remote': remote,
        }) !=
        false;
  }

  /// Takes the controls away, when [owner] has them.
  static Future<void> hide(Object owner) async {
    if (available && owns(owner)) await _channel.invokeMethod('hide');
  }
}
