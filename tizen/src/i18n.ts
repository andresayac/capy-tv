// The Flutter app's own strings (app/lib/l10n/app_*.arb), with the part of ICU they use:
// {name} placeholders, and plural and select.
import strings from './gen/strings.json';

export type StringKey = keyof typeof strings.en;
type Args = Record<string, string | number>;

const supported = Object.keys(strings) as (keyof typeof strings)[];

/** Where the language chosen in Settings is kept; none follows the TV's. */
const CHOSEN = 'language';

/** The language chosen in Settings, as its code; '' follows the TV's. */
export function chosenLanguage(): string {
  try {
    const code = localStorage.getItem(CHOSEN) || '';
    return (supported as string[]).indexOf(code) >= 0 ? code : '';
  } catch {
    return '';
  }
}

/**
 * Keeps [code] ('' for the TV's) and starts the app again in it: every screen took its words at
 * the start. What is saved stays.
 */
export function chooseLanguage(code: string): void {
  try {
    if (code) localStorage.setItem(CHOSEN, code);
    else localStorage.removeItem(CHOSEN);
  } catch {
    return; // nowhere to keep it
  }
  location.reload();
}

/** The app's languages, as codes. */
export const languages: string[] = supported as string[];

/** [code]'s own name ("English", "Español"), as it is listed among the languages. */
export const languageSelf = (code: string): string => (strings as Record<string, Record<string, string>>)[code].languageSelf;

/** The language chosen in Settings, else the TV's if the app has it, else English. */
export const language: keyof typeof strings = (() => {
  const chosen = chosenLanguage();
  if (chosen) return chosen as keyof typeof strings;
  const code = (navigator.language || 'en').slice(0, 2).toLowerCase();
  return (supported as string[]).indexOf(code) >= 0 ? (code as keyof typeof strings) : 'en';
})();

const table = strings[language] as Record<string, string>;
const fallback = strings.en as Record<string, string>;

export function t(key: StringKey, args: Args = {}): string {
  return format(table[key] || fallback[key] || key, args);
}

/** Expands an ICU message: `{x}`, `{n, plural, =1{…} other{…}}`, `{v, select, a{…} other{…}}`. */
export function format(message: string, args: Args): string {
  let out = '';
  let i = 0;
  while (i < message.length) {
    const c = message[i];
    if (c !== '{') {
      out += c;
      i++;
      continue;
    }
    const end = matching(message, i);
    out += expand(message.slice(i + 1, end), args);
    i = end + 1;
  }
  return out;
}

function matching(s: string, open: number): number {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === '{') depth++;
    else if (s[i] === '}' && --depth === 0) return i;
  }
  return s.length - 1;
}

function expand(body: string, args: Args): string {
  const comma = body.indexOf(',');
  if (comma < 0) {
    const v = args[body.trim()];
    return v === undefined ? `{${body}}` : String(v);
  }
  const name = body.slice(0, comma).trim();
  const rest = body.slice(comma + 1);
  const comma2 = rest.indexOf(',');
  const kind = rest.slice(0, comma2).trim();
  const cases = parseCases(rest.slice(comma2 + 1));
  const value = args[name];
  let chosen: string | undefined;
  if (kind === 'plural') {
    const n = Number(value);
    chosen = cases['=' + n];
    if (chosen === undefined && n === 1) chosen = cases.one;
    if (chosen === undefined) chosen = cases.other;
  } else {
    chosen = cases[String(value)];
    if (chosen === undefined) chosen = cases.other;
  }
  return format(chosen || '', args);
}

function parseCases(s: string): Record<string, string> {
  const cases: Record<string, string> = {};
  let i = 0;
  while (i < s.length) {
    const open = s.indexOf('{', i);
    if (open < 0) break;
    const key = s.slice(i, open).trim();
    const close = matching(s, open);
    cases[key] = s.slice(open + 1, close);
    i = close + 1;
  }
  return cases;
}
