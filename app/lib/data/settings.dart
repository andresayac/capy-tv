import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../device.dart';
import '../platform.dart';
import '../player/props.dart';
import 'app_language.dart';
import 'profiles.dart';

/// Language codes offered as preferences (ISO 639-2/T, as in the translations).
const preferenceLanguages = ['spa', 'eng', 'por', 'fra', 'deu', 'ita'];

/// Tags providers actually use for each language; mpv picks the first track matching any of them.
/// The tags streams mark a [code]'s tracks with ("es", "esp", "lat"...), for mpv's alang and slang.
String languageTagsFor(String code) => _languageTags[code] ?? code;

const _languageTags = {
  'spa': 'spa,es,esp,esa,lat,cas',
  'eng': 'eng,en',
  'por': 'por,pt,bra',
  'fra': 'fra,fre,fr',
  'deu': 'deu,ger,de',
  'ita': 'ita,it',
};

/// App-wide preferences.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static Future<AppSettings> load() async {
    final settings = AppSettings._(await SharedPreferences.getInstance());
    appLanguage.value = settings.language;
    return settings;
  }

  final SharedPreferences _prefs;

  /// Preferred audio language, '' = whatever the stream marks as default.
  String get audioLanguage => _prefs.getString('audioLanguage') ?? '';

  /// Preferred subtitle language, '' = stream default, 'off' = never show subtitles.
  String get subtitleLanguage => _prefs.getString('subtitleLanguage') ?? '';

  /// Live stream container for Xtream: 'ts' (most compatible) or 'm3u8'. A browser cannot open a
  /// raw live TS (see [opensRawLiveTs]), so there HLS is the only one that plays.
  String get liveFormat => _prefs.getString('liveFormat') ?? (opensRawLiveTs ? 'ts' : 'm3u8');

  /// Video decoding on Android: 'hardware' (the device's decoder drawing straight to the screen,
  /// smooth even on modest TV boxes) or 'software' (slower, but plays codecs the chip lacks, and
  /// draws subtitles that are pictures, which nothing can over the hardware decoder's own screen).
  String get decoder => _prefs.getString('decoder') ?? 'hardware';

  /// Minutes without a key, a tap or the mouse before the screensaver shows; 0 is never. TVs and
  /// computers have it after five; phones sleep by themselves.
  int get screensaverMinutes => _prefs.getInt('screensaverMinutes') ?? (isTv || !_phone ? 5 : 0);

  static bool get _phone => isAndroid || isIOS;

  /// How the picture fills the screen: 'contain' (all of it, bars where the shapes differ),
  /// 'cover' (zoomed to fill, edges cut), 'fill' (stretched), or a shape of its own drawn whole:
  /// '16:9', '4:3', '21:9'.
  String get videoFit => _prefs.getString('videoFit') ?? 'contain';

  /// Subtitle text size, in percent of the usual.
  int get subtitleScale => _prefs.getInt('subtitleScale') ?? 100;

  /// A dark band behind subtitle text, for reading it on bright pictures.
  bool get subtitleBackground => _prefs.getBool('subtitleBackground') ?? false;

  /// How dark that band is, in percent.
  int get subtitleBandDarkness => _prefs.getInt('subtitleBandDarkness') ?? 70;

  /// A sharp black outline around subtitle text, instead of the soft shadow.
  bool get subtitleOutline => _prefs.getBool('subtitleOutline') ?? false;

  /// How far above the bottom subtitles sit, in percent of the screen's height (0, 10 or 20).
  int get subtitleLift => _prefs.getInt('subtitleLift') ?? 0;

  /// Phones and tablets: what plays goes on, sound only, with the app in the background or the
  /// screen off, with its controls in a notification (see BackgroundPlay).
  bool get backgroundPlay => _prefs.getBool('backgroundPlay') ?? false;

  /// Nothing moves by itself: the poster wall, the backdrops' zoom, the carousel, the trailers. As
  /// the system's own setting, which Windows and most TVs never pass on to the app.
  bool get reduceMotion => _prefs.getBool('reduceMotion') ?? false;

  /// The app's text size, in percent; 0 is the device's own. For a TV whose system has no such
  /// setting, or anyone who wants the app's larger than the rest. Each device's own.
  int get textSize => _prefs.getInt('textSize') ?? 0;

  /// Seconds the player's controls stay after the last key or touch; 0 is the usual moment (3.5 s).
  /// Longer for whoever needs more time to find a button. Each device's own, as the screensaver.
  int get controlsSeconds => _prefs.getInt('controlsSeconds') ?? 0;

  /// Whether the trailers behind the carousel and title pages play by themselves: 'always', 'wifi'
  /// (not on mobile data, where they would spend it unasked) or 'never'.
  String get trailers => _prefs.getString('trailers') ?? 'always';

  /// Minutes a scheduled recording starts before its programme (0, 1 or 5) and goes on after it
  /// (2, 5, 15 or 30): a match with extra time, a channel running late. Read by ScheduledRecordings.
  int get recordEarly => _prefs.getInt('recordEarly') ?? 1;
  int get recordLate => _prefs.getInt('recordLate') ?? 2;

  /// The app's language, as its code; '' follows the device. Also in [appLanguage], for what
  /// speaks without a screen (the guide's titles, a recording's notification).
  String get language => _prefs.getString('language') ?? '';

  /// The Live TV category [profile] last opened in [playlist]: where Live TV opens next time. Kept
  /// without telling the screens: nothing shown changes with it.
  String? lastLiveCategory(String playlist, String profile) => _prefs.getString('live.category.$playlist.$profile');

  void keepLiveCategory(String playlist, String profile, String category) =>
      unawaited(_prefs.setString('live.category.$playlist.$profile', category));

  Future<void> set({
    String? audioLanguage,
    String? subtitleLanguage,
    String? liveFormat,
    String? decoder,
    int? screensaverMinutes,
    String? videoFit,
    int? subtitleScale,
    bool? subtitleBackground,
    int? subtitleBandDarkness,
    bool? subtitleOutline,
    int? subtitleLift,
    bool? backgroundPlay,
    bool? reduceMotion,
    int? controlsSeconds,
    int? textSize,
    String? trailers,
    int? recordEarly,
    int? recordLate,
    String? language,
  }) async {
    if (language != null) {
      await _prefs.setString('language', language);
      appLanguage.value = language;
    }
    if (recordEarly != null) await _prefs.setInt('recordEarly', recordEarly);
    if (recordLate != null) await _prefs.setInt('recordLate', recordLate);
    if (trailers != null) await _prefs.setString('trailers', trailers);
    if (backgroundPlay != null) await _prefs.setBool('backgroundPlay', backgroundPlay);
    if (reduceMotion != null) await _prefs.setBool('reduceMotion', reduceMotion);
    if (controlsSeconds != null) await _prefs.setInt('controlsSeconds', controlsSeconds);
    if (textSize != null) await _prefs.setInt('textSize', textSize);
    if (videoFit != null) await _prefs.setString('videoFit', videoFit);
    if (subtitleScale != null) await _prefs.setInt('subtitleScale', subtitleScale);
    if (subtitleBackground != null) await _prefs.setBool('subtitleBackground', subtitleBackground);
    if (subtitleBandDarkness != null) await _prefs.setInt('subtitleBandDarkness', subtitleBandDarkness);
    if (subtitleOutline != null) await _prefs.setBool('subtitleOutline', subtitleOutline);
    if (subtitleLift != null) await _prefs.setInt('subtitleLift', subtitleLift);
    if (screensaverMinutes != null) await _prefs.setInt('screensaverMinutes', screensaverMinutes);
    if (audioLanguage != null) await _prefs.setString('audioLanguage', audioLanguage);
    if (subtitleLanguage != null) await _prefs.setString('subtitleLanguage', subtitleLanguage);
    if (liveFormat != null) await _prefs.setString('liveFormat', liveFormat);
    if (decoder != null) await _prefs.setString('decoder', decoder);
    notifyListeners();
  }

  /// What a backup carries. Not the decoder, the screensaver nor background play: they suit
  /// each device.
  Map<String, Object> toJson() => {
    'audioLanguage': audioLanguage,
    'subtitleLanguage': subtitleLanguage,
    'liveFormat': liveFormat,
    'subtitleScale': subtitleScale,
    'subtitleBackground': subtitleBackground,
    'subtitleBandDarkness': subtitleBandDarkness,
    'subtitleOutline': subtitleOutline,
    'subtitleLift': subtitleLift,
    'videoFit': videoFit,
  };

  /// Takes the preferences of a backup ([toJson]); unknown or missing ones are left alone.
  Future<void> restore(Map<String, dynamic> j) => set(
    audioLanguage: j['audioLanguage'] as String?,
    subtitleLanguage: j['subtitleLanguage'] as String?,
    liveFormat: j['liveFormat'] as String?,
    // Each by its type: a damaged backup does not fail
    subtitleScale: j['subtitleScale'] is int ? j['subtitleScale'] as int : null,
    subtitleBackground: j['subtitleBackground'] is bool ? j['subtitleBackground'] as bool : null,
    subtitleBandDarkness: j['subtitleBandDarkness'] is int ? j['subtitleBandDarkness'] as int : null,
    subtitleOutline: j['subtitleOutline'] is bool ? j['subtitleOutline'] as bool : null,
    subtitleLift: j['subtitleLift'] is int ? j['subtitleLift'] as int : null,
    videoFit: j['videoFit'] is String ? j['videoFit'] as String : null,
  );

  /// Applies the language preferences to a player before it opens anything: the profile's own,
  /// where it has them, else these.
  Future<void> applyTo(Player player) async {
    final profile = ProfileStore.instance.current;
    final audio = profile.audioLanguage ?? audioLanguage, subtitles = profile.subtitleLanguage ?? subtitleLanguage;
    if (audio.isNotEmpty) await setPlayerProperty(player, 'alang', languageTagsFor(audio));
    if (subtitles == 'off') {
      await setPlayerProperty(player, 'sid', 'no');
    } else if (subtitles.isNotEmpty) {
      await setPlayerProperty(player, 'slang', languageTagsFor(subtitles));
      await setPlayerProperty(player, 'subs-fallback', 'no'); // not another language's instead
    } else {
      // What the stream marks, and nothing else: media_kit's default took any full track, English
      // subtitles over a Spanish dub
      await setPlayerProperty(player, 'subs-fallback', 'default');
    }
  }
}

class SettingsScope extends InheritedNotifier<AppSettings> {
  const SettingsScope({super.key, required AppSettings settings, required super.child}) : super(notifier: settings);

  static AppSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsScope>()?.notifier;

  static AppSettings of(BuildContext context) => maybeOf(context)!;

  /// As [maybeOf], read once without rebuilding on changes: for a timer, or a state starting up.
  static AppSettings? read(BuildContext context) => context.getInheritedWidgetOfExactType<SettingsScope>()?.notifier;
}
