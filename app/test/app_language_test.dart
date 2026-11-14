// The app's language: the device's by default, or the one chosen in Settings, kept between starts
// and followed by what speaks without a screen.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/app_language.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => appLanguage.value = '');

  test('chosen, it is kept and taken at the next start; none follows the device', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    expect(settings.language, '');
    expect(appLanguage.value, '');

    await settings.set(language: 'es');
    expect(appLocale.languageCode, 'es');
    appLanguage.value = '';
    await AppSettings.load(); // the next start
    expect(appLanguage.value, 'es');

    await settings.set(language: '');
    expect(appLocale.languageCode, isIn(['en', PlatformDispatcher.instance.locale.languageCode]));
  });

  test('each language is listed in its own words', () {
    expect(lookupAppLocalizations(const Locale('en')).languageSelf, 'English');
    expect(lookupAppLocalizations(const Locale('es')).languageSelf, 'Español');
  });

  test("TMDB's language: the app's, with the device's country only for the device's own", () {
    expect(tmdbLanguage(const Locale('es', 'CO')), 'es-CO');
    expect(tmdbLanguage(const Locale('es')), 'es');
    expect(tmdbLanguage(const Locale('fr', 'FR')), 'en');
  });
}
