// Recommendations for each profile from a language model (app/lib/data/recommender.dart): the one
// set up on this TV in Settings; else the one the account's sync server offers, which keeps its
// key; else the one built into the app. Turned off in Settings, none of them. It reads the titles
// the profile watched and keeps in its list, and picks from the provider's catalog what that
// person has not seen, saying why. It can only pick from the titles it is given, so it never
// suggests something the provider lacks. Only titles go out: no credentials, no addresses,
// nothing about the TV. Kids profiles do not use it.
//
// Answers are kept per playlist and profile, and asked again after MAX_AGE, or sooner when the
// profile watched something new. Where the Flutter app keeps the service's key in the system's
// secure storage, a web app has no keystore: it lives in localStorage, as the sync account does.
import { BUILT_IN_AI } from '../config';
import { log } from '../log';
import { syncService } from '../sync/service';
import { Notifier } from '../ui/components';
import { CatalogData } from './catalog';
import { Library, MediaRef, watchedFor } from './library';
import { bareTitle } from './matching';
import { Movie, Series } from './models';
import { stableHash } from './source';
import { trending } from './trending';

export interface ChatMessage {
  role: string;
  content: string;
}

/** busy: out of quota or down for now (429, 5xx); service: anything else, its detail the status when there was one. */
export type AiProblem = 'key' | 'model' | 'busy' | 'service';

export class AiException extends Error {
  constructor(readonly problem: AiProblem, readonly detail = '') {
    super(`AiException(${problem}${detail ? `: ${detail}` : ''})`);
  }
}

type Via = (messages: ChatMessage[], json: boolean) => Promise<string>;

/**
 * A language model the app asks for recommendations, through the OpenAI chat completions API
 * that most services and servers speak (Ollama, OpenAI, OpenRouter, vLLM, LM Studio...).
 */
export class AiService {
  static readonly defaultUrl = 'https://ollama.com/v1';

  /** [baseUrl] goes up to the API version, such as "https://ollama.com/v1"; [apiKey] is empty for servers that need none. */
  constructor(readonly baseUrl: string, readonly model: string, readonly apiKey = '', private readonly via: Via | null = null) {}

  /** A service reached through [via], such as the account's sync server, which keeps the key. */
  static through(via: Via, model: string, baseUrl: string): AiService {
    return new AiService(baseUrl, model, '', via);
  }

  /** Reached through the account's sync server. */
  get viaServer(): boolean {
    return this.via !== null;
  }

  /** The model's answer to [messages]; asks for JSON when [json]. Throws an AiException. */
  async chat(messages: ChatMessage[], json = false): Promise<string> {
    if (this.via) {
      try {
        return await this.via(messages, json);
      } catch (e) {
        if (e instanceof AiException) throw e;
        throw new AiException('service', String(e));
      }
    }
    try {
      let res = await this.send(messages, json);
      // Servers that do not know response_format: the prompt asks for JSON anyway
      if (json && res.status === 400) res = await this.send(messages, false);
      // Models that take only their own temperature (some reasoning ones)
      if (res.status === 400) res = await this.send(messages, false, false);
      if (res.status === 401 || res.status === 403) throw new AiException('key');
      if (res.status === 404) throw new AiException('model');
      if (res.status === 429 || res.status >= 500) throw new AiException('busy', String(res.status));
      if (res.status !== 200) throw new AiException('service', String(res.status));
      const j = JSON.parse(res.text) as { choices: { message: { content?: string | null } }[] };
      return j.choices[0].message.content || '';
    } catch (e) {
      if (e instanceof AiException) throw e;
      throw new AiException('service', String(e));
    }
  }

  /** The status and text of one ask; the whole answer within the time, not just its headers. */
  private async send(messages: ChatMessage[], jsonFormat: boolean, temperature = true): Promise<{ status: number; text: string }> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.apiKey) headers.Authorization = `Bearer ${this.apiKey}`;
    const body: Record<string, unknown> = { model: this.model, messages };
    if (temperature) body.temperature = 0.7;
    if (jsonFormat) body.response_format = { type: 'json_object' };
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), 90000); // large models in the cloud take their time
    try {
      const res = await fetch(`${this.baseUrl.replace(/\/+$/, '')}/chat/completions`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: abort.signal,
      });
      return { status: res.status, text: await res.text() };
    } finally {
      clearTimeout(timer);
    }
  }
}

