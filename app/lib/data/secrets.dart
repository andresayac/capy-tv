import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The system's secure storage, the same for all. On macOS the classic keychain: the other one needs
/// a provisioning profile, which this app does not have.
const appSecrets = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

/// The system's secure storage would not keep a password: the rest was saved.
class SecretsUnavailable implements Exception {
  const SecretsUnavailable();
}
