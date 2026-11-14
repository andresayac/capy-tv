// A provider's HTTP client on a device. See provider_http.dart.
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'provider_client.dart';

/// For a provider's panel, lists, guides and images: a certificate it cannot check (self-signed,
/// expired, for another name) is taken, as the player takes it for the channels themselves. A
/// panel at https with such a certificate would otherwise refuse to sign in while its channels
/// play. Sync, TMDB, the language model and updates keep checking theirs.
http.Client providerClient() {
  // One given with http.runWithClient (tests) stays: http.Client() answers it, and it is no IOClient
  final usual = http.Client();
  if (usual is! IOClient) return usual;
  usual.close();
  return IOClient(providerHttpClient());
}
