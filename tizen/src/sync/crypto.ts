// End-to-end encryption of the sync account (app/lib/sync/sync_crypto.dart), byte for byte the
// same, so the TV and the Flutter app read each other's items and derive the same keys.
//
// Chromium 69 has WebCrypto only on secure origins and no CompressionStream: everything here is
// pure JS (noble for the primitives, fflate for gzip).
import { gcm } from '@noble/ciphers/aes.js';
import { argon2idAsync } from '@noble/hashes/argon2.js';
import { hkdf } from '@noble/hashes/hkdf.js';
import { hmac } from '@noble/hashes/hmac.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { gunzipSync, gzipSync } from 'fflate';

const CONTEXT = 'iptv-player/sync/v1';
const NONCE = 12;
const TAG = 16;

const utf8 = (s: string) => new TextEncoder().encode(s);
const fromUtf8 = (b: Uint8Array) => new TextDecoder().decode(b);

function random(length: number): Uint8Array {
  const out = new Uint8Array(length);
  crypto.getRandomValues(out);
  return out;
}

export function toBase64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

export function fromBase64(text: string): Uint8Array {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/** Dart's base64Url without the padding. */
const toBase64Url = (bytes: Uint8Array) => toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/** AES-256-GCM as Dart's SecretBox.concatenation(): nonce, ciphertext, tag. */
function encrypt(key: Uint8Array, clear: Uint8Array, aad: Uint8Array): string {
  const nonce = random(NONCE);
  const sealed = gcm(key, nonce, aad).encrypt(clear);
  const out = new Uint8Array(NONCE + sealed.length);
  out.set(nonce);
  out.set(sealed, NONCE);
  return toBase64(out);
}

/** Opens what [encrypt] made; throws when the key or the associated data are not the same. */
function decrypt(key: Uint8Array, box: string, aad: Uint8Array): Uint8Array {
  const raw = fromBase64(box);
  if (raw.length < NONCE + TAG) throw new Error('too short');
  return gcm(key, raw.subarray(0, NONCE), aad).decrypt(raw.subarray(NONCE));
}

/**
 * The keys of a sync account's data: [encKey] encrypts every item and [idKey] names them, so
 * the server stores data it cannot read and cannot even tell apart.
 *
 * They are random, made once with the account. The server keeps them too, but only wrapped with
 * keys from the password and from the recovery key (see [SignInKeys]), which it never sees.
 */
export class SyncKeys {
  constructor(readonly encKey: Uint8Array, readonly idKey: Uint8Array) {}

  static random(): SyncKeys {
    return new SyncKeys(random(32), random(32));
  }

  static fromJson(j: { enc: string; ids: string }): SyncKeys {
    return new SyncKeys(fromBase64(j.enc), fromBase64(j.ids));
  }

  /** What stays on the device once signed in. */
  toJson(): { enc: string; ids: string } {
    return { enc: toBase64(this.encKey), ids: toBase64(this.idKey) };
  }

  private static wrapping = utf8(`${CONTEXT}/keys`);

  /** These keys encrypted with [key] (a [SignInKeys.wrapKey]), for the server to keep. */
  wrap(key: Uint8Array): string {
    return encrypt(key, utf8(JSON.stringify(this.toJson())), SyncKeys.wrapping);
  }

  /** Opens what [wrap] made. Throws if [key] is not the one it was made with. */
  static unwrap(key: Uint8Array, wrapped: string): SyncKeys {
    return SyncKeys.fromJson(JSON.parse(fromUtf8(decrypt(key, wrapped, SyncKeys.wrapping))));
  }

  /** Encrypts [data] as item [id]: gzip, then AES-256-GCM with the id as associated data. */
  seal(id: string, data: unknown): string {
    return encrypt(this.encKey, gzipSync(utf8(JSON.stringify(data))), utf8(id));
  }

  /** Opens what [seal] made. Throws if it was made with another key or for another item. */
  open(id: string, payload: string): unknown {
    return JSON.parse(fromUtf8(gunzipSync(decrypt(this.encKey, payload, utf8(id)))));
  }

  /** The name of item [key] on the server: the same on every device, meaningless to anyone else. */
  itemId(key: string): string {
    return this.mac(`id:${key}`);
  }

  /** Tells whether something changed without keeping it (it may hold a password) in the clear. */
  fingerprint(text: string): string {
    return this.mac(`fp:${text}`);
  }

  private mac(text: string): string {
    return toBase64Url(hmac(sha256, this.idKey, utf8(text)));
  }
}

export interface KdfOptions {
  memoryKiB?: number;
  passes?: number;
  /** From 0 to 1, as the derivation goes. */
  onProgress?: (done: number) => void;
}

/**
 * What a password, or the recovery key, gives on the device: [authKey], which proves it to the
 * server without revealing it, and [wrapKey], which wraps the account's [SyncKeys] and is never
 * sent.
 */
export class SignInKeys {
  constructor(readonly authKey: Uint8Array, readonly wrapKey: Uint8Array) {}

  /**
   * Argon2id with RFC 9106's second recommended profile (64 MiB, 3 passes), salted with the
   * email so every device derives the same keys. In pure JS on a TV it takes a while: it yields
   * to the page every 20 ms, so the screen stays alive and can show [onProgress].
   */
  static async password(email: string, password: string, opts: KdfOptions = {}): Promise<SignInKeys> {
    const salt = sha256(utf8(`${CONTEXT}/${SignInKeys.normalizeEmail(email)}`)).subarray(0, 16);
    const master = await argon2idAsync(utf8(password), salt, {
      m: opts.memoryKiB || 65536,
      t: opts.passes || 3,
      p: 1,
      dkLen: 32,
      asyncTick: 20, // ms of work between yields: the page stays alive, the work barely slows
      onProgress: opts.onProgress,
    });
    return SignInKeys.split(master, '');
  }

  /** The recovery key is random and long enough to need no stretching. */
  static recovery(key: RecoveryKey): SignInKeys {
    return SignInKeys.split(key.bytes, 'recovery/');
  }

  private static split(master: Uint8Array, prefix: string): SignInKeys {
    const part = (name: string) => hkdf(sha256, master, undefined, utf8(`${CONTEXT}/${prefix}${name}`), 32);
    return new SignInKeys(part('auth'), part('wrap'));
  }

  static normalizeEmail(email: string): string {
    return email.trim().toLowerCase();
  }
}

const LENGTH = 20;
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/**
 * The way back into an account whose password is forgotten: 160 random bits, shown once when
 * the account is made. Written in Crockford's base32 (no I, L, O or U), in groups of four.
 */
export class RecoveryKey {
  readonly bytes: Uint8Array;

  constructor(bytes: Uint8Array) {
    if (bytes.length !== LENGTH) throw new Error(`a recovery key has ${LENGTH} bytes, not ${bytes.length}`);
    this.bytes = bytes.slice();
  }

  static random(): RecoveryKey {
    return new RecoveryKey(random(LENGTH));
  }

  /**
   * What the user typed, forgiving case, spaces, dashes, and letters taken for the digits they
   * look like. Null when it cannot be a recovery key.
   */
  static parse(text: string): RecoveryKey | null {
    const clean = text.toUpperCase().replace(/[\s-]/g, '').replace(/O/g, '0').replace(/[IL]/g, '1');
    if (clean.length !== (LENGTH * 8) / 5) return null;
    const out: number[] = [];
    let buffer = 0;
    let bits = 0;
    for (const c of clean.split('')) {
      const v = ALPHABET.indexOf(c);
      if (v < 0) return null;
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.push((buffer >> bits) & 0xff);
        buffer &= (1 << bits) - 1;
      }
    }
    return new RecoveryKey(new Uint8Array(out));
  }

  /** As the user writes it down: eight groups of four, like K7QM-3XRA-…. */
  get text(): string {
    let chars = '';
    let buffer = 0;
    let bits = 0;
    for (let i = 0; i < this.bytes.length; i++) {
      buffer = (buffer << 8) | this.bytes[i];
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        chars += ALPHABET[(buffer >> bits) & 31];
      }
      buffer &= (1 << bits) - 1;
    }
    const groups: string[] = [];
    for (let i = 0; i < chars.length; i += 4) groups.push(chars.slice(i, i + 4));
    return groups.join('-');
  }
}
