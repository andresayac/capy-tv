// A pretend Xtream Codes panel serving the demo catalog, on this computer only, for taking the
// site's screenshots. The username picks the catalog's language: "en" or "es".
//
//   npm run demo:provider
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  channels, liveCategories, movieCategories, movies, programmes, seriesCategories, shows, slug,
} from './catalog.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8091);
const ROOT = `http://127.0.0.1:${PORT}`;
const ART = {
  posters: path.join(HERE, '..', 'src', 'assets', 'posters'),
  backdrops: path.join(HERE, 'art', 'backdrops'),
  logos: path.join(HERE, 'art', 'logos'),
};

const poster = (i) => `${ROOT}/art/posters/${i.art}.png`;
const backdrop = (i) => `${ROOT}/art/backdrops/${i.art}.png`;
const unix = (date) => Math.floor(date.getTime() / 1000);
const daysAgo = (n) => String(unix(new Date(Date.now() - n * 86400000)));

const noPlot = {
  en: 'A made-up title from the demo catalog.',
  es: 'Un título inventado del catálogo de demostración.',
};
const plotOf = (i, lang) => i[lang] ?? noPlot[lang];
const categoryName = (list, key, lang) => list.find((c) => c.key === key)[lang];
const categoryId = (list, key) => list.find((c) => c.key === key).id;
const categories = (list, lang) => list.map((c) => ({ category_id: c.id, category_name: c[lang], parent_id: 0 }));

const movieId = (i) => 1000 + movies.indexOf(i);
const showId = (i) => 2000 + shows.indexOf(i);
const channelId = (i) => 3000 + channels.indexOf(i);

const movieJson = (m, lang) => ({
  num: movieId(m),
  name: m.title,
  title: m.title,
  stream_type: 'movie',
  stream_id: movieId(m),
  stream_icon: poster(m),
  backdrop_path: [backdrop(m)],
  rating: m.rating,
  year: m.year,
  plot: plotOf(m, lang),
  genre: categoryName(movieCategories, m.cat === 'uhd' ? 'scifi' : m.cat, lang),
  added: daysAgo(movies.indexOf(m) * 3),
  category_id: categoryId(movieCategories, m.cat),
  container_extension: m.ext ?? 'mp4',
  duration_secs: 6300,
});

const showJson = (s, lang) => ({
  num: showId(s),
  name: s.title,
  title: s.title,
  series_id: showId(s),
  cover: poster(s),
  backdrop_path: [backdrop(s)],
  plot: plotOf(s, lang),
  genre: categoryName(seriesCategories, s.cat, lang),
  rating: s.rating,
  year: s.year,
  last_modified: daysAgo(shows.indexOf(s) * 2),
  episode_run_time: 44,
  category_id: categoryId(seriesCategories, s.cat),
});

const channelJson = (c) => ({
  num: channels.indexOf(c) + 1,
  name: c.name,
  stream_type: 'live',
  stream_id: channelId(c),
  stream_icon: `${ROOT}/art/logos/${c.art}.png`,
  epg_channel_id: slug(c.name),
  added: daysAgo(90),
  category_id: categoryId(liveCategories, c.cat),
  tv_archive: 0,
});

function seriesInfo(id, lang) {
  const s = shows.find((x) => showId(x) === Number(id));
  if (!s) return {};
  const episodeNames = {
    en: ['The Last Departure', 'Manifest', 'Night Crossing', 'Harbor Master', 'Fog Warning', 'Open Water'],
    es: ['La última salida', 'Manifiesto', 'Cruce nocturno', 'El capitán de puerto', 'Alerta de niebla', 'Mar abierto'],
  }[lang];
  const episodes = {};
  for (const season of [1, 2]) {
    episodes[season] = episodeNames.map((title, i) => ({
      id: `${id}${season}${i + 1}`,
      episode_num: i + 1,
      title,
      season,
      container_extension: 'mp4',
      info: { duration_secs: 2640, plot: noPlot[lang], movie_image: backdrop(s) },
    }));
  }
  return {
    seasons: [1, 2].map((n) => ({ season_number: n, name: `${lang === 'es' ? 'Temporada' : 'Season'} ${n}`, episode_count: 6, cover: poster(s) })),
    info: showJson(s, lang),
    episodes,
  };
}

