import 'package:flutter/foundation.dart';

import '../data/library.dart';

/// What another device of the account sent here to play ("Send to"), and from where in it.
class CastRequest {
  const CastRequest({
    required this.playlistId,
    required this.ref,
    required this.position,
    required this.from,
    required this.at,
  });

  /// This device's id of the playlist it is in.
  final String playlistId;
  final MediaRef ref;
  final Duration position;

  /// The name of the device that sent it.
  final String from;

  /// When it was sent.
  final DateTime at;
}

/// The last request sent here, until the screen that plays it takes it (the open playlist's Home,
/// else the playlists screen, which opens that playlist first).
final castRequest = ValueNotifier<CastRequest?>(null);
