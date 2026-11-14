import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en'), Locale('es')];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Capy TV'**
  String get appTitle;

  /// No description provided for @playlists.
  ///
  /// In en, this message translates to:
  /// **'Playlists'**
  String get playlists;

  /// No description provided for @addPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Add playlist'**
  String get addPlaylist;

  /// No description provided for @playlistTypeXtream.
  ///
  /// In en, this message translates to:
  /// **'Username and password (Xtream)'**
  String get playlistTypeXtream;

  /// No description provided for @playlistTypeM3u.
  ///
  /// In en, this message translates to:
  /// **'Link (M3U)'**
  String get playlistTypeM3u;

  /// No description provided for @playlistKindXtream.
  ///
  /// In en, this message translates to:
  /// **'Xtream Codes'**
  String get playlistKindXtream;

  /// No description provided for @playlistName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get playlistName;

  /// No description provided for @serverUrl.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get serverUrl;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @m3uUrl.
  ///
  /// In en, this message translates to:
  /// **'M3U playlist URL'**
  String get m3uUrl;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deletePlaylistQuestion.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String deletePlaylistQuestion(String name);

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connecting;

  /// No description provided for @required.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get required;

  /// No description provided for @liveTv.
  ///
  /// In en, this message translates to:
  /// **'Live TV'**
  String get liveTv;

  /// No description provided for @movies.
  ///
  /// In en, this message translates to:
  /// **'Movies'**
  String get movies;

  /// No description provided for @series.
  ///
  /// In en, this message translates to:
  /// **'Series'**
  String get series;

  /// No description provided for @nothingHere.
  ///
  /// In en, this message translates to:
  /// **'Nothing here'**
  String get nothingHere;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @season.
  ///
  /// In en, this message translates to:
  /// **'Season {n}'**
  String season(int n);

  /// No description provided for @seasonSpecials.
  ///
  /// In en, this message translates to:
  /// **'Specials'**
  String get seasonSpecials;

  /// No description provided for @minutes.
  ///
  /// In en, this message translates to:
  /// **'{n} min'**
  String minutes(int n);

  /// No description provided for @status.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get status;

  /// No description provided for @expires.
  ///
  /// In en, this message translates to:
  /// **'Expires'**
  String get expires;

  /// No description provided for @neverExpires.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get neverExpires;

  /// No description provided for @connections.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get connections;

  /// No description provided for @connectionsValue.
  ///
  /// In en, this message translates to:
  /// **'{active} of {max} in use'**
  String connectionsValue(int active, int max);

  /// No description provided for @outputFormats.
  ///
  /// In en, this message translates to:
  /// **'Output formats'**
  String get outputFormats;

  /// No description provided for @serverTimezone.
  ///
  /// In en, this message translates to:
  /// **'Server time zone'**
  String get serverTimezone;

  /// No description provided for @providerMessage.
  ///
  /// In en, this message translates to:
  /// **'Message from the provider'**
  String get providerMessage;

  /// No description provided for @sentFrom.
  ///
  /// In en, this message translates to:
  /// **'Sent from {device}'**
  String sentFrom(String device);

  /// No description provided for @switchPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Switch playlist'**
  String get switchPlaylist;

  /// No description provided for @trialAccount.
  ///
  /// In en, this message translates to:
  /// **'Trial account'**
  String get trialAccount;

  /// No description provided for @nowPlaying.
  ///
  /// In en, this message translates to:
  /// **'Now'**
  String get nowPlaying;

  /// No description provided for @upNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get upNext;

  /// No description provided for @noGuide.
  ///
  /// In en, this message translates to:
  /// **'No guide data for this channel'**
  String get noGuide;

  /// No description provided for @catchupDays.
  ///
  /// In en, this message translates to:
  /// **'Earlier programmes: {n, plural, =1{1 day} other{{n} days}}'**
  String catchupDays(int n);

  /// No description provided for @audioAndSubtitles.
  ///
  /// In en, this message translates to:
  /// **'Audio & subtitles'**
  String get audioAndSubtitles;

  /// No description provided for @audio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get audio;

  /// No description provided for @subtitles.
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get subtitles;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// No description provided for @notAvailable.
  ///
  /// In en, this message translates to:
  /// **'Not available'**
  String get notAvailable;

  /// No description provided for @speed.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get speed;

  /// No description provided for @normalSpeed.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get normalSpeed;

  /// No description provided for @live.
  ///
  /// In en, this message translates to:
  /// **'LIVE'**
  String get live;

  /// No description provided for @trackN.
  ///
  /// In en, this message translates to:
  /// **'Track {n}'**
  String trackN(int n);

  /// No description provided for @languageName.
  ///
  /// In en, this message translates to:
  /// **'{code, select, spa{Spanish} eng{English} fra{French} deu{German} ita{Italian} por{Portuguese} jpn{Japanese} kor{Korean} zho{Chinese} ara{Arabic} rus{Russian} other{{code}}}'**
  String languageName(String code);

  /// No description provided for @listPartsMissing.
  ///
  /// In en, this message translates to:
  /// **'{names} did not answer: the lists stay as they were.'**
  String listPartsMissing(String names);

  /// No description provided for @errorBadAddress.
  ///
  /// In en, this message translates to:
  /// **'Check the server\'s address: it can\'t be one as written.'**
  String get errorBadAddress;

  /// No description provided for @errorWrongServer.
  ///
  /// In en, this message translates to:
  /// **'Check the server\'s address, the username and the password.'**
  String get errorWrongServer;

  /// No description provided for @errorProviderBusy.
  ///
  /// In en, this message translates to:
  /// **'Your provider is overloaded or down for a while. Try again in a few minutes.'**
  String get errorProviderBusy;

  /// No description provided for @errorNoSpace.
  ///
  /// In en, this message translates to:
  /// **'There is no room left on this device for the list. Free some space and try again.'**
  String get errorNoSpace;

  /// No description provided for @errorOffline.
  ///
  /// In en, this message translates to:
  /// **'This device seems to be offline. Check the Wi-Fi or the cable, then try again.'**
  String get errorOffline;

  /// No description provided for @errorDns.
  ///
  /// In en, this message translates to:
  /// **'The server\'s name couldn\'t be found. Check that this device is online and that the address is written right.'**
  String get errorDns;

  /// No description provided for @errorTls.
  ///
  /// In en, this message translates to:
  /// **'The secure connection to the server failed. Check this device\'s date and time: when they are wrong, no secure connection works.'**
  String get errorTls;

  /// No description provided for @errorUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t connect to the server. Check the address and your connection; if both are fine, the provider may be down.'**
  String get errorUnreachable;

  /// No description provided for @errorTimeout.
  ///
  /// In en, this message translates to:
  /// **'The server is not responding.'**
  String get errorTimeout;

  /// No description provided for @errorUnauthorized.
  ///
  /// In en, this message translates to:
  /// **'Wrong username or password, or the account is blocked.'**
  String get errorUnauthorized;

  /// No description provided for @errorInactive.
  ///
  /// In en, this message translates to:
  /// **'The account is not active ({status}). Ask your provider to renew or reactivate it.'**
  String errorInactive(String status);

  /// No description provided for @statusActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get statusActive;

  /// No description provided for @statusExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get statusExpired;

  /// No description provided for @statusBanned.
  ///
  /// In en, this message translates to:
  /// **'Banned'**
  String get statusBanned;

  /// No description provided for @statusDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get statusDisabled;

  /// No description provided for @statusTrial.
  ///
  /// In en, this message translates to:
  /// **'Trial'**
  String get statusTrial;

  /// No description provided for @statusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get statusUnknown;

  /// No description provided for @untitled.
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get untitled;

  /// No description provided for @ungrouped.
  ///
  /// In en, this message translates to:
  /// **'No category'**
  String get ungrouped;

  /// No description provided for @episodeNumber.
  ///
  /// In en, this message translates to:
  /// **'Episode {number}'**
  String episodeNumber(int number);

  /// No description provided for @errorHttp.
  ///
  /// In en, this message translates to:
  /// **'The server replied with error {code}. Try again in a while; if it goes on, ask your provider.'**
  String errorHttp(String code);

  /// No description provided for @errorBadResponse.
  ///
  /// In en, this message translates to:
  /// **'The server did not return a valid response.'**
  String get errorBadResponse;

  /// No description provided for @errorNotFound.
  ///
  /// In en, this message translates to:
  /// **'The server doesn\'t have it. Check the address; if it\'s right, ask your provider.'**
  String get errorNotFound;

  /// No description provided for @errorEmptyPlaylist.
  ///
  /// In en, this message translates to:
  /// **'The playlist is empty or is not a valid M3U file.'**
  String get errorEmptyPlaylist;

  /// No description provided for @errorUnknown.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Try again; if it keeps happening, restart the app.'**
  String get errorUnknown;

  /// No description provided for @seeAll.
  ///
  /// In en, this message translates to:
  /// **'See all'**
  String get seeAll;

  /// No description provided for @details.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get details;

  /// No description provided for @welcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Your TV, your way'**
  String get welcomeTitle;

  /// No description provided for @welcomeBody.
  ///
  /// In en, this message translates to:
  /// **'Connect your TV service with the details your provider gave you: a username and password, or a link. The app includes no channels: you use your own subscription.'**
  String get welcomeBody;

  /// No description provided for @episodesCount.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 episode} other{{n} episodes}}'**
  String episodesCount(int n);

  /// No description provided for @watchLive.
  ///
  /// In en, this message translates to:
  /// **'Watch live'**
  String get watchLive;

  /// No description provided for @home.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// No description provided for @search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Movies, series, channels or what is on'**
  String get searchHint;

  /// No description provided for @myList.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get myList;

  /// No description provided for @inMyList.
  ///
  /// In en, this message translates to:
  /// **'In favorites'**
  String get inMyList;

  /// No description provided for @continueWatching.
  ///
  /// In en, this message translates to:
  /// **'Continue watching'**
  String get continueWatching;

  /// No description provided for @recentChannels.
  ///
  /// In en, this message translates to:
  /// **'Recently watched channels'**
  String get recentChannels;

  /// No description provided for @favoriteChannels.
  ///
  /// In en, this message translates to:
  /// **'Favorite channels'**
  String get favoriteChannels;

  /// No description provided for @favoriteMovies.
  ///
  /// In en, this message translates to:
  /// **'Favorite movies'**
  String get favoriteMovies;

  /// No description provided for @favoriteSeries.
  ///
  /// In en, this message translates to:
  /// **'Favorite series'**
  String get favoriteSeries;

  /// No description provided for @homeEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Make it yours'**
  String get homeEmptyTitle;

  /// No description provided for @homeEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'What you watch and add to Favorites shows up here, ready to pick up where you left off.'**
  String get homeEmptyBody;

  /// No description provided for @resumedFrom.
  ///
  /// In en, this message translates to:
  /// **'Resuming from {time}'**
  String resumedFrom(String time);

  /// No description provided for @startOver.
  ///
  /// In en, this message translates to:
  /// **'Start over'**
  String get startOver;

  /// No description provided for @nextEpisode.
  ///
  /// In en, this message translates to:
  /// **'Next episode'**
  String get nextEpisode;

  /// No description provided for @nextChannel.
  ///
  /// In en, this message translates to:
  /// **'Next channel'**
  String get nextChannel;

  /// No description provided for @channelUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This channel isn\'t playing right now'**
  String get channelUnavailable;

  /// No description provided for @reconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get reconnecting;

  /// No description provided for @videoUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This video couldn\'t be played'**
  String get videoUnavailable;

  /// No description provided for @unavailableHint.
  ///
  /// In en, this message translates to:
  /// **'Your provider isn\'t sending it at the moment. Try again in a little while or pick something else.'**
  String get unavailableHint;

  /// No description provided for @continueAction.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueAction;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @playback.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get playback;

  /// No description provided for @appLanguage.
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get appLanguage;

  /// No description provided for @appLanguageDevice.
  ///
  /// In en, this message translates to:
  /// **'As the device'**
  String get appLanguageDevice;

  /// This language's own name, as it is listed among the app's languages.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageSelf;

  /// No description provided for @advanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get advanced;

  /// No description provided for @preferredAudio.
  ///
  /// In en, this message translates to:
  /// **'Preferred audio language'**
  String get preferredAudio;

  /// No description provided for @preferredSubtitles.
  ///
  /// In en, this message translates to:
  /// **'Preferred subtitles'**
  String get preferredSubtitles;

  /// No description provided for @automatic.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get automatic;

  /// No description provided for @liveFormat.
  ///
  /// In en, this message translates to:
  /// **'Live stream format'**
  String get liveFormat;

  /// No description provided for @liveFormatTs.
  ///
  /// In en, this message translates to:
  /// **'MPEG-TS (most compatible)'**
  String get liveFormatTs;

  /// No description provided for @liveFormatHls.
  ///
  /// In en, this message translates to:
  /// **'HLS (m3u8)'**
  String get liveFormatHls;

  /// No description provided for @decoder.
  ///
  /// In en, this message translates to:
  /// **'Video decoder'**
  String get decoder;

  /// No description provided for @decoderHardware.
  ///
  /// In en, this message translates to:
  /// **'Hardware (recommended)'**
  String get decoderHardware;

  /// No description provided for @decoderSoftware.
  ///
  /// In en, this message translates to:
  /// **'Software (compatibility)'**
  String get decoderSoftware;

  /// No description provided for @failMissing.
  ///
  /// In en, this message translates to:
  /// **'The provider no longer has it at this address. Try updating the list, or pick something else.'**
  String get failMissing;

  /// No description provided for @failDenied.
  ///
  /// In en, this message translates to:
  /// **'The provider refused it. Try again in a while; if it goes on, ask your provider.'**
  String get failDenied;

  /// No description provided for @failNetwork.
  ///
  /// In en, this message translates to:
  /// **'The provider can\'t be reached. Check this device\'s internet connection.'**
  String get failNetwork;

  /// No description provided for @decoderHint.
  ///
  /// In en, this message translates to:
  /// **'The signal arrived, but the picture didn\'t start. In Settings, Playback, Advanced, set Video decoder to Software.'**
  String get decoderHint;

  /// No description provided for @noResults.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get noResults;

  /// No description provided for @clearHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear watch history'**
  String get clearHistory;

  /// No description provided for @clearHistoryQuestion.
  ///
  /// In en, this message translates to:
  /// **'Clear what this profile watched in this playlist? With sync, on all your devices too.'**
  String get clearHistoryQuestion;

  /// No description provided for @removeFromContinue.
  ///
  /// In en, this message translates to:
  /// **'Removed from Continue watching'**
  String get removeFromContinue;

  /// No description provided for @deletePlaylistEverywhere.
  ///
  /// In en, this message translates to:
  /// **'With sync on, it goes from all the devices of this account.'**
  String get deletePlaylistEverywhere;

  /// No description provided for @historyCleared.
  ///
  /// In en, this message translates to:
  /// **'Watch history cleared'**
  String get historyCleared;

  /// No description provided for @loadingCatalog.
  ///
  /// In en, this message translates to:
  /// **'Loading the full catalog…'**
  String get loadingCatalog;

  /// No description provided for @organizingCatalog.
  ///
  /// In en, this message translates to:
  /// **'Putting your catalog in order…'**
  String get organizingCatalog;

  /// No description provided for @importedPlaylist.
  ///
  /// In en, this message translates to:
  /// **'In the playlist'**
  String get importedPlaylist;

  /// No description provided for @importedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} imported'**
  String importedCount(String count);

  /// No description provided for @downloadingCatalogPercent.
  ///
  /// In en, this message translates to:
  /// **'Downloading the catalog… {percent}%'**
  String downloadingCatalogPercent(int percent);

  /// No description provided for @downloadingCatalogSize.
  ///
  /// In en, this message translates to:
  /// **'Downloading the catalog… {size} MB'**
  String downloadingCatalogSize(String size);

  /// No description provided for @typeToSearch.
  ///
  /// In en, this message translates to:
  /// **'Type at least 2 letters'**
  String get typeToSearch;

  /// No description provided for @minutesLeft.
  ///
  /// In en, this message translates to:
  /// **'{n} min left'**
  String minutesLeft(int n);

  /// No description provided for @tvGuide.
  ///
  /// In en, this message translates to:
  /// **'TV guide'**
  String get tvGuide;

  /// No description provided for @holdOkHint.
  ///
  /// In en, this message translates to:
  /// **'Hold OK or press Info on a programme: its details, catch-up and recording'**
  String get holdOkHint;

  /// No description provided for @recentlyAdded.
  ///
  /// In en, this message translates to:
  /// **'Recently added'**
  String get recentlyAdded;

  /// No description provided for @topRated.
  ///
  /// In en, this message translates to:
  /// **'Top rated'**
  String get topRated;

  /// No description provided for @newReleases.
  ///
  /// In en, this message translates to:
  /// **'New releases'**
  String get newReleases;

  /// No description provided for @newEpisodes.
  ///
  /// In en, this message translates to:
  /// **'New episodes'**
  String get newEpisodes;

  /// No description provided for @newMovies.
  ///
  /// In en, this message translates to:
  /// **'New movies'**
  String get newMovies;

  /// No description provided for @sortRecent.
  ///
  /// In en, this message translates to:
  /// **'Newest'**
  String get sortRecent;

  /// No description provided for @sortTitle.
  ///
  /// In en, this message translates to:
  /// **'A–Z'**
  String get sortTitle;

  /// No description provided for @trailer.
  ///
  /// In en, this message translates to:
  /// **'Trailer'**
  String get trailer;

  /// No description provided for @moreLikeThis.
  ///
  /// In en, this message translates to:
  /// **'More like this'**
  String get moreLikeThis;

  /// No description provided for @director.
  ///
  /// In en, this message translates to:
  /// **'Director'**
  String get director;

  /// No description provided for @cast.
  ///
  /// In en, this message translates to:
  /// **'Cast'**
  String get cast;

  /// No description provided for @releaseDate.
  ///
  /// In en, this message translates to:
  /// **'Release date'**
  String get releaseDate;

  /// No description provided for @country.
  ///
  /// In en, this message translates to:
  /// **'Country'**
  String get country;

  /// No description provided for @duration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get duration;

  /// No description provided for @quality.
  ///
  /// In en, this message translates to:
  /// **'Quality'**
  String get quality;

  /// No description provided for @hoursMinutes.
  ///
  /// In en, this message translates to:
  /// **'{h} h {m} min'**
  String hoursMinutes(int h, int m);

  /// No description provided for @seasonsCount.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 season} other{{n} seasons}}'**
  String seasonsCount(int n);

  /// No description provided for @connectPhone.
  ///
  /// In en, this message translates to:
  /// **'Connect your phone'**
  String get connectPhone;

  /// No description provided for @connectPhoneBody.
  ///
  /// In en, this message translates to:
  /// **'Scan the code with your phone\'s camera. A page opens where you can add playlists with your phone\'s keyboard, use your phone as a remote and move your lists between devices.'**
  String get connectPhoneBody;

  /// No description provided for @connectSameNetwork.
  ///
  /// In en, this message translates to:
  /// **'Your phone and {device} must be on the same Wi-Fi.'**
  String connectSameNetwork(String device);

  /// No description provided for @connectOrOpen.
  ///
  /// In en, this message translates to:
  /// **'Or open this address on any device:'**
  String get connectOrOpen;

  /// No description provided for @connectWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your phone…'**
  String get connectWaiting;

  /// No description provided for @connectRemoteOn.
  ///
  /// In en, this message translates to:
  /// **'Your phone is connected as a remote'**
  String get connectRemoteOn;

  /// No description provided for @connectNoNetwork.
  ///
  /// In en, this message translates to:
  /// **'Connect this device to Wi-Fi or Ethernet to use your phone.'**
  String get connectNoNetwork;

  /// No description provided for @connectAnyNetwork.
  ///
  /// In en, this message translates to:
  /// **'Your phone only needs the internet: it does not have to be on the same Wi-Fi as {device}.'**
  String connectAnyNetwork(String device);

  /// No description provided for @connectNeedsServer.
  ///
  /// In en, this message translates to:
  /// **'Set up a sync server in Sync to use your phone with this TV.'**
  String get connectNeedsServer;

  /// No description provided for @connectServerDown.
  ///
  /// In en, this message translates to:
  /// **'The sync server can\'t be reached right now. Try again in a moment.'**
  String get connectServerDown;

  /// No description provided for @addFromPhone.
  ///
  /// In en, this message translates to:
  /// **'Use your phone'**
  String get addFromPhone;

  /// No description provided for @playlistReceived.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" added from your phone'**
  String playlistReceived(String name);

  /// No description provided for @backupReceived.
  ///
  /// In en, this message translates to:
  /// **'Lists received: {added, plural, =1{1 new} other{{added} new}}, {updated} updated'**
  String backupReceived(int added, int updated);

  /// No description provided for @phoneConnected.
  ///
  /// In en, this message translates to:
  /// **'Phone connected as a remote'**
  String get phoneConnected;

  /// No description provided for @pairTitle.
  ///
  /// In en, this message translates to:
  /// **'Connected to {device}'**
  String pairTitle(String device);

  /// No description provided for @pairBody.
  ///
  /// In en, this message translates to:
  /// **'Move your lists, profiles, favorites, history and settings between this phone and {device}. Everything goes straight over your Wi-Fi.'**
  String pairBody(String device);

  /// No description provided for @pairSend.
  ///
  /// In en, this message translates to:
  /// **'Send everything to {device}'**
  String pairSend(String device);

  /// No description provided for @pairReceive.
  ///
  /// In en, this message translates to:
  /// **'Bring the lists from {device}'**
  String pairReceive(String device);

  /// No description provided for @pairRemote.
  ///
  /// In en, this message translates to:
  /// **'Use this phone as a remote'**
  String get pairRemote;

  /// No description provided for @pairSent.
  ///
  /// In en, this message translates to:
  /// **'Sent to {device}: {added, plural, =1{1 new list} other{{added} new lists}}, {updated} updated'**
  String pairSent(int added, int updated, String device);

  /// No description provided for @pairReceived.
  ///
  /// In en, this message translates to:
  /// **'Received: {added, plural, =1{1 new list} other{{added} new lists}}, {updated} updated'**
  String pairReceived(int added, int updated);

  /// No description provided for @pairFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach {device}. Scan its code again: it changes every time.'**
  String pairFailed(String device);

  /// No description provided for @webTabAdd.
  ///
  /// In en, this message translates to:
  /// **'Add list'**
  String get webTabAdd;

  /// No description provided for @webTabRemote.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get webTabRemote;

  /// No description provided for @webTabBackup.
  ///
  /// In en, this message translates to:
  /// **'Backup'**
  String get webTabBackup;

  /// No description provided for @webAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add a list'**
  String get webAddTitle;

  /// No description provided for @webAddBody.
  ///
  /// In en, this message translates to:
  /// **'Type it here, with your phone\'s keyboard. {device} checks it with your provider and saves it.'**
  String webAddBody(String device);

  /// No description provided for @webShow.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get webShow;

  /// No description provided for @showPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get showPassword;

  /// No description provided for @hidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get hidePassword;

  /// No description provided for @webHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get webHide;

  /// No description provided for @webSendToDevice.
  ///
  /// In en, this message translates to:
  /// **'Send to {device}'**
  String webSendToDevice(String device);

  /// No description provided for @webChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking with your provider…'**
  String get webChecking;

  /// No description provided for @webAddedTitle.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" is on {device}'**
  String webAddedTitle(String name, String device);

  /// No description provided for @webAddedBody.
  ///
  /// In en, this message translates to:
  /// **'You can open it there now.'**
  String get webAddedBody;

  /// No description provided for @webAddAnother.
  ///
  /// In en, this message translates to:
  /// **'Add another'**
  String get webAddAnother;

  /// No description provided for @webLostConnection.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach {device}. Is it still on and on this Wi-Fi?'**
  String webLostConnection(String device);

  /// No description provided for @webRelayWaiting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the TV…'**
  String get webRelayWaiting;

  /// No description provided for @webRelayNoAnswer.
  ///
  /// In en, this message translates to:
  /// **'The TV does not answer. Check that it is still on, with Capy TV open.'**
  String get webRelayNoAnswer;

  /// No description provided for @webRelayExpired.
  ///
  /// In en, this message translates to:
  /// **'This page has expired. Scan the code on the TV again.'**
  String get webRelayExpired;

  /// No description provided for @webRelayLostConnection.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach {device}. Is it still on, with the app open?'**
  String webRelayLostConnection(String device);

  /// No description provided for @webExpired.
  ///
  /// In en, this message translates to:
  /// **'This page has expired. Scan the code on {device} again.'**
  String webExpired(String device);

  /// No description provided for @webNowPlaying.
  ///
  /// In en, this message translates to:
  /// **'Now playing'**
  String get webNowPlaying;

  /// No description provided for @webNothingPlaying.
  ///
  /// In en, this message translates to:
  /// **'Nothing playing'**
  String get webNothingPlaying;

  /// No description provided for @webBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get webBack;

  /// No description provided for @webPlayPause.
  ///
  /// In en, this message translates to:
  /// **'Play/Pause'**
  String get webPlayPause;

  /// No description provided for @webChannelDown.
  ///
  /// In en, this message translates to:
  /// **'Ch −'**
  String get webChannelDown;

  /// No description provided for @webChannelUp.
  ///
  /// In en, this message translates to:
  /// **'Ch +'**
  String get webChannelUp;

  /// No description provided for @webSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get webSend;

  /// No description provided for @webTypePlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Search on {device}'**
  String webTypePlaceholder(String device);

  /// No description provided for @webTypeHint.
  ///
  /// In en, this message translates to:
  /// **'What you type replaces the text of the field selected on screen, or searches.'**
  String get webTypeHint;

  /// No description provided for @webConnectedTo.
  ///
  /// In en, this message translates to:
  /// **'Connected to {device}'**
  String webConnectedTo(String device);

  /// No description provided for @webReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get webReconnecting;

  /// No description provided for @webBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'Back up or move your lists'**
  String get webBackupTitle;

  /// No description provided for @webBackupBody.
  ///
  /// In en, this message translates to:
  /// **'A backup has your lists with their passwords, every profile with its PIN and what each one watched and keeps, and your settings. Keep it somewhere private.'**
  String get webBackupBody;

  /// No description provided for @webDownloadBackup.
  ///
  /// In en, this message translates to:
  /// **'Download a backup'**
  String get webDownloadBackup;

  /// No description provided for @webDownloadHint.
  ///
  /// In en, this message translates to:
  /// **'Saved on this phone as a file.'**
  String get webDownloadHint;

  /// No description provided for @webRestoreBackup.
  ///
  /// In en, this message translates to:
  /// **'Restore a backup'**
  String get webRestoreBackup;

  /// No description provided for @webRestoreHint.
  ///
  /// In en, this message translates to:
  /// **'Lists already there are updated, not duplicated.'**
  String get webRestoreHint;

  /// No description provided for @webRestored.
  ///
  /// In en, this message translates to:
  /// **'Done on {device}. New lists: {added} · Updated: {updated}'**
  String webRestored(String added, String updated, String device);

  /// No description provided for @webNotBackup.
  ///
  /// In en, this message translates to:
  /// **'That file is not a Capy TV backup.'**
  String get webNotBackup;

  /// No description provided for @webBackupNewer.
  ///
  /// In en, this message translates to:
  /// **'This backup is from a newer version of Capy TV: update the app here first.'**
  String get webBackupNewer;

  /// No description provided for @webBackupSaved.
  ///
  /// In en, this message translates to:
  /// **'Backup saved to your downloads.'**
  String get webBackupSaved;

  /// No description provided for @webWorking.
  ///
  /// In en, this message translates to:
  /// **'One moment…'**
  String get webWorking;

  /// No description provided for @webSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get webSent;

  /// No description provided for @webOpenAppBody.
  ///
  /// In en, this message translates to:
  /// **'Have Capy TV on this phone? Open it to send your lists to {device} or bring them here.'**
  String webOpenAppBody(String device);

  /// No description provided for @webOpenApp.
  ///
  /// In en, this message translates to:
  /// **'Open the app'**
  String get webOpenApp;

  /// No description provided for @webPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Everything stays between this phone and {device}, on your network.'**
  String webPrivacy(String device);

  /// No description provided for @webRelayPrivacy.
  ///
  /// In en, this message translates to:
  /// **'The server only passes along what this phone and {device} say to each other, locked with a key that only the two of them have.'**
  String webRelayPrivacy(String device);

  /// No description provided for @webUp.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get webUp;

  /// No description provided for @webDown.
  ///
  /// In en, this message translates to:
  /// **'Down'**
  String get webDown;

  /// No description provided for @webLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get webLeft;

  /// No description provided for @webRight.
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get webRight;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @editPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Edit playlist'**
  String get editPlaylist;

  /// No description provided for @moveHistory.
  ///
  /// In en, this message translates to:
  /// **'Bring favorites and history from another list'**
  String get moveHistory;

  /// No description provided for @moveHistoryChoose.
  ///
  /// In en, this message translates to:
  /// **'From which list?'**
  String get moveHistoryChoose;

  /// No description provided for @moveHistoryWorking.
  ///
  /// In en, this message translates to:
  /// **'Looking for your titles in this list…'**
  String get moveHistoryWorking;

  /// No description provided for @moveHistoryDone.
  ///
  /// In en, this message translates to:
  /// **'{moved, plural, =0{Nothing found in this list} =1{1 item moved} other{{moved} items moved}}{missing, plural, =0{} =1{; 1 is not in this list} other{; {missing} are not in this list}}'**
  String moveHistoryDone(int moved, int missing);

  /// No description provided for @sync.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get sync;

  /// No description provided for @syncTitle.
  ///
  /// In en, this message translates to:
  /// **'Your lists everywhere'**
  String get syncTitle;

  /// No description provided for @syncBody.
  ///
  /// In en, this message translates to:
  /// **'Sign in on each device and your playlists, favorites and progress follow you. Everything is encrypted on the device before it leaves: the server keeps it but can\'t read it. Only recommendations, when your server makes them, send it readable the titles to recommend from.'**
  String get syncBody;

  /// No description provided for @syncServer.
  ///
  /// In en, this message translates to:
  /// **'Sync server'**
  String get syncServer;

  /// No description provided for @syncEmail.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get syncEmail;

  /// No description provided for @syncPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get syncPassword;

  /// No description provided for @syncPasswordAgain.
  ///
  /// In en, this message translates to:
  /// **'Repeat password'**
  String get syncPasswordAgain;

  /// No description provided for @syncSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get syncSignIn;

  /// No description provided for @syncCreate.
  ///
  /// In en, this message translates to:
  /// **'Create sync account'**
  String get syncCreate;

  /// No description provided for @syncToCreate.
  ///
  /// In en, this message translates to:
  /// **'New here? Create an account'**
  String get syncToCreate;

  /// No description provided for @syncToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Have an account? Sign in'**
  String get syncToSignIn;

  /// No description provided for @syncPasswordNote.
  ///
  /// In en, this message translates to:
  /// **'Only you know this password. Next you get a recovery key: keep it, it\'s the only way back in if you forget the password.'**
  String get syncPasswordNote;

  /// No description provided for @syncWorking.
  ///
  /// In en, this message translates to:
  /// **'Securing your keys…'**
  String get syncWorking;

  /// No description provided for @syncErrorServer.
  ///
  /// In en, this message translates to:
  /// **'Use an https:// address (plain http only on your local network)'**
  String get syncErrorServer;

  /// No description provided for @syncErrorEmail.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email'**
  String get syncErrorEmail;

  /// No description provided for @syncErrorShort.
  ///
  /// In en, this message translates to:
  /// **'Use at least 8 characters'**
  String get syncErrorShort;

  /// No description provided for @syncErrorMismatch.
  ///
  /// In en, this message translates to:
  /// **'The passwords don\'t match'**
  String get syncErrorMismatch;

  /// No description provided for @syncErrorCredentials.
  ///
  /// In en, this message translates to:
  /// **'Wrong email or password'**
  String get syncErrorCredentials;

  /// No description provided for @syncErrorExists.
  ///
  /// In en, this message translates to:
  /// **'There\'s already an account with this email'**
  String get syncErrorExists;

  /// No description provided for @syncErrorRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Try again in a minute.'**
  String get syncErrorRateLimited;

  /// No description provided for @syncErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Can\'t reach the sync server'**
  String get syncErrorNetwork;

  /// No description provided for @syncErrorFailed.
  ///
  /// In en, this message translates to:
  /// **'The sync server had a problem. Try again later.'**
  String get syncErrorFailed;

  /// No description provided for @syncStatusSynced.
  ///
  /// In en, this message translates to:
  /// **'Up to date · {time}'**
  String syncStatusSynced(String time);

  /// No description provided for @syncStatusSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get syncStatusSyncing;

  /// No description provided for @syncStatusOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline. Changes go out when the server is back.'**
  String get syncStatusOffline;

  /// No description provided for @syncStatusExpired.
  ///
  /// In en, this message translates to:
  /// **'Your session ended. Sign in again.'**
  String get syncStatusExpired;

  /// No description provided for @syncExpiredNotice.
  ///
  /// In en, this message translates to:
  /// **'Sync stopped: the session ended. Sign in again in Settings, Sync.'**
  String get syncExpiredNotice;

  /// No description provided for @syncStatusOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get syncStatusOff;

  /// No description provided for @syncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get syncNow;

  /// No description provided for @syncDevices.
  ///
  /// In en, this message translates to:
  /// **'Signed-in devices'**
  String get syncDevices;

  /// No description provided for @syncSeen.
  ///
  /// In en, this message translates to:
  /// **'Seen {time}'**
  String syncSeen(String time);

  /// No description provided for @syncSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get syncSignOut;

  /// No description provided for @syncSignOutConfirm.
  ///
  /// In en, this message translates to:
  /// **'Sign this device out? What it has stays here, but nothing new comes until it signs in again.'**
  String get syncSignOutConfirm;

  /// No description provided for @syncDeleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get syncDeleteAccount;

  /// No description provided for @syncDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the account and everything synced? Each device keeps its own lists and history.'**
  String get syncDeleteConfirm;

  /// No description provided for @syncSignedOut.
  ///
  /// In en, this message translates to:
  /// **'Signed out. Everything stays on this device.'**
  String get syncSignedOut;

  /// No description provided for @whoIsWatching.
  ///
  /// In en, this message translates to:
  /// **'Who\'s watching?'**
  String get whoIsWatching;

  /// No description provided for @profileYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get profileYou;

  /// No description provided for @profiles.
  ///
  /// In en, this message translates to:
  /// **'Profiles'**
  String get profiles;

  /// No description provided for @profilesTitle.
  ///
  /// In en, this message translates to:
  /// **'Profiles and parental control'**
  String get profilesTitle;

  /// No description provided for @profilesBody.
  ///
  /// In en, this message translates to:
  /// **'Each profile keeps its own favorites, history and \"Continue watching\". Kids profiles never show adult content.'**
  String get profilesBody;

  /// No description provided for @addProfile.
  ///
  /// In en, this message translates to:
  /// **'Add profile'**
  String get addProfile;

  /// No description provided for @editProfile.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get editProfile;

  /// No description provided for @profileName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get profileName;

  /// No description provided for @kidsProfile.
  ///
  /// In en, this message translates to:
  /// **'Kids'**
  String get kidsProfile;

  /// No description provided for @kidsAdultTitle.
  ///
  /// In en, this message translates to:
  /// **'This title is for adults, and this profile can\'t play it.'**
  String get kidsAdultTitle;

  /// No description provided for @kidsProfileHint.
  ///
  /// In en, this message translates to:
  /// **'Never shows adult content.'**
  String get kidsProfileHint;

  /// No description provided for @kidsProfileNoPinHint.
  ///
  /// In en, this message translates to:
  /// **'Never shows adult content. Saving it asks for a parental PIN, so a child can\'t turn this off.'**
  String get kidsProfileNoPinHint;

  /// No description provided for @kidsPinTitle.
  ///
  /// In en, this message translates to:
  /// **'A PIN so a child can\'t change this'**
  String get kidsPinTitle;

  /// No description provided for @adultPinTitle.
  ///
  /// In en, this message translates to:
  /// **'A PIN so only adults can see this'**
  String get adultPinTitle;

  /// No description provided for @lockProfile.
  ///
  /// In en, this message translates to:
  /// **'Ask for the PIN'**
  String get lockProfile;

  /// No description provided for @lockProfileHint.
  ///
  /// In en, this message translates to:
  /// **'Only someone who knows its PIN can open this profile.'**
  String get lockProfileHint;

  /// No description provided for @profilePin.
  ///
  /// In en, this message translates to:
  /// **'This profile\'s PIN'**
  String get profilePin;

  /// No description provided for @enterPinOf.
  ///
  /// In en, this message translates to:
  /// **'{name}\'s PIN'**
  String enterPinOf(String name);

  /// No description provided for @enterPinMain.
  ///
  /// In en, this message translates to:
  /// **'Your PIN'**
  String get enterPinMain;

  /// No description provided for @forgotPin.
  ///
  /// In en, this message translates to:
  /// **'I forgot the PIN'**
  String get forgotPin;

  /// No description provided for @forgotPinAccount.
  ///
  /// In en, this message translates to:
  /// **'Enter your sync account\'s password to remove the parental PIN from all your devices.'**
  String get forgotPinAccount;

  /// No description provided for @forgotPinNoAccount.
  ///
  /// In en, this message translates to:
  /// **'Without a sync account there is no way to prove it is you: the only way out is to clear this app\'s data or reinstall it, losing this device\'s profiles, lists and history.'**
  String get forgotPinNoAccount;

  /// No description provided for @forgotPinProfile.
  ///
  /// In en, this message translates to:
  /// **'To use it again, {name} must be deleted, with its favorites and history. Nobody will see what was watched.'**
  String forgotPinProfile(String name);

  /// No description provided for @forgotPinMain.
  ///
  /// In en, this message translates to:
  /// **'The favorites and history of {name} will be deleted and its PIN removed. Nobody will see what was watched.'**
  String forgotPinMain(String name);

  /// No description provided for @forgotPinMainUnnamed.
  ///
  /// In en, this message translates to:
  /// **'The favorites and history of this profile will be deleted and its PIN removed. Nobody will see what was watched.'**
  String get forgotPinMainUnnamed;

  /// No description provided for @showAdult.
  ///
  /// In en, this message translates to:
  /// **'Show adult content'**
  String get showAdult;

  /// No description provided for @showAdultHint.
  ///
  /// In en, this message translates to:
  /// **'Categories for adults (XXX, +18…) and whatever the provider marks as adult. Hidden by default.'**
  String get showAdultHint;

  /// No description provided for @deleteProfile.
  ///
  /// In en, this message translates to:
  /// **'Delete profile'**
  String get deleteProfile;

  /// No description provided for @deleteProfileQuestion.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}? Its favorites and history go with it.'**
  String deleteProfileQuestion(String name);

  /// No description provided for @parentalPin.
  ///
  /// In en, this message translates to:
  /// **'Parental PIN'**
  String get parentalPin;

  /// No description provided for @parentalPinBody.
  ///
  /// In en, this message translates to:
  /// **'Needed to change these settings. Each profile can also have its own PIN.'**
  String get parentalPinBody;

  /// No description provided for @setPin.
  ///
  /// In en, this message translates to:
  /// **'Set PIN'**
  String get setPin;

  /// No description provided for @changePin.
  ///
  /// In en, this message translates to:
  /// **'Change PIN'**
  String get changePin;

  /// No description provided for @removePin.
  ///
  /// In en, this message translates to:
  /// **'Remove PIN'**
  String get removePin;

  /// No description provided for @enterPin.
  ///
  /// In en, this message translates to:
  /// **'Enter the PIN'**
  String get enterPin;

  /// No description provided for @newPin.
  ///
  /// In en, this message translates to:
  /// **'New PIN'**
  String get newPin;

  /// No description provided for @repeatPin.
  ///
  /// In en, this message translates to:
  /// **'Repeat the PIN'**
  String get repeatPin;

  /// No description provided for @wrongPin.
  ///
  /// In en, this message translates to:
  /// **'Wrong PIN'**
  String get wrongPin;

  /// No description provided for @pinMismatch.
  ///
  /// In en, this message translates to:
  /// **'The PINs don\'t match'**
  String get pinMismatch;

  /// No description provided for @pinSaved.
  ///
  /// In en, this message translates to:
  /// **'PIN saved'**
  String get pinSaved;

  /// No description provided for @pinRemoved.
  ///
  /// In en, this message translates to:
  /// **'PIN removed'**
  String get pinRemoved;

  /// No description provided for @storageFull.
  ///
  /// In en, this message translates to:
  /// **'Changes couldn\'t be saved: this device may be out of space.'**
  String get storageFull;

  /// No description provided for @noSecureStorage.
  ///
  /// In en, this message translates to:
  /// **'This device has no secure storage: the password was not saved.'**
  String get noSecureStorage;

  /// No description provided for @startupFailed.
  ///
  /// In en, this message translates to:
  /// **'Capy TV couldn\'t start.'**
  String get startupFailed;

  /// No description provided for @pickFieldFirst.
  ///
  /// In en, this message translates to:
  /// **'Choose a field on the TV first'**
  String get pickFieldFirst;

  /// No description provided for @castNotAllowed.
  ///
  /// In en, this message translates to:
  /// **'What was sent here isn\'t available on this profile.'**
  String get castNotAllowed;

  /// No description provided for @pairCheck.
  ///
  /// In en, this message translates to:
  /// **'Check it matches the other device: {address} · code {code}'**
  String pairCheck(String address, String code);

  /// No description provided for @pinWait.
  ///
  /// In en, this message translates to:
  /// **'Too many tries. Wait {seconds} s'**
  String pinWait(int seconds);

  /// No description provided for @switchProfile.
  ///
  /// In en, this message translates to:
  /// **'Switch profile'**
  String get switchProfile;

  /// No description provided for @profileLocked.
  ///
  /// In en, this message translates to:
  /// **'PIN'**
  String get profileLocked;

  /// No description provided for @adultTag.
  ///
  /// In en, this message translates to:
  /// **'Adult content'**
  String get adultTag;

  /// No description provided for @backspace.
  ///
  /// In en, this message translates to:
  /// **'Delete digit'**
  String get backspace;

  /// No description provided for @syncInvite.
  ///
  /// In en, this message translates to:
  /// **'Invitation code'**
  String get syncInvite;

  /// No description provided for @syncInviteHint.
  ///
  /// In en, this message translates to:
  /// **'Only if your server asks for one'**
  String get syncInviteHint;

  /// No description provided for @syncErrorInvite.
  ///
  /// In en, this message translates to:
  /// **'This server only creates accounts with its invitation code'**
  String get syncErrorInvite;

  /// No description provided for @syncErrorQuota.
  ///
  /// In en, this message translates to:
  /// **'The account is full: ask whoever runs the server for more space'**
  String get syncErrorQuota;

  /// No description provided for @syncErrorFull.
  ///
  /// In en, this message translates to:
  /// **'This server takes no more accounts: ask whoever runs it'**
  String get syncErrorFull;

  /// No description provided for @syncThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get syncThisDevice;

  /// No description provided for @syncSignOutDevice.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get syncSignOutDevice;

  /// No description provided for @syncSignOutDeviceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Sign {name} out? It keeps what it has, but gets nothing new until it signs in again.'**
  String syncSignOutDeviceConfirm(String name);

  /// No description provided for @syncSignedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in to sync as {email}'**
  String syncSignedInAs(String email);

  /// No description provided for @webTabAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get webTabAccount;

  /// No description provided for @webAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in to sync'**
  String get webAccountTitle;

  /// No description provided for @webAccountBody.
  ///
  /// In en, this message translates to:
  /// **'{device} gets your playlists, profiles, favorites and history from your account. The password travels encrypted, and only {device} uses it.'**
  String webAccountBody(String device);

  /// No description provided for @webSignInOn.
  ///
  /// In en, this message translates to:
  /// **'Sign {device} in'**
  String webSignInOn(String device);

  /// No description provided for @webSigningIn.
  ///
  /// In en, this message translates to:
  /// **'Signing in… it takes a few seconds'**
  String get webSigningIn;

  /// No description provided for @webSignedInTitle.
  ///
  /// In en, this message translates to:
  /// **'{device} is signed in'**
  String webSignedInTitle(String device);

  /// No description provided for @webSignedInBody.
  ///
  /// In en, this message translates to:
  /// **'As {email}. Your lists arrive in a moment.'**
  String webSignedInBody(String email);

  /// No description provided for @webCurrentAccount.
  ///
  /// In en, this message translates to:
  /// **'{device} is signed in as {email}. Signing in again switches accounts.'**
  String webCurrentAccount(String device, String email);

  /// No description provided for @webNeedQr.
  ///
  /// In en, this message translates to:
  /// **'To send passwords, accounts or backups from here, scan the QR code on {device}: it carries the key that keeps them private on your network.'**
  String webNeedQr(String device);

  /// No description provided for @syncForgot.
  ///
  /// In en, this message translates to:
  /// **'Forgot your password?'**
  String get syncForgot;

  /// No description provided for @syncBackToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Back to sign in'**
  String get syncBackToSignIn;

  /// No description provided for @syncRecoveryKey.
  ///
  /// In en, this message translates to:
  /// **'Recovery key'**
  String get syncRecoveryKey;

  /// No description provided for @syncNewPassword.
  ///
  /// In en, this message translates to:
  /// **'New password'**
  String get syncNewPassword;

  /// No description provided for @syncCurrentPassword.
  ///
  /// In en, this message translates to:
  /// **'Current password'**
  String get syncCurrentPassword;

  /// No description provided for @syncRecover.
  ///
  /// In en, this message translates to:
  /// **'Set new password'**
  String get syncRecover;

  /// No description provided for @syncRecoverBody.
  ///
  /// In en, this message translates to:
  /// **'Enter the recovery key you got when you created the account, and choose a new password. Your other devices will ask for it.'**
  String get syncRecoverBody;

  /// No description provided for @syncErrorRecoveryKey.
  ///
  /// In en, this message translates to:
  /// **'That isn\'t a recovery key: it has 32 letters and digits'**
  String get syncErrorRecoveryKey;

  /// No description provided for @syncErrorRecovery.
  ///
  /// In en, this message translates to:
  /// **'Wrong email or recovery key'**
  String get syncErrorRecovery;

  /// No description provided for @syncErrorPassword.
  ///
  /// In en, this message translates to:
  /// **'Wrong password'**
  String get syncErrorPassword;

  /// No description provided for @syncRecoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Your recovery key'**
  String get syncRecoveryTitle;

  /// No description provided for @syncRecoveryBody.
  ///
  /// In en, this message translates to:
  /// **'If you forget your password, this key is the only way back into your account: nobody can reset it for you, not even whoever runs the server. Write it down or take a photo, and keep it somewhere safe.'**
  String get syncRecoveryBody;

  /// No description provided for @syncRecoverySaved.
  ///
  /// In en, this message translates to:
  /// **'I\'ve written it down'**
  String get syncRecoverySaved;

  /// No description provided for @syncCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get syncCopy;

  /// No description provided for @syncCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get syncCopied;

  /// No description provided for @syncChangePassword.
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get syncChangePassword;

  /// No description provided for @syncChangePasswordBody.
  ///
  /// In en, this message translates to:
  /// **'Your other devices are signed out until they sign in with the new password.'**
  String get syncChangePasswordBody;

  /// No description provided for @syncPasswordChanged.
  ///
  /// In en, this message translates to:
  /// **'Password changed'**
  String get syncPasswordChanged;

  /// No description provided for @syncNewRecoveryKey.
  ///
  /// In en, this message translates to:
  /// **'New recovery key'**
  String get syncNewRecoveryKey;

  /// No description provided for @syncNewRecoveryKeyBody.
  ///
  /// In en, this message translates to:
  /// **'The recovery key you have now stops working. Enter your password to make a new one.'**
  String get syncNewRecoveryKeyBody;

  /// No description provided for @trendingMovie.
  ///
  /// In en, this message translates to:
  /// **'Movie trending this week'**
  String get trendingMovie;

  /// No description provided for @trendingSeries.
  ///
  /// In en, this message translates to:
  /// **'Series trending this week'**
  String get trendingSeries;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @aboutLicense.
  ///
  /// In en, this message translates to:
  /// **'Open source, under the Mozilla Public License 2.0. It plays content from your own provider and includes none.'**
  String get aboutLicense;

  /// No description provided for @tmdbNotice.
  ///
  /// In en, this message translates to:
  /// **'This product uses the TMDB API but is not endorsed or certified by TMDB. Trending movies and series, with their images, come from The Movie Database.'**
  String get tmdbNotice;

  /// No description provided for @trendingNow.
  ///
  /// In en, this message translates to:
  /// **'Trending this week'**
  String get trendingNow;

  /// No description provided for @forYou.
  ///
  /// In en, this message translates to:
  /// **'Picked for {name}'**
  String forYou(String name);

  /// No description provided for @forYouMain.
  ///
  /// In en, this message translates to:
  /// **'Picked for you'**
  String get forYouMain;

  /// No description provided for @aiTitle.
  ///
  /// In en, this message translates to:
  /// **'Recommendations with AI'**
  String get aiTitle;

  /// No description provided for @aiBody.
  ///
  /// In en, this message translates to:
  /// **'A language model picks titles for each profile from what it has watched and keeps in Favorites, and says why. Those titles, and some of the catalog\'s to pick from, never any for adults, go to the service that recommends: the one set up here, else your sync server\'s, else the app\'s own. Kids profiles never use it.'**
  String get aiBody;

  /// No description provided for @aiOff.
  ///
  /// In en, this message translates to:
  /// **'Not set up'**
  String get aiOff;

  /// No description provided for @aiSetUp.
  ///
  /// In en, this message translates to:
  /// **'Set up'**
  String get aiSetUp;

  /// No description provided for @aiChange.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get aiChange;

  /// No description provided for @aiRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get aiRemove;

  /// No description provided for @aiUrl.
  ///
  /// In en, this message translates to:
  /// **'Service address'**
  String get aiUrl;

  /// No description provided for @aiUrlHint.
  ///
  /// In en, this message translates to:
  /// **'Any service with the OpenAI chat API: Ollama, OpenAI, OpenRouter, your own server…'**
  String get aiUrlHint;

  /// No description provided for @aiModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get aiModel;

  /// No description provided for @aiKey.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get aiKey;

  /// No description provided for @aiKeyKept.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to keep the current key'**
  String get aiKeyKept;

  /// No description provided for @aiTestAndSave.
  ///
  /// In en, this message translates to:
  /// **'Check and save'**
  String get aiTestAndSave;

  /// No description provided for @aiSaved.
  ///
  /// In en, this message translates to:
  /// **'Recommendations are on'**
  String get aiSaved;

  /// No description provided for @aiWrongKey.
  ///
  /// In en, this message translates to:
  /// **'The service did not accept the key'**
  String get aiWrongKey;

  /// No description provided for @aiWrongModel.
  ///
  /// In en, this message translates to:
  /// **'The service does not have that model, or the address is wrong'**
  String get aiWrongModel;

  /// No description provided for @aiUnreachable.
  ///
  /// In en, this message translates to:
  /// **'The service did not answer: check the address'**
  String get aiUnreachable;

  /// No description provided for @aiBusy.
  ///
  /// In en, this message translates to:
  /// **'The service is busy or down for now: try again later'**
  String get aiBusy;

  /// No description provided for @aiServiceError.
  ///
  /// In en, this message translates to:
  /// **'The service answered with error {code}'**
  String aiServiceError(String code);

  /// No description provided for @aiUrlInsecure.
  ///
  /// In en, this message translates to:
  /// **'Use an https address: plain http only for a service on this network'**
  String get aiUrlInsecure;

  /// No description provided for @aiKeyLost.
  ///
  /// In en, this message translates to:
  /// **'The key of your AI service couldn\'t be read on this device: set it up again'**
  String get aiKeyLost;

  /// No description provided for @aiKeyAgain.
  ///
  /// In en, this message translates to:
  /// **'A new address needs its key typed again'**
  String get aiKeyAgain;

  /// No description provided for @aiBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'On: included in this version of the app'**
  String get aiBuiltIn;

  /// No description provided for @aiUseBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'Turn back on'**
  String get aiUseBuiltIn;

  /// No description provided for @aiTurnedOff.
  ///
  /// In en, this message translates to:
  /// **'Off on this device'**
  String get aiTurnedOff;

  /// No description provided for @aiTurnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get aiTurnOff;

  /// No description provided for @aiOwn.
  ///
  /// In en, this message translates to:
  /// **'Use another service'**
  String get aiOwn;

  /// No description provided for @aiFromServer.
  ///
  /// In en, this message translates to:
  /// **'On: through your sync server, {server}'**
  String aiFromServer(String server);

  /// No description provided for @aiServerNote.
  ///
  /// In en, this message translates to:
  /// **'The titles sent for recommendations go through your sync server, which can read them; it forwards them to its model and keeps nothing.'**
  String get aiServerNote;

  /// No description provided for @aiTypeOnPhone.
  ///
  /// In en, this message translates to:
  /// **'Scan the code with your phone, open Remote and type there: the text goes into the field selected on the TV.'**
  String get aiTypeOnPhone;

  /// No description provided for @recentSearches.
  ///
  /// In en, this message translates to:
  /// **'Recent searches'**
  String get recentSearches;

  /// No description provided for @clearRecent.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clearRecent;

  /// No description provided for @bestMatch.
  ///
  /// In en, this message translates to:
  /// **'Best match'**
  String get bestMatch;

  /// No description provided for @onTvNow.
  ///
  /// In en, this message translates to:
  /// **'On TV'**
  String get onTvNow;

  /// No description provided for @onNow.
  ///
  /// In en, this message translates to:
  /// **'Now'**
  String get onNow;

  /// No description provided for @browseGenres.
  ///
  /// In en, this message translates to:
  /// **'Movies by genre'**
  String get browseGenres;

  /// No description provided for @seeAllCount.
  ///
  /// In en, this message translates to:
  /// **'See all ({count})'**
  String seeAllCount(int count);

  /// No description provided for @versionsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 version} other{{count} versions}}'**
  String versionsCount(int count);

  /// No description provided for @versionNumber.
  ///
  /// In en, this message translates to:
  /// **'Version {n}'**
  String versionNumber(int n);

  /// No description provided for @mostWatchedMovies.
  ///
  /// In en, this message translates to:
  /// **'Most watched movies this week'**
  String get mostWatchedMovies;

  /// No description provided for @mostWatchedSeries.
  ///
  /// In en, this message translates to:
  /// **'Most watched series this week'**
  String get mostWatchedSeries;

  /// No description provided for @tryingAnotherCopy.
  ///
  /// In en, this message translates to:
  /// **'Trying another copy…'**
  String get tryingAnotherCopy;

  /// No description provided for @combinePlaylists.
  ///
  /// In en, this message translates to:
  /// **'Combine playlists'**
  String get combinePlaylists;

  /// No description provided for @combineBody.
  ///
  /// In en, this message translates to:
  /// **'Pick two or more providers to use as one list. Their catalogs come together: a title they share shows once, with every provider\'s copy among its versions, and plays from the one usually fastest at that hour, or from another when one fails. Each playlist stays as it is.'**
  String get combineBody;

  /// No description provided for @pasteLinkHint.
  ///
  /// In en, this message translates to:
  /// **'Or paste the link your provider sent you (get.php?username=…): it fills in everything'**
  String get pasteLinkHint;

  /// No description provided for @filledFromLink.
  ///
  /// In en, this message translates to:
  /// **'Server, user and password taken from the link'**
  String get filledFromLink;

  /// No description provided for @combineSuggestion.
  ///
  /// In en, this message translates to:
  /// **'Two providers: combine them to see all their titles together, and to play from the other when one fails'**
  String get combineSuggestion;

  /// No description provided for @accountAlreadyAdded.
  ///
  /// In en, this message translates to:
  /// **'That account was already here: its password is updated'**
  String get accountAlreadyAdded;

  /// No description provided for @surpriseMe.
  ///
  /// In en, this message translates to:
  /// **'Surprise me'**
  String get surpriseMe;

  /// No description provided for @surpriseQuestion.
  ///
  /// In en, this message translates to:
  /// **'What do you feel like?'**
  String get surpriseQuestion;

  /// No description provided for @surpriseGo.
  ///
  /// In en, this message translates to:
  /// **'Pick one'**
  String get surpriseGo;

  /// No description provided for @surpriseAnother.
  ///
  /// In en, this message translates to:
  /// **'Another one'**
  String get surpriseAnother;

  /// No description provided for @surpriseNone.
  ///
  /// In en, this message translates to:
  /// **'Nothing left for that mood: try another.'**
  String get surpriseNone;

  /// No description provided for @userAgentOptional.
  ///
  /// In en, this message translates to:
  /// **'User-Agent (optional)'**
  String get userAgentOptional;

  /// No description provided for @userAgentHint.
  ///
  /// In en, this message translates to:
  /// **'Only if your provider asks for a particular player'**
  String get userAgentHint;

  /// No description provided for @guideTime.
  ///
  /// In en, this message translates to:
  /// **'Guide time'**
  String get guideTime;

  /// No description provided for @guideTimeHint.
  ///
  /// In en, this message translates to:
  /// **'If the guide shows programmes earlier or later than they air, put it right here.'**
  String get guideTimeHint;

  /// No description provided for @guideTimeAsSent.
  ///
  /// In en, this message translates to:
  /// **'As the provider sends it'**
  String get guideTimeAsSent;

  /// No description provided for @guideTimeMoved.
  ///
  /// In en, this message translates to:
  /// **'{hours} h'**
  String guideTimeMoved(String hours);

  /// No description provided for @diagnostics.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnostics;

  /// No description provided for @diagnosticsCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied: paste it in a message to whoever is helping you.'**
  String get diagnosticsCopied;

  /// No description provided for @diagnosticsHint.
  ///
  /// In en, this message translates to:
  /// **'What the app noted lately, with no addresses or passwords, for whoever is helping you.'**
  String get diagnosticsHint;

  /// No description provided for @surpriseAtRandom.
  ///
  /// In en, this message translates to:
  /// **'Your list has no genres or ratings: here is one at random.'**
  String get surpriseAtRandom;

  /// No description provided for @surpriseNoInfoKids.
  ///
  /// In en, this message translates to:
  /// **'Your list has no genres or ratings, so there is nothing here to suggest for this profile.'**
  String get surpriseNoInfoKids;

  /// No description provided for @moodLaugh.
  ///
  /// In en, this message translates to:
  /// **'A laugh'**
  String get moodLaugh;

  /// No description provided for @moodAction.
  ///
  /// In en, this message translates to:
  /// **'Action'**
  String get moodAction;

  /// No description provided for @moodSuspense.
  ///
  /// In en, this message translates to:
  /// **'Suspense'**
  String get moodSuspense;

  /// No description provided for @moodFamily.
  ///
  /// In en, this message translates to:
  /// **'With the family'**
  String get moodFamily;

  /// No description provided for @moodRomance.
  ///
  /// In en, this message translates to:
  /// **'Romance'**
  String get moodRomance;

  /// No description provided for @moodScary.
  ///
  /// In en, this message translates to:
  /// **'Scary'**
  String get moodScary;

  /// No description provided for @moodDifferent.
  ///
  /// In en, this message translates to:
  /// **'Something different'**
  String get moodDifferent;

  /// No description provided for @newEpisodesForYou.
  ///
  /// In en, this message translates to:
  /// **'New episodes of your series'**
  String get newEpisodesForYou;

  /// No description provided for @upNextForYou.
  ///
  /// In en, this message translates to:
  /// **'Up next'**
  String get upNextForYou;

  /// No description provided for @guideToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get guideToday;

  /// No description provided for @guideYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get guideYesterday;

  /// No description provided for @guideTomorrow.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow'**
  String get guideTomorrow;

  /// No description provided for @guideEarlier.
  ///
  /// In en, this message translates to:
  /// **'Two hours earlier'**
  String get guideEarlier;

  /// No description provided for @guideLater.
  ///
  /// In en, this message translates to:
  /// **'Two hours later'**
  String get guideLater;

  /// No description provided for @rowEarlier.
  ///
  /// In en, this message translates to:
  /// **'Earlier in this row'**
  String get rowEarlier;

  /// No description provided for @rowLater.
  ///
  /// In en, this message translates to:
  /// **'Further in this row'**
  String get rowLater;

  /// No description provided for @newEpisodeNote.
  ///
  /// In en, this message translates to:
  /// **'S{season} · E{number}{more, plural, =0{} =1{ and 1 more} other{ and {more} more}}'**
  String newEpisodeNote(int season, int number, int more);

  /// No description provided for @screensaver.
  ///
  /// In en, this message translates to:
  /// **'Screensaver'**
  String get screensaver;

  /// No description provided for @minutesIdle.
  ///
  /// In en, this message translates to:
  /// **'After {minutes} min'**
  String minutesIdle(int minutes);

  /// No description provided for @movieNight.
  ///
  /// In en, this message translates to:
  /// **'Movie night'**
  String get movieNight;

  /// No description provided for @nightTitle.
  ///
  /// In en, this message translates to:
  /// **'What shall we watch tonight?'**
  String get nightTitle;

  /// No description provided for @nightBodyTv.
  ///
  /// In en, this message translates to:
  /// **'Everyone scans the code with their phone and says yes or no to each of these. The one with the most votes wins.'**
  String get nightBodyTv;

  /// No description provided for @nightYes.
  ///
  /// In en, this message translates to:
  /// **'Yes!'**
  String get nightYes;

  /// No description provided for @nightNo.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get nightNo;

  /// No description provided for @nightWinner.
  ///
  /// In en, this message translates to:
  /// **'See the winner'**
  String get nightWinner;

  /// No description provided for @nightVoters.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Nobody has voted yet} =1{1 phone has voted} other{{count} phones have voted}}'**
  String nightVoters(int count);

  /// No description provided for @nightWinnerTitle.
  ///
  /// In en, this message translates to:
  /// **'Tonight it is'**
  String get nightWinnerTitle;

  /// No description provided for @nightNotEnough.
  ///
  /// In en, this message translates to:
  /// **'Not enough titles for this mood: try another.'**
  String get nightNotEnough;

  /// No description provided for @webTabNight.
  ///
  /// In en, this message translates to:
  /// **'Vote'**
  String get webTabNight;

  /// No description provided for @webNightBody.
  ///
  /// In en, this message translates to:
  /// **'Yes or no to each title: the TV counts everyone\'s votes.'**
  String get webNightBody;

  /// No description provided for @webNightDone.
  ///
  /// In en, this message translates to:
  /// **'All done!'**
  String get webNightDone;

  /// No description provided for @webNightDoneBody.
  ///
  /// In en, this message translates to:
  /// **'Look at {device}: the winner shows there.'**
  String webNightDoneBody(String device);

  /// No description provided for @webNightAgain.
  ///
  /// In en, this message translates to:
  /// **'Change my votes'**
  String get webNightAgain;

  /// No description provided for @webNightClosed.
  ///
  /// In en, this message translates to:
  /// **'There is no vote open on {device} right now.'**
  String webNightClosed(String device);

  /// No description provided for @webNightProgress.
  ///
  /// In en, this message translates to:
  /// **'{n} of {total}'**
  String webNightProgress(String n, String total);

  /// No description provided for @leftOn.
  ///
  /// In en, this message translates to:
  /// **'You left this on {device} {ago}'**
  String leftOn(String device, String ago);

  /// No description provided for @agoNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get agoNow;

  /// No description provided for @agoMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute ago} other{{count} minutes ago}}'**
  String agoMinutes(int count);

  /// No description provided for @agoHours.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour ago} other{{count} hours ago}}'**
  String agoHours(int count);

  /// No description provided for @goOnHere.
  ///
  /// In en, this message translates to:
  /// **'Continue here'**
  String get goOnHere;

  /// No description provided for @notNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get notNow;

  /// No description provided for @avatar.
  ///
  /// In en, this message translates to:
  /// **'Avatar'**
  String get avatar;

  /// No description provided for @avatarInitial.
  ///
  /// In en, this message translates to:
  /// **'Initial'**
  String get avatarInitial;

  /// No description provided for @changeAvatar.
  ///
  /// In en, this message translates to:
  /// **'Change avatar'**
  String get changeAvatar;

  /// No description provided for @playerSettings.
  ///
  /// In en, this message translates to:
  /// **'Player settings'**
  String get playerSettings;

  /// No description provided for @settingOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get settingOff;

  /// No description provided for @settingOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get settingOn;

  /// No description provided for @sleepTimer.
  ///
  /// In en, this message translates to:
  /// **'Sleep timer'**
  String get sleepTimer;

  /// No description provided for @sleepWhenItEnds.
  ///
  /// In en, this message translates to:
  /// **'When it ends'**
  String get sleepWhenItEnds;

  /// No description provided for @sleepDone.
  ///
  /// In en, this message translates to:
  /// **'Paused by the sleep timer'**
  String get sleepDone;

  /// No description provided for @sleepDoneHint.
  ///
  /// In en, this message translates to:
  /// **'Sleep well.'**
  String get sleepDoneHint;

  /// No description provided for @sleepStillWatching.
  ///
  /// In en, this message translates to:
  /// **'Still watching?'**
  String get sleepStillWatching;

  /// No description provided for @sleepStillWatchingHint.
  ///
  /// In en, this message translates to:
  /// **'Playback stops in {seconds, plural, =1{1 second} other{{seconds} seconds}}.'**
  String sleepStillWatchingHint(int seconds);

  /// No description provided for @keepWatching.
  ///
  /// In en, this message translates to:
  /// **'Keep watching'**
  String get keepWatching;

  /// No description provided for @exitPlayer.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get exitPlayer;

  /// No description provided for @leaveAppQuestion.
  ///
  /// In en, this message translates to:
  /// **'Leave Capy TV?'**
  String get leaveAppQuestion;

  /// No description provided for @leaveApp.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get leaveApp;

  /// No description provided for @listUpdatedPlain.
  ///
  /// In en, this message translates to:
  /// **'List updated.'**
  String get listUpdatedPlain;

  /// No description provided for @guideLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading the guide…'**
  String get guideLoading;

  /// No description provided for @restartApp.
  ///
  /// In en, this message translates to:
  /// **'Start again'**
  String get restartApp;

  /// No description provided for @serviceEndsSoon.
  ///
  /// In en, this message translates to:
  /// **'Your service for {name} ends on {date}: renew it with your provider so it keeps working.'**
  String serviceEndsSoon(String name, String date);

  /// No description provided for @openFailedHint.
  ///
  /// In en, this message translates to:
  /// **'Open it to try again, or edit it to check its details.'**
  String get openFailedHint;

  /// No description provided for @noMoviesInPlaylist.
  ///
  /// In en, this message translates to:
  /// **'This playlist has no movies.'**
  String get noMoviesInPlaylist;

  /// No description provided for @noSeriesInPlaylist.
  ///
  /// In en, this message translates to:
  /// **'This playlist has no series.'**
  String get noSeriesInPlaylist;

  /// No description provided for @volumeBoost.
  ///
  /// In en, this message translates to:
  /// **'Volume boost'**
  String get volumeBoost;

  /// No description provided for @streamInfo.
  ///
  /// In en, this message translates to:
  /// **'Stream info'**
  String get streamInfo;

  /// No description provided for @pictureFit.
  ///
  /// In en, this message translates to:
  /// **'Picture'**
  String get pictureFit;

  /// No description provided for @fitContain.
  ///
  /// In en, this message translates to:
  /// **'Fit'**
  String get fitContain;

  /// No description provided for @fitCover.
  ///
  /// In en, this message translates to:
  /// **'Fill'**
  String get fitCover;

  /// No description provided for @fitFill.
  ///
  /// In en, this message translates to:
  /// **'Stretch'**
  String get fitFill;

  /// No description provided for @playerEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Episodes'**
  String get playerEpisodes;

  /// No description provided for @playerChannels.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get playerChannels;

  /// No description provided for @lockControls.
  ///
  /// In en, this message translates to:
  /// **'Lock the screen'**
  String get lockControls;

  /// No description provided for @pipOff.
  ///
  /// In en, this message translates to:
  /// **'Picture-in-picture is turned off for this app in Android\'s settings'**
  String get pipOff;

  /// No description provided for @back10.
  ///
  /// In en, this message translates to:
  /// **'Back 10 seconds'**
  String get back10;

  /// No description provided for @reduceMotion.
  ///
  /// In en, this message translates to:
  /// **'Reduce motion'**
  String get reduceMotion;

  /// No description provided for @trailers.
  ///
  /// In en, this message translates to:
  /// **'Trailers'**
  String get trailers;

  /// No description provided for @trailersAlways.
  ///
  /// In en, this message translates to:
  /// **'Always'**
  String get trailersAlways;

  /// No description provided for @trailersWifi.
  ///
  /// In en, this message translates to:
  /// **'Only on Wi-Fi'**
  String get trailersWifi;

  /// No description provided for @trailersNever.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get trailersNever;

  /// No description provided for @volumeDown.
  ///
  /// In en, this message translates to:
  /// **'Volume down'**
  String get volumeDown;

  /// No description provided for @volumeUp.
  ///
  /// In en, this message translates to:
  /// **'Volume up'**
  String get volumeUp;

  /// No description provided for @previousTitle.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previousTitle;

  /// No description provided for @nextTitle.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get nextTitle;

  /// No description provided for @clearSearch.
  ///
  /// In en, this message translates to:
  /// **'Clear the search'**
  String get clearSearch;

  /// No description provided for @ratingOf.
  ///
  /// In en, this message translates to:
  /// **'rated {rating}'**
  String ratingOf(String rating);

  /// No description provided for @pinDigits.
  ///
  /// In en, this message translates to:
  /// **'{count} of {total} digits'**
  String pinDigits(int count, int total);

  /// No description provided for @forward10.
  ///
  /// In en, this message translates to:
  /// **'Forward 10 seconds'**
  String get forward10;

  /// No description provided for @mute.
  ///
  /// In en, this message translates to:
  /// **'Sound on or off'**
  String get mute;

  /// No description provided for @fullScreen.
  ///
  /// In en, this message translates to:
  /// **'Full screen'**
  String get fullScreen;

  /// No description provided for @timeLeftToday.
  ///
  /// In en, this message translates to:
  /// **'{n} min left for today'**
  String timeLeftToday(int n);

  /// No description provided for @tapToUnlock.
  ///
  /// In en, this message translates to:
  /// **'Tap the lock to unlock'**
  String get tapToUnlock;

  /// No description provided for @infoVideo.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get infoVideo;

  /// No description provided for @infoDecoder.
  ///
  /// In en, this message translates to:
  /// **'Decoder'**
  String get infoDecoder;

  /// No description provided for @infoBitrate.
  ///
  /// In en, this message translates to:
  /// **'Bitrate'**
  String get infoBitrate;

  /// No description provided for @infoBuffer.
  ///
  /// In en, this message translates to:
  /// **'Buffer'**
  String get infoBuffer;

  /// No description provided for @infoDropped.
  ///
  /// In en, this message translates to:
  /// **'Dropped frames'**
  String get infoDropped;

  /// No description provided for @infoCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get infoCopy;

  /// No description provided for @decoderHw.
  ///
  /// In en, this message translates to:
  /// **'Hardware'**
  String get decoderHw;

  /// No description provided for @decoderSw.
  ///
  /// In en, this message translates to:
  /// **'Software'**
  String get decoderSw;

  /// Stream info, in a browser: the film went over to software decoding by itself because the device's hardware decoder gave no picture
  ///
  /// In en, this message translates to:
  /// **'Software (the hardware showed no picture)'**
  String get decoderSwAuto;

  /// No description provided for @channelsMono.
  ///
  /// In en, this message translates to:
  /// **'MONO'**
  String get channelsMono;

  /// No description provided for @channelsStereo.
  ///
  /// In en, this message translates to:
  /// **'STEREO'**
  String get channelsStereo;

  /// No description provided for @fpsBadge.
  ///
  /// In en, this message translates to:
  /// **'{n} FPS'**
  String fpsBadge(int n);

  /// No description provided for @nOfTotal.
  ///
  /// In en, this message translates to:
  /// **'{n} of {total}'**
  String nOfTotal(int n, int total);

  /// No description provided for @refreshList.
  ///
  /// In en, this message translates to:
  /// **'Update channels and movies'**
  String get refreshList;

  /// No description provided for @listUpdating.
  ///
  /// In en, this message translates to:
  /// **'Updating the list…'**
  String get listUpdating;

  /// No description provided for @listUpdated.
  ///
  /// In en, this message translates to:
  /// **'List updated. New: {movies, plural, =1{1 movie} other{{movies} movies}}, {series, plural, =1{1 series} other{{series} series}} and {channels, plural, =1{1 channel} other{{channels} channels}}'**
  String listUpdated(int movies, int series, int channels);

  /// No description provided for @audioDelay.
  ///
  /// In en, this message translates to:
  /// **'Audio sync'**
  String get audioDelay;

  /// No description provided for @subtitleDelay.
  ///
  /// In en, this message translates to:
  /// **'Subtitle sync'**
  String get subtitleDelay;

  /// No description provided for @delayHint.
  ///
  /// In en, this message translates to:
  /// **'Use + if it comes before the picture'**
  String get delayHint;

  /// No description provided for @subtitleSize.
  ///
  /// In en, this message translates to:
  /// **'Subtitle size'**
  String get subtitleSize;

  /// No description provided for @subtitleBackground.
  ///
  /// In en, this message translates to:
  /// **'Subtitle background'**
  String get subtitleBackground;

  /// No description provided for @playNow.
  ///
  /// In en, this message translates to:
  /// **'Play now'**
  String get playNow;

  /// No description provided for @skipIntro.
  ///
  /// In en, this message translates to:
  /// **'Skip intro'**
  String get skipIntro;

  /// No description provided for @seriesIntro.
  ///
  /// In en, this message translates to:
  /// **'Series intro'**
  String get seriesIntro;

  /// No description provided for @introStart.
  ///
  /// In en, this message translates to:
  /// **'Mark start'**
  String get introStart;

  /// No description provided for @introEnd.
  ///
  /// In en, this message translates to:
  /// **'Mark end'**
  String get introEnd;

  /// No description provided for @introClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get introClear;

  /// No description provided for @introNotMarked.
  ///
  /// In en, this message translates to:
  /// **'Not marked'**
  String get introNotMarked;

  /// No description provided for @nextEpisodeIn.
  ///
  /// In en, this message translates to:
  /// **'Next episode in {seconds} s'**
  String nextEpisodeIn(int seconds);

  /// No description provided for @pictureInPicture.
  ///
  /// In en, this message translates to:
  /// **'Picture in picture'**
  String get pictureInPicture;

  /// No description provided for @pipBack.
  ///
  /// In en, this message translates to:
  /// **'Back to the window'**
  String get pipBack;

  /// No description provided for @sendTo.
  ///
  /// In en, this message translates to:
  /// **'Send to…'**
  String get sendTo;

  /// No description provided for @noOtherDevices.
  ///
  /// In en, this message translates to:
  /// **'No other device is signed in to this sync account.'**
  String get noOtherDevices;

  /// No description provided for @deviceActive.
  ///
  /// In en, this message translates to:
  /// **'Active now'**
  String get deviceActive;

  /// No description provided for @sentToDevice.
  ///
  /// In en, this message translates to:
  /// **'Sent to {device}'**
  String sentToDevice(String device);

  /// No description provided for @deviceProfileTitle.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get deviceProfileTitle;

  /// No description provided for @deviceProfileBody.
  ///
  /// In en, this message translates to:
  /// **'The profile that opens when the app starts here, without asking who is watching (a kids\' TV).'**
  String get deviceProfileBody;

  /// No description provided for @deviceProfileAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask who\'s watching'**
  String get deviceProfileAsk;

  /// No description provided for @profileAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio language'**
  String get profileAudio;

  /// No description provided for @profileSubtitles.
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get profileSubtitles;

  /// No description provided for @asInSettings.
  ///
  /// In en, this message translates to:
  /// **'As in Settings'**
  String get asInSettings;

  /// No description provided for @dailyLimit.
  ///
  /// In en, this message translates to:
  /// **'Time per day'**
  String get dailyLimit;

  /// No description provided for @dailyLimitHint.
  ///
  /// In en, this message translates to:
  /// **'Counted on each device. When it runs out, the PIN gives more.'**
  String get dailyLimitHint;

  /// No description provided for @noLimit.
  ///
  /// In en, this message translates to:
  /// **'No limit'**
  String get noLimit;

  /// No description provided for @timeUp.
  ///
  /// In en, this message translates to:
  /// **'That\'s all for today'**
  String get timeUp;

  /// No description provided for @timeUpHint.
  ///
  /// In en, this message translates to:
  /// **'There\'s more tomorrow. A grown-up can give more time with the PIN.'**
  String get timeUpHint;

  /// No description provided for @moreTime.
  ///
  /// In en, this message translates to:
  /// **'30 more minutes'**
  String get moreTime;

  /// No description provided for @moreTimeNeedsPin.
  ///
  /// In en, this message translates to:
  /// **'More time needs a parental PIN: set one in Profiles.'**
  String get moreTimeNeedsPin;

  /// No description provided for @hoursOnly.
  ///
  /// In en, this message translates to:
  /// **'{h} h'**
  String hoursOnly(int h);

  /// No description provided for @goLive.
  ///
  /// In en, this message translates to:
  /// **'Go live'**
  String get goLive;

  /// No description provided for @updateTitle.
  ///
  /// In en, this message translates to:
  /// **'Capy TV {version}'**
  String updateTitle(String version);

  /// No description provided for @updateBody.
  ///
  /// In en, this message translates to:
  /// **'A new version is ready for this device.'**
  String get updateBody;

  /// No description provided for @updateNow.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get updateNow;

  /// No description provided for @updateLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get updateLater;

  /// No description provided for @updateInBackground.
  ///
  /// In en, this message translates to:
  /// **'Continue in background'**
  String get updateInBackground;

  /// No description provided for @updateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading the update…'**
  String get updateDownloading;

  /// No description provided for @updateAllowTitle.
  ///
  /// In en, this message translates to:
  /// **'Allow the update'**
  String get updateAllowTitle;

  /// No description provided for @updateAllowBody.
  ///
  /// In en, this message translates to:
  /// **'Android asks for this once: on the screen that opens, allow Capy TV to install apps, then come back here.'**
  String get updateAllowBody;

  /// No description provided for @updateAllowManual.
  ///
  /// In en, this message translates to:
  /// **'In this device\'s settings, allow Capy TV to install unknown apps, then come back here.'**
  String get updateAllowManual;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get openSettings;

  /// No description provided for @updateFailed.
  ///
  /// In en, this message translates to:
  /// **'The update didn\'t go through. Try again in a moment.'**
  String get updateFailed;

  /// No description provided for @updateDamaged.
  ///
  /// In en, this message translates to:
  /// **'The download arrived damaged and was thrown away. Try again.'**
  String get updateDamaged;

  /// No description provided for @updateTo.
  ///
  /// In en, this message translates to:
  /// **'Update to {version}'**
  String updateTo(String version);

  /// No description provided for @appVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String appVersion(String version);

  /// No description provided for @checkUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get checkUpdates;

  /// No description provided for @upToDate.
  ///
  /// In en, this message translates to:
  /// **'This is the latest version.'**
  String get upToDate;

  /// No description provided for @backgroundPlay.
  ///
  /// In en, this message translates to:
  /// **'Keep playing outside the app'**
  String get backgroundPlay;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @stopPlaying.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stopPlaying;

  /// No description provided for @multiview.
  ///
  /// In en, this message translates to:
  /// **'Multiview'**
  String get multiview;

  /// No description provided for @multiviewAdd.
  ///
  /// In en, this message translates to:
  /// **'Add a channel'**
  String get multiviewAdd;

  /// No description provided for @multiviewChange.
  ///
  /// In en, this message translates to:
  /// **'Change channel'**
  String get multiviewChange;

  /// No description provided for @multiviewRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get multiviewRemove;

  /// No description provided for @multiviewFull.
  ///
  /// In en, this message translates to:
  /// **'Full screen'**
  String get multiviewFull;

  /// No description provided for @record.
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get record;

  /// No description provided for @stopRecording.
  ///
  /// In en, this message translates to:
  /// **'Stop recording'**
  String get stopRecording;

  /// No description provided for @recordings.
  ///
  /// In en, this message translates to:
  /// **'Recordings'**
  String get recordings;

  /// No description provided for @recordingSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved in Recordings (in Settings, or next to your playlists)'**
  String get recordingSaved;

  /// No description provided for @recordingFailed.
  ///
  /// In en, this message translates to:
  /// **'Nothing was recorded'**
  String get recordingFailed;

  /// No description provided for @noRecordings.
  ///
  /// In en, this message translates to:
  /// **'Your recordings show here: those from the player and those scheduled from the guide.'**
  String get noRecordings;

  /// No description provided for @deleteRecording.
  ///
  /// In en, this message translates to:
  /// **'Delete this recording?'**
  String get deleteRecording;

  /// No description provided for @recordingNotDeleted.
  ///
  /// In en, this message translates to:
  /// **'This recording couldn\'t be deleted: another program may have it open'**
  String get recordingNotDeleted;

  /// No description provided for @cancelScheduledQuestion.
  ///
  /// In en, this message translates to:
  /// **'Cancel this scheduled recording?'**
  String get cancelScheduledQuestion;

  /// No description provided for @stopRecordingQuestion.
  ///
  /// In en, this message translates to:
  /// **'Stop this recording? What was recorded is kept.'**
  String get stopRecordingQuestion;

  /// No description provided for @keepIt.
  ///
  /// In en, this message translates to:
  /// **'Keep it'**
  String get keepIt;

  /// No description provided for @recordingUntitled.
  ///
  /// In en, this message translates to:
  /// **'Channel'**
  String get recordingUntitled;

  /// No description provided for @recordingStopped.
  ///
  /// In en, this message translates to:
  /// **'The recording stopped: it couldn\'t be saved further (is the storage full?)'**
  String get recordingStopped;

  /// No description provided for @recordingNoRoom.
  ///
  /// In en, this message translates to:
  /// **'Not enough room left on this device to record'**
  String get recordingNoRoom;

  /// No description provided for @recordingStoppedNoRoom.
  ///
  /// In en, this message translates to:
  /// **'The recording stopped: this device is nearly full. What was recorded is saved.'**
  String get recordingStoppedNoRoom;

  /// No description provided for @recordingAppClosedNote.
  ///
  /// In en, this message translates to:
  /// **'Android closed Capy TV meanwhile. Open it to record what is still on.'**
  String get recordingAppClosedNote;

  /// No description provided for @closeWithRecordingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Close Capy TV?'**
  String get closeWithRecordingsTitle;

  /// No description provided for @closeWithRecordingsBody.
  ///
  /// In en, this message translates to:
  /// **'Something is being recorded or is scheduled. With the app closed it will not be recorded.'**
  String get closeWithRecordingsBody;

  /// No description provided for @closeAnyway.
  ///
  /// In en, this message translates to:
  /// **'Close anyway'**
  String get closeAnyway;

  /// No description provided for @keepOpen.
  ///
  /// In en, this message translates to:
  /// **'Keep it open'**
  String get keepOpen;

  /// No description provided for @keepAppOpenToRecord.
  ///
  /// In en, this message translates to:
  /// **'On iPhone, keep Capy TV open on screen until it is recorded: iOS stops it in the background.'**
  String get keepAppOpenToRecord;

  /// No description provided for @keepAppOpenToCast.
  ///
  /// In en, this message translates to:
  /// **'On iPhone, keep Capy TV open: a live channel stops reaching the TV once the app leaves the screen.'**
  String get keepAppOpenToCast;

  /// No description provided for @castNoSubtitles.
  ///
  /// In en, this message translates to:
  /// **'Subtitles do not reach the TV: there the video plays without them.'**
  String get castNoSubtitles;

  /// No description provided for @castOtherAudio.
  ///
  /// In en, this message translates to:
  /// **'The TV plays the video\'s own audio, not the language chosen here.'**
  String get castOtherAudio;

  /// No description provided for @sendToYourDevices.
  ///
  /// In en, this message translates to:
  /// **'Your devices'**
  String get sendToYourDevices;

  /// No description provided for @sendToNearby.
  ///
  /// In en, this message translates to:
  /// **'On this network'**
  String get sendToNearby;

  /// No description provided for @castSearching.
  ///
  /// In en, this message translates to:
  /// **'Looking for Chromecasts…'**
  String get castSearching;

  /// No description provided for @castNoneFound.
  ///
  /// In en, this message translates to:
  /// **'No Chromecast found on this network.'**
  String get castNoneFound;

  /// No description provided for @castByAddress.
  ///
  /// In en, this message translates to:
  /// **'Connect by address…'**
  String get castByAddress;

  /// No description provided for @castAddressHint.
  ///
  /// In en, this message translates to:
  /// **'IP address, like 192.168.1.20'**
  String get castAddressHint;

  /// No description provided for @castAddressInvalid.
  ///
  /// In en, this message translates to:
  /// **'That is no device\'s address: write its IP, like 192.168.1.20'**
  String get castAddressInvalid;

  /// No description provided for @castConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get castConnect;

  /// No description provided for @castConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {device}…'**
  String castConnecting(String device);

  /// No description provided for @castStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting on {device}…'**
  String castStarting(String device);

  /// No description provided for @castTrying.
  ///
  /// In en, this message translates to:
  /// **'Trying another copy ({n} of {total})…'**
  String castTrying(int n, int total);

  /// No description provided for @castBuffering.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get castBuffering;

  /// No description provided for @castPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get castPaused;

  /// No description provided for @castLost.
  ///
  /// In en, this message translates to:
  /// **'Connection to {device} lost. Reconnecting…'**
  String castLost(String device);

  /// No description provided for @castStopped.
  ///
  /// In en, this message translates to:
  /// **'Casting stopped.'**
  String get castStopped;

  /// No description provided for @castConnectFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t connect to {device}.'**
  String castConnectFailed(String device);

  /// No description provided for @castLaunchFailed.
  ///
  /// In en, this message translates to:
  /// **'{device} didn\'t open its player.'**
  String castLaunchFailed(String device);

  /// No description provided for @castCannotPlay.
  ///
  /// In en, this message translates to:
  /// **'{device} can\'t play this.'**
  String castCannotPlay(String device);

  /// No description provided for @castRelayUnreachable.
  ///
  /// In en, this message translates to:
  /// **'{device} couldn\'t connect to this device. Check that its firewall lets it in, and that both are on the same network.'**
  String castRelayUnreachable(String device);

  /// No description provided for @castProviderRefused.
  ///
  /// In en, this message translates to:
  /// **'Your provider refused this to {device}: your account may not allow another connection right now.'**
  String castProviderRefused(String device);

  /// No description provided for @castTakenOver.
  ///
  /// In en, this message translates to:
  /// **'{device} is now playing something else.'**
  String castTakenOver(String device);

  /// No description provided for @castFinished.
  ///
  /// In en, this message translates to:
  /// **'Finished.'**
  String get castFinished;

  /// No description provided for @castingTo.
  ///
  /// In en, this message translates to:
  /// **'Casting to {device}'**
  String castingTo(String device);

  /// No description provided for @castMkvMayFail.
  ///
  /// In en, this message translates to:
  /// **'MKV files may not play on {device}.'**
  String castMkvMayFail(String device);

  /// No description provided for @castKeepOn.
  ///
  /// In en, this message translates to:
  /// **'Keep this device on and on the same Wi-Fi while casting a channel.'**
  String get castKeepOn;

  /// No description provided for @castPlayHere.
  ///
  /// In en, this message translates to:
  /// **'Play here'**
  String get castPlayHere;

  /// No description provided for @stopCasting.
  ///
  /// In en, this message translates to:
  /// **'Stop casting'**
  String get stopCasting;

  /// No description provided for @castUnsupportedLive.
  ///
  /// In en, this message translates to:
  /// **'This channel\'s format can\'t be cast. Your devices can still play it.'**
  String get castUnsupportedLive;

  /// No description provided for @castUnsupportedFile.
  ///
  /// In en, this message translates to:
  /// **'This video\'s format ({format}) can\'t be cast.'**
  String castUnsupportedFile(String format);

  /// No description provided for @castUnsupportedLocal.
  ///
  /// In en, this message translates to:
  /// **'Recordings and earlier programmes can\'t be sent to Chromecast yet.'**
  String get castUnsupportedLocal;

  /// No description provided for @castNoHls.
  ///
  /// In en, this message translates to:
  /// **'Your provider doesn\'t offer this channel in the format Chromecast needs.'**
  String get castNoHls;

  /// No description provided for @castLostEnded.
  ///
  /// In en, this message translates to:
  /// **'The connection to {device} was lost.'**
  String castLostEnded(String device);

  /// No description provided for @recordingEncrypted.
  ///
  /// In en, this message translates to:
  /// **'This channel can\'t be recorded: it is encrypted'**
  String get recordingEncrypted;

  /// No description provided for @recordingFragmented.
  ///
  /// In en, this message translates to:
  /// **'This channel can\'t be recorded: the app can\'t save its format'**
  String get recordingFragmented;

  /// No description provided for @recordingSeparateAudio.
  ///
  /// In en, this message translates to:
  /// **'This channel can\'t be recorded: its sound and picture come separately'**
  String get recordingSeparateAudio;

  /// No description provided for @recordingCut.
  ///
  /// In en, this message translates to:
  /// **'The recording stopped because the channel dropped. What was recorded is saved.'**
  String get recordingCut;

  /// No description provided for @cancelRecording.
  ///
  /// In en, this message translates to:
  /// **'Cancel recording'**
  String get cancelRecording;

  /// No description provided for @scheduledRecordings.
  ///
  /// In en, this message translates to:
  /// **'Scheduled'**
  String get scheduledRecordings;

  /// No description provided for @recordedFiles.
  ///
  /// In en, this message translates to:
  /// **'Recorded'**
  String get recordedFiles;

  /// No description provided for @recordingScheduled.
  ///
  /// In en, this message translates to:
  /// **'Recording scheduled'**
  String get recordingScheduled;

  /// No description provided for @recordingNow.
  ///
  /// In en, this message translates to:
  /// **'Recording now'**
  String get recordingNow;

  /// No description provided for @recordingDone.
  ///
  /// In en, this message translates to:
  /// **'Recorded'**
  String get recordingDone;

  /// No description provided for @recordingFailedState.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t be recorded'**
  String get recordingFailedState;

  /// No description provided for @recordingFailedBecause.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t be recorded: {why}'**
  String recordingFailedBecause(String why);

  /// No description provided for @recordingPartly.
  ///
  /// In en, this message translates to:
  /// **'Recorded in part: {why}'**
  String recordingPartly(String why);

  /// No description provided for @recordingMissedBecause.
  ///
  /// In en, this message translates to:
  /// **'Missed: {why}'**
  String recordingMissedBecause(String why);

  /// No description provided for @recordingRetrying.
  ///
  /// In en, this message translates to:
  /// **'Trying again shortly: {why}'**
  String recordingRetrying(String why);

  /// No description provided for @problemAppClosed.
  ///
  /// In en, this message translates to:
  /// **'the app was closed'**
  String get problemAppClosed;

  /// No description provided for @problemAsleep.
  ///
  /// In en, this message translates to:
  /// **'the device was asleep'**
  String get problemAsleep;

  /// No description provided for @problemNoNetwork.
  ///
  /// In en, this message translates to:
  /// **'the channel couldn\'t be reached'**
  String get problemNoNetwork;

  /// No description provided for @problemChannelGone.
  ///
  /// In en, this message translates to:
  /// **'the channel is no longer in the playlist'**
  String get problemChannelGone;

  /// No description provided for @problemUnsupported.
  ///
  /// In en, this message translates to:
  /// **'the app can\'t save this channel in the format it comes in'**
  String get problemUnsupported;

  /// No description provided for @problemNothingCame.
  ///
  /// In en, this message translates to:
  /// **'the channel sent nothing'**
  String get problemNothingCame;

  /// No description provided for @problemNoSpace.
  ///
  /// In en, this message translates to:
  /// **'the device has no room left'**
  String get problemNoSpace;

  /// No description provided for @problemWriteFailed.
  ///
  /// In en, this message translates to:
  /// **'the file couldn\'t be written'**
  String get problemWriteFailed;

  /// No description provided for @scheduleNote.
  ///
  /// In en, this message translates to:
  /// **'Recorded while the app is running, even in the background. If it is closed at that time, the recording is missed.'**
  String get scheduleNote;

  /// No description provided for @recordEarly.
  ///
  /// In en, this message translates to:
  /// **'Start before the programme'**
  String get recordEarly;

  /// No description provided for @recordLate.
  ///
  /// In en, this message translates to:
  /// **'Go on after the programme'**
  String get recordLate;

  /// No description provided for @recordMarginsHint.
  ///
  /// In en, this message translates to:
  /// **'For a match with extra time or a channel running late. For what you schedule from now on.'**
  String get recordMarginsHint;

  /// No description provided for @recordingStartsAt.
  ///
  /// In en, this message translates to:
  /// **'Recording starts at {time}'**
  String recordingStartsAt(String time);

  /// No description provided for @recordingChannel.
  ///
  /// In en, this message translates to:
  /// **'Recording {channel}'**
  String recordingChannel(String channel);

  /// No description provided for @recordingChannels.
  ///
  /// In en, this message translates to:
  /// **'Recording {count} channels'**
  String recordingChannels(int count);

  /// No description provided for @removeFromList.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeFromList;

  /// No description provided for @recordingPaused.
  ///
  /// In en, this message translates to:
  /// **'Recordings paused'**
  String get recordingPaused;

  /// No description provided for @recordingPausedNote.
  ///
  /// In en, this message translates to:
  /// **'Android lets the app record in the background for a few hours a day. Open Capy TV and they go on.'**
  String get recordingPausedNote;

  /// No description provided for @installOtherDevice.
  ///
  /// In en, this message translates to:
  /// **'Install on another device'**
  String get installOtherDevice;

  /// No description provided for @installLinkLoading.
  ///
  /// In en, this message translates to:
  /// **'Getting a link…'**
  String get installLinkLoading;

  /// No description provided for @installLinkType.
  ///
  /// In en, this message translates to:
  /// **'In Downloader on the Fire TV, type this address'**
  String get installLinkType;

  /// No description provided for @installLinkScan.
  ///
  /// In en, this message translates to:
  /// **'On a phone, scan the code.'**
  String get installLinkScan;

  /// No description provided for @installLinkValid.
  ///
  /// In en, this message translates to:
  /// **'{minutes, plural, =1{Valid for 1 minute} other{Valid for {minutes} minutes}}'**
  String installLinkValid(int minutes);

  /// No description provided for @installLinkNoApp.
  ///
  /// In en, this message translates to:
  /// **'The sync server has no copy of the app to share. Whoever runs it can put one there.'**
  String get installLinkNoApp;

  /// No description provided for @installLinkTooMany.
  ///
  /// In en, this message translates to:
  /// **'Too many links in a short time. Try again later.'**
  String get installLinkTooMany;

  /// No description provided for @avatarCredits.
  ///
  /// In en, this message translates to:
  /// **'Profile avatars drawn with DiceBear (dicebear.com): \"Croodles - Doodle your face\" by vijay verma and \"Fun Emoji Set\" by Davis Uche, adapted for the app, under CC BY 4.0 (creativecommons.org/licenses/by/4.0); Notionists by Zoish, Lorelei by Lisa Wischofsky, Open Peeps by Pablo Stanley, and Critters and Voxel Bot by DiceBear, under CC0 1.0.'**
  String get avatarCredits;

  /// No description provided for @titleBarSearch.
  ///
  /// In en, this message translates to:
  /// **'Search in this playlist…'**
  String get titleBarSearch;

  /// No description provided for @titleBarSearchShortcut.
  ///
  /// In en, this message translates to:
  /// **'Ctrl K'**
  String get titleBarSearchShortcut;

  /// No description provided for @playlistKindM3u.
  ///
  /// In en, this message translates to:
  /// **'M3U'**
  String get playlistKindM3u;

  /// No description provided for @playlistKindCombined.
  ///
  /// In en, this message translates to:
  /// **'Combined'**
  String get playlistKindCombined;

  /// No description provided for @windowMinimize.
  ///
  /// In en, this message translates to:
  /// **'Minimize'**
  String get windowMinimize;

  /// No description provided for @windowMaximize.
  ///
  /// In en, this message translates to:
  /// **'Maximize'**
  String get windowMaximize;

  /// No description provided for @windowRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get windowRestore;

  /// No description provided for @errorExpiredOn.
  ///
  /// In en, this message translates to:
  /// **'The account ended on {date}. Ask your provider to renew it.'**
  String errorExpiredOn(String date);

  /// No description provided for @deletePlaylistInCombined.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{It\'s part of the combined playlist {names}, which will go on without it.} other{It\'s part of the combined playlists {names}, which will go on without it.}}'**
  String deletePlaylistInCombined(int count, String names);

  /// No description provided for @sleepSoon.
  ///
  /// In en, this message translates to:
  /// **'The sleep timer stops it in a minute. Tap or press any button to keep watching {n} more minutes.'**
  String sleepSoon(int n);

  /// No description provided for @sleepExtended.
  ///
  /// In en, this message translates to:
  /// **'Sleep timer: {n} more minutes'**
  String sleepExtended(int n);

  /// No description provided for @guideFailed.
  ///
  /// In en, this message translates to:
  /// **'The guide couldn\'t be downloaded.'**
  String get guideFailed;

  /// No description provided for @rankLabel.
  ///
  /// In en, this message translates to:
  /// **'Number {n}'**
  String rankLabel(int n);

  /// No description provided for @watchedPercent.
  ///
  /// In en, this message translates to:
  /// **'{percent}% watched'**
  String watchedPercent(int percent);

  /// No description provided for @holdOkChannelHint.
  ///
  /// In en, this message translates to:
  /// **'Hold OK or press Info on a channel: what it shows next, and Favorites'**
  String get holdOkChannelHint;

  /// No description provided for @controlsStay.
  ///
  /// In en, this message translates to:
  /// **'Player controls stay'**
  String get controlsStay;

  /// No description provided for @controlsStayMoment.
  ///
  /// In en, this message translates to:
  /// **'A moment'**
  String get controlsStayMoment;

  /// No description provided for @controlsStaySeconds.
  ///
  /// In en, this message translates to:
  /// **'{n} seconds'**
  String controlsStaySeconds(int n);

  /// No description provided for @webNoSecureStorage.
  ///
  /// In en, this message translates to:
  /// **'{device} saved the playlist, but not its password: its secure storage isn\'t working.'**
  String webNoSecureStorage(String device);

  /// No description provided for @deviceMode.
  ///
  /// In en, this message translates to:
  /// **'Use this device as'**
  String get deviceMode;

  /// No description provided for @deviceModeAuto.
  ///
  /// In en, this message translates to:
  /// **'As it says it is'**
  String get deviceModeAuto;

  /// No description provided for @deviceModeTv.
  ///
  /// In en, this message translates to:
  /// **'A TV, with a remote'**
  String get deviceModeTv;

  /// No description provided for @deviceModeTouch.
  ///
  /// In en, this message translates to:
  /// **'A phone or tablet, by touch'**
  String get deviceModeTouch;

  /// No description provided for @appliesNextStart.
  ///
  /// In en, this message translates to:
  /// **'This applies the next time the app opens'**
  String get appliesNextStart;

  /// No description provided for @playbackPosition.
  ///
  /// In en, this message translates to:
  /// **'Position'**
  String get playbackPosition;

  /// No description provided for @previousChannel.
  ///
  /// In en, this message translates to:
  /// **'Previous channel'**
  String get previousChannel;

  /// No description provided for @subtitleOutline.
  ///
  /// In en, this message translates to:
  /// **'Subtitle outline'**
  String get subtitleOutline;

  /// No description provided for @subtitleBandDarkness.
  ///
  /// In en, this message translates to:
  /// **'Background darkness'**
  String get subtitleBandDarkness;

  /// No description provided for @subtitleLift.
  ///
  /// In en, this message translates to:
  /// **'Subtitle height'**
  String get subtitleLift;

  /// No description provided for @subtitleLiftBottom.
  ///
  /// In en, this message translates to:
  /// **'At the bottom'**
  String get subtitleLiftBottom;

  /// No description provided for @subtitleLiftHigher.
  ///
  /// In en, this message translates to:
  /// **'Higher'**
  String get subtitleLiftHigher;

  /// No description provided for @subtitleLiftHighest.
  ///
  /// In en, this message translates to:
  /// **'Much higher'**
  String get subtitleLiftHighest;

  /// No description provided for @subtitlePicture.
  ///
  /// In en, this message translates to:
  /// **'picture'**
  String get subtitlePicture;

  /// No description provided for @subtitlePictureHidden.
  ///
  /// In en, this message translates to:
  /// **'These subtitles are pictures: with the hardware decoder they can\'t show. Choose the software decoder in the player\'s settings.'**
  String get subtitlePictureHidden;

  /// No description provided for @playingOnDevice.
  ///
  /// In en, this message translates to:
  /// **'Playing on {device}'**
  String playingOnDevice(String device);

  /// No description provided for @playingOnDeviceHint.
  ///
  /// In en, this message translates to:
  /// **'Here it stopped, so the provider sees one connection. It goes on from the same place.'**
  String get playingOnDeviceHint;

  /// No description provided for @keepWatchingHere.
  ///
  /// In en, this message translates to:
  /// **'Keep watching here'**
  String get keepWatchingHere;

  /// No description provided for @failExpired.
  ///
  /// In en, this message translates to:
  /// **'The account isn\'t active any more. Ask your provider to renew it.'**
  String get failExpired;

  /// No description provided for @failBusy.
  ///
  /// In en, this message translates to:
  /// **'All the connections the account allows are in use on other devices. Stop one, then try again.'**
  String get failBusy;

  /// No description provided for @failUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This device can\'t play this format. In the player\'s settings, try the other video decoder.'**
  String get failUnsupported;

  /// No description provided for @failUnsupportedHere.
  ///
  /// In en, this message translates to:
  /// **'This device can\'t play this format. Try another copy, or something else.'**
  String get failUnsupportedHere;

  /// No description provided for @textSize.
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get textSize;

  /// No description provided for @textSizeDevice.
  ///
  /// In en, this message translates to:
  /// **'As the device\'s'**
  String get textSizeDevice;

  /// No description provided for @watchAgain.
  ///
  /// In en, this message translates to:
  /// **'Watch again'**
  String get watchAgain;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
