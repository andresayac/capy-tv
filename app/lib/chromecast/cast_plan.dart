import 'package:flutter/foundation.dart';

import '../data/xtream_paths.dart';
import '../player/play.dart';

/// How a candidate reaches the receiver: [direct]ly from the provider, or through this device's
/// relay ([CastRelay]), as [hls] with its playlists rewritten or as a [progressive] file.
enum CastRoute { direct, hls, progressive }

/// Why an item cannot be cast: a channel in a format the receiver cannot play live ([liveFormat]),
/// a video in a container it cannot play ([file], see [CastPlan.format]), a recording or catch-up
/// ([local]), or a channel whose account does not allow the HLS a cast needs ([noHls]).
enum CastRefusal { liveFormat, file, local, noHls }

/// One way to play an item on the receiver. [headers] are what the relay sends the provider.
class CastCandidate {
  const CastCandidate({
    required this.url,
    required this.contentType,
    required this.route,
    this.headers = const {},
    this.live = false,
  });

  final String url, contentType;
  final CastRoute route;
  final Map<String, String> headers;
  final bool live;

  @override
  bool operator ==(Object other) =>
      other is CastCandidate &&
      other.url == url &&
      other.contentType == contentType &&
      other.route == route &&
      other.live == live &&
      mapEquals(other.headers, headers);

  @override
  int get hashCode => Object.hash(url, contentType, route, live, headers.length);

  @override
  String toString() =>
      'CastCandidate(${route.name}, $contentType${live ? ', live' : ''}, ${Uri.tryParse(url)?.host}, ${headers.length} headers)';
}

/// What to try on the receiver, in order; or, with no [candidates], why the item cannot be cast.
/// [format] is the refused file's extension; [mkv] says a candidate is Matroska, which the
/// receiver may not play.
class CastPlan {
  const CastPlan(this.candidates, {this.refusal, this.format, this.mkv = false});

  final List<CastCandidate> candidates;
  final CastRefusal? refusal;
  final String? format;
  final bool mkv;

  bool get castable => candidates.isNotEmpty;

  @override
  String toString() => 'CastPlan($candidates, refusal: ${refusal?.name}, format: $format, mkv: $mkv)';
}

/// How [item] can be cast: the item first, then its alternates, the ones in containers the receiver
/// plays best first. Channels always go through the relay as HLS; Xtream channels are asked for in
/// their m3u8 output whatever the app plays here. [accountFormats] are the outputs the Xtream
/// account allows, when known (empty counts as unknown). [panelExport]: the item's list is a
/// panel's M3U export, so its short /user/password/id addresses are the panel's channels.
CastPlan castPlan(PlayItem item, {Set<String>? accountFormats, bool panelExport = false}) {
  final formats = accountFormats == null || accountFormats.isEmpty
      ? null
      : {for (final f in accountFormats) f.toLowerCase()};
  final ways = [
    for (final source in [item, ...item.alternates])
      _way(source.url, source.headers, live: item.isLive, formats: formats, panelExport: panelExport),
  ];
  // By rank, and within one in the item's order (sort() alone may not keep it)
  final ranked = ways.indexed.toList()
    ..sort((a, b) => a.$2.rank != b.$2.rank ? a.$2.rank.compareTo(b.$2.rank) : a.$1.compareTo(b.$1));
  final candidates = <CastCandidate>[];
  for (final (_, w) in ranked) {
    for (final c in w.candidates) {
      if (!candidates.contains(c)) candidates.add(c);
    }
  }
  if (candidates.isEmpty) return CastPlan(const [], refusal: ways.first.refusal, format: ways.first.format);
  return CastPlan(candidates, mkv: candidates.any((c) => c.contentType == _matroska));
}

const _hlsType = 'application/x-mpegurl', _matroska = 'video/x-matroska';

extension CastCandidateKind on CastCandidate {
  /// An MKV, which many TVs do not play.
  bool get isMatroska => contentType == _matroska;
}

/// Video containers the receiver may play, with the type to load them as and their rank: the
/// ones it plays first, QuickTime (which its MP4 reader takes), then Matroska, which it may not.
const _files = {
  'mp4': ('video/mp4', 0),
  'm4v': ('video/mp4', 0),
  'webm': ('video/webm', 0),
  'mov': ('video/mp4', 1),
  'mkv': (_matroska, 2),
  'mp3': ('audio/mpeg', 1),
  'm4a': ('audio/mp4', 1),
  'aac': ('audio/aac', 1),
};

