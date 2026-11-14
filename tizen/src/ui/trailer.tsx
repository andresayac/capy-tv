// A trailer playing silently behind a hero page (app/lib/ui/trailer.dart): YouTube's own player,
// without controls, for a short stretch past the studio logos. YouTube refuses to play in a
// file:// page, so the player's page comes from the sync server (GET /trailer), framed here; it
// tells this page what it does. It fades in once it plays, fades out at the end of the stretch and
// then calls onEnd; until then, and when it cannot play or there is no server, the backdrop shows.
// Only while it is in sight (its screen on top, its tab chosen).
import { useEffect, useRef, useState } from 'preact/hooks';
import { DEFAULT_SERVER } from '../config';
import { settings } from '../data/settings';
import { log } from '../log';
import { syncService } from '../sync/service';
import { useInSight } from './sight';

const DELAY = 2500; // the backdrop first, then it comes to life
// After it starts playing: YouTube hides what it puts over the start (title, pause, its logo)
// about 3 s in (measured in Edge, 2026-11-13)
const REVEAL = 4000;
const LENGTH = 27000; // the stretch the server's page plays (server/internal/syncserver/trailer.go)
const FADE = 800;

/** Where trailers can play from: the sync server in use, else the one the build was given. */
export function trailerServer(): string {
  return (syncService.server || DEFAULT_SERVER || '').replace(/\/+$/, '');
}

export function TrailerBackdrop({ load, onPlaying, onEnd }: { load: () => Promise<string | null>; onPlaying: (on: boolean) => void; onEnd: () => void }) {
  const inSight = useInSight();
  const [url, setUrl] = useState<string | null>(null);
  const [shown, setShown] = useState(false);
  const frame = useRef<HTMLIFrameElement>(null);
  // The latest of them: when the delay ends the page may know more of its title (a series' full
  // record, with the provider's trailer) than when it began
  const props = useRef({ load, onPlaying, onEnd });
  props.current = { load, onPlaying, onEnd };
  // Ended or failed: it does not start again, not even once its screen is back in sight
  const over = useRef(false);
  const fading = useRef(0);
  useEffect(() => () => clearTimeout(fading.current), []);

  /** Fades out, then lets the carousel move on. */
  const end = () => {
    if (over.current) return;
    over.current = true;
    setShown(false);
    fading.current = window.setTimeout(() => {
      setUrl(null); // the player goes, and what it costs with it
      props.current.onPlaying(false);
      props.current.onEnd();
    }, FADE);
  };

  // Its address, after the backdrop had its moment
  useEffect(() => {
    const server = trailerServer();
    // Turned off in Settings: the backdrop stays, as where there is no server
    if (!server || settings.trailers === 'never') {
      props.current.onPlaying(false);
      return;
    }
    if (!inSight || over.current) return;
    let live = true;
    const timer = window.setTimeout(() => {
      props.current.load().then(
        (id) => {
          if (!live) return;
          if (!id) return props.current.onPlaying(false);
          setUrl(`${server}/trailer?v=${encodeURIComponent(id)}`);
        },
        () => live && props.current.onPlaying(false),
      );
    }, DELAY);
    return () => {
      live = false;
      clearTimeout(timer);
      if (over.current) return; // fading out: it goes by itself
      setUrl(null);
      setShown(false);
    };
  }, [inSight]);

  // What the player's page reports: 1 playing, 0 ended, "error ..." when it cannot
  useEffect(() => {
    if (!url) return;
    let reveal = 0;
    // In case the player never says it is done: stalled, buffering forever, or gone quiet
    const watchdog = window.setTimeout(end, LENGTH + 15000);
    const listen = (e: MessageEvent) => {
      if (over.current || !frame.current || e.source !== frame.current.contentWindow) return;
      const state = String((e.data && e.data.trailer) || '');
      if (state === '1') {
        // The carousel knows at once, so it waits for it; the video shows a moment later, once
        // YouTube has hidden what it puts over the start (title, pause)
        if (!reveal) reveal = window.setTimeout(() => !over.current && setShown(true), REVEAL);
        props.current.onPlaying(true);
      } else if (state === '0') {
        end();
      } else if (state.indexOf('error') === 0) {
        log(`trailer: ${state}`);
        over.current = true;
        setShown(false);
        setUrl(null);
        props.current.onPlaying(false);
      }
    };
    window.addEventListener('message', listen);
    return () => {
      window.removeEventListener('message', listen);
      clearTimeout(reveal);
      clearTimeout(watchdog);
    };
  }, [url]);

  if (!url || !inSight) return null;
  return (
    <iframe
      ref={frame}
      src={url}
      allow="autoplay"
      tabIndex={-1}
      style={{
        position: 'absolute',
        left: 0,
        top: 0,
        width: '100%',
        height: '100%',
        border: 0,
        pointerEvents: 'none',
        opacity: shown ? 1 : 0,
        transition: `opacity ${FADE}ms ease`,
      }}
    />
  );
}
