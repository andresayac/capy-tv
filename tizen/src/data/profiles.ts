// Profiles and the parental PIN (app/lib/data/profiles.dart), saved and merged the same way so
// sync moves them between the two apps unchanged. The parental PIN keeps children away from adult
// content and from the settings; a profile can have a PIN of its own, for what it watches to stay
// its own. Four digits: they are not meant to stop someone with the TV and time to spare.
import { sha256 } from '@noble/hashes/sha2.js';
import { Notifier } from '../ui/components';
import { keepsOver } from './keeps_over';
import { mainProfileId } from './library';

export interface Profile {
  id: string;
  name: string; // empty for the main profile until someone names it
  kids?: boolean; // never shown adult content
  locked?: boolean; // opening it asks for its own PIN, or the parental one when it has none
  adult?: boolean; // shows adult content (never in a kids profile)
  at: number; // when it last changed (ms): between devices, the latest change wins
  deleted?: boolean; // kept as a marker, so other devices delete it too
  /** The picture chosen for it, one of those the app comes with ("notionists-8"); none for its initial. */
  avatar?: string;
  /** Its own PIN: what it watches is for whoever knows it, and the parental PIN does not open it. */
  pin?: OwnPin;
  /**
   * What a newer version of the app keeps in a profile and this one does not know: kept as it came
   * and sent on, so syncing through this TV loses none of it.
   */
  extra?: Record<string, unknown>;
}

interface Pin {
  salt?: string;
  hash?: string;
  at: number;
}

interface OwnPin {
  salt: string;
  hash: string;
}

export const isMain = (p: Profile) => p.id === mainProfileId;
export const showsAdult = (p: Profile) => !!p.adult && !p.kids;
export const hasOwnPin = (p: Profile) => !!p.pin;

const KNOWN = ['id', 'name', 'kids', 'locked', 'adult', 'at', 'deleted', 'avatar', 'pin'];

/**
 * Keys of Flutter's own this TV keeps without using them all (its languages, its time per day,
 * read by watch_time.ts): written where Flutter writes them, after the avatar, not first.
 */
const FLUTTER_OWN = ['audio', 'subtitles', 'minutes'];

/** Its own PIN as it came; one with nothing to check against is none. */
function ownPin(j: Record<string, unknown>): OwnPin | undefined {
  const pin = j.pin as OwnPin | null | undefined;
  return pin && typeof pin === 'object' && pin.hash != null ? pin : undefined;
}

function profileFromJson(j: Record<string, unknown>): Profile {
  const p: Profile = { id: String(j.id), name: typeof j.name === 'string' ? j.name : '', at: Math.trunc(Number(j.at) || 0) };
  const pin = ownPin(j);
  if (j.kids === true) p.kids = true;
  // Whatever a device that does not know about a PIN of its own may have done to the lock
  if (j.locked === true || pin) p.locked = true;
  if (j.adult === true) p.adult = true;
  if (j.deleted === true) p.deleted = true;
  if (typeof j.avatar === 'string') p.avatar = j.avatar;
  if (pin) p.pin = pin;
  const extra: Record<string, unknown> = {};
  let any = false;
  for (const k of Object.keys(j)) {
    if (KNOWN.indexOf(k) >= 0) continue;
    extra[k] = j[k];
    any = true;
  }
  if (any) p.extra = extra;
  return p;
}

/**
 * A profile as the Flutter app encodes it: what neither version knows first, then these keys in
 * this order, the false ones left out. The same profile gives the same text in both apps, or each
 * would take the other's for a change and write it back, over and over.
 */
export function profileJson(p: Profile): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const extra = p.extra || {};
  for (const k of Object.keys(extra)) if (KNOWN.indexOf(k) < 0 && FLUTTER_OWN.indexOf(k) < 0) out[k] = extra[k];
  out.id = p.id;
  out.name = p.name || '';
  if (p.kids) out.kids = true;
  if (p.locked) out.locked = true;
  if (p.adult) out.adult = true;
  out.at = p.at || 0;
  if (p.deleted) out.deleted = true;
  if (typeof p.avatar === 'string') out.avatar = p.avatar;
  for (const k of FLUTTER_OWN) if (extra[k] !== undefined && extra[k] !== null) out[k] = extra[k];
  if (p.pin) out.pin = p.pin;
  return out;
}

