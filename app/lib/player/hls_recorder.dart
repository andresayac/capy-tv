import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../data/off_thread.dart';
import '../data/provider_client.dart';
import 'background_recorder.dart';

/// Why an HLS channel cannot be recorded: it could not be had; it is encrypted other than the
/// plain way (AES-128 with a key anyone playing it is given); its pieces are fragmented MP4, not
/// MPEG-TS; or its sound comes apart from the picture, which pieces put one after another cannot
/// join.
enum HlsProblem { unreachable, encrypted, fragmented, separateAudio }

/// Recording an HLS channel was refused, and why.
class HlsRefused implements Exception {
  const HlsRefused(this.problem);

  final HlsProblem problem;

  @override
  String toString() => 'HlsRefused(${problem.name})';
}

/// The attributes of an HLS tag (NAME=value,NAME="value, with commas"), quotes taken off.
Map<String, String> hlsAttributes(String list) => {
  for (final m in RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)').allMatches(list))
    m[1]!: m[2]!.length >= 2 && m[2]!.startsWith('"') && m[2]!.endsWith('"')
        ? m[2]!.substring(1, m[2]!.length - 1)
        : m[2]!.trim(),
};

/// A tag's name and what follows its colon.
(String, String) _tag(String line) {
  final colon = line.indexOf(':');
  return colon < 0 ? (line, '') : (line.substring(0, colon), line.substring(colon + 1));
}

/// One of the qualities a master playlist offers.
class HlsVariant {
  const HlsVariant(this.uri, {this.bandwidth, this.separateAudio = false});

  final Uri uri;
  final int? bandwidth;

  /// Its sound is a playlist of its own (EXT-X-MEDIA with a URI, none in the variant).
  final bool separateAudio;
}

/// A master playlist: the variants of a channel, each a media playlist.
class HlsMaster {
  const HlsMaster(this.variants);

  final List<HlsVariant> variants;

  /// Past this, a recording takes over 10 GB an hour: no variant above it is picked by itself.
  static const maxBandwidth = 25000000;

  /// [text] read as a master playlist found at [base]; null when it is not one.
  static HlsMaster? parse(String text, Uri base) {
    final found = <(Uri, Map<String, String>)>[];
    final apart = <String, bool>{}; // audio group: every rendition in it has a URI of its own
    Map<String, String>? pending;
    for (final raw in LineSplitter.split(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final (tag, value) = _tag(line);
      if (tag == '#EXT-X-STREAM-INF') {
        pending = hlsAttributes(value);
      } else if (tag == '#EXT-X-MEDIA') {
        final a = hlsAttributes(value);
        final group = a['GROUP-ID'];
        if (a['TYPE'] == 'AUDIO' && group != null) apart[group] = (apart[group] ?? true) && a.containsKey('URI');
      } else if (!line.startsWith('#') && pending != null) {
        found.add((base.resolve(line), pending));
        pending = null;
      }
    }
    if (found.isEmpty) return null;
    return HlsMaster([
      for (final (uri, a) in found)
        HlsVariant(uri, bandwidth: int.tryParse(a['BANDWIDTH'] ?? ''), separateAudio: apart[a['AUDIO']] ?? false),
    ]);
  }

  /// The variant to record: the one the player plays, when it says ([bandwidth]); else the best one
  /// up to [maxBandwidth]; else the first.
  static HlsVariant pick(List<HlsVariant> variants, {int? bandwidth}) {
    if (bandwidth != null) {
      for (final v in variants) {
        if (v.bandwidth == bandwidth) return v;
      }
    }
    HlsVariant? best;
    for (final v in variants) {
      final b = v.bandwidth;
      if (b == null || b > maxBandwidth) continue;
      if (best == null || b > best.bandwidth!) best = v;
    }
    return best ?? variants.first;
  }
}

/// How a piece is encrypted (EXT-X-KEY).
class HlsKey {
  const HlsKey(this.method, {this.uri, this.iv, this.format});

  final String method;
  final Uri? uri;
  final Uint8List? iv;
  final String? format;

  /// AES-128 with the key at [uri], as anyone playing it gets it: what is decrypted here. Others
  /// (SAMPLE-AES, a DRM's key format) are refused.
  bool get plain => method == 'AES-128' && uri != null && (format == null || format == 'identity');

