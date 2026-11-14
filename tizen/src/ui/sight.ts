// Whether a component is in sight: its screen on top and, inside Home, its tab the one chosen.
// Flutter mutes what is out of sight with TickerMode (app/lib/ui/home_screen.dart: "Tabs out of
// sight neither animate nor play trailers"); trailers ask this before they play.
import { createContext } from 'preact';
import { useContext } from 'preact/hooks';
import { useOnTop } from './router';

/** Given by Home to each tab pane: false while another tab is chosen. */
export const TabInSight = createContext(true);

export function useInSight(): boolean {
  const top = useOnTop();
  const tab = useContext(TabInSight);
  return top && tab;
}
