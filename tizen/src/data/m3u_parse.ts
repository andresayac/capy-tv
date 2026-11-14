// Reading an M3U playlist (app/lib/data/m3u.dart parseM3u, m3uGuideUrl). Nothing else in here, so
// the parsing worker (src/workers/catalog.ts) can run it on a playlist of tens of MB.

export interface M3uEntry {
  name: string;
  url: string;
  attrs: Record<string, string>; // tvg-id, tvg-name, tvg-logo, group-title, catchup…
  userAgent?: string; // #EXTVLCOPT:http-user-agent=…
}

/**
 * Parses an extended M3U/M3U8 playlist. Tolerates blank lines, a BOM and \r\n line endings. Read a
 * line at a time, so a big one is not in memory as lines too. [each] hears how many entries there
 * are, and how far it has read, every so many of them.
 */
export function parseM3u(text: string, each?: (entries: number, share: number) => void): M3uEntry[] {
  const out: M3uEntry[] = [];
  let name: string | undefined;
  let group: string | undefined; // #EXTGRP, before #EXTINF or after it, kept apart until the address
  let ua: string | undefined;
  let attrs: Record<string, string> = {};
  let described = false; // an #EXTINF came for the next entry
  let header = true; // the first line with something in it is still to come
  let headerShift: string | undefined; // the header's tvg-shift: every channel's that has none of its own
  let told = 0;
  let at = 0;
  while (at < text.length) {
    let end = text.indexOf('\n', at);
    if (end < 0) end = text.length;
    const line = text.slice(at, end).trim(); // the BOM and any \r go here
    at = end + 1;
    if (!line) continue;
    if (header) {
      header = false;
      if (line.slice(0, 7).toUpperCase() === '#EXTM3U') {
        const re = /([\w-]+)\s*=\s*("[^"]*"|'[^']*'|[^\s,"']+)/g;
        let m: RegExpExecArray | null;
        while ((m = re.exec(line))) if (m[1].toLowerCase() === 'tvg-shift') headerShift = unquoted(m[2]);
      }
    }
    const upper = line.slice(0, 12).toUpperCase();
    // An HLS manifest: its lines are its segments or variants, not channels
    if (line.indexOf('#EXT-X-TARGETDURATION') === 0 || line.indexOf('#EXT-X-STREAM-INF') === 0) return [];
    if (upper.indexOf('#EXTINF') === 0) {
      described = true;
      // #EXTINF:-1 tvg-id="x" group-title="y",Channel name, which may contain commas
      const comma = firstCommaOutsideQuotes(line);
      name = comma < 0 ? undefined : line.slice(comma + 1).trim() || undefined;
      const head = comma < 0 ? line : line.slice(0, comma);
      attrs = {};
      const re = /([\w-]+)\s*=\s*("[^"]*"|'[^']*'|[^\s,"']+)/g;
      let m: RegExpExecArray | null;
      // Empty values are none: group-title="" is no group, tvg-logo="" no logo
      while ((m = re.exec(head))) {
        const v = unquoted(m[2]);
        if (v) attrs[m[1].toLowerCase()] = v;
      }
      if (attrs['user-agent'] && !ua) ua = attrs['user-agent'];
    } else if (upper.indexOf('#EXTGRP:') === 0) {
      group = line.slice(8).trim() || group;
    } else if (/^#EXTVLCOPT:http-user-agent=/i.test(line)) {
      ua = unquoted(line.slice(27)) || ua;
    } else if (line[0] !== '#' && (described || streamAddress.test(line))) {
      // Only an entry described, or an address: a web page or "Account expired" sent with a 200
      // would otherwise be a list of channels called <html> and the like.
      // "address|User-Agent=x&Referer=y": the address alone; of what goes with it AVPlay takes only
      // the user agent (Referer, Origin and cookies it cannot send)
      let url = line;
      const bar = line.indexOf('|');
      if (bar > 0) {
        url = line.slice(0, bar);
        for (const pair of line.slice(bar + 1).split('&')) {
          const eq = pair.indexOf('=');
          if (eq > 0 && pair.slice(0, eq).trim().toLowerCase() === 'user-agent') ua = decodeURIComponent(pair.slice(eq + 1).trim());
        }
      }
      if (group && !attrs['group-title']) attrs['group-title'] = group;
      if (headerShift && !attrs['tvg-shift']) attrs['tvg-shift'] = headerShift;
      if (isStreamAddress(url)) out.push({ name: name || attrs['tvg-name'] || url, url, attrs, userAgent: ua });
      name = undefined;
      group = undefined;
      ua = undefined;
      attrs = {};
      described = false;
      if (each && out.length >= told + 1024) {
        told = out.length;
        each(told, at / text.length);
      }
    }
  }
  return out;
}

