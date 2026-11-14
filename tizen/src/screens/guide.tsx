// The programme grid (app/lib/ui/guide_screen.dart): channels down the side, time across and a
// live "now" line. Built row by row as they come into view, as Flutter's ListView.builder: a
// category can have hundreds of channels, and the remote only weighs the rows that exist. One box
// scrolls the rows up and down; across, the time moves with the remote (the programmes slide
// under a clipped strip), so the channel column never scrolls away and Down never drifts in time.
import { useEffect, useRef, useState } from 'preact/hooks';
import { EpgGuide, epgProgress, isNow } from '../data/epg';
import { categoryLabel } from '../ui/labels';
import { Category, EpgEntry, LiveChannel } from '../data/source';
import { language, t } from '../i18n';
import { Keys } from '../platform/tv';
import { session } from '../session';
import { AppBar, AppChip, Focusable, Icon, SecondaryButton, useNotifier } from '../ui/components';
import { focus, focused, noteUserAction } from '../ui/focus';
import { showDialog, useKeys } from '../ui/router';
import { useRowWindow } from '../ui/window';
import { showChannelSheet } from './channel';
import { Empty, Failed, Loading, NetImage, useAsync } from './home';
import { playChannels, playQueue } from './player';

const ROW = 7.6; // rem
const CHANNEL = 21; // rem
const PER_MINUTE = 0.5; // rem: one hour is 30 rem
const TODAY_SPAN = 14 * 60; // minutes
/** Days before today the guide goes back to: what it keeps of the past, for channels with catch-up. */
const DAYS_BACK = 3;
const RULER = 3.2; // rem
const PX = 20; // px in a rem (theme.css)
/** Room kept between a programme and the edge when the time moves to show it. */
const MARGIN = 2.4; // rem

/** The TV's clock setting, as Flutter's alwaysUse24HourFormat: Tizen's own, else the browser's. */
const use24h: boolean = (() => {
  try {
    const tizen = (window as unknown as { tizen?: { time?: { getTimeFormat?: () => string } } }).tizen;
    if (tizen && tizen.time && tizen.time.getTimeFormat) return String(tizen.time.getTimeFormat()).indexOf('a') < 0; // "h:m:s ap" or "H:m:s"
  } catch {
    // Not on the TV
  }
  try {
    return (new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).resolvedOptions() as { hour12?: boolean }).hour12 === false;
  } catch {
    return false;
  }
})();

/**
 * A time as Flutter's MaterialLocalizations.formatTimeOfDay writes it in the app's language:
 * "8:30 PM" in English ("20:30" with the 24-hour clock), "20:30" in Spanish.
 */
export function hm(d: Date): string {
  const h = d.getHours();
  const mm = (d.getMinutes() < 10 ? ':0' : ':') + d.getMinutes();
  if (language === 'es') return `${h}${mm}`;
  if (use24h) return (h < 10 ? '0' : '') + h + mm;
  return `${h % 12 || 12}${mm} ${h < 12 ? 'AM' : 'PM'}`;
}

/** Whether [c] keeps [e] to watch again: aired, and within the days it keeps (Flutter's LiveChannel.keeps). */
function keeps(c: LiveChannel, e: EpgEntry, now: number): boolean {
  const end = e.end.getTime();
  return c.archiveDays > 0 && end < now && end > now - c.archiveDays * 24 * 3600 * 1000;
}

/** Live if it is on now, catch-up if it already aired and the channel keeps an archive, else its details. */
function openProgramme(channels: LiveChannel[], index: number, e: EpgEntry): void {
  const c = channels[index];
  if (isNow(e)) return playChannels(channels, index);
  // Only within the days the channel keeps: older, the provider has nothing to give
  const catchup = keeps(c, e, Date.now()) ? session().source.catchupUrl(c, e.start, (e.end.getTime() - e.start.getTime()) / 60000) : null;
  if (catchup) {
    playQueue([{ url: catchup, title: c.name, subtitle: `${e.title} · ${hm(e.start)}` }]);
    return;
  }
  showProgrammeSheet(c, e);
}

