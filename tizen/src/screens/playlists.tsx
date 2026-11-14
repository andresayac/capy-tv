// Entry screen: the saved playlists, and adding, editing, combining and deleting them
// (app/lib/ui/playlists_screen.dart, in its wide layout: welcome left, playlists right).
import { useEffect, useRef, useState } from 'preact/hooks';
import { displayAddress, applyLiveFormat, combinePlaylists, createPlaylist, Playlist, PlaylistType, playlistStore, sameAccount, verifyPlaylist, xtreamLink } from '../data/playlists';
import { settings } from '../data/settings';
import { accountRefused, errorText } from '../data/source';
import { t } from '../i18n';
import { openPlaylistId, session } from '../session';
import { focus } from '../ui/focus';
import {
  AppBar,
  AppChip,
  AppLogo,
  Focusable,
  Icon,
  IconButton,
  PrimaryButton,
  SecondaryButton,
  Spinner,
  TextField,
  useNotifier,
} from '../ui/components';
import { Backdrop, PosterBackdrop } from '../ui/backdrop';
import { ListProgressText } from '../ui/list_loading';
import { popToRoot, push, showDialog, toast, useOnTop } from '../ui/router';
import { profileStore } from '../data/profiles';
import { adultActionsHidden, confirmPin, displayName, openProfileSettings, ProfileAvatar, takeReopenAfterProfile } from './profiles';
import { syncService } from '../sync/service';
import { openSync, syncIcon } from './sync';
import { ConnectScreen } from './connect';
import { castRequest } from '../sync/cast';
import { openPlaylist, PlaylistUpdate, takePlaylistUpdate } from './home';

/** Leaves whatever is open and goes back to "Who's watching?". */
export function switchProfile(): void {
  popToRoot();
  profileStore.switchProfile();
}

/** Playlists opened so far: a later one may open while an earlier one closes. */
let opened = 0;
/** The playlist open now, until its Home has closed and ended its session. */
let running: Promise<void> = Promise.resolve();