/// Containers the receiver does not play.
const _refusedFiles = {
  'avi',
  'flv',
  'wmv',
  'mpg',
  'mpeg',
  'ts',
  'm2ts',
  'mts',
  'vob',
  'asf',
  'rm',
  'rmvb',
  'divx',
  '3gp',
};

/// A live stream of a panel served under a path of its own (https://proxy.example/iptv/live/…):
/// that path, then the user, password and id.
final _xtreamLive = RegExp(r'^(/(?:.*/)?)live/([^/]+)/([^/]+)/(\d+)(?:\.\w+)?$');

/// How one address casts: its candidates and their rank, or why it does not.
typedef _Way = ({int rank, List<CastCandidate> candidates, CastRefusal? refusal, String? format});

_Way _refuse(CastRefusal why, [String? format]) => (rank: 0, candidates: const [], refusal: why, format: format);

_Way _way(
  String url,
  Map<String, String> headers, {
  required bool live,
  required Set<String>? formats,
  required bool panelExport,
}) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
    // A file on this device (a recording) has no address the receiver could reach; rtmp, rtsp or
    // udp it does not play
    final elsewhere = uri != null && uri.host.isNotEmpty && !uri.isScheme('file');
    if (!elsewhere) return _refuse(CastRefusal.local);
    return live ? _refuse(CastRefusal.liveFormat) : _refuse(CastRefusal.file, uri.scheme.toLowerCase());
  }
  if (uri.pathSegments.any((s) => s == 'timeshift' || s == 'timeshift.php')) return _refuse(CastRefusal.local);
  final ext = _extension(uri);
  final xtream = parseXtreamPath(uri.path), long = _xtreamLive.firstMatch(uri.path);
  if (live || xtream?.type == 'live' || long != null) {
    CastCandidate hls(String url) =>
        CastCandidate(url: url, contentType: _hlsType, route: CastRoute.hls, headers: headers, live: true);
    if (ext == 'm3u8') return (rank: 0, candidates: [hls(url)], refusal: null, format: null);
    // The panel's HLS of the same channel, under the panel's own path when it has one. The short
    // form only from a panel's export: elsewhere /news/hd/7.ts is some server's, with no /live/
    final path = long != null
        ? '${long[1]}live/${long[2]}/${long[3]}/${long[4]}.m3u8'
        : xtream != null && xtream.type == null && panelExport
        ? '/live/${xtream.user}/${xtream.password}/${xtream.id}.m3u8'
        : null;
    if (path != null && (ext == null || ext == 'ts')) {
      if (formats != null && !formats.contains('m3u8')) return _refuse(CastRefusal.noHls);
      return (rank: 0, candidates: [hls(uri.replace(path: path).toString())], refusal: null, format: null);
    }
    // No extension, .m3u or a script: often HLS that does not say so. Tried; if it is not, the TV
    // says it cannot play it
    if (ext == null || ext == 'm3u' || ext == 'php') {
      return (rank: 0, candidates: [hls(url)], refusal: null, format: null);
    }
    return _refuse(CastRefusal.liveFormat); // a TS stream: the receiver plays live TS only as HLS
  }
  if (ext == 'm3u8') {
    final c = CastCandidate(url: url, contentType: _hlsType, route: CastRoute.hls, headers: headers);
    return (rank: 0, candidates: [c], refusal: null, format: null);
  }
  if (_refusedFiles.contains(ext)) return _refuse(CastRefusal.file, ext);
  if (ext == 'mpd') {
    // DASH straight from the provider only: the relay does not rewrite its manifest, whose relative
    // addresses would then point at the relay (and it plays only if the provider sends CORS)
    if (headers.isNotEmpty) return _refuse(CastRefusal.file, 'mpd');
    final c = CastCandidate(url: url, contentType: 'application/dash+xml', route: CastRoute.direct);
    return (rank: 0, candidates: [c], refusal: null, format: null);
  }
  // An unknown container is tried last, as MP4, the most common one
  final (type, rank) = _files[ext] ?? ('video/mp4', 3);
  final direct = CastCandidate(url: url, contentType: type, route: CastRoute.direct);
  final relayed = CastCandidate(url: url, contentType: type, route: CastRoute.progressive, headers: headers);
  // The receiver sends no headers of its own; and a provider that turns it away (by its User-Agent,
  // or by where it comes from) may still take this device
  final candidates = headers.isNotEmpty ? [relayed] : [direct, relayed];
  return (rank: rank, candidates: candidates, refusal: null, format: null);
}

/// The lowercase extension of [uri]'s last path segment, if it has one.
String? _extension(Uri uri) {
  final name = uri.pathSegments.lastOrNull ?? '';
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}
