// What another device of the account sent here to play ("Send to", app/lib/sync/cast.dart).
import { MediaRef } from '../data/library';
import { Notifier } from '../ui/components';

export interface CastRequest {
  /** This TV's id of the playlist it is in. */
  playlistId: string;
  ref: MediaRef;
  position: number; // ms
  /** The name of the device that sent it. */
  from: string;
  /** When it was sent. */
  at: number;
}

/** How long a request stays good: one found later (a TV that was off) is not played. */
export const CAST_FOR = 2 * 60 * 1000;

/** The last request sent here, until the screen that plays it takes it. */
class CastInbox extends Notifier {
  value: CastRequest | null = null;

  put(r: CastRequest): void {
    this.value = r;
    this.notify();
  }

  clear(): void {
    this.value = null;
  }
}

export const castRequest = new CastInbox();
