// The demo catalog behind the site's screenshots. Every title, channel and programme is made up,
// so the pictures show the app with nobody's content.

export const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

export const movieCategories = [
  { id: '10', key: 'action', en: 'Action', es: 'Acción' },
  { id: '11', key: 'drama', en: 'Drama', es: 'Drama' },
  { id: '12', key: 'scifi', en: 'Science fiction', es: 'Ciencia ficción' },
  { id: '13', key: 'thriller', en: 'Thriller', es: 'Suspenso' },
  { id: '14', key: 'comedy', en: 'Comedy', es: 'Comedia' },
  { id: '15', key: 'family', en: 'Family', es: 'Familia' },
  { id: '16', key: 'uhd', en: '4K', es: '4K' },
];

export const seriesCategories = [
  { id: '20', key: 'drama', en: 'Drama', es: 'Drama' },
  { id: '21', key: 'crime', en: 'Crime', es: 'Crimen' },
  { id: '22', key: 'comedy', en: 'Comedy', es: 'Comedia' },
  { id: '23', key: 'kids', en: 'Kids', es: 'Infantil' },
];

export const liveCategories = [
  { id: '30', key: 'general', en: 'General', es: 'General' },
  { id: '31', key: 'sports', en: 'Sports', es: 'Deportes' },
  { id: '32', key: 'movies', en: 'Movies', es: 'Películas' },
  { id: '33', key: 'kids', en: 'Kids', es: 'Infantil' },
];

const movie = (title, year, rating, cat, motif, palette, font, extra = {}) => ({
  title, year, rating, cat, motif, palette, font, art: slug(title), ...extra,
});

export const movies = [
  movie('Static Bloom', 2025, 8.4, 'scifi', 'bloom', 'violet', 'syne', {
    en: 'A botanist hears a pattern in the static of a dead satellite, and something in her greenhouse starts answering.',
    es: 'Una botánica oye un patrón en la estática de un satélite muerto, y algo en su invernadero empieza a responder.',
  }),
  movie('Static Bloom LAT', 2025, 8.4, 'scifi', 'bloom', 'violet', 'syne', { art: 'static-bloom', hidden: true }),
  movie('Static Bloom 4K', 2025, 8.4, 'uhd', 'bloom', 'violet', 'syne', { art: 'static-bloom', hidden: true, ext: 'mkv' }),
  movie('Orbit of Quiet Things', 2025, 8.6, 'scifi', 'planet', 'ocean', 'syne', {
    en: 'The last crew of a research station has one week to decide who goes home.',
    es: 'La última tripulación de una estación de investigación tiene una semana para decidir quién vuelve a casa.',
  }),
  movie('Neon Harvest', 2025, 7.8, 'action', 'road', 'cherry', 'anton', {
    en: 'A getaway driver takes one more job across a desert that glows at night.',
    es: 'Una conductora de fugas acepta un último trabajo a través de un desierto que brilla de noche.',
  }),
  movie('The Salt Orchard', 2024, 7.9, 'drama', 'hills', 'teal', 'dmserif', {
    en: 'Three sisters return to the family farm the sea is slowly taking back.',
    es: 'Tres hermanas vuelven a la finca familiar que el mar está recuperando poco a poco.',
  }),
  movie('Red Door, Blue Door', 2024, 8.1, 'thriller', 'door', 'ink', 'archivo'),
  movie('Keeper of Small Fires', 2024, 8.2, 'drama', 'figure', 'ember', 'playfair'),
  movie('Wolves of Avenue K', 2024, 7.6, 'action', 'skyline', 'plum', 'anton'),
  movie('The Tuesday Heist', 2025, 7.4, 'action', 'bars', 'mustard', 'bebas'),
  movie('Paper Harbor', 2023, 7.5, 'drama', 'boat', 'sand', 'playfair'),
  movie('Seven Rooms of Rain', 2023, 8.0, 'thriller', 'rain', 'ink', 'dmserif'),
  movie('The Glass Cartographer', 2025, 8.0, 'scifi', 'eye', 'teal', 'abril'),
  movie('Low Tide Club', 2023, 7.1, 'comedy', 'waves', 'sky', 'righteous'),
  movie('Midnight Laundromat', 2024, 7.2, 'comedy', 'rings', 'rose', 'righteous'),
  movie('Zero Gravity Bakery', 2025, 7.7, 'comedy', 'planet', 'mustard', 'bungee'),
  movie('Copper Sky', 2022, 7.3, 'drama', 'sun', 'ember', 'abril'),
  movie('Mile Marker Nine', 2023, 7.4, 'thriller', 'road', 'forest', 'bebas'),
  movie('Hollow Creek Ranch', 2022, 6.9, 'drama', 'sun', 'cream', 'dmserif'),
  movie('Cinder and Rye', 2024, 7.6, 'drama', 'bloom', 'rose', 'playfair'),
  movie('The Sundial Thief', 2023, 7.5, 'action', 'burst', 'tangerine', 'anton'),
  movie('North of Yesterday', 2025, 8.3, 'drama', 'hills', 'ocean', 'dmserif'),
  movie('The Cartel of Bees', 2024, 7.8, 'thriller', 'burst', 'mustard', 'archivo'),
  movie('A Quiet Kind of Loud', 2025, 7.9, 'comedy', 'rings', 'plum', 'syne'),
  movie('Capy Goes to Space', 2025, 8.3, 'family', 'capyspace', 'ocean', 'righteous'),
  movie('Capy and the Big Melon', 2024, 7.9, 'family', 'capy', 'mint', 'righteous'),
  movie('Tiny Thunder Goes to School', 2023, 7.0, 'family', 'burst', 'cherry', 'bungee'),
  movie('The Lantern Parade', 2024, 7.8, 'family', 'waves', 'violet', 'righteous'),
  movie('Harbor Lights at Noon', 2022, 7.0, 'drama', 'boat', 'teal', 'abril'),
  movie('Ninth Floor Orchestra', 2025, 7.7, 'comedy', 'skyline', 'rose', 'bebas'),
  movie('Glasshouse Summer', 2023, 7.2, 'comedy', 'figure', 'mint', 'playfair'),
];