/** A programme's details (Flutter's showProgrammeSheet), with a button for the remote to close it. */
export function showProgrammeSheet(c: LiveChannel, e: EpgEntry): Promise<void> {
  return showDialog<void>((done) => (
    <div class="dialog" style={{ maxWidth: '72rem' }}>
      <div class="muted">{c.name}</div>
      <h2 class="title-large" style={{ margin: '0.4rem 0' }}>{e.title}</h2>
      <div>{`${hm(e.start)} – ${hm(e.end)}`}</div>
      {e.description && <p style={{ lineHeight: 1.5, margin: '1.2rem 0 0' }}>{e.description}</p>}
      <div class="actions">
        <Focusable class="button secondary" onTap={() => done()} autofocus>
          {t('close')}
        </Focusable>
      </div>
    </div>
  )).then(() => {});
}

export function GuideScreen({ categories, initial }: { categories: Category[]; initial?: string }) {
  const { source } = session();
  const [category, setCategory] = useState(initial || (categories[0] && categories[0].id));
  const [scrollX, setScrollX] = useState(0); // rem of time scrolled past, the ruler's and the grid's
  const [, tick] = useState(0);
  const chips = useRef<HTMLDivElement>(null);
  // Start on the half-hour before now, an hour earlier: blocks are clipped to it, so every title
  // is readable and the "now" line sits a little to the right
  const [day, setDay] = useState(0); // days before today on screen
  // Today from just before now; an earlier day whole, from its midnight, to find what it aired
  const from = (() => {
    const d = new Date();
    if (day > 0) return new Date(d.getFullYear(), d.getMonth(), d.getDate() - day).getTime();
    d.setMinutes(d.getMinutes() < 30 ? 0 : 30, 0, 0);
    return d.getTime() - 60 * 60000;
  })();
  const SPAN = day === 0 ? TODAY_SPAN : 24 * 60;
  const channels = useAsync<LiveChannel[]>(() => source.liveChannels(category), [category]);

  useEffect(() => {
    const timer = window.setInterval(() => tick((n) => n + 1), 60000);
    // The chosen category may be far down a long list
    const chip = chips.current && chips.current.querySelector<HTMLElement>('.chip.selected');
    if (chip && chips.current) chips.current.scrollLeft = chip.offsetLeft - 32;
    return () => clearInterval(timer);
  }, []);

  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <AppBar title={t('tvGuide')} />
      {/* Which day: today, or one before it for what channels with catch-up kept */}
      <div class="row hscroll" data-fgroup data-chips style={{ padding: '0.8rem 1.6rem 0', flex: 'none' }}>
        {Array.from({ length: DAYS_BACK + 1 }, (_, d) => (
          <div key={d} style={{ marginRight: '0.8rem', flex: 'none' }}>
            <AppChip
              label={d === 0 ? t('guideToday') : d === 1 ? t('guideYesterday') : new Date(Date.now() - d * 86400000).toLocaleDateString()}
              selected={d === day}
              onTap={() => {
                setDay(d);
                setScrollX(0);
              }}
            />
          </div>
        ))}
      </div>
      <div ref={chips} class="row hscroll" data-fgroup data-chips style={{ padding: '0.8rem 1.6rem', flex: 'none' }}>
        {categories.map((c) => (
          <div key={c.id} style={{ marginRight: '0.8rem', flex: 'none' }}>
            <AppChip
              label={categoryLabel(c.name)}
              selected={c.id === category}
              onTap={() => {
                setCategory(c.id);
                setScrollX(0); // another category opens at the start, as in Flutter
              }}
              autofocus={c.id === category}
            />
          </div>
        ))}
      </div>
      {/* Time ruler, as the programmes are scrolled */}
      <div class="row" style={{ height: `${RULER}rem`, flex: 'none', borderBottom: '1px solid var(--stroke)' }}>
        <div style={{ width: `${CHANNEL}rem`, flex: 'none' }} />
        <div class="grow" style={{ position: 'relative', height: '100%', overflow: 'hidden' }}>
          <div style={{ position: 'absolute', left: 0, top: 0, height: '100%', width: `${SPAN * PER_MINUTE}rem`, transform: `translateX(${-scrollX}rem)` }}>
            {Array.from({ length: SPAN / 30 }, (_, i) => (
              <span key={i} class="muted" style={{ position: 'absolute', left: `${i * 30 * PER_MINUTE + 0.6}rem`, top: '0.6rem', fontWeight: 600 }}>
                {hm(new Date(from + i * 30 * 60000))}
              </span>
            ))}
          </div>
        </div>
      </div>
      <GuideFailed />
      <div style={{ flex: 1, minHeight: 0, position: 'relative' }}>
        {channels.error ? (
          <Failed error={channels.error} retry={channels.retry} />
        ) : !channels.data ? (
          <Loading />
        ) : !channels.data.length ? (
          <Empty />
        ) : (
          <Grid key={`${category}@${day}`} channels={channels.data} from={from} span={SPAN} scrollX={scrollX} setScrollX={setScrollX} />
        )}
      </div>
    </div>
  );
}

