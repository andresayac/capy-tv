// Profiles (app/lib/ui/profiles_screen.dart): "Who's watching?", managing profiles and the
// PINs, entered on an on-screen pad (One Remote has no number keys) or with number keys.
import { ComponentChildren } from 'preact';
import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks';
import { Library } from '../data/library';
import { playlistStore } from '../data/playlists';
import { forgetProfileTraces, hasOwnPin, isMain, Profile, profileStore, showsAdult } from '../data/profiles';
import avatarList from '../avatars.json';
import { t } from '../i18n';
import { session } from '../session';
import { PosterBackdrop } from '../ui/backdrop';
import { AppBar, Focusable, Icon, Panel, PrimaryButton, SecondaryButton, TextField, useNotifier } from '../ui/components';
import { syncService } from '../sync/service';
import { keepingFocus } from '../ui/refocus';
import { back, popToRoot, push, showDialog, toast, useKeys } from '../ui/router';
import { PasswordsDialog } from './sync';

export const displayName = (p: Profile) => (p.name ? p.name : t('profileYou'));

/**
 * The avatars the app comes with (the Flutter app's app/assets/avatars, copied by the build), in
 * the order they are offered: black and white drawings of people, then [kidsAvatars]. A profile
 * keeps the name. The list (src/avatars.json) is the Flutter app's, as its tests check.
 */
export const avatars: string[] = avatarList.avatars;

/** The colourful ones, for kids: monsters, robots and emoji. */
export const kidsAvatars: string[] = avatarList.kids;

/** For a new profile: the first avatar of its kind (colourful for kids, drawings for others) nobody has yet. */
export function defaultAvatar(kids: boolean): string {
  const taken: Record<string, true> = {};
  for (const p of profileStore.profiles) if (p.avatar) taken[p.avatar] = true;
  const kind = kids ? kidsAvatars : avatars.filter((a) => kidsAvatars.indexOf(a) < 0);
  return kind.filter((a) => !taken[a])[0] || kind[0];
}

/**
 * The first character as a reader sees it (Flutter's characters.first): a code point with the
 * marks, variation selectors, skin tones and joined emoji that go with it, or a flag's pair.
 * Chromium 69 has no Intl.Segmenter.
 */
function firstGrapheme(s: string): string {
  const cps = Array.from(s);
  let out = cps[0] || '';
  const regional = (c?: string) => !!c && c.codePointAt(0)! >= 0x1f1e6 && c.codePointAt(0)! <= 0x1f1ff;
  if (regional(cps[0]) && regional(cps[1])) return cps[0] + cps[1];
  for (let i = 1; i < cps.length; i++) {
    const c = cps[i];
    const code = c.codePointAt(0)!;
    if (c === '\u200d' && i + 1 < cps.length) {
      out += c + cps[++i];
    } else if (/^[\p{M}\ufe0e\ufe0f]$/u.test(c) || (code >= 0x1f3fb && code <= 0x1f3ff) || (code >= 0xe0020 && code <= 0xe007f)) {
      out += c;
    } else {
      break;
    }
  }
  return out;
}

/** One of the app's avatars, round. */
export function AvatarPicture({ name, size = 40 }: { name: string; size?: number }) {
  const s = `${size / 10}rem`;
  return <img src={`avatars/${name}.svg`} alt="" style={{ width: s, height: s, flex: 'none', display: 'block', borderRadius: '50%', objectFit: 'cover' }} />;
}

/** A profile's round badge: its avatar, else its initial, white on grey. */
export function ProfileAvatar({ profile, size = 40 }: { profile: Profile; size?: number }) {
  // One this app does not have (chosen with a newer one, on another device): the initial
  if (profile.avatar && avatars.indexOf(profile.avatar) >= 0) return <AvatarPicture name={profile.avatar} size={size} />;
  const s = `${size / 10}rem`;
  return (
    <div class="row" style={{ width: s, height: s, flex: 'none', justifyContent: 'center', borderRadius: '50%', background: 'var(--surface-high)' }}>
      {profile.kids ? <Icon icon="child_care_rounded" size={size * 0.5} /> : <span style={{ fontSize: `${(size * 0.42) / 10}rem`, fontWeight: 700 }}>{firstGrapheme(displayName(profile)).toUpperCase()}</span>}
    </div>
  );
}

