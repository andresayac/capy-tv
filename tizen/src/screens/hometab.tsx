// The personal start page (app/lib/ui/home_tab.dart), movies and series first: what is trending
// this week and the provider has, what was left on another device, continue watching, new
// episodes, what was picked for the profile, the week's most watched, "My list", what is new; then
// recent and favorite channels.
import { useEffect, useRef, useState } from 'preact/hooks';
import { CatalogData } from '../data/catalog';
import { libraryShows } from '../data/kids';
import { episodeRef, HistoryEntry, MediaRef, progressOf, refKey, refToChannel, refToEpisode, refToMovie, refToSeries } from '../data/library';
import { addTmdbIds } from '../data/matching';
import { Episode, Movie, Series } from '../data/models';
import { errorText } from '../data/source';
import { NewEpisodeFinder, NewEpisodes } from '../data/new_episodes';
import { profileStore } from '../data/profiles';
import { trendTrailer } from '../data/trailers';
import { guessLanguage, trending } from '../data/trending';
import { t } from '../i18n';
import { session, Session } from '../session';
import { CapyStatus, Focusable, Icon, Panel, PrimaryButton, SecondaryButton, useNotifier } from '../ui/components';
import { offer } from '../ui/focus';
import { toast } from '../ui/router';
import { episodeSubtitle } from '../ui/labels';
import { useRailInset } from '../ui/tab';
import { CatalogItem, HeroCarousel, ItemRail, LoadError, movieCatalogItem, movieItem, openItemGrid, PosterCard, RankedRail, SectionHeader, seriesCatalogItem } from './catalog';
import { showChannelSheet } from './channel';
import { openMovie, openSeries } from './details';
import { ForYouRail } from './foryou';
import { NetImage, useAsync } from './home';
import { PlayItem, playQueue } from './player';
import { changeProfile, ProfileAvatar } from './profiles';
import { openSurprise } from './surprise';

/** What plays a library entry again, its URL rebuilt through the source. */
export function playItemFor(r: MediaRef): PlayItem {
  const { source } = session();
  switch (r.kind) {
    case 'live':
      return { url: source.liveUrl(refToChannel(r)), title: r.title, channel: refToChannel(r), ref: r };
    case 'episode':
      return { url: source.episodeUrl(refToEpisode(r)), title: r.seriesTitle || r.title, subtitle: `S${r.season} · E${r.number}  ${r.title}`, ref: r };
    default:
      return { ...movieItem(refToMovie(r)), ref: r };
  }
}

/** Plays [refs] as a queue from the one at [index], leaving out those that cannot play; says why when that one cannot. */
function playRefs(refs: MediaRef[], index: number): void {
  try {
    playItemFor(refs[index]);
  } catch (e) {
    toast(errorText(e));
    return;
  }
  const items: PlayItem[] = [];
  let at = 0;
  refs.forEach((r, i) => {
    try {
      const item = playItemFor(r);
      if (i === index) at = items.length;
      items.push(item);
    } catch {
      // A combined list's part that is gone, or the like: left out
    }
  });
  void playQueue(items, at);
}

/**
 * Plays [r] from the library; an episode with the rest of its series around it, so the next one
 * follows as from the series' page (one alone if the provider does not answer in time). [from]:
 * where to start, in place of where it was left.
 */
export async function playFromLibrary(r: MediaRef, from?: number): Promise<void> {
  if (r.kind === 'episode' && r.seriesId) {
    const { source } = session();
    try {
      const d = await Promise.race([
        source.seriesDetail(refToSeries(r)),
        new Promise<never>((_, no) => setTimeout(() => no(new Error('timeout')), 6000)),
      ]);
      const all = ([] as Episode[]).concat(...d.seasons.map((x) => x.episodes));
      const i = all.findIndex((x) => x.id === r.id);
      if (i >= 0) {
        const items: PlayItem[] = all.map((x) => ({ url: source.episodeUrl(x), title: d.series.name, subtitle: episodeSubtitle(x, d.series.name), ref: episodeRef(d.series, x) }));
        items[i].start = from;
        return playQueue(items, i);
      }
    } catch {
      // One episode, then
    }
  }
  let item: PlayItem;
  try {
    item = playItemFor(r);
  } catch (e) {
    toast(errorText(e));
    return;
  }
  return playQueue([{ ...item, start: from }]);
}

const finders = new WeakMap<object, NewEpisodeFinder>();

/** Catalogs already looked over once loaded (see [afterLoad]). */
const looked = new WeakSet<CatalogData>();

