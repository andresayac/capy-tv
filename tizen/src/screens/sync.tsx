// The sync account (app/lib/ui/sync_screen.dart, in its wide layout): sign in or create one, then
// see how it is going and which devices share it.
import { useEffect, useRef, useState } from 'preact/hooks';
import { language, StringKey, t } from '../i18n';
import { log } from '../log';
import { Device, SyncClient, SyncException, SyncProblem } from '../sync/client';
import { RecoveryKey } from '../sync/crypto';
import { syncService } from '../sync/service';
import { PosterBackdrop } from '../ui/backdrop';
import { AppBar, CapyStatus, Icon, IconButton, Panel, PrimaryButton, SecondaryButton, Spinner, TextField, useNotifier } from '../ui/components';
import { activeLayer, settle } from '../ui/focus';
import { push, showDialog, toast, useBack } from '../ui/router';
import { DEFAULT_SERVER } from '../config';

type Mode = 'signIn' | 'create' | 'recover';

/** Opens the Sync screen; resolves once it is closed. */
export function openSync(): Promise<void> {
  return push(() => <SyncScreen />).then(() => undefined);
}

/** The icon of the sync button: how it is going at a glance. */
export function syncIcon(): string {
  switch (syncService.status) {
    case 'off': return 'cloud_outlined';
    case 'offline': return 'cloud_off_outlined';
    case 'expired': return 'lock_clock_outlined';
    default: return 'cloud_done_outlined';
  }
}

/** Why a call to the sync server failed, for the user. */
export function problemText(p: SyncProblem): string {
  const keys: Record<SyncProblem, StringKey> = {
    credentials: 'syncErrorCredentials',
    exists: 'syncErrorExists',
    rateLimited: 'syncErrorRateLimited',
    network: 'syncErrorNetwork',
    signedOut: 'syncStatusExpired',
    invite: 'syncErrorInvite',
    full: 'syncErrorFull',
    quota: 'syncErrorQuota',
    server: 'syncErrorFailed',
    stale: 'syncErrorFailed',
    notFound: 'syncErrorFailed',
  };
  return t(keys[p]);
}

/** What went wrong, for the user: the server's reason, or a failure of our own (logged). */
function failureText(e: unknown): string {
  if (e instanceof SyncException) return problemText(e.problem);
  log(`sync: ${e instanceof Error ? e.stack || e.message : e}`);
  return t('syncErrorFailed');
}

const couldNotReach = (e: unknown) => e instanceof SyncException && e.problem === 'network';

const pad = (n: number) => (n < 10 ? '0' : '') + n;

/** Hours and minutes today; with the day otherwise (Flutter's DateFormat.Hm and MMMd). */
function time(d: Date): string {
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (d.toDateString() === new Date().toDateString()) return hm;
  return `${d.toLocaleDateString(language, { month: 'short', day: 'numeric' })} ${hm}`;
}

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

