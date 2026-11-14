// Back to the button that opened a dialog once it closes, as Flutter's focus returns to the route
// below: the router alone settles on the screen's first element.
import { activeLayer, focus, focused } from './focus';

/** Runs [dialog] (one that showDialog opens) and then puts the remote back where it was. */
export async function keepingFocus<T>(dialog: () => Promise<T>): Promise<T> {
  const opener = focused();
  try {
    return await dialog();
  } finally {
    refocus(opener);
  }
}

/** Focuses [el] once the screen it is on has settled, if it is still there and on top. */
export function refocus(el: HTMLElement | null): void {
  if (!el) return;
  setTimeout(() => {
    const layer = activeLayer();
    if (layer && layer.contains(el) && document.body.contains(el)) focus(el);
  }, 0);
}
