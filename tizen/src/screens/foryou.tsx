// Home's "Picked for <name>" (app/lib/ui/home_tab.dart, _ForYou): titles picked for the profile on
// screen by the language model set up in Settings (data/recommender.ts), each with why. The ones
// kept show at once, fresh ones replace them when they are due. Nothing without a service, in
// kids profiles, or before the profile has watched or listed anything.
import { useEffect, useState } from 'preact/hooks';
import { CatalogData } from '../data/catalog';
import { Movie, Series } from '../data/models';
import { profileStore } from '../data/profiles';
import { AiException, Pick, recommender } from '../data/recommender';
import { language, t } from '../i18n';
import { log } from '../log';
import { session } from '../session';
import { useNotifier } from '../ui/components';
import { ItemRail, movieCatalogItem, seriesCatalogItem } from './catalog';
import { displayName } from './profiles';

export function ForYouRail({ data }: { data: CatalogData }) {
  useNotifier(recommender);
  useNotifier(profileStore);
  const { library } = session();
  const service = recommender.service;
  const kids = !!profileStore.current.kids;
  const [picks, setPicks] = useState<Pick[]>([]);

  // Again for another profile's library, and from scratch when the service changes
  useEffect(() => {
    setPicks([]);
    if (kids || !service) return;
    let live = true;
    setPicks(recommender.kept(library, data));
    // The reasons in the app's language
    recommender.refresh(library, data, language === 'es' ? 'Spanish' : 'English').then(
      (fresh) => {
        if (fresh && live) setPicks(fresh);
      },
      (e) => log(`recommendations: ${e instanceof AiException ? e.message : e}`), // the ones kept stay
    );
    return () => {
      live = false;
    };
  }, [library, data, service, kids, library.clearedAt]);

  if (kids || !service || !picks.length) return null;
  const items = picks.map((p) => ({
    ...('extension' in p.item ? movieCatalogItem(p.item as Movie) : seriesCatalogItem(p.item as Series)),
    note: p.why || undefined,
  }));
  // The main profile has no name of its own: not "Picked for You"
  const p = profileStore.current;
  return <ItemRail title={p.name ? t('forYou', { name: displayName(p) }) : t('forYouMain')} items={items} />;
}