/**
 * Once a playlist's catalog is there, quietly (app/lib/ui/home_screen.dart): this week's trends
 * also in the catalog's language when it is not the app's, so their titles match the provider's;
 * and the TMDB id of the library's movies, which finds them again with another provider.
 */
function afterLoad(data: CatalogData, { source, library }: Session): void {
  if (looked.has(data)) return;
  looked.add(data);
  const quiet = () => undefined; // extras: Home shows the catalog whatever becomes of them
  try {
    trending.alsoIn(guessLanguage(data.movies.slice(0, 5000).map((m) => m.name))).catch(quiet); // all it reads
  } catch {
    // A name it cannot read: the trends stay in the app's language
  }
  addTmdbIds(library, source, 30, () => {
    try {
      return session().library === library; // the playlist is still open, for this profile
    } catch {
      return false;
    }
  }).catch(quiet);
}

/** "Not now" on the banner of what was left elsewhere, since the app started. */
const dismissed: Record<string, true> = {};

export function HomeTab({ onBrowse }: { onBrowse: (tab: number) => void }) {
  const s = session();
  const { library, catalog, playlist } = s;
  useNotifier(library);
  useNotifier(trending);
  useNotifier(profileStore);
  // As Flutter's initState: with this tab's own session, not whichever is open once it loads
  const data = useAsync<CatalogData>(() => catalog.load().then((d) => (afterLoad(d, s), d)), []);
  // The pane starts under the see-through side rail: the hero goes under it, the rest keeps clear
  const rail = useRailInset();
  const [, setVersion] = useState(0);
  const box = useRef<HTMLDivElement>(null);
  const d = data.data;
  const shows = (r: MediaRef) => libraryShows(r, d, catalog.source);
  const cont = library.continueWatching.filter((e) => shows(e.ref));
  const recent = library.recent('live').filter(shows).slice(0, 20);
  const favChannels = library.favorites('live').filter(shows);
  const favMovies = library.favorites('movie').filter(shows);
  const favSeries = library.favorites('series').filter(shows);
  const empty = !cont.length && !recent.length && !favChannels.length && !favMovies.length && !favSeries.length;
  const left = library.leftElsewhere();
  const away = left && shows(left.ref) ? left : null;
  const awayKey = away ? `${refKey(away.ref)}@${away.at}` : '';
  // A kids profile never gets the trends rated for adults
  const kids = !!profileStore.current.kids;

  const hero: CatalogItem[] = d
    ? trending
        .available(d, kids)
        .filter((x) => x.trend.backdrop)
        .slice(0, 8)
        .map(({ trend, item }) => {
          const base = trend.series ? seriesCatalogItem(item as Series) : movieCatalogItem(item as Movie);
          return { ...base, backdrop: trend.backdrop || base.backdrop, plot: base.plot || trend.overview, trailer: () => trendTrailer(trend) };
        })
    : [];
  // Once content is there, the remote starts on it rather than on the rail
  useEffect(() => {
    if (box.current) offer(box.current.querySelector<HTMLElement>('[data-autofocus]'));
  }, [d, cont.length, hero.length]);

  const ranked = (series: boolean) =>
    d ? trending.ofKind(d, series, kids).map((x) => (series ? seriesCatalogItem(x as Series) : movieCatalogItem(x as Movie))) : [];
  const mostMovies = ranked(false);
  const mostSeries = ranked(true);
  const newMovies = d ? d.recentMovies.slice(0, 40).map(movieCatalogItem) : [];
  const newSeries = d ? d.recentSeries.slice(0, 40).map(seriesCatalogItem) : [];
  const first = cont.length ? 'cont' : favMovies.length ? 'favMovies' : favSeries.length ? 'favSeries' : recent.length ? 'recent' : favChannels.length ? 'favChannels' : '';
  return (
    <div ref={box} style={{ height: '100%', overflowY: 'auto', paddingBottom: '12rem', boxSizing: 'border-box' }}>
      <div style={{ position: 'relative' }}>
        {/* Never the remote's start: Home's own content is there before the trends, as in Flutter */}
        {hero.length > 0 && <HeroCarousel items={hero} label={t('trendingNow')} autofocus={false} />}
        <div class="row" style={{ position: hero.length ? 'absolute' : 'relative', left: 0, right: 0, top: 0, padding: `2rem 1.6rem 0.4rem ${rail + 2.4}rem` }}>
          <div class="grow">
            <h1 class="headline-medium">{t('home')}</h1>
            <div class="muted">{playlist.name}</div>
          </div>
          {/* For an evening without a plan */}
          <SecondaryButton icon="casino_outlined" label={t('surpriseMe')} onPressed={openSurprise} />
          {/* Who is watching, and OK for someone else: the playlist opens again for them */}
          <div style={{ marginLeft: '0.8rem' }}>
            <Focusable radius={999} onTap={() => changeProfile(playlist.id)} label={t('switchProfile')}>
              <ProfileAvatar profile={profileStore.current} size={38} />
            </Focusable>
          </div>
        </div>
      </div>
      {/* The catalog failed: what went wrong and Retry, not "make it yours" as for someone new */}
      {!d && data.error ? (
        <LoadError error={data.error} retry={data.retry} autofocus={empty} />
      ) : empty && (
        <div style={{ padding: `2.4rem 2.4rem 2.4rem ${rail + 2.4}rem` }}>
          <Panel style={{ padding: '2.8rem' }}>
            <div class="row">
              <CapyStatus mood="empty" size={56} />
            </div>
            <h2 class="headline-medium" style={{ marginTop: '1.6rem' }}>{t('homeEmptyTitle')}</h2>
            <p class="muted" style={{ maxWidth: '52rem', lineHeight: 1.5 }}>{t('homeEmptyBody')}</p>
            <div class="wrap" data-fgroup style={{ marginTop: '1.4rem' }}>
              <PrimaryButton icon="movie_rounded" label={t('movies')} onPressed={() => onBrowse(1)} autofocus />
              <SecondaryButton icon="video_library_rounded" label={t('series')} onPressed={() => onBrowse(2)} />
              <SecondaryButton icon="live_tv_rounded" label={t('liveTv')} onPressed={() => onBrowse(3)} />
            </div>
          </Panel>
        </div>
      )}
      {away && !dismissed[awayKey] && (
        <LeftElsewhere
          entry={away}
          onPlay={() => playFromLibrary(away.ref)}
          onDismiss={() => {
            dismissed[awayKey] = true;
            setVersion((v) => v + 1);
          }}
        />
      )}
      {cont.length > 0 && (
        <div>
          <SectionHeader title={t('continueWatching')} />
          <div
            class="row hscroll"
            data-fgroup
            data-inset-left={rail * 20}
            style={{ padding: `0.6rem 2.4rem 0.6rem ${rail + 2.4}rem`, alignItems: 'flex-start' }}
          >
            {cont.map((h, i) => (
              <ContinueCard
                key={refKey(h.ref)}
                entry={h}
                autofocus={i === 0 && !away}
                onTap={() => playFromLibrary(h.ref)}
                onLongPress={() => {
                  library.forget(h.ref);
                  toast(t('removeFromContinue'));
                }}
              />
            ))}
          </div>
        </div>
      )}
      {/* The episode after one watched to the end: "Continue watching" only has those left half way */}
      {d && <NewEpisodesRail data={d} upNext />}
      {d && <NewEpisodesRail data={d} />}
      {d && <ForYouRail data={d} />}
      {mostMovies.length >= RANKED_MIN && <RankedRail title={t('mostWatchedMovies')} items={mostMovies} onSeeAll={() => openItemGrid(t('mostWatchedMovies'), mostMovies)} />}
      {mostSeries.length >= RANKED_MIN && <RankedRail title={t('mostWatchedSeries')} items={mostSeries} onSeeAll={() => openItemGrid(t('mostWatchedSeries'), mostSeries)} />}
      {favMovies.length > 0 && (
        <RefRail
          title={t('favoriteMovies')}
          refs={favMovies}
          autofocus={first === 'favMovies'}
          open={(r) => openMovie(refToMovie(r))}
          onSeeAll={() => openItemGrid(t('favoriteMovies'), favMovies.map((r) => movieCatalogItem(refToMovie(r))))}
        />
      )}
      {favSeries.length > 0 && (
        <RefRail
          title={t('favoriteSeries')}
          refs={favSeries}
          autofocus={first === 'favSeries'}
          open={(r) => openSeries(refToSeries(r))}
          onSeeAll={() => openItemGrid(t('favoriteSeries'), favSeries.map((r) => seriesCatalogItem(refToSeries(r))))}
        />
      )}
      {newMovies.length > 0 && <ItemRail title={t('newMovies')} items={newMovies} onSeeAll={() => openItemGrid(t('newMovies'), d ? d.recentMovies.map(movieCatalogItem) : newMovies)} />}
      {newSeries.length > 0 && <ItemRail title={t('newEpisodes')} items={newSeries} onSeeAll={() => openItemGrid(t('newEpisodes'), d ? d.recentSeries.map(seriesCatalogItem) : newSeries)} />}
      {recent.length > 0 && <ChannelRail title={t('recentChannels')} channels={recent} autofocus={first === 'recent'} />}
      {favChannels.length > 0 && <ChannelRail title={t('favoriteChannels')} channels={favChannels} autofocus={first === 'favChannels'} />}
    </div>
  );
}

