import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../device.dart' show lowMemory;
import 'app_language.dart';
import 'matching.dart' show fold;
import 'models.dart';
import 'off_thread.dart';
import 'provider_http.dart';
import 'source.dart';

/// TV guide parsed from XMLTV: programmes per channel id, sorted by start time.
/// A channel's guide id in a combined list's provider [part]: one that is only a number is that
/// provider's own, and is told apart from another's ("1~101"); one in words is shared.
String? partEpgId(int part, String? id) =>
    id == null || !RegExp(r'^\s*\d+\s*$').hasMatch(id) ? id : '$part~${id.trim()}';

/// The channels of a playlist, as its guide is read: only their programmes are kept (a guide carries
/// thousands of channels a list may not have, which a TV stick has no memory for); one whose id the
/// guide does not have is matched by name with the guide's own names for its channels; and a
/// channel's times may be moved ([shifts], M3U's tvg-shift, by the guide id the playlist uses).
class GuideChannels {
  GuideChannels({
    required Iterable<String> ids,
    Map<String, Iterable<String>> names = const {},
    Map<String, Duration> shifts = const {},
    Iterable<String> archive = const [],
  }) : ids = {for (final id in ids) EpgGuide._key(id)},
       names = _byName(names),
       shifts = {for (final MapEntry(:key, :value) in shifts.entries) EpgGuide._key(key): value},
       archive = {for (final id in archive) EpgGuide._key(id)};

  /// Names alike once made as [guideName] makes them ("ESPN HD", "ESPN") go together.
  static Map<String, Set<String>> _byName(Map<String, Iterable<String>> names) {
    final out = <String, Set<String>>{};
    for (final MapEntry(:key, :value) in names.entries) {
      final n = guideName(key);
      if (n.isNotEmpty) (out[n] ??= {}).addAll(value.map(EpgGuide._key));
    }
    return out;
  }

  /// The guide ids the playlist's channels go by.
  final Set<String> ids;

  /// Channels by their name as [guideName] makes it: the guide ids they go by.
  final Map<String, Set<String>> names;

  /// How far each channel's times are moved, by its guide id.
  final Map<String, Duration> shifts;

  /// The channels with catch-up: their past is worth its memory.
  final Set<String> archive;
}

/// A channel's name as a guide's name for it is matched: in lowercase, without accents, marks of
/// quality (HD, FHD, 4K…) or punctuation. Only names alike in all of that match, never alike ones.
String guideName(String name) =>
    fold(name)
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .split(' ')
        .where((w) => w.isNotEmpty && !_quality.contains(w))
        .join(' ');

const _quality = {'hd', 'fhd', 'uhd', 'sd', '4k', '8k', 'hevc', 'h265', '1080p', '720p', '1080', '720', 'hq', 'lq'};

/// M3U's tvg-shift: hours, maybe with a fraction ("-5", "+1.5", "5,5"); null when it is not one.
Duration? parseTvgShift(String? raw) {
  final hours = double.tryParse((raw ?? '').trim().replaceFirst(',', '.').replaceFirst(RegExp(r'^\+'), ''));
  if (hours == null || hours.isNaN || hours.abs() > 24) return null;
  final minutes = (hours * 60).round();
  return minutes == 0 ? null : Duration(minutes: minutes);
}

class EpgGuide {
  EpgGuide(this._programmes, {this.icons = const {}, this.complete = true});

  static final empty = EpgGuide(const {});

  /// Whether the document came to its end (`</tv>`): one cut short (a download that broke off) is
  /// shown, but kept in place of a whole one never.
  final bool complete;

  /// What there is while the guide is on its way: as [empty], but a screen can tell "loading" from
  /// "this channel has no guide".
  static final loading = EpgGuide(const {});

  /// What there is when the guide could not be downloaded and no copy was kept: as [empty], but a
  /// screen can say so, and offer to try again, rather than "this channel has no guide".
  static final failed = EpgGuide(const {});

  /// [guides] as one; where two describe the same channel, the first one's.
  factory EpgGuide.merge(List<EpgGuide> guides) {
    if (guides.length == 1) return guides.single;
    if (guides.isNotEmpty && guides.every((g) => identical(g, failed))) return failed;
    final programmes = <String, List<EpgEntry>>{};
    final icons = <String, String>{};
    for (final g in guides) {
      g._programmes.forEach((k, v) => programmes.putIfAbsent(k, () => v));
      g.icons.forEach((k, v) => icons.putIfAbsent(k, () => v));
    }
    return EpgGuide(programmes, icons: icons);
  }

