// A movie's or a series' page (app/lib/ui/detail_screens.dart): wide artwork that fades into
// black with the title block over it, then the synopsis, episodes, versions and similar titles.
import { ComponentChild, ComponentChildren } from 'preact';
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { CatalogData } from '../data/catalog';
import { episodeRef, Library, MediaRef, movieRef, progressOf, resumable, seriesRef } from '../data/library';
import { Episode, Movie, Series, SeriesDetail, splitGenres } from '../data/models';
import { categoryLabel, episodeName, episodeSubtitle } from '../ui/labels';

/** "3. Its title", or "Episode 3" for one with none. */
function episodeLine(e: Episode, seriesName: string): string {
  const name = episodeName(e, seriesName);
  return name === null ? t('episodeNumber', { number: String(e.number) }) : `${e.number}. ${name}`;
}
import { Category } from '../data/source';
import { movieTrailer, seriesTrailer, youtubeId } from '../data/trailers';
import { language, t } from '../i18n';
import { profileStore } from '../data/profiles';
import { openYouTube } from '../platform/youtube';
import { session } from '../session';
import { AppChip, Focusable, IconButton, Panel, PrimaryButton, SecondaryButton, Spinner, useNotifier } from '../ui/components';
import { offer } from '../ui/focus';
import { back, push, toast } from '../ui/router';
import { TrailerBackdrop } from '../ui/trailer';
import { Backdrop, CatalogItem, ItemRail, LoadError, movieCatalogItem, movieItem, SectionHeader, seriesCatalogItem, useLastError } from './catalog';
import { NetImage, useAsync } from './home';
import { Bar, clock, playQueue } from './player';

/** "1 h 41 min", or "45 min" under an hour: whole minutes, as Flutter's Duration counts them. */
export function formatRuntime(secs: number): string {
  const hours = Math.floor(secs / 3600);
  const mins = Math.floor(secs / 60);
  return hours > 0 ? t('hoursMinutes', { h: hours, m: mins % 60 }) : t('minutes', { n: Math.max(1, mins) });
}

/** A date with its year and its month short ("Mar 26, 2026" / "26 mar 2026"), as Flutter's yMMMd. */
export function formatDate(d: Date): string {
  try {
    // ICU ends Spanish short months with a period ("mar."), which Flutter's intl leaves out
    return d.toLocaleDateString(language, { day: 'numeric', month: 'short', year: 'numeric' }).replace(/([^\d\s.])\.(?=[\s,]|$)/g, '$1');
  } catch {
    return d.toDateString();
  }
}

/** First names of a comma-separated cast list. */
const castList = (cast: string) =>
  cast
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .slice(0, 6)
    .join(', ');

/** "4.2 Mbps · 1.8 GB · MKV", or null when the record gives neither bitrate nor size. */
function quality(m: Movie): string | null {
  if (m.bitrateKbps === undefined && m.sizeBytes === undefined) return null;
  return [
    (m.bitrateKbps || 0) > 0 ? `${(m.bitrateKbps! / 1000).toFixed(1)} Mbps` : '',
    (m.sizeBytes || 0) > 0 ? `${(m.sizeBytes! / 1073741824).toFixed(1)} GB` : '',
    m.extension.toUpperCase(),
  ]
    .filter(Boolean)
    .join(' · ');
}

/** The provider's trailer, whole and with sound, in the TV's YouTube app. Only YouTube: a provider can put any address there. */
function TrailerButton({ trailer }: { trailer: string }) {
  const id = youtubeId(trailer);
  if (!id || profileStore.current.kids) return null;
  const open = () => {
    openYouTube(`https://www.youtube.com/watch?v=${id}`, id).then((ok) => ok || toast(t('errorUnknown')));
  };
  return <SecondaryButton icon="smart_display_outlined" label={t('trailer')} onPressed={open} />;
}

/** Opens [movie]'s page, which can then give its place to another version of it. */
export function openMovie(movie: Movie, versions?: Movie[]): void {
  push((done) => <MovieDetailScreen movie={movie} versions={versions} close={done} />);
}

