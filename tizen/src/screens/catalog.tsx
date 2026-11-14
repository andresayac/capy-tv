// Movies and series (app/lib/ui/catalog.dart): a featured carousel, genres, the week's most
// watched, rows computed from the whole catalog, then the provider's own categories, each loaded
// as it comes near.
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { CatalogData } from '../data/catalog';
import { movieRef as movieRefOf } from '../data/library';
import { Movie, Series, splitGenres } from '../data/models';
import { movieBackdrop } from '../data/movie_details';
import { categoryLabel } from '../ui/labels';
import { profileStore } from '../data/profiles';
import { Category, errorText } from '../data/source';
import { movieTrailer, seriesTrailer } from '../data/trailers';
import { trending } from '../data/trending';
import { t } from '../i18n';
import { session } from '../session';
import { AppBar, AppChip, CapyMessage, CapyStatus, capyMoodForError, Focusable, Icon, PrimaryButton, SecondaryButton, Spinner, useNotifier } from '../ui/components';
import { focusables, offer } from '../ui/focus';
import { useMaxExtentGrid } from '../ui/grid';
import { ListLoading } from '../ui/list_loading';
import { push } from '../ui/router';
import { useRailInset } from '../ui/tab';
import { settings } from '../data/settings';
import { trailerServer, TrailerBackdrop } from '../ui/trailer';
import { openMovie, openSeries } from './details';
import { Failed, NetImage, useAsync } from './home';
import { PlayItem, playQueue } from './player';

/** What browsing needs to show a movie or a series. */
export interface CatalogItem {
  key: string;
  title: string;
  poster?: string;
  backdrop?: string;
  /** Where [backdrop] is missing and must be fetched: movie listings carry none, the full record does. */
  loadBackdrop?: () => Promise<string | null>;
  rating?: number;
  year?: number;
  plot?: string;
  genres: string[];
  added?: Date;
  note?: string; // a line under the poster, such as which episode is new
  /** The YouTube id of a trailer the hero plays behind the page, if any. */
  trailer?: () => Promise<string | null>;
  open: () => void; // details page
  play?: () => void; // direct playback, movies only
}

/** [m] to play, with the other versions of its title the catalog knows as alternates. */
export function movieItem(m: Movie): PlayItem {
  const { source, catalog } = session();
  const versions = catalog.loaded ? catalog.loaded.versionsOf(m) : [];
  return {
    url: source.movieUrl(m),
    title: m.name,
    ref: movieRefOf(m),
    alternates: versions.filter((v) => v.id !== m.id).map((v) => source.movieUrl(v)),
  };
}

export function movieCatalogItem(m: Movie): CatalogItem {
  const { source } = session();
  return {
    key: `movie:${m.id}`,
    title: m.name,
    poster: m.poster,
    backdrop: m.backdrop,
    loadBackdrop: source.movieDetail ? () => movieBackdrop(source, m) : undefined,
    rating: m.rating,
    year: m.year,
    plot: m.plot,
    genres: splitGenres(m.genre),
    added: m.added,
    trailer: () => movieTrailer(source, m),
    open: () => openMovie(m),
    play: () => playQueue([movieItem(m)]), // with its other versions, should this one fail
  };
}

export function seriesCatalogItem(s: Series): CatalogItem {
  return {
    key: `series:${s.id}`,
    title: s.name,
    poster: s.cover,
    backdrop: s.backdrop,
    rating: s.rating,
    year: s.year,
    plot: s.plot,
    genres: splitGenres(s.genre),
    added: s.updated,
    trailer: () => seriesTrailer(s),
    open: () => openSeries(s),
  };
}

const HERO_HEIGHT = '42rem'; // Flutter's (540 * 0.68).clamp(420, 640) on a 540 dp tall TV

