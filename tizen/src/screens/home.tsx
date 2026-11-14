// A playlist once opened (app/lib/ui/home_screen.dart): the side rail and its tabs.
import { useEffect, useRef, useState } from 'preact/hooks';
import { channelRef } from '../data/library';
import { CatalogData } from '../data/catalog';
import { openPlaylist as openSource, Playlist } from '../data/playlists';
import { AccountInfo, Category, ContentSource, EpgEntry, errorText, LiveChannel } from '../data/source';
import { categoryLabel } from '../ui/labels';
import { posterWall } from '../data/poster_wall';
import { profileStore, showsAdult } from '../data/profiles';
import { settings } from '../data/settings';
import { CombinedSource } from '../data/combined';
import { XtreamSource } from '../data/xtream';
import { t } from '../i18n';
import { Keys } from '../platform/tv';
import { AppLogo, CapyMessage, capyMoodForError, Focusable, Icon, IconButton, SecondaryButton, useNotifier } from '../ui/components';
import { activeLayer, focus, focusables, focused, noteUserAction } from '../ui/focus';
import { imageFailed, imageLeftAlone, imageTurn } from '../ui/image_queue';
import { ListLoading } from '../ui/list_loading';
import { popTo, popToRoot, push, screenCount, toast, useBack } from '../ui/router';
import { TabInSight, useInSight } from '../ui/sight';
import { RAIL_WIDTH, RailInset, useRailInset } from '../ui/tab';
import { useRowWindow } from '../ui/window';
import { endSession, session, startSession } from '../session';
import { remoteSearch } from '../remote/now';
import { CatalogTab } from './catalog';
import { showChannelSheet } from './channel';
import { GuideScreen, NowOnAir } from './guide';
import { AccountScreen } from './account';
import { libraryShows } from '../data/kids';
import { CAST_FOR, castRequest } from '../sync/cast';
import { HomeTab, playFromLibrary } from './hometab';
import { SearchTab } from './search';
import { playChannels } from './player';

/** What a catalog had, by id: all "Update list" keeps of the old one, to say what is new. */
interface KnownIds {
  movies: Set<string>;
  series: Set<string>;
  channels: Set<string>;
}

export interface PlaylistUpdate {
  id: string;
  /** Null when the old catalog never came, and what is new cannot be told. */
  before: KnownIds | null;
}

let pendingUpdate: PlaylistUpdate | null = null;

/** The playlist closed to be opened anew, if any: PlaylistsScreen opens it, guarded as any other. */
export function takePlaylistUpdate(): PlaylistUpdate | null {
  const update = pendingUpdate;
  pendingUpdate = null;
  return update;
}

/**
 * Its lists and guide again from the provider, whatever their age ("Update list"): the playlist is
 * closed and opened anew, as the old catalog and the new one do not both fit in a TV. Then how many
 * titles and channels are new.
 */
export function updatePlaylist(p: Playlist): void {
  const ids = (list: { id: string }[]) => new Set(list.map((x) => x.id));
  const old = session().catalog.loaded;
  pendingUpdate = { id: p.id, before: old ? { movies: ids(old.movies), series: ids(old.series), channels: ids(old.live) } : null };
  popToRoot();
  toast(t('listUpdating'));
}

/** Logs in and shows the playlist's Home. Throws (a SourceException) when it does not open. */
export async function openPlaylist(p: Playlist, update?: PlaylistUpdate): Promise<void> {
  const source = await openSource(p, settings.liveFormat, !!update);
  source.hideAdult = !showsAdult(profileStore.current);
  source.kidsOnly = !!profileStore.current.kids;
  // No answer from the panel with its lists on the TV: those open, as when they cannot be updated
  const account = source instanceof XtreamSource ? await source.loginOrSaved() : undefined;
  const s = startSession(p, source, account);
  warnExpiry(p, account);
  // Quietly, the catalog's best posters for the screens outside a playlist; only without adult content
  s.catalog.load().then((data) => {
    posterWall.remember(data, source.hideAdult);
    if (!update) return;
    const missing = notUpdated(source, p.name);
    const before = update.before;
    update.before = null; // this frame waits for Home to close: not kept all that time
    toast(missing.length ? t('listPartsMissing', { names: missing.join(', ') }) : before ? updated(before, data) : t('listUpdatedPlain'));
  }, () => {});
  await push(() => <HomeScreen source={source} />);
  // Only its own: the same playlist opened again for another profile has a session of its own
  endSession(s);
}