/** Shows "Who's watching?" instead of [children] until a profile is picked, or its PIN given. */
export function ProfileGate({ children }: { children: ComponentChildren }) {
  useNotifier(profileStore);
  return profileStore.choosing ? <ProfilesScreen /> : <div style={{ height: '100%' }}>{children}</div>;
}

/** The playlist to open again once a profile is picked from inside it (see changeProfile). */
let reopenAfterProfile: string | null = null;

/**
 * "Who's watching?" from inside the playlist [playlistId]: the profile picked takes over right
 * there, the playlist opening again with its favorites, history and adult setting. The same
 * profile, or Back, leaves everything as it was.
 */
export function changeProfile(playlistId: string): Promise<void> {
  return push<void>((done) => <ProfilesScreen reopen={playlistId} done={done} />).then(() => undefined);
}

/** The playlist to open again for the profile just picked, once; the playlists screen does it. */
export function takeReopenAfterProfile(): string | null {
  if (reopenAfterProfile === null || profileStore.choosing) return null;
  const id = reopenAfterProfile;
  reopenAfterProfile = null;
  return id;
}

/** Profiles and parental control, behind the PIN when there is one. */
export async function openProfileSettings(): Promise<void> {
  if (!(await confirmPin())) return;
  push(() => <ManageProfilesScreen />);
}

/**
 * "Who's watching?": one tile per profile, locked ones behind the PIN. Before a playlist opens
 * (see ProfileGate), or from inside the playlist [reopen] (see changeProfile).
 */
