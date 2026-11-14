// The playlist's account and the app's settings (app/lib/ui/account_screen.dart). Flutter's
// dropdowns become rows that open their options, the current one focused.
import { useEffect, useLayoutEffect, useState } from 'preact/hooks';
import { moveHistory } from '../data/move_history';
import { displayAddress, Playlist, playlistStore } from '../data/playlists';
import { profileStore } from '../data/profiles';
import { preferenceLanguages, settings } from '../data/settings';
import { accountStatusText, errorText } from '../data/source';
import { API_KEY } from '../data/trending';
import { noted } from '../log';
import { syncService } from '../sync/service';
import { chooseLanguage, chosenLanguage, languages, languageSelf, t } from '../i18n';
import { session } from '../session';
import { PosterBackdrop } from '../ui/backdrop';
import { AppBar, AppLogo, Focusable, Icon, Panel, PrimaryButton, SecondaryButton, Spinner, useNotifier } from '../ui/components';
import { ListProgressNote } from '../ui/list_loading';
import { keepingFocus } from '../ui/refocus';
import { popToRoot, push, showDialog, toast, useBack } from '../ui/router';
import { AiSettingsPanel } from './ai';
import { ConnectScreen } from './connect';
import { formatDate } from './details';
import { adultActionsHidden, adultOnly, changeProfile, openProfileSettings, profilePinSettings } from './profiles';
import { updatePlaylist } from './home';
import { openSync } from './sync';

declare const __BUILD__: string;
const BUILD = typeof __BUILD__ === 'string' ? __BUILD__ : '?';

/**
 * What the TV noted lately, newest first, for whoever helps when something fails: there is
 * nothing to paste on a TV, so it is shown to be read out or photographed.
 */
function showDiagnostics(): void {
  const lines = [`Capy TV ${BUILD}`, navigator.userAgent, `sync: ${syncService.status}`, new Date().toISOString(), ''].concat(noted().reverse());
  showDialog<void>((done) => (
    <div class="dialog" style={{ width: '120rem', maxHeight: '86vh', display: 'flex', flexDirection: 'column' }}>
      <h2 class="title-large">{t('diagnostics')}</h2>
      <pre class="vscroll f" tabIndex={-1} style={{ flex: '1 1 auto', overflowY: 'auto', margin: '1.2rem 0', fontSize: 'calc(1.2rem * var(--text))', whiteSpace: 'pre-wrap' }}>
        {lines.join('\n')}
      </pre>
      <div class="wrap">
        <PrimaryButton label={t('close')} autofocus onPressed={() => done()} />
      </div>
    </div>
  ));
}

/** A setting with a few values: its label and the value now; OK lists the others. */
function Choice<T>({ label, value, options, text, onChange, autofocus }: { label: string; value: T; options: T[]; text: (v: T) => string; onChange: (v: T) => void; autofocus?: boolean }) {
  const pick = async () => {
    const chosen = await keepingFocus(() => showDialog<{ v: T }>((done) => (
      <div class="dialog" style={{ minWidth: '44rem' }}>
        <h2 class="title-large" style={{ marginBottom: '1.2rem' }}>{label}</h2>
        {options.map((o, i) => (
          <div key={i} style={{ padding: '0.2rem 0' }}>
            <Focusable radius={12} scale={1.02} onTap={() => done({ v: o })} autofocus={o === value}>
              <div class="row" style={{ padding: '1.1rem 1.4rem', background: o === value ? 'rgba(255,255,255,0.08)' : 'transparent' }}>
                <span style={{ width: '2.4rem', color: o === value ? 'var(--text)' : 'transparent' }}>
                  <Icon icon="check_rounded" size={20} />
                </span>
                <span style={{ marginLeft: '0.8rem', fontWeight: o === value ? 700 : 500 }}>{text(o)}</span>
              </div>
            </Focusable>
          </div>
        ))}
      </div>
    )));
    if (chosen) onChange(chosen.v);
  };
  return (
    <div style={{ padding: '0.4rem 0' }}>
      <Focusable radius={10} scale={1.01} onTap={pick} autofocus={autofocus}>
        <div class="row" style={{ padding: '1rem 0.8rem' }}>
          <span class="grow">{label}</span>
          <span style={{ fontWeight: 600 }}>{text(value)}</span>
          <span class="muted" style={{ marginLeft: '0.6rem' }}>
            <Icon icon="expand_more_rounded" size={24} />
          </span>
        </div>
      </Focusable>
    </div>
  );
}

