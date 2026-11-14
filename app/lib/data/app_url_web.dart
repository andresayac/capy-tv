// Addresses for the app in a browser: through the local proxy.
//
// Why: a page can only read another server's bytes if that server allows it (CORS), and IPTV
// panels' picture hosts very often do not — nor do the nodes their streams redirect to. That last
// one matters for video because a player that demuxes the file itself must `fetch` it (movi-player
// does, to offer the stream's audio languages). tools/img-proxy.mjs fetches server-side, where the
// rule does not apply, and passes the answer on with the headers a page needs.
//
// The proxy's address is chosen at run time, not at build time, because it depends on where the
// page is opened from: `127.0.0.1:8093` is this computer for a browser on this computer, and the
// visitor's own machine for anyone else (a phone, or a tunnel). In this order:
//
//  1. ?imgproxy=<prefix> in the page's address, remembered in localStorage for the next visit, so
//     one build serves both localhost and a tunnel:
//         https://<tunnel>/?imgproxy=/i        (the proxy is forwarded too, same origin)
//     The video one is worked out from it: `/i` → `/v`.
//  2. --dart-define=IMG_PROXY=<prefix> at build time.
//  3. Nothing: the addresses are left alone, as on the native platforms.
import 'dart:js_interop';

@JS('localStorage.getItem')
external JSString? _getItem(JSString key);

@JS('localStorage.setItem')
external void _setItem(JSString key, JSString value);

@JS('localStorage.removeItem')
external void _removeItem(JSString key);

const _key = 'imgProxy';

/// The address the build was made with, if any.
const _built = String.fromEnvironment('IMG_PROXY');

/// What the page's address asks for, remembered; null where it says nothing.
String? _asked() {
  try {
    final search = Uri.base.query;
    if (!search.contains('imgproxy=')) return null;
    final value = Uri.base.queryParameters['imgproxy'] ?? '';
    if (value.isEmpty || value == 'off') {
      _removeItem(_key.toJS);
      return '';
    }
    _setItem(_key.toJS, value.toJS);
    return value;
  } on Object {
    return null; // no storage, no address: the build's own
  }
}

String? _kept() {
  try {
    return _getItem(_key.toJS)?.toDart;
  } on Object {
    return null;
  }
}

/// The prefix every remote image goes through; '' for none.
String get imageProxy {
  final asked = _asked();
  if (asked != null) return asked;
  final kept = _kept();
  if (kept != null && kept.isNotEmpty) return kept;
  return _built;
}

/// The same proxy for streams: the image path with its last segment changed to "/v".
String get videoProxy {
  final images = imageProxy;
  if (images.isEmpty) return '';
  if (images.endsWith('/i')) return '${images.substring(0, images.length - 2)}/v';
  return images;
}

String _through(String proxy, String url) {
  if (proxy.isEmpty || url.isEmpty) return url;
  if (url.startsWith(proxy)) return url; // already through it
  if (!url.startsWith('http://') && !url.startsWith('https://')) return url;
  // A bare "/i" or "/v" is this same origin: the host need not be said, and no mixed content
  final base = proxy.startsWith('/') ? Uri.base.origin : '';
  return '$base$proxy?u=${Uri.encodeComponent(url)}';
}

/// The address of an image.
String imageUrl(String url) => _through(imageProxy, url);

/// The address of a video stream, with the whole file readable and its ranges answered.
///
/// Only a file that is one file: an HLS playlist is left alone. Its pieces are named relative to
/// the manifest's own address, so sending the manifest through the proxy would point them at the
/// proxy's path, where nothing lives. And it does not need it: a <video> reads HLS without CORS
/// through the browser's own player, which is how the live channels play today.
String videoUrl(String url) {
  if (url.isEmpty) return url;
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  if (path.endsWith('.m3u8') || path.endsWith('.mpd')) return url;
  return _through(videoProxy, url);
}