function SyncScreen() {
  useNotifier(syncService);
  const root = useRef<HTMLDivElement>(null);
  const alive = useRef(true);
  const [mode, setMode] = useState<Mode>('signIn');
  const [server, setServer] = useState(syncService.server || DEFAULT_SERVER);
  const [email, setEmail] = useState(syncService.email || '');
  const [password, setPassword] = useState('');
  const [again, setAgain] = useState('');
  const [invite, setInvite] = useState('');
  const [recoveryKey, setRecoveryKey] = useState('');
  const [checked, setChecked] = useState(false); // tried to submit: the fields show what is wrong
  const [busy, setBusy] = useState(false);
  // Not left while an account is made or signed in to (Back, or the arrow the focus falls on)
  useBack(() => busy);
  const [error, setError] = useState<string | null>(null);
  const [unreachable, setUnreachable] = useState(false); // what failed last could not reach the server
  const [devices, setDevices] = useState<Device[]>([]);

  const status = syncService.status;
  const signedIn = status !== 'off' && status !== 'expired';
  // Capy when something needs doing: signing in, or a server out of reach
  const mood = unreachable || status === 'offline' ? 'offline' : signedIn ? null : 'account';
  const create = mode === 'create';
  const recover = mode === 'recover';
  const newPassword = create || recover;

  const loadDevices = () =>
    syncService.devices().then(
      (d) => alive.current && setDevices(d),
      () => {}, // the status says why
    );

  useEffect(() => {
    if (signedIn) loadDevices();
    return () => {
      alive.current = false;
    };
  }, []);

  // What had the focus may be gone (the form after signing in, buttons while busy): back in
  useEffect(() => {
    const screen = root.current && (root.current.closest('.screen') as HTMLElement | null);
    if (screen && screen === activeLayer()) settle(screen);
  }, [signedIn, mode, busy]);

  const invalid: Record<string, string | null> = {
    server: SyncClient.parseServer(server) === null ? t('syncErrorServer') : null,
    email: EMAIL.test(email.trim()) ? null : t('syncErrorEmail'),
    recoveryKey: recover && RecoveryKey.parse(recoveryKey) === null ? t('syncErrorRecoveryKey') : null,
    password: password.length < (newPassword ? 8 : 1) ? t('syncErrorShort') : null,
    again: newPassword && again !== password ? t('syncErrorMismatch') : null,
  };
  const shown = (field: string) => (checked ? invalid[field] : null);

  // A field's Done while it works would make the account twice. A ref, as busy is still the old
  // value until the screen is drawn again
  const working = useRef(false);
  const submit = async () => {
    if (busy || working.current) return;
    setChecked(true);
    if (Object.keys(invalid).some((k) => invalid[k])) return;
    working.current = true;
    setBusy(true);
    setError(null);
    setUnreachable(false);
    const url = SyncClient.parseServer(server)!;
    let made: RecoveryKey | null = null;
    try {
      if (mode === 'signIn') await syncService.signIn(url, email, password);
      else if (mode === 'create') made = await syncService.createAccount(url, email, password, invite);
      else await syncService.recover(url, email, RecoveryKey.parse(recoveryKey)!, password);
      setPassword('');
      setAgain('');
      setRecoveryKey('');
      setChecked(false);
      setMode('signIn');
      loadDevices();
    } catch (e) {
      const wrongKey = mode === 'recover' && e instanceof SyncException && e.problem === 'credentials';
      if (alive.current) {
        setError(wrongKey ? t('syncErrorRecovery') : failureText(e));
        setUnreachable(couldNotReach(e));
      }
    } finally {
      working.current = false;
      if (alive.current) setBusy(false);
    }
    // Even with the screen gone: it is the only time the key can be shown
    if (made) await showRecoveryKey(made);
  };

  const act = async (action: () => Promise<void>, done?: string) => {
    setBusy(true);
    setError(null);
    setUnreachable(false);
    try {
      await action();
      if (done) toast(done);
    } catch (e) {
      if (alive.current) {
        setError(failureText(e));
        setUnreachable(couldNotReach(e));
      }
    } finally {
      if (alive.current) setBusy(false);
    }
  };

  const switchTo = (m: Mode) => {
    setMode(m);
    setChecked(false);
    setError(null);
    setUnreachable(false);
  };

  const signOutDevice = async (d: Device) => {
    const sure = await confirm(t('syncSignOutDeviceConfirm', { name: d.name }), t('syncSignOutDevice'));
    if (!sure) return;
    await act(async () => {
      await syncService.signOutDevice(d.id);
      await loadDevices();
    });
  };

  const changePassword = async () => {
    const changed = await showDialog<boolean>((done) => (
      <PasswordsDialog
        title={t('syncChangePassword')}
        body={t('syncChangePasswordBody')}
        labels={[t('syncCurrentPassword'), t('syncNewPassword'), t('syncPasswordAgain')]}
        action={t('syncChangePassword')}
        run={async (p) => {
          await syncService.changePassword(p[0], p[1]);
          return true;
        }}
        done={done}
      />
    ));
    if (!changed) return;
    toast(t('syncPasswordChanged'));
    loadDevices(); // the others are signed out
  };

  const newRecoveryKey = async () => {
    const key = await showDialog<RecoveryKey>((done) => (
      <PasswordsDialog
        title={t('syncNewRecoveryKey')}
        body={t('syncNewRecoveryKeyBody')}
        labels={[t('syncPassword')]}
        action={t('syncNewRecoveryKey')}
        run={(p) => syncService.newRecoveryKey(p[0])}
        done={done}
      />
    ));
    if (key) await showRecoveryKey(key);
  };

  const deleteAccount = async () => {
    const deleted = await showDialog<boolean>((done) => (
      <PasswordsDialog
        title={t('syncDeleteAccount')}
        body={t('syncDeleteConfirm')}
        labels={[t('syncPassword')]}
        action={t('syncDeleteAccount')}
        run={async (p) => {
          await syncService.deleteAccount(p[0]);
          return true;
        }}
        done={done}
      />
    ));
    if (deleted) toast(t('syncSignedOut'));
  };

  const errorLine = error && <p style={{ color: 'var(--error)', margin: '1.6rem 0 0' }}>{error}</p>;

  const form = (
    <div>
      {status === 'expired' && !recover && (
        <div style={{ marginBottom: '1.6rem' }}>
          <StatusLine />
        </div>
      )}
      {recover && <p class="muted" style={{ lineHeight: 1.4, margin: '0 0 1.6rem' }}>{t('syncRecoverBody')}</p>}
      {/* The TV's keyboard with "/" and ".com", and "@" for the email, as Flutter's keyboardType */}
      <TextField label={t('syncServer')} hint="https://sync.example.com" value={server} onChange={setServer} inputType="url" next error={shown('server')} />
      <div style={{ height: '1.2rem' }} />
      <TextField label={t('syncEmail')} value={email} onChange={setEmail} inputType="email" next error={shown('email')} />
      {recover && (
        <div style={{ marginTop: '1.2rem' }}>
          <TextField label={t('syncRecoveryKey')} hint="XXXX-XXXX-XXXX-XXXX-…" value={recoveryKey} onChange={setRecoveryKey} next error={shown('recoveryKey')} />
        </div>
      )}
      <div style={{ height: '1.2rem' }} />
      <TextField
        label={recover ? t('syncNewPassword') : t('syncPassword')}
        value={password}
        onChange={setPassword}
        password
        next={newPassword}
        onSubmit={newPassword ? undefined : submit}
        error={shown('password')}
      />
      {newPassword && (
        <div style={{ marginTop: '1.2rem' }}>
          <TextField label={t('syncPasswordAgain')} value={again} onChange={setAgain} password next={create} onSubmit={submit} error={shown('again')} />
        </div>
      )}
      {create && (
        <div style={{ marginTop: '1.2rem' }}>
          <TextField label={t('syncInvite')} value={invite} onChange={setInvite} onSubmit={submit} help={t('syncInviteHint')} />
          <p class="muted" style={{ fontSize: 'calc(1.3rem * var(--text-scale))', lineHeight: 1.4, margin: '1.2rem 0 0' }}>{t('syncPasswordNote')}</p>
        </div>
      )}
      {errorLine}
      <div style={{ marginTop: '2.4rem' }}>
        {busy ? (
          <Working />
        ) : (
          <div class="wrap" style={{ alignItems: 'center' }}>
            {/* With a remote, start on the button: the fields are one press up */}
            <PrimaryButton
              autofocus
              icon={mode === 'signIn' ? 'login_rounded' : create ? 'person_add_alt_rounded' : 'lock_reset_rounded'}
              label={mode === 'signIn' ? t('syncSignIn') : create ? t('syncCreate') : t('syncRecover')}
              onPressed={submit}
            />
            {mode === 'signIn' ? (
              [
                <SecondaryButton key="create" label={t('syncToCreate')} onPressed={() => switchTo('create')} />,
                <SecondaryButton key="forgot" label={t('syncForgot')} onPressed={() => switchTo('recover')} />,
              ]
            ) : (
              <SecondaryButton label={create ? t('syncToSignIn') : t('syncBackToSignIn')} onPressed={() => switchTo('signIn')} />
            )}
          </div>
        )}
      </div>
    </div>
  );

  let host = '';
  try {
    host = syncService.server ? new URL(syncService.server).hostname : '';
  } catch {
    // Not an address: nothing to show
  }
  const idle = !busy; // the buttons wait while something runs
  const account = (
    <div>
      <Panel style={{ padding: '2rem' }}>
        <div class="title-medium">{syncService.email || ''}</div>
        <div class="muted ellipsis" style={{ fontSize: 'calc(1.3rem * var(--text-scale))' }}>{host}</div>
        <div style={{ height: '1.4rem' }} />
        <StatusLine />
        {status === 'offline' && syncService.problem && (
          <div class="muted" style={{ fontSize: 'calc(1.3rem * var(--text-scale))', marginTop: '0.6rem' }}>{problemText(syncService.problem)}</div>
        )}
      </Panel>
      {errorLine}
      <div class="wrap" style={{ marginTop: '2rem' }}>
        <PrimaryButton
          autofocus
          icon="sync_rounded"
          label={t('syncNow')}
          onPressed={idle ? () => act(async () => {
            await syncService.syncNow();
            await loadDevices();
          }) : null}
        />
        <SecondaryButton icon="logout_rounded" label={t('syncSignOut')} onPressed={idle ? () => act(() => syncService.signOut(), t('syncSignedOut')) : null} />
        <SecondaryButton icon="password_rounded" label={t('syncChangePassword')} onPressed={idle ? changePassword : null} />
        <SecondaryButton icon="key_rounded" label={t('syncNewRecoveryKey')} onPressed={idle ? newRecoveryKey : null} />
        <SecondaryButton icon="delete_outlined" label={t('syncDeleteAccount')} onPressed={idle ? deleteAccount : null} />
      </div>
      <h2 class="title-large" style={{ marginTop: '2.8rem' }}>{t('syncDevices')}</h2>
      <div style={{ marginTop: '0.8rem' }} data-fgroup>
        {devices.map((d) => (
          <div key={d.id} class="row" style={{ minHeight: '4.8rem', padding: '0.2rem 0' }}>
            <span class="muted">
              <Icon icon="devices_rounded" size={20} />
            </span>
            <span class="grow ellipsis" style={{ marginLeft: '1.2rem' }}>{d.name}</span>
            <span class="muted" style={{ marginLeft: '1.2rem' }}>{d.current ? t('syncThisDevice') : t('syncSeen', { time: time(d.seen) })}</span>
            {/* A lost phone, a TV given away: it gets nothing new */}
            {d.current ? <div style={{ width: '4.8rem' }} /> : <IconButton icon="logout_rounded" onPressed={() => !busy && signOutDevice(d)} />}
          </div>
        ))}
      </div>
    </div>
  );

  return (
    <PosterBackdrop>
      <div ref={root} style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
        <AppBar title={t('sync')} />
        <div class="row" style={{ flex: 1, minHeight: 0, padding: '0 4.8rem' }}>
          <div style={{ flex: 5, maxHeight: '100%', overflowY: 'auto' }}>
            {mood ? (
              <div class="row">
                <CapyStatus mood={mood} size={48} />
              </div>
            ) : (
              <Icon icon="cloud_sync_outlined" size={48} />
            )}
            <h1 class="headline-medium" style={{ marginTop: '2rem' }}>{t('syncTitle')}</h1>
            <p class="body-large muted" style={{ marginTop: '1.2rem' }}>{t('syncBody')}</p>
          </div>
          <div style={{ width: '5.6rem' }} />
          <div style={{ flex: 6, maxHeight: '100%', overflowY: 'auto', padding: '2.4rem 0.8rem', boxSizing: 'border-box' }}>
            {signedIn ? account : form}
          </div>
        </div>
      </div>
    </PosterBackdrop>
  );
}