function xmltv() {
  const stamp = (d) => `${d.toISOString().replace(/[-:T]/g, '').slice(0, 14)} +0000`;
  const escape = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const start = new Date(Math.floor(Date.now() / 1800000) * 1800000 - 6 * 3600000);
  let body = '';
  channels.forEach((c, n) => {
    const id = slug(c.name);
    body += `<channel id="${id}"><display-name>${c.name}</display-name></channel>`;
    const names = programmes[c.cat];
    let at = start;
    for (let i = 0; i < 28; i++) {
      const minutes = [30, 60, 60, 90, 30, 120][(i * 5 + n * 3) % 6];
      const end = new Date(at.getTime() + minutes * 60000);
      body += `<programme start="${stamp(at)}" stop="${stamp(end)}" channel="${id}"><title>${escape(names[(i + n) % names.length])}</title></programme>`;
      at = end;
    }
  });
  return `<?xml version="1.0" encoding="UTF-8"?><tv>${body}</tv>`;
}

// Stands in for this week's trends, matched to the catalog by title and year as the real ones are
function trending(lang) {
  const list = [...movies.filter((m) => !m.hidden).slice(0, 9), ...shows.slice(0, 7)];
  const turns = [];
  const films = list.filter((i) => movies.includes(i));
  const series = list.filter((i) => shows.includes(i));
  for (let i = 0; i < Math.max(films.length, series.length); i++) {
    if (films[i]) turns.push(films[i]);
    if (series[i]) turns.push(series[i]);
  }
  return turns.map((i, n) => ({
    series: shows.includes(i),
    tmdbId: 500000 + n,
    title: i.title,
    originalTitle: i.title,
    year: i.year,
    rating: i.rating,
    poster: poster(i),
    backdrop: backdrop(i),
    overview: plotOf(i, lang),
  }));
}

function panel(query) {
  const lang = query.get('username') === 'es' ? 'es' : 'en';
  const now = new Date();
  switch (query.get('action')) {
    case 'get_live_categories': return categories(liveCategories, lang);
    case 'get_vod_categories': return categories(movieCategories, lang);
    case 'get_series_categories': return categories(seriesCategories, lang);
    case 'get_live_streams': return channels.map(channelJson);
    case 'get_vod_streams': return movies.map((m) => movieJson(m, lang));
    case 'get_series': return shows.map((s) => showJson(s, lang));
    case 'get_series_info': return seriesInfo(query.get('series_id'), lang);
    case 'get_short_epg': return { epg_listings: [] };
    default:
      return {
        user_info: { username: query.get('username'), auth: 1, status: 'Active', exp_date: String(unix(now) + 31536000), is_trial: '0', active_cons: '0', max_connections: '1', allowed_output_formats: ['m3u8', 'ts'] },
        server_info: { url: '127.0.0.1', port: String(PORT), server_protocol: 'http', timezone: 'UTC', timestamp_now: unix(now), time_now: now.toISOString().slice(0, 19).replace('T', ' ') },
      };
  }
}

http
  .createServer((req, res) => {
    const url = new URL(req.url, ROOT);
    const json = (data) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(data));
    };
    if (url.pathname === '/player_api.php') return json(panel(url.searchParams));
    if (url.pathname === '/trending') return json(trending(url.searchParams.get('lang') === 'es' ? 'es' : 'en'));
    if (url.pathname === '/xmltv.php') {
      res.writeHead(200, { 'Content-Type': 'application/xml' });
      return res.end(xmltv());
    }
    const art = /^\/art\/(posters|backdrops|logos)\/([a-z0-9-]+\.png)$/.exec(url.pathname);
    const file = art && path.join(ART[art[1]], art[2]);
    if (file && fs.existsSync(file)) {
      res.writeHead(200, { 'Content-Type': 'image/png' });
      return fs.createReadStream(file).pipe(res);
    }
    res.writeHead(404);
    res.end();
  })
  .listen(PORT, '127.0.0.1', () => console.log(`Demo provider at ${ROOT}`));