interface RowParts {
  cell: HTMLElement | null;
  /** In time order: the positioned box, its focusable, and where it lies (rem). */
  blocks: { box: Element; el: HTMLElement; x: number; w: number }[];
}

/** The channel and the programmes of a built row. */
function rowParts(row: Element): RowParts {
  const blocks: RowParts['blocks'] = [];
  const boxes = row.querySelectorAll('[data-x]');
  for (let i = 0; i < boxes.length; i++) {
    const el = boxes[i].querySelector<HTMLElement>('.f');
    if (el) blocks.push({ box: boxes[i], el, x: Number(boxes[i].getAttribute('data-x')), w: Number(boxes[i].getAttribute('data-w')) });
  }
  return { cell: row.querySelector<HTMLElement>('[data-cell] .f'), blocks };
}

/**
 * The programmes of [list] (in time order) overlapping [from, to), and the one just past each end:
 * Left and Right always find the next one built, however long the one they leave.
 */
function near(list: EpgEntry[], from: number, to: number): EpgEntry[] {
  let lo = 0;
  while (lo < list.length && list[lo].end.getTime() <= from) lo++;
  let hi = list.length;
  while (hi > lo && list[hi - 1].start.getTime() >= to) hi--;
  return list.slice(Math.max(0, lo - 1), Math.min(list.length, hi + 1));
}

/** Not downloaded, and no copy kept: said once, with the way to try again. */
function GuideFailed() {
  const { guide: holder } = session();
  useNotifier(holder);
  if (holder.guide !== EpgGuide.failed) return null;
  return (
    <div class="row" data-fgroup style={{ padding: '1rem 2.4rem', flex: 'none', alignItems: 'center' }}>
      <Icon icon="cloud_off_rounded" />
      <span class="grow" style={{ marginLeft: '1.2rem' }}>
        {t('guideFailed')}
      </span>
      <SecondaryButton icon="refresh_rounded" label={t('retry')} onPressed={() => holder.retry()} />
    </div>
  );
}