export function openSeries(series: Series, versions?: Series[]): void {
  push((done) => <SeriesDetailScreen series={series} versions={versions} close={done} />);
}

/**
 * Another version's page in place of this one (Flutter's pushReplacement): the screen below keeps
 * where the remote goes back to. The new page goes over this one before this one goes; a page
 * opened without [close] goes first, and the new one comes once the screen below has the focus
 * again, as push() keeps what has it.
 */
function replacePage(close: (() => void) | undefined, render: (done: () => void) => ComponentChild): void {
  if (close) {
    push(render);
    close();
  } else {
    back();
    window.setTimeout(() => push(render), 0);
  }
}

/**
 * [trailer] plays once behind the title, silent, if there is one. Each time [ready] changes (what
 * loaded late), the page's autofocus element is offered the remote, as Flutter's autofocus takes
 * it when nothing in the route has it yet.
 */
function DetailPage({ backdrop, poster, title, trailer, ready, children }: { backdrop?: string; poster?: string; title: ComponentChildren; trailer?: () => Promise<string | null>; ready?: unknown; children?: ComponentChildren }) {
  const [ended, setEnded] = useState(false);
  const page = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (ready && page.current) offer(page.current.querySelector<HTMLElement>('[data-autofocus]'));
  }, [ready]);
  return (
    <div ref={page} style={{ position: 'relative', height: '100%' }}>
      {/* Over the page, not in it, so it stays put while the page scrolls (Flutter's app bar). It
          is where the remote starts while a series loads, and yields to its Play once there */}
      <div data-fyield style={{ position: 'absolute', left: '0.6rem', top: '0.6rem', zIndex: 1, background: 'var(--scrim)', borderRadius: '99rem' }}>
        <IconButton icon="arrow_back_rounded" onPressed={back} />
      </div>
      <div style={{ height: '100%', overflowY: 'auto', paddingBottom: '5.6rem', boxSizing: 'border-box' }}>
        {/* Flutter's (540 * 0.64).clamp(440, 620) on a 540 dp tall TV: the synopsis shows below it */}
        <div style={{ position: 'relative', height: '44rem' }}>
          <Backdrop url={backdrop} poster={poster} />
          {trailer && !ended && <TrailerBackdrop load={trailer} onPlaying={() => {}} onEnd={() => setEnded(true)} />}
          <div style={{ position: 'absolute', left: 0, top: 0, right: 0, bottom: 0, background: 'linear-gradient(to bottom, rgba(0,0,0,0.5) 0%, rgba(0,0,0,0.1) 30%, rgba(0,0,0,0.8) 75%, #000 100%)' }} />
          <div style={{ position: 'absolute', left: 0, top: 0, right: 0, bottom: 0, background: 'linear-gradient(to right, rgba(0,0,0,0.8) 0%, transparent 70%)' }} />
          <div style={{ position: 'absolute', left: '4.8rem', right: '4.8rem', bottom: '0.8rem' }}>{title}</div>
        </div>
        {children}
      </div>
    </div>
  );
}

function TitleBlock(p: { title: string; poster?: string; originalTitle?: string; facts: string[]; genres: string[]; actions: ComponentChildren }) {
  return (
    <div class="row" style={{ alignItems: 'flex-end' }}>
      <div style={{ width: '19rem', flex: 'none', borderRadius: 'var(--r-card)', overflow: 'hidden', position: 'relative', paddingTop: '28.5rem', background: 'var(--surface)' }}>
        <div style={{ position: 'absolute', left: 0, top: 0, width: '100%', height: '100%' }}>
          <NetImage url={p.poster} icon="movie_rounded" cover label={p.title} />
        </div>
      </div>
      <div class="grow" style={{ marginLeft: '3.2rem' }}>
        <h1 class="display-small clamp3">{p.title}</h1>
        {p.originalTitle && p.originalTitle.toLowerCase() !== p.title.toLowerCase() && (
          <div class="muted" style={{ marginTop: '0.6rem', fontStyle: 'italic' }}>{p.originalTitle}</div>
        )}
        {p.facts.length > 0 && <div style={{ marginTop: '1.2rem', fontWeight: 600 }}>{p.facts.join('   ·   ')}</div>}
        {p.genres.length > 0 && (
          <div class="wrap" style={{ marginTop: '0.9rem' }}>
            {p.genres.map((g) => (
              <span key={g} style={{ background: 'rgba(255,255,255,0.2)', borderRadius: '0.6rem', padding: '0.5rem 1rem', fontWeight: 600, fontSize: 'calc(1.3rem * var(--text-scale))', margin: '0.3rem' }}>{g}</span>
            ))}
          </div>
        )}
        <div class="wrap" data-fgroup style={{ marginTop: '1.6rem' }}>{p.actions}</div>
      </div>
    </div>
  );
}

