// A screen stack like Flutter's Navigator: push() returns what the screen pops with, Back pops,
// and focus comes back to where it was, after a screen and after a dialog alike. Screens below
// the top stay mounted (hidden), so they keep their state.
import { ComponentChild, createContext } from 'preact';
import { useContext, useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks';
import { exitApp, Keys } from '../platform/tv';
import { ErrorBoundary } from './components';
import { activeLayer, focused, longPressOf, move, noteUserAction, settle } from './focus';

type Done<T> = (value?: T) => void;

interface Entry {
  id: number;
  render: (done: Done<unknown>) => ComponentChild;
  done: Done<unknown>;
  last?: HTMLElement | null; // focus to return to when what covered it closes
  clear?: boolean; // see-through: the video plays under it
}

let nextId = 1;
const screens: Entry[] = [];
const dialogs: Entry[] = [];
const listeners = new Set<() => void>();
const changed = () => listeners.forEach((l) => l());

/** The entry the remote acts on: the last dialog, else the top screen. */
const topEntry = (): Entry | undefined => dialogs[dialogs.length - 1] || screens[screens.length - 1];

function open<T>(list: Entry[], render: (done: Done<T>) => ComponentChild, clear = false): Promise<T | undefined> {
  return new Promise((resolve) => {
    // What opens it, a screen's element or a dialog's, gets the focus back when it closes (a
    // Settings row after its choice, the playlist's menu after a cancelled delete). Focus still
    // in a dialog or screen that closed a moment ago leaves what opened that one in its place. A
    // field the TV's keyboard is typing into counts as the field
    const top = topEntry();
    const active = document.activeElement as HTMLElement | null;
    const current = active && active !== document.body ? (active.closest('.f') as HTMLElement | null) : null;
    const owner = current && (current.closest('[data-entry]') as HTMLElement | null);
    if (top && owner && owner.getAttribute('data-entry') === String(top.id)) top.last = current;
    const entry: Entry = {
      id: nextId++,
      render: render as Entry['render'],
      clear,
      done: (value) => {
        const i = list.indexOf(entry);
        if (i < 0) return;
        list.splice(i, 1);
        changed();
        resolve(value as T | undefined);
      },
    };
    list.push(entry);
    changed();
  });
}

/** Shows a screen over the current one; resolves with what it is closed with. */
export function push<T = void>(render: (done: Done<T>) => ComponentChild, opts: { clear?: boolean } = {}): Promise<T | undefined> {
  return open(screens, render, opts.clear);
}

/** Shows a dialog over the top screen; resolves with what it is closed with. */
export function showDialog<T = void>(render: (done: Done<T>) => ComponentChild): Promise<T | undefined> {
  return open(dialogs, render);
}

/** Closes every dialog open, of whatever screen. */
export function closeDialogs(): void {
  while (dialogs.length) dialogs[dialogs.length - 1].done();
}

/** How many screens are open. */
export const screenCount = (): number => screens.length;

/** Closes every dialog, and every screen over the first [count]. */
export function popTo(count: number): void {
  while (dialogs.length) dialogs[dialogs.length - 1].done();
  while (screens.length > count) screens[screens.length - 1].done();
}

/** Closes every dialog and screen over the first one. */
export function popToRoot(): void {
  popTo(1);
}

/** Closes the top dialog, else the top screen; on the first screen, leaves the app. */
export function back(): void {
  if (!maybePop()) leave();
}

/**
 * Flutter's Navigator.maybePop: Back without leaving the app (the phone's Back button). False
 * when there was nothing to close.
 */
export function maybePop(): boolean {
  // Each that may answer, the newest first, until one deals with it: one that does not (a
  // screensaver that is not showing) must not keep Back from the screen's own
  const top = topEntry();
  for (let i = backHandlers.length - 1; i >= 0; i--) {
    const h = backHandlers[i];
    if ((h.owner === null || (top && h.owner === top.id)) && h.run()) return true;
  }
  if (dialogs.length) dialogs[dialogs.length - 1].done();
  else if (screens.length > 1) screens[screens.length - 1].done();
  else return false;
  return true;
}

const exitTasks: (() => Promise<void> | void)[] = [];
let leaving = false;

/**
 * [task] runs when Back leaves the app, which waits for it up to 3 s: Android keeps the Flutter
 * app's process running after it leaves, a TV app's page dies at once.
 */
export function beforeExit(task: () => Promise<void> | void): void {
  exitTasks.push(task);
}

function leave(): void {
  if (leaving) return;
  leaving = true;
  const tasks = exitTasks.map((task) => Promise.resolve().then(task).catch(() => undefined));
  const cap = new Promise((resolve) => setTimeout(resolve, 3000));
  Promise.race([Promise.all(tasks), cap]).then(() => {
    try {
      exitApp();
    } finally {
      leaving = false; // still here: a desktop browser
    }
  });
}

/** The screen or dialog a component is in; null outside the Navigator (the screensaver's layer). */
const Owner = createContext<number | null>(null);

interface Handler<E> {
  owner: number | null;
  run: (e: E) => boolean;
}

/**
 * The latest handler of the screen or dialog on top, or of no screen: as Flutter gives keys and
 * Back to the top route only, the player's do not act while its audio and subtitles panel is open.
 */
function latest<E>(list: Handler<E>[]): Handler<E> | undefined {
  const top = topEntry();
  for (let i = list.length - 1; i >= 0; i--) {
    const h = list[i];
    if (h.owner === null || (top && h.owner === top.id)) return h;
  }
  return undefined;
}

/** Keeps [handler] in [list] while mounted, with the screen or dialog it belongs to. */
function useHandler<E>(list: Handler<E>[], handler: (e: E) => boolean): void {
  const owner = useContext(Owner);
  const ref = useRef(handler);
  ref.current = handler;
  useEffect(() => {
    const h: Handler<E> = { owner, run: (e) => ref.current(e) };
    list.push(h);
    return () => {
      list.splice(list.indexOf(h), 1);
    };
  }, []);
}

const backHandlers: Handler<void>[] = [];

/** While mounted and on top, Back asks [handler] first; it returns true when it dealt with it. */
export function useBack(handler: () => boolean): void {
  useHandler(backHandlers, handler);
}

// ---- toast -----------------------------------------------------------------------------------

interface Snack {
  id: number;
  text: string;
  ms: number;
}

/** Waiting their turn, the one on screen first (Flutter's ScaffoldMessenger queue). */
const snacks: Snack[] = [];
let snackLeaving = false;
const SNACK_OUT = 150; // its fade-out (theme.css .snackbar.leaving)

/**
 * The Flutter app's snack bar: a short message at the bottom. One that comes while another shows
 * waits for it to have had its time ("Backup received" after "Phone connected").
 */
export function toast(text: string, ms = 4000): void {
  snacks.push({ id: nextId++, text, ms });
  if (snacks.length === 1) showSnack();
}

function showSnack(): void {
  snackLeaving = false;
  changed();
  window.setTimeout(() => {
    snackLeaving = true;
    changed();
    window.setTimeout(() => {
      snacks.shift();
      if (snacks.length) showSnack();
      else changed();
    }, SNACK_OUT);
  }, snacks[0].ms);
}

// ---- keys ------------------------------------------------------------------------------------

const keyHandlers: Handler<KeyboardEvent>[] = [];

/** While mounted and on top, [handler] sees every key first (the player's media keys); true = handled. */
export function useKeys(handler: (e: KeyboardEvent) => boolean): void {
  useHandler(keyHandlers, handler);
}

/**
 * OK held down on an item with a long press, until it is let go: a tap if that is before Flutter's
 * 500 ms, else the long press has [fired].
 */
let held: { el: HTMLElement; timer: number; fired: boolean; last: number } | null = null;
const LONG_PRESS = 500;

/**
 * The InkWell splash and highlight OK gives in Flutter: Chromium shows no :active for keys, so a
 * class does, for as long as theme.css's .pressed fades.
 */
function pressed(el: HTMLElement & { __pressed?: number }): void {
  clearTimeout(el.__pressed); // pressed again meanwhile: the fade starts over, and lasts its time
  el.classList.remove('pressed');
  void el.offsetWidth;
  el.classList.add('pressed');
  el.__pressed = window.setTimeout(() => el.classList.remove('pressed'), 300);
}

const ONCE: number[] = [Keys.enter, Keys.back, Keys.escape, Keys.info, Keys.playPause, Keys.play, Keys.pause, Keys.trackNext, Keys.trackPrevious];

/** Remote keys down with no keyup yet, and since when: for firmware that does not mark repeats. */
const down: Record<number, number> = {};

/**
 * Whether [e] repeats a key still held. Only the remote's own keys: the phone's have no keyup, and a
 * keyup that got lost stops counting after a second.
 */
function isRepeat(e: KeyboardEvent): boolean {
  if (e.repeat) return true;
  if (!e.isTrusted) return false;
  const now = Date.now();
  const since = down[e.keyCode];
  down[e.keyCode] = now;
  return since !== undefined && now - since < 1000;
}

function onKey(e: KeyboardEvent): void {
  const editing = document.activeElement && document.activeElement.tagName === 'INPUT';
  if (editing) return; // the text field and the TV's keyboard have it
  if (held && e.keyCode === Keys.enter) {
    // The remote repeats a key held down; a press long after the last one means its keyup got lost
    const now = Date.now();
    const lost = now - held.last > 1000;
    held.last = now;
    if (!lost) {
      e.preventDefault();
      return;
    }
    clearTimeout(held.timer);
    held = null;
  }
  // A key held down repeats; OK, Back, Info and the play keys act once per press: held, they would
  // type a PIN 1111, flip a switch back and forth, close screen after screen or pause and play
  if (ONCE.indexOf(e.keyCode) >= 0 && isRepeat(e)) {
    e.preventDefault();
    return;
  }
  const handler = latest(keyHandlers);
  if (handler && handler.run(e)) {
    e.preventDefault();
    return;
  }
  let handled = true;
  switch (e.keyCode) {
    case Keys.left: move('left'); break;
    case Keys.right: move('right'); break;
    case Keys.up: move('up'); break;
    case Keys.down: move('down'); break;
    case Keys.enter: {
      noteUserAction();
      const el = focused();
      if (!el) {
        move('down');
        break;
      }
      if (!e.repeat) pressed(el);
      const long = longPressOf(el);
      // A key from the phone or a script has no keyup to wait for: it taps at once
      if (long && e.isTrusted) {
        const hold = {
          el,
          fired: false,
          last: Date.now(),
          timer: window.setTimeout(() => {
            hold.fired = true;
            // Not for an item that went away or that the remote left meanwhile
            if (el.isConnected && el === focused()) long();
          }, LONG_PRESS),
        };
        held = hold;
      } else {
        el.click();
      }
      break;
    }
    case Keys.info: {
      // The remote's other way to the long press, for a hand that does not hold OK
      const el = focused();
      const long = el && longPressOf(el);
      if (long) {
        noteUserAction();
        long();
      } else {
        handled = false;
      }
      break;
    }
    case Keys.back:
    case Keys.escape:
      back();
      break;
    default:
      handled = false;
  }
  if (handled) e.preventDefault();
}

function onKeyUp(e: KeyboardEvent): void {
  delete down[e.keyCode];
  if (!held || e.keyCode !== Keys.enter) return;
  const { el, timer, fired } = held;
  held = null;
  clearTimeout(timer);
  e.preventDefault();
  if (!fired && el.isConnected && el === focused()) el.click();
}

// ---- view ------------------------------------------------------------------------------------

const OnTop = createContext(true);

/** Whether the screen this is in is the one on top: what plays should stop under another. */
export function useOnTop(): boolean {
  return useContext(OnTop);
}

export function Navigator({ home }: { home: () => ComponentChild }) {
  const [, setVersion] = useState(0);
  const update = () => setVersion((v) => v + 1);
  const root = useRef<HTMLDivElement>(null);
  if (!screens.length) screens.push({ id: nextId++, render: home, done: () => {} });

  useEffect(() => {
    listeners.add(update);
    document.addEventListener('keydown', onKey);
    document.addEventListener('keyup', onKeyUp);
    return () => {
      listeners.delete(update);
      document.removeEventListener('keydown', onKey);
      document.removeEventListener('keyup', onKeyUp);
    };
  }, []);

  // After every change, focus belongs in the layer on top: back where it was (on what opened the
  // dialog or screen that just closed), or its first element
  useLayoutEffect(() => {
    const layer = activeLayer();
    const top = topEntry();
    if (layer) settle(layer, top && top.last);
  });

  return (
    <div ref={root}>
      {screens.map((s, i) => (
        <div key={s.id} data-entry={s.id} class={'screen' + (i < screens.length - 1 ? ' hidden' : '') + (s.clear ? ' clear' : '')}>
          <Owner.Provider value={s.id}>
            <OnTop.Provider value={i === screens.length - 1}>
              <ErrorBoundary>{s.render(s.done)}</ErrorBoundary>
            </OnTop.Provider>
          </Owner.Provider>
        </div>
      ))}
      {dialogs.map((d) => (
        <div key={d.id} data-entry={d.id} class="scrim" data-layer="dialog">
          <Owner.Provider value={d.id}>
            <ErrorBoundary>{d.render(d.done)}</ErrorBoundary>
          </Owner.Provider>
        </div>
      ))}
      {snacks.length > 0 && (
        <div key={snacks[0].id} class={'snackbar' + (snackLeaving ? ' leaving' : '')}>
          {snacks[0].text}
        </div>
      )}
    </div>
  );
}

/** Re-renders the stack: for stores that changed outside any screen. */
export function refresh(): void {
  changed();
}