/** The provider's service ending within a week: said once a day, so it is renewed in time. Nothing is limited; kids are not told. */
function warnExpiry(p: Playlist, account?: AccountInfo): void {
  const ends = account && account.expires;
  if (!ends || profileStore.current.kids) return;
  const left = ends.getTime() - Date.now();
  if (left < 0 || left > 7 * 86400000) return;
  const key = `expiryTold.${p.id}`;
  const today = new Date().toISOString().slice(0, 10);
  try {
    if (localStorage.getItem(key) === today) return;
    localStorage.setItem(key, today);
  } catch {
    // No storage: said every time, then
  }
  const date = ends.toLocaleDateString(undefined, { month: 'long', day: 'numeric' });
  setTimeout(() => toast(t('serviceEndsSoon', { name: p.name, date })), 1500);
}

/** Who did not answer an "Update list", by name: what shows of them is the copy there was. */
function notUpdated(source: ContentSource, name: string): string[] {
  if (!(source instanceof CombinedSource)) return source.notUpdated ? [name] : [];
  return source.failed.concat(source.parts.filter((x) => x.source.notUpdated).map((x) => x.name));
}

/** What is new in [after] that [before] did not have, as "List updated. New: …". */
function updated(before: KnownIds, after: CatalogData): string {
  const added = (known: Set<string>, now: { id: string }[]) => now.filter((x) => !known.has(x.id)).length;
  return t('listUpdated', {
    movies: added(before.movies, after.movies),
    series: added(before.series, after.series),
    channels: added(before.channels, after.live),
  });
}

const HOME = 0;
const MOVIES = 1;
const SERIES = 2;
const LIVE = 3;
const SEARCH = 4;

const PX = 20; // px in a rem: html's font-size (ui/theme.css)

/** Whether [el] can take the remote inside [root]: still there, shown, with a size, and enabled. */
function usable(root: HTMLElement, el: HTMLElement | null | undefined): el is HTMLElement {
  if (!el || !root.contains(el) || el.offsetParent === null || el.hasAttribute('data-disabled')) return false;
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0;
}

/** Where a tab starts: its first element marked data-autofocus that can take the remote. */
function startOf(pane: HTMLElement): HTMLElement | null {
  const marked = pane.querySelectorAll<HTMLElement>('.f[data-autofocus]');
  for (let i = 0; i < marked.length; i++) if (usable(pane, marked[i])) return marked[i];
  return null;
}

