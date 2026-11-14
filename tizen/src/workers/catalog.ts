// Parses big provider answers off the page's thread, as the Flutter app does in an isolate
// (app/lib/data/xtream.dart _read, app/lib/data/m3u.dart _read, app/lib/data/catalog.dart
// _versionKeys): an Xtream list of tens of MB read item by item and indexed, an M3U playlist read,
// the version keys of a big catalog worked out. The page waits for the answer without freezing.
//
// Messages in: {id, op: 'listing', kind, text} | {id, op: 'm3u', text} | {id, op: 'keys', names} |
// {id, op: 'series', base, text} (a series' record, out as {id, detail}).
// Out: {id, listing} | {id, entries, guideUrls} | {id, keys}, or {id, error} ('badResponse' when the
// text is not JSON). On the way, {id, progress: [items, share]} says how far a list has been read.
import { jsonItems } from '../data/json_items';
import { buildListing, FROM_JSON, ListKind } from '../data/listing';
import { m3uGuideUrls, parseM3u } from '../data/m3u_parse';
import { Series, seriesDetailFromJson, setUntitledName } from '../data/models';
import { afterPhpNotice } from '../data/json_items';
import { versionKey } from '../data/titles';

const post = (m: unknown) => (self as unknown as Worker).postMessage(m);

self.onmessage = (e: MessageEvent) => {
  const m = e.data as { id: number; op: string; kind?: ListKind; text?: string; names?: [string, number | undefined][][]; untitled?: string; base?: Series };
  if (m.untitled) setUntitledName(m.untitled); // in the app's language
  try {
    switch (m.op) {
      case 'listing': {
        const text = m.text || '';
        const place = { at: 0 };
        const tell = (items: number) => post({ id: m.id, progress: [items, place.at / text.length] });
        let listing: unknown;
        try {
          listing = buildListing(jsonItems(text, place), FROM_JSON[m.kind || 'category'] as (j: Record<string, unknown>) => unknown, tell);
        } catch (error) {
          post({ id: m.id, error: error instanceof SyntaxError ? 'badResponse' : String(error) });
          return;
        }
        post({ id: m.id, listing });
        return;
      }
      case 'm3u': {
        const tell = (entries: number, share: number) => post({ id: m.id, progress: [entries, share] });
        post({ id: m.id, entries: parseM3u(m.text || '', tell), guideUrls: m3uGuideUrls(m.text || '') });
        return;
      }
      case 'series': {
        // A series' record (xtream.ts seriesDetail): {id, detail} or {id, error}
        const text = m.text || '';
        let j: unknown;
        try {
          j = JSON.parse(text.slice(afterPhpNotice(text) || 0));
        } catch {
          post({ id: m.id, error: 'badResponse' });
          return;
        }
        // Some panels answer [] for a series they no longer have
        if (!j || typeof j !== 'object' || Array.isArray(j)) {
          post({ id: m.id, error: 'notFound' });
          return;
        }
        post({ id: m.id, detail: seriesDetailFromJson(m.base as Series, j as Record<string, unknown>) });
        return;
      }
      case 'keys':
        post({ id: m.id, keys: (m.names || []).map((list) => list.map(([name, year]) => versionKey(name, year))) });
        return;
      default:
        post({ id: m.id, error: `unknown op ${m.op}` });
    }
  } catch (error) {
    post({ id: m.id, error: String(error) });
  }
};
