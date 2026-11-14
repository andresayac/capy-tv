// The code a phone scans to open the companion page (app/lib/ui/connect_screen.dart): add
// playlists with the phone's keyboard, use it as a remote, move backups. [tab] is the part of the
// page it opens on; with [closeOnPlaylist] the screen goes back once a playlist arrives.
import qrcode from 'qrcode-generator';
import { useEffect, useState } from 'preact/hooks';
import { deviceName } from '../platform/tv';
import { companionHost } from '../remote/host';
import { t } from '../i18n';
import { PosterBackdrop } from '../ui/backdrop';
import { AppBar, CapyMessage, CapyStatus, Icon, PrimaryButton, useNotifier } from '../ui/components';
import { trailerServer } from '../ui/trailer';
import { openSync } from './sync';

/** A QR code on white, as phones read it best. */
export function QrCard({ data, size }: { data: string; size: number }) {
  const qr = qrcode(0, 'M');
  qr.addData(data);
  qr.make();
  const n = qr.getModuleCount();
  let path = '';
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (qr.isDark(y, x)) path += `M${x} ${y}h1v1h-1z`;
  return (
    <div style={{ background: '#fff', padding: '1.8rem', borderRadius: 'var(--r-panel)', flex: 'none' }}>
      <svg viewBox={`0 0 ${n} ${n}`} style={{ width: `${size / 10}rem`, height: `${size / 10}rem`, display: 'block' }} shape-rendering="crispEdges">
        <path d={path} fill="#000" />
      </svg>
    </div>
  );
}

/**
 * Why the phone cannot come in yet, and the way on: Retry while the server is down (it also tries
 * again on its own), or Sync for a TV without a server. Unlike Flutter's own server, the bridge
 * can fail, and the remote must not be left on a dead end.
 */
export function BridgeFailure({ autofocus = true }: { autofocus?: boolean }) {
  const failure = companionHost.failure;
  if (!failure) return null;
  return failure === 'noServer' ? (
    <PrimaryButton icon="cloud_sync_outlined" label={t('sync')} autofocus={autofocus} onPressed={() => openSync().then(() => companionHost.retry(trailerServer()))} />
  ) : (
    <PrimaryButton icon="refresh_rounded" label={t('retry')} autofocus={autofocus} onPressed={() => companionHost.retry(trailerServer())} />
  );
}

export function ConnectScreen({ tab = 'add', closeOnPlaylist = false, done }: { tab?: string; closeOnPlaylist?: boolean; done?: () => void }) {
  useNotifier(companionHost);
  const [received, setReceived] = useState<string | null>(null);

  useEffect(() => {
    companionHost.hold(trailerServer());
    const off = companionHost.onEvent((e) => {
      if (e.kind !== 'playlist') return;
      setReceived(e.name);
      if (closeOnPlaylist && done) setTimeout(done, 1600);
    });
    return () => {
      off();
      companionHost.release();
    };
  }, []);

  const link = companionHost.link(tab);
  const failure = companionHost.failure;
  const status = received
    ? { icon: 'check_circle_rounded', text: t('playlistReceived', { name: received }), done: true }
    : companionHost.remotes
      ? { icon: 'phonelink_rounded', text: t('connectRemoteOn'), done: true }
      : { icon: 'hourglass_empty_rounded', text: t('connectWaiting'), done: false };
  return (
    <PosterBackdrop>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        <AppBar title={t('connectPhone')} />
        <div class="row" style={{ flex: 1, justifyContent: 'center', padding: '0 3.2rem 3.2rem' }}>
          {failure ? (
            <div style={{ maxWidth: '64rem' }}>
              {/* The TV's "no network" (Flutter's connectNoNetwork): its way in is the bridge */}
              <CapyMessage
                mood={failure === 'noServer' ? 'account' : 'offline'}
                text={failure === 'noServer' ? t('connectNeedsServer') : t('connectServerDown')}
                textClass="title-medium"
                action={<BridgeFailure />}
              />
            </div>
          ) : !link ? (
            <CapyStatus mood="loading" />
          ) : (
            <div class="row" style={{ maxWidth: '96rem' }}>
              <QrCard data={link} size={300} />
              <div style={{ width: '5.6rem' }} />
              <div class="grow">
                <h1 class="headline-medium">{t('connectPhone')}</h1>
                <p class="body-large muted" style={{ marginTop: '1.2rem' }}>{t('connectPhoneBody')}</p>
                <div class="row muted" style={{ marginTop: '1.6rem' }}>
                  <Icon icon="wifi_rounded" size={18} />
                  <span style={{ marginLeft: '0.8rem' }}>{t('connectAnyNetwork', { device: deviceName() })}</span>
                </div>
                <div
                  class="row"
                  style={{
                    marginTop: '2.4rem',
                    display: 'inline-flex',
                    padding: '1.2rem 1.6rem',
                    borderRadius: 'var(--r-panel)',
                    background: status.done ? 'var(--text)' : 'var(--surface-high)',
                    color: status.done ? 'var(--black)' : 'var(--text)',
                  }}
                >
                  <span style={{ color: status.done ? 'var(--black)' : 'var(--muted)' }}>
                    <Icon icon={status.icon} size={20} />
                  </span>
                  <span style={{ marginLeft: '1rem', fontWeight: 600 }}>{status.text}</span>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </PosterBackdrop>
  );
}
