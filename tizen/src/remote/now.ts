// What a phone acting as a remote needs from outside any screen (app/lib/remote/remote_input.dart):
// what is playing, and text typed on the phone with no field to put it in.
import { Notifier } from '../ui/components';

class NowPlaying extends Notifier {
  value: { title: string; subtitle?: string } | null = null;

  set(value: { title: string; subtitle?: string } | null): void {
    this.value = value;
    this.notify();
  }
}

/** What is playing right now, shown on the phone remote. Null when nothing is. */
export const nowPlaying = new NowPlaying();

class RemoteSearch extends Notifier {
  text = '';

  send(text: string): void {
    this.text = text;
    this.notify();
  }
}

/** Text typed on the phone remote with no text field focused: the open playlist searches it. */
export const remoteSearch = new RemoteSearch();
