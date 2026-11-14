import './polyfills';
import { render } from 'preact';
import { setUntitledName } from './data/models';
import { settings } from './data/settings';
import { trending } from './data/trending';
import { language } from './i18n';
import { log } from './log';
import { isTizen, registerKeys } from './platform/tv';
import { PlaylistsScreen } from './screens/playlists';
import { ProfileGate } from './screens/profiles';
import { watchIdle } from './screens/screensaver';
import { syncService } from './sync/service';
import { companionHost } from './remote/host';
import { t } from './i18n';
import { beforeExit, Navigator, toast } from './ui/router';
import './ui/theme.css';

setUntitledName(t('untitled')); // what comes without a name, named in the app's language
// The text's size chosen in Settings: the text alone grows (theme.css's --text), the layout stays
const applyTextSize = () => document.documentElement.style.setProperty('--text', String(settings.textSize / 100));
applyTextSize();
settings.listen(applyTextSize);
registerKeys();
watchIdle();
syncService.start();
// A session ended elsewhere (a new password on a phone): said once, wherever one is, or "Continue
// watching" would fall behind for weeks with nobody knowing why
let toldExpired = false;
const tellExpired = () => {
  const expired = syncService.status === 'expired';
  if (expired && !toldExpired) toast(t('syncExpiredNotice'));
  toldExpired = expired;
};
syncService.listen(tellExpired);
setTimeout(tellExpired, 3000); // it may have ended before the app was up
// What the Flutter app sends on pause (app/lib/sync/sync_service.dart): Back on the first screen
// ends the page, debounce and quiet timers with it, so what waits or is on its way goes out first
beforeExit(() => {
  if (syncService.pending) return syncService.syncNow();
  if (syncService.status !== 'syncing') return;
  // Only on its way: waiting for it is enough, syncNow() would ask for one more round
  return new Promise<void>((resolve) => {
    const unlisten = syncService.listen(() => {
      if (syncService.status === 'syncing') return;
      unlisten();
      resolve();
    });
  });
});
companionHost.onEvent((e) => {
  if (e.kind === 'playlist') toast(t('playlistReceived', { name: e.name }));
  else if (e.kind === 'backup') toast(t('backupReceived', { added: e.added, updated: e.updated }));
  else if (e.kind === 'remote') toast(t('phoneConnected'));
  else toast(t('syncSignedInAs', { email: e.email }));
});
// AVPlay's plane exists on the TV only; elsewhere its <object> would say the plug-in is missing
if (!isTizen) document.getElementById('av')!.style.display = 'none';
log(`start ${navigator.userAgent}`);
// What is trending this week, in the TV's language and country (titles differ between countries)
trending.load();
const region = /^[a-z]{2}-([A-Z]{2})$/.exec(navigator.language || '');
trending.refresh(region && navigator.language.slice(0, 2) === language ? navigator.language : language);
render(<Navigator home={() => (
  <ProfileGate>
    <PlaylistsScreen />
  </ProfileGate>
)} />, document.getElementById('root')!);
