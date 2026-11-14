// FNV-1a over 64 bits, in a native int. See stable_hash.dart.
import 'dart:convert';

String fnv1a64Hex(String s) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(s)) {
    h = (h ^ b) * 0x100000001b3;
  }
  return (h >>> 32).toRadixString(16).padLeft(8, '0') + (h & 0xffffffff).toRadixString(16).padLeft(8, '0');
}
