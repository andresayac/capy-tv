// How titles compare across names and providers (app/lib/data/matching.dart), the part that needs
// nothing else: the parsing worker (src/workers/catalog.ts) works out version keys with it, and the
// XMLTV worker (src/workers/xmltv.ts) the guide's names for its channels.

const FOLDED: Record<string, string> = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a', 'å': 'a', 'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e', 'ě': 'e',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i', 'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o', 'ø': 'o', 'ő': 'o',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u', 'ů': 'u', 'ű': 'u', 'ñ': 'n', 'ń': 'n', 'ç': 'c', 'ć': 'c', 'č': 'c',
  'ł': 'l', 'ş': 's', 'ś': 's', 'š': 's', 'ğ': 'g', 'ý': 'y', 'ž': 'z', 'ź': 'z', 'ż': 'z', 'ř': 'r', 'đ': 'd',
  'ı': 'i', 'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'þ': 'th',
};

/** The accents Latin letters take apart from them. Other scripts' marks stay: some are vowels. */
const latinMarks = /[\u0300-\u036f]/g;

/** Lowercase without diacritics, so "accion" finds "Acción": as one letter, or a letter and its accent apart (NFD). */
export function fold(s: string): string {
  let out = '';
  for (const ch of s.toLowerCase().replace(latinMarks, '')) out += FOLDED[ch] || ch;
  return out;
}

const notLetterOrNumber = /[^\p{L}\p{N}]+/gu;
const QUALITY = ['hd', 'fhd', 'uhd', 'sd', '4k', '8k', 'hevc', 'h265', '1080p', '720p', '1080', '720', 'hq', 'lq'];

/**
 * A channel's name as a guide's name for it is matched (app/lib/data/epg.dart guideName): in
 * lowercase, without accents, marks of quality (HD, FHD, 4K…) or punctuation. Only names alike in
 * all of that match, never alike ones. The XMLTV worker keeps the guide's names made so.
 */
export function guideName(name: string): string {
  return fold(name)
    .replace(notLetterOrNumber, ' ')
    .split(' ')
    .filter((w) => w && QUALITY.indexOf(w) < 0)
    .join(' ');
}

const bracketed = /\(\d{4}\)|\[[^\]]*\]/g;
const qualityTags = /\b(4k|uhd|fhd|hd|sd|1080p|720p|hevc|h265|x265)\b/g;
const notAlnum = /[^a-z0-9]+/g;
const notLetterOrDigit = /[^\p{L}\p{M}\p{N}]+/gu;

/**
 * A title as compared across providers: folded, without punctuation, the year in brackets or
 * quality tags. Latin letters only, unless [anyScript]: library keys were made that way.
 */
export function looseTitle(s: string, anyScript = false): string {
  return fold(s)
    .replace(bracketed, ' ')
    .replace(qualityTags, ' ')
    .replace(anyScript ? notLetterOrDigit : notAlnum, ' ')
    .trim();
}

/** What providers add to names besides the title. */
const TAGS = [
  'ac3', 'eac3', 'dts', 'aac', 'atmos', 'hdr', 'hdr10', 'dv', '2160p', '480p', 'x264', 'h264', 'web', 'webdl',
  'bluray', 'altadefinicion', 'dual', 'vose', 'vos', 'sub', 'subs', 'subtitulado', 'esp', 'lat', 'cast', 'multi',
  'mp4', 'mkv', 'avi', 'ts', 'm3u8',
];

/** The words of a title as search compares them, in any script. One made only of tags ("Dual") keeps them. */
export function searchWords(s: string): string[] {
  const all = looseTitle(s, true)
    .split(' ')
    .filter((w) => w);
  const words = all.filter((w) => TAGS.indexOf(w) < 0);
  return words.length ? words : all;
}

/** The year a title carries in its name ("Arthur (2024)", "Arthur [2024]"); "[1080]" is a quality. */
export function yearInTitle(s: string): number | undefined {
  const m = /[([]((?:19|20)\d{2})[)\]]/.exec(s);
  return m ? parseInt(m[1], 10) : undefined;
}

/**
 * A title's words alone, as versionKey has them: without its year, tags or the language written
 * out, in any script. For comparing titles here and now; saved keys keep looseTitle.
 */
export function bareTitle(name: string): string {
  const key = versionKey(name);
  return key.slice(0, key.lastIndexOf('|'));
}

const languageSuffix = /(?:\s[-|:]\s*|\s*\()(?:latino|castellano|espanol|ingles|subtitulad[oa])\)?(?=\s*(?:\(\d{4}\)|\[[^\]]*\])*\s*$)/;

/**
 * What tells versions of one title apart from other titles: a provider may list a movie once per
 * language or quality, with the same words and year.
 */
export function versionKey(name: string, year?: number): string {
  // The language written out after the title ("Dark - Latino") is a version too; search keeps it
  const words = searchWords(fold(name).replace(languageSuffix, ''));
  // A year after the title without brackets ("No Way Home.2022") is the year, not a word
  const last = words.length > 1 ? Number(words[words.length - 1]) : NaN;
  if (!isNaN(last) && last >= 1900 && last <= new Date().getFullYear() + 1) {
    words.pop();
    if (year === undefined) year = last;
  }
  const y = year !== undefined ? year : yearInTitle(name);
  return `${words.join(' ')}|${y === undefined ? '' : y}`;
}
