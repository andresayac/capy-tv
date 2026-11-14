// How provider names read best, as the Flutter app shows them (app/lib/data/catalog.dart).

// Small words kept lowercase in titles, and acronyms kept uppercase
const MINOR = ['de', 'del', 'la', 'las', 'el', 'los', 'y', 'e', 'en', 'a', 'o', 'of', 'the', 'and', 'in', 'for', 'por', 'con'];
const ACRONYMS = [
  'TV', 'HD', 'FHD', 'UHD', '4K', 'VOD', 'ESPN', 'HBO', 'NBA', 'NFL', 'MLB', 'NHL', 'UFC', 'WWE', 'PPV', 'MMA', 'F1',
  'USA', 'UK', 'VIP', 'DC', 'TNT', 'AMC', 'CNN', 'BBC', 'FX', 'MTV', 'LMP', 'WBA', 'LVBP', 'DSPORTS',
];

/**
 * Provider category names are often shouting, decorated and prefixed ("🎞️ VOD | TOP 10 DE LA
 * SEMANA"); this makes them read like titles ("Top 10 de la Semana"), as the Flutter app does.
 */
export function displayCategoryName(raw: string): string {
  let s = raw.trim();
  // Leading emoji/symbols and type prefixes such as "VOD |" or "SERIES |"
  s = s.replace(/^[^\p{L}\p{N}]+/u, '');
  s = s.replace(/^(VOD|SERIES|SERIE|MOVIES?|PEL[IÍ]CULAS?|LIVE|TV)\s*[|:\-–]\s*/i, '');
  s = s.replace(/\s+/g, ' ').trim();
  if (!s) return raw.trim();
  // Only retitle names written entirely in capitals; anything else is left as the provider wrote it
  if (s !== s.toUpperCase()) return s;
  return s
    .split(' ')
    .map((w, i) => {
      if (ACRONYMS.indexOf(w.replace(/[^\p{L}\p{N}]/gu, '')) >= 0 || /\d/.test(w)) return w;
      if (i > 0 && MINOR.indexOf(w.toLowerCase()) >= 0) return w.toLowerCase();
      return w ? w.charAt(0) + w.slice(1).toLowerCase() : w;
    })
    .join(' ');
}