  /// This guide with its ids that are only a number as [part]'s own ("101" → "1~101"), as a
  /// combined list's channels say them (see [partEpgId]).
  EpgGuide numbersOf(int part) => EpgGuide(
    {for (final e in _programmes.entries) _key(partEpgId(part, e.key)!): e.value},
    icons: {for (final e in icons.entries) _key(partEpgId(part, e.key)!): e.value},
  );

  final Map<String, List<EpgEntry>> _programmes; // key: normalized channel id
  final Map<String, String> icons; // channel logos declared by the guide, by normalized id

  static String _key(String id) => id.trim().toLowerCase();

  bool get isEmpty => _programmes.isEmpty;

  /// Logo the guide declares for a channel; useful when the provider sends none.
  String? iconOf(String? channelId) => channelId == null ? null : icons[_key(channelId)];
  int get channelCount => _programmes.length;

  bool has(String? channelId) => channelId != null && (_programmes[_key(channelId)]?.isNotEmpty ?? false);

  List<EpgEntry> forChannel(String? channelId) =>
      channelId == null ? const [] : _programmes[_key(channelId)] ?? const [];

  EpgEntry? nowOn(String? channelId, [DateTime? at]) {
    final t = at ?? DateTime.now();
    return forChannel(channelId).where((e) => e.isNow(t)).firstOrNull;
  }

  /// What is on now followed by what comes next.
  List<EpgEntry> upcoming(String? channelId, {int count = 6, DateTime? at}) {
    final t = at ?? DateTime.now();
    return forChannel(channelId).where((e) => e.end.isAfter(t)).take(count).toList();
  }

  /// Programmes overlapping [from, to).
  List<EpgEntry> between(String? channelId, DateTime from, DateTime to) =>
      forChannel(channelId).where((e) => e.end.isAfter(from) && e.start.isBefore(to)).toList();
}

/// "20261105203000 -0500" → the same instant, as local time. Missing offset means UTC.
DateTime? parseXmltvTime(String raw) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?\s*([+-])?(\d{2})?:?(\d{2})?').firstMatch(raw.trim());
  if (m == null) return null;
  int n(int g) => int.parse(m[g] ?? '0');
  var utc = DateTime.utc(n(1), n(2), n(3), n(4), n(5), n(6));
  if (m[7] != null) {
    final offset = Duration(hours: n(8), minutes: n(9));
    utc = m[7] == '+' ? utc.subtract(offset) : utc.add(offset);
  }
  return utc.toLocal();
}

/// Streams through an XMLTV document keeping only programmes that overlap the window around
/// [now] (default: 3 days back, which the grid shows, 2 days ahead). Memory stays proportional to
/// the window. With [channels], only theirs are kept (see [GuideChannels]); and with [shortPast] the
/// past is that short but for channels with catch-up (a device with little memory).
/// A scanner, not an XML parser (as tizen/src/workers/xmltv.ts): guides often carry a bare "<"
/// ("A < B", "<3") or come cut off, and what is broken is skipped rather than losing the guide.
Future<EpgGuide> parseXmltv(
  Stream<String> xml, {
  DateTime? now,
  Duration past = const Duration(days: 3),
  Duration ahead = const Duration(days: 2),
  Duration? shortPast,
  String? language,
  GuideChannels? channels,
  Duration shift = Duration.zero,
}) async {
  final t = now ?? DateTime.now();
  final scanner = _XmltvScanner(
    t.subtract(past),
    t.add(ahead),
    language?.toLowerCase(),
    channels,
    shortPast == null ? null : t.subtract(shortPast),
    shift,
  );
  await for (final chunk in xml) {
    scanner.push(chunk);
  }
  scanner.push('', last: true);
  for (final list in scanner.programmes.values) {
    list.sort((a, b) => a.start.compareTo(b.start));
    // One with no stop ends where the next one starts; the last keeps its hour
    for (var i = 0; i < list.length - 1; i++) {
      final e = list[i], next = list[i + 1].start;
      if (scanner.openEnded.contains(e) && next.isAfter(e.start)) {
        list[i] = EpgEntry(title: e.title, start: e.start, end: next, description: e.description);
      }
    }
    // A guide mixing sources repeats or overlaps programmes: each once, one ending where the next
    // starts, so none is drawn over another in the grid
    final kept = <EpgEntry>[];
    for (final e in list) {
      final prev = kept.lastOrNull;
      if (prev != null && e.start.isBefore(prev.end)) {
        if (!e.start.isAfter(prev.start)) continue; // the same slot: the first stays
        kept.last = EpgEntry(title: prev.title, start: prev.start, end: e.start, description: prev.description);
      }
      kept.add(e);
    }
    list
      ..clear()
      ..addAll(kept);
  }
  return EpgGuide(scanner.programmes, icons: scanner.icons, complete: scanner.ended);
}

