import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _quote = 0x22, _backslash = 0x5c;
const _openBrace = 0x7b, _closeBrace = 0x7d, _openBracket = 0x5b, _closeBracket = 0x5d;

bool _isSpace(int b) => b == 0x20 || b == 0x0a || b == 0x0d || b == 0x09;

/// The most kept of what is no list. A bare value is small; past this it is something else (a
/// warning before a list of 60 MB), and holding it whole to find out would not fit in a TV stick.
const _mostBare = 256 * 1024;

/// Where the JSON starts past a PHP warning a panel printed before it ("<br />\n<b>Warning</b>:
/// ..."): the first [ or { at the start of a line or right after a tag. Null when [text] starts
/// with no such warning (a web page is no JSON, and stays an error), or none comes soon enough.
int? afterPhpNotice(String text) {
  final start = text.trimLeft();
  if (!_phpNotice.hasMatch(start)) return null;
  final m = RegExp(r'(?:^|\n|>)\s*([\[{])').allMatches(text).where((m) => m.start < _mostBare).firstOrNull;
  return m == null ? null : m.end - 1;
}

final _phpNotice = RegExp(r'^(?:<br|<b>|(?:PHP )?(?:Warning|Notice|Deprecated|Fatal error)\b)', caseSensitive: false);

/// The objects in a JSON array, or the values of a JSON object (some panels send {"0": {...},
/// "1": {...}}), one at a time from [chunks] of its bytes. Decoded whole, a list of tens of MB takes
/// several hundred in memory, as text and then as maps, which a TV stick does not have; this way it
/// takes the items made of it and little else. Other elements are skipped unread. Nothing comes of
/// a bare value (null, a number). An item that is no JSON (a tab left unescaped in one title) is
/// skipped: the rest of the list is good. Throws [FormatException] when it is not JSON or is cut
/// short, or when all its items were skipped.
Iterable<Map<String, dynamic>> jsonItems(Iterable<Uint8List> chunks) sync* {
  int? outer; // the opening bracket of the whole, once seen
  var depth = 0, inString = false, escape = false, inItem = false, ended = false;
  var read = 0, skipped = 0;
  var notice = false, noticeRead = 0, afterBreak = false; // past a PHP warning (see [afterPhpNotice])
  final item = BytesBuilder(copy: false), bare = BytesBuilder();
  for (final chunk in chunks) {
    if (outer == null && bare.isNotEmpty) {
      bare.add(chunk);
      if (bare.length > _mostBare) throw const FormatException('Not a list');
      continue;
    }
    var from = inItem ? 0 : -1; // where the item being read starts in this chunk
    for (var i = 0; i < chunk.length; i++) {
      final b = chunk[i];
      if (notice) {
        if (++noticeRead > _mostBare) throw const FormatException('Not a list');
        if (afterBreak && (b == _openBracket || b == _openBrace)) {
          notice = false;
          outer = b;
          depth = 1;
        } else if (b == 0x0a || b == 0x3e) {
          afterBreak = true; // a new line, or the end of a tag
        } else if (!_isSpace(b)) {
          afterBreak = false;
        }
        continue;
      }
      if (inString) {
        if (escape) {
          escape = false;
        } else if (b == _backslash) {
          escape = true;
        } else if (b == _quote) {
          inString = false;
        }
      } else if (outer == null) {
        if (b == _openBracket || b == _openBrace) {
          outer = b;
          depth = 1;
        } else if (!_isSpace(b) && b != 0xef && b != 0xbb && b != 0xbf) {
          if (_phpNotice.hasMatch(latin1.decode(Uint8List.sublistView(chunk, i, (i + 24).clamp(0, chunk.length))))) {
            notice = true; // a warning before the list: skipped
            continue;
          }
          // Not a list: read whole (it is small), for what it is
          bare.add(Uint8List.sublistView(chunk, i));
          break;
        }
      } else if (ended) {
        if (!_isSpace(b)) throw const FormatException('Unexpected character after the end');
      } else if (b == _quote) {
        inString = true;
      } else if (b == _openBrace || b == _openBracket) {
        depth++;
        if (depth == 2 && b == _openBrace) {
          inItem = true;
          from = i;
        }
      } else if (b == _closeBrace || b == _closeBracket) {
        depth--;
        if (inItem && depth == 1) {
          item.add(Uint8List.sublistView(chunk, from, i + 1));
          inItem = false;
          final Object? j;
          try {
            j = jsonDecode(utf8.decode(item.takeBytes(), allowMalformed: true));
            read++;
          } on FormatException {
            skipped++;
            continue;
          }
          if (j is Map<String, dynamic>) yield j;
        } else if (depth == 0) {
          if (b != (outer == _openBracket ? _closeBracket : _closeBrace)) throw const FormatException('Mismatched end');
          ended = true;
        }
      }
    }
    if (inItem) item.add(Uint8List.sublistView(chunk, from));
  }
  if (notice) {
    throw const FormatException('Not a list');
  } else if (bare.isNotEmpty) {
    jsonDecode(utf8.decode(bare.takeBytes(), allowMalformed: true)); // throws when it is not JSON either
  } else if (!ended) {
    throw const FormatException('Cut short');
  } else if (skipped > 0 && read == 0) {
    throw const FormatException('No item could be read');
  }
}

/// [file]'s bytes in pieces, read as they are asked for.
Iterable<Uint8List> chunksOf(RandomAccessFile file, {int size = 64 * 1024}) sync* {
  while (true) {
    final chunk = file.readSync(size);
    if (chunk.isEmpty) return;
    yield chunk;
  }
}

/// Counts the objects of a JSON list as its bytes go by, none of them read: to say how many have
/// come while a big list still downloads. Only for showing: it does not check that it is JSON.
class JsonItemCounter {
  var count = 0;
  var _depth = 0, _inString = false, _escape = false;

  void add(List<int> piece) {
    for (final b in piece) {
      if (_inString) {
        if (_escape) {
          _escape = false;
        } else if (b == _backslash) {
          _escape = true;
        } else if (b == _quote) {
          _inString = false;
        }
      } else if (b == _quote) {
        _inString = true;
      } else if (b == _openBrace || b == _openBracket) {
        _depth++;
      } else if (b == _closeBrace || b == _closeBracket) {
        _depth--;
        if (_depth == 1 && b == _closeBrace) count++;
      }
    }
  }
}
