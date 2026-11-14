# Capy TV site

The project's public page, built with [Astro](https://astro.build) as plain static files. English
is at `/` and Spanish at `/es/`; every text lives in `src/i18n/*.json`, one file per language.

```sh
npm install
npm run dev       # http://localhost:4321
npm run build     # dist/, ready for any static host
```

`SITE_URL=https://your.domain npm run build` adds the canonical link once the site has a domain.
The GitHub address the page links to is in `src/config.ts`.

## Screenshots and posters

The page only shows made-up content, never a real provider's or a studio's artwork. `demo/` holds
a catalog of invented movies, series and channels, its artwork, and a pretend Xtream panel that
serves it on this computer. To take the app's screenshots again after changing its screens:

```sh
npm run demo:art        # needs Edge and access to Google Fonts; also redraws src/assets/posters
npm run demo:provider   # leave it running

cd ../app
SITE_SHOTS=1 flutter test test/site_shots_test.dart   # writes src/assets/shots/{en,es}
```
