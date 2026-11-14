// Parses an XMLTV guide off the page's thread while it downloads (app/lib/data/epg.dart
// parseXmltv and _readGuide), keeping only programmes that overlap the window around now: 3 days
// back for catch-up, 2 days ahead. The page streams the body in as it arrives; .xml.gz files are
// un-gzipped on the way (magic bytes 1f 8b, whatever the URL or Content-Type says), the text is
// UTF-8 with bad bytes replaced, and a scanner (not a DOM) picks out <channel> and <programme>
// elements, so memory stays proportional to the window, not to the document (often hundreds of MB).
// The guide's names for its channels (<display-name>) are kept too, as guideName makes them: by them
// the page finds a playlist's channel whose id the guide does not have.
//
// Messages in: {id, op: 'start', now, lang} | {id, op: 'chunk', bytes} | {id, op: 'end'} | {id, op: 'cancel'}.
// Out: {id, ack: true} once a chunk is done (the page sends a few ahead, no more), then the guide
// as {id, parts} (JSON of a few hundred kB each, see src/data/epg.ts), or {id, error}.
import { Gunzip } from 'fflate';
import { guideName } from '../data/titles';

const PAST = 3 * 24 * 60 * 60 * 1000;
const AHEAD = 2 * 24 * 60 * 60 * 1000;
/** Roughly how much JSON goes in each part sent back: the page parses one per task. */
const PART = 256 * 1024;
/** Text an element may take before it is taken as broken; real ones are a few kB. */
const LONGEST = 1024 * 1024;

const key = (id: string) => id.trim().toLowerCase();

/** "20261105203000 -0500" → ms since the epoch. A missing offset means UTC. */
function parseTime(raw: string): number | null {
  const m = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?\s*([+-])?(\d{2})?:?(\d{2})?/.exec(raw.trim());
  if (!m) return null;
  const n = (i: number) => parseInt(m[i] || '0', 10);
  let utc = Date.UTC(n(1), n(2) - 1, n(3), n(4), n(5), n(6));
  if (m[7]) {
    const offset = (n(8) * 60 + n(9)) * 60000;
    utc = m[7] === '+' ? utc - offset : utc + offset;
  }
  return utc;
}

const attrs: Record<string, RegExp> = {};

function attr(tag: string, name: string): string | undefined {
  const re = attrs[name] || (attrs[name] = new RegExp(`\\s${name}\\s*=\\s*("([^"]*)"|'([^']*)')`));
  const m = re.exec(tag);
  return m ? decode(m[2] !== undefined ? m[2] : m[3]) : undefined;
}

/** The XML entities and character references; anything else stays as written, as in Flutter's parser. */
function decode(s: string): string {
  if (s.indexOf('&') < 0) return s;
  return s.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (whole: string, e: string) => {
    const l = e.toLowerCase();
    if (l === 'amp') return '&';
    if (l === 'lt') return '<';
    if (l === 'gt') return '>';
    if (l === 'quot') return '"';
    if (l === 'apos') return "'";
    const n = l[1] === 'x' ? parseInt(l.slice(2), 16) : parseInt(l.slice(1), 10);
    // Above U+FFFF (emoji) needs a surrogate pair
    return n >= 0 && n <= 0x10ffff ? String.fromCodePoint(n) : whole;
  });
}

/** Element text: entities decoded, CDATA kept as it is. */
function text(raw: string): string {
  let out = '';
  let i = 0;
  for (;;) {
    const s = raw.indexOf('<![CDATA[', i);
    if (s < 0) return out + decode(raw.slice(i));
    out += decode(raw.slice(i, s));
    const e = raw.indexOf(']]>', s + 9);
    if (e < 0) return out + raw.slice(s + 9);
    out += raw.slice(s + 9, e);
    i = e + 3;
  }
}

const opening: Record<string, RegExp> = {
  title: /<title(?=[\s/>])[^>]*>/g,
  desc: /<desc(?=[\s/>])[^>]*>/g,
  icon: /<icon(?=[\s/>])[^>]*>/g,
  'display-name': /<display-name(?=[\s/>])[^>]*>/g,
};

