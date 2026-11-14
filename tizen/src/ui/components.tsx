// The Flutter app's shared widgets (app/lib/ui/common.dart), for the remote.
import { Component, ComponentChildren, JSX } from 'preact';
import { useEffect, useRef, useState } from 'preact/hooks';
import { SourceException } from '../data/source';
import icons from '../gen/icons.json';
import { t } from '../i18n';
import { log } from '../log';
import { Keys } from '../platform/tv';
import { activeLayer, focus, focusables, offer, setLongPress } from './focus';
import { back } from './router';

export function Icon({ icon, size }: { icon: string; size?: number }) {
  const d = (icons as Record<string, string>)[icon];
  const style = size ? { width: `${size / 10}rem`, height: `${size / 10}rem` } : undefined;
  return (
    <svg class="icon" viewBox="0 -960 960 960" style={style}>
      <path d={d} />
    </svg>
  );
}

interface FocusableProps {
  onTap?: () => void;
  /** Holding OK, or the Info key (Flutter's onLongPress: the channel sheet). */
  onLongPress?: () => void;
  /** Takes the focus when it appears, unless the user is already somewhere (Flutter's autofocus). */
  autofocus?: boolean;
  /** Where the remote lands whenever it comes into this item's data-fgroup from outside. */
  entry?: boolean;
  /** Corner radius in dp, as in Flutter. */
  radius?: number;
  /** How much it grows when focused. */
  scale?: number;
  class?: string;
  style?: JSX.CSSProperties;
  /** What it does, for an icon alone (Flutter's tooltip). */
  label?: string;
  children: ComponentChildren;
}

/**
 * Any child made focusable with the app's treatment: a small gap, a white ring and a slight lift.
 * OK on the remote taps it; held, it long-presses it.
 */
export function Focusable({ onTap, onLongPress, autofocus, entry, radius, scale, class: cls, style, label, children }: FocusableProps) {
  const ref = useRef<HTMLDivElement>(null);
  const longPress = useRef(onLongPress);
  longPress.current = onLongPress;
  const holds = !!onLongPress;
  useEffect(() => {
    if (ref.current) setLongPress(ref.current, holds ? () => longPress.current && longPress.current() : null);
  }, [holds]);
  // Content that appears after a load (a series' Continue button) still gets the remote, as
  // long as the user has not moved yet; settle() already took the ones there from the start
  useEffect(() => {
    if (autofocus) offer(ref.current);
  }, []);
  const vars: Record<string, string> = {};
  if (radius !== undefined) vars['--r'] = `${radius / 10}rem`;
  if (scale !== undefined) vars['--s'] = String(scale);
  return (
    <div
      ref={ref}
      class={'f' + (cls ? ' ' + cls : '') + (onTap ? '' : ' inert')}
      tabIndex={-1}
      data-autofocus={autofocus ? '' : undefined}
      data-fentry={entry ? '' : undefined}
      aria-label={label}
      data-disabled={onTap ? undefined : ''}
      onClick={onTap}
      style={{ ...vars, ...(style as object) }}
    >
      <div class="fc">{children}</div>
    </div>
  );
}

interface ButtonProps {
  label: string;
  icon?: string;
  onPressed?: (() => void) | null;
  autofocus?: boolean;
}

function ActionButton({ label, icon, onPressed, autofocus, kind }: ButtonProps & { kind: string }) {
  return (
    <Focusable class={`button ${onPressed ? kind : 'disabled'}`} onTap={onPressed || undefined} autofocus={autofocus}>
      {icon && <Icon icon={icon} />}
      {label}
    </Focusable>
  );
}

/** Main action: white with black text. */
export const PrimaryButton = (p: ButtonProps) => <ActionButton {...p} kind="primary" />;

/** Secondary action: dark grey with white text. */
export const SecondaryButton = (p: ButtonProps) => <ActionButton {...p} kind="secondary" />;

export function IconButton({ icon, onPressed, label }: { icon: string; onPressed: () => void; label?: string }) {
  return (
    <Focusable class="icon-button" onTap={onPressed} label={label}>
      <Icon icon={icon} />
    </Focusable>
  );
}

/** Selectable pill (categories, seasons, playlist type): white when selected. */
export function AppChip(p: { label: string; selected: boolean; onTap: () => void; icon?: string; autofocus?: boolean }) {
  return (
    <Focusable class={'chip' + (p.selected ? ' selected' : '')} onTap={p.onTap} autofocus={p.autofocus}>
      {p.icon && <Icon icon={p.icon} />}
      {p.label}
    </Focusable>
  );
}

export function Panel({ children, style }: { children: ComponentChildren; style?: JSX.CSSProperties }) {
  return (
    <div class="panel" style={style}>
      {children}
    </div>
  );
}

export function AppLogo({ size = 40 }: { size?: number }) {
  return (
    <img src="capy-icon.svg" alt="" style={{ width: `${size / 10}rem`, height: `${size / 10}rem` }} />
  );
}