/// Text an element may take before it is taken as broken; real ones are a few kB.
const _longest = 1024 * 1024;

/// Fed the text as it comes, it keeps the programmes in the window and the channels' logos.
class _XmltvScanner {
  _XmltvScanner(this.from, this.to, [this.language, this.channels, this.recentFrom, this.shift = Duration.zero]);

  final DateTime from, to;

  /// The language ("es") whose title and description are taken when a programme has several.
  final String? language;

  /// The playlist's channels, when known: only theirs are kept.
  final GuideChannels? channels;

  /// Where the past starts for channels with no catch-up, when it is to be short.
  final DateTime? recentFrom;

  /// How far every programme is moved: the playlist's own setting (a guide on the wrong clock).
  final Duration shift;
  final programmes = <String, List<EpgEntry>>{};
  final icons = <String, String>{};

  /// Whether the document's end (`</tv>`) came.
  var ended = false;

  final _direct = <String>{}; // the playlist's ids the guide has as its own
  final _alias = <String, Set<String>>{}; // a guide channel's id: the playlist's ids matched to it by name
  final _matched = <String>{}; // the playlist's ids matched by name already: by the first guide channel only
  final _pool = ValuePool(); // a title said again and again (news, a film's) is kept once

  /// The programmes that came with no stop (XMLTV allows it), given an hour until the next is known.
  final openEnded = Set<EpgEntry>.identity();
  var _buf = '';

  void push(String chunk, {bool last = false}) {
    _buf += chunk;
    final done = _scan(last);
    _buf = last ? '' : _buf.substring(done);
  }

  /// Reads every complete element in the buffer; returns where the first incomplete one starts.
  int _scan(bool last) {
    final b = _buf;
    var i = 0;
    for (;;) {
      final lt = b.indexOf('<', i);
      if (lt < 0) return b.length;
      // Too little to tell what it is yet
      if (!last && b.length - lt < 12) return lt;
      for (final (open, close) in const [('<!--', '-->'), ('<![CDATA[', ']]>')]) {
        if (!b.startsWith(open, lt)) continue;
        final end = b.indexOf(close, lt + open.length);
        if (end < 0) return last ? b.length : lt;
        i = end + close.length;
        break;
      }
      if (i > lt) continue;
      final next = _element(b, lt, last);
      if (next == null) return last ? b.length : lt;
      i = next;
    }
  }

  static final _name = RegExp(r'^<(programme|channel)[\s/>]');

  /// Past the element that starts at [lt] (or past its tag when it is not one that matters, or is
  /// never closed); null if it may still be completed by what comes.
  int? _element(String b, int lt, bool last) {
    final headEnd = b.indexOf('>', lt);
    if (headEnd < 0) return null;
    final name = _name.firstMatch(b.substring(lt, lt + 12 > b.length ? b.length : lt + 12))?[1];
    if (name == null) {
      if (b.startsWith('</tv', lt)) ended = true; // the whole document came
      return headEnd + 1; // <?xml>, <tv>, </tv>, <!DOCTYPE>...
    }
    final head = b.substring(lt + name.length + 1, headEnd);
    if (head.endsWith('/')) return headEnd + 1; // nothing in it
    final close = b.indexOf('</$name', headEnd);
    // One never closed would hold back the rest of the document: past _longest, or at the end,
    // its tag is skipped and what is inside it still read
    if (close < 0) return last || b.length - lt > _longest ? headEnd + 1 : null;
    // Another one opening before this one closes: this one was never closed, and does not take
    // the next one's end for its own
    final nested = b.indexOf('<$name', headEnd);
    if (nested >= 0 && nested < close) return headEnd + 1;
    final after = b.indexOf('>', close);
    if (after < 0) return null;
    final body = _withoutComments(b.substring(headEnd + 1, close));
    if (name == 'programme') {
      _programme(' $head', body);
    } else {
      _channel(' $head', body);
    }
    return after + 1;
  }

