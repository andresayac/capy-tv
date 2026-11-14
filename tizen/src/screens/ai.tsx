// Settings' section for the language model that picks titles for each profile
// (app/lib/ui/ai_settings.dart, data/recommender.ts): what it does, what it sends, and setting it
// up. Behind the parental PIN, when there is one. Typing an address and a key with the remote is
// slow, so the setup window can show the phone's code: the phone's remote types into the field
// the TV has selected.
import { useEffect, useRef, useState } from 'preact/hooks';
import { AiException, AiService, recommender } from '../data/recommender';
import { t } from '../i18n';
import { companionHost } from '../remote/host';
import { isLocal } from '../sync/client';
import { Panel, PrimaryButton, SecondaryButton, Spinner, TextField, useNotifier } from '../ui/components';
import { activeLayer, focus, focusables, focused } from '../ui/focus';
import { showDialog, toast, useBack } from '../ui/router';
import { trailerServer } from '../ui/trailer';
import { QrCard } from './connect';
import { confirmPin } from './profiles';

/** What is wrong with [url] as a service's address: none, or the key and what was watched would go unencrypted off this network. */
function urlProblem(url: string): string | null {
  if (!SCHEME.test(url)) return t('aiUrl');
  try {
    const u = new URL(url);
    if (!u.hostname) return t('aiUrl');
    if (u.protocol === 'https:') return null;
    return u.protocol === 'http:' && isLocal(u.hostname) ? null : t('aiUrlInsecure');
  } catch {
    return t('aiUrl');
  }
}

/** The same service: scheme, host and port alike, whatever the path. */
function sameService(a: string, b: string): boolean {
  try {
    const x = new URL(a), y = new URL(b);
    return x.protocol === y.protocol && x.host === y.host;
  } catch {
    return false;
  }
}

/** The host of [url], or [url] itself when it has none. */
function hostOf(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return url;
  }
}

export function AiSettingsPanel() {
  useNotifier(recommender);
  const box = useRef<HTMLDivElement>(null);
  const s = recommender.service;

  /**
   * Runs [action] from one of the buttons, then puts the remote back on it: closing a window
   * hands the focus to the screen's first element, and the button may be gone (Turn off).
   */
  const run = (action: () => Promise<void>) => async () => {
    const from = focused();
    await action();
    setTimeout(() => {
      const layer = activeLayer();
      if (!box.current || !layer || !layer.contains(box.current)) return;
      const all = focusables(box.current);
      const target = from && all.indexOf(from) >= 0 ? from : all[0];
      if (target) focus(target);
    }, 0);
  };

  const setUp = run(async () => {
    if (!(await confirmPin())) return;
    if (await showDialog<boolean>((done) => <AiDialog done={done} />)) toast(t('aiSaved'));
  });
  const forgetOwn = run(async () => {
    if (await confirmPin()) recommender.configure(null);
  });
  const turn = (on: boolean) =>
    run(async () => {
      if (await confirmPin()) recommender.turn(on);
    });

  const status = !s
    ? recommender.off
      ? t('aiTurnedOff')
      : t('aiOff')
    : s.viaServer
      ? t('aiFromServer', { server: s.baseUrl })
      : recommender.usingBuiltIn
        ? t('aiBuiltIn')
        : `${s.model} · ${hostOf(s.baseUrl)}`;
  return (
    <div ref={box}>
      <Panel style={{ padding: '2rem' }}>
        <p class="muted" style={{ lineHeight: 1.5, margin: 0 }}>{t('aiBody')}</p>
        <div style={{ fontWeight: 600, marginTop: '1.4rem' }}>{status}</div>
        {/* Unlike everything else, what goes to the server for this is readable there */}
        {s && s.viaServer && <p class="muted" style={{ fontSize: 'calc(1.3rem * var(--text-scale))', lineHeight: 1.4, margin: '0.6rem 0 0' }}>{t('aiServerNote')}</p>}
        <div class="wrap" data-fgroup style={{ marginTop: '1.4rem' }}>
          {recommender.off && recommender.canTurnOn ? (
            <SecondaryButton icon="restart_alt_rounded" label={t('aiUseBuiltIn')} onPressed={turn(true)} />
          ) : (
            <SecondaryButton icon="auto_awesome_outlined" label={!s ? t('aiSetUp') : recommender.usingOwn ? t('aiChange') : t('aiOwn')} onPressed={setUp} />
          )}
          {recommender.usingOwn && <SecondaryButton icon="close_rounded" label={t('aiRemove')} onPressed={forgetOwn} />}
          {s && <SecondaryButton icon="block_rounded" label={t('aiTurnOff')} onPressed={turn(false)} />}
        </div>
      </Panel>
    </div>
  );
}

/** A URI scheme, as Dart's Uri.hasScheme tells it ("https:", "localhost:"). */
const SCHEME = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;