/** How the sync is going, in a line with its icon. */
function StatusLine() {
  useNotifier(syncService);
  const last = syncService.lastSync;
  const [icon, label] = (() => {
    switch (syncService.status) {
      case 'synced': return ['cloud_done_outlined', t('syncStatusSynced', { time: last ? time(last) : '' })];
      case 'syncing': return ['sync_rounded', t('syncStatusSyncing')];
      case 'offline': return ['cloud_off_outlined', t('syncStatusOffline')];
      case 'expired': return ['lock_clock_outlined', t('syncStatusExpired')];
      default: return ['cloud_outlined', t('syncStatusOff')];
    }
  })();
  return (
    <div class="row">
      <Icon icon={icon} size={20} />
      <span class="grow" style={{ marginLeft: '1rem', fontWeight: 600 }}>{label}</span>
    </div>
  );
}

/** The spinner while keys are derived or the server answers, with how far the derivation is. */
function Working() {
  useNotifier(syncService);
  const d = syncService.deriving;
  return (
    <div class="row">
      <Spinner size={18} />
      <span style={{ marginLeft: '1.2rem' }}>{t('syncWorking')}</span>
      {d !== null && <span class="muted" style={{ marginLeft: '0.8rem' }}>{Math.round(d * 100)} %</span>}
    </div>
  );
}

