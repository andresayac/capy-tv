// D-pad navigation: what Flutter's focus traversal did for the remote. Every element with the
// class "f" can take focus; the arrows move to the nearest one in that direction within the
// active layer (the top screen, or a dialog over it). A container marked data-fgroup remembers
// which of its elements had focus, so coming back to a row or a side menu lands where it was;
// one of its elements marked data-fentry (the side rail's current section) is where it is always
// entered instead. Along a row that scrolls sideways (.hscroll) Left and Right keep to the row
// while it has more that way; the side rail (data-rail) is reached from content by Left only.

export type Direction = 'up' | 'down' | 'left' | 'right';

/** The layer the remote acts on: the last open dialog, else the top screen. */
export function activeLayer(): HTMLElement | null {
  const dialogs = document.querySelectorAll<HTMLElement>('[data-layer="dialog"]');
  if (dialogs.length) return dialogs[dialogs.length - 1];
  const screens = document.querySelectorAll<HTMLElement>('.screen:not(.hidden)');
  return screens.length ? screens[screens.length - 1] : null;
}

function visible(el: HTMLElement): boolean {
  if (el.offsetParent === null) return false;
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0;
}

export function focusables(root: ParentNode): HTMLElement[] {
  return Array.prototype.filter.call(root.querySelectorAll<HTMLElement>('.f'), (el: HTMLElement) =>
    visible(el) && !el.hasAttribute('data-disabled'),
  ) as HTMLElement[];
}

export function focused(): HTMLElement | null {
  const el = document.activeElement as HTMLElement | null;
  return el && el.classList.contains('f') ? el : null;
}

/** Focuses [el], remembering it in its groups; scrolls it into view. */
export function focus(el: HTMLElement): void {
  el.focus({ preventScroll: true });
  remember(el);
  reveal(el);
}

function remember(el: HTMLElement): void {
  let group = el.parentElement && (el.parentElement.closest('[data-fgroup]') as HTMLElement | null);
  while (group) {
    (group as GroupElement).__last = el;
    group = group.parentElement && (group.parentElement.closest('[data-fgroup]') as HTMLElement | null);
  }
}

interface GroupElement extends HTMLElement {
  __last?: HTMLElement;
}

/**
 * Scrolls the scrollable ancestors just enough to show [el] with a margin. A box may keep a strip
 * covered by something that stays put in it (data-inset-left / data-inset-top, in px).
 */
function reveal(el: HTMLElement): void {
  const margin = 48;
  let box = el.parentElement;
  while (box && box !== document.body) {
    const style = getComputedStyle(box);
    const scrollsY = /(auto|scroll)/.test(style.overflowY) && box.scrollHeight > box.clientHeight;
    const scrollsX = /(auto|scroll)/.test(style.overflowX) && box.scrollWidth > box.clientWidth;
    if (scrollsY || scrollsX) {
      const b = box.getBoundingClientRect();
      const r = el.getBoundingClientRect();
      const top = margin + (Number(box.getAttribute('data-inset-top')) || 0);
      const left = margin + (Number(box.getAttribute('data-inset-left')) || 0);
      if (scrollsY) {
        if (r.top < b.top + top) box.scrollTop -= b.top + top - r.top;
        else if (r.bottom > b.bottom - margin) box.scrollTop += r.bottom - (b.bottom - margin);
      }
      if (scrollsX) {
        if (r.left < b.left + left) box.scrollLeft -= b.left + left - r.left;
        else if (r.right > b.right - margin) box.scrollLeft += r.right - (b.right - margin);
      }
    }
    box = box.parentElement;
  }
}

/**
 * The best element from [from] towards [dir]: it must lie beyond [from]'s edge in that
 * direction; nearer wins, and being out of line costs more than being far.
 */