/** A title picked for someone, with why in a few words. */
export interface Pick {
  item: Movie | Series; // of the playlist
  why: string;
}

/** What a profile watched (newest first, a series once) and keeps in its list, and a hash of both. */
export interface Taste {
  watched: string[];
  listed: string[];
  /** Every title watched or listed, not only the latest the prompt takes: none is offered as new. */
  known: string[];
  hash: string;
}

const MAX_AGE = 12 * 60 * 60 * 1000;
const MIN_AGE = 30 * 60 * 1000; // between asks when only the taste changed
const PICKS = 12;

const OFF = 'ai.off';
const URL_KEY = 'ai.baseUrl';
const MODEL_KEY = 'ai.model';
const API_KEY = 'ai.apiKey';
const PICKS_PREFIX = 'ai.picks.';

const isMovie = (x: Movie | Series): x is Movie => 'extension' in x;

function read(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function write(key: string, value: string | null): void {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    // Storage full or blocked: kept in memory until the app closes
  }
}

class Recommender extends Notifier {
  private own: AiService | null = null;
  private server: AiService | null = null;
  private serverKey = '';
  private _off = false;
  private _service: AiService | null = null;
  /** Answers being asked for, by playlist and profile: Home coming back does not ask twice. */
  private asking: Record<string, { s: AiService; picks: Promise<Pick[] | null> }> = {};

  /** The service built into the app (see config.ts); null when there is none. */
  readonly builtIn: AiService | null = BUILT_IN_AI.model
    ? new AiService(BUILT_IN_AI.baseUrl || AiService.defaultUrl, BUILT_IN_AI.model, BUILT_IN_AI.apiKey)
    : null;

  constructor() {
    super();
    this.load();
    // The sync server's model, for TVs without one of their own; the key stays there
    syncService.listen(() => this.serverChanged());
    this.serverChanged();
  }

  /** The service in use; null when there is none or recommendations are off. */
  get service(): AiService | null {
    return this._service;
  }

  /** Turned off in Settings. */
  get off(): boolean {
    return this._off;
  }

  /** Whether there is a service to turn back on without setting one up. */
  get canTurnOn(): boolean {
    return !!(this.own || this.server || this.builtIn);
  }

  /** Whether the service in use is the one built into the app. */
  get usingBuiltIn(): boolean {
    return this._service !== null && this._service === this.builtIn;
  }

  /** Whether the service in use is this TV's own, set up in Settings. */
  get usingOwn(): boolean {
    return this._service !== null && this._service === this.own;
  }

  /** Reads the service set up on this TV and whether recommendations were turned off. */
  private load(): void {
    this._off = read(OFF) === 'true';
    const url = read(URL_KEY);
    const model = read(MODEL_KEY);
    this.own = url !== null && model !== null ? new AiService(url, model, read(API_KEY) || '') : null;
    this.choose();
  }

  private choose(): void {
    const before = this._service;
    const wasOff = this._off;
    this._service = this._off ? null : this.own || this.server || this.builtIn;
    if (this._service !== before || this._off !== wasOff) this.notify();
  }

  /** Follows the model the account's server offers (SyncService.aiModel), asked through the server. */
  private serverChanged(): void {
    const model = syncService.aiModel;
    let host = '';
    try {
      host = syncService.server ? new URL(syncService.server).hostname : '';
    } catch {
      // Not an address: no host to show
    }
    const key = model ? `${model}@${host}` : '';
    if (key === this.serverKey) return; // sync told of something else
    this.serverKey = key;
    this.server = model ? AiService.through((messages, json) => syncService.aiChat(messages, json), model, host) : null;
    this.choose();
  }

  /**
   * Sets up [s] as this TV's own service; null forgets it, for the server's or the built-in one.
   * The recommendations of the one before are forgotten.
   */
  configure(s: AiService | null): void {
    write(URL_KEY, s ? s.baseUrl : null);
    write(MODEL_KEY, s ? s.model : null);
    write(API_KEY, s ? s.apiKey : null);
    this.forgetPicks();
    this.own = s;
    this._off = false;
    write(OFF, 'false');
    this.choose();
  }

  /** Turns recommendations off ([on] false) or back on, whatever the service. */
  turn(on: boolean): void {
    write(OFF, on ? 'false' : 'true');
    if (!on) this.forgetPicks();
    this._off = !on;
    this.choose();
  }