export function PlaylistsScreen() {
  useNotifier(playlistStore);
  useNotifier(profileStore);
  useNotifier(syncService);
  const [opening, setOpening] = useState<string | null>(null);
  const combineBox = useRef<HTMLDivElement>(null);
  const first = useRef(true);
  const onTop = useOnTop(); // a screen opened over this one meanwhile has the remote
  const list = playlistStore.playlists;
  const providers = list.filter((p) => p.type !== 'combined');

  // A profile picked from inside a playlist: open it again, for that profile. Else, as this screen
  // first shows, one playlist is nothing to choose; coming back here is the way to add, change or
  // delete it, and one that failed to open stays here too
  useEffect(() => {
    // "Update list" closed it to open it anew: from here, so this card shows it and no second press
    // opens it twice
    const update = takePlaylistUpdate();
    const updated = update && list.filter((x) => x.id === update.id)[0];
    const id = updated ? null : takeReopenAfterProfile();
    const p = id && list.filter((x) => x.id === id)[0];
    if (updated) open(updated, update!);
    else if (p) open(p);
    else if (first.current && onTop && list.length === 1) open(list[0]);
    first.current = false;
  });

  // Something another device sent to play here, in a playlist that is not the one open (that
  // one's Home plays it): back here, and that playlist opens, its Home playing it
  useEffect(
    () =>
      castRequest.listen(() => {
        const r = castRequest.value;
        if (!r || openPlaylistId() === r.playlistId) return;
        const p = playlistStore.playlists.filter((x) => x.id === r.playlistId)[0];
        if (!p) return;
        popToRoot();
        open(p);
      }),
  );

  // The live format setting applies right away to the open playlist's next channel URLs
  useEffect(
    () =>
      settings.listen(() => {
        try {
          applyLiveFormat(session().source, settings.liveFormat);
        } catch {
          // No playlist open: the next one opens with it
        }
      }),
    [],
  );

  const add = async () => {
    if (!(await confirmPin())) return;
    const p = await push<Playlist>((done) => <AddPlaylistScreen done={done} />);
    if (!p) return;
    // The same account again: its new password, not a second list of it
    const had = playlistStore.playlists.filter((x) => sameAccount(x, p))[0];
    if (had) {
      playlistStore.update({ ...had, password: p.password });
      toast(t('accountAlreadyAdded'));
      return;
    }
    playlistStore.add(p);
    // A second provider, and none combined yet: say what they can do together. A snack bar's
    // action is out of a remote's reach, so the button that does it takes the focus
    const all = playlistStore.playlists;
    if (all.filter((x) => x.type !== 'combined').length >= 2 && !all.some((x) => x.type === 'combined')) {
      toast(t('combineSuggestion'), 8000);
      setTimeout(() => {
        const button = combineBox.current && combineBox.current.querySelector<HTMLElement>('.f');
        if (button) focus(button);
      }, 0);
    }
  };

  /** A phone types the playlist instead of the remote; the screen closes once it arrives. */
  const addFromPhone = async () => {
    if (await confirmPin()) push((done) => <ConnectScreen tab="add" closeOnPlaylist done={done} />);
  };

  const edit = async (p: Playlist) => {
    if (!(await confirmPin())) return;
    const edited = await push<Playlist>((done) =>
      p.type === 'combined' ? <CombineScreen initial={p} done={done} /> : <AddPlaylistScreen initial={p} done={done} />,
    );
    if (edited) playlistStore.update(edited);
  };

  const combine = async () => {
    if (!(await confirmPin())) return;
    const p = await push<Playlist>((done) => <CombineScreen done={done} />);
    if (p) playlistStore.add(p);
  };

  const remove = async (p: Playlist) => {
    if (!(await confirmPin())) return;
    const ok = await showDialog<boolean>((done) => (
      <div class="dialog">
        <h2 class="title-large">{t('deletePlaylistQuestion', { name: p.name })}</h2>
        {syncService.status !== 'off' && <p class="muted">{t('deletePlaylistEverywhere')}</p>}
        <div class="actions">
          <SecondaryButton label={t('cancel')} onPressed={() => done(false)} autofocus />
          <PrimaryButton label={t('delete')} onPressed={() => done(true)} />
        </div>
      </div>
    ));
    if (ok) playlistStore.remove(p);
  };

  const open = (p: Playlist, update?: PlaylistUpdate) => {
    const turn = ++opened;
    setOpening(p.id);
    // The same playlist opened again for another profile waits for the Home closing to end its
    // session, so that one cannot end the new one
    running = running.then(async () => {
      try {
        await openPlaylist(p, update);
      } catch (e) {
        toast(errorText(e));
      } finally {
        if (turn === opened) setOpening(null);
      }
    });
  };

  const subtitle = (p: Playlist) => {
    if (profileStore.current.kids && p.type !== 'combined') return '';
    switch (p.type) {
      case 'xtream': return `${p.username} · ${displayAddress(p)}`;
      case 'm3u': return displayAddress(p);
      default:
        return p.members
          .map((id) => (list.filter((x) => x.id === id)[0] || { name: '' }).name)
          .filter(Boolean)
          .join(' + ');
    }
  };

  return (
    <Backdrop>
    <div class="row" style={{ height: '100%', padding: '0 9.6rem' }}>
      <div style={{ flex: 5, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <AppLogo size={56} />
        {/* Whose favorites and history these are, and the way to someone else's */}
        {profileStore.profiles.length > 1 && (
          <div style={{ marginTop: '2rem' }}>
            {/* Not while a playlist logs in: "Who's watching?" takes this screen's place, and Home
                would still open over it for the profile it left (Flutter's open stops unmounted) */}
            <Focusable radius={999} scale={1.03} onTap={opening ? undefined : switchProfile} class="inline">
              <div class="row" style={{ background: 'var(--surface)', padding: '0.6rem 1.4rem 0.6rem 0.6rem' }}>
                <ProfileAvatar profile={profileStore.current} size={30} />
                <span style={{ marginLeft: '1rem', fontWeight: 600 }}>{displayName(profileStore.current)}</span>
                <span class="muted" style={{ marginLeft: '0.8rem' }}>
                  <Icon icon="swap_horiz_rounded" size={18} />
                </span>
              </div>
            </Focusable>
          </div>
        )}
        <h1 class="display-small" style={{ marginTop: '2.8rem' }}>{t('welcomeTitle')}</h1>
        <p class="body-large muted" style={{ marginTop: '1.2rem' }}>{t('welcomeBody')}</p>
      </div>
      <div style={{ width: '5.6rem' }} />
      <div style={{ flex: 6, maxHeight: '100%', overflowY: 'auto', padding: '3.2rem 0.8rem', boxSizing: 'border-box' }}>
        {list.length > 0 && <h2 class="title-large" style={{ marginBottom: '1.2rem' }}>{t('playlists')}</h2>}
        {list.map((p, i) => (
          <div key={p.id} class="row" style={{ marginBottom: '1.2rem' }}>
            <Focusable class="grow" radius={20} scale={1.02} autofocus={i === 0} onTap={opening ? undefined : () => open(p)}>
              <div class="row panel" style={{ borderRadius: '2rem', padding: '1.4rem 1.6rem' }}>
                <div class="row" style={{ width: '4.4rem', height: '4.4rem', justifyContent: 'center', background: 'var(--surface-high)', borderRadius: '1.4rem' }}>
                  <Icon icon={p.type === 'xtream' ? 'dns_rounded' : p.type === 'm3u' ? 'playlist_play_rounded' : 'layers_rounded'} size={24} />
                </div>
                <div class="grow" style={{ marginLeft: '1.4rem' }}>
                  <div style={{ fontWeight: 700, fontSize: 'calc(1.6rem * var(--text))' }}>{p.name}</div>
                  {/* While it opens, how much of its list has come (an M3U downloads here) */}
                  <div class="muted ellipsis" style={{ fontSize: 'calc(1.3rem * var(--text))' }}>{opening === p.id ? <ListProgressText or={subtitle(p)} /> : subtitle(p)}</div>
                </div>
              </div>
            </Focusable>
            {/* Flutter puts these inside the card; on a remote they are their own stops. While the
                playlist opens, the spinner takes Edit's place: it cannot be edited mid-login */}
            {opening === p.id ? (
              <div class="row" style={{ width: '4.6rem', height: '4.6rem', justifyContent: 'center', flex: 'none' }}>
                <Spinner />
              </div>
            ) : (
              !adultActionsHidden() && <IconButton icon="edit_outlined" label={t('editPlaylist')} onPressed={() => edit(p)} />
            )}
            {!adultActionsHidden() && <IconButton icon="delete_outline_rounded" label={t('delete')} onPressed={() => remove(p)} />}
          </div>
        ))}
        <div class="wrap" style={{ marginTop: '0.2rem' }}>
          {/* On a TV the phone is the easy way to type a server and a password */}
          {list.length === 0 ? (
            <PrimaryButton icon="qr_code_rounded" label={t('addFromPhone')} onPressed={addFromPhone} autofocus />
          ) : (
            <SecondaryButton icon="qr_code_rounded" label={t('addFromPhone')} onPressed={addFromPhone} />
          )}
          <SecondaryButton icon="add_rounded" label={t('addPlaylist')} onPressed={add} />
          {providers.length >= 2 && !adultActionsHidden() && (
            <div ref={combineBox}>
              <SecondaryButton icon="layers_outlined" label={t('combinePlaylists')} onPressed={combine} />
            </div>
          )}
          {!adultActionsHidden() && <SecondaryButton icon="people_outline_rounded" label={t('profiles')} onPressed={openProfileSettings} />}
          {/* On a new TV, signing in brings the lists from the other devices */}
          <SecondaryButton icon={syncIcon()} label={t('sync')} onPressed={openSync} />
        </div>
      </div>
    </div>
    </Backdrop>
  );
}

/** Form for a new playlist, or to change [initial]; checks it against the server before saving. */
export function AddPlaylistScreen({ initial, done }: { initial?: Playlist; done: (p?: Playlist) => void }) {
  const [type, setType] = useState<PlaylistType>(initial ? initial.type : 'xtream');
  const [name, setName] = useState(initial ? initial.name : '');
  const [url, setUrl] = useState(initial ? initial.url : '');
  const [user, setUser] = useState(initial ? initial.username : '');
  const [pass, setPass] = useState(initial ? initial.password : '');
  const [fromLink, setFromLink] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [missing, setMissing] = useState(false);
  const link = useRef<string | null>(null); // the provider's link the fields came from

  /**
   * The account taken from a provider's link did not check out, and not because the panel said it
   * is no good (its API closed, or no Xtream panel behind it): the link itself is tried as the M3U
   * list it also is. The playlist saved that way, or null.
   */
  const asList = async (p: Playlist, error: unknown): Promise<Playlist | null> => {
    const x = link.current ? xtreamLink(link.current) : null;
    if (!x || p.type !== 'xtream' || accountRefused(error)) return null;
    if (p.url !== x.server || p.username !== x.username || p.password !== x.password) return null; // changed since
    const list: Playlist = { id: p.id, name: p.name, type: 'm3u', url: link.current!, username: '', password: '', members: [] };
    try {
      await verifyPlaylist(list);
      return list;
    } catch {
      return null;
    }
  };

  // A pasted provider link: its server, user and password go to their fields
  /** A provider's link fills the fields; null when [text] is none. */
  const fillFromLink = (text: string) => {
    const x = xtreamLink(text);
    if (!x) return null;
    link.current = text.trim();
    setType('xtream');
    setUrl(x.server);
    setUser(x.username);
    setPass(x.password);
    setFromLink(true);
    return x;
  };

  // When the link comes at once (pasted, or sent from the phone), not while typed a letter at a
  // time: the first letter of a password would be taken for all of it. Typed, it is read on saving
  const urlChanged = (text: string) => {
    const before = url;
    setUrl(text);
    if (text.length - before.length > 1) fillFromLink(text);
  };

  const save = async () => {
    if (busy) return; // pressed again while it checks (a disabled button would lose the remote)
    // A link typed whole: its fields, now and for this save (state updates come after)
    const link = fillFromLink(url);
    const f = link ? { type: 'xtream' as const, url: link.server, user: link.username, pass: link.password } : { type, url, user, pass };
    const xtream = f.type === 'xtream';
    if (!f.url.trim() || (xtream && (!f.user.trim() || !f.pass.trim()))) {
      setMissing(true);
      return;
    }
    const created = createPlaylist({ type: f.type, url: f.url, name, username: xtream ? f.user : '', password: xtream ? f.pass : '' });
    // An edit here keeps what only Flutter's form sets
    const p: Playlist = initial ? { ...created, id: initial.id, extra: initial.extra } : created;
    if (initial && initial.userAgent && p.type === 'xtream') p.userAgent = initial.userAgent;
    // Renamed only: nothing to check, and a provider down right now would not let it be saved
    if (initial && initial.type === p.type && initial.url === p.url && initial.username === p.username && initial.password === p.password && initial.userAgent === p.userAgent) return done(p);
    setBusy(true);
    setError(null);
    try {
      await verifyPlaylist(p);
      done(p);
    } catch (e) {
      const list = await asList(p, e);
      if (list) return done(list);
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const required = (v: string) => (missing && !v.trim() ? t('required') : null);
  return (
    <PosterBackdrop>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        <AppBar title={initial ? t('editPlaylist') : t('addPlaylist')} />
        <div style={{ flex: 1, overflowY: 'auto' }}>
          <div style={{ width: '52rem', margin: '0 auto', padding: '2rem' }}>
            <div class="wrap">
              <AppChip label={t('playlistTypeXtream')} icon="dns_outlined" selected={type === 'xtream'} autofocus onTap={() => setType('xtream')} />
              <AppChip label={t('playlistTypeM3u')} icon="link_rounded" selected={type === 'm3u'} onTap={() => setType('m3u')} />
            </div>
            <div style={{ height: '2rem' }} />
            <TextField label={t('playlistName')} value={name} onChange={setName} next />
            <div style={{ height: '1.2rem' }} />
            <TextField
              label={type === 'xtream' ? t('serverUrl') : t('m3uUrl')}
              hint={type === 'xtream' ? 'http://example.com:8080' : 'http://example.com/list.m3u'}
              value={url}
              onChange={urlChanged}
              inputType="url"
              next={type === 'xtream'}
              onSubmit={type === 'xtream' ? undefined : save}
              // Providers send a link with everything in it: pasting it is enough
              help={fromLink ? t('filledFromLink') : t('pasteLinkHint')}
              error={required(url)}
            />
            {type === 'xtream' && (
              <div>
                <div style={{ height: '1.2rem' }} />
                <TextField label={t('username')} value={user} onChange={setUser} next error={required(user)} />
                <div style={{ height: '1.2rem' }} />
                <TextField label={t('password')} value={pass} onChange={setPass} password onSubmit={save} error={required(pass)} />
              </div>
            )}
            {error && <p style={{ color: 'var(--error)', marginTop: '1.6rem' }}>{error}</p>}
            <div style={{ marginTop: '2.4rem' }}>
              {/* The button stays while it checks, the progress beside it: the remote stays on it, and
                  after an error OK tries again rather than landing at the top of the form */}
              <div class="row">
                <PrimaryButton icon="check_rounded" label={t('save')} onPressed={save} />
                {busy && (
                  <div class="row" style={{ marginLeft: '1.6rem' }}>
                    <Spinner size={18} />
                    {/* An M3U comes whole to be checked: how much of it has come */}
                    <span style={{ marginLeft: '1.2rem' }}>
                      <ListProgressText or={t('connecting')} />
                    </span>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>
      </div>
    </PosterBackdrop>
  );
}

/**
 * Joins playlists of several providers into one: their catalogs together, each title once with
 * every provider's copy. The playlists stay as they are; or changes [initial]'s.
 */
export function CombineScreen({ initial, done }: { initial?: Playlist; done: (p?: Playlist) => void }) {
  const [name, setName] = useState(initial ? initial.name : '');
  const [chosen, setChosen] = useState<string[]>(initial ? initial.members.slice() : []); // in the order picked
  const all = playlistStore.playlists.filter((p) => p.type !== 'combined');

  // One taken out of a saved playlist leaves its place empty (''), and one put back takes it again:
  // ids saved in favorites and history carry those places
  const before = initial ? initial.members : [];
  const toggle = (id: string) =>
    setChosen((c) => {
      const at = c.indexOf(id);
      const was = before.indexOf(id);
      const next = c.slice();
      if (at >= 0) {
        if (at < before.length) next[at] = '';
        else next.splice(at, 1);
      } else if (was >= 0 && was < next.length && !next[was]) {
        next[was] = id;
      } else {
        next.push(id);
      }
      return next;
    });
  const picked = chosen.filter(Boolean).length;
  /** Where [id] goes among those picked, from 0. */
  const placeOf = (id: string) => chosen.slice(0, chosen.indexOf(id)).filter(Boolean).length;

  const save = () => {
    const names = chosen.map((id) => (all.filter((p) => p.id === id)[0] || { name: '' }).name).filter(Boolean);
    // Empty places at the end hold no one's ids
    const members = chosen.slice();
    while (members.length && !members[members.length - 1]) members.pop();
    // An edit keeps what only Flutter's form sets
    done({ ...combinePlaylists(name.trim() ? name : names.join(' + '), members, initial && initial.id), extra: initial && initial.extra });
  };

  return (
    <PosterBackdrop>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        <AppBar title={t('combinePlaylists')} />
        <div style={{ flex: 1, overflowY: 'auto' }}>
          <div style={{ width: '56rem', margin: '0 auto', padding: '2rem' }}>
            <p class="muted" style={{ lineHeight: 1.5, marginTop: 0 }}>{t('combineBody')}</p>
            <div style={{ height: '2rem' }} />
            {all.map((p, i) => {
              const n = chosen.indexOf(p.id) >= 0 ? placeOf(p.id) : -1;
              return (
                <div key={p.id} style={{ marginBottom: '1rem' }}>
                  <Focusable radius={16} scale={1.02} autofocus={i === 0} onTap={() => toggle(p.id)}>
                    <div class="row panel" style={{ borderRadius: '1.6rem', padding: '1.2rem 1.6rem' }}>
                      <span style={{ color: n >= 0 ? 'var(--text)' : 'var(--muted)' }}>
                        <Icon icon={n >= 0 ? 'check_box_rounded' : 'check_box_outline_blank_rounded'} size={24} />
                      </span>
                      <div class="grow" style={{ marginLeft: '1.4rem', fontWeight: 700, fontSize: 'calc(1.6rem * var(--text))' }}>{p.name}</div>
                      {/* The order picked: on equal speed, the first one's copy plays */}
                      {n >= 0 && <span class="muted" style={{ fontWeight: 700 }}>{n + 1}</span>}
                    </div>
                  </Focusable>
                </div>
              );
            })}
            <div style={{ height: '1.2rem' }} />
            <TextField label={t('playlistName')} value={name} onChange={setName} />
            <div style={{ marginTop: '2.4rem' }}>
              <PrimaryButton icon="check_rounded" label={t('save')} onPressed={picked >= 2 ? save : null} />
            </div>
          </div>
        </div>
      </div>
    </PosterBackdrop>
  );
}