/** A task under way that cannot be stopped halfway: Back does nothing, and it closes once [task] is done. */
function Working({ text, task, done }: { text: string; task: Promise<unknown>; done: () => void }) {
  useBack(() => true);
  // Nothing here takes the focus, and nothing under the window may keep it: OK would press it
  useLayoutEffect(() => {
    const el = document.activeElement as HTMLElement | null;
    if (el && el.blur) el.blur();
  }, []);
  useEffect(() => {
    task.then(() => done());
  }, []);
  return (
    <div class="dialog row" style={{ minWidth: '44rem' }}>
      <Spinner size={22} />
      <div class="grow" style={{ marginLeft: '1.6rem' }}>
        <div>{text}</div>
        {/* Updating the list: how much of it has come */}
        <ListProgressNote />
      </div>
    </div>
  );
}

/**
 * After a change of provider: favorites and history of another playlist are looked for in this
 * one, where every id is different (see data/move_history.ts). Ends with what was found.
 */
async function bringHistory(playlist: Playlist): Promise<void> {
  const others = playlistStore.playlists.filter((p) => p.id !== playlist.id);
  const from = await showDialog<Playlist>((done) => (
    <div class="dialog" style={{ minWidth: '44rem' }}>
      <h2 class="title-large" style={{ marginBottom: '1.2rem' }}>{t('moveHistoryChoose')}</h2>
      {/* Flutter's SimpleDialog scrolls: many playlists must not run off a 540 dp screen */}
      <div style={{ maxHeight: '38rem', overflowY: 'auto', margin: '0 -0.8rem', padding: '0 0.8rem' }}>
        {others.map((p, i) => (
          <div key={p.id} style={{ padding: '0.2rem 0' }}>
            <Focusable radius={12} scale={1.02} autofocus={i === 0} onTap={() => done(p)}>
              <div class="ellipsis" style={{ padding: '1.1rem 1.4rem', fontWeight: 600 }}>{p.name}</div>
            </Focusable>
          </div>
        ))}
      </div>
    </div>
  ));
  if (!from) return;
  const { source, catalog } = session();
  const task = catalog
    .load()
    .then((data) => moveHistory(from.id, playlist.id, source, data))
    .then(
      (r) => t('moveHistoryDone', { moved: r.moved, missing: r.missing }),
      (e) => errorText(e),
    );
  await showDialog((done) => <Working text={t('moveHistoryWorking')} task={task} done={done} />);
  toast(await task);
}