const RANKED_MIN = 3;

function NewEpisodesRail({ data, upNext = false }: { data: CatalogData; upNext?: boolean }) {
  const { source, catalog, library } = session();
  let finder = finders.get(catalog);
  if (!finder) finders.set(catalog, (finder = new NewEpisodeFinder(source)));
  // Once per library, as Flutter: the rail stays put through the session, and the remote's place on it with it
  const found = useAsync<NewEpisodes[]>(() => finder!.find(library, data, 8, upNext).catch(() => []), [data, library]);
  if (!found.data || !found.data.length) return null;
  return (
    <ItemRail
      title={t(upNext ? 'upNextForYou' : 'newEpisodesForYou')}
      items={found.data.map(({ series, next, count }) => ({
        ...seriesCatalogItem(series),
        note: t('newEpisodeNote', { season: next.season, number: next.number, more: count - 1 }),
      }))}
    />
  );
}

function ago(ms: number): string {
  const mins = Math.floor(Math.max(0, ms) / 60000);
  return mins < 1 ? t('agoNow') : mins < 60 ? t('agoMinutes', { count: mins }) : t('agoHours', { count: Math.floor(mins / 60) });
}

/** "You left this on the living room TV 20 minutes ago", with a button to go on here. */
function LeftElsewhere({ entry, onPlay, onDismiss }: { entry: HistoryEntry; onPlay: () => void; onDismiss: () => void }) {
  const r = entry.ref;
  const rail = useRailInset();
  return (
    <div style={{ padding: `2rem 2.4rem 0.4rem ${rail + 2.4}rem` }}>
      <div class="row" style={{ background: 'var(--surface)', border: '1px solid var(--stroke)', borderRadius: 'var(--r-card)', padding: '1.4rem' }}>
        <div style={{ width: '16.8rem', height: '9.45rem', flex: 'none', position: 'relative', borderRadius: 'var(--r-button)', overflow: 'hidden', background: 'var(--surface-high)' }}>
          <NetImage url={r.image} icon="movie_rounded" cover label={r.seriesTitle || r.title} />
          <div style={{ position: 'absolute', left: 0, bottom: 0, height: '0.4rem', width: `${progressOf(entry) * 100}%`, background: 'var(--text)' }} />
        </div>
        <div class="grow" style={{ margin: '0 1.8rem' }}>
          <div class="muted ellipsis" style={{ fontSize: 'calc(1.3rem * var(--text-scale))', fontWeight: 600 }}>{t('leftOn', { device: entry.dev || '', ago: ago(Date.now() - entry.at) })}</div>
          <div class="ellipsis" style={{ fontSize: 'calc(1.8rem * var(--text-scale))', fontWeight: 800, marginTop: '0.4rem' }}>{r.seriesTitle || r.title}</div>
          {r.kind === 'episode' && <div class="muted ellipsis" style={{ fontSize: 'calc(1.2rem * var(--text-scale))' }}>{`S${r.season} · E${r.number}  ${r.title}`}</div>}
          <div class="muted" style={{ fontSize: 'calc(1.2rem * var(--text-scale))', marginTop: '0.4rem' }}>{t('minutesLeft', { n: Math.max(1, Math.floor((entry.dur - entry.pos) / 60000)) })}</div>
        </div>
        <div class="wrap" data-fgroup>
          <PrimaryButton icon="play_arrow_rounded" label={t('goOnHere')} onPressed={onPlay} autofocus />
          <SecondaryButton label={t('notNow')} onPressed={onDismiss} />
        </div>
      </div>
    </div>
  );
}