/** Asks [question]; true when the user chose [action]. */
async function confirm(question: string, action: string): Promise<boolean> {
  const sure = await showDialog<boolean>((done) => (
    <div class="dialog">
      <p class="body-large" style={{ marginTop: 0 }}>{question}</p>
      <div class="actions">
        <SecondaryButton label={t('cancel')} onPressed={() => done(false)} autofocus />
        <PrimaryButton label={action} onPressed={() => done(true)} />
      </div>
    </div>
  ));
  return !!sure;
}

interface PasswordsDialogProps<T> {
  title: string;
  body: string;
  /** With more than one, the last two are a new password and its repetition. */
  labels: string[];
  action: string;
  run: (passwords: string[]) => Promise<T>;
  done: (result?: T) => void;
}

/** Asks for passwords and runs [run] with them, staying open with the reason while it fails. */
export function PasswordsDialog<T>({ title, body, labels, action, run, done }: PasswordsDialogProps<T>) {
  const [values, setValues] = useState<string[]>(labels.map(() => ''));
  const [checked, setChecked] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const n = labels.length;
  const changing = n > 1;
  useBack(() => busy); // not while it runs

  const invalid = values.map((v, i) => {
    if (changing && i === n - 1) return v !== values[n - 2] ? t('syncErrorMismatch') : null;
    if (changing && i === n - 2) return v.length < 8 ? t('syncErrorShort') : null;
    return v ? null : t('syncErrorShort');
  });

  const submit = async () => {
    if (busy) return;
    setChecked(true);
    if (invalid.some((x) => x)) return;
    setBusy(true);
    setError(null);
    try {
      done(await run(values));
    } catch (e) {
      setError(e instanceof SyncException && e.problem === 'credentials' ? t('syncErrorPassword') : failureText(e));
      setBusy(false);
    }
  };

  return (
    <div class="dialog" style={{ width: '56rem', boxSizing: 'border-box' }}>
      <h2 class="title-large">{title}</h2>
      <p class="muted" style={{ lineHeight: 1.4, margin: '1.2rem 0 0' }}>{body}</p>
      {labels.map((label, i) => (
        // The fields darker than the dialog, which has their usual color (Flutter's fillColor surface)
        <div key={i} style={{ marginTop: i === 0 ? '2rem' : '1.2rem', '--surface-high': 'var(--surface)' }}>
          <TextField
            label={label}
            value={values[i]}
            onChange={(v) => setValues((all) => all.map((x, j) => (j === i ? v : x)))}
            password
            autofocus={i === 0}
            next={i < n - 1}
            onSubmit={i === n - 1 ? submit : undefined}
            error={checked ? invalid[i] : null}
          />
        </div>
      ))}
      {error && <p style={{ color: 'var(--error)', margin: '1.2rem 0 0' }}>{error}</p>}
      {busy ? (
        <div style={{ marginTop: '2.4rem' }}>
          <Working />
        </div>
      ) : (
        <div class="actions">
          <SecondaryButton label={t('cancel')} onPressed={() => done()} />
          <PrimaryButton label={action} onPressed={submit} />
        </div>
      )}
    </div>
  );
}