  /// Null for METHOD=NONE.
  static HlsKey? parse(String attributes, Uri base) {
    final a = hlsAttributes(attributes);
    final method = (a['METHOD'] ?? 'NONE').toUpperCase();
    if (method == 'NONE') return null;
    Uint8List? iv;
    final hex = a['IV']?.toLowerCase();
    if (hex != null && hex.startsWith('0x') && hex.length > 2 && hex.length <= 34) {
      final digits = hex.substring(2).padLeft(32, '0');
      final bytes = [for (var i = 0; i < 32; i += 2) int.tryParse(digits.substring(i, i + 2), radix: 16)];
      if (!bytes.contains(null)) iv = Uint8List.fromList(bytes.cast<int>());
    }
    return HlsKey(method, uri: a['URI'] == null ? null : base.resolve(a['URI']!), iv: iv, format: a['KEYFORMAT']);
  }

  /// The IV for the piece numbered [sequence]: its own, else the number itself, big-endian.
  Uint8List ivFor(int sequence) {
    if (iv case final own?) return own;
    final out = Uint8List(16);
    for (var i = 15, n = sequence; i >= 8 && n > 0; i--, n >>= 8) {
      out[i] = n & 0xff;
    }
    return out;
  }
}

/// A piece of a media playlist, with its number (EXT-X-MEDIA-SEQUENCE onwards).
class HlsSegment {
  const HlsSegment(this.sequence, this.uri, {this.duration = 0, this.key, this.range});

  final int sequence;
  final Uri uri;
  final double duration;
  final HlsKey? key;

  /// Part of [uri] only (EXT-X-BYTERANGE): from where, and how many bytes.
  final (int, int)? range;
}

/// A media playlist: the pieces there are now.
class HlsMedia {
  const HlsMedia(
    this.segments, {
    this.targetDuration = 6,
    this.ended = false,
    this.fragmented = false,
    this.timed = true,
  });

  final List<HlsSegment> segments;
  final int targetDuration; // seconds
  final bool ended; // EXT-X-ENDLIST: no more pieces come
  final bool fragmented; // EXT-X-MAP: fragmented MP4

  /// It says its target duration, as HLS must: a plain M3U list of streams (an endless one each)
  /// does not.
  final bool timed;

  /// How far from a live playlist's end players join it, in pieces (as FFmpeg's does).
  static const liveEdge = 3;

  static HlsMedia parse(String text, Uri base) {
    var target = 6, sequence = 0, ended = false, fragmented = false, timed = false;
    final segments = <HlsSegment>[];
    double? duration;
    HlsKey? key;
    var keyOpen = false; // key tags since the last piece: one for each key format
    String? range;
    final ends = <Uri, int>{}; // where the last range of each address ended
    for (final raw in LineSplitter.split(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        final (tag, value) = _tag(line);
        switch (tag) {
          case '#EXT-X-TARGETDURATION':
            final seconds = double.tryParse(value.trim());
            timed = seconds != null;
            target = seconds?.ceil() ?? target;
          case '#EXT-X-MEDIA-SEQUENCE':
            sequence = int.tryParse(value.trim()) ?? sequence;
          case '#EXT-X-ENDLIST':
            ended = true;
          case '#EXT-X-MAP':
            fragmented = true;
          case '#EXTINF':
            duration = double.tryParse(value.split(',').first.trim());
          case '#EXT-X-BYTERANGE':
            range = value;
          case '#EXT-X-KEY':
            final k = HlsKey.parse(value, base);
            // Several for the same pieces (one per key format): the one decrypted here wins
            if (!keyOpen || key == null || (k != null && k.plain && !key.plain)) key = k;
            keyOpen = true;
        }
        continue;
      }
      final uri = base.resolve(line);
      (int, int)? part;
      if (range != null) {
        final at = range.split('@');
        final length = int.tryParse(at.first.trim());
        final offset = at.length > 1 ? int.tryParse(at[1].trim()) : ends[uri] ?? 0;
        if (length != null && offset != null) {
          part = (offset, length);
          ends[uri] = offset + length;
        }
      }
      segments.add(HlsSegment(sequence + segments.length, uri, duration: duration ?? 0, key: key, range: part));
      duration = null;
      keyOpen = false;
      range = null;
    }
    return HlsMedia(segments, targetDuration: target, ended: ended, fragmented: fragmented, timed: timed);
  }

