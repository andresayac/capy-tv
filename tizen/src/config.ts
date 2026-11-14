// What the build is given from the repository's .env (scripts/build.mjs), as the Flutter app takes
// it with --dart-define. Nothing here is written in the code.
declare const __SYNC_SERVER__: string;
declare const __AI_MODEL__: string;
declare const __AI_BASE_URL__: string;
declare const __AI_API_KEY__: string;

/** The sync server the sign-in form starts with (SYNC_SERVER), or ''. */
export const DEFAULT_SERVER = typeof __SYNC_SERVER__ === 'string' ? __SYNC_SERVER__ : '';

/**
 * The language model built into this version (AI_MODEL, AI_BASE_URL and AI_API_KEY), so a family
 * gets recommendations without setting anything up; model '' for none (app/lib/data/recommender.dart).
 */
export const BUILT_IN_AI = {
  model: typeof __AI_MODEL__ === 'string' ? __AI_MODEL__ : '',
  baseUrl: typeof __AI_BASE_URL__ === 'string' ? __AI_BASE_URL__ : '',
  apiKey: typeof __AI_API_KEY__ === 'string' ? __AI_API_KEY__ : '',
};
