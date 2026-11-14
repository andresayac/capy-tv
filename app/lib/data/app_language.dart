import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import 'models.dart';

/// The language chosen in Settings, as its code; '' follows the device. Set by AppSettings.
final appLanguage = ValueNotifier<String>('');

/// The language the app speaks: the one chosen, else the device's when the app has it, else
/// English. The device's country goes with its own language (TMDB's titles for that country).
Locale get appLocale {
  final device = PlatformDispatcher.instance.locale;
  final chosen = appLanguage.value;
  if (chosen.isNotEmpty) return chosen == device.languageCode ? device : Locale(chosen);
  return AppLocalizations.supportedLocales.any((l) => l.languageCode == device.languageCode)
      ? device
      : const Locale('en');
}

/// Keeps what speaks without a screen in the app's language: the name of what came without one.
void followAppLanguage() {
  void follow() => untitledName = lookupAppLocalizations(appLocale).untitled;
  follow();
  appLanguage.addListener(follow);
}

/// TMDB's language for [locale]: titles differ between countries ("es-MX", "es-ES"). The app's
/// languages only; any other gets English.
String tmdbLanguage(Locale locale) {
  final language = AppLocalizations.supportedLocales.any((l) => l.languageCode == locale.languageCode)
      ? locale.languageCode
      : 'en';
  final country = locale.countryCode ?? '';
  return RegExp(r'^[A-Z]{2}$').hasMatch(country) && language == locale.languageCode ? '$language-$country' : language;
}