/** Shows an account's recovery key for the user to write down. It is the only time it is shown. */
export async function showRecoveryKey(key: RecoveryKey): Promise<void> {
  await showDialog<void>((done) => <RecoveryKeyDialog text={key.text} done={done} />);
}

function RecoveryKeyDialog({ text, done }: { text: string; done: () => void }) {
  useBack(() => true); // only the button closes it
  // And only after a few seconds: the focus is on it from the start, and an OK too many would close it
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const timer = window.setTimeout(() => setReady(true), 3000);
    return () => clearTimeout(timer);
  }, []);
  return (
    <div class="dialog" style={{ width: '60rem', boxSizing: 'border-box' }}>
      <h2 class="title-large">{t('syncRecoveryTitle')}</h2>
      <p class="muted" style={{ lineHeight: 1.5, margin: '1.2rem 0 0' }}>{t('syncRecoveryBody')}</p>
      {/* Two lines of four groups, to copy one at a time */}
      <Panel style={{ marginTop: '2rem', padding: '1.8rem 1.6rem', textAlign: 'center', fontSize: 'calc(2.2rem * var(--text-scale))', fontWeight: 600, letterSpacing: '0.2rem', lineHeight: 1.6, fontVariantNumeric: 'tabular-nums' }}>
        <div>{text.slice(0, 19)}</div>
        <div>{text.slice(20)}</div>
      </Panel>
      <div class="actions">
        <PrimaryButton label={t('syncRecoverySaved')} onPressed={ready ? () => done() : null} autofocus />
      </div>
    </div>
  );
}