  private forgetPicks(): void {
    try {
      const keys: string[] = [];
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k && k.indexOf(PICKS_PREFIX) === 0) keys.push(k);
      }
      keys.forEach((k) => localStorage.removeItem(k));
    } catch {
      // Nothing kept, then
    }
    this.asking = {};
  }

  /** Checks that [s] answers, before it is set up. Throws an AiException. */
  test(s: AiService): Promise<string> {
    return s.chat([{ role: 'user', content: 'Reply with the word OK.' }]);
  }

  /** The picks kept for [library]'s playlist and profile, found again in [data]; empty when there are none. Quick: for Home to show at once. */
  kept(library: Library, data: CatalogData): Pick[] {
    const saved = this.saved(library);
    return saved && Array.isArray(saved.picks) ? resolve(saved.picks, data) : [];
  }

  /**
   * Fresh picks when the kept ones are old or the taste changed, else null (nothing to change).
   * [language] is the one of the reasons, such as "Spanish". Rejects with an AiException.
   */
  refresh(library: Library, data: CatalogData, language: string, now = Date.now()): Promise<Pick[] | null> {
    const s = this._service;
    if (!s) return Promise.resolve(null);
    const key = keyOf(library);
    const running = this.asking[key];
    if (running && running.s === s) return running.picks;
    const picks = this.ask(s, library, data, language, now);
    const asking = { s, picks };
    this.asking[key] = asking;
    const done = () => {
      if (this.asking[key] === asking) delete this.asking[key];
    };
    picks.then(done, done);
    return picks;
  }

  private async ask(s: AiService, library: Library, data: CatalogData, language: string, now: number): Promise<Pick[] | null> {
    const taste = tasteOf(library);
    if (!taste.watched.length && !taste.listed.length) return null; // nothing to go on yet
    const saved = this.saved(library);
    const at = saved && typeof saved.at === 'string' ? Date.parse(saved.at) : NaN;
    const age = isNaN(at) || at > now ? null : now - at; // from the future: asked again
    const sameTaste = !!saved && saved.taste === taste.hash;
    if (age !== null && age < MAX_AGE && (sameTaste || age < MIN_AGE)) return null;

    const candidates = candidatesFor(data, taste);
    if (!candidates.length) return null;
    const answer = await s.chat(prompt(taste, candidates, language), true);
    const picks = parse(answer, candidates);
    if (!picks.length) throw new AiException('service', 'no picks in the answer');
    if (s !== this._service) return null; // set up anew meanwhile: these belong to the one before
    write(
      keyOf(library),
      JSON.stringify({
        at: new Date(now).toISOString(),
        taste: taste.hash,
        picks: picks.map((p) => ({ kind: isMovie(p.item) ? 'movie' : 'series', id: p.item.id, why: p.why })),
      }),
    );
    return picks;
  }

  private saved(library: Library): { at?: unknown; taste?: unknown; picks?: unknown } | null {
    // Picks from before the history was cleared say what was watched: never shown again
    const kept = this.read(library);
    const at = kept && typeof kept.at === 'string' ? Date.parse(kept.at) : NaN;
    if (kept && at < library.clearedAt) {
      try {
        localStorage.removeItem(PICKS_PREFIX + library.playlistId + '.' + library.profileId);
      } catch {
        // Not shown either way
      }
      return null;
    }
    return kept;
  }

  private read(library: Library): { at?: unknown; taste?: unknown; picks?: unknown } | null {
    const raw = read(keyOf(library));
    if (raw === null) return null;
    try {
      const j = JSON.parse(raw);
      return j && typeof j === 'object' ? j : null;
    } catch {
      log('recommendations: kept picks that do not read');
      return null;
    }
  }
}

const keyOf = (l: Library) => `${PICKS_PREFIX}${l.playlistId}.${l.profileId}`;

/** What a profile watched (newest first, a series once) and keeps in its list. */
export function tasteOf(library: Library): Taste {
  const described = (r: MediaRef) => `${r.kind === 'episode' && r.seriesTitle != null ? r.seriesTitle : r.title}${r.year == null ? '' : ` (${r.year})`}`;
  const once = (all: string[], max: number) => all.filter((x, i) => all.indexOf(x) === i).slice(0, max);
  const allWatched = library.history.filter(watchedFor).map((h) => described(h.ref));
  const allListed = library.favorites('movie').concat(library.favorites('series')).map(described);
  const watched = once(allWatched, 25);
  const listed = once(allListed, 15);
  return { watched, listed, known: allWatched.concat(allListed), hash: stableHash(watched.concat(['|'], listed).join('\n')) };
}

