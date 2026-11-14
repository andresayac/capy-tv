// The HTTP client for a provider's panel, lists, guides and images: one that takes the certificates
// it cannot check, as the player does with its streams (see provider_client.dart). A browser keeps
// its own rules, which no page can change: there it is the usual client.
export 'provider_http_native.dart' if (dart.library.js_interop) 'provider_http_web.dart';
