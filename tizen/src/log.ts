// A short log in memory, read from afar over the TV's web inspector (scripts/tv.mjs logs): the
// only way to know what happened on a screen nobody here is looking at.
const MAX = 300;
const lines: string[] = [];
(window as unknown as { capyLog: string[] }).capyLog = lines;

/** [text] with only the host of each address in it: no path, query or user, where an account is. */
export function clean(text: string): string {
  return text.replace(/([a-z][a-z0-9+.-]*:\/\/)(?:[^@/\s]*@)?([^/\s?#@]+)[^\s]*/gi, '$1$2/…');
}

/** What was noted, oldest first, cleaned (Settings' Diagnostics). */
export function noted(): string[] {
  return lines.map(clean);
}

export function log(message: string): void {
  lines.push(new Date().toISOString().slice(11, 23) + '  ' + message);
  if (lines.length > MAX) lines.shift();
}

window.addEventListener('error', (e) => log(`error: ${e.message} @${e.filename}:${e.lineno}`));
window.addEventListener('unhandledrejection', (e) => log(`unhandled: ${(e.reason && e.reason.message) || e.reason}`));