  void _programme(String head, String body) {
    final channel = _attr(head, 'channel');
    final start = parseXmltvTime(_attr(head, 'start') ?? '');
    if (channel == null || start == null) return;
    final keys = _keysOf(EpgGuide._key(channel));
    if (keys.isEmpty) return; // a channel the playlist does not have
    final given = parseXmltvTime(_attr(head, 'stop') ?? '');
    final stop = given ?? start.add(const Duration(hours: 1));
    String? title, desc;
    var read = false;
    for (final key in keys) {
      final shift = this.shift + (channels?.shifts[key] ?? Duration.zero);
      final s = start.add(shift), e = stop.add(shift);
      final from = recentFrom != null && !(channels?.archive.contains(key) ?? false) ? recentFrom! : this.from;
      if (!e.isAfter(from) || !s.isBefore(to)) continue;
      if (!read) {
        read = true;
        title = _pool.text(_firstText(body, 'title', language));
        final d = _firstText(body, 'desc', language);
        desc = d == null || d.isEmpty ? null : d;
      }
      if (title == null) return;
      final entry = EpgEntry(title: title, start: s, end: e, description: desc);
      programmes.putIfAbsent(key, () => []).add(entry);
      if (given == null) openEnded.add(entry);
    }
  }

  /// The playlist's ids a programme of the guide's channel [key] is kept under: its own, when the
  /// playlist has it (or none is given), and those matched to it by name.
  List<String> _keysOf(String key) {
    final c = channels;
    if (c == null) return [key];
    final own = c.ids.contains(key);
    if (own) _direct.add(key);
    final named = _alias[key];
    return [
      if (own) key,
      if (named != null)
        for (final k in named)
          if (!_direct.contains(k)) k,
    ];
  }

  /// A channel of the guide: its logo (the first with an http address, past any relative or data:
  /// one before it), and, by the names the guide gives it, the playlist's channels whose ids it
  /// does not have.
  void _channel(String head, String body) {
    final id = _attr(head, 'id');
    if (id == null) return;
    final key = EpgGuide._key(id);
    final c = channels;
    final targets = <String>[if (c == null || c.ids.contains(key)) key];
    if (c != null) {
      if (c.ids.contains(key)) _direct.add(key);
      for (final name in _texts(body, 'display-name')) {
        for (final k in c.names[guideName(name)] ?? const <String>{}) {
          // Only for a channel the guide has no id for, and from the first guide channel so named
          if (k == key || c.ids.contains(k) && _direct.contains(k) || !_matched.add(k)) continue;
          (_alias[key] ??= {}).add(k);
          targets.add(k);
        }
      }
    }
    if (targets.every(icons.containsKey)) return;
    for (final m in _opening['icon']!.allMatches(body)) {
      final src = _attr(m[0]!, 'src');
      if (src != null && src.startsWith('http')) {
        for (final k in targets) {
          icons.putIfAbsent(k, () => src);
        }
        return;
      }
    }
  }
}

/// The texts of every [name] element in [body].
Iterable<String> _texts(String body, String name) sync* {
  for (final m in _opening[name]!.allMatches(body)) {
    final tag = m[0]!;
    if (tag[tag.length - 2] == '/') continue;
    final end = body.indexOf('</$name', m.end);
    if (end < 0) return;
    yield _text(body.substring(m.end, end)).trim();
  }
}

final _attrs = <String, RegExp>{};

String? _attr(String tag, String name) {
  final m = (_attrs[name] ??= RegExp('\\s$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')')).firstMatch(tag);
  return m == null ? null : _unescape(m[2] ?? m[3]!);
}

final _entity = RegExp(r'&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);', caseSensitive: false);

/// The XML entities and character references; anything else stays as written.
String _unescape(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entity, (m) {
    final e = m[1]!.toLowerCase();
    switch (e) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final n = e[1] == 'x' ? int.tryParse(e.substring(2), radix: 16) : int.tryParse(e.substring(1));
    return n != null && n >= 0 && n <= 0x10ffff ? String.fromCharCode(n) : m[0]!;
  });
}