/** The texts of every <name> in [body]. */
function texts(body: string, name: 'display-name'): string[] {
  const re = opening[name];
  re.lastIndex = 0;
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(body))) {
    if (m[0][m[0].length - 2] === '/') continue;
    const start = m.index + m[0].length;
    const end = body.indexOf(`</${name}`, start);
    if (end < 0) break;
    out.push(text(body.slice(start, end)).trim());
  }
  return out;
}

/**
 * The text of the <name> in [body] in [lang] (lang="es", "es-CO"), or else of the first that has
 * any: an empty <title/> is skipped for the next one, an empty <title></title> counts.
 */
function firstText(body: string, name: 'title' | 'desc', lang?: string): string | undefined {
  const re = opening[name];
  re.lastIndex = 0;
  let first: string | undefined;
  let m: RegExpExecArray | null;
  while ((m = re.exec(body))) {
    if (m[0][m[0].length - 2] === '/') continue;
    const start = m.index + m[0].length;
    const end = body.indexOf(`</${name}`, start);
    if (end < 0) break;
    const found = text(body.slice(start, end)).trim();
    if (!lang) return found;
    if (first === undefined) first = found;
    if ((attr(m[0], 'lang') || '').toLowerCase().indexOf(lang) === 0) return found;
  }
  return first;
}

const withoutComments = (s: string) => (s.indexOf('<!--') < 0 ? s : s.replace(/<!--[\s\S]*?-->/g, ''));

type Programme = [number, number, string, string];

/** Fed the text as it comes, it keeps the programmes in the window and the channels' logos. */
class Scanner {
  private buf = '';
  private readonly from: number;
  private readonly to: number;
  readonly programmes: Record<string, Programme[]> = {};
  /** The programmes that came with no stop (XMLTV allows it), given an hour until the next is known. */
  private readonly openEnded = new Set<Programme>();
  readonly icons: Record<string, string> = {};
  /** The guide's channels in its order, each [id, its names as guideName makes them]. */
  private readonly named: string[][] = [];
  /** Whether the document's end (</tv>) came: one cut short is not kept. */
  complete = false;

  /** The language ("es") whose title and description are taken when a programme has several. */
  private readonly lang?: string;

  constructor(now: number, lang?: string) {
    this.from = now - PAST;
    this.to = now + AHEAD;
    this.lang = lang && lang.toLowerCase();
  }

  push(chunk: string, final = false): void {
    this.buf += chunk;
    const done = this.scan(final);
    this.buf = final ? '' : this.buf.slice(done);
  }

  /** Reads every complete element in the buffer; returns where the first incomplete one starts. */
  private scan(final: boolean): number {
    const b = this.buf;
    let i = 0;
    for (;;) {
      const lt = b.indexOf('<', i);
      if (lt < 0) return b.length;
      // Too little to tell what it is yet
      if (!final && b.length - lt < 12) return lt;
      let end: number;
      if (b.substr(lt, 4) === '<!--') {
        end = b.indexOf('-->', lt + 4);
        if (end < 0) return final ? b.length : lt;
        i = end + 3;
        continue;
      }
      if (b.substr(lt, 9) === '<![CDATA[') {
        end = b.indexOf(']]>', lt + 9);
        if (end < 0) return final ? b.length : lt;
        i = end + 3;
        continue;
      }
      const element = this.element(b, lt, final);
      if (element === null) return final ? b.length : lt;
      i = element;
    }
  }