/** Titles to pick from: trending this week, best rated and new, movies and series, that the profile has not watched nor listed. */
export function candidatesFor(data: CatalogData, taste: Taste): (Movie | Series)[] {
  const known: Record<string, true> = {};
  for (const t of taste.known) known[bareTitle(t)] = true;
  const seen = new Set<Movie | Series>();
  const all = trending.available(data).map((x): Movie | Series => x.item).concat(
    data.topMovies.slice(0, 60),
    data.topSeries.slice(0, 40),
    data.newReleases.slice(0, 30),
    data.recentSeries.slice(0, 30),
  );
  const out: (Movie | Series)[] = [];
  for (const x of all) {
    if (out.length >= 150) break;
    // Another copy of one watched is no new title: its tags and language do not count
    if (known[bareTitle(x.name)] || seen.has(x)) continue;
    seen.add(x);
    out.push(x);
  }
  return out;
}

export function prompt(taste: Taste, candidates: (Movie | Series)[], language: string): ChatMessage[] {
  const line = (i: number, x: Movie | Series) =>
    `c${i} | ${isMovie(x) ? 'movie' : 'series'} | ${x.name}${x.year == null ? '' : ` (${x.year})`}${x.genre == null ? '' : ` | ${x.genre}`}`;
  const user = ['Watched, newest first:'].concat(taste.watched.map((t) => `- ${t}`));
  if (taste.listed.length) user.push('', 'In their list:', ...taste.listed.map((t) => `- ${t}`));
  user.push('', 'Candidates:', ...candidates.map((x, i) => line(i, x)));
  return [
    {
      role: 'system',
      content:
        'You recommend movies and series to one member of a family, from what their IPTV ' +
        `provider offers. Pick only from the candidates, by their code. Choose ${PICKS} that ` +
        'this person is likely to enjoy given what they watched and keep in their list, best ' +
        `first, mixing movies and series when both fit. For each, write why in ${language}, in ` +
        'at most 12 words, naming something they watched when that explains it. Answer only ' +
        'with JSON: {"picks":[{"id":"c3","why":"..."}]}',
    },
    { role: 'user', content: user.join('\n') },
  ];
}

/** The picks in a model's [answer], in its order: only known codes, each once. Tolerates text, reasoning or code fences around the JSON. */
export function parse(answer: string, candidates: (Movie | Series)[]): Pick[] {
  const text = answer.replace(/<think>[\s\S]*?<\/think>/g, '');
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return [];
  let picks: unknown;
  try {
    picks = (JSON.parse(text.slice(start, end + 1)) as Record<string, unknown>).picks;
  } catch {
    return [];
  }
  if (!Array.isArray(picks)) return [];
  const seen: Record<number, true> = {};
  const out: Pick[] = [];
  for (const p of picks) {
    if (!p || typeof p !== 'object' || Array.isArray(p)) continue;
    const code = String((p as Record<string, unknown>).id).replace(/^c/, '').trim();
    if (!/^[+-]?\d+$/.test(code)) continue;
    const i = parseInt(code, 10);
    if (i < 0 || i >= candidates.length || seen[i]) continue;
    seen[i] = true;
    const why = (p as Record<string, unknown>).why;
    out.push({ item: candidates[i], why: (why == null ? '' : String(why)).trim() });
  }
  return out.slice(0, PICKS);
}

/** Saved picks found again in the catalog, by id. */
function resolve(saved: unknown[], data: CatalogData): Pick[] {
  const movies = new Map<string, Movie>();
  const series = new Map<string, Series>();
  for (const m of data.movies) movies.set(m.id, m);
  for (const s of data.series) series.set(s.id, s);
  const out: Pick[] = [];
  for (const p of saved) {
    if (!p || typeof p !== 'object') continue;
    const j = p as Record<string, unknown>;
    const item = j.kind === 'series' ? series.get(String(j.id)) : movies.get(String(j.id));
    if (item) out.push({ item, why: j.why == null ? '' : String(j.why) });
  }
  return out;
}

export const recommender = new Recommender();
