import 'dart:convert';

/// What an address in an HLS playlist points at: another [playlist] (a variant, a rendition), or
/// [media] passed through as it comes (a segment, a key, an init section).
enum HlsKind { playlist, media }

/// An upstream address a playlist named, behind one of [HlsLinks]' ids.
class HlsLink {
  const HlsLink(this.url, this.kind);

  final Uri url;
  final HlsKind kind;
}

/// Short ids for the addresses in a stream's playlists. The same address always gets the same id,
/// so a refreshed live playlist names the segments it named before the same way.
///
/// Playlist ids are kept for good: a master names a few, and the receiver asks for them for as long
/// as it plays. Media ids are kept while the latest version of a playlist names them, and after that
/// the last [margin] of them, for a player still behind: a live channel names new segments forever,
/// a long film thousands at once.
class HlsLinks {
  HlsLinks({this.margin = 2000});

  final int margin;
  final _ids = <String, String>{}; // kind and address -> id
  final _links = <String, HlsLink>{};
  final _named = <String, Set<String>>{}; // playlist -> the media ids its latest version names
  final _uses = <String, int>{}; // media id -> how many latest versions name it
  final _dropped = <String>{}; // media ids no latest version names, oldest first
  final _places = <String, Map<String, _Place>>{}; // playlist -> where each playlist it named stood
  final _latest = <String, List<_Place>>{}; // playlist -> the playlists its latest version names
  var _next = 0;

  int get length => _links.length;

  HlsLink? operator [](String id) => _links[id];

  /// [text], fetched from [base], as the latest version of the playlist [owner] ('' for the first
  /// one): rewritten by [rewriteHls] with an id for every address, which [address] turns into what
  /// stands for it. Throws [FormatException] when [text] is no playlist.
  String rewrite(String owner, String text, Uri base, String Function(String id, HlsKind kind, Uri url) address) {
    final media = <String>{};
    final places = <_Place>[];
    final byTag = <String, int>{}, byName = <String, int>{};
    final out = rewriteHls(text, base, (url, kind, tag) {
      final id = _idFor(url, kind);
      if (kind == HlsKind.media) {
        media.add(id);
      } else {
        // Where it stands: under its tag, and among the tags of that name
        final name = tag.split(':').first;
        final exact = byTag[tag] = (byTag[tag] ?? 0) + 1;
        final loose = byName[name] = (byName[name] ?? 0) + 1;
        places.add((id: id, exact: '$tag#$exact', loose: '$name#$loose'));
      }
      return address(id, kind, url);
    });
    _name(owner, media);
    final known = _places[owner] ??= {};
    for (final p in places) {
      known[p.id] = p;
    }
    _latest[owner] = places;
    return out;
  }

  /// The playlist that stands, in [owner]'s latest version, where [id] stood when [owner] named it:
  /// under the same tag, else at the same place among the tags of that name. A fresh master may name
  /// its variants anew, with new tokens, and measure their bandwidth anew. Null when there is none.
  String? standIn(String owner, String id) {
    final was = _places[owner]?[id];
    final now = _latest[owner];
    if (was == null || now == null) return null;
    for (final p in now) {
      if (p.exact == was.exact) return p.id;
    }
    for (final p in now) {
      if (p.loose == was.loose) return p.id;
    }
    return null;
  }

  String _idFor(Uri url, HlsKind kind) {
    final key = '${kind.index} $url';
    final known = _ids[key];
    if (known != null) return known;
    final id = (_next++).toRadixString(36);
    _ids[key] = id;
    _links[id] = HlsLink(url, kind);
    if (kind == HlsKind.media) _dropped.add(id); // named by no version yet
    return id;
  }

  /// [media] is what [owner]'s latest version names: what it named before and no longer does is
  /// dropped, and the oldest dropped ids are forgotten past [margin].
  void _name(String owner, Set<String> media) {
    final before = _named[owner] ?? const <String>{};
    for (final id in media.difference(before)) {
      _uses[id] = (_uses[id] ?? 0) + 1;
      _dropped.remove(id);
    }
    for (final id in before.difference(media)) {
      final uses = _uses[id]! - 1;
      if (uses > 0) {
        _uses[id] = uses;
      } else {
        _uses.remove(id);
        _dropped.add(id);
      }
    }
    _named[owner] = media;
    while (_dropped.length > margin) {
      final id = _dropped.first;
      _dropped.remove(id);
      final link = _links.remove(id)!;
      _ids.remove('${link.kind.index} ${link.url}');
    }
  }
}