/** The rows of one category: only those near the view are built. */
function Grid({ channels, from, span: SPAN, scrollX, setScrollX }: { channels: LiveChannel[]; from: number; span: number; scrollX: number; setScrollX: (x: number) => void }) {
  const { guide: holder } = session();
  useNotifier(holder);
  const guide = holder.guide;
  const box = useRef<HTMLDivElement | null>(null);
  const win = useRowWindow(channels.length, ROW * PX);
  const [width, setWidth] = useState(75); // of the programmes' strip, rem
  const state = useRef({ scrollX: 0, last: null as { row: number; x: number } | null });
  state.current.scrollX = scrollX;
  const to = from + SPAN * 60000;
  const maxX = Math.max(0, SPAN * PER_MINUTE - width);

  useEffect(() => {
    if (box.current && box.current.clientWidth) setWidth(box.current.clientWidth / PX - CHANNEL);
  }, []);

  /**
   * The time follows the remote as Flutter's focus traversal scrolls: Right shows the programme
   * from its end (never back), Left shows its start, and Up, Down or in from the side keep the
   * time unless the programme is out of sight.
   */
  const onFocusIn = (e: FocusEvent) => {
    const el = e.target as HTMLElement;
    const rowEl = el.closest('[data-row]');
    if (!rowEl) return;
    const row = Number(rowEl.getAttribute('data-row'));
    win.focusRow(row);
    const block = el.closest('[data-x]');
    if (!block) {
      state.current.last = null;
      return;
    }
    const x = Number(block.getAttribute('data-x'));
    const w = Number(block.getAttribute('data-w'));
    const prev = state.current.last;
    const sideways = prev !== null && prev.row === row;
    let sx = state.current.scrollX;
    if (sideways && x > prev!.x) {
      if (x + w > sx + width - MARGIN) sx = Math.max(sx, Math.min(x - MARGIN, x + w - width + MARGIN));
    } else if (sideways && x < prev!.x) {
      if (x < sx + MARGIN) sx = x - MARGIN;
    } else if (x + w < sx + MARGIN || x > sx + width - MARGIN) {
      sx = x - MARGIN;
    }
    sx = Math.max(0, Math.min(maxX, sx));
    state.current.last = { row, x };
    if (sx !== state.current.scrollX) {
      state.current.scrollX = sx;
      setScrollX(sx);
    }
  };

  /**
   * The arrows inside the grid go along the row and to the programme on at the same time in the
   * next one. The focus engine would weigh the programmes slid out of the strip too (still laid
   * out, under the channel column or past the edge), and land on one hours away.
   * Undefined: the engine's move; null: nothing that way.
   */
  const step = (el: HTMLElement, dir: 'left' | 'right' | 'up' | 'down'): HTMLElement | null | undefined => {
    const rowEl = el.closest('[data-row]');
    if (!rowEl || !box.current) return undefined;
    const row = Number(rowEl.getAttribute('data-row'));
    const here = rowParts(rowEl);
    const blockEl = el.closest('[data-x]');
    const i = blockEl ? here.blocks.map((b) => b.box).indexOf(blockEl) : -1;
    const sx = state.current.scrollX;
    if (dir === 'right') {
      // From the channel: what is on at the time shown, even if it began off to the left
      if (i < 0) return here.blocks.filter((b) => b.x + b.w > sx + MARGIN).map((b) => b.el)[0] || null;
      return here.blocks[i + 1] ? here.blocks[i + 1].el : null;
    }
    if (dir === 'left') return i < 0 ? null : i > 0 ? here.blocks[i - 1].el : here.cell;
    const next = row + (dir === 'down' ? 1 : -1);
    if (next < 0) return undefined; // up to the categories
    if (next >= channels.length) return null;
    const nextEl = box.current.querySelector(`[data-row="${next}"]`);
    if (!nextEl) return undefined;
    const there = rowParts(nextEl);
    return i < 0 ? there.cell : at(there, Math.max(here.blocks[i].x, sx), sx);
  };

  /** In [r], the programme in sight nearest the time [t] (rem), else the channel. */
  const at = (r: RowParts, t: number, sx: number): HTMLElement | null => {
    let best: HTMLElement | null = null;
    let distance = Infinity;
    for (const b of r.blocks) {
      if (b.x + b.w <= sx || b.x >= sx + width) continue;
      const d = t < b.x ? b.x - t : t >= b.x + b.w ? t - (b.x + b.w) + 0.01 : 0;
      if (d < distance) {
        distance = d;
        best = b.el;
      }
    }
    return best || r.cell;
  };

  useKeys((e) => {
    const k = e.keyCode;
    const dir = k === Keys.left ? 'left' : k === Keys.right ? 'right' : k === Keys.up ? 'up' : k === Keys.down ? 'down' : null;
    const el = focused();
    if (!dir || !el || !box.current) return false;
    let target: HTMLElement | null | undefined;
    if (box.current.contains(el)) {
      target = step(el, dir);
    } else if (dir === 'down' && el.closest('[data-chips]')) {
      // Down from the categories: the first row in sight, below the chip
      const rowEl = box.current.querySelector(`[data-row="${Math.min(channels.length - 1, Math.ceil(box.current.scrollTop / (ROW * PX) - 0.05))}"]`);
      if (rowEl) {
        const r = el.getBoundingClientRect();
        const strip = box.current.getBoundingClientRect().left + CHANNEL * PX;
        const cx = (r.left + r.right) / 2;
        const parts = rowParts(rowEl);
        const sx = state.current.scrollX;
        target = cx < strip ? parts.cell : at(parts, sx + (cx - strip) / PX, sx);
      }
    }
    if (target === undefined) return false;
    noteUserAction();
    if (target) focus(target);
    return true;
  });

  const x = (ms: number) => ((ms - from) / 60000) * PER_MINUTE;
  const now = Date.now();
  // Programmes built across: a view's width either side of the one shown
  const winFrom = Math.max(from, from + ((scrollX - width) / PER_MINUTE) * 60000);
  const winTo = Math.min(to, from + ((scrollX + 2 * width) / PER_MINUTE) * 60000);
  const nowX = x(now) - scrollX;
  const rows: number[] = [];
  for (let i = win.first; i < win.end; i++) rows.push(i);

  return (
    <div
      ref={(el) => {
        box.current = el;
        win.ref(el);
      }}
      class="vscroll"
      onScroll={win.onScroll}
      onFocusIn={onFocusIn}
      onFocusOut={(e: FocusEvent) => {
        // Back in later (from the chips, a sheet, the player) is not a move along a row
        const to = e.relatedTarget as Node | null;
        if (!to || !box.current || !box.current.contains(to)) state.current.last = null;
      }}
      style={{ height: '100%', overflowY: 'auto', overflowX: 'hidden' }}
    >
      <div style={{ position: 'relative', height: `${channels.length * ROW + 3.2}rem` }}>
        {rows.map((i) => {
          const c = channels[i];
          return (
            <div key={i} data-row={i} class="row" style={{ position: 'absolute', left: 0, right: 0, top: `${i * ROW}rem`, height: `${ROW}rem`, alignItems: 'stretch' }}>
              <div data-cell style={{ width: `${CHANNEL}rem`, flex: 'none', padding: '0.4rem 0.8rem 0.4rem 1.2rem', boxSizing: 'border-box' }}>
                <Focusable
                  radius={12}
                  scale={1.02}
                  onTap={() => playChannels(channels, i)}
                  onLongPress={() => showChannelSheet(c, () => playChannels(channels, i))}
                  style={{ height: '100%', boxSizing: 'border-box' }}
                >
                  <div class="row" style={{ background: 'var(--surface)', height: `${ROW - 1.4}rem` }}>
                    <div style={{ width: '4.8rem', height: '4rem', margin: '0 0.8rem', flex: 'none' }}>
                      <NetImage url={c.icon || guide.iconOf(c.epgId)} icon="tv_rounded" />
                    </div>
                    <div class="clamp2 grow" style={{ fontWeight: 600, fontSize: 'calc(1.3rem * var(--text-scale))', paddingRight: '0.6rem' }}>{c.name}</div>
                  </div>
                </Focusable>
              </div>
              <div class="grow" style={{ position: 'relative', overflow: 'hidden' }}>
                <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: `${SPAN * PER_MINUTE}rem`, transform: `translateX(${-scrollX}rem)` }}>
                  {guide.has(c.epgId) ? (
                    near(guide.between(c.epgId, from, to), winFrom, winTo).map((e) => {
                      const left = x(Math.max(e.start.getTime(), from));
                      const width = Math.max(2.4, x(Math.min(e.end.getTime(), to)) - left - 0.4);
                      // A programme that began off to the left keeps its title in sight
                      const shift = Math.max(0, Math.min(scrollX - left, width - 8));
                      return (
                        <div key={`${e.start.getTime()}|${e.title}`} data-x={left} data-w={width} style={{ position: 'absolute', left: `${left}rem`, width: `${width}rem`, top: '0.4rem', bottom: '0.4rem' }}>
                          <Block entry={e} archive={keeps(c, e, now)} shift={shift} now={now} onTap={() => openProgramme(channels, i, e)} />
                        </div>
                      );
                    })
                  ) : (
                    <div class="muted row" style={{ position: 'absolute', left: '0.4rem', top: '0.4rem', bottom: '0.4rem', width: `${x(now) + 30}rem`, padding: '0 1.4rem', fontSize: 'calc(1.2rem * var(--text-scale))', background: 'rgba(17,17,17,0.5)', borderRadius: '1rem', boxSizing: 'border-box' }}>
                      {!holder.ready ? t('guideLoading') : guide === EpgGuide.failed ? t('guideFailed') : t('noGuide')}
                    </div>
                  )}
                </div>
              </div>
            </div>
          );
        })}
        {/* The "now" line */}
        {nowX >= 0 && nowX <= width && (
          <div style={{ position: 'absolute', top: 0, bottom: 0, left: `${CHANNEL + nowX - 0.1}rem`, width: '0.2rem', background: 'var(--live)', zIndex: 1, pointerEvents: 'none' }} />
        )}
      </div>
    </div>
  );
}

