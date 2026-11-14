// What the model puts for a name the panel did not send, said in the app's language
// (app/lib/ui/common.dart: categoryLabel, episodeName). The markers stay in the data, read in a
// worker without the strings, and an M3U group's is its category's id too.
import { cleanEpisodeTitle, Episode, ungrouped, untitled, untitledEpisode } from '../data/models';
import { displayCategoryName } from '../data/names';
import { t } from '../i18n';

/** A category's name as shown: the provider's, tidied, or the app's words for one it did not name. */
export function categoryLabel(raw: string): string {
  if (raw === ungrouped) return t('ungrouped');
  if (raw === untitled) return t('untitled');
  return displayCategoryName(raw);
}

/** An episode's own title, without the series' name; null when the panel sent none. */
export function episodeName(e: Episode, seriesName: string): string | null {
  const name = cleanEpisodeTitle(e, seriesName);
  return name === untitledEpisode ? null : name;
}

/** "S1 · E3  Its title", or "S1 · E3" for one with none. */
export function episodeSubtitle(e: Episode, seriesName: string): string {
  const name = episodeName(e, seriesName);
  return name === null ? `S${e.season} · E${e.number}` : `S${e.season} · E${e.number}  ${name}`;
}