/// A playlist [id] another one named, under its tag ([exact]) and among the tags of its name ([loose]).
typedef _Place = ({String id, String exact, String loose});

/// What a Cast receiver is told an HLS stream's segments are: MediaInformation's hlsSegmentFormat
/// ([segment], its audio's: ts, fmp4, aac...) and hlsVideoSegmentFormat ([video]: mpeg2_ts, fmp4;
/// none for audio alone). Without them a receiver takes Transport Stream.
class HlsFormat {
  const HlsFormat(this.segment, [this.video]);

  final String segment;
  final String? video;

  static const ts = HlsFormat('ts', 'mpeg2_ts');
  static const fmp4 = HlsFormat('fmp4', 'fmp4');

  @override
  bool operator ==(Object other) => other is HlsFormat && other.segment == segment && other.video == video;

  @override
  int get hashCode => Object.hash(segment, video);

  @override
  String toString() => 'HlsFormat($segment, $video)';
}

/// Packed audio segments, by extension, as the receiver names their format.
const _packedAudio = {'aac': 'aac', 'adts': 'aac', 'mp3': 'mp3', 'ac3': 'ac3', 'ec3': 'e_ac3', 'eac3': 'e_ac3'};

/// The format of media playlist [text]'s segments: fMP4 (CMAF) with an init section (EXT-X-MAP) or
/// .m4s/.mp4/.cmf* segments, packed audio for .aac, .mp3, .ac3 or .ec3 ones, else Transport Stream.
HlsFormat hlsFormatOf(String text) {
  for (final raw in const LineSplitter().convert(_withoutBom(text))) {
    final line = raw.trim();
    if (line.startsWith('#EXT-X-MAP')) return HlsFormat.fmp4;
    if (line.isEmpty || line.startsWith('#')) continue;
    // The first segment says it
    final path = Uri.tryParse(line)?.path ?? line;
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    if (ext == 'm4s' || ext == 'mp4' || ext == 'm4v' || ext.startsWith('cmf')) return HlsFormat.fmp4;
    final audio = _packedAudio[ext];
    return audio == null ? HlsFormat.ts : HlsFormat(audio);
  }
  return HlsFormat.ts;
}

/// The playlists of master playlist [text], fetched from [base], that say its format: its first
/// variant and, when its audio comes apart, that audio's rendition (the group's default, else its
/// first). Null [variant] when [text] is a media playlist.
({Uri? variant, Uri? audio}) hlsFirstVariant(String text, Uri base) {
  final lines = [for (final l in const LineSplitter().convert(_withoutBom(text))) l.trim()];
  String? group;
  Uri? variant;
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
    for (var j = i + 1; j < lines.length; j++) {
      if (lines[j].isEmpty || lines[j].startsWith('#')) continue;
      variant = _resolve(base, lines[j]);
      break;
    }
    group = _attribute(lines[i], 'AUDIO');
    break;
  }
  if (variant == null) return (variant: null, audio: null);
  Uri? first, preferred;
  for (final line in lines) {
    if (!line.startsWith('#EXT-X-MEDIA:') || _attribute(line, 'TYPE') != 'AUDIO') continue;
    if (group == null || _attribute(line, 'GROUP-ID') != group) continue;
    final at = _uriAttribute(line);
    final url = at == null ? null : _resolve(base, line.substring(at.value, at.end));
    if (url == null) continue; // muxed in the variant
    first ??= url;
    if (_attribute(line, 'DEFAULT') == 'YES') preferred ??= url;
  }
  return (variant: variant, audio: preferred ?? first);
}

/// The value of [name] in tag [line]'s attribute list, its quotes taken off; null without it.
String? _attribute(String line, String name) {
  final m = RegExp('[:,]${RegExp.escape(name)}=("[^"]*"|[^,]*)').firstMatch(line);
  if (m == null) return null;
  final v = m[1]!;
  return v.startsWith('"') && v.endsWith('"') && v.length >= 2 ? v.substring(1, v.length - 1) : v;
}

