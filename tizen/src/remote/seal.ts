// What seals the messages between this TV and the user's phone (app/lib/remote/companion_seal.dart,
// app/assets/companion/seal.js): a key made for each session travels only inside the QR code, in
// the address's #fragment, which browsers never send. ChaCha20-Poly1305 (RFC 8439) with the path
// as associated data, so a sealed message cannot be replayed elsewhere; sealed text is
// base64(nonce ‖ ciphertext ‖ tag).
import { chacha20poly1305 } from '@noble/ciphers/chacha.js';

function base64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, Array.prototype.slice.call(bytes.subarray(i, i + 0x8000)));
  return btoa(s);
}

function bytesOf(text: string): Uint8Array {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class CompanionSeal {
  private constructor(readonly key: Uint8Array) {}

  static random(): CompanionSeal {
    const key = new Uint8Array(32);
    crypto.getRandomValues(key);
    return new CompanionSeal(key);
  }

  /** The key for the QR code: base64url without padding. */
  get text(): string {
    return base64(this.key).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  seal(path: string, value: unknown): string {
    const nonce = new Uint8Array(12);
    crypto.getRandomValues(nonce);
    const box = chacha20poly1305(this.key, nonce, encoder.encode(path)).encrypt(encoder.encode(JSON.stringify(value)));
    const out = new Uint8Array(12 + box.length);
    out.set(nonce, 0);
    out.set(box, 12);
    return base64(out);
  }

  /** What [seal] sealed for [path]; throws if it was sealed with another key, for another path, or changed. */
  open(path: string, sealed: string): unknown {
    const all = bytesOf(sealed);
    if (all.length < 28) throw new Error('sealed');
    const clear = chacha20poly1305(this.key, all.subarray(0, 12), encoder.encode(path)).decrypt(all.subarray(12));
    return JSON.parse(decoder.decode(clear));
  }
}
