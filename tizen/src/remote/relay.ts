// The sync server's phone bridge (server: /v1/relay), for a TV app that cannot listen on a port:
// a room whose id is the only way in, where the phone posts to "tv" and this TV to "phone", each
// reading the other's messages by long polling. The server only carries what the companion seal
// sealed: it cannot read any of it.
import { log } from '../log';

export interface Room {
  room: string;
  secret: string;
}

/**
 * The answer at [url], its body read within [timeoutMs] too: a server that sends its headers and
 * then nothing gives up as one that sends nothing does.
 */
async function call(url: string, init: RequestInit = {}, timeoutMs = 30000): Promise<{ status: number; text: string }> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  try {
    const res = await fetch(url, { ...init, signal: abort.signal });
    return { status: res.status, text: await res.text() };
  } finally {
    clearTimeout(timer);
  }
}

export class RelayRoom {
  private after = 0;
  private open = true;

  private constructor(readonly server: string, readonly room: Room) {}

  /** A new room on [server]; throws when the server cannot make one. */
  static async create(server: string): Promise<RelayRoom> {
    const res = await call(`${server}/v1/relay`, { method: 'POST' });
    if (res.status !== 201) throw new Error(`relay ${res.status}`);
    return new RelayRoom(server, JSON.parse(res.text) as Room);
  }

  /** Posts [body] (sealed) to the phones. */
  async toPhone(body: string): Promise<void> {
    const res = await call(`${this.server}/v1/relay/${this.room.room}/phone`, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body });
    if (res.status !== 200) throw new Error(`relay ${res.status}`);
  }

  /**
   * Hands each message the phones post to [onMessage], until [close]. A gone room (expired, the
   * server restarted) ends it and calls [onGone].
   */
  async listen(onMessage: (body: string) => void, onGone: () => void): Promise<void> {
    let failures = 0;
    while (this.open) {
      try {
        // The server answers within 25 s; a little more before giving up on it
        const res = await call(`${this.server}/v1/relay/${this.room.room}/tv?after=${this.after}`, {}, 35000);
        if (res.status === 404) {
          this.open = false;
          onGone();
          return;
        }
        if (res.status !== 200) throw new Error(`relay ${res.status}`);
        const j = JSON.parse(res.text) as { messages: { seq: number; body: string }[]; next: number };
        this.after = j.next;
        failures = 0;
        for (const m of j.messages) {
          try {
            onMessage(m.body);
          } catch (e) {
            log(`relay: ${(e as Error).message}`);
          }
        }
      } catch (e) {
        if (!this.open) return;
        // The network hiccuped: try again, more slowly each time
        failures++;
        log(`relay: ${(e as Error).message}`);
        await new Promise((ok) => setTimeout(ok, Math.min(30000, 1000 * failures)));
      }
    }
  }

  /** Ends the room: the server forgets it and every message in it. */
  close(): void {
    if (!this.open) return;
    this.open = false;
    call(`${this.server}/v1/relay/${this.room.room}`, { method: 'DELETE', headers: { 'X-Relay-Secret': this.room.secret } }).catch(() => {});
  }
}
