// ChaCha20-Poly1305 (RFC 8439) for the companion page. It is served over plain HTTP on the local
// network, where browsers offer no crypto.subtle, so passwords and backups are sealed here with
// the key the QR code carries (in the address's #fragment, which browsers never send).
// sealed = base64(nonce ‖ ciphertext ‖ tag), with the API path as associated data. The app does
// the same with the cryptography package (lib/remote/companion_seal.dart).
const Seal = (() => {
  'use strict';

  const words = (bytes) => {
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return Uint32Array.from({ length: bytes.length / 4 }, (_, i) => dv.getUint32(i * 4, true));
  };

  function block(key, counter, nonce) {
    const s = new Uint32Array(16);
    s.set([0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]);
    s.set(key, 4);
    s[12] = counter;
    s.set(nonce, 13);
    const x = s.slice();
    const rotl = (v, c) => (v << c) | (v >>> (32 - c));
    const quarter = (a, b, c, d) => {
      x[a] += x[b]; x[d] = rotl(x[d] ^ x[a], 16);
      x[c] += x[d]; x[b] = rotl(x[b] ^ x[c], 12);
      x[a] += x[b]; x[d] = rotl(x[d] ^ x[a], 8);
      x[c] += x[d]; x[b] = rotl(x[b] ^ x[c], 7);
    };
    for (let i = 0; i < 10; i++) {
      quarter(0, 4, 8, 12); quarter(1, 5, 9, 13); quarter(2, 6, 10, 14); quarter(3, 7, 11, 15);
      quarter(0, 5, 10, 15); quarter(1, 6, 11, 12); quarter(2, 7, 8, 13); quarter(3, 4, 9, 14);
    }
    const out = new Uint8Array(64), dv = new DataView(out.buffer);
    for (let i = 0; i < 16; i++) dv.setUint32(i * 4, (x[i] + s[i]) >>> 0, true);
    return out;
  }

  function chacha20(key, counter, nonce, data) {
    const k = words(key), n = words(nonce), out = new Uint8Array(data.length);
    for (let i = 0; i < data.length; i += 64) {
      const stream = block(k, counter + i / 64, n);
      for (let j = 0; j < 64 && i + j < data.length; j++) out[i + j] = data[i + j] ^ stream[j];
    }
    return out;
  }

  // Little-endian bytes as a number
  const number = (bytes) => {
    let v = 0n;
    for (let i = bytes.length - 1; i >= 0; i--) v = (v << 8n) | BigInt(bytes[i]);
    return v;
  };

  function poly1305(key, message) {
    const r = number(key.subarray(0, 16)) & 0x0ffffffc0ffffffc0ffffffc0fffffffn;
    const s = number(key.subarray(16, 32));
    const p = (1n << 130n) - 5n;
    let a = 0n;
    for (let i = 0; i < message.length; i += 16) {
      const chunk = message.subarray(i, i + 16);
      a = ((a + number(chunk) + (1n << BigInt(8 * chunk.length))) * r) % p;
    }
    a = (a + s) & ((1n << 128n) - 1n);
    const out = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      out[i] = Number(a & 0xffn);
      a >>= 8n;
    }
    return out;
  }

  const pad16 = (n) => (16 - (n % 16)) % 16;

  function tag(key, nonce, aad, cipherText) {
    const oneTimeKey = block(words(key), 0, words(nonce)).subarray(0, 32);
    const length = aad.length + pad16(aad.length) + cipherText.length + pad16(cipherText.length) + 16;
    const m = new Uint8Array(length), dv = new DataView(m.buffer);
    m.set(aad, 0);
    m.set(cipherText, aad.length + pad16(aad.length));
    // Two 32-bit halves, not setBigUint64, which Safari has only from 15
    dv.setUint32(length - 16, aad.length, true);
    dv.setUint32(length - 12, 0, true);
    dv.setUint32(length - 8, cipherText.length, true);
    dv.setUint32(length - 4, 0, true);
    return poly1305(oneTimeKey, m);
  }

  const encoder = new TextEncoder(), decoder = new TextDecoder();

  function base64(bytes) {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  }

  function bytesOf(text) {
    const s = atob(text);
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
  }

  /** The key as the QR code carries it: base64url without padding. */
  const keyFrom = (text) =>
    bytesOf(text.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((text.length + 3) % 4));

  /** Seals [value] (anything JSON) for [path]. The nonce is random unless a test gives one. */
  function seal(key, path, value, nonce = crypto.getRandomValues(new Uint8Array(12))) {
    const cipherText = chacha20(key, 1, nonce, encoder.encode(JSON.stringify(value)));
    const out = new Uint8Array(12 + cipherText.length + 16);
    out.set(nonce, 0);
    out.set(cipherText, 12);
    out.set(tag(key, nonce, encoder.encode(path), cipherText), 12 + cipherText.length);
    return base64(out);
  }

  /** What [seal] sealed for [path]; throws if it was made with another key, for another path or changed. */
  function open(key, path, sealed) {
    const all = bytesOf(sealed);
    if (all.length < 28) throw new Error('sealed');
    const nonce = all.subarray(0, 12), cipherText = all.subarray(12, all.length - 16), mac = all.subarray(all.length - 16);
    const expected = tag(key, nonce, encoder.encode(path), cipherText);
    let diff = 0;
    for (let i = 0; i < 16; i++) diff |= expected[i] ^ mac[i];
    if (diff !== 0) throw new Error('sealed');
    return JSON.parse(decoder.decode(chacha20(key, 1, nonce, cipherText)));
  }

  return { seal, open, keyFrom, chacha20, poly1305 };
})();
if (typeof module === 'object') module.exports = Seal; // tests run it with Node