  /// Where a recording starts: in a live playlist [liveEdge] pieces from its end, where players join
  /// it; in a complete one (played from its start) at [position], where the player is.
  int startIndex({Duration? position}) {
    if (segments.isEmpty) return 0;
    if (!ended) return math.max(0, segments.length - liveEdge);
    final at = (position?.inMilliseconds ?? 0) / 1000;
    var end = 0.0;
    for (var i = 0; i < segments.length; i++) {
      end += segments[i].duration;
      if (end > at) return i;
    }
    return segments.length - 1;
  }
}

/// Records a live HLS channel while the player plays it: HLS comes as a playlist of short pieces
/// (MPEG-TS segments) that players fetch one by one, so this fetches the same ones the player does
/// and writes them, in order, one after another into a file, which is then one MPEG-TS stream.
///
/// The media playlist is read again about every target duration, from where it was found the first
/// time (after redirects); only once it failed a few times in a row is it asked for from the
/// channel's address again, which a provider may count as one more session. Each piece is written
/// once, by its number. One not had is tried again on the next reads while it is still listed (an
/// edge may list a piece a moment before it has it), then given up; pieces that went by meanwhile
/// (a long stall) are a gap. Both are counted in [missed]. Cookies the provider sets go back to it,
/// as players send them. Pieces encrypted with AES-128 are decrypted; other encryption, and
/// fragmented MP4, are refused.
class HlsRecorder {
  HlsRecorder._(
    this.source,
    this.file,
    this._headers,
    this._bandwidth,
    this._onUnusable,
    this._onWriteError,
    this._onEnded,
  );

  /// The channel's own address.
  final Uri source;
  final File file;
  final Map<String, String> _headers;
  int? _bandwidth; // the variant's, once picked
  final void Function(HlsProblem problem)? _onUnusable;
  final void Function(Object error)? _onWriteError;
  final void Function()? _onEnded;
  // mpv's user agent, unless the playlist says otherwise: some providers refuse Dart's own
  final _client = providerHttpClient(userAgent: 'libmpv');

  /// How fast the clock runs: tests make the waits shorter.
  @visibleForTesting
  static var pace = 1.0;

  /// A provider that sends nothing for this long is given up on, for this request.
  static const _idle = Duration(seconds: 20);
  static const _playlistCap = 8 << 20, _segmentCap = 160 << 20;

  /// Reads of the playlist a piece not had is tried again on, while it is listed, before it is
  /// given up.
  static const _holdReads = 4;

  /// Reads of the media playlist in a row that may fail before it is asked for from the channel's
  /// address again.
  static const _playlistTries = 3;

  Uri? _media; // the media playlist, where it was found
  String? _server; // the host that numbered the pieces
  var _moved = false; // the media playlist is another host's now, numbered its own way
  int? _next; // the number of the next piece to write
  var _held = 0; // reads of the playlist the piece [_next] was not had on
  var _failed = 0; // reads of the media playlist in a row that failed
  var _barren = 0; // reads of the playlist since a piece was last written
  final _quiet = Stopwatch(); // since a piece was last written
  final _read = Stopwatch(); // since the playlist was last read
  var _missed = 0, _written = 0;
  final _keys = <Uri, Uint8List>{};
  final _cookies = <String, _Cookie>{};
  late final IOSink _out;
  var _writable = true;
  var _stopped = false;
  Completer<void>? _nap;
  late final Future<void> _done;

  /// Pieces lost: gone by before they could be fetched, or not had while they were listed.
  int get missed => _missed;

  /// Pieces written.
  int get written => _written;

