// "Surprise me" (app/lib/ui/surprise_screen.dart): a mood, movies or series, then one title to
// watch, and another if that one does not appeal.
import { useMemo, useState } from 'preact/hooks';
import type { CatalogData } from '../data/catalog';
import { Movie, Series, splitGenres } from '../data/models';
import { profileStore } from '../data/profiles';
import { Mood, MOODS, Surprise } from '../data/surprise';
import { StringKey, t } from '../i18n';
import { session } from '../session';
import { PosterBackdrop } from '../ui/backdrop';
import { AppBar, AppChip, Panel, PrimaryButton, SecondaryButton } from '../ui/components';
import { push } from '../ui/router';
import { movieItem } from './catalog';
import { openMovie, openSeries } from './details';
import { Failed, Loading, NetImage, useAsync } from './home';
import { MovieNightScreen } from './movienight';
import { playQueue } from './player';

const NAMES: Record<Mood, StringKey> = {
  laugh: 'moodLaugh',
  action: 'moodAction',
  suspense: 'moodSuspense',
  family: 'moodFamily',
  romance: 'moodRomance',
  scary: 'moodScary',
  different: 'moodDifferent',
};

export function openSurprise(): void {
  push(() => <SurpriseLoading />);
}

/** Opens at once: the catalog may still be on its way, and this says how far it has got. */
function SurpriseLoading() {
  const { catalog, library } = session();
  const data = useAsync<CatalogData>(() => catalog.load(), []);
  const surprise = useMemo(() => (data.data ? new Surprise(data.data, library, !!profileStore.current.kids) : null), [data.data]);
  if (surprise) return <SurpriseScreen surprise={surprise} />;
  return (
    <PosterBackdrop>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        <AppBar title={t('surpriseMe')} />
        <div style={{ flex: 1, minHeight: 0 }}>{data.error ? <Failed error={data.error} retry={data.retry} /> : <Loading />}</div>
      </div>
    </PosterBackdrop>
  );
}

function SurpriseScreen({ surprise }: { surprise: Surprise }) {
  const kids = !!profileStore.current.kids;
  const moods = (Object.keys(MOODS) as Mood[]).filter((m) => !(kids && m === 'scary'));
  const [mood, setMood] = useState<Mood>(moods[0]);
  const [seriesPicked, setSeries] = useState(false);
  const series = seriesPicked && surprise.data.series.length > 0; // none to choose from: movies
  // A list that says no genres nor ratings: no moods to choose from
  const byMood = surprise.picksByMood(series);
  const [pick, setPick] = useState<Movie | Series | null>(null);
  const [none, setNone] = useState(false);

  const next = () => {
    const p = surprise.next(mood, series);
    setPick(p);
    setNone(!p);
  };

  return (
    <PosterBackdrop>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        <AppBar title={t('surpriseMe')} />
        <div style={{ flex: 1, overflowY: 'auto', padding: '0.8rem 2.4rem 4rem' }}>
          {byMood ? (
            <div>
              <h2 class="title-large">{t('surpriseQuestion')}</h2>
              <div class="wrap" data-fgroup style={{ marginTop: '0.8rem' }}>
                {moods.map((m, i) => (
                  <AppChip key={m} label={t(NAMES[m])} selected={m === mood} autofocus={i === 0} onTap={() => setMood(m)} />
                ))}
              </div>
            </div>
          ) : (
            <p class="muted">{t(kids ? 'surpriseNoInfoKids' : 'surpriseAtRandom')}</p>
          )}
          <div class="wrap" data-fgroup style={{ marginTop: '0.8rem' }}>
            <AppChip label={t('movies')} icon="movie_outlined" selected={!series} autofocus={!byMood} onTap={() => setSeries(false)} />
            {surprise.data.series.length > 0 && <AppChip label={t('series')} icon="video_library_outlined" selected={series} onTap={() => setSeries(true)} />}
          </div>
          <div class="wrap" style={{ marginTop: '1.4rem' }}>
            <PrimaryButton icon="casino_outlined" label={pick ? t('surpriseAnother') : t('surpriseGo')} onPressed={next} />
            {/* Everyone in the room votes from their phone */}
            <SecondaryButton icon="how_to_vote_outlined" label={t('movieNight')} onPressed={() => push(() => <MovieNightScreen data={surprise.data} library={surprise.library} mood={mood} series={series} />)} />
          </div>
          {none && <p class="muted" style={{ marginTop: '2.8rem' }}>{t('surpriseNone')}</p>}
          {pick && <Pick pick={pick} />}
        </div>
      </div>
    </PosterBackdrop>
  );
}

/** The title picked: its poster, what it is, and the way to watch it. */
function Pick({ pick }: { pick: Movie | Series }) {
  const movie = 'extension' in pick ? (pick as Movie) : null;
  const poster = movie ? movie.poster : (pick as Series).cover;
  const meta = [pick.year ? String(pick.year) : '', (pick.rating || 0) > 0 ? `★ ${pick.rating!.toFixed(1)}` : '', ...splitGenres(pick.genre).slice(0, 3)].filter(Boolean);
  return (
    <div style={{ marginTop: '2.8rem' }}>
      <Panel style={{ padding: '2rem' }}>
        <div class="row" style={{ alignItems: 'flex-start' }}>
          <div style={{ width: '15rem', height: '22.5rem', flex: 'none', borderRadius: 'var(--r-card)', overflow: 'hidden', background: 'var(--surface-high)' }}>
            <NetImage url={poster} icon="movie_rounded" cover label={pick.name} />
          </div>
          <div class="grow" style={{ marginLeft: '2rem' }}>
            <h2 class="headline-medium" style={{ fontSize: 'calc(2.4rem * var(--text))' }}>{pick.name}</h2>
            <div class="muted" style={{ marginTop: '0.8rem', fontWeight: 600 }}>{meta.join('   ·   ')}</div>
            {pick.plot && <p class="clamp3" style={{ lineHeight: 1.5, margin: '1.2rem 0 0' }}>{pick.plot}</p>}
            <div class="wrap" data-fgroup style={{ marginTop: '1.4rem' }}>
              {movie && <PrimaryButton icon="play_arrow_rounded" label={t('play')} onPressed={() => playQueue([movieItem(movie)])} autofocus />}
              <SecondaryButton
                icon="info_outlined"
                label={t('details')}
                onPressed={() => (movie ? openMovie(movie) : openSeries(pick as Series))}
                autofocus={!movie}
              />
            </div>
          </div>
        </div>
      </Panel>
    </div>
  );
}
