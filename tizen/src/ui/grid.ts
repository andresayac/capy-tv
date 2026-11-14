// Flutter's SliverGridDelegateWithMaxCrossAxisExtent (app/lib/ui/search_tab.dart, catalog.dart)
// for a CSS grid: as many columns as keep every tile at most so wide, all of one width. CSS's
// auto-fill counts the other way round (tiles at least so wide), which on a TV gives fewer and
// bigger posters than the phone shows.
import { JSX } from 'preact';
import { useLayoutEffect, useState } from 'preact/hooks';

/** A grid's ref and style; [maxExtent] and the spacings in dp, as Flutter gives them. */
export function useMaxExtentGrid(
  maxExtent: number,
  crossSpacing: number,
  mainSpacing: number,
): { ref: (el: HTMLElement | null) => void; style: JSX.CSSProperties } {
  const [el, setEl] = useState<HTMLElement | null>(null);
  const [columns, setColumns] = useState(0);
  useLayoutEffect(() => {
    if (!el) return;
    const measure = () => {
      const box = getComputedStyle(el);
      const dp = parseFloat(getComputedStyle(document.documentElement).fontSize) / 10; // 1rem is 10 dp
      const width = (el.clientWidth - parseFloat(box.paddingLeft) - parseFloat(box.paddingRight)) / dp;
      // Flutter's count: the width over a tile and its spacing, rounded up
      setColumns(width > 0 ? Math.max(1, Math.ceil(width / (maxExtent + crossSpacing))) : 0);
    };
    measure();
    // A tab out of sight measures nothing until it shows
    if (typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [el, maxExtent, crossSpacing]);
  return {
    ref: setEl,
    style: {
      display: 'grid',
      gridTemplateColumns: columns ? `repeat(${columns}, minmax(0, 1fr))` : `repeat(auto-fill, minmax(${maxExtent / 10}rem, 1fr))`,
      gridGap: `${mainSpacing / 10}rem ${crossSpacing / 10}rem`,
    },
  };
}
