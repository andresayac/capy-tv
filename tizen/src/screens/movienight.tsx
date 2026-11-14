// Movie night on the TV (app/lib/ui/movie_night_screen.dart): a few titles for a mood, a QR code
// for everyone's phone, the votes as they come, and the winner, ready to play.
import { useEffect, useRef, useState } from 'preact/hooks';
import { CatalogData } from '../data/catalog';
import { Library } from '../data/library';
import { Movie, Series } from '../data/models';
import { profileStore } from '../data/profiles';
import { Mood, Surprise } from '../data/surprise';
import { t } from '../i18n';
import { companionHost } from '../remote/host';
import { MovieNight, NightTitle } from '../remote/movie_night';
import { PosterBackdrop } from '../ui/backdrop';
import { AppBar, PrimaryButton, SecondaryButton, Spinner, useNotifier } from '../ui/components';
import { activeLayer, settle } from '../ui/focus';
import { trailerServer } from '../ui/trailer';
import { movieItem } from './catalog';
import { BridgeFailure, QrCard } from './connect';
import { openMovie, openSeries } from './details';
import { NetImage } from './home';
import { playQueue } from './player';

const TITLES = 6;

export function MovieNightScreen({ data, library, mood, series }: { data: CatalogData; library: Library | null; mood: Mood; series: boolean }) {
  // The Movie or Series behind each title: a picker of its own, so what "Surprise me" offered
  // still counts here, and what is voted on is still offered there
  const [picks] = useState(() => {
    const surprise = new Surprise(data, library, !!profileStore.current.kids);
    const out: (Movie | Series)[] = [];
    for (let i = 0; i < TITLES; i++) {
      const p = surprise.next(mood, series);
      if (p) out.push(p);
    }
    return out;
  });
  const [night] = useState(
    () =>
      new MovieNight(
        picks.map((x): NightTitle => {
          const movie = 'extension' in x;
          return { id: x.id, title: x.name, year: x.year, rating: x.rating, poster: movie ? (x as Movie).poster : (x as Series).cover, plot: x.plot };
        }),
      ),
  );
  const [winner, setWinner] = useState<NightTitle | null>(null);
  const root = useRef<HTMLDivElement>(null);
  useNotifier(companionHost);
  useNotifier(night);

  useEffect(() => {
    if (picks.length < 2) return;
    companionHost.night = night;
    // The page comes from the sync server: over https, the phones need posters that load there
    if (/^https:/i.test(trailerServer())) night.forPhones();
    companionHost.hold(trailerServer());
    return () => {
      if (companionHost.night === night) companionHost.night = null;
      companionHost.release();
    };
  }, []);

  // The winner takes the place of the button that had the focus: on to Play (or Details) at once
  useEffect(() => {
    const screen = root.current && (root.current.closest('.screen') as HTMLElement | null);
    if (winner && screen && screen === activeLayer()) settle(screen);
  }, [winner]);

  const votes = (x: NightTitle) => `${t('nightYes')} ${night.yes(x.id)}   ·   ${t('nightNo')} ${night.no(x.id)}`;
  const body = () => {
    if (picks.length < 2) return <p class="muted" style={{ textAlign: 'center', marginTop: '8rem' }}>{t('nightNotEnough')}</p>;
    if (winner) {
      const pick = picks[night.titles.indexOf(winner)];
      const movie = 'extension' in pick ? (pick as Movie) : null;
      return (
        <div class="row" style={{ justifyContent: 'center', height: '100%' }}>
          <div style={{ width: '22rem', height: '33rem', borderRadius: 'var(--r-card)', overflow: 'hidden', background: 'var(--surface)' }}>
            <NetImage url={winner.poster} icon="movie_rounded" cover label={winner.title} />
          </div>
          <div style={{ marginLeft: '3.6rem', maxWidth: '52rem' }}>
            <div class="muted" style={{ fontWeight: 700, letterSpacing: '0.2rem' }}>{t('nightWinnerTitle').toUpperCase()}</div>
            <h1 class="display-small" style={{ marginTop: '0.8rem' }}>{winner.title}</h1>
            <div class="muted" style={{ marginTop: '1rem', fontWeight: 600 }}>{votes(winner)}</div>
            <div class="wrap" data-fgroup style={{ marginTop: '2.4rem' }}>
              {movie && <PrimaryButton icon="play_arrow_rounded" label={t('play')} onPressed={() => playQueue([movieItem(movie)])} autofocus />}
              <SecondaryButton
                icon="info_outlined"
                label={t('details')}
                autofocus={!movie}
                onPressed={() => (movie ? openMovie(movie) : openSeries(pick as Series))}
              />
            </div>
          </div>
        </div>
      );
    }
    const link = companionHost.votingLink();
    return (
      <div style={{ padding: '0.8rem 3.2rem 2.4rem' }}>
        <div class="row" style={{ alignItems: 'flex-start' }}>
          {link ? <QrCard data={link} size={160} /> : companionHost.failure ? null : <Spinner size={32} />}
          <div class="grow" style={{ marginLeft: '3.2rem' }}>
            <h1 class="headline-medium">{t('nightTitle')}</h1>
            <p class="muted" style={{ lineHeight: 1.5 }}>
              {companionHost.failure ? (companionHost.failure === 'noServer' ? t('connectNeedsServer') : t('connectServerDown')) : t('nightBodyTv')}
            </p>
            <div style={{ fontWeight: 600 }}>{t('nightVoters', { count: night.voters })}</div>
            <div class="wrap" data-fgroup style={{ marginTop: '1.2rem' }}>
              <PrimaryButton icon="emoji_events_outlined" label={t('nightWinner')} onPressed={night.voters ? () => setWinner(night.winner) : null} autofocus />
              {/* Nobody can vote yet: Retry, or Sync to set up a server */}
              <BridgeFailure autofocus={!night.voters} />
            </div>
          </div>
        </div>
        {/* All on the screen: the six posters in one row under the code, their votes in sight as they come */}
        <div class="row" style={{ marginTop: '2rem', alignItems: 'flex-start' }}>
          {night.titles.map((x) => (
            <div key={x.id} style={{ width: '12rem', marginRight: '1.6rem', flex: 'none' }}>
              <div style={{ height: '18rem', borderRadius: 'var(--r-card)', overflow: 'hidden', background: 'var(--surface)' }}>
                <NetImage url={x.poster} icon="movie_rounded" cover label={x.title} />
              </div>
              <div class="ellipsis" style={{ fontWeight: 600, marginTop: '0.8rem' }}>{x.title}</div>
              {/* As the votes come */}
              <div class="muted" style={{ fontSize: 'calc(1.3rem * var(--text-scale))' }}>{votes(x)}</div>
            </div>
          ))}
        </div>
      </div>
    );
  };
  return (
    <PosterBackdrop>
      <div ref={root} style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        <AppBar title={t('movieNight')} />
        <div style={{ flex: 1, overflowY: 'auto' }}>{body()}</div>
      </div>
    </PosterBackdrop>
  );
}