function nearest(
  from: DOMRect,
  dir: Direction,
  candidates: HTMLElement[],
  rectOf: (el: HTMLElement) => DOMRect = (el) => el.getBoundingClientRect(),
): HTMLElement | null {
  let best: HTMLElement | null = null;
  let bestScore = Infinity;
  const fx = (from.left + from.right) / 2;
  const fy = (from.top + from.bottom) / 2;
  for (const el of candidates) {
    const r = rectOf(el);
    const cx = (r.left + r.right) / 2;
    const cy = (r.top + r.bottom) / 2;
    let main: number, cross: number;
    switch (dir) {
      case 'right':
        if (r.left < from.right - 4 || cx <= fx) continue;
        main = r.left - from.right;
        cross = overlap(from.top, from.bottom, r.top, r.bottom) ? 0 : Math.abs(cy - fy);
        break;
      case 'left':
        if (r.right > from.left + 4 || cx >= fx) continue;
        main = from.left - r.right;
        cross = overlap(from.top, from.bottom, r.top, r.bottom) ? 0 : Math.abs(cy - fy);
        break;
      case 'down':
        if (r.top < from.bottom - 4 || cy <= fy) continue;
        main = r.top - from.bottom;
        cross = overlap(from.left, from.right, r.left, r.right) ? Math.abs(r.left - from.left) / 8 : Math.abs(cx - fx);
        break;
      default:
        if (r.bottom > from.top + 4 || cy >= fy) continue;
        main = from.top - r.bottom;
        cross = overlap(from.left, from.right, r.left, r.right) ? Math.abs(r.left - from.left) / 8 : Math.abs(cx - fx);
    }
    const score = Math.max(main, 0) + cross * 3;
    if (score < bestScore) {
      bestScore = score;
      best = el;
    }
  }
  return best;
}

function overlap(a1: number, a2: number, b1: number, b2: number): boolean {
  return Math.min(a2, b2) - Math.max(a1, b1) > 4;
}

/** Whether the remote moved since the top layer settled: then late content leaves the focus alone. */
let userMoved = false;

/** A key the user pressed on the remote (an arrow, OK): what they chose is not taken away. */
export function noteUserAction(): void {
  userMoved = true;
}

/** Moves focus towards [dir]; false when there is nothing that way. */
export function move(dir: Direction): boolean {
  userMoved = true;
  const layer = activeLayer();
  if (!layer) return false;
  const current = focused();
  const all = focusables(layer);
  if (!current || !layer.contains(current)) {
    const first = initial(layer);
    if (first) focus(first);
    return !!first;
  }
  const from = current.getBoundingClientRect();
  const others = all.filter((el) => el !== current);
  // Each measured once, however many searches there are
  const rects = new Map<HTMLElement, DOMRect>();
  const rectOf = (el: HTMLElement) => {
    let r = rects.get(el);
    if (!r) rects.set(el, (r = el.getBoundingClientRect()));
    return r;
  };
  const row = current.closest('.hscroll') as HTMLElement | null;
  let target: HTMLElement | null;
  if (row && (dir === 'left' || dir === 'right')) {
    // Along the row first, however far its next item is (a ranked number or a wide card between
    // them): once the row has scrolled along, the side rail would be nearer than it
    target = nearest(from, dir, others.filter((el) => row.contains(el)), rectOf);
    // At its end Right stays, rather than dropping to another row, unless the row goes on to the
    // button in its header (data-fheader: the only way there); Left goes on, to the side rail
    if (!target && dir === 'right') {
      const header = row.hasAttribute('data-fheader') ? row.previousElementSibling : null;
      target = (header && focusables(header)[0]) || null;
      if (!target) return false;
    }
    if (!target) target = nearest(from, dir, others, rectOf);
  } else {
    // Up and Down keep to the content: the side rail, taller than it, is not below the last row
    const inRail = !!current.closest('[data-rail]');
    const fromContent = dir === 'up' || dir === 'down' ? others.filter((el) => inRail || !el.closest('[data-rail]')) : others;
    target = nearest(from, dir, fromContent, rectOf);
  }
  if (!target) {
    // Nothing more that way: what is below (or above) the last item can still be read
    if (dir === 'up' || dir === 'down') scrollAlong(current, dir === 'down' ? 1 : -1);
    return false;
  }
  // Entering a group from outside: on its entry if it has one (app/lib/ui/home_screen.dart's
  // _SideNav lands on the current section, not on whichever item is level with where the remote
  // left), else where it was left, if that is still there
  const group = target.closest('[data-fgroup]') as GroupElement | null;
  if (group && !group.contains(current)) {
    const entry = all.filter((el) => el.hasAttribute('data-fentry') && group.contains(el))[0];
    if (entry) target = entry;
    else if (group.__last && group.contains(group.__last) && visible(group.__last)) target = group.__last;
  }
  focus(target);
  return true;
}

