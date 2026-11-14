// A video opened whole and with sound in the TV's YouTube app, as the Flutter app hands a trailer
// to the phone's (app/lib/ui/detail_screens.dart: _openTrailer). The trailer behind a page is
// another thing: silent, a stretch of it, framed from the sync server. Off the TV, a browser tab.
// Launching another app needs the application.launch privilege (static/config.xml).
import { isTizen } from './tv';

/* eslint-disable @typescript-eslint/no-explicit-any */
declare const tizen: any;

const YOUTUBE_APP = '111299001912'; // Samsung's YouTube app
const VIEW = 'http://tizen.org/appcontrol/operation/view';

/**
 * Opens [url] (a YouTube address) in the YouTube app when [id], its video, is known, else in
 * whatever views addresses; resolves with whether anything opened it.
 */
export function openYouTube(url: string, id: string | null): Promise<boolean> {
  if (!isTizen) return Promise.resolve(!!window.open(url, '_blank'));
  return new Promise((resolve) => {
    const anyViewer = () => {
      try {
        tizen.application.launchAppControl(new tizen.ApplicationControl(VIEW, url), null, () => resolve(true), () => resolve(false));
      } catch {
        resolve(false);
      }
    };
    if (!id) return anyViewer();
    try {
      // The app takes the video in its PAYLOAD, the deep link Samsung's YouTube understands
      const payload = new tizen.ApplicationControlData('PAYLOAD', [JSON.stringify({ values: `v=${id}` })]);
      tizen.application.launchAppControl(new tizen.ApplicationControl(VIEW, null, null, null, [payload]), YOUTUBE_APP, () => resolve(true), anyViewer);
    } catch {
      anyViewer();
    }
  });
}
