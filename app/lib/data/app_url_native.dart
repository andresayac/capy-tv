// Addresses for the app on the native platforms: the host's own, as given.
//
// On the web they go through a local proxy instead (app_url_web.dart), because a browser will not
// read from a server that does not allow it (CORS) and panels' media nodes almost never do.
// See app_url.dart.

/// The address of an image.
String imageUrl(String url) => url;

/// The address of a video stream. On the web, the one that gives the player the whole file with
/// CORS, so it can demux it (and offer its audio languages).
String videoUrl(String url) => url;