/// Whether [text] is an HLS playlist (a BOM and leading blank lines allowed).
bool isHls(String text) => _withoutBom(text).trimLeft().startsWith('#EXTM3U');

/// [text], a master or media playlist fetched from [base] (its address after redirects), with every
/// address in it, the URI lines and the URI="…" attributes, replaced by what [link] gives for it,
/// resolved against [base]. [link] is also told the tag that named a playlist: the EXT-X-STREAM-INF
/// line before a variant, or the tag a URI attribute is in, the attribute left out ('' for a URI
/// line of media). Addresses that are not http(s), like data: keys, stay as they are.
/// Content steering is dropped: it would send the player to the provider on its own.
/// Throws [FormatException] when [text] is no playlist.
String rewriteHls(String text, Uri base, String Function(Uri url, HlsKind kind, String tag) link) {
  if (!isHls(text)) throw const FormatException('Not an HLS playlist');
  final out = StringBuffer();
  String? variant; // the last tag was EXT-X-STREAM-INF: the next address is a playlist
  for (final raw in const LineSplitter().convert(_withoutBom(text))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      if (line.startsWith('#EXT-X-CONTENT-STEERING')) continue;
      if (line.startsWith('#EXT-X-STREAM-INF')) variant = line;
      out.writeln(line.startsWith('#EXT-X-') ? _rewriteUri(line, base, link) : line);
      continue;
    }
    final url = _resolve(base, line);
    out.writeln(url == null ? line : link(url, variant == null ? HlsKind.media : HlsKind.playlist, variant ?? ''));
    variant = null;
  }
  return out.toString();
}

String _withoutBom(String text) => text.startsWith('﻿') ? text.substring(1) : text;

/// Tags whose URI attribute names another playlist; any other URI attribute names media.
const _playlistTags = {'EXT-X-MEDIA', 'EXT-X-I-FRAME-STREAM-INF', 'EXT-X-RENDITION-REPORT'};

/// [line], a tag, with the address in its URI attribute replaced.
String _rewriteUri(String line, Uri base, String Function(Uri url, HlsKind kind, String tag) link) {
  final at = _uriAttribute(line);
  final url = at == null ? null : _resolve(base, line.substring(at.value, at.end));
  if (at == null || url == null) return line;
  final kind = _playlistTags.contains(line.substring(1, line.indexOf(':'))) ? HlsKind.playlist : HlsKind.media;
  var (from, to) = (at.start, at.end + 1); // the attribute, and a comma beside it
  if (to < line.length && line[to] == ',') {
    to++;
  } else if (line[from - 1] == ',') {
    from--;
  }
  final tag = line.replaceRange(from, to, '');
  return line.replaceRange(at.value, at.end, link(url, kind, tag));
}

/// Where [line]'s URI attribute is: it [start]s there, its quoted value runs from [value] to [end].
/// The attribute list is walked as the spec writes it (NAME=value, quoted values may hold commas),
/// so a URI="…" inside another attribute's quoted value is not taken for one.
({int start, int value, int end})? _uriAttribute(String line) {
  final colon = line.indexOf(':');
  if (colon < 0) return null;
  var i = colon + 1;
  while (i < line.length) {
    final eq = line.indexOf('=', i);
    if (eq < 0) return null;
    final name = line.substring(i, eq).trim();
    var end = eq + 1;
    final quoted = end < line.length && line[end] == '"';
    if (quoted) {
      final close = line.indexOf('"', end + 1);
      if (close < 0) return null;
      end = close + 1;
    } else {
      final comma = line.indexOf(',', end);
      end = comma < 0 ? line.length : comma;
    }
    if (name == 'URI' && quoted) return (start: i, value: eq + 2, end: end - 1);
    i = end < line.length && line[end] == ',' ? end + 1 : end;
  }
  return null;
}

/// [ref] resolved against [base], or null when it is not an http(s) address.
Uri? _resolve(Uri base, String ref) {
  final Uri url;
  try {
    url = base.resolve(ref.trim());
  } on FormatException {
    return null;
  }
  return url.isScheme('http') || url.isScheme('https') ? url : null;
}
