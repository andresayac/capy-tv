// The playlist open now and what goes with it: its source, its catalog (loaded once) and the
// profile's library. Null on the playlists screen (Flutter's currentLibrary and currentCatalog).
import { Airing } from './data/airing';
import { Catalog } from './data/catalog';
import { GuideHolder } from './data/epg';
import { Library } from './data/library';
import { profileStore } from './data/profiles';
import { Playlist } from './data/playlists';
import { AccountInfo, ContentSource } from './data/source';

export interface Session {
  playlist: Playlist;
  source: ContentSource;
  catalog: Catalog;
  library: Library;
  /** The XMLTV guide, loaded in the background once the playlist opens. */
  guide: GuideHolder;
  /** What is on, for the channels the guide has nothing on now for: asked of the provider. */
  airing: Airing;
  account?: AccountInfo;
}

let current: Session | null = null;

export function startSession(playlist: Playlist, source: ContentSource, account?: AccountInfo): Session {
  const s: Session = {
    playlist,
    source,
    account,
    catalog: new Catalog(source),
    library: Library.load(playlist.id, profileStore.current.id),
    guide: new GuideHolder((stop, early) => source.guide(stop, early)),
    airing: new Airing((c) => source.shortEpg(c)),
  };
  current = s;
  s.guide.start();
  prefetch(s);
  document.addEventListener('visibilitychange', renewOnReturn);
  return s;
}

/** Back from standby with the playlist still open: a guide older than a session's is loaded again. */
function renewOnReturn(): void {
  if (document.hidden || !current) return;
  current.guide.renewIfOlder(6 * 60 * 60 * 1000);
}

/**
 * Ends [which] (else whichever is open), unless another one has started since: a playlist opened
 * again for another profile has a session of its own, which the Home closing must not end.
 */
export function endSession(which?: Session): void {
  // Its guide and lists, still downloading and parsing tens of MB, would take the TV from the next one's
  const ended = which || current;
  if (ended) {
    ended.guide.stop();
    if (ended.source.close) ended.source.close();
  }
  if (!which || current === which) {
    current = null;
    document.removeEventListener('visibilitychange', renewOnReturn);
  }
}

/** The open session; screens past the playlists screen always have one. */
/** The id of the playlist open now, if any. */
export const openPlaylistId = (): string | null => (current ? current.playlist.id : null);

export function session(): Session {
  if (!current) throw new Error('no playlist is open');
  return current;
}

/**
 * What every tab starts on, asked for at once, as Flutter builds all of them when the playlist
 * opens (app/lib/ui/home_screen.dart): the catalog, Live TV's categories and the first one's
 * channels, the provider's movie and series categories. Tabs here mount on their first visit;
 * the sources keep these lists for the session, so a tab finds them there instead of a spinner.
 */
function prefetch({ source, catalog }: Session): void {
  const quiet = () => undefined;
  catalog.load().catch(quiet);
  source
    .liveCategories()
    .then((cats) => (cats.length ? source.liveChannels(cats[0].id) : null))
    .catch(quiet);
  source.movieCategories().catch(quiet);
  source.seriesCategories().catch(quiet);
}