/** Scrolls [el]'s nearest box that scrolls up and down by a few lines, [sign] 1 down and -1 up. */
function scrollAlong(el: HTMLElement, sign: number): void {
  let box = el.parentElement;
  while (box && box !== document.body) {
    if (/(auto|scroll)/.test(getComputedStyle(box).overflowY) && box.scrollHeight > box.clientHeight) {
      box.scrollTop += sign * 300;
      return;
    }
    box = box.parentElement;
  }
}

/** The element a layer starts on: the one marked data-autofocus, else the first. */
export function initial(layer: HTMLElement): HTMLElement | null {
  const all = focusables(layer);
  return all.filter((el) => el.hasAttribute('data-autofocus'))[0] || all[0] || null;
}

/**
 * Where settle() put the remote only for want of a data-autofocus element (the back arrow of a
 * page still loading): Flutter has nothing focused there yet, so autofocus that comes later wins.
 */
let provisional: HTMLElement | null = null;

/**
 * Content that just loaded asks for the focus (Flutter's autofocus when the widget appears): it
 * gets it, in the layer the remote acts on, when the remote is nowhere yet, or on a provisional
 * place or one that yields (data-fyield, like the side rail the screen started on) the user has
 * not moved from.
 */
export function offer(el: HTMLElement | null): void {
  if (!el || !el.classList.contains('f') || el.hasAttribute('data-disabled')) return;
  const layer = activeLayer();
  if (!layer || !layer.contains(el) || !visible(el)) return;
  const active = document.activeElement;
  if (active && active.tagName === 'INPUT') return; // the TV's keyboard is typing there
  const current = focused();
  if (current === el) return;
  const free = !userMoved && !!current && (current === provisional || !!current.closest('[data-fyield]'));
  if (!current || !layer.contains(current) || free) {
    focus(el);
    provisional = null;
  }
}

/** Puts focus inside [layer] unless it already is: on [last] if given and still there. */
export function settle(layer: HTMLElement, last?: HTMLElement | null): void {
  // Already inside: on an element, or in a field the TV's keyboard types into (a message that
  // comes meanwhile must not close it)
  const current = focused();
  if (current && layer.contains(current)) return;
  const active = document.activeElement;
  if (active && active.tagName === 'INPUT' && layer.contains(active)) return;
  const back = last && layer.contains(last) && visible(last) && !last.hasAttribute('data-disabled') ? last : null;
  const target = back || initial(layer);
  if (target) {
    focus(target);
    userMoved = false;
    provisional = back || target.hasAttribute('data-autofocus') ? null : target;
  }
}

// ---- long press --------------------------------------------------------------------------------

interface LongPressable extends HTMLElement {
  __longPress?: () => void;
}

/** What holding OK on [el] does (Flutter's onLongPress); null clears it. */
export function setLongPress(el: HTMLElement, action: (() => void) | null): void {
  (el as LongPressable).__longPress = action || undefined;
}

export function longPressOf(el: HTMLElement): (() => void) | undefined {
  return (el as LongPressable).__longPress;
}