/// Element text: entities decoded, CDATA kept as it is.
String _text(String raw) {
  final out = StringBuffer();
  var i = 0;
  for (;;) {
    final s = raw.indexOf('<![CDATA[', i);
    if (s < 0) return (out..write(_unescape(raw.substring(i)))).toString();
    out.write(_unescape(raw.substring(i, s)));
    final e = raw.indexOf(']]>', s + 9);
    if (e < 0) return (out..write(raw.substring(s + 9))).toString();
    out.write(raw.substring(s + 9, e));
    i = e + 3;
  }
}

final _opening = {
  'title': RegExp(r'<title(?=[\s/>])[^>]*>'),
  'desc': RegExp(r'<desc(?=[\s/>])[^>]*>'),
  'icon': RegExp(r'<icon(?=[\s/>])[^>]*>'),
  'display-name': RegExp(r'<display-name(?=[\s/>])[^>]*>'),
};

/// The text of the [name] element in [body] in [language] (lang="es", "es-CO"), or else of the first
/// that has any: an empty `<title/>` is skipped for the next one, an empty `<title></title>` counts.
String? _firstText(String body, String name, [String? language]) {
  String? first;
  for (final m in _opening[name]!.allMatches(body)) {
    final tag = m[0]!;
    if (tag[tag.length - 2] == '/') continue;
    final end = body.indexOf('</$name', m.end);
    if (end < 0) break;
    final text = _text(body.substring(m.end, end)).trim();
    if (language == null) return text;
    first ??= text;
    if (_attr(tag, 'lang')?.toLowerCase().startsWith(language) ?? false) return text;
  }
  return first;
}

final _comment = RegExp(r'<!--[\s\S]*?-->');

String _withoutComments(String s) => s.contains('<!--') ? s.replaceAll(_comment, '') : s;

/// Reads a cached guide as text, transparently un-gzipping .xml.gz files (magic bytes 1f 8b).
Stream<String> _readGuide(File file) {
  final raf = file.openSync();
  final head = raf.readSync(2);
  raf.closeSync();
  Stream<List<int>> bytes = file.openRead();
  if (head.length == 2 && head[0] == 0x1f && head[1] == 0x8b) bytes = bytes.transform(gzip.decoder);
  return _decode(bytes);
}

/// UTF-8, or Latin-1 for a guide whose declaration says so (encoding="ISO-8859-1"): read as UTF-8
/// its accents would come out as "�".
Stream<String> _decode(Stream<List<int>> bytes) async* {
  final chunks = StreamIterator(bytes);
  if (!await chunks.moveNext()) return;
  final first = chunks.current;
  final head = latin1.decode(first.take(200).toList(), allowInvalid: true).toLowerCase();
  Stream<List<int>> all() async* {
    yield first;
    while (await chunks.moveNext()) {
      yield chunks.current;
    }
  }

  yield* all().transform(
    _latinDeclared.hasMatch(head)
        ? const Latin1Decoder(allowInvalid: true) as Converter<List<int>, String>
        : const Utf8Decoder(allowMalformed: true),
  );
}

final _latinDeclared = RegExp(r'''encoding\s*=\s*["'](?:iso-8859-1|iso-8859-15|latin-?1|windows-1252|cp1252)''');