/** Synopsis on the left, a facts table on the right. */
function Overview({ plot, facts }: { plot?: string; facts: [string, string][] }) {
  return (
    <div class="row" style={{ alignItems: 'flex-start', padding: '2.4rem 4.8rem 0.8rem' }}>
      <div style={{ flex: 3 }}>{plot && <p class="body-large" style={{ fontSize: 'calc(1.7rem * var(--text-scale))', lineHeight: 1.6, margin: 0 }}>{plot}</p>}</div>
      <div style={{ width: '5.6rem' }} />
      <div style={{ flex: 2 }}>
        {facts.map(([label, value]) => (
          <div key={label} style={{ marginBottom: '1.4rem' }}>
            <div class="muted" style={{ fontSize: 'calc(1.3rem * var(--text-scale))' }}>{label}</div>
            <div style={{ fontWeight: 500, lineHeight: 1.4, marginTop: '0.3rem' }}>{value}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

const Loading = () => (
  <div class="row" style={{ justifyContent: 'center', padding: '2.4rem' }}>
    <Spinner />
  </div>
);

/** "More like this", once the catalog is there: a page opened while it loads gets it when it comes. */
function MoreLikeThis({ movie, series }: { movie?: Movie; series?: Series }) {
  const { catalog } = session();
  const data = useAsync<CatalogData>(() => catalog.load(), []);
  const d = data.data;
  const items = useMemo<CatalogItem[]>(
    () => (!d ? [] : movie ? d.similarMovies(movie).map(movieCatalogItem) : series ? d.similarSeries(series).map(seriesCatalogItem) : []),
    [d, movie, series],
  );
  return items.length ? <ItemRail title={t('moreLikeThis')} items={items} /> : null;
}

/** "My list" toggle. */
export function FavoriteButton({ refOf }: { refOf: MediaRef }) {
  const { library } = session();
  useNotifier(library);
  const on = library.isFavorite(refOf);
  return (
    <SecondaryButton
      icon={on ? 'favorite_rounded' : 'favorite_border_rounded'}
      label={on ? t('inMyList') : t('myList')}
      onPressed={() => library.toggleFavorite(refOf)}
    />
  );
}

/**
 * The versions of a title the provider lists more than once, by the category each is in (often a
 * language or a quality: "Latino", "4K"); the one shown is marked, the others a tap away.
 */
function Versions({ series, versions, current, open }: { series: boolean; versions: { category?: string; detail?: string }[]; current: number; open: (i: number) => void }) {
  const { source } = session();
  const cats = useAsync<Category[]>(() => (series ? source.seriesCategories() : source.movieCategories()).catch(() => []), []);
  const names: Record<string, string> = {};
  for (const c of cats.data || []) names[c.id] = categoryLabel(c.name);
  return (
    <div style={{ padding: '2.8rem 4.8rem 0' }}>
      <h2 class="title-large">{t('versionsCount', { count: versions.length })}</h2>
      <div class="wrap" data-fgroup style={{ marginTop: '0.6rem' }}>
        {versions.map((v, i) => (
          <Focusable key={i} radius={8} scale={1.03} onTap={i === current ? undefined : () => open(i)}>
            <div style={{ background: i === current ? 'var(--text)' : 'var(--surface-high)', color: i === current ? 'var(--black)' : 'var(--text)', padding: '1rem 1.6rem', fontWeight: 600 }}>
              {[(v.category && names[v.category]) || t('versionNumber', { n: i + 1 }), v.detail || ''].filter(Boolean).join(' · ')}
            </div>
          </Focusable>
        ))}
      </div>
    </div>
  );
}

export function MovieDetailScreen({ movie, versions: given, picked, close }: { movie: Movie; versions?: Movie[]; picked?: boolean; close?: () => void }) {
  const { source, library, catalog } = session();
  useNotifier(library);
  const full = useAsync<Movie>(() => (source.movieDetail ? source.movieDetail(movie) : Promise.resolve(movie)), [movie.id]);
  // Without the full record the listing still makes the page, and Play works: the error and Retry
  // sit where its facts would be
  const failed = useLastError(full);
  const m = full.data || movie;
  const loading = !full.data && !full.error;
  const saved = library.entry(movieRef(m));
  const versions = given && given.length ? given : catalog.loaded ? catalog.loaded.versionsOf(movie) : [];
  const facts = [m.year ? String(m.year) : '', m.durationSecs ? formatRuntime(m.durationSecs) : '', (m.rating || 0) > 0 ? `★ ${m.rating!.toFixed(1)}` : '', m.ageRating || ''].filter(Boolean);
  const table: [string, string][] = [];
  if (m.director) table.push([t('director'), m.director]);
  if (m.cast) table.push([t('cast'), castList(m.cast)]);
  if (m.releaseDate) table.push([t('releaseDate'), formatDate(m.releaseDate)]);
  if (m.country) table.push([t('country'), m.country]);
  const file = loading ? null : quality(m);
  if (file) table.push([t('quality'), file]);
  // With its other versions, should this one fail; the fastest first unless this one was picked in Versions
  const play = () => playQueue([{ ...movieItem(m), pinned: !!picked }]);
  return (
    // [ready]: a Retry that worked goes with the remote on it, which Play then takes
    <DetailPage backdrop={m.backdrop} poster={m.poster} trailer={profileStore.current.kids ? undefined : () => movieTrailer(source, movie)} ready={full.data} title={
      <TitleBlock
        title={m.name}
        poster={m.poster}
        originalTitle={m.originalName}
        facts={facts}
        genres={splitGenres(m.genre)}
        actions={[
          <PrimaryButton
            key="play"
            autofocus
            icon="play_arrow_rounded"
            label={saved && resumable(saved) ? `${t('continueAction')} · ${clock(saved.pos)}` : t('play')}
            onPressed={play}
          />,
          <FavoriteButton key="fav" refOf={movieRef(m)} />,
          m.trailer ? <TrailerButton key="trailer" trailer={m.trailer} /> : null,
        ]}
      />
    }>
      {saved && resumable(saved) && (
        <div style={{ padding: '0.4rem 4.8rem 0', width: '30rem' }}>
          <Bar value={progressOf(saved)} />
        </div>
      )}
      <Overview plot={m.plot} facts={table} />
      {failed !== undefined ? <LoadError error={failed} retry={full.retry} busy={loading} /> : loading && <Loading />}
      {versions.length > 1 && (
        <Versions
          series={false}
          current={versions.findIndex((v) => v.id === movie.id)}
          versions={versions.map((v) => ({ category: v.categoryId, detail: v.extension.toUpperCase() }))}
          open={(i) => replacePage(close, (done) => <MovieDetailScreen movie={versions[i]} versions={versions} picked close={done} />)}
        />
      )}
      <MoreLikeThis movie={m} />
    </DetailPage>
  );
}

/** Where "play" starts: the episode in progress, the one after the last finished, or the first. */
function startPoint(d: SeriesDetail, library: Library): [Episode, boolean] | null {
  const all = ([] as Episode[]).concat(...d.seasons.map((s) => s.episodes));
  if (!all.length) return null;
  const last = library.lastEpisodeOf(d.series.id);
  const i = last ? all.findIndex((x) => x.id === last.ref.id) : -1;
  // Never watched: the first real episode, specials (season 0) aside
  if (i < 0 || !last) return [all.filter((x) => x.season > 0)[0] || all[0], false];
  if (resumable(last)) return [all[i], true];
  if (last.dur <= 0 || progressOf(last) < 0.95) {
    // Opened and left at once is not watched: the one left half way, else the same one again
    const open = library.history.filter((h) => h.ref.kind === 'episode' && h.ref.seriesId === d.series.id && resumable(h))[0];
    const j = open ? all.findIndex((x) => x.id === open.ref.id) : -1;
    return j >= 0 ? [all[j], true] : [all[i], false];
  }
  return i + 1 < all.length ? [all[i + 1], false] : [all[i], false];
}

export function SeriesDetailScreen({ series, versions: given, close }: { series: Series; versions?: Series[]; close?: () => void }) {
  const { source, library, catalog } = session();
  useNotifier(library);
  const detail = useAsync<SeriesDetail>(() => source.seriesDetail(series), [series.id]);
  // Without its episodes the page has no Play: the error and Retry take the remote instead
  const failed = useLastError(detail);
  const [chosen, setChosen] = useState<number | null>(null);
  const d = detail.data;
  const s = d ? d.series : series;
  const start = d ? startPoint(d, library) : null;
  const seasons = d ? d.seasons : [];
  const seasonNumber = chosen !== null ? chosen : start ? start[0].season : seasons.length ? seasons[0].number : null;
  const season = seasons.filter((x) => x.number === seasonNumber)[0];
  const episodes = season ? season.episodes : [];
  const info = d && seasonNumber !== null ? d.seasonInfo[seasonNumber] : undefined;
  const versions = given && given.length ? given : catalog.loaded ? catalog.loaded.seriesVersionsOf(series) : [];

  /** Plays [e] with the rest of the series queued after it, so "next episode" just works. */
  const play = (e: Episode) => {
    if (!d) return;
    const all = ([] as Episode[]).concat(...d.seasons.map((x) => x.episodes));
    playQueue(
      all.map((x) => ({
        url: source.episodeUrl(x),
        title: d.series.name,
        subtitle: episodeSubtitle(x, d.series.name),
        ref: episodeRef(d.series, x),
      })),
      Math.max(0, all.findIndex((x) => x.id === e.id)),
    );
  };

  const facts = [s.year ? String(s.year) : '', seasons.length ? t('seasonsCount', { n: seasons.length }) : '', (s.rating || 0) > 0 ? `★ ${s.rating!.toFixed(1)}` : ''].filter(Boolean);
  const table: [string, string][] = [];
  if (s.director) table.push([t('director'), s.director]);
  if (s.cast) table.push([t('cast'), castList(s.cast)]);
  if (s.episodeRuntimeMins) table.push([t('duration'), formatRuntime(s.episodeRuntimeMins * 60)]);
  return (
    // The provider's trailer, else TMDB's; read when the delay ends, from the full record if it came
    <DetailPage backdrop={s.backdrop} poster={s.cover} trailer={profileStore.current.kids ? undefined : () => seriesTrailer(s)} ready={d || detail.error} title={
      <TitleBlock
        title={s.name}
        poster={s.cover}
        facts={facts}
        genres={splitGenres(s.genre)}
        actions={[
          start ? (
            <PrimaryButton
              key="play"
              autofocus
              icon="play_arrow_rounded"
              label={`${start[1] ? t('continueAction') : t('play')}  S${start[0].season} · E${start[0].number}`}
              onPressed={() => play(start[0])}
            />
          ) : null,
          <FavoriteButton key="fav" refOf={seriesRef(s)} />,
          s.trailer ? <TrailerButton key="trailer" trailer={s.trailer} /> : null,
        ]}
      />
    }>
      <Overview plot={s.plot} facts={table} />
      {failed !== undefined ? <LoadError error={failed} retry={detail.retry} busy={!d && detail.error === undefined} autofocus /> : !d && <Loading />}
      {seasons.length > 1 && (
        <div class="row hscroll" data-fgroup style={{ padding: '1.2rem 4.8rem 0.8rem' }}>
          {seasons.map((x) => (
            <div key={x.number} style={{ marginRight: '0.8rem', flex: 'none' }}>
              <AppChip
                label={(d && d.seasonInfo[x.number] && d.seasonInfo[x.number].name) || t('season', { n: x.number })}
                selected={x.number === seasonNumber}
                onTap={() => setChosen(x.number)}
              />
            </div>
          ))}
        </div>
      )}
      {seasonNumber !== null && (
        <div>
          <SectionHeader title={(info && info.name) || t('season', { n: seasonNumber })} />
          <div style={{ padding: '0 4.8rem 1.2rem' }}>
            <div class="muted" style={{ fontWeight: 600 }}>
              {[info && info.airDate ? String(info.airDate.getFullYear()) : '', t('episodesCount', { n: episodes.length }), info && (info.rating || 0) > 0 ? `★ ${info.rating!.toFixed(1)}` : '']
                .filter(Boolean)
                .join('   ·   ')}
            </div>
            {/* Many panels repeat the series synopsis as the season overview */}
            {info && info.overview && info.overview !== s.plot && <p class="muted" style={{ maxWidth: '82rem', lineHeight: 1.5 }}>{info.overview}</p>}
          </div>
        </div>
      )}
      <div data-fgroup>
        {episodes.map((e) => {
          const h = library.entry(episodeRef(s, e));
          const meta = [e.durationSecs ? formatRuntime(e.durationSecs) : '', e.releaseDate ? formatDate(e.releaseDate) : '', (e.rating || 0) > 0 ? `★ ${e.rating!.toFixed(1)}` : ''].filter(Boolean);
          return (
            <div key={e.id} style={{ padding: '0 4.5rem 1rem' }}>
              <Focusable scale={1.01} onTap={() => play(e)}>
                <Panel style={{ borderRadius: 0, padding: '1rem' }}>
                  <div class="row" style={{ alignItems: 'flex-start' }}>
                    <div style={{ width: '22rem', height: '12.4rem', flex: 'none', position: 'relative', borderRadius: '0.6rem', overflow: 'hidden', background: 'var(--surface-high)' }}>
                      <NetImage url={e.image || s.backdrop} icon="play_circle_outlined" cover />
                      {h && progressOf(h) > 0 && (
                        <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, height: '0.4rem', background: 'rgba(255,255,255,0.2)' }}>
                          <div style={{ width: `${progressOf(h) * 100}%`, height: '100%', background: 'var(--text)' }} />
                        </div>
                      )}
                    </div>
                    <div class="grow" style={{ marginLeft: '1.8rem' }}>
                      <div class="clamp2" style={{ fontWeight: 700, fontSize: 'calc(1.5rem * var(--text-scale))' }}>{episodeLine(e, s.name)}</div>
                      {meta.length > 0 && <div class="muted" style={{ fontSize: 'calc(1.3rem * var(--text-scale))', marginTop: '0.4rem' }}>{meta.join('   ·   ')}</div>}
                      {e.plot && (
                        <p class="muted clamp3" style={{ margin: '0.8rem 0 0', lineHeight: 1.45 }}>{e.plot}</p>
                      )}
                    </div>
                  </div>
                </Panel>
              </Focusable>
            </div>
          );
        })}
      </div>
      {versions.length > 1 && (
        <Versions
          series
          current={versions.findIndex((v) => v.id === series.id)}
          versions={versions.map((v) => ({ category: v.categoryId }))}
          open={(i) => replacePage(close, (done) => <SeriesDetailScreen series={versions[i]} versions={versions} close={done} />)}
        />
      )}
      <MoreLikeThis series={s} />
    </DetailPage>
  );
}
