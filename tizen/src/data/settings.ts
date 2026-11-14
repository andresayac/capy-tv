// App-wide preferences (app/lib/data/settings.dart), under the same keys.
import { Notifier } from '../ui/components';

/** Language codes offered as preferences (ISO 639-2/T, as in the translations). */
export const preferenceLanguages = ['spa', 'eng', 'por', 'fra', 'deu', 'ita'];

/** Tags providers actually use for each language. */
const LANGUAGE_TAGS: Record<string, string[]> = {
  spa: ['spa', 'es', 'esp', 'esa', 'lat', 'cas'],
  eng: ['eng', 'en'],
  por: ['por', 'pt', 'bra'],
  fra: ['fra', 'fre', 'fr'],
  deu: ['deu', 'ger', 'de'],
  ita: ['ita', 'it'],
};

/** Whether a track tagged [tag] ("es", "esa", "spa") is in [language] ("spa"). */
export function isLanguage(tag: string, language: string): boolean {
  const t = tag.toLowerCase().trim();
  return t === language || (LANGUAGE_TAGS[language] || []).indexOf(t) >= 0;
}

class AppSettings extends Notifier {
  private get(key: string, fallback: string): string {
    const v = localStorage.getItem(key);
    return v === null ? fallback : v;
  }

  /** Preferred audio language, '' = whatever the stream marks as default. */
  get audioLanguage(): string {
    return this.get('audioLanguage', '');
  }

  /** Preferred subtitle language, '' = stream default, 'off' = never show subtitles. */
  get subtitleLanguage(): string {
    return this.get('subtitleLanguage', '');
  }

  /** Live stream container for Xtream: 'ts' (most compatible) or 'm3u8'. */
  get liveFormat(): string {
    return this.get('liveFormat', 'ts');
  }

  /** Minutes without a key before the screensaver shows; 0 is never. */
  get screensaverMinutes(): number {
    return Number(this.get('screensaverMinutes', '5')) || 0;
  }

  /**
   * How the picture fills the screen: 'contain' (all of it), 'cover' (zoomed, edges cut), 'fill'
   * (stretched), or a shape of its own drawn whole: '16:9', '4:3', '21:9'.
   */
  get videoFit(): string {
    return this.get('videoFit', 'contain');
  }

  /** Whether one was ever picked: until then AVPlay goes on drawing the picture as it always has. */
  get videoFitPicked(): boolean {
    return localStorage.getItem('videoFit') !== null;
  }

  /** Subtitle text size, in percent of the usual. */
  get subtitleScale(): number {
    return Number(this.get('subtitleScale', '100')) || 100;
  }

  /** A dark band behind subtitle text, for reading it on bright pictures. */
  get subtitleBackground(): boolean {
    return this.get('subtitleBackground', 'false') === 'true';
  }

  /** How dark that band is, in percent. */
  get subtitleBandDarkness(): number {
    return Number(this.get('subtitleBandDarkness', '70')) || 70;
  }

  /** A sharp black outline around subtitle text, instead of the soft shadow. */
  get subtitleOutline(): boolean {
    return this.get('subtitleOutline', 'false') === 'true';
  }

  /** How far above the bottom subtitles sit, in percent of the screen's height (0, 10 or 20). */
  get subtitleLift(): number {
    return Number(this.get('subtitleLift', '0')) || 0;
  }

  /** The text's size, in percent: the TV's system has no setting of its own for it (Flutter's textSize). */
  get textSize(): number {
    return Number(this.get('textSize', '100')) || 100;
  }

  /**
   * Whether trailers play by themselves behind the carousel and the title pages: 'always' or
   * 'never' (Flutter's key; its 'wifi' has no meaning here, where no network is paid by the amount).
   */
  get trailers(): string {
    return this.get('trailers', 'always') === 'never' ? 'never' : 'always';
  }

  /**
   * Seconds the player's controls stay after the last key; 0 is the usual moment (3.5 s). Longer
   * for whoever needs more time to find a button.
   */
  get controlsSeconds(): number {
    return Number(this.get('controlsSeconds', '0')) || 0;
  }

  set(changes: { audioLanguage?: string; subtitleLanguage?: string; liveFormat?: string; screensaverMinutes?: number; videoFit?: string; subtitleScale?: number; subtitleBackground?: boolean; controlsSeconds?: number; subtitleBandDarkness?: number; subtitleOutline?: boolean; subtitleLift?: number; textSize?: number; trailers?: string }): void {
    for (const k of Object.keys(changes) as (keyof typeof changes)[]) {
      const v = changes[k];
      if (v !== undefined) localStorage.setItem(k, String(v));
    }
    this.notify();
  }

  /** What a backup or sync carries. */
  toJson(): Record<string, string | number | boolean> {
    return {
      audioLanguage: this.audioLanguage,
      subtitleLanguage: this.subtitleLanguage,
      liveFormat: this.liveFormat,
      subtitleScale: this.subtitleScale,
      subtitleBackground: this.subtitleBackground,
      subtitleBandDarkness: this.subtitleBandDarkness,
      subtitleOutline: this.subtitleOutline,
      subtitleLift: this.subtitleLift,
      videoFit: this.videoFit,
    };
  }

  /** Takes the preferences of a backup; unknown or missing ones are left alone. */
  restore(j: Record<string, unknown>): void {
    const pick = (k: string) => (typeof j[k] === 'string' ? (j[k] as string) : undefined);
    this.set({
      audioLanguage: pick('audioLanguage'),
      subtitleLanguage: pick('subtitleLanguage'),
      liveFormat: pick('liveFormat'),
      // Each by its type: a damaged backup does not fail
      subtitleScale: typeof j.subtitleScale === 'number' ? j.subtitleScale : undefined,
      subtitleBackground: typeof j.subtitleBackground === 'boolean' ? j.subtitleBackground : undefined,
      subtitleBandDarkness: typeof j.subtitleBandDarkness === 'number' ? j.subtitleBandDarkness : undefined,
      subtitleOutline: typeof j.subtitleOutline === 'boolean' ? j.subtitleOutline : undefined,
      subtitleLift: typeof j.subtitleLift === 'number' ? j.subtitleLift : undefined,
      videoFit: pick('videoFit'),
    });
  }
}

export const settings = new AppSettings();