export function AccountScreen() {
  useNotifier(settings);
  useNotifier(playlistStore);
  useNotifier(profileStore);
  const { playlist, account: a, library } = session();
  const [, setVersion] = useState(0);
  const langLabel = (code: string) => (code === '' ? t('automatic') : code === 'off' ? t('off') : t('languageName', { code }));
  const row = (k: string, v: string) => (
    <div class="row" style={{ padding: '0.6rem 0' }}>
      <span class="muted grow">{k}</span>
      <span style={{ fontWeight: 600, textAlign: 'right' }}>{v}</span>
    </div>
  );
  const minutes = settings.screensaverMinutes;
  const subtitle =
    playlist.type === 'combined'
      ? playlist.members.map((id) => (playlistStore.playlists.filter((x) => x.id === id)[0] || { name: '' }).name).filter(Boolean).join(' + ')
      : profileStore.current.kids
        ? ''
        : displayAddress(playlist);
  return (
    <PosterBackdrop>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        <AppBar title={t('settings')} />
        <div style={{ flex: 1, overflowY: 'auto' }}>
          <div style={{ width: '60rem', margin: '0 auto', padding: '0.8rem 2rem 4rem' }}>
            <Panel style={{ padding: '2rem' }}>
              <div class="row">
                <AppLogo size={40} />
                <div class="grow" style={{ marginLeft: '1.4rem', minWidth: 0 }}>
                  <div class="title-medium">{playlist.name}</div>
                  <div class="muted ellipsis" style={{ fontSize: 'calc(1.3rem * var(--text))' }}>{subtitle}</div>
                </div>
              </div>
              {a && (
                <div style={{ marginTop: '1.2rem', borderTop: '1px solid var(--stroke)', paddingTop: '0.6rem' }}>
                  {row(t('status'), a.isTrial ? `${accountStatusText(a.status)} · ${t('trialAccount')}` : accountStatusText(a.status))}
                  {row(t('expires'), a.expires ? formatDate(a.expires) : t('neverExpires'))}
                  {a.maxConnections !== undefined && row(t('connections'), t('connectionsValue', { active: a.activeConnections || 0, max: a.maxConnections }))}
                  {a.formats.length > 0 && row(t('outputFormats'), a.formats.join(', '))}
                  {a.serverTimezone && row(t('serverTimezone'), a.serverTimezone)}
                  {/* A notice the panel publishes (maintenance, say): as plain text */}
                  {a.message && row(t('providerMessage'), a.message)}
                </div>
              )}
            </Panel>
            <h2 class="title-large" style={{ marginTop: '2.8rem', marginBottom: '0.8rem' }}>{t('playback')}</h2>
            <Panel style={{ padding: '0.8rem 2rem' }}>
              <div data-fgroup>
                {/* Each in its own words: whoever cannot read this one finds theirs. The app starts again in it */}
                <Choice
                  label={t('appLanguage')}
                  value={chosenLanguage()}
                  options={[''].concat(languages)}
                  text={(code) => (code ? languageSelf(code) : t('appLanguageDevice'))}
                  onChange={(code) => code !== chosenLanguage() && chooseLanguage(code)}
                  autofocus
                />
                <Choice label={t('preferredAudio')} value={settings.audioLanguage} options={[''].concat(preferenceLanguages)} text={langLabel} onChange={(v) => settings.set({ audioLanguage: v })} />
                <Choice label={t('preferredSubtitles')} value={settings.subtitleLanguage} options={['', 'off'].concat(preferenceLanguages)} text={langLabel} onChange={(v) => settings.set({ subtitleLanguage: v })} />
                <Choice
                  label={t('screensaver')}
                  value={minutes}
                  options={[0, 2, 5, 10, 15].concat([0, 2, 5, 10, 15].indexOf(minutes) < 0 ? [minutes] : []).sort((x, y) => x - y)}
                  text={(m) => (m === 0 ? t('off') : t('minutesIdle', { minutes: m }))}
                  onChange={(m) => settings.set({ screensaverMinutes: m })}
                />
                <Choice
                  label={t('textSize')}
                  value={settings.textSize}
                  options={[100, 115, 130]}
                  text={(v) => `${v} %`}
                  onChange={(v) => settings.set({ textSize: v })}
                />
                <Choice
                  label={t('trailers')}
                  value={settings.trailers}
                  options={['always', 'never']}
                  text={(v) => (v === 'never' ? t('trailersNever') : t('trailersAlways'))}
                  onChange={(v) => settings.set({ trailers: v })}
                />
                <Choice
                  label={t('controlsStay')}
                  value={settings.controlsSeconds}
                  options={[0, 8, 15]}
                  text={(n) => (n === 0 ? t('controlsStayMoment') : t('controlsStaySeconds', { n }))}
                  onChange={(n) => settings.set({ controlsSeconds: n })}
                />
                {/* What only matters when something does not play: last, apart from the everyday */}
                {playlist.type === 'xtream' && (
                  <>
                    <div class="muted" role="heading" style={{ fontWeight: 700, margin: '1.6rem 0 0.4rem' }}>{t('advanced')}</div>
                    <Choice label={t('liveFormat')} value={settings.liveFormat} options={['ts', 'm3u8']} text={(v) => (v === 'ts' ? t('liveFormatTs') : t('liveFormatHls'))} onChange={(v) => settings.set({ liveFormat: v })} />
                  </>
                )}
              </div>
            </Panel>
            <div class="wrap" data-fgroup style={{ marginTop: '2.8rem' }}>
              {!adultActionsHidden() && <SecondaryButton icon="phonelink_rounded" label={t('connectPhone')} onPressed={() => adultOnly(() => push(() => <ConnectScreen tab="remote" />))} />}
              {/* Its lists and guide again from the provider, whatever their age */}
              <SecondaryButton icon="refresh_rounded" label={t('refreshList')} onPressed={() => updatePlaylist(playlist)} />
              {!adultActionsHidden() && <SecondaryButton icon="swap_horiz_rounded" label={t('switchPlaylist')} onPressed={() => adultOnly(popToRoot)} />}
              {/* "Who's watching?" right here: the playlist opens again for the profile picked */}
              {profileStore.profiles.length > 1 && <SecondaryButton icon="switch_account_outlined" label={t('switchProfile')} onPressed={() => changeProfile(playlist.id)} />}
              {!adultActionsHidden() && <SecondaryButton icon="manage_accounts_outlined" label={t('profilesTitle')} onPressed={openProfileSettings} />}
              {/* Not a child's: it would lock the parents out */}
              {!profileStore.current.kids && <SecondaryButton icon="pin_outlined" label={t('profilePin')} onPressed={profilePinSettings} />}
              {!adultActionsHidden() && <SecondaryButton icon="cloud_sync_outlined" label={t('sync')} onPressed={() => adultOnly(openSync)} />}
              {playlistStore.playlists.length > 1 && !adultActionsHidden() && (
                <SecondaryButton icon="move_down_rounded" label={t('moveHistory')} onPressed={() => adultOnly(() => keepingFocus(() => bringHistory(playlist)))} />
              )}
              <SecondaryButton
                icon="history_toggle_off_rounded"
                label={t('clearHistory')}
                onPressed={async () => {
                  // An OK too many on a remote must not take it from every device
                  const sure = await showDialog<boolean>((d) => (
                    <div class="dialog">
                      <p class="body-large" style={{ marginTop: 0 }}>{t('clearHistoryQuestion')}</p>
                      <div class="actions">
                        <SecondaryButton label={t('cancel')} onPressed={() => d(false)} autofocus />
                        <PrimaryButton label={t('clearHistory')} onPressed={() => d(true)} />
                      </div>
                    </div>
                  ));
                  if (!sure) return;
                  library.clearHistory();
                  setVersion((v) => v + 1);
                  toast(t('historyCleared'));
                }}
              />
            </div>
            <h2 class="title-large" style={{ marginTop: '2.8rem', marginBottom: '0.8rem' }}>{t('aiTitle')}</h2>
            <AiSettingsPanel />
            <h2 class="title-large" style={{ marginTop: '2.8rem', marginBottom: '0.8rem' }}>{t('about')}</h2>
            <Panel style={{ padding: '2rem' }}>
              <p class="muted" style={{ lineHeight: 1.5, margin: 0 }}>{t('aboutLicense')}</p>
              <p class="muted" style={{ margin: '1.2rem 0' }}>{t('appVersion', { version: BUILD })}</p>
              <SecondaryButton icon="bug_report_outlined" label={t('diagnostics')} onPressed={showDiagnostics} />
              <p class="muted" style={{ fontSize: 'calc(1.3rem * var(--text))', margin: '0.6rem 0 0' }}>{t('diagnosticsHint')}</p>
              {/* CC BY asks for the artists' credit where their drawings show */}
              <p class="muted" style={{ lineHeight: 1.5, margin: '1.2rem 0 0' }}>{t('avatarCredits')}</p>
              {/* TMDB asks for this wherever its data is used: only with a key, there is none otherwise */}
              {API_KEY !== '' && <p class="muted" style={{ lineHeight: 1.5, margin: '1.2rem 0 0' }}>{t('tmdbNotice')}</p>}
            </Panel>
          </div>
        </div>
      </div>
    </PosterBackdrop>
  );
}
