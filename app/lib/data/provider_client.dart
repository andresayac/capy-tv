import 'dart:io';

/// A connection to a provider (its panel, lists, guides, images, and the streams it records and
/// casts), made as mpv makes the one that plays them: a certificate it cannot check (self-signed,
/// expired, for another name) is accepted. Providers' often are such, and refusing it here would
/// only break what plays. The one place this is decided (provider_http.dart gives it as an http
/// client): sync, TMDB, the language model and updates check their certificates. Checking
/// providers' for real would be a setting per account that also told mpv (its tls-verify), not a
/// fingerprint kept at first use: they spread over hosts and renew.
HttpClient providerHttpClient({String? userAgent}) {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..badCertificateCallback = ((_, _, _) => true);
  if (userAgent != null) client.userAgent = userAgent;
  return client;
}
