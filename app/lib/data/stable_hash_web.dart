// FNV-1a over 64 bits, in BigInt: the same value the native build gives, without a number that
// JavaScript cannot carry. See stable_hash.dart.
import 'dart:convert';

final _offset = BigInt.parse('cbf29ce484222325', radix: 16);
final _prime = BigInt.parse('100000001b3', radix: 16);
final _mask = (BigInt.one << 64) - BigInt.one;

String fnv1a64Hex(String s) {
  var h = _offset;
  for (final b in utf8.encode(s)) {
    h = ((h ^ BigInt.from(b)) * _prime) & _mask;
  }
  final hex = h.toRadixString(16).padLeft(16, '0');
  return hex;
}