  /// Starts recording [url] into [file] (after what it has), asked for with [headers]. [bandwidth]
  /// is that of the variant the player plays, when known; [position] where the player is, for a
  /// playlist that is complete. The first piece is had before this returns: refused with
  /// [HlsRefused] when the channel cannot be recorded, also when that piece cannot be had. Later:
  /// a channel that turns into one that cannot be recorded, or gives no piece for a long while,
  /// ends the recording, said through [onUnusable]; a file that cannot be written (no room left)
  /// ends it too, said once through [onWriteError]; and a playlist that ends (EXT-X-ENDLIST), once
  /// written to its end, ends it, said through [onEnded].
  static Future<HlsRecorder> start(
    String url,
    File file, {
    Map<String, String> headers = const {},
    int? bandwidth,
    Duration? position,
    void Function(HlsProblem problem)? onUnusable,
    void Function(Object error)? onWriteError,
    void Function()? onEnded,
  }) async {
    final rec = HlsRecorder._(Uri.parse(url), file, headers, bandwidth, onUnusable, onWriteError, onEnded);
    final HlsMedia first;
    final Uint8List piece;
    try {
      first = await rec._playlist();
      rec._read.start();
      if (first.segments.isEmpty) throw const FormatException('No pieces');
      final from = first.segments[first.startIndex(position: position)];
      if (_problem(first, from.sequence) case final problem?) throw HlsRefused(problem);
      // Had before the recording begins: a piece the provider does not give this way (a cookie it
      // wants, a key it keeps, a second session it refuses) is said now, not with an empty file at
      // the end
      piece = await rec._segment(from, first.targetDuration) ?? (throw const HlsRefused(HlsProblem.unreachable));
      rec._next = from.sequence + 1;
    } on Object catch (e) {
      rec._client.close(force: true);
      throw e is HlsRefused ? e : const HlsRefused(HlsProblem.unreachable);
    }
    rec._open();
    rec._write(piece);
    rec._done = rec._run(first);
    return rec;
  }

  /// Ends the recording: a piece in hand is written whole, one still coming is let go, and the file
  /// is closed.
  Future<void> stop() {
    _halt();
    return _done;
  }

  void _halt() {
    _stopped = true;
    if (_nap case final nap? when !nap.isCompleted) nap.complete();
    _client.close(force: true); // what is under way ends now
  }

  /// Ends the recording from within, and says why with [say].
  void _end(void Function()? say) {
    if (_stopped) return;
    _stopped = true;
    say?.call();
  }

  void _open() {
    final out = _out = file.openWrite(mode: FileMode.append);
    out.done.catchError((Object e) {
      if (!_writable) return;
      _writable = false;
      if (_stopped) return; // ended already
      _onWriteError?.call(e);
      _halt(); // nothing more can be kept
    });
    // Opens the file now: one that cannot be opened is said like any write that fails
    out.add(const <int>[]);
    _quiet.start();
  }

  /// No piece for this long, though asked for again and again: the provider does not give them
  /// this way any more.
  Duration _silence(int target) => Duration(milliseconds: (math.max(60, 6 * target) * 1000 * pace).round());

  Future<void> _run(HlsMedia first) async {
    HlsMedia? playlist = first;
    var target = first.targetDuration;
    try {
      while (!_stopped) {
        final poll = Stopwatch()..start(); // not the wall clock, which may be set back meanwhile
        var fresh = false;
        try {
          playlist ??= await _playlist();
          _failed = 0;
          target = playlist.targetDuration;
          final since = _read.elapsed;
          _read.reset();
          fresh = await _follow(playlist, since);
          final segments = playlist.segments;
          if (playlist.ended && !_stopped && (segments.isEmpty || (_next ?? 0) > segments.last.sequence)) {
            _end(_onEnded); // written to its end: complete
            return;
          }
        } on HlsRefused catch (e) {
          _end(() => _onUnusable?.call(e.problem));
          return;
        } on Object {
          // The playlist could not be had: again from where it was; after a few times from the
          // channel's address, as at first (an address it was sent on to may have run out)
          if (!_stopped && ++_failed >= _playlistTries) {
            _failed = 0;
            _media = null;
          }
        }
        playlist = null;
        if (_stopped) break;
        // Said, rather than a recording that goes on empty while the player plays
        if (++_barren >= 3 && _quiet.elapsed > _silence(target)) {
          _end(() => _onUnusable?.call(HlsProblem.unreachable));
          return;
        }
        // A playlist that did not change is asked for again sooner
        final every = target.clamp(1, 30) * (fresh ? 1000 : 500) * pace;
        final wait = Duration(milliseconds: every.round()) - poll.elapsed;
        await _sleep(wait > Duration.zero ? wait : Duration.zero);
      }
    } finally {
      _client.close(force: true);
      try {
        await _out.close(); // not flush(): on a sink that failed it would wait forever
      } on Object {
        // Said when it failed
      }
    }
  }