  /**
   * Past the element that starts at [lt] (or past its tag when it is not one that matters, or is
   * never closed); null if it may still be completed by what comes.
   */
  private element(b: string, lt: number, final: boolean): number | null {
    const headEnd = b.indexOf('>', lt);
    if (headEnd < 0) return null;
    const name = /^<(programme|channel)[\s/>]/.exec(b.substr(lt, 12));
    if (!name) {
      if (/^<\/tv[\s>]/.test(b.substr(lt, 5))) this.complete = true;
      return headEnd + 1; // <?xml>, <tv>, </tv>, <!DOCTYPE>...
    }
    const head = b.slice(lt + name[1].length + 1, headEnd);
    if (head[head.length - 1] === '/') return headEnd + 1; // nothing in it
    const close = b.indexOf(`</${name[1]}`, headEnd);
    // One never closed would hold back the rest of the document: past LONGEST, or at the end,
    // its tag is skipped and what is inside it still read
    if (close < 0) return final || b.length - lt > LONGEST ? headEnd + 1 : null;
    // Another one opening before this one closes: this one was never closed, and does not take
    // the next one's end for its own
    const nested = b.indexOf(`<${name[1]}`, headEnd);
    if (nested >= 0 && nested < close) return headEnd + 1;
    const after = b.indexOf('>', close);
    if (after < 0) return null;
    const body = withoutComments(b.slice(headEnd + 1, close));
    if (name[1] === 'programme') this.programme(' ' + head, body);
    else this.channel(' ' + head, body);
    return after + 1;
  }

  private programme(head: string, body: string): void {
    const channel = attr(head, 'channel');
    const start = parseTime(attr(head, 'start') || '');
    if (!channel || start === null) return;
    // XMLTV's stop is optional: an hour until the next programme says where it ends
    const given = parseTime(attr(head, 'stop') || '');
    const stop = given === null ? start + 3600000 : given;
    if (stop <= this.from || start >= this.to) return;
    const title = firstText(body, 'title', this.lang);
    if (title === undefined) return;
    const desc = firstText(body, 'desc', this.lang) || '';
    const k = key(channel);
    const entry: Programme = [start, stop, title, desc];
    (this.programmes[k] || (this.programmes[k] = [])).push(entry);
    if (given === null) this.openEnded.add(entry);
  }

  /**
   * A channel of the guide: its names, and its logo (the first with an http address, past any
   * relative or data: one before it).
   */
  private channel(head: string, body: string): void {
    const id = attr(head, 'id');
    if (!id) return;
    const names = [key(id)];
    for (const raw of texts(body, 'display-name')) {
      const n = guideName(raw);
      if (n && names.indexOf(n, 1) < 0) names.push(n);
    }
    this.named.push(names);
    if (this.icons[key(id)]) return;
    const re = opening.icon;
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(body))) {
      const src = attr(m[0], 'src');
      if (src && src.indexOf('http') === 0) {
        this.icons[key(id)] = src;
        return;
      }
    }
  }

  /**
   * The guide as parts of JSON, {"p": {channel: programmes}, "i": {channel: logo}} and
   * {"n": [[channel, names…], …]}. There is always an "n" part, even an empty one: a copy kept
   * without any comes from before the names were kept.
   */
  parts(): string[] {
    const out: string[] = [];
    let part: string[] = [];
    let size = 0;
    const flush = (kind: 'p' | 'i' | 'n') => {
      if (part.length) out.push(kind === 'n' ? `{"n":[${part.join(',')}]}` : `{"${kind}":{${part.join(',')}}}`);
      part = [];
      size = 0;
    };
    for (const k of Object.keys(this.programmes)) {
      const list = this.programmes[k].sort((a, b) => a[0] - b[0]);
      // One with no stop ends where the next one starts; the last keeps its hour
      for (let i = 0; i < list.length - 1; i++) {
        if (this.openEnded.has(list[i]) && list[i + 1][0] > list[i][0]) list[i][1] = list[i + 1][0];
      }
      // A guide mixing sources repeats or overlaps programmes: each once, one ending where the
      // next starts, so none is drawn over another in the grid
      const kept: Programme[] = [];
      for (const e of list) {
        const prev = kept[kept.length - 1];
        if (prev && e[0] < prev[1]) {
          if (e[0] <= prev[0]) continue; // the same slot: the first stays
          prev[1] = e[0];
        }
        kept.push(e);
      }
      const json = `${JSON.stringify(k)}:${JSON.stringify(kept)}`;
      part.push(json);
      size += json.length;
      if (size > PART) flush('p');
    }
    flush('p');
    for (const k of Object.keys(this.icons)) {
      const json = `${JSON.stringify(k)}:${JSON.stringify(this.icons[k])}`;
      part.push(json);
      size += json.length;
      if (size > PART) flush('i');
    }
    flush('i');
    const parts = out.length;
    for (const names of this.named) {
      const json = JSON.stringify(names);
      part.push(json);
      size += json.length;
      if (size > PART) flush('n');
    }
    flush('n');
    if (out.length === parts) out.push('{"n":[]}');
    return out;
  }
}

