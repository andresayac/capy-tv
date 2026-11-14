// The page's side of the parsing worker (src/workers/catalog.ts): big answers are parsed there so
// the spinner keeps turning and the remote keeps working, as the Flutter app parses them in an
// isolate. Where the worker cannot run (it failed to load, or died) the caller parses them here
// instead, as before: slower to the eye, the same result.
import { log } from '../log';
import { untitledName } from './models';

/** What is worth the trip: Flutter's threshold for its isolates (app/lib/data/xtream.dart). */
export const BIG = 256 * 1024;

/** A parse taking this long means the worker is gone. */
const STUCK = 3 * 60 * 1000;

interface Job {
  done: (reply: Record<string, unknown>) => void;
  fail: (e: Error) => void;
  progress?: (items: number, share: number) => void;
  timer: number;
}

let worker: Worker | null = null;
let broken = false;
let nextJob = 1;
const jobs: Record<number, Job> = {};

function lose(reason: string): void {
  log(`catalog worker: ${reason}`);
  broken = true; // the rest of the session parses here
  if (worker) worker.terminate();
  worker = null;
  for (const id of Object.keys(jobs)) {
    const job = jobs[Number(id)];
    delete jobs[Number(id)];
    clearTimeout(job.timer);
    job.fail(new Error(reason));
  }
}

function theWorker(): Worker {
  if (worker) return worker;
  const w = new Worker('catalog-worker.js');
  w.onmessage = (e: MessageEvent) => {
    const reply = e.data as Record<string, unknown> & { id: number; progress?: [number, number] };
    const job = jobs[reply.id];
    if (!job) return;
    if (reply.progress) {
      // It goes on: not stuck
      clearTimeout(job.timer);
      job.timer = window.setTimeout(() => lose('no answer'), STUCK);
      if (job.progress) job.progress(reply.progress[0], reply.progress[1]);
      return;
    }
    delete jobs[reply.id];
    clearTimeout(job.timer);
    job.done(reply);
  };
  w.onerror = (e: ErrorEvent) => {
    e.preventDefault();
    lose(e.message || 'failed to load');
  };
  w.onmessageerror = () => lose('unreadable answer');
  return (worker = w);
}

/**
 * Sends [message] to the worker and resolves with its reply ({error} included). Rejects only when
 * the worker cannot do it, and then the caller does it itself. [progress] hears how far it got.
 */
export function offThread<T>(message: Record<string, unknown>, progress?: (items: number, share: number) => void): Promise<T & { error?: string }> {
  if (broken) return Promise.reject(new Error('no worker'));
  return new Promise((resolve, reject) => {
    try {
      const w = theWorker();
      const id = nextJob++;
      jobs[id] = {
        done: resolve as (reply: Record<string, unknown>) => void,
        fail: reject,
        progress,
        timer: window.setTimeout(() => lose('no answer'), STUCK),
      };
      w.postMessage({ ...message, id, untitled: untitledName }); // the worker has no strings of its own
    } catch (e) {
      broken = true;
      reject(e);
    }
  });
}
