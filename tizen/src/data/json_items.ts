// A panel's JSON lists read and counted item by item (app/lib/data/json_items.dart). Nothing else
// in here, so the parsing worker (src/workers/catalog.ts) can run it on a list of tens of MB.

const QUOTE = 0x22;
const BACKSLASH = 0x5c;
const OPEN_BRACE = 0x7b;
const CLOSE_BRACE = 0x7d;
const OPEN_BRACKET = 0x5b;
const CLOSE_BRACKET = 0x5d;

const isSpace = (c: number) => c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09;

/** The most kept of what is no list: a bare value is small; past this it is something else. */
const MOST_BARE = 256 * 1024;

const PHP_NOTICE = /^(?:<br|<b>|(?:PHP )?(?:Warning|Notice|Deprecated|Fatal error)\b)/i;

/**
 * Where the JSON starts past a PHP warning a panel printed before it ("<br />\n<b>Warning</b>:
 * ..."): the first [ or { at the start of a line or right after a tag. Undefined when [text] starts
 * with no such warning (a web page is no JSON, and stays an error), or none comes soon enough.
 */
export function afterPhpNotice(text: string): number | undefined {
  if (!PHP_NOTICE.test(text.replace(/^[\s\ufeff]+/, ''))) return undefined;
  const m = /(?:^|\n|>)\s*([[{])/.exec(text);
  return m && m.index < MOST_BARE ? m.index + m[0].length - 1 : undefined;
}

/**
 * The objects in the JSON array [text], or the values of a JSON object (some panels send {"0":
 * {...}, "1": {...}}), one at a time. Decoded whole, a list of tens of MB takes several hundred in
 * memory as maps; this way it takes the items made of it and little else. [place].at says how far
 * it has read. Other elements are skipped; nothing comes of a bare value (null, a number). An item
 * that is no JSON (a tab left unescaped in one title) is skipped: the rest of the list is good.
 * Throws a SyntaxError when it is not JSON or is cut short, or when all its items were skipped.
 */
export function* jsonItems(text: string, place: { at: number } = { at: 0 }): IterableIterator<Record<string, unknown>> {
  let outer = 0; // the opening bracket of the whole, once seen
  let depth = 0;
  let inString = false;
  let escape = false;
  let from = -1; // where the item being read starts
  let ended = false;
  let read = 0;
  let skipped = 0;
  // Past a PHP warning before the list, if any
  for (let i = afterPhpNotice(text) || 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (inString) {
      if (escape) escape = false;
      else if (c === BACKSLASH) escape = true;
      else if (c === QUOTE) inString = false;
    } else if (!outer) {
      if (c === OPEN_BRACKET || c === OPEN_BRACE) {
        outer = c;
        depth = 1;
      } else if (!isSpace(c) && c !== 0xfeff) {
        // Not a list: read whole (it is small), for what it is
        if (text.length - i > MOST_BARE) throw new SyntaxError('Not a list');
        JSON.parse(text.slice(i));
        return;
      }
    } else if (ended) {
      if (!isSpace(c)) throw new SyntaxError('Unexpected character after the end');
    } else if (c === QUOTE) {
      inString = true;
    } else if (c === OPEN_BRACE || c === OPEN_BRACKET) {
      depth++;
      if (depth === 2 && c === OPEN_BRACE) from = i;
    } else if (c === CLOSE_BRACE || c === CLOSE_BRACKET) {
      depth--;
      if (from >= 0 && depth === 1) {
        place.at = i;
        let item: Record<string, unknown> | undefined;
        try {
          item = JSON.parse(text.slice(from, i + 1)) as Record<string, unknown>;
          read++;
        } catch {
          skipped++;
        }
        from = -1;
        if (item) yield item;
      } else if (depth === 0) {
        if (c !== (outer === OPEN_BRACKET ? CLOSE_BRACKET : CLOSE_BRACE)) throw new SyntaxError('Mismatched end');
        ended = true;
      }
    }
  }
  if (!ended) throw new SyntaxError('Cut short');
  if (skipped && !read) throw new SyntaxError('No item could be read');
}

/**
 * Counts the objects of a JSON list as its bytes go by, none of them read: to say how many have
 * come while a big list still downloads, and whether it got to its end.
 */
export class JsonItemCounter {
  count = 0;
  private depth = 0;
  private inString = false;
  private escape = false;

  add(piece: Uint8Array): void {
    for (let i = 0; i < piece.length; i++) {
      const b = piece[i];
      if (this.inString) {
        if (this.escape) this.escape = false;
        else if (b === BACKSLASH) this.escape = true;
        else if (b === QUOTE) this.inString = false;
      } else if (b === QUOTE) {
        this.inString = true;
      } else if (b === OPEN_BRACE || b === OPEN_BRACKET) {
        this.depth++;
      } else if (b === CLOSE_BRACE || b === CLOSE_BRACKET) {
        this.depth--;
        if (this.depth === 1 && b === CLOSE_BRACE) this.count++;
      }
    }
  }

  /** Every bracket opened so far was closed: a list read to its end, not one cut short. */
  get closed(): boolean {
    return this.depth === 0 && !this.inString;
  }
}
