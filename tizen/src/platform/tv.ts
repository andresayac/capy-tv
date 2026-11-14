// What the Samsung TV adds to the page (the `tizen` and `webapis` globals), with what stands in
// for it in a desktop browser while developing.

/* eslint-disable @typescript-eslint/no-explicit-any */
declare const tizen: any;
declare const webapis: any;

export const isTizen = typeof tizen !== 'undefined';

/** Remote keys as keyCodes. The arrows, OK and Back exist everywhere; the rest only once registered. */
export const Keys = {
  left: 37,
  up: 38,
  right: 39,
  down: 40,
  enter: 13,
  back: 10009,
  escape: 27, // the desktop's back
  playPause: 10252,
  play: 415,
  pause: 19,
  stop: 413,
  fastForward: 417,
  rewind: 412,
  channelUp: 427,
  channelDown: 428,
  info: 457,
  trackPrevious: 10232,
  trackNext: 10233,
  caption: 10221, // subtitles, on the remotes that have it
  mts: 10195, // sound track (Multichannel Television Sound)
  red: 403,
  green: 404,
  yellow: 405,
  blue: 406,
  // The TV's on-screen keyboard
  imeDone: 65376,
  imeCancel: 65385,
} as const;

const MEDIA_KEYS = [
  'MediaPlayPause', 'MediaPlay', 'MediaPause', 'MediaStop', 'MediaFastForward', 'MediaRewind',
  'MediaTrackPrevious', 'MediaTrackNext', 'ChannelUp', 'ChannelDown', 'Info', 'Caption', 'MTS',
  'ColorF0Red', 'ColorF1Green', 'ColorF2Yellow', 'ColorF3Blue',
];

/** The number keys, for the PIN pad: unregistered, the TV keeps them and the app never sees them. */
const NUMBER_KEYS = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];

/** Asks the TV to hand the media, channel and color keys to the app instead of acting on them. */
export function registerKeys(): void {
  if (!isTizen) return;
  for (const k of MEDIA_KEYS.concat(NUMBER_KEYS)) {
    try {
      tizen.tvinputdevice.registerKey(k);
    } catch {
      // A model without that key
    }
  }
}

/** Leaves the app (Back on the first screen). */
export function exitApp(): void {
  if (isTizen) tizen.application.getCurrentApplication().exit();
}

let bare: string | null = null;

/** The TV's model ("UN65TU7000KXZL"), or "" off the TV or without the privilege. */
function model(): string {
  if (bare === null) {
    bare = '';
    try {
      if (isTizen) bare = String(webapis.productinfo.getRealModel() || '');
    } catch {
      // Without the privilege
    }
  }
  return bare;
}

let name: string | null = null;

/**
 * How the TV calls itself to phones and in the sync account. Tizen gives apps no name the user
 * set, so it is the Flutter app's fallback on Android, "Manufacturer Model" (app/lib/device.dart).
 */
export function deviceName(): string {
  if (name === null) {
    const m = model();
    name = !m ? 'Browser' : /^samsung/i.test(m) ? m : `Samsung ${m}`;
  }
  return name;
}

/**
 * Whether [dev], the device a history entry was watched on, is this TV: also under the bare model
 * it called itself before, so its own last entries do not look as if they came from elsewhere.
 */
export function isThisDevice(dev: string): boolean {
  return dev === deviceName() || (dev !== '' && dev === model());
}

export function webapisOrNull(): any {
  return typeof webapis !== 'undefined' ? webapis : null;
}
