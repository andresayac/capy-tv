import { defineConfig } from 'astro/config';

export default defineConfig({
  // Set SITE_URL once the site has a domain: canonical links and social previews need it
  site: process.env.SITE_URL || undefined,
  // The path it is published under, when not a domain's root: /capy-tv on GitHub Pages
  base: process.env.BASE_PATH || '/',
  output: 'static',
  i18n: {
    defaultLocale: 'en',
    locales: ['en', 'es'],
    routing: { prefixDefaultLocale: false },
  },
});
