// The one place the site links out to the project
export const GITHUB_URL = 'https://github.com/andresayac/capy-tv';

/** A path of this site, under the path it is published at (BASE_PATH, such as /capy-tv on GitHub Pages). */
export const local = (path: string): string => import.meta.env.BASE_URL.replace(/\/?$/, '/') + path.replace(/^\//, '');