function ProfilesScreen({ reopen, done }: { reopen?: string; done?: () => void }) {
  useNotifier(profileStore);
  const profiles = profileStore.profiles;
  const current = profileStore.current;
  const choose = async (tapped: Profile) => {
    const p = profileStore.profiles.filter((x) => x.id === tapped.id)[0];
    if (!p) return; // deleted while this was on screen
    if (reopen && p.id === profileStore.current.id) return done && done(); // already theirs
    // Leaving a kids profile, or going to one with adult content, is for whoever has the PIN
    const guarded = p.locked || showsAdult(p) || (profileStore.current.kids && !p.kids);
    if (guarded && !(await confirmProfilePin(p))) return;
    if (reopen) {
      reopenAfterProfile = reopen;
      popToRoot();
    }
    profileStore.select(p.id);
  };
  // A TV is 540 dp tall: Flutter's layout below 600 dp, and it scrolls when the profiles do not fit
  const size = 84;
  return (
    <PosterBackdrop>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        {/* From inside a playlist there is a way back to it */}
        {reopen && <AppBar title="" />}
        <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', display: 'flex', flexDirection: 'column' }}>
          <div style={{ margin: 'auto 0', padding: '2.4rem', display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
            <h1 class="headline-medium">{t('whoIsWatching')}</h1>
            <div class="row" data-fgroup style={{ margin: '1.6rem 0', maxWidth: '100%', flexWrap: 'wrap', justifyContent: 'center' }}>
              {profiles.map((p, i) => (
                <div key={p.id} style={{ margin: '0.8rem' }}>
                  <Focusable radius={16} autofocus={p.id === current.id || (i === 0 && !profiles.some((x) => x.id === current.id))} onTap={() => choose(p)}>
                    <div style={{ width: `${(size + 24) / 10}rem`, padding: '1.2rem 0', display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
                      <ProfileAvatar profile={p} size={size} />
                      <div class="row" style={{ marginTop: '1rem', maxWidth: '100%' }}>
                        <span class="ellipsis" style={{ fontWeight: 600, fontSize: 'calc(1.5rem * var(--text))' }}>{displayName(p)}</span>
                        {p.locked && (
                          <span class="muted" style={{ marginLeft: '0.4rem' }}>
                            <Icon icon="lock_rounded" size={14} />
                          </span>
                        )}
                      </div>
                    </div>
                  </Focusable>
                </div>
              ))}
            </div>
            {!adultActionsHidden() && <SecondaryButton icon="manage_accounts_outlined" label={t('profilesTitle')} onPressed={openProfileSettings} />}
          </div>
        </div>
      </div>
    </PosterBackdrop>
  );
}

/** Profiles and parental control: the list of profiles and the PIN. */
function ManageProfilesScreen() {
  useNotifier(profileStore);
  /** One with a PIN of its own only for whoever knows it: from there its lock could be taken off. */
  const edit = async (p?: Profile) => {
    if (p && hasOwnPin(p) && !(await confirmProfilePin(p, !inUse(p)))) return;
    push(() => <EditProfileScreen profile={p} />);
  };
  const setPin = async () => {
    const pin = await askNewPin();
    if (pin === null) return;
    profileStore.setPin(pin);
    toast(t('pinSaved'));
  };
  return (
    <PosterBackdrop>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        <AppBar title={t('profilesTitle')} />
        <div style={{ flex: 1, overflowY: 'auto' }}>
          <div style={{ width: '64rem', margin: '0 auto', padding: '0.8rem 2rem 4rem' }}>
            <p class="muted" style={{ lineHeight: 1.5, marginTop: 0 }}>{t('profilesBody')}</p>
            <div data-fgroup>
              {profileStore.profiles.map((p, i) => (
                <div key={p.id} style={{ marginBottom: '1rem' }}>
                  <Focusable radius={16} scale={1.01} autofocus={i === 0} onTap={() => edit(p)}>
                    <Panel style={{ borderRadius: '1.6rem', padding: '1.2rem 1.4rem' }}>
                      <div class="row">
                        <ProfileAvatar profile={p} size={44} />
                        <div class="grow" style={{ marginLeft: '1.4rem' }}>
                          <div style={{ fontWeight: 700, fontSize: 'calc(1.6rem * var(--text))' }}>{displayName(p)}</div>
                          {(p.kids || p.locked || showsAdult(p)) && (
                            <div class="muted" style={{ fontSize: 'calc(1.3rem * var(--text))' }}>
                              {[p.kids ? t('kidsProfile') : '', p.locked ? t('profileLocked') : '', showsAdult(p) ? t('adultTag') : ''].filter(Boolean).join(' · ')}
                            </div>
                          )}
                        </div>
                        <span class="muted">
                          <Icon icon="chevron_right_rounded" size={24} />
                        </span>
                      </div>
                    </Panel>
                  </Focusable>
                </div>
              ))}
            </div>
            <div style={{ marginTop: '0.6rem' }}>
              <SecondaryButton icon="person_add_alt_rounded" label={t('addProfile')} onPressed={() => edit()} />
            </div>
            <h2 class="title-large" style={{ marginTop: '3.2rem' }}>{t('parentalPin')}</h2>
            <p class="muted" style={{ lineHeight: 1.5 }}>{t('parentalPinBody')}</p>
            <div class="wrap">
              <SecondaryButton icon="pin_outlined" label={profileStore.hasPin ? t('changePin') : t('setPin')} onPressed={setPin} />
              {profileStore.hasPin && (
                <SecondaryButton
                  icon="lock_open_rounded"
                  label={t('removePin')}
                  onPressed={() => {
                    profileStore.setPin(null);
                    toast(t('pinRemoved'));
                  }}
                />
              )}
            </div>
          </div>
        </div>
      </div>
    </PosterBackdrop>
  );
}

/** A new profile, or changes to [profile]. */
function EditProfileScreen({ profile }: { profile?: Profile }) {
  const [name, setName] = useState(profile ? profile.name : '');
  const [kids, setKids] = useState(!!(profile && profile.kids));
  const [locked, setLocked] = useState(!!(profile && profile.locked));
  const [newPin, setNewPin] = useState<string | null>(null); // saved with the profile
  const [adult, setAdult] = useState(!!(profile && profile.adult));
  // A new profile starts with an avatar of its kind, until one is picked
  const [avatar, setAvatar] = useState<string | undefined>(() => (profile ? profile.avatar : defaultAvatar(false)));
  const [avatarPicked, setAvatarPicked] = useState(!!profile);
  const [missing, setMissing] = useState(false);
  const base: Profile = profile || { id: '', name: '', at: 0 };

  /** Locking asks for a PIN of its own; off, it goes. */
  const lock = async (on: boolean) => {
    const pin = on ? await askNewPin() : null;
    if (on && pin === null) return;
    setNewPin(pin);
    setLocked(on);
  };

  const setKind = (v: boolean) => {
    setKids(v);
    // The avatar it was given follows: a colourful one for a kids profile
    if (!avatarPicked) setAvatar(defaultAvatar(v));
  };

  /** The avatars in a window that scrolls, the current one in view and in focus; the initial counts as one. */
  const pickAvatar = async () => {
    const initial: Profile = { ...base, name, kids, avatar: undefined };
    const picked = await keepingFocus(() => showDialog<{ avatar?: string }>((d) => <AvatarPicker selected={avatar} initial={initial} done={d} />));
    if (!picked) return;
    setAvatar(picked.avatar);
    setAvatarPicked(true);
  };

  // Saving: a second OK would make the profile twice and go back one screen too many. A ref, as a
  // second press can come before the screen is drawn again
  const saving = useRef(false);
  const save = async () => {
    if (saving.current) return;
    saving.current = true;
    try {
      await saveNow();
    } finally {
      saving.current = false;
    }
  };

  const saveNow = async () => {
    // The main profile may stay unnamed
    if (!name.trim() && !(profile && isMain(profile))) {
      setMissing(true);
      return;
    }
    // With no PIN at all, anyone could walk into it: see choose
    if (adult && !kids && !profileStore.hasPin) {
      const pin = await askNewPin(t('adultPinTitle'));
      if (pin === null) return;
      profileStore.setPin(pin);
    }
    let id: string;
    if (!profile) {
      const added = profileStore.add(name, kids, avatar);
      id = added.id;
      profileStore.update({ ...added, locked, adult: adult && !kids });
    } else {
      id = profile.id;
      profileStore.update({ ...profile, name: name.trim(), kids, locked, adult: adult && !kids, avatar });
    }
    // After the rest: what was just saved comes from before the PIN
    if (newPin !== null) profileStore.setProfilePin(id, newPin);
    else if (!locked && profile && hasOwnPin(profile)) profileStore.setProfilePin(id, null);
    // Without one, a child could come here and turn all this off
    if (kids && !profileStore.hasPin) {
      const pin = await askNewPin(t('kidsPinTitle'));
      if (pin !== null) profileStore.setPin(pin);
    }
    if (profile && inUse(profile) && (showsAdult(profile) !== (adult && !kids) || !!profile.kids !== kids)) {
      // What is open was listed for the profile as it was
      reopenAfterProfile = session().playlist.id;
      popToRoot();
      profileStore.select(id);
      return;
    }
    back();
  };

  const remove = async () => {
    const sure = await showDialog<boolean>((d) => (
      <div class="dialog">
        <p class="body-large" style={{ marginTop: 0 }}>{t('deleteProfileQuestion', { name: displayName(profile!) })}</p>
        <div class="actions">
          <SecondaryButton label={t('cancel')} onPressed={() => d(false)} autofocus />
          <PrimaryButton label={t('delete')} onPressed={() => d(true)} />
        </div>
      </div>
    ));
    if (!sure) return;
    // Its playlist would write its library back
    const open = inUse(profile!);
    if (open) popToRoot();
    profileStore.remove(profile!.id);
    if (!open) back();
  };

  return (
    <PosterBackdrop>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        <AppBar title={profile ? t('editProfile') : t('addProfile')} />
        <div style={{ flex: 1, overflowY: 'auto' }}>
          <div style={{ width: '56rem', margin: '0 auto', padding: '0.8rem 2rem 4rem' }}>
            <TextField
              label={t('profileName')}
              hint={profile && isMain(profile) ? t('profileYou') : undefined}
              value={name}
              onChange={setName}
              autofocus={!profile}
              error={missing && !name.trim() ? t('required') : null}
            />
            <div class="row" style={{ marginTop: '1.8rem' }}>
              {/* The initial follows the name being typed */}
              <ProfileAvatar profile={{ ...base, name, kids, avatar }} size={56} />
              <div style={{ marginLeft: '1.6rem' }}>
                <SecondaryButton icon="face_rounded" label={t('changeAvatar')} onPressed={pickAvatar} />
              </div>
            </div>
            <div style={{ height: '1.6rem' }} />
            <Toggle label={t('kidsProfile')} hint={t(kids && !profileStore.hasPin ? 'kidsProfileNoPinHint' : 'kidsProfileHint')} value={kids} onChange={setKind} />
            <Toggle label={t('lockProfile')} hint={t('lockProfileHint')} value={locked} onChange={lock} />
            {locked && (
              <div style={{ padding: '0.2rem 0 0.8rem 0.8rem' }}>
                <SecondaryButton icon="pin_outlined" label={newPin !== null || (profile && hasOwnPin(profile)) ? t('changePin') : t('setPin')} onPressed={() => lock(true)} />
              </div>
            )}
            {!kids && <Toggle label={t('showAdult')} hint={t('showAdultHint')} value={adult} onChange={setAdult} />}
            <div class="wrap" style={{ marginTop: '2.4rem' }}>
              <PrimaryButton icon="check_rounded" label={t('save')} onPressed={save} autofocus={!!profile} />
              {profile && !isMain(profile) && <SecondaryButton icon="delete_outline_rounded" label={t('deleteProfile')} onPressed={remove} />}
            </div>
          </div>
        </div>
      </div>
    </PosterBackdrop>
  );
}

/**
 * The avatars to pick from, and the profile's [initial] for none, in rows of seven; the colourful
 * ones for kids under their own title. The one in use is ringed, and brought into view: with so
 * many it can be far down. OK picks.
 */
function AvatarPicker({ selected, initial, done }: { selected?: string; initial: Profile; done: (v: { avatar?: string }) => void }) {
  const size = 52; // Flutter's on a short screen
  const box = useRef<HTMLDivElement>(null);
  // In the middle of the window, as Flutter's Scrollable.ensureVisible(alignment: 0.5)
  useLayoutEffect(() => {
    const b = box.current;
    const on = b && b.querySelector<HTMLElement>('[data-autofocus]');
    if (!b || !on) return;
    const r = on.getBoundingClientRect();
    const v = b.getBoundingClientRect();
    b.scrollTop += r.top + r.height / 2 - (v.top + v.height / 2);
  }, []);
  const choice = (a: string | undefined, picture: ComponentChildren) => {
    const on = a === selected;
    return (
      <div key={a || ''} style={{ margin: '0.3rem' }}>
        <Focusable radius={999} autofocus={on} label={a || t('avatarInitial')} onTap={() => done({ avatar: a })}>
          {/* The initial is grey on the window's grey: an outline shows where it is. The same width for all, so picking one moves nothing */}
          <div style={{ padding: '0.3rem', borderRadius: '50%', border: `0.3rem solid ${on ? 'var(--text)' : a === undefined ? 'var(--subtle)' : 'transparent'}` }}>
            {picture}
          </div>
        </Focusable>
      </div>
    );
  };
  // Seven of 7.6rem in a row, as Flutter's 76 dp: the avatar, its ring and gap, the focus ring's
  // gap and the spacing
  return (
    <div class="dialog" style={{ minWidth: 0, width: '57.4rem', maxHeight: '50rem', boxSizing: 'border-box', display: 'flex', flexDirection: 'column' }}>
      <h2 class="title-large" style={{ marginBottom: '1.6rem', flex: 'none' }}>{t('avatar')}</h2>
      <div ref={box} class="vscroll" style={{ flex: '0 1 auto', minHeight: 0, overflowY: 'auto', margin: '-0.3rem' }}>
        <div class="row" style={{ flexWrap: 'wrap' }}>
          {choice(undefined, <ProfileAvatar profile={initial} size={size} />)}
          {avatars.filter((a) => kidsAvatars.indexOf(a) < 0).map((a) => choice(a, <AvatarPicture name={a} size={size} />))}
        </div>
        <div class="muted" style={{ padding: '1.7rem 0.7rem 0.7rem', fontSize: 'calc(1.4rem * var(--text))', fontWeight: 500 }}>{t('kidsProfile')}</div>
        <div class="row" style={{ flexWrap: 'wrap' }}>{kidsAvatars.map((a) => choice(a, <AvatarPicture name={a} size={size} />))}</div>
      </div>
    </div>
  );
}

/** A whole row that switches a setting on and off. */
export function Toggle({ label, hint, value, onChange }: { label: string; hint: string; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <div style={{ padding: '0.4rem 0' }}>
      <Focusable radius={12} scale={1.01} onTap={() => onChange(!value)}>
        <div class="row" style={{ padding: '1rem 0.8rem' }}>
          <div class="grow">
            <div style={{ fontWeight: 600, fontSize: 'calc(1.5rem * var(--text))' }}>{label}</div>
            <div class="muted" style={{ fontSize: 'calc(1.3rem * var(--text))', lineHeight: 1.4, marginTop: '0.2rem' }}>{hint}</div>
          </div>
          <div style={{ width: '5.2rem', height: '3.2rem', flex: 'none', marginLeft: '1.2rem', borderRadius: '1.6rem', background: value ? 'var(--text)' : 'var(--surface-high)', border: '1px solid var(--stroke)', position: 'relative', boxSizing: 'border-box' }}>
            <div style={{ position: 'absolute', top: '50%', left: value ? '2.4rem' : '0.6rem', width: value ? '2.4rem' : '1.6rem', height: value ? '2.4rem' : '1.6rem', marginTop: value ? '-1.2rem' : '-0.8rem', borderRadius: '50%', background: value ? 'var(--black)' : 'var(--muted)', transition: 'left 150ms' }} />
          </div>
        </div>
      </Focusable>
    </div>
  );
}

// PIN

/** Asks for the parental PIN. True when it was right, or when there is none. */
export async function confirmPin(): Promise<boolean> {
  if (!profileStore.hasPin) return true;
  const pin = await showPinPad(t('enterPin'), (p) => profileStore.checkPin(p), t('wrongPin'), true, true);
  if (pin !== FORGOT) return pin !== null;
  await forgotParentalPin();
  return false;
}

/**
 * The way out of a forgotten parental PIN: the account's password. Without an account nothing can
 * tell a parent from a child, and a button that wiped the PIN would be the child's way past it.
 */
async function forgotParentalPin(): Promise<void> {
  if (syncService.status === 'off' || syncService.status === 'expired') {
    await showDialog<void>((d) => (
      <div class="dialog">
        <p class="body-large" style={{ marginTop: 0 }}>{t('forgotPinNoAccount')}</p>
        <div class="actions">
          <SecondaryButton label={t('close')} onPressed={() => d()} autofocus />
        </div>
      </div>
    ));
    return;
  }
  const proved = await showDialog<boolean>((done) => (
    <PasswordsDialog
      title={t('forgotPin')}
      body={t('forgotPinAccount')}
      labels={[t('syncPassword')]}
      action={t('removePin')}
      run={async (p) => {
        await syncService.verifyPassword(p[0]);
        return true;
      }}
      done={done}
    />
  ));
  if (!proved) return;
  profileStore.setPin(null);
  toast(t('pinRemoved'));
}

/** Tries at a PIN, kept over restarts (Flutter's PinTries): four digits fall to a patient child. */
const pinTries = {
  secondsLeft: () => Math.max(0, Math.ceil((Number(localStorage.getItem('pin.until') || 0) - Date.now()) / 1000)),
  failed() {
    const fails = Number(localStorage.getItem('pin.fails') || 0) + 1;
    localStorage.setItem('pin.fails', String(fails));
    if (fails >= 5) localStorage.setItem('pin.until', String(Date.now() + Math.min(30 * Math.pow(2, Math.min(fails - 5, 10)), 900) * 1000));
  },
  passed() {
    localStorage.removeItem('pin.fails');
    localStorage.removeItem('pin.until');
  },
};

/** A kids profile with no parental PIN to ask for: what is decided for the whole device or account is not offered. */
export const adultActionsHidden = () => !!profileStore.current.kids && !profileStore.hasPin;

/** Does [action], which on a kids profile takes the parental PIN. */
export async function adultOnly(action: () => unknown): Promise<void> {
  if (profileStore.current.kids && !(await confirmPin())) return;
  action();
}

/**
 * Asks for the PIN that opens [p]: its own, else the parental one. True when it was right, or when
 * there is none. Who forgot its own gets the way out, with what it watched gone, unless [forgot]
 * says it is no time for it: someone already in the profile, whom that would throw out.
 */
export async function confirmProfilePin(p: Profile, forgot = true): Promise<boolean> {
  if (!hasOwnPin(p)) return confirmPin();
  const pin = await showPinPad(p.name ? t('enterPinOf', { name: displayName(p) }) : t('enterPinMain'), (x) => profileStore.checkProfilePin(p, x), t('wrongPin'), forgot, true);
  if (pin !== FORGOT) return pin !== null;
  await forgotProfilePin(p);
  return false;
}

const FORGOT = 'forgot'; // what the pad returns for it: never four digits

/** Whether a playlist is open with [p]: what "I forgot the PIN" wipes, that session would save again. */
function inUse(p: Profile): boolean {
  try {
    return session().library.profileId === p.id;
  } catch {
    return false; // no playlist open
  }
}

/**
 * The way out of a forgotten PIN: behind the parental one, and what the profile watched goes with
 * it, so forgetting is no way to see it. The main profile cannot go: it stays, empty and without PIN.
 */
async function forgotProfilePin(p: Profile): Promise<void> {
  if (!(await confirmPin())) return;
  const name = displayName(p);
  const sure = await showDialog<boolean>((d) => (
    <div class="dialog">
      <p class="body-large" style={{ marginTop: 0 }}>{isMain(p) ? (p.name ? t('forgotPinMain', { name }) : t('forgotPinMainUnnamed')) : t('forgotPinProfile', { name })}</p>
      <div class="actions">
        <SecondaryButton label={t('cancel')} onPressed={() => d(false)} autofocus />
        <PrimaryButton label={t('delete')} onPressed={() => d(true)} />
      </div>
    </div>
  ));
  if (!sure) return;
  if (!isMain(p)) return profileStore.remove(p.id);
  for (const playlist of playlistStore.playlists) Library.load(playlist.id, p.id).forgetAll();
  forgetProfileTraces(p.id); // its searches and picks: they tell what it watched too
  profileStore.update({ ...p, adult: false });
  profileStore.setProfilePin(p.id, null);
}

/**
 * Settings' way to the PIN of the profile in use, for whoever is in it: without the parental one,
 * which that person may not know.
 */
export async function profilePinSettings(): Promise<void> {
  const p = profileStore.current;
  if (hasOwnPin(p)) {
    if (!(await confirmProfilePin(p, false))) return;
    const remove = await showDialog<boolean>((d) => (
      <div class="dialog">
        <h2 class="title-large">{t('profilePin')}</h2>
        <div class="actions">
          <SecondaryButton label={t('cancel')} onPressed={() => d()} />
          <SecondaryButton label={t('removePin')} onPressed={() => d(true)} />
          <PrimaryButton label={t('changePin')} onPressed={() => d(false)} autofocus />
        </div>
      </div>
    ));
    if (remove === undefined) return;
    if (remove) {
      profileStore.setProfilePin(p.id, null);
      toast(t('pinRemoved'));
      return;
    }
  }
  const pin = await askNewPin();
  if (pin === null) return;
  profileStore.setProfilePin(p.id, pin);
  toast(t('pinSaved'));
}

/** Asks for a new PIN, twice. Null when cancelled. */
export async function askNewPin(title?: string): Promise<string | null> {
  const first = await showPinPad(title || t('newPin'));
  if (first === null) return null;
  return showPinPad(t('repeatPin'), (p) => p === first, t('pinMismatch'));
}

/**
 * A four-digit pad. The PIN once [check] accepts it; null when cancelled. Digits come from the
 * pad, a remote's number keys or a keyboard. With [forgot], it also offers "I forgot the PIN".
 */
export async function showPinPad(title: string, check?: (pin: string) => boolean, wrong?: string, forgot = false, limited = false): Promise<string | null> {
  const pin = await showDialog<string>((d) => <PinPad title={title} check={check} wrong={wrong} forgot={forgot} limited={limited} done={d} />);
  return pin === undefined ? null : pin;
}

const LENGTH = 4;

function PinPad({ title, check, wrong, forgot, limited, done }: { title: string; check?: (pin: string) => boolean; wrong?: string; forgot?: boolean; limited?: boolean; done: (pin?: string) => void }) {
  const [pin, setPin] = useState('');
  const [error, setError] = useState(false);
  const [wait, setWait] = useState(limited ? pinTries.secondsLeft() : 0);

  useEffect(() => {
    if (wait <= 0) return undefined;
    const id = window.setInterval(() => setWait(pinTries.secondsLeft()), 1000);
    return () => clearInterval(id);
  }, [wait > 0]);

  const type = (digit: string) => {
    if (wait > 0 || pin.length >= LENGTH) return;
    const next = pin + digit;
    setError(false);
    if (next.length < LENGTH) return setPin(next);
    const ok = !check || check(next);
    if (limited) ok ? pinTries.passed() : pinTries.failed();
    if (ok) return done(next);
    setPin('');
    setError(true);
    if (limited) setWait(pinTries.secondsLeft());
  };

  const erase = () => setPin(pin.slice(0, -1));

  // Number keys, where the remote or a keyboard has them; a keyboard's Backspace and Delete erase
  useKeys((e) => {
    if (e.keyCode >= 48 && e.keyCode <= 57) return type(String(e.keyCode - 48)), true;
    if (e.keyCode >= 96 && e.keyCode <= 105) return type(String(e.keyCode - 96)), true;
    if (e.keyCode === 8 || e.keyCode === 46) return erase(), true;
    return false;
  });

  // [label] says what an icon alone does, for the TV's Voice Guide
  const key = (k: string, content: ComponentChildren, onTap: () => void, autofocus = false, label?: string) => (
    <div key={k} style={{ padding: '0.5rem' }}>
      <Focusable radius={12} scale={1.06} onTap={onTap} autofocus={autofocus} label={label}>
        <div class="row" style={{ width: '6.4rem', height: '5.2rem', justifyContent: 'center', background: 'var(--surface-high)', fontSize: 'calc(2.2rem * var(--text))', fontWeight: 600 }}>
          {content}
        </div>
      </Focusable>
    </div>
  );
  return (
    <div class="dialog" style={{ minWidth: 0, background: 'var(--surface)', textAlign: 'center' }}>
      <h2 class="title-large">{title}</h2>
      {/* Voice Guide says how many digits are in, never which, as they change */}
      <div class="row" role="status" aria-live="polite" aria-label={t('pinDigits', { count: pin.length, total: 4 })} style={{ justifyContent: 'center', marginTop: '1.8rem' }}>
        {[0, 1, 2, 3].map((i) => (
          <div key={i} style={{ width: '1.4rem', height: '1.4rem', margin: '0 0.8rem', borderRadius: '50%', border: '0.15rem solid var(--text)', background: i < pin.length ? 'var(--text)' : 'transparent' }} />
        ))}
      </div>
      <div role="alert" style={{ height: '3rem', lineHeight: '3rem', color: 'var(--error)' }}>{wait > 0 ? t('pinWait', { seconds: wait }) : error ? wrong || '' : ''}</div>
      {[['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']].map((row) => (
        <div key={row[0]} class="row" style={{ justifyContent: 'center' }}>
          {row.map((d) => key(d, d, () => type(d), d === '1'))}
        </div>
      ))}
      <div class="row" style={{ justifyContent: 'center' }}>
        {key('cancel', <Icon icon="close_rounded" size={24} />, () => done(), false, t('cancel'))}
        {key('0', '0', () => type('0'))}
        {key('back', <Icon icon="backspace_outlined" size={24} />, erase, false, t('backspace'))}
      </div>
      {forgot && (
        <div class="row" style={{ justifyContent: 'center', marginTop: '0.8rem' }}>
          <SecondaryButton label={t('forgotPin')} onPressed={() => done(FORGOT)} />
        </div>
      )}
    </div>
  );
}