const KEY = 'profiles';
const CURRENT = 'profiles.current';

function b64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

class ProfileStore extends Notifier {
  private all: Record<string, Profile> = {};
  private pin: Pin | null = null;
  private currentId = mainProfileId;
  private chosen = false;

  constructor() {
    super();
    this.load();
  }

  private load(): void {
    try {
      const raw = localStorage.getItem(KEY);
      if (raw) this.absorb(JSON.parse(raw));
    } catch {
      // Damaged: the main profile only
    }
    if (!this.all[mainProfileId]) this.all[mainProfileId] = { id: mainProfileId, name: '', at: 0 };
    this.currentId = localStorage.getItem(CURRENT) || mainProfileId;
    // With a single profile there is nothing to choose, also once a second one is added; unless
    // its PIN is to be asked for
    this.chosen = this.profiles.length <= 1 && !this.current.locked && !hasOwnPin(this.current);
  }

  /**
   * Profiles in use: the main one, then by name, compared as Dart's compareTo does (by code unit,
   * not by locale), so the phone and the TV list them in the same order.
   */
  get profiles(): Profile[] {
    const byName = (a: Profile, b: Profile) => {
      const x = a.name.toLowerCase();
      const y = b.name.toLowerCase();
      return x < y ? -1 : x > y ? 1 : 0;
    };
    return Object.keys(this.all)
      .map((k) => this.all[k])
      .filter((p) => !p.deleted)
      .sort((a, b) => (isMain(a) !== isMain(b) ? (isMain(a) ? -1 : 1) : byName(a, b)));
  }

  get current(): Profile {
    const p = this.all[this.currentId];
    return p && !p.deleted ? p : this.all[mainProfileId];
  }

  /** "Who's watching?" goes first: there is someone to pick, or a PIN to ask for, and it was not yet. */
  get choosing(): boolean {
    return !this.chosen && (this.profiles.length > 1 || !!this.current.locked || hasOwnPin(this.current));
  }

  get hasPin(): boolean {
    return !!(this.pin && this.pin.hash);
  }

  select(id: string): void {
    this.currentId = id;
    this.chosen = true;
    localStorage.setItem(CURRENT, id);
    this.notify();
  }

  /** Back to "Who's watching?". */
  switchProfile(): void {
    this.chosen = false;
    this.notify();
  }

  add(name: string, kids = false, avatar?: string): Profile {
    const bytes = new Uint8Array(8);
    crypto.getRandomValues(bytes);
    const id = Array.prototype.map.call(bytes, (b: number) => (b < 16 ? '0' : '') + b.toString(16)).join('');
    const p: Profile = { id, name: name.trim(), kids, at: Date.now() };
    if (avatar) p.avatar = avatar;
    this.all[id] = p;
    this.save();
    return p;
  }

  /** Saves the changes in [p]; its time moves on, so they win over other devices' older ones. */
  update(p: Profile): void {
    this.all[p.id] = { ...p, at: Math.max(Date.now(), ((this.all[p.id] && this.all[p.id].at) || 0) + 1) };
    this.save();
  }

  /** Deletes a profile (never the main one), with its favorites and history on this TV. */
  remove(id: string): void {
    const p = this.all[id];
    if (!p || isMain(p)) return;
    this.all[id] = { id, name: '', deleted: true, at: Math.max(Date.now(), p.at + 1) };
    if (id === this.currentId) this.chosen = false; // whoever was in it picks again, PINs and all
    dropLibraries(id);
    this.save();
  }

  /**
   * Sets the parental PIN, or with null removes it (and with it the lock of the profiles that
   * depended on it; those with a PIN of their own keep theirs).
   */
  setPin(pin: string | null): void {
    const at = Math.max(Date.now(), ((this.pin && this.pin.at) || 0) + 1);
    if (pin === null) {
      this.pin = { at };
      for (const p of this.profiles.filter((x) => x.locked && !hasOwnPin(x))) this.all[p.id] = { ...p, locked: false, at: Math.max(Date.now(), p.at + 1) };
    } else {
      const s = newSalt();
      this.pin = { salt: s, hash: hash(s, pin), at };
    }
    this.save();
  }

