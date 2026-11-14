import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/catalog.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/settings.dart';
import '../data/source.dart';
import '../device.dart';
import '../platform.dart';
import '../ui/common.dart';
import 'audio_choice.dart';
import 'movi_player.dart';
import 'player_screen.dart';
import 'props.dart';

/// One playable entry: a channel, a movie or an episode.
class PlayItem {
  const PlayItem({
    required this.url,
    required this.title,
    this.subtitle,
    this.ref,
    this.headers = const {},
    this.alternates = const [],
    this.start,
    this.pinned = false,
  });

  final String url;
  final String title;
  final String? subtitle;
  final MediaRef? ref; // when set, progress is saved to the library
  final Map<String, String> headers; // HTTP headers the stream needs, like an M3U user agent

  /// Other copies of the same title (another language or quality, another provider): the player
  /// tries them, fastest first, when one does not start. Only their address and headers count.
  final List<PlayItem> alternates;

  /// Where to start, instead of where it was left here (sent from another device).
  final Duration? start;

  /// This copy was picked by hand (a language, a provider): it goes first, the others only if it
  /// does not start, instead of the fastest first.
  final bool pinned;

  PlayItem pinnedCopy() => PlayItem(
    url: url,
    title: title,
    subtitle: subtitle,
    ref: ref,
    headers: headers,
    alternates: alternates,
    start: start,
    pinned: true,
  );

  bool get isLive => ref?.kind == MediaKind.live;

  PlayItem startingAt(Duration? at) => PlayItem(
    url: url,
    title: title,
    subtitle: subtitle,
    ref: ref,
    headers: headers,
    alternates: alternates,
    start: at,
    pinned: pinned,
  );

  PlayItem withHeaders(Map<String, String> Function(String url) headersFor) => PlayItem(
    url: url,
    title: title,
    subtitle: subtitle,
    ref: ref,
    headers: headers.isEmpty ? headersFor(url) : headers,
    alternates: [for (final a in alternates) a.withHeaders(headersFor)],
    start: start,
    pinned: pinned,
  );
}

/// [m] to play, with the other versions of its title the open catalog has as alternates.
PlayItem movieItem(ContentSource source, Movie m) {
  final versions = currentCatalog.value?.loaded?.versionsOf(m) ?? const <Movie>[];
  return PlayItem(
    url: source.movieUrl(m),
    title: m.name,
    ref: MediaRef.movie(m),
    alternates: [
      for (final v in versions)
        if (v.id != m.id) PlayItem(url: source.movieUrl(v), title: v.name),
    ],
  );
}

/// The player and its video output for one viewing session, with the decoder chosen in the
/// settings; both are replaced when the decoder changes during the session ([switchDecoder]).
class PlaybackEngine {
  PlaybackEngine._(this._settings, this.player, this.controller, {required this.hardware});

  final AppSettings? _settings;
  Player player;
  VideoController controller;

  /// The device's hardware decoder (on Android drawing straight to the screen: smooth on modest TV
  /// boxes, but a device's decoder may choke on an odd stream; the software decoder is the way out).
  bool hardware;

  static Future<PlaybackEngine> start(AppSettings? settings) async {
    final hardware = settings?.decoder != 'software';
    final (player, controller) = await _make(settings, hardware: hardware);
    return PlaybackEngine._(settings, player, controller, hardware: hardware);
  }

