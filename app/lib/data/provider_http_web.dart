// A provider's HTTP client in a browser, which checks certificates itself. See provider_http.dart.
import 'package:http/http.dart' as http;

http.Client providerClient() => http.Client();