function HomeScreen({ source }: { source: ContentSource }) {
  const tabs = [
    { icon: 'home_rounded', label: t('home') },
    { icon: 'movie_rounded', label: t('movies') },
    { icon: 'video_library_rounded', label: t('series') },
    { icon: 'live_tv_rounded', label: t('liveTv') },
    { icon: 'search_rounded', label: t('search') },
  ];
  const [selected, setSelected] = useState(HOME);
  const [opened, setOpened] = useState<number[]>([HOME]);
  const shown = useRef(HOME); // for the listeners, which outlive a render
  shown.current = selected;
  const panes = useRef<(HTMLDivElement | null)[]>([]);
  const rail = useRef<HTMLDivElement>(null);

  // Its profile deleted on another device (by sync) while its playlist is open here: the playlist
  // closes, as when it is deleted here, so nothing more is saved for it; whoever is here picks again
  useEffect(() => {
    const profile = profileStore.current.id;
    return profileStore.listen(() => {
      if (!profileStore.profiles.some((p) => p.id === profile)) popToRoot();
    });
  }, []);
  // Each tab remembers what was focused in it, as Flutter's FocusScope per tab does
  const lastIn = useRef<(HTMLElement | null)[]>([]);

  // A tab just chosen takes the remote as soon as it has something to take it with: a tab seen
  // for the first time is often still loading, and then the remote would be left on the rail
  const pending = useRef(-1);
  const watcher = useRef<MutationObserver | null>(null);
  const stop = () => {
    pending.current = -1;
    if (watcher.current) watcher.current.disconnect();
    watcher.current = null;
  };
  const step = (first: boolean) => {
    const i = pending.current;
    const pane = panes.current[i];
    const layer = activeLayer();
    // Another tab chosen since, or a screen or dialog over Home: not for now
    if (i < 0 || i !== shown.current || !pane || !layer || !layer.contains(pane)) return stop();
    const current = focused();
    // Back where it was there
    if (first && usable(pane, lastIn.current[i])) {
      focus(lastIn.current[i]!);
      return stop();
    }
    // Else where it starts
    const start = startOf(pane);
    if (start) {
      if (start !== current) focus(start);
      return stop();
    }
    // Nothing marked yet (the hero still loading): its first item meanwhile, and its start once
    // it appears, unless a key is pressed first
    if (!current || !pane.contains(current)) {
      const any = focusables(pane)[0];
      if (any) focus(any);
    }
    if (!watcher.current) {
      watcher.current = new MutationObserver(() => step(false));
      watcher.current.observe(pane, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-autofocus', 'data-disabled'] });
    }
  };
  /** Takes the remote into tab [i], once it is shown. */
  const enter = (i: number) => {
    stop();
    pending.current = i;
    setTimeout(() => step(true), 0);
  };

  /** Shows tab [i] and moves the remote into it: back to what was focused there, or its start. */
  const select = (i: number) => {
    setSelected(i);
    setOpened((o) => (o.indexOf(i) < 0 ? o.concat([i]) : o));
    enter(i);
  };
  const selectRef = useRef(select);
  selectRef.current = select;
  // Back from another tab goes to Home first, rather than out of the playlist
  useBack(() => {
    if (shown.current === HOME) return false;
    selectRef.current(HOME);
    return true;
  });

  // Something another device sent to play here, in this playlist: whatever is open over Home
  // closes, and it plays from where it was there
  useEffect(() => {
    const depth = screenCount();
    const { playlist, catalog } = session();
    const take = () => {
      const r = castRequest.value;
      if (!r || r.playlistId !== playlist.id) return;
      castRequest.clear();
      // Sent a while ago, it waited behind "Who's watching?": this may be someone else
      if (Date.now() - r.at > CAST_FOR) return;
      if (!libraryShows(r.ref, catalog.loaded || undefined, source)) return toast(t('castNotAllowed'));
      popTo(depth);
      // What was open closes and something else plays: say where it came from
      if (r.from) toast(t('sentFrom', { device: r.from }));
      playFromLibrary(r.ref, r.position);
    };
    take();
    return castRequest.listen(take);
  }, []);

  useEffect(() => {
    // Any key is the user acting: a tab still loading no longer takes the remote from them
    document.addEventListener('keydown', stop, true);
    // Text typed on the phone with no field to put it in: Search, with it
    const unlisten = remoteSearch.listen(() => selectRef.current(SEARCH));
    return () => {
      document.removeEventListener('keydown', stop, true);
      unlisten();
      stop();
    };
  }, []);

  // What starts under the see-through rail (a loading placeholder as wide as the tab) has nothing
  // to its left but the rail, which the nearest-in-line search never finds from there: Left goes
  // to it, as Flutter's traversal does at a tab's edge
  const leftToRail = (e: KeyboardEvent) => {
    if (e.keyCode !== Keys.left) return;
    const el = e.target as HTMLElement;
    const layer = activeLayer();
    if (!el.classList.contains('f') || !layer || !layer.contains(el) || !rail.current) return;
    if (el.getBoundingClientRect().left >= RAIL_WIDTH * PX) return;
    const item = rail.current.querySelectorAll<HTMLElement>('.f')[shown.current];
    if (!item) return;
    focus(item);
    noteUserAction();
    e.preventDefault();
    e.stopPropagation();
  };

  const body = (i: number) =>
    i === HOME ? (
      <HomeTab onBrowse={select} />
    ) : i === MOVIES ? (
      <CatalogTab kind="movies" />
    ) : i === SERIES ? (
      <CatalogTab kind="series" />
    ) : i === LIVE ? (
      <LiveTab source={source} />
    ) : (
      <SearchTab />
    );

  return (
    <div style={{ position: 'relative', height: '100%' }}>
      {/* Over the tabs, so it can open without moving them; first, so the remote starts on it */}
      <SideRail box={rail} tabs={tabs} selected={selected} onSelect={select} onEnter={() => enter(shown.current)} />
      <div style={{ position: 'absolute', left: 0, top: 0, right: 0, bottom: 0, zIndex: 0 }}>
        {/* Each tab stays mounted once opened, as Flutter keeps it alive */}
        {tabs.map((_, i) => {
          // Home, Movies and Series go under the rail, their artwork edge to edge; Live TV and
          // Search keep clear of it, as Flutter's SafeArea does
          const bleeds = i <= SERIES;
          return (
            <div
              key={i}
              ref={(el) => {
                panes.current[i] = el;
              }}
              onFocusIn={(e) => {
                const el = e.target as HTMLElement;
                if (el.classList.contains('f')) lastIn.current[i] = el;
              }}
              onKeyDown={bleeds ? leftToRail : undefined}
              style={{
                position: 'absolute',
                left: 0,
                top: 0,
                right: 0,
                bottom: 0,
                paddingLeft: bleeds ? 0 : `${RAIL_WIDTH}rem`,
                display: i === selected ? '' : 'none',
              }}
            >
              {/* Out of sight, a tab neither animates nor plays trailers (Flutter's TickerMode) */}
              <TabInSight.Provider value={i === selected}>
                <RailInset.Provider value={bleeds ? RAIL_WIDTH : 0}>{opened.indexOf(i) >= 0 && body(i)}</RailInset.Provider>
              </TabInSight.Provider>
            </div>
          );
        })}
      </div>
    </div>
  );
}

/**
 * The side rail over the tabs: on a TV as on a computer (_SideNav), the logo on top and each icon
 * with its name under it, a little closer together to fit 540 dp. It never opens.
 */
function SideRail(p: {
  box: { current: HTMLDivElement | null };
  tabs: { icon: string; label: string }[];
  selected: number;
  onSelect: (i: number) => void;
  onEnter: () => void;
}) {
  const rail = p.box;
  const shown = useRef(p.selected);
  shown.current = p.selected;
  const inRail = useRef(false);

  const items = (): HTMLElement[] => (rail.current ? Array.prototype.slice.call(rail.current.querySelectorAll('.f')) : []);

  const onIn = (e: FocusEvent) => {
    if (inRail.current) return;
    inRail.current = true;
    // Coming in from anywhere else, the remote lands on the current section, not on whichever
    // item happens to be level with where it left
    const item = items()[shown.current];
    if (item && e.target !== item) focus(item);
  };
  const onOut = (e: FocusEvent) => {
    const to = e.relatedTarget as Node | null;
    if (to && rail.current && rail.current.contains(to)) return;
    inRail.current = false;
  };
  // The arrows keep to its items, and Right goes into the tab shown, where it was left (Flutter's
  // traversal targets the tab's scope)
  const onKey = (e: KeyboardEvent) => {
    const el = e.target as HTMLElement;
    const layer = activeLayer();
    if (!layer || !layer.contains(el)) return; // a screen or dialog over Home has the keys
    const all = items();
    const at = all.indexOf(el);
    if (at < 0) return;
    switch (e.keyCode) {
      case Keys.up:
      case Keys.down: {
        const to = at + (e.keyCode === Keys.up ? -1 : 1);
        if (to >= 0 && to < all.length) focus(all[to]);
        break;
      }
      case Keys.right:
        p.onEnter();
        break;
      case Keys.left:
        break;
      default:
        return;
    }
    noteUserAction();
    e.preventDefault();
    e.stopPropagation();
  };

  return (
    <div
      ref={rail}
      data-fgroup
      data-fyield
      data-rail
      onFocusIn={onIn}
      onFocusOut={onOut}
      onKeyDown={onKey}
      style={{
        position: 'absolute',
        left: 0,
        top: 0,
        bottom: 0,
        zIndex: 1,
        width: `${RAIL_WIDTH}rem`,
        boxSizing: 'border-box',
        paddingTop: '0.8rem',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        // See-through over the artwork and rows passing under it
        background: 'rgba(0,0,0,0.75)',
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'center', flex: 'none', marginBottom: '1.2rem' }}>
        <AppLogo size={58} />
      </div>
      {p.tabs.map((tab, i) => (
        <NavItem key={i} icon={tab.icon} label={tab.label} selected={i === p.selected} onTap={() => p.onSelect(i)} />
      ))}
      {/* Settings sit at the bottom of the rail; who is watching is in Home's header */}
      <div style={{ flex: 1 }} />
      <NavItem icon="settings_rounded" label={t('settings')} selected={false} last onTap={() => push(() => <AccountScreen />)} />
    </div>
  );
}

/** The icon with its name under it, on a lighter block when selected. */
function NavItem(p: { icon: string; label: string; selected: boolean; last?: boolean; onTap: () => void }) {
  const color = p.selected ? 'var(--text)' : 'var(--muted)'; // over artwork: subtle would not read
  return (
    // Flutter's 4 and 10, less the 3 that .f keeps around each item for its focus ring
    <div style={{ padding: p.last ? '0.1rem 0.7rem 1.3rem' : '0.1rem 0.7rem', flex: 'none' }}>
      <Focusable radius={10} scale={1.03} onTap={p.onTap} label={p.label} entry={p.selected}>
        <div
          style={{ padding: '0.9rem 0', display: 'flex', flexDirection: 'column', alignItems: 'center', color, background: p.selected ? 'var(--surface-high)' : 'transparent', transition: 'background-color 200ms' }}
        >
          <span style={{ display: 'flex', flex: 'none' }}>
            <Icon icon={p.icon} size={26} />
          </span>
          <div style={{ marginTop: '0.4rem', maxWidth: '100%', fontSize: 'calc(1.2rem * var(--text-scale))', lineHeight: 1.25, fontWeight: p.selected ? 700 : 500, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{p.label}</div>
        </div>
      </Focusable>
    </div>
  );
}

/** Loading, error (with retry) and empty states around [load] (Flutter's AsyncView). */
export function useAsync<T>(load: () => Promise<T>, deps: unknown[]): { data?: T; error?: unknown; retry: () => void } {
  const [state, setState] = useState<{ data?: T; error?: unknown }>({});
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let live = true;
    setState({});
    load().then(
      (data) => live && setState({ data }),
      (error) => live && setState({ error }),
    );
    return () => {
      live = false;
    };
  }, deps.concat([attempt]));
  return { ...state, retry: () => setAttempt((n) => n + 1) };
}

/** In the middle of what is clear of the side rail, in a tab that goes under it. */
function centered(rail: number, padding = 0) {
  return {
    height: '100%',
    boxSizing: 'border-box',
    padding: `${padding}rem ${padding}rem ${padding}rem ${rail + padding}rem`,
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    textAlign: 'center',
  } as const;
}

export function Failed({ error, retry }: { error: unknown; retry: () => void }) {
  const rail = useRailInset();
  return (
    <div style={centered(rail, 2.4)}>
      <CapyMessage
        mood={capyMoodForError(error)}
        text={errorText(error)}
        textClass="" // in the body's colour: something to act on
        action={<SecondaryButton icon="refresh_rounded" label={t('retry')} onPressed={retry} autofocus />}
      />
    </div>
  );
}

export function Loading() {
  const rail = useRailInset();
  return (
    <div style={centered(rail)}>
      <ListLoading />
    </div>
  );
}

/** A list that loaded with nothing in it (Flutter's AsyncView isEmpty). */
export function Empty() {
  const rail = useRailInset();
  return (
    <div style={centered(rail)}>
      <CapyMessage mood="empty" text={t('nothingHere')} />
    </div>
  );
}

/** Categories on the left and the channels of the selected one. */
function LiveTab({ source }: { source: ContentSource }) {
  const cats = useAsync(() => source.liveCategories(), [source]);
  const [selected, setSelected] = useState<string | null>(null);
  // The remote comes in on the selected category (its data-autofocus): HomeScreen takes it there
  if (cats.error) return <Failed error={cats.error} retry={cats.retry} />;
  if (!cats.data) return <Loading />;
  if (!cats.data.length) return <Empty />;
  const current = selected || cats.data[0].id;
  return (
    <div class="row" style={{ height: '100%', alignItems: 'stretch' }}>
      <div style={{ width: '30rem', flex: 'none', display: 'flex', flexDirection: 'column' }}>
        {/* The header stays put while the categories scroll, so the guide is always one press away */}
        <div class="row" style={{ padding: '2rem 0.8rem 0.8rem 2.4rem' }}>
          <h1 class="headline-medium grow">{t('liveTv')}</h1>
          <IconButton icon="view_timeline_rounded" label={t('tvGuide')} onPressed={() => push(() => <GuideScreen categories={cats.data!} initial={current} />)} />
        </div>
        <div data-fgroup style={{ flex: 1, overflowY: 'auto', padding: '0 0.8rem 2rem 1.6rem' }}>
          {cats.data.map((c) => (
            <CategoryRow key={c.id} name={categoryLabel(c.name)} selected={c.id === current} onTap={() => setSelected(c.id)} />
          ))}
        </div>
      </div>
      <div class="grow">
        <Channels key={current} source={source} category={current} />
      </div>
    </div>
  );
}

function CategoryRow(p: { name: string; selected: boolean; onTap: () => void }) {
  return (
    <div style={{ padding: '0.2rem 0' }}>
      <Focusable radius={12} scale={1.02} onTap={p.onTap} autofocus={p.selected}>
        <div class="row" style={{ padding: '1.2rem 1.4rem', background: p.selected ? 'rgba(255,255,255,0.08)' : 'transparent' }}>
          <div style={{ width: '0.4rem', height: '1.8rem', borderRadius: '0.2rem', background: p.selected ? 'var(--text)' : 'transparent' }} />
          <div class="ellipsis grow" style={{ marginLeft: '1rem', fontWeight: p.selected ? 700 : 500, color: p.selected ? 'var(--text)' : 'var(--muted)' }}>
            {p.name}
          </div>
        </div>
      </Focusable>
    </div>
  );
}

const CARD_ROW = 18; // rem: a card (16.4) and the row gap under it (1.6); every grid row is this tall

function Channels({ source, category }: { source: ContentSource; category: string }) {
  const { guide: holder, library } = session();
  useNotifier(holder);
  useNotifier(library); // the hearts
  // Keeps "on now" and its progress bar current, while the tab is in sight
  const inSight = useInSight();
  const [, tick] = useState(0);
  useEffect(() => {
    if (!inSight) return;
    const timer = window.setInterval(() => tick((n) => n + 1), 60000);
    return () => clearInterval(timer);
  }, [inSight]);
  const list = useAsync(() => source.liveChannels(category), [source, category]);
  // Only the rows near the view are built, as Flutter's GridView.builder: before the early
  // returns, so the hooks always run
  const [perRow, setPerRow] = useState(1);
  const total = list.data ? list.data.length : 0;
  const win = useRowWindow(Math.ceil(total / perRow), CARD_ROW * 20, 144); // 7.2rem of padding above the first row
  if (list.error) return <Failed error={list.error} retry={list.retry} />;
  if (!list.data) return <Loading />;
  if (!list.data.length) return <Empty />;
  const guide = holder.guide;
  const channels = list.data;
  const rows = Math.ceil(channels.length / perRow);
  return (
    <div
      data-fgroup
      ref={win.ref}
      onScroll={win.onScroll}
      onFocusIn={(e: FocusEvent) => {
        const card = (e.target as HTMLElement).closest('[data-i]');
        if (card) win.focusRow(Math.floor(Number(card.getAttribute('data-i')) / perRow));
      }}
      style={{ height: '100%', overflowY: 'auto', boxSizing: 'border-box', padding: '7.2rem 2.4rem 2.4rem 1.6rem' }}
    >
      <div
        ref={(el) => {
          if (!el) return;
          // The columns auto-fill gives, read back: the window counts in rows of them. Only the
          // laid-out tracks ("150px 150px …"): out of sight it reads back the template itself
          const n = (getComputedStyle(el).gridTemplateColumns || '').split(' ').filter((x) => /px$/.test(x)).length;
          if (n && n !== perRow) setPerRow(n);
        }}
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fill, minmax(15rem, 1fr))',
          gridGap: '1.6rem',
          // Room for the rows not built, so the scroll stays true
          paddingTop: `${win.first * CARD_ROW}rem`,
          paddingBottom: `${Math.max(0, rows - win.end) * CARD_ROW}rem`,
        }}
      >
        {channels.slice(win.first * perRow, win.end * perRow).map((c, k) => {
          const i = win.first * perRow + k;
          const now = guide.nowOn(c.epgId);
          return (
            <div key={c.id} data-i={i}>
              <Focusable onTap={() => playChannels(channels, i)} onLongPress={() => showChannelSheet(c, () => playChannels(channels, i))}>
                <div style={{ background: 'var(--surface)', padding: '1.4rem', height: '16.4rem', boxSizing: 'border-box', display: 'flex', flexDirection: 'column' }}>
                  <div class="row">
                    {c.number !== undefined && <span class="muted" style={{ fontWeight: 700 }}>{c.number}</span>}
                    <span class="grow" />
                    {library.isFavorite(channelRef(c)) && <Icon icon="favorite_rounded" size={16} />}
                    {c.archiveDays > 0 && (
                      <span style={{ display: 'flex', marginLeft: '0.6rem' }}>
                        <Icon icon="history_rounded" size={18} />
                      </span>
                    )}
                  </div>
                  <div class="grow row" style={{ justifyContent: 'center', minHeight: 0 }}>
                    <NetImage url={c.icon || guide.iconOf(c.epgId)} icon="tv_rounded" />
                  </div>
                  <div class={now ? 'ellipsis' : 'clamp2'} style={{ marginTop: '0.8rem', fontWeight: 600, fontSize: 'calc(1.3rem * var(--text-scale))' }}>{c.name}</div>
                  {now && (
                    <div style={{ marginTop: '0.6rem' }}>
                      <NowOnAir entry={now} />
                    </div>
                  )}
                </div>
              </Focusable>
            </div>
          );
        })}
      </div>
    </div>
  );
}