type CapyMood = 'loading' | 'offline' | 'account' | 'error' | 'empty' | 'video';

export function capyMoodForError(error: unknown): CapyMood {
  if (!(error instanceof SourceException)) return 'error';
  switch (error.error) {
    case 'unreachable': case 'timeout': case 'providerBusy': return 'offline';
    case 'unauthorized': case 'inactiveAccount': case 'wrongServer': return 'account';
    case 'notFound': case 'emptyPlaylist': return 'empty';
    default: return 'error';
  }
}

/**
 * How long a mood other than loading plays before it rests on its still drawing: two loops of its
 * animation (24 frames of 100 ms, the first one the still drawing, so no jump at the end). An
 * animated image costs frames for as long as it shows, and an empty list can stay for minutes.
 */
const LIVELY = 2 * 24 * 100;

/**
 * A mood's drawing: the still one, already there when it takes over, under the animated one. The
 * box moves and not the images, so handing over does not play the entrance again.
 */
function CapyArt({ name, forever, size }: { name: string; forever: boolean; size: number }) {
  const [phase, setPhase] = useState<'waiting' | 'playing' | 'resting'>(() =>
    window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'resting' : 'waiting',
  );
  const timer = useRef(0);
  useEffect(() => () => clearTimeout(timer.current), []);
  const loaded = () => {
    setPhase('playing');
    if (!forever) timer.current = window.setTimeout(() => setPhase('resting'), LIVELY);
  };
  const side = `${size / 10}rem`;
  return (
    <div class={'capy-art' + (phase === 'resting' ? '' : ' capy-moving')} style={{ width: side, height: side }}>
      {/* The animation has a transparent background: the still drawing cannot show through it */}
      <img src={`capy-${name}.svg`} alt="" style={{ opacity: phase === 'playing' ? 0 : 1 }} />
      {phase !== 'resting' && <img src={`capy-${name}.webp`} alt="" onLoad={loaded} onError={() => setPhase('resting')} />}
    </div>
  );
}

/**
 * Decorative; the surrounding text describes the error or empty state. Only loading keeps moving;
 * with animations turned off it is the still drawing, and the WebP is not decoded at all.
 */
export function CapyStatus({ mood, size = 76 }: { mood: CapyMood; size?: number }) {
  const loading = mood === 'loading';
  return (
    <div class={'capy-status' + (loading ? ' capy-loading' : '')} aria-hidden="true">
      {/* Another mood comes in and plays anew, as in Flutter's didUpdateWidget */}
      <CapyArt key={mood} name={loading ? 'icon' : mood} forever={loading} size={size} />
      {loading && <div class="capy-dots"><i /><i /><i /></div>}
    </div>
  );
}

interface CapyMessageProps {
  mood: CapyMood;
  text: string;
  /** Muted unless given; '' for the body's own, as for a failure to act on. */
  textClass?: string;
  /** Under the message, such as a retry button. */
  action?: ComponentChildren;
}

/** Capy over a short message, where a list or a page has nothing to show: empty, or failed. */
/**
 * What a screen shows when drawing it failed (a provider's data nobody expected): rather than a
 * black screen that answers nothing, what happened and a way out. Back closes that screen;
 * Start again reloads the app.
 */
export class ErrorBoundary extends Component<{ children: ComponentChildren }, { error: unknown }> {
  state = { error: null as unknown };

  componentDidCatch(error: unknown): void {
    log(`render failed: ${(error as Error) && (error as Error).stack ? (error as Error).stack : error}`);
    this.setState({ error });
  }

  render() {
    if (this.state.error === null) return this.props.children;
    return (
      <div style={{ height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'var(--bg)' }}>
        <CapyMessage
          mood="error"
          text={t('errorUnknown')}
          action={
            <div class="wrap" style={{ justifyContent: 'center' }}>
              <SecondaryButton icon="arrow_back_rounded" label={t('webBack')} onPressed={() => back()} autofocus />
              <SecondaryButton icon="refresh_rounded" label={t('restartApp')} onPressed={() => location.reload()} />
            </div>
          }
        />
      </div>
    );
  }
}

export function CapyMessage({ mood, text, textClass = 'muted', action }: CapyMessageProps) {
  return (
    <div class="capy-message">
      <CapyStatus mood={mood} size={68} />
      <p class={textClass}>{text}</p>
      {action && <div style={{ marginTop: '1.6rem' }}>{action}</div>}
    </div>
  );
}

export function Spinner({ size }: { size?: number }) {
  return <div class="spinner" style={size ? { width: `${size / 10}rem`, height: `${size / 10}rem` } : undefined} />;
}

/** The title bar of inner screens, with a back arrow for the remote. */
export function AppBar({ title }: { title: string }) {
  return (
    <div class="app-bar">
      <IconButton icon="arrow_back_rounded" onPressed={back} />
      <h1>{title}</h1>
    </div>
  );
}