  static Future<(Player, VideoController)> _make(AppSettings? settings, {required bool hardware}) async {
    // Warnings too: an HTTP 404 or 403 comes as one, and says why a stream did not open. In a
    // browser, files play in movi, which starts on [hardware] too (see movi_player.dart)
    final player = newPlayer(hardware: hardware);
    final controller = VideoController(
      player,
      configuration: switch ((isAndroid, hardware)) {
        (true, true) => const VideoControllerConfiguration(vo: 'mediacodec_embed', hwdec: 'mediacodec'),
        (_, false) => const VideoControllerConfiguration(hwdec: 'no'),
        _ => const VideoControllerConfiguration(), // elsewhere media_kit's defaults decode on the GPU
      },
    );
    await settings?.applyTo(player);
    await player.setVolume(await savedVolume()); // where the last title left it
    // An HTTP stream that breaks off is opened again by FFmpeg itself, picture and all; what it
    // cannot see (a stream that freezes) the player screen handles
    await setPlayerProperty(player, 'stream-lavf-o', 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5');
    // A panel that wakes a channel up takes a while to answer; media_kit gives up at 5 s
    await setPlayerProperty(player, 'network-timeout', '15');
    // Of an HLS stream's qualities mpv takes the highest and never adapts: a TV stick on a modest
    // Wi-Fi would buffer for good on a 4K one, or not decode it. As much as the device can take
    await setPlayerProperty(player, 'hls-bitrate', switch (deviceTier) {
      DeviceTier.low => '3500000',
      DeviceTier.medium => '8000000',
      DeviceTier.high => 'max',
    });
    return (player, controller);
  }

  /// The other decoder, without leaving: a new player and video output take the place of these
  /// (the decoder of a running one cannot change). Returns the old player, for the caller to let
  /// go once nothing shows it.
  Future<Player> switchDecoder({required bool hardware}) async {
    final old = player;
    final (p, c) = await _make(_settings, hardware: hardware);
    // The player closed meanwhile: this one is let go too, not left behind
    if (_disposed) {
      unawaited(p.dispose());
      return old;
    }
    player = p;
    controller = c;
    this.hardware = hardware;
    return old;
  }

  Future<void> dispose() {
    _disposed = true;
    return player.dispose();
  }

  var _disposed = false;
}

/// Builds a playable item from a library reference.
PlayItem playItemFor(ContentSource source, MediaRef r) => switch (r.kind) {
  MediaKind.live => PlayItem(url: source.liveUrl(r.toChannel()), title: r.title, ref: r),
  MediaKind.movie => () {
    final item = movieItem(source, r.toMovie());
    return PlayItem(url: item.url, title: r.title, ref: r, alternates: item.alternates);
  }(),
  MediaKind.episode => PlayItem(
    url: source.episodeUrl(r.toEpisode()),
    title: r.seriesTitle ?? r.title,
    subtitle: 'S${r.season} · E${r.number}  ${r.title}',
    ref: r,
  ),
  MediaKind.series => throw ArgumentError('A series is not playable; play one of its episodes'),
};

/// [r]'s item, or null when its list cannot make one any more: a combined list's part that is gone,
/// an entry of a list that changed from Xtream to M3U.
PlayItem? tryPlayItemFor(ContentSource source, MediaRef r) {
  try {
    return playItemFor(source, r);
  } on Object catch (e) {
    debugPrint('Play: $e');
    return null;
  }
}

/// Plays [refs] as a queue from the one at [index], leaving out those that cannot play. When that
/// one cannot, says why instead of doing nothing.
Future<void> playRefs(BuildContext context, ContentSource source, List<MediaRef> refs, int index) async {
  try {
    playItemFor(source, refs[index]);
  } on Object catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(context.l10n, e))));
    return;
  }
  final items = <PlayItem>[];
  var at = 0;
  for (var i = 0; i < refs.length; i++) {
    if (tryPlayItemFor(source, refs[i]) case final item?) {
      if (i == index) at = items.length;
      items.add(item);
    }
  }
  await playQueue(context, items, index: at);
}

/// Plays [r] from a profile's library; an episode with the rest of its series around it, so the next
/// one follows as from the series' page (one alone if the provider does not answer in time). [from]
/// for where another device left it.
Future<void> playFromLibrary(BuildContext context, ContentSource source, MediaRef r, {Duration? from}) async {
  final PlayItem first;
  try {
    first = playItemFor(source, r);
  } on Object catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(context.l10n, e))));
    return;
  }
  var items = [first];
  var index = 0;
  if (r.kind == MediaKind.episode && r.seriesId != null) {
    try {
      final d = await source.seriesDetail(r.toSeries()).timeout(const Duration(seconds: 6));
      final all = [for (final list in d.seasons.values) ...list];
      final i = all.indexWhere((e) => e.id == r.id);
      if (i >= 0) {
        items = [
          for (final x in all)
            PlayItem(
              url: source.episodeUrl(x),
              title: d.series.name,
              subtitle: ['S${x.season} · E${x.number}', ?episodeName(x, d.series.name)].join('  '),
              ref: MediaRef.episode(d.series, x),
            ),
        ];
        index = i;
      }
    } on Object {
      // One episode, then
    }
  }
  if (from != null) items[index] = items[index].startingAt(from);
  if (context.mounted) await playQueue(context, items, index: index);
}

/// Plays [items] starting at [index] in the full-screen player. For live channels the queue is
/// what channel up/down zaps through; for episodes it drives "next episode".
/// The player is created per session and disposed when the screen closes.
/// Plays [items] from [index] in the player; with [replace], in place of the screen that asks (as
/// multiview does).
Future<void> playQueue(BuildContext context, List<PlayItem> items, {int index = 0, bool replace = false}) async {
  final source = currentCatalog.value?.source;
  if (source != null) items = [for (final i in items) i.withHeaders(source.headersFor)];
  final library = LibraryScope.maybeOf(context);
  final settings = SettingsScope.maybeOf(context);
  // Starting the engine takes a moment with nothing on screen: a second tap meanwhile would open a
  // second player, the first going on playing under it
  if (_opening) return;
  _opening = true;
  PlaybackEngine? engine;
  try {
    engine = await PlaybackEngine.start(settings);
    if (!context.mounted) return;
    final started = engine;
    final route = MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(engine: started, items: items, index: index, library: library),
    );
    final navigator = Navigator.of(context);
    final shown = replace ? navigator.pushReplacement(route) : navigator.push(route);
    _opening = false;
    await shown;
  } finally {
    _opening = false;
    // Not awaited: a device decoder stuck on a bad stream can take long to let go, and leaving the
    // player must never wait for it
    if (engine != null) unawaited(engine.dispose());
  }
}

var _opening = false;

Future<void> playMedia(
  BuildContext context, {
  required String url,
  required String title,
  String? subtitle,
  MediaRef? ref,
}) => playQueue(context, [PlayItem(url: url, title: title, subtitle: subtitle, ref: ref)]);
