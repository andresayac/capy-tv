// Everything a user would want on another device (app/lib/data/backup.dart), in the same format:
// playlists with their credentials, profiles with the PIN, favorites, history and playback
// settings. It only travels between the user's own devices.
import { Library, mainProfileId } from './library';
import { mergeInto } from './open_library';
import { newId, Playlist, playlistExtra, playlistToJson, playlistStore, sameAccount } from './playlists';
import { isMain, profileStore } from './profiles';
import { settings } from './settings';

const FORMAT = 'capy-tv-backup';
const VERSION = 2;


export function exportBackup(withSettings = true): Record<string, unknown> {
  const playlists = playlistStore.playlists;
  const libraries = (profileId: string) => {
    const out: Record<string, unknown> = {};
    for (const p of playlists) {
      const lib = Library.stored(p.id, profileId);
      if (lib) out[p.id] = lib;
    }
    return out;
  };
  const profileLibraries: Record<string, unknown> = {};
  for (const profile of profileStore.profiles) if (!isMain(profile)) profileLibraries[profile.id] = libraries(profile.id);
  const out: Record<string, unknown> = {
    format: FORMAT,
    version: VERSION,
    exported: new Date().toISOString(),
    playlists: playlists.map((p) => playlistToJson(p)),
    // The main profile's, as in version 1
    libraries: libraries(mainProfileId),
    profiles: profileStore.toJson(),
    profileLibraries,
  };
  if (withSettings) out.settings = settings.toJson();
  return out;
}

/** Whether [data] was made by a newer version of the app, whose contents this one may not know. */
export function backupTooNew(data: Record<string, unknown>): boolean {
  return typeof data.version === 'number' && data.version > VERSION;
}

/** Whether [data] looks like one of our backups: those made under the app's earlier names ("…-backup") too. */
export function isBackup(data: unknown): data is Record<string, unknown> {
  const d = data as Record<string, unknown> | null;
  return !!d && typeof d === 'object' && typeof d.format === 'string' && d.format.endsWith('-backup') && Array.isArray(d.playlists);
}

export interface ImportResult {
  added: number;
  updated: number;
  libraries: number;
}

/**
 * Merges a backup into this TV: a playlist for an account already here updates its password
 * instead of appearing twice, favorites are added and, for the same item, the most recent progress
 * wins. Settings are taken when [withSettings].
 */
export function importBackup(data: Record<string, unknown>, withSettings: boolean): ImportResult {
  if (!isBackup(data)) throw new Error('Not a Capy TV backup');
  if (backupTooNew(data)) throw new Error('A backup from a newer version');
  let added = 0;
  let updated = 0;
  const target: Record<string, string> = {}; // backup playlist id → id on this TV
  // Combined playlists last, their members as this TV has them: the same accounts may be here
  // already under other ids
  const list = data.playlists as Partial<Playlist>[];
  for (const j of list.filter((x) => x.type !== 'combined').concat(list.filter((x) => x.type === 'combined'))) {
    const p: Playlist = {
      id: j.id || newId(),
      name: j.name || '',
      type: j.type || 'xtream',
      url: j.url || '',
      username: j.username || '',
      password: j.password || '',
      members: (j.members || []).map((m) => target[m] || m),
    };
    if (typeof j.userAgent === 'string' && j.userAgent) p.userAgent = j.userAgent;
    const extra = playlistExtra(j as Record<string, unknown>);
    if (extra) p.extra = extra;
    const existing = playlistStore.playlists;
    const same = existing.filter((x) => sameAccount(x, p))[0];
    if (same) {
      target[p.id] = same.id;
      if (p.password && same.password !== p.password) {
        playlistStore.update({ ...same, password: p.password });
        updated++;
      }
      continue;
    }
    const id = existing.some((x) => x.id === p.id) ? newId() : p.id;
    playlistStore.add({ ...p, id });
    target[p.id] = id;
    added++;
  }
  if (data.profiles && typeof data.profiles === 'object') profileStore.merge(data.profiles as Record<string, unknown>);
  const known: Record<string, true> = {};
  for (const p of profileStore.profiles) known[p.id] = true;
  const byProfile: Record<string, unknown> = { [mainProfileId]: data.libraries, ...((data.profileLibraries as Record<string, unknown>) || {}) };
  let libraries = 0;
  for (const profileId of Object.keys(byProfile)) {
    const libs = byProfile[profileId] as Record<string, Record<string, unknown>> | undefined;
    if (!known[profileId] || !libs || typeof libs !== 'object') continue;
    for (const id of Object.keys(libs)) {
      const to = target[id];
      if (!to) continue;
      // Into the open library when it is this one: the screen shows it, and its next save keeps it
      mergeInto(to, profileId, libs[id]);
      libraries++;
    }
  }
  if (withSettings && data.settings && typeof data.settings === 'object') settings.restore(data.settings as Record<string, unknown>);
  return { added, updated, libraries };
}