  /// Writes the pieces of [playlist] not written yet, read [since] the last time; whether there
  /// were any.
  Future<bool> _follow(HlsMedia playlist, Duration since) async {
    final segments = playlist.segments;
    if (segments.isEmpty) return false;
    final first = segments.first.sequence, last = segments.last.sequence;
    // About how many pieces could have come meanwhile
    final came = since.inMilliseconds / (playlist.targetDuration.clamp(1, 30) * 1000 * pace);
    final moved = _moved;
    _moved = false;
    var next = _next;
    if (next == null ||
        (moved && !playlist.ended) ||
        last < next - 1 - segments.length ||
        first - next > 2 * came + segments.length + HlsMedia.liveEdge) {
      // The first pieces; another host's, numbered its own way; or a stream that started over, or
      // was numbered anew far ahead: from its live end, as at first
      next = segments[playlist.startIndex()].sequence;
      _held = 0;
    } else if (first > next) {
      _missed += first - next; // gone by while it stalled: a gap
      next = first;
      _held = 0;
    }
    _next = next;
    if (_problem(playlist, next) case final problem?) throw HlsRefused(problem);
    var fresh = false;
    for (final s in segments) {
      if (_stopped) break;
      if (s.sequence < next) continue;
      fresh = true;
      final bytes = await _segment(s, playlist.targetDuration);
      if (bytes != null) {
        _write(bytes);
      } else if (_stopped) {
        break; // let go, not lost
      } else if (++_held < _holdReads && !playlist.ended) {
        break; // still listed: again on the next read, before the ones after it
      } else {
        _missed++; // given up
      }
      _held = 0;
      _next = s.sequence + 1;
    }
    return fresh;
  }

  /// What keeps the pieces from [from] on out of a recording.
  static HlsProblem? _problem(HlsMedia playlist, int from) {
    if (playlist.fragmented) return HlsProblem.fragmented;
    for (final s in playlist.segments) {
      if (s.sequence >= from && s.key != null && !s.key!.plain) return HlsProblem.encrypted;
    }
    return null;
  }

  void _write(Uint8List bytes) {
    if (!_writable) return;
    try {
      _out.add(bytes);
      _written++;
      _barren = 0;
      _quiet.reset();
    } on Object catch (e) {
      // A sink that failed: said once, here or through done
      if (!_writable) return;
      _writable = false;
      _onWriteError?.call(e);
      _halt();
    }
  }

  Future<void> _sleep(Duration d) {
    final nap = _nap = Completer<void>();
    final timer = Timer(d, () => nap.isCompleted ? null : nap.complete());
    if (_stopped) nap.complete();
    return nap.future.whenComplete(timer.cancel);
  }

  /// The media playlist as it is now: from where it was found, or from the channel's address
  /// (through its master playlist, if it has one).
  Future<HlsMedia> _playlist() async {
    final known = _media;
    var (at, text) = await _text(known ?? source);
    if (known == null) {
      if (HlsMaster.parse(text, at) case final master?) {
        final variant = HlsMaster.pick(master.variants, bandwidth: _bandwidth);
        if (variant.separateAudio) throw const HlsRefused(HlsProblem.separateAudio);
        _bandwidth = variant.bandwidth;
        (at, text) = await _text(variant.uri);
      }
    }
    final media = HlsMedia.parse(text, at);
    // A plain M3U list, its streams endless ones: no HLS to follow
    if (!media.timed) throw const FormatException('Not HLS');
    _media = at;
    if (_server != null && _server != at.authority) _moved = true;
    _server = at.authority;
    return media;
  }

  /// A playlist: where it was found (after redirects), and what it says.
  Future<(Uri, String)> _text(Uri uri) async {
    final (at, bytes) = await _fetch(uri, cap: _playlistCap, playlist: true);
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!text.replaceFirst('\uFEFF', '').trimLeft().startsWith('#EXTM3U')) throw const FormatException('Not HLS');
    return (at, text);
  }

