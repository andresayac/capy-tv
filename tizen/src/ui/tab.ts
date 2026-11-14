// The strip at a Home tab's left that the side rail lies over (app/lib/ui/home_screen.dart gives
// it to the tabs as MediaQuery padding.left, as a camera cutout). Whether a tab is in sight is
// ui/sight.ts.
import { createContext } from 'preact';
import { useContext } from 'preact/hooks';

/** The side rail's width on a TV (Flutter's 108, with the names under the icons), in rem. */
export const RAIL_WIDTH = 10.8;

/** Given by Home to each tab pane: RAIL_WIDTH where the tab goes under the rail, else 0. */
export const RailInset = createContext(0);

/**
 * How much of the left edge the side rail lies over, in rem: RAIL_WIDTH in the Home, Movies and
 * Series tabs, whose artwork goes under it while their text and rows keep clear of it; 0 anywhere
 * else. A row that scrolls under it starts at the screen's edge, pads its items by this, and marks
 * the strip with data-inset-left={inset * 20} (px), so the remote's focus never sits under it.
 */
export function useRailInset(): number {
  return useContext(RailInset);
}