function Block({ entry: e, archive, shift, now, onTap }: { entry: EpgEntry; archive: boolean; shift: number; now: number; onTap: () => void }) {
  const on = isNow(e, now);
  const past = e.end.getTime() < now;
  return (
    <Focusable radius={10} scale={1} onTap={onTap} style={{ height: '100%', boxSizing: 'border-box' }}>
      <div
        style={{
          height: `${ROW - 1.4}rem`,
          boxSizing: 'border-box',
          padding: `0.8rem 1rem 0.8rem ${1.2 + shift}rem`,
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'center',
          background: on ? 'var(--surface-high)' : 'var(--surface)',
          borderLeft: on ? '0.3rem solid var(--text)' : 'none',
          opacity: past && !archive ? 0.55 : 1,
        }}
      >
        <div class="row">
          {archive && (
            <span style={{ marginRight: '0.4rem', display: 'flex' }}>
              <Icon icon="history_rounded" size={14} />
            </span>
          )}
          <span class="ellipsis" style={{ fontWeight: on ? 700 : 600, fontSize: 'calc(1.3rem * var(--text-scale))' }}>{e.title}</span>
        </div>
        <div class="muted" style={{ fontSize: 'calc(1.1rem * var(--text-scale))', marginTop: '0.3rem', whiteSpace: 'nowrap', overflow: 'hidden' }}>{`${hm(e.start)} – ${hm(e.end)}`}</div>
      </div>
    </Focusable>
  );
}

/** Title of what is on now plus a thin progress bar, for channel cards. */
export function NowOnAir({ entry }: { entry: EpgEntry }) {
  return (
    <div>
      <div class="muted ellipsis" style={{ fontSize: 'calc(1.2rem * var(--text-scale))' }}>{entry.title}</div>
      <div style={{ height: '0.3rem', background: 'rgba(255,255,255,0.12)', borderRadius: '0.2rem', marginTop: '0.5rem', overflow: 'hidden' }}>
        <div style={{ width: `${epgProgress(entry) * 100}%`, height: '100%', background: 'var(--text)' }} />
      </div>
    </div>
  );
}
