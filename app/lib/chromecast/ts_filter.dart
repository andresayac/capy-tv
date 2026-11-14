import 'dart:typed_data';

/// Drops the DVB service tables (PIDs 0x10-0x14: NIT, SDT/BAT, EIT, RST, TDT/TOT; 0x1E, 0x1F: DIT,
/// SIT) from an MPEG-TS stream, packet by packet, whatever chunks it comes in: the receiver's HLS
/// player expects only the program and its streams.
///
/// Those PIDs are DVB's by convention only: elsewhere (ATSC captures, restreams that keep the
/// source's PIDs) a PMT, a video or an audio stream may be on them. So the PAT and PMTs are read as
/// they pass, a PID they name is kept, and nothing is dropped before they have all been read. A
/// stream that loses packet sync goes on as it is from there.
class TsTableFilter {
  static const _packet = 188;

  final _held = Uint8List(_packet); // the start of a packet the next chunk ends
  var _heldLength = 0;
  var _lost = false;
  Set<int>? _pmts; // the PMT PIDs the PAT names, once it has been read
  final _streams = <int, Set<int>>{}; // by PMT PID, once read: the PIDs it names
  final _partial = <int, List<int>>{}; // by PID: a table section the next packet goes on with

  /// What of [chunk] goes on.
  List<int> add(List<int> chunk) {
    if (_lost) return chunk;
    final out = Uint8List(_heldLength + chunk.length);
    var n = 0, i = 0;
    if (_heldLength > 0) {
      final need = _packet - _heldLength;
      if (chunk.length < need) {
        _held.setRange(_heldLength, _heldLength + chunk.length, chunk);
        _heldLength += chunk.length;
        return const [];
      }
      _held.setRange(_heldLength, _packet, chunk);
      _heldLength = 0;
      i = need;
      if (_keep(_held, 0)) {
        out.setRange(0, _packet, _held);
        n = _packet;
      }
    }
    while (i < chunk.length) {
      final left = chunk.length - i;
      if (chunk[i] != 0x47) {
        _lost = true;
        out.setRange(n, n + left, chunk, i);
        n += left;
        break;
      }
      if (left < _packet) {
        _held.setRange(0, left, chunk, i);
        _heldLength = left;
        break;
      }
      if (_keep(chunk, i)) {
        out.setRange(n, n + _packet, chunk, i);
        n += _packet;
      }
      i += _packet;
    }
    return Uint8List.sublistView(out, 0, n);
  }

  /// What is left at the end: a packet cut short goes as it is.
  List<int> close() {
    final rest = Uint8List.fromList(_held.sublist(0, _heldLength));
    _heldLength = 0;
    return rest;
  }

  bool _keep(List<int> b, int at) {
    final pid = (b[at + 1] & 0x1f) << 8 | b[at + 2];
    if (pid == 0 || (_pmts?.contains(pid) ?? false)) _read(b, at, pid);
    if (!((pid >= 0x10 && pid <= 0x14) || pid == 0x1e || pid == 0x1f)) return true;
    final pmts = _pmts;
    if (pmts == null || pmts.contains(pid) || !pmts.every(_streams.containsKey)) return true;
    return _streams.values.any((named) => named.contains(pid));
  }

  /// Reads what the packet at [at] carries of the PAT or a PMT.
  void _read(List<int> b, int at, int pid) {
    final end = at + _packet;
    final control = b[at + 3] >> 4 & 0x3;
    if (control & 0x1 == 0) return; // no payload
    var p = at + 4;
    if (control & 0x2 != 0) p += 1 + b[p]; // past the adaptation field
    if (p >= end) return;
    final rest = _partial.remove(pid);
    if (b[at + 1] & 0x40 == 0) {
      if (rest != null) _gather(pid, rest..addAll(b.getRange(p, end)));
      return;
    }
    // A section starts here, after what ends the one before
    final pointer = b[p++];
    if (rest != null && p + pointer <= end) _gather(pid, rest..addAll(b.getRange(p, p + pointer)));
    p += pointer;
    if (p < end) _gather(pid, List.of(b.getRange(p, end)));
  }

  /// Reads the whole sections at the start of [bytes]; one cut short waits for the next packet, and
  /// what follows the last is stuffing.
  void _gather(int pid, List<int> bytes) {
    var i = 0;
    while (i < bytes.length && bytes[i] != 0xff) {
      if (bytes.length - i < 3) break;
      final length = 3 + ((bytes[i + 1] & 0x0f) << 8 | bytes[i + 2]);
      if (length > 1024) return; // longer than the PAT or a PMT may be: not one
      if (bytes.length - i < length) break;
      _section(pid, bytes.sublist(i, i + length));
      i += length;
    }
    if (i < bytes.length && bytes[i] != 0xff) _partial[pid] = List.of(bytes.getRange(i, bytes.length));
  }

  /// Reads [s], one whole section of the PAT or a PMT, its CRC last.
  void _section(int pid, List<int> s) {
    if (s.length < 12 || s[1] & 0x80 == 0 || s[5] & 0x1 == 0) return; // no table, or one not current yet
    final end = s.length - 4;
    if (pid == 0 && s[0] == 0x00) {
      final pmts = _pmts ??= {};
      for (var i = 8; i + 4 <= end; i += 4) {
        // Program 0 names the NIT, which goes
        if ((s[i] << 8 | s[i + 1]) != 0) pmts.add((s[i + 2] & 0x1f) << 8 | s[i + 3]);
      }
    } else if (pid != 0 && s[0] == 0x02) {
      final named = _streams[pid] ??= {};
      named.add((s[8] & 0x1f) << 8 | s[9]); // the PCR's
      var i = 12 + ((s[10] & 0x0f) << 8 | s[11]);
      while (i + 5 <= end) {
        named.add((s[i + 1] & 0x1f) << 8 | s[i + 2]);
        i += 5 + ((s[i + 3] & 0x0f) << 8 | s[i + 4]);
      }
    }
  }
}
