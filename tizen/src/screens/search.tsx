// Search over the whole catalog (app/lib/ui/search_tab.dart), best matches first: movies and
// series, then channels. Before anything is typed, what saves typing with a remote: recent
// searches, the week's top ten and genres.
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { Movie, Series } from '../data/models';
import { isNow } from '../data/epg';
import { profileStore } from '../data/profiles';
import { recentSearches, SearchIndex, SearchQuery, searchGuide } from '../data/search';
import { LiveChannel } from '../data/source';
import { trending } from '../data/trending';
import { remoteSearch } from '../remote/now';
import { t } from '../i18n';
import { session } from '../session';
import { CapyMessage, Focusable, Icon, IconButton, TextField, useNotifier } from '../ui/components';
import { focus } from '../ui/focus';
import { useMaxExtentGrid } from '../ui/grid';
import { ListLoading } from '../ui/list_loading';
import { useRailInset } from '../ui/tab';
import { CatalogItem, ChipBar, movieCatalogItem, openItemGrid, PosterCard, RankedRail, SectionHeader, seriesCatalogItem } from './catalog';
import { openMovie, openSeries } from './details';
import { Failed, NetImage, useAsync } from './home';
import { hm } from './guide';
import { playChannels } from './player';

/** Shown at first in each section; "see all" has the rest, in the same order. */
const SHOWN = 18;
const SHOWN_CHANNELS = 12;

/**
 * Text typed on the phone while Search was not there yet. The shell opens Search for it, and
 * Search mounts too late to hear it (Flutter builds every tab up front, so its Search always
 * listens): it takes the text when it mounts, if it is that fresh.
 */
let unheard: { text: string; at: number } | null = null;
remoteSearch.listen(() => {
  try {
    session(); // with no playlist open, no Search is going to want it
    unheard = { text: remoteSearch.text, at: Date.now() };
  } catch {
    unheard = null;
  }
});

function takeUnheard(): string {
  const u = unheard;
  unheard = null;
  return u && Date.now() - u.at < 5000 ? u.text : '';
}

/** The version of a title to show it by: the best match that has artwork. */
function cover<T extends Movie | Series>(versions: T[]): T {
  for (const x of versions) if ('poster' in x ? (x as Movie).poster : (x as Series).cover) return x;
  return versions[0];
}

export function SearchTab() {
  const { catalog } = session();
  useNotifier(trending);
  const index = useAsync<SearchIndex>(() => catalog.load().then((d) => SearchIndex.of(d)), []);
  const [text, setText] = useState(takeUnheard);
  const [q, setQ] = useState(() => new SearchQuery(text));
  // Each profile its own: a child does not see what the parents looked for
  const profile = () => profileStore.current.id;
  const [recent, setRecent] = useState(() => recentSearches.of(profile()));
  const field = useRef<HTMLDivElement>(null);
  useEffect(
    () =>
      remoteSearch.listen(() => {
        unheard = null; // heard
        fill(remoteSearch.text);
      }),
    [],
  );
  const debounce = useRef(0);

  useEffect(() => () => clearTimeout(debounce.current), []);

  const changed = (v: string) => {
    setText(v);
    clearTimeout(debounce.current);
    debounce.current = window.setTimeout(() => setQ(new SearchQuery(v)), 250);
  };

  const fill = (v: string) => {
    setText(v);
    clearTimeout(debounce.current);
    setQ(new SearchQuery(v));
  };

  /** Flutter's clear button: the start page again, and the remote back on the field. */
  const clear = () => {
    const target = field.current && field.current.querySelector<HTMLElement>('.f');
    if (target) focus(target);
    fill('');
  };

  /** Opening a result is what makes a search worth remembering. */
  const remember = () => {
    recentSearches.add(profile(), text);
    setRecent(recentSearches.of(profile()));
  };

  /** [x] with its versions when the provider lists it more than once. */
  const item = (x: Movie | Series, versions: (Movie | Series)[] = []): CatalogItem => {
    const isMovie = 'extension' in x;
    const base = isMovie ? movieCatalogItem(x as Movie) : seriesCatalogItem(x as Series);
    return {
      ...base,
      note: versions.length > 1 ? t('versionsCount', { count: versions.length }) : undefined,
      open: () => {
        remember();
        if (versions.length < 2) return base.open();
        if (isMovie) openMovie(x as Movie, versions as Movie[]);
        else openSeries(x as Series, versions as Series[]);
      },
    };
  };

  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <div style={{ padding: '2rem 2.4rem 0.8rem' }}>
        <h1 class="headline-medium">{t('search')}</h1>
      </div>
      <div class="row" style={{ padding: '0.4rem 2.4rem 0.8rem' }}>
        <div ref={field} class="grow">
          <TextField label="" icon="search_rounded" hint={t('searchHint')} value={text} onChange={changed} onSubmit={remember} autofocus />
        </div>
        {/* Flutter keeps it inside the field; for the remote it is the next stop to the right */}
        {text && (
          <div style={{ marginLeft: '0.8rem' }}>
            <IconButton icon="close_rounded" onPressed={clear} />
          </div>
        )}
      </div>
      <div style={{ flex: 1, overflowY: 'auto', paddingBottom: '12rem' }}>
        {index.error ? (
          <Failed error={index.error} retry={index.retry} />
        ) : !index.data ? (
          // Until the catalog is loaded and its words worked out
          <div style={{ paddingTop: '6rem' }}>
            <ListLoading />
          </div>
        ) : q.isEmpty ? (
          <Start
            index={index.data}
            recent={recent}
            fill={fill}
            clear={() => {
              recentSearches.clear(profile());
              setRecent([]);
            }}
            item={item}
          />
        ) : (
          <Results index={index.data} q={q} item={item} remember={remember} />
        )}
      </div>
    </div>
  );
}