const FADE = 250; // ms, Flutter's

/** What a NetImage's label looks like on its placeholder: up to four lines. */
const LABEL = { padding: '1rem', fontWeight: 600, display: '-webkit-box', WebkitLineClamp: '4', WebkitBoxOrient: 'vertical', overflow: 'hidden' } as const;

type Phase = 'wait' | 'load' | 'ok' | 'broken';

/**
 * A provider's image, loaded once it nears the screen and its turn comes (Chromium 69 has no
 * loading="lazy"; see ui/image_queue.ts for the turns), over a placeholder: the title when there
 * is one, else the icon. The placeholder shows while it waits, loads and when it breaks or there
 * is none, as IPTV logos and posters often are; the image fades in over it. Once in, the
 * placeholder goes, so it never shows through a logo's transparent parts.
 */
export function NetImage({ url, icon, cover, label }: { url?: string; icon: string; cover?: boolean; label?: string }) {
  // Only web addresses are tried, as Flutter's
  const first: Phase = url && url.indexOf('http') === 0 && !imageLeftAlone(url) ? 'wait' : 'broken';
  const [state, setState] = useState<{ url?: string; phase: Phase }>({ url, phase: first });
  // Another image in the same place (the player's logo as it zaps) starts over
  const phase = state.url === url ? state.phase : first;
  const to = (p: Phase) => setState({ url, phase: p });
  const [box, setBox] = useState<HTMLElement | null>(null);
  const turn = useRef<(() => void) | null>(null);
  const endTurn = () => {
    if (turn.current) turn.current();
    turn.current = null;
  };
  useEffect(() => endTurn, [url]); // another image here, or none any more
  useEffect(() => {
    if (!box || phase !== 'wait') return;
    const io = new IntersectionObserver(
      (entries) => {
        // Near the screen it waits for its turn; scrolled past before it comes, it stops waiting
        if (!entries[entries.length - 1].isIntersecting) endTurn();
        else if (!turn.current) turn.current = imageTurn(() => to('load'));
      },
      { rootMargin: '400px' },
    );
    io.observe(box);
    return () => io.disconnect();
  }, [box, phase, url]);
  const loaded = phase === 'ok';
  return (
    <div ref={setBox} style={{ position: 'relative', width: '100%', height: '100%', overflow: 'hidden', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      {/* The surface is the placeholder's: once in, a logo sits on what is under it (the player's lighter box) */}
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          right: 0,
          bottom: 0,
          background: 'var(--surface)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          textAlign: 'center',
          // Gone once the image has faded in over it
          visibility: loaded ? 'hidden' : 'visible',
          transition: loaded ? `visibility 0s ${FADE}ms` : 'none',
        }}
      >
        {label ? (
          <div class="muted" style={LABEL}>
            {label}
          </div>
        ) : (
          <span class="subtle" style={{ display: 'flex' }}>
            <Icon icon={icon} size={24} />
          </span>
        )}
      </div>
      {(phase === 'load' || loaded) && (
        <img
          src={url}
          onLoad={() => {
            endTurn();
            to('ok');
          }}
          onError={() => {
            endTurn();
            if (url) imageFailed(url);
            to('broken');
          }}
          style={{
            position: 'relative', // over the placeholder
            ...(cover ? { width: '100%', height: '100%' } : { maxWidth: '100%', maxHeight: '100%' }),
            objectFit: cover ? 'cover' : 'contain',
            opacity: loaded ? 1 : 0,
            transition: `opacity ${FADE}ms`,
          }}
        />
      )}
    </div>
  );
}

export type { Category, EpgEntry, LiveChannel };
