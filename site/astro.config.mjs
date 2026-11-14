import { defineConfig } from 'astro/config';

export default defineConfig({
  // Set SITE_URL once the site has a domain: canonical links and social previews need it
  site: process.env.SITE_URL || undefined,
  output: 'static',
  i18n: {
    defaultLocale: 'en',
    locales: ['en', 'es'],
    routing: { prefixDefaultLocale: false },
  },
});
