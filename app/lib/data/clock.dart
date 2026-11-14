// How the app writes a time of day, the same everywhere: the guide, recordings, sync, the screensaver
// and what speaks without a screen (a recording's notification).
import 'dart:ui' show PlatformDispatcher;

import 'package:intl/intl.dart';

import '../platform.dart';

/// 12 or 24 hours as a phone or a TV has its clock set ([h24], else the device's own), whatever the
/// language would have (Spanish writes 24 hours, and a phone set to 12 got them all the same);
/// elsewhere as [locale]'s language writes it ("21:05", "9:05 PM").
DateFormat clockFormat(String locale, {bool? h24}) {
  if (isAndroid || isIOS) {
    return h24 ?? PlatformDispatcher.instance.alwaysUse24HourFormat
        ? DateFormat.Hm(locale)
        : DateFormat('h:mm a', locale);
  }
  return DateFormat.jm(locale);
}
