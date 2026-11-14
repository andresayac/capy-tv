// The screensaver (app/lib/ui/screensaver.dart): after a while without a key, outside the player,
// this week's backdrops and the time over whatever screen is open, dialogs and messages included.
// Any key goes back, and does nothing else: the screen behind should not move.
import { render } from 'preact';
import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks';
import { profileStore } from '../data/profiles';
import { settings } from '../data/settings';
import { player } from '../platform/player';
import { Backdrop } from '../ui/backdrop';
import { popToRoot, push, useBack, useOnTop } from '../ui/router';
import { hm } from './guide';
import { confirmProfilePin } from './profiles';

const FADE_IN = 900;
const FADE_OUT = 300;

let timer = 0;
let showing = false;
let playing = false;
let relocking = false;
let hiddenAt = 0;
const RELOCK_AFTER = 20 * 60000; // in the background this long, a profile behind a PIN asks again

/** Starts watching for idleness; every key starts the wait again. */
export function watchIdle(): void {
  document.addEventListener('keydown', restart, true);
  settings.listen(restart);
  // No wait while something plays; when it stops, the whole wait starts from then
  player.listen(() => {
    const now = player.state !== 'idle';
    if (now === playing) return;
    playing = now;
    restart();
  });
  // Back from another app or the TV's home: the key that brought it back never reached the page,
  // and a wait that ran out meanwhile must not greet it with the screensaver
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      clearTimeout(timer);
      hiddenAt = Date.now();
      return;
    }
    restart();
    if (hiddenAt && Date.now() - hiddenAt >= RELOCK_AFTER) relock();
    hiddenAt = 0;
  });
  restart();
}

/**
 * Whoever comes back to a TV left alone may not be who opened this profile: only over what is open,
 * as "Who's watching?" only shows at the root. A movie going on is someone there.
 */
async function relock(): Promise<void> {
  const p = profileStore.current;
  if (relocking || !p.locked || profileStore.choosing || player.state !== 'idle') return;
  relocking = true;
  const ok = await confirmProfilePin(p, false);
  relocking = false;
  if (ok) return;
  popToRoot();
  profileStore.switchProfile();
}

function restart(): void {
  clearTimeout(timer);
  const minutes = settings.screensaverMinutes;
  // Not while something plays: a movie is no still picture
  if (minutes <= 0 || showing || player.state !== 'idle') return;
  timer = window.setTimeout(show, minutes * 60000);
}

/**
 * Over everything, in a layer of its own above the screens, their dialogs and the toast. It fades
 * in over the idle screen; once it covers it, a blank screen goes under it, so what is below stops
 * as under any other screen (slides, trailers).
 */
function show(): void {
  if (player.state !== 'idle' || showing) return restart();
  showing = true;
  const host = document.createElement('div');
  host.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;z-index:1000';
  document.body.appendChild(host);
  render(
    <ScreenSaver
      gone={() => {
        render(null, host);
        if (host.parentNode) host.parentNode.removeChild(host);
        showing = false;
        relock();
        restart();
      }}
    />,
    host,
  );
}

/** The time as Flutter's TimeOfDay.format (guide.tsx hm): "8:15 PM" in English, "20:15" in Spanish. */
function timeNow(): string {
  return hm(new Date());
}

function ScreenSaver({ gone }: { gone: () => void }) {
  const box = useRef<HTMLDivElement>(null);
  const cover = useRef<(() => void) | null>(null); // takes the blank screen under it away
  const leaving = useRef(false);
  const [, tick] = useState(0);

  const leave = () => {
    if (leaving.current) return;
    leaving.current = true;
    // The screen it was over shows again, under it as it fades out
    if (cover.current) cover.current();
    cover.current = null;
    const el = box.current;
    if (!el || typeof el.animate !== 'function') return gone();
    const from = getComputedStyle(el).opacity;
    el.animate([{ opacity: from }, { opacity: 0 }], { duration: FADE_OUT, fill: 'forwards' }).onfinish = gone;
  };

  useLayoutEffect(() => {
    const el = box.current;
    if (el && typeof el.animate === 'function') el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: FADE_IN, fill: 'forwards' });
  }, []);

  useEffect(() => {
    const clock = window.setInterval(() => tick((n) => n + 1), 20000);
    const covered = window.setTimeout(() => {
      if (leaving.current) return;
      // Closed by someone else (the phone's Back, back to the first screen): this goes too
      push<void>((done) => {
        cover.current = done;
        return <Cover onCovered={leave} />;
      }).then(leave);
    }, FADE_IN);
    // Something the phone started playing shows, as over Flutter's route
    const unlisten = player.listen(() => player.state !== 'idle' && leave());
    // Any key leaves, and does nothing else, the ones while it fades out too: taken before the
    // screens and the text fields see them
    const key = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopImmediatePropagation();
      leave();
    };
    document.addEventListener('keydown', key, true);
    return () => {
      clearInterval(clock);
      clearTimeout(covered);
      unlisten();
      document.removeEventListener('keydown', key, true);
    };
  }, []);

  // The phone's Back goes straight to the router
  useBack(() => {
    leave();
    return true;
  });

  return (
    <div ref={box} style={{ width: '100%', height: '100%', background: 'var(--black)' }}>
      {/* Only the time and a line on it: the pictures can shine */}
      <Backdrop veil="rgba(0,0,0,0.3)">
        <div style={{ position: 'absolute', right: '4.8rem', top: '3.6rem', fontSize: '5.6rem', fontWeight: 400, letterSpacing: '-0.1rem' }}>{timeNow()}</div>
      </Backdrop>
    </div>
  );
}

/**
 * The blank screen under the screensaver. A screen opened over it (the phone's movie night, its
 * player) is pushed above Flutter's screensaver route and shows; here the screensaver goes.
 */
function Cover({ onCovered }: { onCovered: () => void }) {
  const top = useOnTop();
  useEffect(() => {
    if (!top) onCovered();
  }, [top]);
  return null;
}