interface TextFieldProps {
  label: string;
  value: string;
  onChange: (value: string) => void;
  /** Done on the TV keyboard: the next step (save, say), Flutter's onSubmitted. */
  onSubmit?: () => void;
  /** Flutter's TextInputAction.next: Done goes on to the following field, keyboard and all. */
  next?: boolean;
  hint?: string;
  help?: string;
  error?: string | null;
  password?: boolean;
  /** Flutter's keyboardType: the TV's keyboard offers ".com" and "@" for these. */
  inputType?: 'text' | 'url' | 'email' | 'number' | 'tel';
  autofocus?: boolean;
  /** An icon before the text, such as Search's magnifier (Flutter's prefixIcon). */
  icon?: string;
}

/**
 * Flutter's filled text field, for a remote: the arrows pass over it, and OK opens the TV's
 * keyboard on it; the keyboard's Done (or leaving it) brings the remote back, after it submits
 * or opens the next field as Flutter's textInputAction says.
 */
export function TextField(p: TextFieldProps) {
  const [editing, setEditing] = useState(false);
  const [revealed, setRevealed] = useState(false); // a password, shown to check what was typed
  const box = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (editing && input.current) input.current.focus();
  }, [editing]);

  /** Done with the keyboard: the remote comes back to the field, unless it already went elsewhere. */
  const finish = (submit: boolean, refocus = true) => {
    setEditing(false);
    const wrapper = box.current && (box.current.closest('.f') as HTMLElement | null);
    if (wrapper && refocus && !(submit && p.next && advance(wrapper))) focus(wrapper);
    if (submit && p.onSubmit) p.onSubmit();
  };

  // The key stops here: by the time it would reach the router the remote is back on the field,
  // and OK would open the keyboard again, Back close the screen
  const onKeyDown = (e: KeyboardEvent) => {
    if (e.keyCode === Keys.enter || e.keyCode === Keys.imeDone) {
      e.preventDefault();
      e.stopPropagation();
      // Text typed on the phone closes the keyboard only, as it only fills the field in Flutter
      finish(!(e as KeyboardEvent & { closeOnly?: boolean }).closeOnly);
    } else if (e.keyCode === Keys.imeCancel || e.keyCode === Keys.escape || e.keyCode === Keys.back) {
      e.preventDefault();
      e.stopPropagation();
      finish(false);
    }
  };

  const hidden = p.password && !revealed;
  const shown = hidden ? '•'.repeat(p.value.length) : p.value;
  return (
    <div>
      {p.password && (
        <div style={{ float: 'right', marginLeft: '1rem' }}>
          <IconButton
            icon={revealed ? 'visibility_off_rounded' : 'visibility_rounded'}
            label={t(revealed ? 'hidePassword' : 'showPassword')}
            onPressed={() => setRevealed(!revealed)}
          />
        </div>
      )}
      <Focusable class="field" onTap={() => setEditing(true)} autofocus={p.autofocus}>
        <div ref={box} class={p.icon ? 'row' : undefined}>
          {p.icon && (
            <span class="muted" style={{ display: 'flex', marginRight: '1.2rem' }}>
              <Icon icon={p.icon} size={24} />
            </span>
          )}
          <div class={p.icon ? 'grow' : undefined}>
            <label>{p.label}</label>
            {editing ? (
              <input
                ref={input}
                type={hidden ? 'password' : p.inputType || 'text'}
                value={p.value}
                autoComplete="off"
                autoCapitalize="off"
                spellcheck={false}
                onInput={(e) => p.onChange((e.target as HTMLInputElement).value)}
                onKeyDown={onKeyDown}
                onBlur={() => editing && finish(false, false)}
              />
            ) : (
              <div class={'value ellipsis' + (shown ? '' : ' hint')}>{shown || p.hint || ''}</div>
            )}
          </div>
        </div>
      </Focusable>
      {p.error ? <div class="field-error">{p.error}</div> : p.help ? <div class="field-help">{p.help}</div> : null}
    </div>
  );
}

/**
 * TextInputAction.next: the remote goes to what follows [field] and, when that is a field too,
 * opens its keyboard. False when nothing follows.
 */
function advance(field: HTMLElement): boolean {
  const layer = activeLayer();
  const all = layer ? focusables(layer) : [];
  const i = all.indexOf(field);
  const next = i >= 0 ? all[i + 1] : undefined;
  if (!next) return false;
  focus(next);
  if (next.classList.contains('field')) next.click();
  return true;
}

/** Something that tells its listeners when it changes (Flutter's ChangeNotifier). */
export class Notifier {
  private listeners = new Set<() => void>();

  listen(l: () => void): () => void {
    this.listeners.add(l);
    return () => this.listeners.delete(l);
  }

  protected notify(): void {
    this.listeners.forEach((l) => l());
  }
}

/** Re-renders the component whenever [n] changes. */
export function useNotifier(n: Notifier): void {
  const [, setVersion] = useState(0);
  useEffect(() => n.listen(() => setVersion((v) => v + 1)), [n]);
}