/** Flutter's SectionHeader with an action in its own words ("See all 40", "Clear"). */
function ActionHeader({ title, action, onAction }: { title: string; action: string; onAction: () => void }) {
  const rail = useRailInset(); // 0 here, as Search keeps clear of the rail; the same as SectionHeader
  return (
    <div class="row" style={{ padding: `2.4rem 1.6rem 1rem ${rail + 2.4}rem` }}>
      <h2 class="title-large ellipsis grow">{title}</h2>
      <Focusable radius={8} scale={1.03} onTap={onAction}>
        <div class="row" style={{ padding: '0.6rem 0.8rem 0.6rem 1.2rem', fontWeight: 600 }}>
          {action}
          <Icon icon="chevron_right_rounded" size={24} />
        </div>
      </Focusable>
    </div>
  );
}

function Start(p: { index: SearchIndex; recent: string[]; fill: (v: string) => void; clear: () => void; item: (x: Movie | Series) => CatalogItem }) {
  const data = p.index.data;
  const genres = data.movieGenres.slice(0, 14);
  // A kids profile never gets the trends rated for adults
  const kids = !!profileStore.current.kids;
  const ranked: [string, CatalogItem[]][] = [
    [t('mostWatchedMovies'), trending.ofKind(data, false, kids).map((x) => p.item(x))],
    [t('mostWatchedSeries'), trending.ofKind(data, true, kids).map((x) => p.item(x))],
  ];
  return (
    <div>
      {p.recent.length > 0 && (
        <div>
          <ActionHeader title={t('recentSearches')} action={t('clearRecent')} onAction={p.clear} />
          <ChipBar labels={p.recent} onTap={p.fill} toHeader />
        </div>
      )}
      {ranked.filter(([, items]) => items.length).map(([title, items]) => (
        <RankedRail key={title} title={title} items={items} />
      ))}
      {genres.length > 0 && (
        <div>
          <SectionHeader title={t('browseGenres')} />
          <ChipBar labels={genres} onTap={(g) => openItemGrid(g, data.moviesIn(g).map((m) => p.item(m)))} />
        </div>
      )}
      {!p.recent.length && !genres.length && <p class="muted" style={{ textAlign: 'center', padding: '4.8rem' }}>{t('typeToSearch')}</p>}
    </div>
  );
}

