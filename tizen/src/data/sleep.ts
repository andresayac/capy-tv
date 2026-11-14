// Sleep timer: after some minutes, or when what is playing ends, the player asks "Still watching?"
// and, with no answer, stops. Lives for the session only, like the TV's own sleep timer.
import { Notifier } from '../ui/components';

/** Minutes offered in the sleep picker (0 = off). */
export const SLEEP_CHOICES = [0, 15, 30, 60, 90, 120] as const;
export type SleepMinutes = (typeof SLEEP_CHOICES)[number];

export type SleepMode =
  | { kind: 'off' }
  | { kind: 'after'; minutes: SleepMinutes; endsAt: number }   // absolute ms
  | { kind: 'atEnd' };

class SleepTimer extends Notifier {
  private current: SleepMode = { kind: 'off' };

  get mode(): SleepMode {
    return this.current;
  }

  set(mode: SleepMode): void {
    this.current = mode;
    this.notify();
  }

  /** Milliseconds left before it fires, or null when off or set to the end. */
  get left(): number | null {
    return this.current.kind === 'after' ? Math.max(0, this.current.endsAt - Date.now()) : null;
  }

  get atEnd(): boolean {
    return this.current.kind === 'atEnd';
  }
}

export const sleepTimer = new SleepTimer();
