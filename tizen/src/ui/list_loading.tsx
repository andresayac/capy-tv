// How far the lists being waited for have got (app/lib/ui/common.dart listDownloadText,
// listProgressText, ListLoading): a big catalog on a slow line takes minutes, and a spinner alone
// looks stuck. So does one that goes quiet with the list here and still to be read.
import { DownloadProgress, ImportKind, ImportRow, listDownloads, listImports } from '../data/lists';
import { language, StringKey, t } from '../i18n';
import { CapyStatus, Icon, useNotifier } from './components';

/** [n] as the app's language writes it, with [digits] decimals. */
const number = (n: number, digits = 0) => n.toLocaleString(language, { minimumFractionDigits: digits, maximumFractionDigits: digits });

/** The share of the lists, or how much has come when the server does not say how much there is. */
function listDownloadText(p: DownloadProgress | null): string | null {
  if (!p) return null;
  if (p.total) return t('downloadingCatalogPercent', { percent: Math.min(100, Math.floor((100 * p.received) / p.total)) });
  const mb = p.received / 1000000;
  return t('downloadingCatalogSize', { size: number(mb, mb < 10 ? 1 : 0) });
}

/** How far the lists have got, on one line: what has come and how many are in it. */
function listProgressText(): string | null {
  const download = listDownloadText(listDownloads.value);
  const items = listImports.items;
  if (!items) return download;
  const imported = t('importedCount', { count: number(items) });
  return download ? `${download} · ${imported}` : imported;
}

/** How far the lists have got, kept current; [or] while there is nothing to say. */
export function ListProgressText({ or }: { or: string }) {
  useNotifier(listDownloads);
  useNotifier(listImports);
  return <span>{listProgressText() || or}</span>;
}

/** The same in a small line under something, and nothing while there is nothing to say. */
export function ListProgressNote() {
  useNotifier(listDownloads);
  useNotifier(listImports);
  const text = listProgressText();
  return text ? <div class="muted" style={{ marginTop: '0.4rem', fontSize: 'calc(1.3rem * var(--text-scale))' }}>{text}</div> : null;
}

const IMPORT_NAMES: Record<ImportKind, StringKey> = { live: 'liveTv', movies: 'movies', series: 'series', playlist: 'importedPlaylist' };

/** Capy while the provider's lists load and, as they come, how far they have got and how many are in them already. */
export function ListLoading() {
  useNotifier(listDownloads);
  useNotifier(listImports);
  const p = listDownloads.value;
  const rows = listImports.current;
  const downloaded = p && p.total ? Math.min(1, p.received / p.total) : null;
  const read = p || !rows.length || rows.every((r) => r.done) ? null : rows.reduce((sum, r) => sum + (r.read || 0), 0) / rows.length;
  const share = downloaded !== null ? downloaded : read;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', textAlign: 'center' }}>
      <CapyStatus mood="loading" />
      <div class="muted" style={{ marginTop: '1.6rem' }}>{listDownloadText(p) || t(rows.length ? 'organizingCatalog' : 'loadingCatalog')}</div>
      <div style={{ width: '16rem', height: '0.2rem', marginTop: '0.8rem', background: share === null ? 'transparent' : 'var(--stroke)' }}>
        {share !== null && <div style={{ width: `${share * 100}%`, height: '100%', background: 'var(--text)' }} />}
      </div>
      {rows.length > 0 && (
        <div class="row" style={{ marginTop: '1.8rem' }}>
          {rows.map((row, i) => (
            <ImportCount key={row.kind} row={row} first={i === 0} />
          ))}
        </div>
      )}
    </div>
  );
}

/** How many of a kind have come so far, and a check once they are all here. */
function ImportCount({ row, first }: { row: ImportRow; first: boolean }) {
  return (
    <div style={{ marginLeft: first ? 0 : '2.8rem' }}>
      <div style={{ fontSize: 'calc(2rem * var(--text-scale))', fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>{row.items === 0 ? '–' : number(row.items)}</div>
      <div class="row muted" style={{ justifyContent: 'center', marginTop: '0.2rem', fontSize: 'calc(1.3rem * var(--text-scale))' }}>
        {row.done && (
          <span style={{ display: 'flex', marginRight: '0.3rem' }}>
            <Icon icon="check_rounded" size={13} />
          </span>
        )}
        {t(IMPORT_NAMES[row.kind])}
      </div>
    </div>
  );
}