/** Landscape card with artwork and a progress bar. */
function ContinueCard({ entry, onTap, onLongPress, autofocus }: { entry: HistoryEntry; onTap: () => void; onLongPress?: () => void; autofocus?: boolean }) {
  const r = entry.ref;
  return (
    <div style={{ width: '26rem', flex: 'none', marginRight: '1.6rem' }}>
      <Focusable onTap={onTap} onLongPress={onLongPress} autofocus={autofocus}>
        <div style={{ position: 'relative', height: '14.6rem', background: 'var(--surface)' }}>
          <NetImage url={r.image} icon="movie_rounded" cover label={r.seriesTitle || r.title} />
          <div style={{ position: 'absolute', left: 0, top: 0, right: 0, bottom: 0, background: 'linear-gradient(to bottom, transparent, rgba(0,0,0,0.8))' }} />
          <div style={{ position: 'absolute', left: '50%', top: '50%', margin: '-2.2rem 0 0 -2.2rem', color: 'rgba(255,255,255,0.7)' }}>
            <Icon icon="play_circle_rounded" size={44} />
          </div>
          <div style={{ position: 'absolute', left: '1.2rem', right: '1.2rem', bottom: '1rem' }}>
            <div style={{ fontSize: 'calc(1.2rem * var(--text-scale))', color: 'rgba(255,255,255,0.7)' }}>{t('minutesLeft', { n: Math.max(1, Math.floor((entry.dur - entry.pos) / 60000)) })}</div>
            <div style={{ height: '0.4rem', background: 'rgba(255,255,255,0.24)', borderRadius: '0.3rem', marginTop: '0.6rem', overflow: 'hidden' }}>
              <div style={{ width: `${progressOf(entry) * 100}%`, height: '100%', background: 'var(--text)' }} />
            </div>
          </div>
        </div>
      </Focusable>
      <div class="ellipsis" style={{ fontWeight: 700, margin: '0.8rem 0.3rem 0' }}>{r.seriesTitle || r.title}</div>
      {/* Always two lines, so movie and episode cards keep the same artwork height */}
      <div class="muted ellipsis" style={{ fontSize: 'calc(1.2rem * var(--text-scale))', margin: '0 0.3rem' }}>{r.kind === 'episode' ? `S${r.season} · E${r.number}  ${r.title}` : ' '}</div>
    </div>
  );
}