  /// A piece's bytes, decrypted; null when it could not be had after a few tries. [target] is the
  /// playlist's target duration.
  Future<Uint8List?> _segment(HlsSegment s, int target) async {
    // Far more than its time would make, even at a high bitrate (80 Mb/s): no piece, but an endless
    // stream listed as one
    final seconds = s.duration > 0 ? s.duration : target.toDouble();
    final cap = (seconds * (10 << 20)).round().clamp(16 << 20, _segmentCap);
    for (var attempt = 0; attempt < 3 && !_stopped; attempt++) {
      if (attempt > 0) await _sleep(Duration(milliseconds: (500 * pace).round()));
      if (_stopped) break;
      try {
        final (_, bytes) = await _fetch(s.uri, cap: cap, range: s.range);
        final key = s.key;
        if (key == null) return bytes;
        return await _decrypt(bytes, await _key(key.uri!), key.ivFor(s.sequence));
      } on Object {
        // Again, a moment later
      }
    }
    return null;
  }

  Future<Uint8List> _key(Uri uri) async {
    if (_keys[uri] case final key?) return key;
    final (_, bytes) = await _fetch(uri, cap: 64);
    if (bytes.length != 16) throw const FormatException('Not an AES-128 key');
    return _keys[uri] = bytes;
  }

  /// AES-128-CBC with PKCS#7 padding, as HLS has it; away from the screen's isolate, which a piece
  /// of a few megabytes would hold up.
  static Future<Uint8List> _decrypt(Uint8List data, Uint8List key, Uint8List iv) => runOffThread(() async {
    final clear = await AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty).decrypt(
      SecretBox(data, nonce: iv, mac: Mac.empty),
      secretKey: SecretKey(key),
    );
    return clear is Uint8List ? clear : Uint8List.fromList(clear);
  });

  /// [uri]'s bytes (only [range] of them, if given), and where it was found after redirects.
  /// [playlist]: given up at once if it does not start as one (an endless stream instead).
  Future<(Uri, Uint8List)> _fetch(Uri uri, {required int cap, (int, int)? range, bool playlist = false}) async {
    var at = uri;
    HttpClientResponse response;
    for (var hops = 0; ; hops++) {
      final request = await _client.getUrl(at);
      // Redirects followed here: HttpClient's own would not send the headers on, and a provider may
      // want them where it sends to as well
      request.followRedirects = false;
      _headers.forEach(request.headers.set);
      if (_cookiesFor(at) case final mine when mine.isNotEmpty) {
        final own = request.headers.value(HttpHeaders.cookieHeader);
        request.headers.set(HttpHeaders.cookieHeader, own == null || own.isEmpty ? mine : '$own; $mine');
      }
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, 'bytes=${range.$1}-${range.$1 + range.$2 - 1}');
      try {
        response = await request.close().timeout(_idle);
      } on TimeoutException {
        request.abort();
        rethrow;
      }
      _keepCookies(response.headers, at);
      final location = response.headers.value(HttpHeaders.locationHeader);
      final next = response.isRedirect && location != null && hops < 5 ? at.resolve(location) : null;
      if (next == null && response.statusCode < 300) break;
      unawaited(_quietly(() async => (await response.detachSocket()).destroy())); // let go of the provider
      if (next == null) throw HttpException('HTTP ${response.statusCode}', uri: at);
      at = next;
    }
    final body = BytesBuilder(copy: false);
    final head = <int>[];
    await for (final chunk in response.timeout(_idle)) {
      body.add(chunk);
      if (body.length > cap) throw HttpException('Too long', uri: uri);
      if (playlist && head.length < 16) {
        head.addAll(chunk.take(16 - head.length));
        final start = latin1.decode(head).replaceFirst('\u00EF\u00BB\u00BF', '').trimLeft();
        if (start.length >= 7 && !start.startsWith('#EXTM3U')) throw const FormatException('Not HLS');
      }
    }
    var bytes = body.takeBytes();
    // A provider that sent it all rather than the part asked for
    if (range != null && response.statusCode == HttpStatus.ok && bytes.length >= range.$1 + range.$2) {
      bytes = Uint8List.sublistView(bytes, range.$1, range.$1 + range.$2);
    }
    return (at, bytes);
  }

  /// Keeps the cookies [headers] set, as players do: FFmpeg's HLS sends those its playlist got with
  /// the pieces, and a provider may let only those in.
  void _keepCookies(HttpHeaders headers, Uri at) {
    final host = at.host.toLowerCase();
    for (final line in headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      final parts = line.split(';');
      final eq = parts.first.indexOf('=');
      if (eq <= 0) continue;
      String? domain;
      var path = '/';
      int? maxAge;
      DateTime? expires;
      for (final part in parts.skip(1)) {
        final i = part.indexOf('=');
        final value = i < 0 ? '' : part.substring(i + 1).trim();
        switch ((i < 0 ? part : part.substring(0, i)).trim().toLowerCase()) {
          case 'domain' when value.isNotEmpty:
            domain = value.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
          case 'path' when value.startsWith('/'):
            path = value;
          case 'max-age':
            maxAge = int.tryParse(value);
          case 'expires':
            try {
              expires = HttpDate.parse(value);
            } on Object {
              // A date it cannot read: kept
            }
        }
      }
      if (domain != null && host != domain && !host.endsWith('.$domain')) continue; // not this host's to set
      final name = parts.first.substring(0, eq).trim();
      final cookie = _Cookie(
        name,
        parts.first.substring(eq + 1).trim(),
        domain ?? host,
        path,
        hostOnly: domain == null,
      );
      final id = '${cookie.domain} ${cookie.path} $name';
      final gone = maxAge != null ? maxAge <= 0 : expires?.isBefore(DateTime.now()) ?? false;
      if (gone) {
        _cookies.remove(id);
      } else {
        _cookies[id] = cookie;
      }
    }
  }

  /// The cookies to send to [uri], as a Cookie header has them.
  String _cookiesFor(Uri uri) => [
    for (final c in _cookies.values)
      if (c.sentTo(uri)) '${c.name}=${c.value}',
  ].join('; ');
}