export function CatalogTab({ kind }: { kind: 'movies' | 'series' }) {
  const { source, catalog } = session();
  const movies = kind === 'movies';
  const cats = useAsync<Category[]>(() => (movies ? source.movieCategories() : source.seriesCategories()), [kind]);
  const data = useAsync<CatalogData>(() => catalog.load(), [kind]);
  const box = useRef<HTMLDivElement>(null);
  // Whatever comes takes the remote from the placeholder that held it: the hero's main button, or
  // Retry. Not in a tab out of sight, and not from where the user went meanwhile
  useEffect(() => {
    const el = box.current;
    if (el && el.offsetParent !== null) offer(el.querySelector<HTMLElement>('[data-autofocus]') || focusables(el)[0] || null);
  }, [data.data, data.error, cats.data, cats.error]);
  return (
    <div ref={box} data-scroller style={{ height: '100%', overflowY: 'auto', paddingBottom: '12rem', boxSizing: 'border-box' }}>
      {cats.error ? (
        <Failed error={cats.error} retry={cats.retry} />
      ) : cats.data && !cats.data.length ? (
        // A playlist without any (an M3U has no series): said, rather than a black tab
        <div style={{ paddingTop: '20vh' }}>
          <CapyMessage mood="empty" text={t(movies ? 'noMoviesInPlaylist' : 'noSeriesInPlaylist')} />
        </div>
      ) : (
        <div>
          {data.data ? (
            <Curated kind={kind} data={data.data} />
          ) : data.error ? (
            <LoadError error={data.error} retry={data.retry} autofocus />
          ) : (
            <HeroSkeleton />
          )}
          {(cats.data || []).map((c) => (
            <LoadedRail
              key={c.id}
              title={categoryLabel(c.name)}
              load={() => (movies ? source.movies(c.id).then((l) => l.map(movieCatalogItem)) : source.series(c.id).then((l) => l.map(seriesCatalogItem)))}
            />
          ))}
        </div>
      )}
    </div>
  );
}

/**
 * Where the hero comes, while the catalog loads (and the provider's categories, which the rows
 * below wait for): it holds the remote, so entering the tab does not land on a row the hero then
 * pushes off screen. Its main button takes over.
 */