const series = (title, year, rating, cat, motif, palette, font, extra = {}) => ({
  title, year, rating, cat, motif, palette, font, art: slug(title), ...extra,
});

export const shows = [
  series('Ferry Line 12', 2025, 8.7, 'drama', 'waves', 'ink', 'bebas', {
    en: 'Every night the last ferry carries a passenger who was never on the list.',
    es: 'Cada noche, el último ferry lleva a un pasajero que nunca estuvo en la lista.',
  }),
  series('Mercury Street', 2024, 8.2, 'crime', 'skyline', 'violet', 'anton', {
    en: 'Two detectives, one street, and a case that keeps reopening itself.',
    es: 'Dos detectives, una calle y un caso que no deja de reabrirse.',
  }),
  series('Two Kitchens', 2025, 7.9, 'comedy', 'bars', 'cream', 'playfair'),
  series('Deep Field', 2024, 8.5, 'drama', 'planet', 'plum', 'syne'),
  series('House of Tides', 2023, 8.0, 'drama', 'hills', 'sky', 'dmserif'),
  series('Substitute Gods', 2025, 8.1, 'comedy', 'burst', 'tangerine', 'bungee'),
  series('Lost Signal Bureau', 2024, 7.8, 'crime', 'rings', 'forest', 'archivo'),
  series('Small Town Satellites', 2023, 7.6, 'comedy', 'planet', 'sand', 'righteous'),
  series('Atlas of Strange Weather', 2025, 8.3, 'drama', 'rain', 'teal', 'abril'),
  series('Orchard Road Detectives', 2022, 7.4, 'crime', 'door', 'ember', 'bebas'),
  series("Capy's Garden", 2025, 8.4, 'kids', 'capy', 'sky', 'righteous'),
  series('Pixel Farm', 2024, 7.7, 'kids', 'bars', 'mint', 'bungee'),
];

const channel = (name, cat, code, palette) => ({ name, cat, code, palette, art: slug(name) });