function unquoted(v: string): string {
  v = v.trim();
  return v.length >= 2 && (v[0] === '"' || v[0] === "'") && v[v.length - 1] === v[0] ? v.slice(1, -1) : v;
}

/** A line that can only be an entry, with no #EXTINF before it: scheme://something. */
const streamAddress = /^[a-z][a-z0-9+.-]*:\/\/\S+$/i;

/**
 * Whether [url] is a stream's: one of the ways streams come, or one with no scheme (relative to the
 * list, as before). A list's line with file:// or the like would have the player open what is on
 * the TV, not a channel.
 */
export function isStreamAddress(url: string): boolean {
  const m = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(url);
  return !m || ['http', 'https', 'rtmp', 'rtmps', 'rtsp', 'udp', 'rtp', 'mms'].indexOf(m[1].toLowerCase()) >= 0;
}

/**
 * Whether [text] holds a playlist, as parseM3u would read it: an entry with its #EXTINF line or a
 * bare stream address, at least. A server's error page or an empty answer is none, and may not take
 * the place of a good copy. Stops at the first entry: a real playlist costs nothing to check.
 */
export function isPlaylist(text: string): boolean {
  let described = false;
  let at = 0;
  while (at < text.length) {
    let end = text.indexOf('\n', at);
    if (end < 0) end = text.length;
    const line = text.slice(at, end).trim();
    at = end + 1;
    if (line.indexOf('#EXTINF') === 0) described = true;
    else if (line && line[0] !== '#' && (described || streamAddress.test(line))) return true;
  }
  return false;
}

/**
 * Counts the entries of a playlist as its bytes go by: lines that are neither blank nor a #
 * comment. To say how many have come while a big one still downloads.
 */
export class M3uEntryCounter {
  count = 0;
  private atStart = true;

  add(piece: Uint8Array): void {
    for (let i = 0; i < piece.length; i++) {
      const b = piece[i];
      if (b === 0x0a || b === 0x0d) {
        this.atStart = true;
      } else if (this.atStart && b !== 0x20 && b !== 0x09 && b !== 0xef && b !== 0xbb && b !== 0xbf) {
        this.atStart = false;
        if (b !== 0x23) this.count++;
      }
    }
  }
}

/**
 * The guides an M3U playlist declares in its header (x-tvg-url, url-tvg or tvg-url), up to three:
 * some list several, by commas or spaces, each with channels the others lack.
 */
export function m3uGuideUrls(text: string): string[] {
  const start = text.slice(0, 64 << 10).replace(/^\uFEFF/, '');
  const header = start.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)[0] || '';
  if (header.toUpperCase().indexOf('#EXTM3U') !== 0) return [];
  const m = /(?:x-tvg-url|url-tvg|tvg-url)\s*=\s*"([^"]+)"/i.exec(header);
  return m ? m[1].split(/[,\s]+/).filter(Boolean).slice(0, 3) : [];
}

/** The first guide an M3U playlist declares, if any. */
export function m3uGuideUrl(text: string): string | undefined {
  return m3uGuideUrls(text)[0];
}

/** The comma before the name, past quoted values: the quote that opened one closes it ("L'Equipe"). */
function firstCommaOutsideQuotes(s: string): number {
  let quote = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (quote) {
      if (c === quote) quote = '';
    } else if (c === '"' || (c === "'" && s[i - 1] === '=')) {
      quote = c;
    } else if (c === ',') {
      return i;
    }
  }
  return -1;
}