function HeroSkeleton() {
  const rail = useRailInset();
  return (
    <Focusable class="bare" radius={0} scale={1} autofocus onTap={() => {}}>
      {/* The focus padding makes up the rest of the hero's height */}
      <div style={{ height: '41.4rem', boxSizing: 'border-box', paddingLeft: `${rail}rem`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <ListLoading />
      </div>
    </Focusable>
  );
}

/**
 * What could not load, with Retry (Flutter's AsyncView error). [busy] while it loads again: the
 * button stays, and the remote on it.
 */
export function LoadError({ error, retry, busy, autofocus }: { error: unknown; retry: () => void; busy?: boolean; autofocus?: boolean }) {
  const rail = useRailInset(); // centered in what is clear of the side rail
  return (
    <div style={{ padding: `2.4rem 2.4rem 2.4rem ${rail + 2.4}rem`, display: 'flex', flexDirection: 'column', alignItems: 'center', textAlign: 'center' }}>
      {busy ? (
        <CapyStatus mood="loading" size={68} />
      ) : (
        <CapyStatus mood={capyMoodForError(error)} size={68} />
      )}
      <div style={{ margin: '1.2rem 0 1.6rem', lineHeight: 1.4 }}>{errorText(error)}</div>
      <SecondaryButton icon="refresh_rounded" label={t('retry')} onPressed={retry} autofocus={autofocus} />
    </div>
  );
}

/** [a]'s error, kept while Retry loads it again, so what shows it (and the remote on it) stays. */
export function useLastError(a: { data?: unknown; error?: unknown }): unknown {
  const last = useRef<unknown>(undefined);
  if (a.error !== undefined) last.current = a.error;
  else if (a.data !== undefined) last.current = undefined;
  return last.current;
}

/** Fewer than this many of the week's trends in the catalog say little as a ranking. */
export const RANKED_MIN = 3;

/** Hero, genres, the week's most watched and the rows computed from the full catalog. */
function Curated({ kind, data }: { kind: 'movies' | 'series'; data: CatalogData }) {
  useNotifier(trending); // the ranking comes once TMDB answers, and again when it refreshes
  const movies = kind === 'movies';
  const m = (list: Movie[]) => list.map(movieCatalogItem);
  const s = (list: Series[]) => list.map(seriesCatalogItem);
  const { featured, genres, rows } = useMemo(() => {
    const genres = (movies ? data.movieGenres : data.seriesGenres).slice(0, 14);
    // Each row: its title, the 60 its rail shows, and all of them for "See all" (worked out then)
    type Row = [string, CatalogItem[], () => CatalogItem[]];
    const row = <T,>(title: string, all: T[], make: (l: T[]) => CatalogItem[]): Row => [title, make(all.slice(0, 60)), () => make(all)];
    const rows: Row[] = movies
      ? [
          row(t('recentlyAdded'), data.recentMovies, m),
          row(t('topRated'), data.topMovies, m),
          row(t('newReleases'), data.newReleases, m),
          ...genres.slice(0, 5).map((g) => row(g, data.moviesIn(g), m)),
        ]
      : [
          row(t('newEpisodes'), data.recentSeries, s),
          row(t('topRated'), data.topSeries, s),
          ...genres.slice(0, 5).map((g) => row(g, data.seriesIn(g), s)),
        ];
    return { featured: movies ? m(data.featuredMovies) : s(data.featuredSeries), genres, rows };
  }, [data, kind]);
  const mostTitle = movies ? t('mostWatchedMovies') : t('mostWatchedSeries');
  const most = trending
    .ofKind(data, !movies, !!profileStore.current.kids)
    .map((x) => (movies ? movieCatalogItem(x as Movie) : seriesCatalogItem(x as Series)));
  return (
    <div>
      {featured.length > 0 && <HeroCarousel items={featured} label={movies ? t('movies') : t('series')} />}
      {genres.length > 0 && (
        <ChipBar
          labels={genres}
          onTap={(g) => openItemGrid(g, movies ? m(data.moviesIn(g)) : s(data.seriesIn(g)))}
        />
      )}
      {most.length >= RANKED_MIN && <RankedRail title={mostTitle} items={most} onSeeAll={() => openItemGrid(mostTitle, most)} />}
      {rows.filter(([, items]) => items.length).map(([title, items, all]) => (
        <ItemRail key={title} title={title} items={items} onSeeAll={() => openItemGrid(title, all())} />
      ))}
    </div>
  );
}

const PAGE = 8000;
const WAIT_FOR_TRAILER = 14000; // its delay and its loading
const HOLD = 20000; // after the remote leaves the hero (for a title's page, say) or pages it
const SWAP = 600; // one page fading into the next: Flutter slides them in this time

const fill = { position: 'absolute', left: 0, top: 0, width: '100%', height: '100%' } as const;

/**
 * The featured titles, one at a time over their artwork, moving on by themselves; the remote
 * pages them with the arrows at the bottom right. It stands still while the remote is on it, for
 * a while after, and while out of sight (a screen or another tab over it).
 */
export function HeroCarousel({ items, label, autofocus = true }: { items: CatalogItem[]; label: string; autofocus?: boolean }) {
  const rail = useRailInset(); // the artwork goes under the side rail, the text keeps clear of it
  const n = items.length;
  const [page, setPage] = useState(0);
  const [before, setBefore] = useState<CatalogItem | null>(null); // the page fading out
  // The page's trailer: on its way, playing, or none (it cannot play)
  const [trailer, setTrailer] = useState<'waiting' | 'playing' | 'none'>('waiting');
  const shownAt = useRef(Date.now());
  const touched = useRef(0); // the last focus change in or out of it, or page turned by hand
  const away = useRef(false);
  const box = useRef<HTMLDivElement>(null);
  const index = page % n; // the list may have shrunk (Home's trends)
  const item = items[index];
  const withTrailer = !!item.trailer && !!trailerServer() && settings.trailers !== 'never' && trailer !== 'none' && !profileStore.current.kids;

  const go = (i: number, user = false) => {
    if (user) touched.current = Date.now();
    const next = ((i % n) + n) % n;
    if (n < 2 || next === index) return;
    setBefore(item);
    shownAt.current = Date.now();
    setTrailer('waiting');
    setPage(next);
  };
  const latest = useRef({ go, index, trailer, withTrailer });
  latest.current = { go, index, trailer, withTrailer };
  const touch = () => {
    touched.current = Date.now();
  };
  // Whether it can be seen, and the remote is not on it
  const idle = () => {
    const el = box.current;
    return !!el && el.offsetParent !== null && !el.contains(document.activeElement);
  };

  useEffect(() => {
    const timer = window.setInterval(() => {
      const el = box.current;
      // Covered: nothing moves under the cover, and once back the page starts afresh, so a short
      // visit to a title's page finds the same one here
      if (!el || el.offsetParent === null) {
        away.current = true;
        return;
      }
      if (away.current) {
        away.current = false;
        shownAt.current = touched.current = Date.now();
      }
      if (el.contains(document.activeElement) || Date.now() - touched.current < HOLD) return;
      const s = latest.current;
      if (s.trailer === 'playing') return; // it moves on when the trailer ends
      if (Date.now() - shownAt.current >= (s.withTrailer ? WAIT_FOR_TRAILER : PAGE)) s.go(s.index + 1);
    }, 1000);
    return () => clearInterval(timer);
  }, [n]);

  // The page faded out goes once the new one is over it
  useEffect(() => {
    if (!before) return;
    const timer = window.setTimeout(() => setBefore(null), SWAP);
    return () => clearTimeout(timer);
  }, [before]);

  const meta = [item.year ? String(item.year) : '', (item.rating || 0) > 0 ? `★ ${item.rating!.toFixed(1)}` : '', ...item.genres.slice(0, 3)].filter(Boolean);
  const fade = before ? 'fade-in' : undefined;
  return (
    <div ref={box} onFocusIn={touch} onFocusOut={touch} style={{ position: 'relative', height: HERO_HEIGHT, overflow: 'hidden' }}>
      {before && (
        <div key={`art:${before.key}`} style={fill}>
          <HeroArt item={before} />
        </div>
      )}
      <div key={`art:${item.key}`} class={fade} style={fill}>
        <HeroArt item={item} />
        {item.trailer && (
          <TrailerBackdrop
            key={item.key}
            load={item.trailer}
            onPlaying={(on) => setTrailer(on ? 'playing' : 'none')}
            onEnd={() => (idle() ? latest.current.go(latest.current.index + 1) : setTrailer('none'))}
          />
        )}
      </div>
      {/* Left and bottom fades keep the text legible on any artwork */}
      <div style={{ ...fill, background: 'linear-gradient(to right, rgba(0,0,0,0.95) 0%, rgba(0,0,0,0.5) 38%, transparent 75%)' }} />
      <div style={{ ...fill, background: 'linear-gradient(to bottom, rgba(0,0,0,0.4) 0%, transparent 45%, #000 100%)' }} />
      <div style={{ position: 'absolute', left: `${rail + 4.8}rem`, bottom: '6.4rem', width: '62rem' }}>
        <div key={`text:${item.key}`} class={fade}>
          <div class="muted" style={{ fontWeight: 700, letterSpacing: '0.25rem', fontSize: 'calc(1.2rem * var(--text))' }}>{label.toUpperCase()}</div>
          <h1 class="display-small clamp2" style={{ marginTop: '1rem' }}>{item.title}</h1>
          {meta.length > 0 && <div class="muted" style={{ marginTop: '1.2rem', fontWeight: 600 }}>{meta.join('   ·   ')}</div>}
          {item.plot && <p class="clamp3" style={{ margin: '1.2rem 0 0', lineHeight: 1.5 }}>{item.plot}</p>}
        </div>
        {/* The same buttons from page to page, so the one the remote is on stays */}
        <div class="wrap" style={{ marginTop: '1.6rem' }} data-fgroup>
          {item.play ? (
            [
              <PrimaryButton key="play" icon="play_arrow_rounded" label={t('play')} onPressed={item.play} autofocus={autofocus} />,
              <SecondaryButton key="details" icon="info_outlined" label={t('details')} onPressed={item.open} />,
            ]
          ) : (
            <PrimaryButton icon="info_outlined" label={t('details')} onPressed={item.open} autofocus={autofocus} />
          )}
        </div>
      </div>
      {n > 1 && (
        <div class="row" style={{ position: 'absolute', right: '4rem', bottom: '2.8rem' }}>
          <div class="row" data-fgroup>
            <RoundIcon icon="chevron_left_rounded" onTap={() => go(index - 1, true)} />
            <div style={{ width: '0.4rem' }} />
            <RoundIcon icon="chevron_right_rounded" onTap={() => go(index + 1, true)} />
          </div>
          <div style={{ width: '1.4rem' }} />
          {items.map((x, i) => (
            <div
              key={x.key}
              style={{
                marginLeft: '0.6rem',
                width: i === index ? '2.2rem' : '0.8rem',
                height: '0.4rem',
                borderRadius: '0.2rem',
                background: i === index ? 'var(--text)' : 'rgba(255,255,255,0.4)',
                transition: 'width 250ms, background-color 250ms',
              }}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function RoundIcon({ icon, onTap }: { icon: string; onTap: () => void }) {
  return (
    <Focusable radius={20} scale={1.06} onTap={onTap}>
      <div style={{ width: '4rem', height: '4rem', background: 'var(--scrim)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Icon icon={icon} size={24} />
      </div>
    </Focusable>
  );
}

/** A hero page's artwork; black while a movie's backdrop is fetched. */
function HeroArt({ item }: { item: CatalogItem }) {
  const load = !item.backdrop ? item.loadBackdrop : undefined;
  const fetched = useAsync<string | null>(() => (load ? load() : Promise.resolve(null)), [item.key]);
  if (load && fetched.data === undefined && fetched.error === undefined) return null;
  return <Backdrop url={(load ? fetched.data : item.backdrop) || undefined} poster={item.poster} />;
}

/**
 * Artwork filling its box: the backdrop, else a flat surface with the poster, sharp, at the right
 * (as Flutter's PosterInPlace): not the poster blown up and blurred, heavy on the TV.
 */
export function Backdrop({ url, poster }: { url?: string; poster?: string }) {
  if (url) return <FadeInImage key={url} src={url} />;
  if (poster) {
    return (
      <div style={{ ...fill, background: 'var(--surface)' }}>
        <FadeInImage key={poster} src={poster} poster />
      </div>
    );
  }
  return null;
}

/** Comes in over 250 ms once decoded, as Flutter's NetImage; a [poster] stands at the right, whole. */
function FadeInImage({ src, poster }: { src: string; poster?: boolean }) {
  const [ready, setReady] = useState(false);
  const place = poster
    ? { position: 'absolute' as const, right: '4.8rem', top: '15%', height: '70%', borderRadius: 'var(--r-card)' }
    : { ...fill, objectFit: 'cover' as const };
  return <img src={src} onLoad={() => setReady(true)} style={{ ...place, opacity: ready ? 1 : 0, transition: 'opacity 250ms' }} />;
}

/** A row of chips to tap, such as genres. With [toHeader] Right at its end goes on to the button in the header above it. */
export function ChipBar({ labels, onTap, toHeader }: { labels: string[]; onTap: (label: string) => void; toHeader?: boolean }) {
  const rail = useRailInset();
  return (
    <div class="row hscroll" data-fgroup data-fheader={toHeader ? '' : undefined} data-inset-left={rail * 20} style={{ padding: `1.4rem 2.4rem 0.6rem ${rail + 2.1}rem` }}>
      {labels.map((g) => (
        <div key={g} style={{ marginRight: '0.4rem', flex: 'none' }}>
          <Focusable radius={8} scale={1.03} onTap={() => onTap(g)}>
            <div style={{ background: 'var(--surface-high)', padding: '1rem 1.6rem', fontWeight: 600 }}>{g}</div>
          </Focusable>
        </div>
      ))}
    </div>
  );
}

/** Section title with "See all". */
export function SectionHeader({ title, onSeeAll }: { title: string; onSeeAll?: () => void }) {
  const rail = useRailInset();
  return (
    <div class="row" style={{ padding: `2.4rem 1.6rem 1rem ${rail + 2.4}rem` }}>
      <h2 class="title-large ellipsis grow">{title}</h2>
      {onSeeAll && (
        <Focusable radius={8} scale={1.03} onTap={onSeeAll}>
          <div class="row" style={{ padding: '0.6rem 0.8rem 0.6rem 1.2rem', fontWeight: 600 }}>
            {t('seeAll')}
            <Icon icon="chevron_right_rounded" size={24} />
          </div>
        </Focusable>
      )}
    </div>
  );
}

const CARD_WIDTH = '15rem';

/**
 * How many of [total] cells to put on the page: [first], then [step] more whenever the remote
 * comes within [ahead] of the last. Flutter's lists build only what is near the screen; here a
 * category of thousands would be thousands of nodes the focus engine measures on every key. Give
 * the returned handler to the cells' container as onFocusIn, and each cell its index as data-i.
 */
function useGrowing(total: number, first: number, step: number, ahead: number): [number, (e: FocusEvent) => void] {
  const [shown, setShown] = useState(first);
  const grow = (e: FocusEvent) => {
    const cell = e.target instanceof Element ? e.target.closest('[data-i]') : null;
    if (cell && Number(cell.getAttribute('data-i')) >= shown - ahead && shown < total) setShown(shown + step);
  };
  return [Math.min(shown, total), grow];
}

export function ItemRail({ title, items, onSeeAll }: { title: string; items: CatalogItem[]; onSeeAll?: () => void }) {
  const [shown, grow] = useGrowing(items.length, 20, 20, 8);
  const rail = useRailInset();
  return (
    <div>
      <SectionHeader title={title} onSeeAll={onSeeAll} />
      <div
        class="row hscroll"
        data-fgroup
        data-inset-left={rail * 20}
        onFocusIn={grow}
        style={{ padding: `0.6rem 2.4rem 0.6rem ${rail + 2.4}rem`, alignItems: 'flex-start' }}
      >
        {items.slice(0, shown).map((item, i) => (
          <div key={item.key} data-i={i} style={{ width: CARD_WIDTH, flex: 'none', marginRight: '1.4rem' }}>
            <PosterCard item={item} />
          </div>
        ))}
      </div>
    </div>
  );
}

/** A row whose items come from the provider, loaded when it comes near the screen. */
function LoadedRail({ title, load }: { title: string; load: () => Promise<CatalogItem[]> }) {
  const [near, setNear] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  const rail = useRef<HTMLDivElement>(null);
  const retried = useRef(false);
  const inset = useRailInset();
  useEffect(() => {
    if (!box.current || near) return;
    // Within the page that scrolls: the margin only grows what it clips by, and the next row was never in sight
    const scroller = box.current.closest<HTMLElement>('[data-scroller]');
    const io = new IntersectionObserver((e) => e.some((x) => x.isIntersecting) && setNear(true), { root: scroller, rootMargin: '800px' });
    io.observe(box.current);
    return () => io.disconnect();
  }, [near]);
  const items = useAsync<CatalogItem[] | null>(() => (near ? load() : Promise.resolve(null)), [near]);
  const failed = useLastError(items);
  // Retry had the remote: the row's first title takes it once there
  useEffect(() => {
    if (items.data && retried.current && rail.current) offer(rail.current.querySelector<HTMLElement>('[data-i] .f'));
  }, [items.data]);
  if (items.data && !items.data.length) return null;
  if (items.data) {
    return (
      <div ref={rail}>
        <ItemRail title={title} items={items.data} onSeeAll={() => openItemGrid(title, items.data!)} />
      </div>
    );
  }
  if (failed !== undefined) {
    return (
      <div>
        <SectionHeader title={title} />
        <div class="row" style={{ padding: `0.6rem 2.4rem 1.2rem ${inset + 2.4}rem` }}>
          {items.error === undefined ? (
            <Spinner />
          ) : (
            <span class="muted">
              <Icon icon="wifi_off_rounded" size={24} />
            </span>
          )}
          <div class="muted" style={{ margin: '0 2rem 0 1.2rem' }}>{errorText(failed)}</div>
          <SecondaryButton
            icon="refresh_rounded"
            label={t('retry')}
            onPressed={() => {
              retried.current = true;
              items.retry();
            }}
          />
        </div>
      </div>
    );
  }
  return (
    <div ref={box}>
      <SectionHeader title={title} />
      <div class="row" style={{ padding: `0.6rem 2.4rem 0.6rem ${inset + 2.4}rem`, overflow: 'hidden' }}>
        {[0, 1, 2, 3, 4, 5, 6, 7].map((i) => (
          <div key={i} style={{ width: CARD_WIDTH, height: '22.5rem', flex: 'none', marginRight: '1.4rem', marginBottom: '3.4rem', background: 'var(--surface)', borderRadius: 'var(--r-card)' }} />
        ))}
      </div>
    </div>
  );
}

/** Poster tile used in rails and grids. */
export function PosterCard({ item, autofocus }: { item: CatalogItem; autofocus?: boolean }) {
  return (
    <div>
      <Focusable onTap={item.open} autofocus={autofocus}>
        <div style={{ position: 'relative', paddingTop: '150%', background: 'var(--surface)' }}>
          <div style={{ position: 'absolute', left: 0, top: 0, width: '100%', height: '100%' }}>
            <NetImage url={item.poster} icon="movie_rounded" cover label={item.title} />
          </div>
          {(item.rating || 0) > 0 && (
            <div class="row" style={{ position: 'absolute', top: '0.8rem', right: '0.8rem', background: 'var(--scrim)', borderRadius: '0.6rem', padding: '0.3rem 0.7rem', fontSize: 'calc(1.2rem * var(--text))', fontWeight: 700 }}>
              <Icon icon="star_rounded" size={13} />
              <span style={{ marginLeft: '0.3rem' }}>{item.rating!.toFixed(1)}</span>
            </div>
          )}
        </div>
      </Focusable>
      <div class="ellipsis" style={{ margin: '0.8rem 0.3rem 0', fontSize: 'calc(1.3rem * var(--text))', fontWeight: 600 }}>{item.title}</div>
      {item.note && <div class="muted clamp2" style={{ margin: '0.2rem 0.3rem 0', fontSize: 'calc(1.2rem * var(--text))', lineHeight: 1.3 }}>{item.note}</div>}
    </div>
  );
}

/**
 * The titles most watched this week that the provider has, each numbered large beside its poster,
 * up to ten.
 */
export function RankedRail({ title, items, onSeeAll }: { title: string; items: CatalogItem[]; onSeeAll?: () => void }) {
  const rail = useRailInset();
  return (
    <div>
      <SectionHeader title={title} onSeeAll={onSeeAll} />
      <div class="row hscroll" data-fgroup data-inset-left={rail * 20} style={{ padding: `0.6rem 2.4rem 0.6rem ${rail + 2.4}rem`, alignItems: 'flex-start' }}>
        {items.slice(0, 10).map((item, i) => (
          <div key={item.key} class="row" style={{ flex: 'none', marginRight: '1.2rem', alignItems: 'flex-end' }}>
            {/* Outlined, so it stays quiet next to the artwork; aligned with the poster's foot */}
            <div class="ranked-number">{i + 1}</div>
            <div style={{ width: CARD_WIDTH, marginLeft: '-1.4rem' }}>
              <PosterCard item={item} />
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

/** [order] names the order they come in, such as "Best match"; else they are the newest first. */
export function openItemGrid(title: string, items: CatalogItem[], order?: string): void {
  push(() => <ItemGridScreen title={title} items={items} order={order} />);
}

type Sort = 'recent' | 'rating' | 'title';

/** Flutter's String.compareTo on lowercased titles: by UTF-16 code units, accents after "z". */
const byTitle = (a: CatalogItem, b: CatalogItem) => {
  const x = a.title.toLowerCase();
  const y = b.title.toLowerCase();
  return x < y ? -1 : x > y ? 1 : 0;
};

/** Every title of a row, category or genre, with sorting. */
function ItemGridScreen({ title, items, order }: { title: string; items: CatalogItem[]; order?: string }) {
  const [sort, setSort] = useState<Sort>('recent');
  const scroller = useRef<HTMLDivElement>(null);
  const sorted = useMemo(
    () =>
      sort === 'recent'
        ? items // lists already arrive newest first
        : items.slice().sort(sort === 'rating' ? (a, b) => (b.rating || 0) - (a.rating || 0) : byTitle),
    [items, sort],
  );
  const labels: Record<Sort, string> = { recent: order || t('sortRecent'), rating: t('topRated'), title: t('sortTitle') };
  const choose = (s: Sort) => {
    if (s === sort) return;
    if (scroller.current) scroller.current.scrollTop = 0; // the grid starts over, from its first titles
    setSort(s);
  };
  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <AppBar title={title} />
      <div class="wrap" data-fgroup style={{ padding: '0 2.4rem 1.2rem' }}>
        {(['recent', 'rating', 'title'] as Sort[]).map((s) => (
          <AppChip key={s} label={labels[s]} selected={s === sort} onTap={() => choose(s)} />
        ))}
      </div>
      {sorted.length ? (
        <div ref={scroller} style={{ flex: 1, overflowY: 'auto', padding: '0.6rem 2.4rem 4rem' }}>
          <ItemGrid key={sort} items={sorted} />
        </div>
      ) : (
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <CapyMessage mood="empty" text={t('nothingHere')} />
        </div>
      )}
    </div>
  );
}

function ItemGrid({ items }: { items: CatalogItem[] }) {
  const [shown, grow] = useGrowing(items.length, 40, 40, 15);
  // Flutter's grid: tiles up to 170 dp wide, 16 dp apart, rows 20 dp apart
  const grid = useMaxExtentGrid(170, 16, 20);
  return (
    <div ref={grid.ref} onFocusIn={grow} style={grid.style}>
      {items.slice(0, shown).map((item, i) => (
        <div key={item.key} data-i={i}>
          <PosterCard item={item} autofocus={i === 0} />
        </div>
      ))}
    </div>
  );
}