/** Address, model and key of the service; checked with a short question before it is saved. */
function AiDialog({ done }: { done: (saved?: boolean) => void }) {
  // The key that an empty field keeps; never the one built into the app, for another service
  const [kept] = useState(() => (recommender.usingOwn ? recommender.service : null));
  const [url, setUrl] = useState(kept ? kept.baseUrl : AiService.defaultUrl);
  const [model, setModel] = useState(kept ? kept.model : '');
  const [key, setKey] = useState('');
  const [checked, setChecked] = useState(false); // tried to save: the fields show what is wrong
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [phone, setPhone] = useState(false);
  const alive = useRef(true);
  useBack(() => busy); // not while it checks
  useEffect(
    () => () => {
      alive.current = false;
    },
    [],
  );

  const invalid = {
    url: urlProblem(url.trim()),
    model: model.trim() ? null : t('aiModel'),
  };

  const submit = async () => {
    if (busy) return;
    setChecked(true);
    if (invalid.url || invalid.model) return;
    // Empty: the key set up before, so it need not be typed again on a remote
    // Only for the service it was set up for, never sent to another address
    const s = new AiService(url.trim(), model.trim(), key.trim() || (kept && sameService(kept.baseUrl, url.trim()) ? kept.apiKey : ''));
    setBusy(true);
    setError(null);
    try {
      await recommender.test(s);
      recommender.configure(s);
      done(true);
    } catch (e) {
      if (!alive.current) return;
      const problem = e instanceof AiException ? e.problem : 'service';
      const detail = e instanceof AiException ? e.detail : '';
      setError(
        problem === 'key'
          ? !key.trim() && kept
            ? t('aiKeyAgain')
            : t('aiWrongKey')
          : problem === 'model'
            ? t('aiWrongModel')
            : problem === 'busy'
              ? t('aiBusy')
              : /^\d+$/.test(detail)
                ? t('aiServiceError', { code: detail })
                : t('aiUnreachable'),
      );
    } finally {
      if (alive.current) setBusy(false);
    }
  };

  return (
    // With the code, as wide as a dialog goes (theme.css .dialog)
    <div class="dialog" style={{ width: phone ? '80rem' : '56rem', boxSizing: 'border-box' }}>
      <h2 class="title-large">{t('aiTitle')}</h2>
      <div class="row" style={{ alignItems: 'flex-start', marginTop: '2rem' }}>
        {/* The fields darker than the dialog, which has their usual color (Flutter's fillColor surface) */}
        <div class="grow" style={{ minWidth: 0, '--surface-high': 'var(--surface)' }}>
          <TextField label={t('aiUrl')} value={url} onChange={setUrl} inputType="url" next help={t('aiUrlHint')} error={checked ? invalid.url : null} autofocus />
          <div style={{ height: '1.2rem' }} />
          <TextField label={t('aiModel')} value={model} onChange={setModel} next error={checked ? invalid.model : null} />
          <div style={{ height: '1.2rem' }} />
          <TextField label={t('aiKey')} value={key} onChange={setKey} password onSubmit={submit} help={kept ? t('aiKeyKept') : undefined} />
        </div>
        {phone && <PhoneTyping />}
      </div>
      {error && <p style={{ color: 'var(--error)', margin: '1.2rem 0 0' }}>{error}</p>}
      {busy && (
        <div style={{ marginTop: '1.6rem' }}>
          <Spinner size={18} />
        </div>
      )}
      <div class="actions">
        {/* Pressed again, the code goes away; the button stays, and so does the focus */}
        <SecondaryButton icon="phonelink_rounded" label={t('addFromPhone')} onPressed={busy ? null : () => setPhone((p) => !p)} />
        <div class="grow" />
        <SecondaryButton label={t('cancel')} onPressed={busy ? null : () => done()} />
        <PrimaryButton label={t('aiTestAndSave')} onPressed={busy ? null : submit} />
      </div>
    </div>
  );
}

/** The code that opens the phone's remote, held while it shows: what is typed there fills the field selected here. */
function PhoneTyping() {
  useNotifier(companionHost);
  useEffect(() => {
    companionHost.hold(trailerServer());
    return () => companionHost.release();
  }, []);
  const link = companionHost.link('remote');
  const failure = companionHost.failure;
  return (
    <div style={{ width: '26rem', flex: 'none', marginLeft: '3.2rem' }}>
      {failure ? (
        <p class="muted" style={{ lineHeight: 1.4, margin: 0 }}>{failure === 'noServer' ? t('connectNeedsServer') : t('connectServerDown')}</p>
      ) : link ? (
        <QrCard data={link} size={180} />
      ) : (
        <Spinner size={32} />
      )}
      {!failure && (
        <p class="muted" style={{ fontSize: 'calc(1.3rem * var(--text-scale))', lineHeight: 1.4, margin: '1.2rem 0 0' }}>{companionHost.remotes ? t('connectRemoteOn') : t('aiTypeOnPhone')}</p>
      )}
    </div>
  );
}
