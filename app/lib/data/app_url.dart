// Addresses for the app: images and, on the web, video.
//
// In a browser a page can only read from another server if that server allows it (CORS). IPTV
// panels' picture hosts very often do not, and the node a panel redirects a stream to almost never
// does — which matters because a player that has to demux a file itself (to offer its audio
// languages) must read it with `fetch`, not just hand the address to a <video>. So on the web both
// go through tools/img-proxy.mjs, which fetches server-side (no CORS there) and passes the answer
// on with the headers a page needs.
//
// Nothing else changes: the native builds keep the host's own addresses, where there is no such
// rule and a proxy would only add a hop.
export 'app_url_native.dart' if (dart.library.js_interop) 'app_url_web.dart';
