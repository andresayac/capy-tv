// What is on a channel now and next (app/lib/ui/detail_screens.dart showChannelGuide), with Watch
// live and My list: the one place a channel becomes a favorite. Flutter opens it with a long
// press, which a remote has not; here holding OK or the Info key on a channel does, and it shows
// as a dialog. The programmes can be gone through with the remote, OK showing one whole.
import { isNow } from '../data/epg';
import { channelRef } from '../data/library';
import { errorText, EpgEntry, LiveChannel } from '../data/source';
import { t } from '../i18n';
import { session } from '../session';
import { Focusable, PrimaryButton, SecondaryButton, Spinner } from '../ui/components';
import { showDialog } from '../ui/router';
import { FavoriteButton } from './details';
import { hm, showProgrammeSheet } from './guide';
import { NetImage, useAsync } from './home';
import { playChannels } from './player';

/**
 * Shows the sheet of [c]. [watch] plays it, by default alone; from a list of channels it should
 * play the list, so the channel keys zap through it.
 */
export function showChannelSheet(c: LiveChannel, watch?: () => void): Promise<void> {
  return showDialog<void>((done) => <ChannelSheet channel={c} watch={watch || (() => playChannels([c], 0))} done={() => done()} />).then(() => {});
}

function ChannelSheet({ channel: c, watch, done }: { channel: LiveChannel; watch: () => void; done: () => void }) {
  const { source, guide: holder } = session();
  // The guide as it is when the sheet opens; without it for this channel, the provider's short EPG
  const epg = useAsync<EpgEntry[]>(() => {
    const guide = holder.guide;
    return guide.has(c.epgId) ? Promise.resolve(guide.upcoming(c.epgId)) : source.shortEpg(c);
  }, []);
  return (
    <div class="dialog" style={{ width: '64rem', maxHeight: '50rem', boxSizing: 'border-box', display: 'flex', flexDirection: 'column' }}>
      <div class="row" style={{ flex: 'none' }}>
        <div style={{ width: '5.6rem', height: '4rem', flex: 'none' }}>
          <NetImage url={c.icon} icon="tv_rounded" />
        </div>
        <h2 class="title-large grow" style={{ marginLeft: '1.2rem' }}>{c.name}</h2>
      </div>
      {c.archiveDays > 0 && <div style={{ marginTop: '0.6rem', flex: 'none' }}>{t('catchupDays', { n: c.archiveDays })}</div>}
      <div class="vscroll" data-fgroup style={{ flex: '0 1 auto', minHeight: 0, overflowY: 'auto', margin: '1.2rem -0.6rem 0', padding: '0 0.6rem' }}>
        {epg.error ? (
          <div class="row" style={{ padding: '1.2rem 0' }}>
            <span class="muted grow" style={{ marginRight: '1.2rem' }}>{errorText(epg.error)}</span>
            <SecondaryButton icon="refresh_rounded" label={t('retry')} onPressed={epg.retry} />
          </div>
        ) : !epg.data ? (
          <div class="row" style={{ justifyContent: 'center', padding: '2.4rem 0' }}>
            <Spinner size={28} />
          </div>
        ) : !epg.data.length ? (
          <div class="muted" style={{ padding: '1.6rem 0' }}>{t('noGuide')}</div>
        ) : (
          // Guides may list two programmes at one time: keyed by place, as the list never reorders
          epg.data.map((e, i) => <ProgrammeRow key={i} channel={c} entry={e} />)
        )}
      </div>
      <div class="wrap" data-fgroup style={{ marginTop: '0.6rem', flex: 'none', paddingTop: '1.2rem' }}>
        <PrimaryButton
          autofocus
          icon="play_arrow_rounded"
          label={t('watchLive')}
          onPressed={() => {
            done();
            watch();
          }}
        />
        <FavoriteButton refOf={channelRef(c)} />
      </div>
    </div>
  );
}

/** NOW or its start time, then the title, the hours and two lines of what it is about. */
function ProgrammeRow({ channel, entry: e }: { channel: LiveChannel; entry: EpgEntry }) {
  return (
    <Focusable radius={10} scale={1} onTap={() => showProgrammeSheet(channel, e)}>
      <div class="row" style={{ alignItems: 'flex-start', padding: '0.8rem 0.6rem' }}>
        <div style={{ width: '7rem', flex: 'none' }}>
          {isNow(e) ? (
            <span style={{ fontWeight: 800, letterSpacing: '0.1rem' }}>{t('nowPlaying').toUpperCase()}</span>
          ) : (
            <span class="muted">{hm(e.start)}</span>
          )}
        </div>
        <div class="grow">
          <div style={{ fontWeight: 600 }}>{e.title}</div>
          <div class="muted" style={{ fontSize: 'calc(1.2rem * var(--text-scale))' }}>{`${hm(e.start)} – ${hm(e.end)}`}</div>
          {e.description && <div class="muted clamp2">{e.description}</div>}
        </div>
      </div>
    </Focusable>
  );
}
