// A movie's full record (get_vod_info), asked once per movie in a session for what browsing shows
// before its page opens: the hero's backdrop and its trailer (app/lib/ui/catalog.dart: _backdrops;
// app/lib/ui/trailer.dart: movieTrailer). Movie listings carry neither.
import { Movie } from './models';
import { ContentSource } from './source';

const records = new WeakMap<ContentSource, Record<string, Promise<Movie>>>();

/** [movie] completed with its full record; the listing itself when the source has none or it fails. */
export function fullMovie(source: ContentSource, movie: Movie): Promise<Movie> {
  if (!source.movieDetail) return Promise.resolve(movie);
  let known = records.get(source);
  if (!known) records.set(source, (known = {}));
  if (!(movie.id in known)) known[movie.id] = source.movieDetail(movie).catch(() => movie);
  return known[movie.id];
}

/** The backdrop of a provider's movie: its own when the listing has one, else the full record's. */
export function movieBackdrop(source: ContentSource, movie: Movie): Promise<string | null> {
  if (movie.backdrop) return Promise.resolve(movie.backdrop);
  return fullMovie(source, movie).then((m) => m.backdrop || null);
}
