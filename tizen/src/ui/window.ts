// Only the rows near the view are built, as Flutter's ListView.builder and GridView.builder do
// (app/lib/ui/guide_screen.dart, home_screen.dart): a category can have hundreds of channels, and
// on every key press the remote weighs each focusable element that exists. The rows share one
// height; the scrolling box keeps room for those not built, so its scroll stays true.
import { useLayoutEffect, useRef, useState } from 'preact/hooks';

/** Rows built beyond those in view, each way. */
const OVERSCAN = 5;

export interface RowWindow {
  /** For the scrolling box. */
  ref: (el: HTMLElement | null) => void;
  /** The first row built, and the one past the last. */
  first: number;
  end: number;
  /** For the box's onScroll. */
  onScroll: () => void;
  /** Row [row] took the focus: the rows next to it are built before the next key arrives. */
  focusRow: (row: number) => void;
}

/**
 * [rows] rows of [rowPx] each (spacing included), the first [offsetPx] down the box. A list that
 * opens part way down says at which row: that row has to exist in the first render to take the focus.
 */
export function useRowWindow(rows: number, rowPx: number, offsetPx = 0, startRow = 0): RowWindow {
  const box = useRef<HTMLElement | null>(null);
  const [start, setStart] = useState(Math.max(0, startRow - OVERSCAN));
  const [inView, setInView] = useState(6);
  const current = useRef(0);
  const count = inView + 2 * OVERSCAN;
  // Fewer rows than when it was set (a list that shrank): the window still ends on the last one
  const first = Math.max(0, Math.min(start, rows - count));
  current.current = first;

  useLayoutEffect(() => {
    if (box.current && box.current.clientHeight) setInView(Math.ceil(box.current.clientHeight / rowPx) + 1);
  }, [rowPx]);

  /** Makes sure rows [lo, hi] are built, building around them when they are not. */
  const cover = (lo: number, hi: number) => {
    const f = current.current;
    if (lo >= f && hi < f + count) return;
    const next = Math.max(0, Math.min(Math.round((lo + hi) / 2) - Math.floor(count / 2), rows - count));
    if (next !== f) {
      current.current = next;
      setStart(next);
    }
  };

  return {
    ref: (el) => {
      box.current = el;
    },
    first,
    end: Math.min(rows, first + count),
    onScroll: () => {
      const b = box.current;
      if (!b) return;
      const top = Math.floor(Math.max(0, b.scrollTop - offsetPx) / rowPx);
      cover(top - 2, top + inView + 1);
    },
    focusRow: (row) => cover(row - 2, row + 2),
  };
}