/** Channels from the library; the rail is the zapping queue, so up/down in the player moves along it. */
function ChannelRail({ title, channels, autofocus }: { title: string; channels: MediaRef[]; autofocus?: boolean }) {
  const rail = useRailInset();
  return (
    <div>
      <SectionHeader title={title} />
      <div class="row hscroll" data-fgroup data-inset-left={rail * 20} style={{ padding: `0.6rem 2.4rem 0.6rem ${rail + 2.4}rem` }}>
        {channels.map((c, i) => (
          <div key={refKey(c)} style={{ width: '15rem', flex: 'none', marginRight: '1.4rem' }}>
            {/* Holding OK, or Info: the channel sheet, the TV's one place to take a channel off the favorites */}
            <Focusable
              autofocus={autofocus && i === 0}
              onTap={() => playRefs(channels, i)}
              onLongPress={() => showChannelSheet(refToChannel(c), () => playRefs(channels, i))}
            >
              <div style={{ background: 'var(--surface)', padding: '1.2rem', height: '12rem', boxSizing: 'border-box', display: 'flex', flexDirection: 'column' }}>
                <div class="grow" style={{ minHeight: 0 }}>
                  <NetImage url={c.image} icon="tv_rounded" />
                </div>
                <div class="ellipsis" style={{ marginTop: '0.8rem', fontWeight: 600, fontSize: 'calc(1.3rem * var(--text-scale))', textAlign: 'center' }}>{c.title}</div>
              </div>
            </Focusable>
          </div>
        ))}
      </div>
    </div>
  );
}

/** Favorite movies or series, as the library keeps them. */
function RefRail({
  title,
  refs,
  open,
  autofocus,
  onSeeAll,
}: {
  title: string;
  refs: MediaRef[];
  open: (r: MediaRef) => void;
  autofocus?: boolean;
  /** All of them in a grid: sixty saved titles are not to be gone through one by one. */
  onSeeAll?: () => void;
}) {
  const rail = useRailInset();
  return (
    <div>
      <SectionHeader title={title} onSeeAll={onSeeAll} />
      <div class="row hscroll" data-fgroup data-inset-left={rail * 20} style={{ padding: `0.6rem 2.4rem 0.6rem ${rail + 2.4}rem`, alignItems: 'flex-start' }}>
        {refs.map((r, i) => (
          <div key={refKey(r)} style={{ width: '15rem', flex: 'none', marginRight: '1.4rem' }}>
            <PosterCard item={{ key: refKey(r), title: r.title, poster: r.image, genres: [], open: () => open(r) }} autofocus={autofocus && i === 0} />
          </div>
        ))}
      </div>
    </div>
  );
}