export const channels = [
  channel('Demo News', 'general', 'N', 'cherry'),
  channel('Demo One', 'general', '1', 'ocean'),
  channel('Demo Docs', 'general', 'D', 'forest'),
  channel('Demo Travel', 'general', 'T', 'teal'),
  channel('Demo Food', 'general', 'F', 'mustard'),
  channel('Demo Music', 'general', 'M', 'violet'),
  channel('Demo Nature', 'general', 'NA', 'mint'),
  channel('Demo History', 'general', 'H', 'cream'),
  channel('Demo Science', 'general', 'SC', 'plum'),
  channel('Demo Culture', 'general', 'CU', 'rose'),
  channel('Demo Business', 'general', 'B', 'dusk'),
  channel('Demo Sports 1', 'sports', 'S1', 'ink'),
  channel('Demo Sports 2', 'sports', 'S2', 'ink'),
  channel('Demo Racing', 'sports', 'R', 'ember'),
  channel('Demo Cinema', 'movies', 'C', 'plum'),
  channel('Demo Classics', 'movies', 'CL', 'sand'),
  channel('Demo Kids', 'kids', 'K', 'sky'),
  channel('Demo Toons', 'kids', 'TN', 'rose'),
];

// What each kind of channel airs, in the guide
export const programmes = {
  general: ['Morning Bulletin', 'The Long Table', 'Open Roads', 'Market Day', 'Night Desk', 'Field Notes', 'City Hour', 'Weather Watch'],
  sports: ['Matchday Live', 'The Final Lap', 'Extra Time', 'Court Side', 'Season Review', 'Training Ground'],
  movies: ['Copper Sky', 'Paper Harbor', 'Seven Rooms of Rain', 'Mile Marker Nine', 'Hollow Creek Ranch'],
  kids: ["Capy's Garden", 'Pixel Farm', 'The Lantern Parade', 'Story Corner', 'Big Melon Time'],
};

export const palettes = {
  dusk: { bg: '#1d1a3a', a: '#ff6b4a', b: '#ffb347', c: '#6a4c93', ink: '#fff4e0' },
  teal: { bg: '#07393c', a: '#2c8c99', b: '#f0edee', c: '#0a5a60', ink: '#f0edee' },
  ember: { bg: '#2b0f0e', a: '#d9441f', b: '#f4a259', c: '#8c1c13', ink: '#ffe8d1' },
  mint: { bg: '#d8f3dc', a: '#2d6a4f', b: '#95d5b2', c: '#52b788', ink: '#1b4332' },
  mustard: { bg: '#f2c14e', a: '#d1495b', b: '#2e294e', c: '#f78154', ink: '#2e294e' },
  ink: { bg: '#0d1b2a', a: '#415a77', b: '#e0e1dd', c: '#1b263b', ink: '#e0e1dd' },
  rose: { bg: '#ffc2d1', a: '#c9184a', b: '#590d22', c: '#ff8fab', ink: '#590d22' },
  violet: { bg: '#240046', a: '#9d4edd', b: '#e0aaff', c: '#5a189a', ink: '#f3e8ff' },
  sand: { bg: '#eadfc9', a: '#c1121f', b: '#003049', c: '#669bbc', ink: '#003049' },
  forest: { bg: '#132a13', a: '#4f772d', b: '#ecf39e', c: '#31572c', ink: '#ecf39e' },
  ocean: { bg: '#03045e', a: '#00b4d8', b: '#caf0f8', c: '#0077b6', ink: '#caf0f8' },
  tangerine: { bg: '#ff7b00', a: '#ffea00', b: '#3a0ca3', c: '#ff5400', ink: '#1a0a3c' },
  plum: { bg: '#3c1642', a: '#1dd3b0', b: '#affc41', c: '#086375', ink: '#eafff5' },
  cream: { bg: '#fefae0', a: '#bc6c25', b: '#283618', c: '#dda15e', ink: '#283618' },
  cherry: { bg: '#b00000', a: '#ffba08', b: '#370617', c: '#f48c06', ink: '#fff3b0' },
  sky: { bg: '#a2d2ff', a: '#ff8fab', b: '#3d5a80', c: '#ffffff', ink: '#1d3557' },
};