/// A cookie a provider set: sent back to the host it came from (or, given, to its domain), under
/// its path.
class _Cookie {
  const _Cookie(this.name, this.value, this.domain, this.path, {required this.hostOnly});

  final String name, value, domain, path;
  final bool hostOnly;

  bool sentTo(Uri uri) {
    final host = uri.host.toLowerCase();
    return (host == domain || !hostOnly && host.endsWith('.$domain')) &&
        (uri.path.isEmpty ? '/' : uri.path).startsWith(path);
  }
}

Future<void> _quietly(Future<void> Function() f) async {
  try {
    await f();
  } on Object {
    // The other end is gone
  }
}

/// An [HlsRecorder] for a recording scheduled from the guide ([hlsRecorder]): no player to follow,
/// so the highest variant, from the live end. Throws [HlsRefused] for a channel it cannot record.
Future<ChannelRecorder> startHlsChannelRecorder(
  String url,
  File file, {
  Map<String, String> headers = const {},
  void Function(Object error)? onWriteError,
}) async {
  final done = Completer<RecorderEnd>();
  late final HlsRecorder rec;
  void end(RecorderEnd how) => done.isCompleted ? null : done.complete(how);
  rec = await HlsRecorder.start(
    url,
    file,
    headers: headers,
    // What came is kept, the file closed first. No pieces for a long while: asked for again by the
    // scheduler; a channel that cannot be recorded any more: not
    onUnusable: (problem) => rec.stop().whenComplete(
      () => end(problem == HlsProblem.unreachable ? RecorderEnd.dropped : RecorderEnd.refused),
    ),
    onWriteError: (e) {
      onWriteError?.call(e);
      end(RecorderEnd.writeFailed);
    },
    onEnded: () => rec.stop().whenComplete(() => end(RecorderEnd.finished)),
  );
  return _HlsChannelRecorder(rec, file, done);
}

class _HlsChannelRecorder implements ChannelRecorder {
  _HlsChannelRecorder(this._rec, this._file, this._done);

  final HlsRecorder _rec;
  final File _file;
  final Completer<RecorderEnd> _done;

  @override
  int get bytes => _file.existsSync() ? _file.lengthSync() : 0;

  @override
  Future<RecorderEnd> get done => _done.future;

  @override
  Future<void> stop() async {
    await _rec.stop();
    if (!_done.isCompleted) _done.complete(RecorderEnd.stopped);
  }
}