  /** Whether [pin] is the parental PIN; true when there is none. */
  checkPin(pin: string): boolean {
    return !this.hasPin || hash(this.pin!.salt || '', pin) === this.pin!.hash;
  }

  /** Gives the profile [id] a PIN of its own and locks it, or with null takes both away. */
  setProfilePin(id: string, pin: string | null): void {
    const p = this.all[id];
    if (!p) return;
    const next: Profile = { ...p, locked: pin !== null, at: Math.max(Date.now(), p.at + 1) };
    delete next.pin;
    if (pin !== null) {
      const s = newSalt();
      next.pin = { salt: s, hash: hash(s, pin) };
    }
    this.all[id] = next;
    this.save();
  }

  /** Whether [pin] is the PIN of [p], which has one. */
  checkProfilePin(p: Profile, pin: string): boolean {
    return hash(p.pin!.salt, pin) === p.pin!.hash;
  }

  /** Merges profiles from another device: for each and for the PIN, the latest change wins. */
  merge(j: Record<string, unknown>): boolean {
    const before = JSON.stringify(this.toJson());
    const gone = this.absorb(j);
    if (JSON.stringify(this.toJson()) === before) return false;
    gone.forEach(dropLibraries);
    this.save();
    return true;
  }

  /** Returns the profiles that became deleted. */
  private absorb(j: Record<string, unknown>): string[] {
    const gone: string[] = [];
    const list = Array.isArray(j.profiles) ? (j.profiles as unknown[]) : [];
    for (const x of list) {
      if (!x || typeof x !== 'object' || typeof (x as Profile).id !== 'string') continue;
      const p = profileFromJson(x as Record<string, unknown>);
      const mine = this.all[p.id];
      // At the same time the fuller copy wins: a device that drops a field cannot take it away
      if (!mine || p.at > mine.at || (p.at === mine.at && keepsOver(profileJson(p), profileJson(mine)))) {
        if (p.deleted && mine && !mine.deleted) {
          gone.push(p.id);
          if (p.id === this.currentId) this.chosen = false;
        }
        this.all[p.id] = p;
      }
    }
    const pin = j.pin as Record<string, unknown> | undefined;
    if (pin && typeof pin === 'object') {
      const mine = this.pin ? this.pin.at : -1;
      const theirs = Math.trunc(Number(pin.at) || 0);
      if (theirs > mine || (theirs === mine && keepsOver(pin, this.pin as unknown as Record<string, unknown> | null))) this.pin = pin as unknown as Pin;
    }
    return gone;
  }

  /** As saved and synced. Sorted, so the same profiles always encode the same way. */
  toJson(): Record<string, unknown> {
    const out: Record<string, unknown> = { profiles: Object.keys(this.all).sort().map((id) => profileJson(this.all[id])) };
    if (this.pin) out.pin = this.pin;
    return out;
  }

  private save(): void {
    localStorage.setItem(KEY, JSON.stringify(this.toJson()));
    this.notify();
  }
}

function newSalt(): string {
  const salt = new Uint8Array(16);
  crypto.getRandomValues(salt);
  return b64(salt);
}

function hash(salt: string, pin: string): string {
  return b64(sha256(new TextEncoder().encode(`${salt}:${pin}`)));
}

/** Deletes every library of a profile on this TV. */
function dropLibraries(profileId: string): void {
  forgetProfileTraces(profileId);
  for (const k of Object.keys(localStorage)) if (k.indexOf('library.') === 0 && k.slice(-(profileId.length + 1)) === `@${profileId}`) localStorage.removeItem(k);
}

/** A profile's searches and AI picks, which tell what it watched as well as its history does. */
export function forgetProfileTraces(profileId: string): void {
  for (const k of Object.keys(localStorage)) {
    if (k === `search.recent.${profileId}` || (k.indexOf('ai.picks.') === 0 && k.slice(-(profileId.length + 1)) === `.${profileId}`)) localStorage.removeItem(k);
  }
}

export const profileStore = new ProfileStore();