/// Downloads (or reuses a fresh cached copy of) an XMLTV guide and parses it.
/// A copy older than [maxAge] but from the last day is shown at once, as lists are, while a new
/// one comes in the background for the next time; an older one is waited for. Falls back to the
/// copy there is when the download fails or brings no guide, and to an empty guide with none.
/// Once [stop] completes (its source closed, see [Closable]), a download under way ends with an
/// empty guide, and nothing is read.
Future<EpgGuide> loadXmltv(
  Uri url, {
  required File cache,
  http.Client? client,
  Duration maxAge = const Duration(hours: 6),
  DateTime? now,
  Future<void>? stop,
  Future<GuideChannels?>? channels,
  Duration shift = Duration.zero,
}) async {
  final reading = (channels: channels, shift: shift);
  dropStaleCache(cache, 'epg-', const Duration(days: 7));
  final age = cache.existsSync() ? DateTime.now().difference(cache.lastModifiedSync()) : null;
  if (age != null && age < maxAge) return _parseGuide(cache, now, reading);
  if (age != null && age < const Duration(hours: 24) && maxAge > Duration.zero) {
    final guide = await _parseGuide(cache, now, reading);
    if (!guide.isEmpty) {
      refreshInBackground(
        cache,
        (part, giveWay) async => await _downloadGuide(url, cache, part, client, giveWay, now, reading) != null,
      );
      return guide;
    }
  }
  final part = partFile(cache);
  try {
    // A way to give that never comes unless closed: waited for, it is still no list in the
    // loading screens
    final guide = await _downloadGuide(url, cache, part, client, stop ?? Completer<void>().future, now, reading);
    if (guide != null) {
      // One cut short is shown, there being no other, but not kept: the next time downloads it again
      if (guide.complete) {
        try {
          await part.rename(cache.path);
        } on FileSystemException {
          // Not kept, then: it is only a cache
        }
      }
      return guide;
    }
  } on DownloadStopped {
    return EpgGuide.empty; // nobody waits for it any more
  } finally {
    dropFile(part);
  }
  return cache.existsSync() ? _parseGuide(cache, now, reading) : EpgGuide.failed;
}

/// What a guide is read for: the playlist's channels, when they come (see [GuideChannels]), and how
/// far its times are moved.
typedef _Reading = ({Future<GuideChannels?>? channels, Duration shift});

/// How far back the guide goes, at most, for channels that keep what they aired.
const maxCatchupDays = 7;

/// The guide in [file]. Often tens of MB of XML: parsed off the UI isolate, so the app stays smooth.
/// On a device with little memory, a day ahead rather than two, and the past only of the channels
/// with catch-up (decided here: inside the isolate [lowMemory] is not known). The playlist's
/// channels are waited for only now, so the guide downloads while they still come.
Future<EpgGuide> _parseGuide(File file, DateTime? now, _Reading reading) async {
  final path = file.path, language = appLocale.languageCode, small = lowMemory, shift = reading.shift;
  try {
    final channels = await reading.channels;
    return await runOffThread(
      () => parseXmltv(
        _readGuide(File(path)),
        now: now,
        language: language,
        channels: channels,
        shift: shift,
        ahead: Duration(days: small ? 1 : 2),
        // Channels with catch-up keep up to a week of what they aired, as far as the guide goes
        // back; the others the days the grid shows, or a couple of hours on a small device
        past: Duration(days: !small && channels != null ? maxCatchupDays : 3),
        shortPast: channels == null ? null : (small ? const Duration(hours: 2) : const Duration(days: 3)),
      ),
    );
  } on Object {
    // Not readable at all (a damaged gzip): gone, so the next time downloads it rather than
    // failing on it again until it is old enough to be replaced
    try {
      file.deleteSync();
    } on Object {
      // Already gone
    }
    return EpgGuide.empty;
  }
}

/// The guide at [url], downloaded into [part]: null when it fails or is no guide to keep instead of
/// [cache]'s. A web page, an empty answer or a guide with no programmes sent with a 200 (a panel
/// rebuilding its guide), much less than there was, or one cut short (no `</tv>`, a download that
/// broke off with no length to tell) while there is a copy, is none: the copy there is stays, its
/// date untouched, so the next load tries again.
Future<EpgGuide?> _downloadGuide(
  Uri url,
  File cache,
  File part,
  http.Client? client,
  Future<void> giveWay,
  DateTime? now,
  _Reading reading,
) async {
  final c = client ?? providerClient();
  try {
    // Each piece may take a minute, not the whole: a guide stalled half way gives up
    if (await downloadTo(c, url, part, wait: const Duration(seconds: 60), giveWay: giveWay, maxBytes: largestGuide) !=
        200) {
      return null;
    }
  } on DownloadStopped {
    rethrow;
  } on Object {
    return null;
  } finally {
    if (client == null) c.close();
  }
  if (cache.existsSync() && part.lengthSync() < cache.lengthSync() ~/ 2) return null;
  final guide = await _parseGuide(part, now, reading);
  if (guide.isEmpty || !guide.complete && cache.existsSync()) return null;
  return guide;
}

/// The guide of the playlist open, once it is in: what the player shows of a channel as it zaps.
final currentGuide = ValueNotifier<EpgGuide?>(null);