function Results({ index, q, item, remember }: { index: SearchIndex; q: SearchQuery; item: (x: Movie | Series, v?: (Movie | Series)[]) => CatalogItem; remember: () => void }) {
  const holder = session().guide;
  useNotifier(holder);
  const data = index.data;
  // Once per query: the guide arriving or moving on redraws this, and need not search again
  const found = useMemo(() => index.search(q), [index, q]);
  const [allChannels, setAllChannels] = useState(false);
  useEffect(() => setAllChannels(false), [q]); // a new search starts with a dozen again
  const onAir = searchGuide(holder.guide, data.live, q).slice(0, SHOWN_CHANNELS);
  if (!found.movies.length && !found.series.length && !found.channels.length && !onAir.length) {
    return (
      <div style={{ paddingTop: '6rem' }}>
        <CapyMessage mood="empty" text={t('noResults')} />
      </div>
    );
  }
  const posters = (title: string, all: (Movie | Series)[][]) => {
    const items = all.slice(0, SHOWN).map((g) => item(cover(g), g));
    return (
      <div>
        {all.length > SHOWN ? (
          <ActionHeader
            title={`${title} · ${all.length}`}
            action={t('seeAllCount', { count: all.length })}
            onAction={() => openItemGrid(title, all.map((g) => item(cover(g), g)), t('bestMatch'))}
          />
        ) : (
          <SectionHeader title={`${title} · ${all.length}`} />
        )}
        <ResultGrid items={items} />
      </div>
    );
  };
  // A dozen at first; the others a press away, as movies' "See all"
  const channels = allChannels ? found.channels : found.channels.slice(0, SHOWN_CHANNELS);
  return (
    <div>
      {found.movies.length > 0 && posters(t('movies'), found.movies)}
      {found.series.length > 0 && posters(t('series'), found.series)}
      {onAir.length > 0 && (
        <div>
          <SectionHeader title={t('onTvNow')} />
          <div data-fgroup>
            {onAir.map(({ channel, programme }, i) => (
              <ChannelRow
                key={channel.id}
                channel={channel}
                title={programme.title}
                subtitle={`${isNow(programme) ? t('onNow') : hm(programme.start)} · ${channel.name}`}
                live={isNow(programme)}
                onTap={() => {
                  remember();
                  playChannels(onAir.map((x) => x.channel), i);
                }}
              />
            ))}
          </div>
        </div>
      )}
      {channels.length > 0 && (
        <div>
          {found.channels.length > channels.length ? (
            <ActionHeader
              title={`${t('liveTv')} · ${found.channels.length}`}
              action={t('seeAllCount', { count: found.channels.length })}
              onAction={() => setAllChannels(true)}
            />
          ) : (
            <SectionHeader title={`${t('liveTv')} · ${found.channels.length}`} />
          )}
          <div data-fgroup>
            {channels.map((c, i) => (
              <ChannelRow
                key={c.id}
                channel={c}
                title={c.name}
                subtitle={holder.guide.nowOn(c.epgId) ? holder.guide.nowOn(c.epgId)!.title : undefined}
                onTap={() => {
                  remember();
                  playChannels(found.channels, i); // zapping goes through all those found
                }}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

/** Movies or series found, as many a row as Flutter's grid of tiles up to 160 dp wide fits. */
function ResultGrid({ items }: { items: CatalogItem[] }) {
  const grid = useMaxExtentGrid(160, 14, 18);
  return (
    <div ref={grid.ref} data-fgroup style={{ ...grid.style, padding: '0 2.4rem' }}>
      {items.map((x) => (
        <PosterCard key={x.key} item={x} />
      ))}
    </div>
  );
}

/** A channel in the results: its logo, a title, and what is on or when. */
function ChannelRow({ channel, title, subtitle, live, onTap }: { channel: LiveChannel; title: string; subtitle?: string; live?: boolean; onTap: () => void }) {
  return (
    <div style={{ padding: '0 2.4rem 0.8rem' }}>
      <Focusable scale={1.02} onTap={onTap}>
        <div class="row" style={{ background: 'var(--surface)', padding: '1rem' }}>
          <div style={{ width: '5.6rem', height: '4rem', flex: 'none' }}>
            <NetImage url={channel.icon} icon="tv_rounded" />
          </div>
          <div class="grow" style={{ marginLeft: '1.4rem', minWidth: 0 }}>
            <div class="ellipsis" style={{ fontWeight: 600 }}>{title}</div>
            {subtitle && (
              <div class="row">
                {/* On now: a red dot, the one colour live TV has */}
                {live && <span style={{ width: '0.7rem', height: '0.7rem', borderRadius: '50%', background: 'var(--live)', marginRight: '0.6rem', flex: 'none' }} />}
                <span class="muted ellipsis" style={{ fontSize: 'calc(1.3rem * var(--text-scale))' }}>{subtitle}</span>
              </div>
            )}
          </div>
        </div>
      </Focusable>
    </div>
  );
}