/** One guide on its way in: raw bytes, then text, then programmes. */
class Job {
  private head: Uint8Array | null = new Uint8Array(0); // until it is known whether it is gzip
  private gunzip: Gunzip | null = null;
  // UTF-8, or Latin-1 for a guide whose declaration says so (encoding="ISO-8859-1")
  private decoder: TextDecoder | null = null;
  private readonly scanner: Scanner;

  constructor(now: number, lang?: string) {
    this.scanner = new Scanner(now, lang);
  }

  push(bytes: Uint8Array): void {
    if (this.head) {
      const joined = new Uint8Array(this.head.length + bytes.length);
      joined.set(this.head);
      joined.set(bytes, this.head.length);
      if (joined.length < 2) {
        this.head = joined;
        return;
      }
      this.head = null;
      this.start(joined);
      bytes = joined;
    }
    if (this.gunzip) this.gunzip.push(bytes);
    else this.text(bytes);
  }

  private start(first: Uint8Array): void {
    if (first[0] !== 0x1f || first[1] !== 0x8b) return;
    this.gunzip = new Gunzip((data) => this.text(data));
  }

  private text(bytes: Uint8Array): void {
    if (!bytes.length) return;
    if (!this.decoder) {
      let head = '';
      for (let i = 0; i < Math.min(200, bytes.length); i++) head += String.fromCharCode(bytes[i]);
      const latin = /encoding\s*=\s*["'](?:iso-8859-1|iso-8859-15|latin-?1|windows-1252|cp1252)/i.test(head);
      this.decoder = new TextDecoder(latin ? 'windows-1252' : 'utf-8');
    }
    this.scanner.push(this.decoder.decode(bytes, { stream: true }));
  }

  /** The guide's parts, and whether its end (</tv>) came. */
  end(): { parts: string[]; complete: boolean } {
    if (this.head && this.head.length) {
      const rest = this.head;
      this.head = null;
      this.text(rest);
    }
    if (this.gunzip) this.gunzip.push(new Uint8Array(0), true);
    this.scanner.push(this.decoder ? this.decoder.decode() : '', true);
    return { parts: this.scanner.parts(), complete: this.scanner.complete };
  }
}

const jobs: Record<number, Job> = {};
const post = (m: unknown) => (self as unknown as Worker).postMessage(m);

self.onmessage = (e: MessageEvent) => {
  const m = e.data as { id: number; op: string; now?: number; lang?: string; bytes?: Uint8Array };
  try {
    switch (m.op) {
      case 'start':
        jobs[m.id] = new Job(m.now || Date.now(), m.lang);
        break;
      case 'chunk':
        if (jobs[m.id] && m.bytes) jobs[m.id].push(m.bytes);
        post({ id: m.id, ack: true });
        break;
      case 'end': {
        const job = jobs[m.id];
        delete jobs[m.id];
        const out = job ? job.end() : { parts: [], complete: false };
        post({ id: m.id, parts: out.parts, complete: out.complete });
        break;
      }
      default:
        delete jobs[m.id];
    }
  } catch (error) {
    // A broken gzip stream, say: this guide fails, the next one starts afresh
    delete jobs[m.id];
    post({ id: m.id, error: String(error) });
  }
};
