// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Capy TV';

  @override
  String get playlists => 'Playlists';

  @override
  String get addPlaylist => 'Add playlist';

  @override
  String get playlistTypeXtream => 'Username and password (Xtream)';

  @override
  String get playlistTypeM3u => 'Link (M3U)';

  @override
  String get playlistKindXtream => 'Xtream Codes';

  @override
  String get playlistName => 'Name';

  @override
  String get serverUrl => 'Server URL';

  @override
  String get username => 'Username';

  @override
  String get password => 'Password';

  @override
  String get m3uUrl => 'M3U playlist URL';

  @override
  String get save => 'Save';

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String deletePlaylistQuestion(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get connecting => 'Connecting…';

  @override
  String get required => 'Required';

  @override
  String get liveTv => 'Live TV';

  @override
  String get movies => 'Movies';

  @override
  String get series => 'Series';

  @override
  String get nothingHere => 'Nothing here';

  @override
  String get retry => 'Retry';

  @override
  String get play => 'Play';

  @override
  String season(int n) {
    return 'Season $n';
  }

  @override
  String get seasonSpecials => 'Specials';

  @override
  String minutes(int n) {
    return '$n min';
  }

  @override
  String get status => 'Status';

  @override
  String get expires => 'Expires';

  @override
  String get neverExpires => 'Never';

  @override
  String get connections => 'Connections';

  @override
  String connectionsValue(int active, int max) {
    return '$active of $max in use';
  }

  @override
  String get outputFormats => 'Output formats';

  @override
  String get serverTimezone => 'Server time zone';

  @override
  String get providerMessage => 'Message from the provider';

  @override
  String sentFrom(String device) {
    return 'Sent from $device';
  }

  @override
  String get switchPlaylist => 'Switch playlist';

  @override
  String get trialAccount => 'Trial account';

  @override
  String get nowPlaying => 'Now';

  @override
  String get upNext => 'Next';

  @override
  String get noGuide => 'No guide data for this channel';

  @override
  String catchupDays(int n) {
    String _temp0 = intl.Intl.pluralLogic(n, locale: localeName, other: '$n days', one: '1 day');
    return 'Earlier programmes: $_temp0';
  }

  @override
  String get audioAndSubtitles => 'Audio & subtitles';

  @override
  String get audio => 'Audio';

  @override
  String get subtitles => 'Subtitles';

  @override
  String get off => 'Off';

  @override
  String get notAvailable => 'Not available';

  @override
  String get speed => 'Speed';

  @override
  String get normalSpeed => 'Normal';

  @override
  String get live => 'LIVE';

  @override
  String trackN(int n) {
    return 'Track $n';
  }

  @override
  String languageName(String code) {
    String _temp0 = intl.Intl.selectLogic(code, {
      'spa': 'Spanish',
      'eng': 'English',
      'fra': 'French',
      'deu': 'German',
      'ita': 'Italian',
      'por': 'Portuguese',
      'jpn': 'Japanese',
      'kor': 'Korean',
      'zho': 'Chinese',
      'ara': 'Arabic',
      'rus': 'Russian',
      'other': '$code',
    });
    return '$_temp0';
  }

  @override
  String listPartsMissing(String names) {
    return '$names did not answer: the lists stay as they were.';
  }

  @override
  String get errorBadAddress => 'Check the server\'s address: it can\'t be one as written.';

  @override
  String get errorWrongServer => 'Check the server\'s address, the username and the password.';

  @override
  String get errorProviderBusy => 'Your provider is overloaded or down for a while. Try again in a few minutes.';

  @override
  String get errorNoSpace => 'There is no room left on this device for the list. Free some space and try again.';

  @override
  String get errorOffline => 'This device seems to be offline. Check the Wi-Fi or the cable, then try again.';

  @override
  String get errorDns =>
      'The server\'s name couldn\'t be found. Check that this device is online and that the address is written right.';

  @override
  String get errorTls =>
      'The secure connection to the server failed. Check this device\'s date and time: when they are wrong, no secure connection works.';

  @override
  String get errorUnreachable =>
      'Couldn\'t connect to the server. Check the address and your connection; if both are fine, the provider may be down.';

  @override
  String get errorTimeout => 'The server is not responding.';

  @override
  String get errorUnauthorized => 'Wrong username or password, or the account is blocked.';

  @override
  String errorInactive(String status) {
    return 'The account is not active ($status). Ask your provider to renew or reactivate it.';
  }

  @override
  String get statusActive => 'Active';

  @override
  String get statusExpired => 'Expired';

  @override
  String get statusBanned => 'Banned';

  @override
  String get statusDisabled => 'Disabled';

  @override
  String get statusTrial => 'Trial';

  @override
  String get statusUnknown => 'Unknown';

  @override
  String get untitled => 'Untitled';

  @override
  String get ungrouped => 'No category';

  @override
  String episodeNumber(int number) {
    return 'Episode $number';
  }

  @override
  String errorHttp(String code) {
    return 'The server replied with error $code. Try again in a while; if it goes on, ask your provider.';
  }

  @override
  String get errorBadResponse => 'The server did not return a valid response.';

  @override
  String get errorNotFound => 'The server doesn\'t have it. Check the address; if it\'s right, ask your provider.';

  @override
  String get errorEmptyPlaylist => 'The playlist is empty or is not a valid M3U file.';

  @override
  String get errorUnknown => 'Something went wrong. Try again; if it keeps happening, restart the app.';

  @override
  String get seeAll => 'See all';

  @override
  String get details => 'Details';

  @override
  String get welcomeTitle => 'Your TV, your way';

  @override
  String get welcomeBody =>
      'Connect your TV service with the details your provider gave you: a username and password, or a link. The app includes no channels: you use your own subscription.';

  @override
  String episodesCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(n, locale: localeName, other: '$n episodes', one: '1 episode');
    return '$_temp0';
  }

  @override
  String get watchLive => 'Watch live';

  @override
  String get home => 'Home';

  @override
  String get search => 'Search';

  @override
  String get searchHint => 'Movies, series, channels or what is on';

  @override
  String get myList => 'Favorites';

  @override
  String get inMyList => 'In favorites';

  @override
  String get continueWatching => 'Continue watching';

  @override
  String get recentChannels => 'Recently watched channels';

  @override
  String get favoriteChannels => 'Favorite channels';

  @override
  String get favoriteMovies => 'Favorite movies';

  @override
  String get favoriteSeries => 'Favorite series';

  @override
  String get homeEmptyTitle => 'Make it yours';

  @override
  String get homeEmptyBody => 'What you watch and add to Favorites shows up here, ready to pick up where you left off.';

  @override
  String resumedFrom(String time) {
    return 'Resuming from $time';
  }

  @override
  String get startOver => 'Start over';

  @override
  String get nextEpisode => 'Next episode';

  @override
  String get nextChannel => 'Next channel';

  @override
  String get channelUnavailable => 'This channel isn\'t playing right now';

  @override
  String get reconnecting => 'Reconnecting…';

  @override
  String get videoUnavailable => 'This video couldn\'t be played';

  @override
  String get unavailableHint =>
      'Your provider isn\'t sending it at the moment. Try again in a little while or pick something else.';

  @override
  String get continueAction => 'Continue';

  @override
  String get settings => 'Settings';

  @override
  String get playback => 'Playback';

  @override
  String get appLanguage => 'App language';

  @override
  String get appLanguageDevice => 'As the device';

  @override
  String get languageSelf => 'English';

  @override
  String get advanced => 'Advanced';

  @override
  String get preferredAudio => 'Preferred audio language';

  @override
  String get preferredSubtitles => 'Preferred subtitles';

  @override
  String get automatic => 'Automatic';

  @override
  String get liveFormat => 'Live stream format';

  @override
  String get liveFormatTs => 'MPEG-TS (most compatible)';

  @override
  String get liveFormatHls => 'HLS (m3u8)';

  @override
  String get decoder => 'Video decoder';

  @override
  String get decoderHardware => 'Hardware (recommended)';

  @override
  String get decoderSoftware => 'Software (compatibility)';

  @override
  String get failMissing =>
      'The provider no longer has it at this address. Try updating the list, or pick something else.';

  @override
  String get failDenied => 'The provider refused it. Try again in a while; if it goes on, ask your provider.';

  @override
  String get failNetwork => 'The provider can\'t be reached. Check this device\'s internet connection.';

  @override
  String get decoderHint =>
      'The signal arrived, but the picture didn\'t start. In Settings, Playback, Advanced, set Video decoder to Software.';

  @override
  String get noResults => 'No results';

  @override
  String get clearHistory => 'Clear watch history';

  @override
  String get clearHistoryQuestion =>
      'Clear what this profile watched in this playlist? With sync, on all your devices too.';

  @override
  String get removeFromContinue => 'Removed from Continue watching';

  @override
  String get deletePlaylistEverywhere => 'With sync on, it goes from all the devices of this account.';

  @override
  String get historyCleared => 'Watch history cleared';

  @override
  String get loadingCatalog => 'Loading the full catalog…';

  @override
  String get organizingCatalog => 'Putting your catalog in order…';

  @override
  String get importedPlaylist => 'In the playlist';

  @override
  String importedCount(String count) {
    return '$count imported';
  }

  @override
  String downloadingCatalogPercent(int percent) {
    return 'Downloading the catalog… $percent%';
  }

  @override
  String downloadingCatalogSize(String size) {
    return 'Downloading the catalog… $size MB';
  }

  @override
  String get typeToSearch => 'Type at least 2 letters';

  @override
  String minutesLeft(int n) {
    return '$n min left';
  }

  @override
  String get tvGuide => 'TV guide';

  @override
  String get holdOkHint => 'Hold OK or press Info on a programme: its details, catch-up and recording';

  @override
  String get recentlyAdded => 'Recently added';

  @override
  String get topRated => 'Top rated';

  @override
  String get newReleases => 'New releases';

  @override
  String get newEpisodes => 'New episodes';

  @override
  String get newMovies => 'New movies';

  @override
  String get sortRecent => 'Newest';

  @override
  String get sortTitle => 'A–Z';

  @override
  String get trailer => 'Trailer';

  @override
  String get moreLikeThis => 'More like this';

  @override
  String get director => 'Director';

  @override
  String get cast => 'Cast';

  @override
  String get releaseDate => 'Release date';

  @override
  String get country => 'Country';

  @override
  String get duration => 'Duration';

  @override
  String get quality => 'Quality';

  @override
  String hoursMinutes(int h, int m) {
    return '$h h $m min';
  }

  @override
  String seasonsCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(n, locale: localeName, other: '$n seasons', one: '1 season');
    return '$_temp0';
  }

  @override
  String get connectPhone => 'Connect your phone';

  @override
  String get connectPhoneBody =>
      'Scan the code with your phone\'s camera. A page opens where you can add playlists with your phone\'s keyboard, use your phone as a remote and move your lists between devices.';

  @override
  String connectSameNetwork(String device) {
    return 'Your phone and $device must be on the same Wi-Fi.';
  }

  @override
  String get connectOrOpen => 'Or open this address on any device:';

  @override
  String get connectWaiting => 'Waiting for your phone…';

  @override
  String get connectRemoteOn => 'Your phone is connected as a remote';

  @override
  String get connectNoNetwork => 'Connect this device to Wi-Fi or Ethernet to use your phone.';

  @override
  String connectAnyNetwork(String device) {
    return 'Your phone only needs the internet: it does not have to be on the same Wi-Fi as $device.';
  }

  @override
  String get connectNeedsServer => 'Set up a sync server in Sync to use your phone with this TV.';

  @override
  String get connectServerDown => 'The sync server can\'t be reached right now. Try again in a moment.';

  @override
  String get addFromPhone => 'Use your phone';

  @override
  String playlistReceived(String name) {
    return '\"$name\" added from your phone';
  }

  @override
  String backupReceived(int added, int updated) {
    String _temp0 = intl.Intl.pluralLogic(added, locale: localeName, other: '$added new', one: '1 new');
    return 'Lists received: $_temp0, $updated updated';
  }

  @override
  String get phoneConnected => 'Phone connected as a remote';

  @override
  String pairTitle(String device) {
    return 'Connected to $device';
  }

  @override
  String pairBody(String device) {
    return 'Move your lists, profiles, favorites, history and settings between this phone and $device. Everything goes straight over your Wi-Fi.';
  }

  @override
  String pairSend(String device) {
    return 'Send everything to $device';
  }

  @override
  String pairReceive(String device) {
    return 'Bring the lists from $device';
  }

  @override
  String get pairRemote => 'Use this phone as a remote';

  @override
  String pairSent(int added, int updated, String device) {
    String _temp0 = intl.Intl.pluralLogic(added, locale: localeName, other: '$added new lists', one: '1 new list');
    return 'Sent to $device: $_temp0, $updated updated';
  }

  @override
  String pairReceived(int added, int updated) {
    String _temp0 = intl.Intl.pluralLogic(added, locale: localeName, other: '$added new lists', one: '1 new list');
    return 'Received: $_temp0, $updated updated';
  }

  @override
  String pairFailed(String device) {
    return 'Couldn\'t reach $device. Scan its code again: it changes every time.';
  }

  @override
  String get webTabAdd => 'Add list';

  @override
  String get webTabRemote => 'Remote';

  @override
  String get webTabBackup => 'Backup';

  @override
  String get webAddTitle => 'Add a list';

  @override
  String webAddBody(String device) {
    return 'Type it here, with your phone\'s keyboard. $device checks it with your provider and saves it.';
  }

  @override
  String get webShow => 'Show';

  @override
  String get showPassword => 'Show password';

  @override
  String get hidePassword => 'Hide password';

  @override
  String get webHide => 'Hide';

  @override
  String webSendToDevice(String device) {
    return 'Send to $device';
  }

  @override
  String get webChecking => 'Checking with your provider…';

  @override
  String webAddedTitle(String name, String device) {
    return '\"$name\" is on $device';
  }

  @override
  String get webAddedBody => 'You can open it there now.';

  @override
  String get webAddAnother => 'Add another';

  @override
  String webLostConnection(String device) {
    return 'Couldn\'t reach $device. Is it still on and on this Wi-Fi?';
  }

  @override
  String get webRelayWaiting => 'Connecting to the TV…';

  @override
  String get webRelayNoAnswer => 'The TV does not answer. Check that it is still on, with Capy TV open.';

  @override
  String get webRelayExpired => 'This page has expired. Scan the code on the TV again.';

  @override
  String webRelayLostConnection(String device) {
    return 'Couldn\'t reach $device. Is it still on, with the app open?';
  }

  @override
  String webExpired(String device) {
    return 'This page has expired. Scan the code on $device again.';
  }

  @override
  String get webNowPlaying => 'Now playing';

  @override
  String get webNothingPlaying => 'Nothing playing';

  @override
  String get webBack => 'Back';

  @override
  String get webPlayPause => 'Play/Pause';

  @override
  String get webChannelDown => 'Ch −';

  @override
  String get webChannelUp => 'Ch +';

  @override
  String get webSend => 'Send';

  @override
  String webTypePlaceholder(String device) {
    return 'Search on $device';
  }

  @override
  String get webTypeHint => 'What you type replaces the text of the field selected on screen, or searches.';

  @override
  String webConnectedTo(String device) {
    return 'Connected to $device';
  }

  @override
  String get webReconnecting => 'Reconnecting…';

  @override
  String get webBackupTitle => 'Back up or move your lists';

  @override
  String get webBackupBody =>
      'A backup has your lists with their passwords, every profile with its PIN and what each one watched and keeps, and your settings. Keep it somewhere private.';

  @override
  String get webDownloadBackup => 'Download a backup';

  @override
  String get webDownloadHint => 'Saved on this phone as a file.';

  @override
  String get webRestoreBackup => 'Restore a backup';

  @override
  String get webRestoreHint => 'Lists already there are updated, not duplicated.';

  @override
  String webRestored(String added, String updated, String device) {
    return 'Done on $device. New lists: $added · Updated: $updated';
  }

  @override
  String get webNotBackup => 'That file is not a Capy TV backup.';

  @override
  String get webBackupNewer => 'This backup is from a newer version of Capy TV: update the app here first.';

  @override
  String get webBackupSaved => 'Backup saved to your downloads.';

  @override
  String get webWorking => 'One moment…';

  @override
  String get webSent => 'Sent';

  @override
  String webOpenAppBody(String device) {
    return 'Have Capy TV on this phone? Open it to send your lists to $device or bring them here.';
  }

  @override
  String get webOpenApp => 'Open the app';

  @override
  String webPrivacy(String device) {
    return 'Everything stays between this phone and $device, on your network.';
  }

  @override
  String webRelayPrivacy(String device) {
    return 'The server only passes along what this phone and $device say to each other, locked with a key that only the two of them have.';
  }

  @override
  String get webUp => 'Up';

  @override
  String get webDown => 'Down';

  @override
  String get webLeft => 'Left';

  @override
  String get webRight => 'Right';

  @override
  String get close => 'Close';

  @override
  String get editPlaylist => 'Edit playlist';

  @override
  String get moveHistory => 'Bring favorites and history from another list';

  @override
  String get moveHistoryChoose => 'From which list?';

  @override
  String get moveHistoryWorking => 'Looking for your titles in this list…';

  @override
  String moveHistoryDone(int moved, int missing) {
    String _temp0 = intl.Intl.pluralLogic(
      moved,
      locale: localeName,
      other: '$moved items moved',
      one: '1 item moved',
      zero: 'Nothing found in this list',
    );
    String _temp1 = intl.Intl.pluralLogic(
      missing,
      locale: localeName,
      other: '; $missing are not in this list',
      one: '; 1 is not in this list',
      zero: '',
    );
    return '$_temp0$_temp1';
  }

  @override
  String get sync => 'Sync';

  @override
  String get syncTitle => 'Your lists everywhere';

  @override
  String get syncBody =>
      'Sign in on each device and your playlists, favorites and progress follow you. Everything is encrypted on the device before it leaves: the server keeps it but can\'t read it. Only recommendations, when your server makes them, send it readable the titles to recommend from.';

  @override
  String get syncServer => 'Sync server';

  @override
  String get syncEmail => 'Email';

  @override
  String get syncPassword => 'Password';

  @override
  String get syncPasswordAgain => 'Repeat password';

  @override
  String get syncSignIn => 'Sign in';

  @override
  String get syncCreate => 'Create sync account';

  @override
  String get syncToCreate => 'New here? Create an account';

  @override
  String get syncToSignIn => 'Have an account? Sign in';

  @override
  String get syncPasswordNote =>
      'Only you know this password. Next you get a recovery key: keep it, it\'s the only way back in if you forget the password.';

  @override
  String get syncWorking => 'Securing your keys…';

  @override
  String get syncErrorServer => 'Use an https:// address (plain http only on your local network)';

  @override
  String get syncErrorEmail => 'Enter a valid email';

  @override
  String get syncErrorShort => 'Use at least 8 characters';

  @override
  String get syncErrorMismatch => 'The passwords don\'t match';

  @override
  String get syncErrorCredentials => 'Wrong email or password';

  @override
  String get syncErrorExists => 'There\'s already an account with this email';

  @override
  String get syncErrorRateLimited => 'Too many attempts. Try again in a minute.';

  @override
  String get syncErrorNetwork => 'Can\'t reach the sync server';

  @override
  String get syncErrorFailed => 'The sync server had a problem. Try again later.';

  @override
  String syncStatusSynced(String time) {
    return 'Up to date · $time';
  }

  @override
  String get syncStatusSyncing => 'Syncing…';

  @override
  String get syncStatusOffline => 'Offline. Changes go out when the server is back.';

  @override
  String get syncStatusExpired => 'Your session ended. Sign in again.';

  @override
  String get syncExpiredNotice => 'Sync stopped: the session ended. Sign in again in Settings, Sync.';

  @override
  String get syncStatusOff => 'Off';

  @override
  String get syncNow => 'Sync now';

  @override
  String get syncDevices => 'Signed-in devices';

  @override
  String syncSeen(String time) {
    return 'Seen $time';
  }

  @override
  String get syncSignOut => 'Sign out';

  @override
  String get syncSignOutConfirm =>
      'Sign this device out? What it has stays here, but nothing new comes until it signs in again.';

  @override
  String get syncDeleteAccount => 'Delete account';

  @override
  String get syncDeleteConfirm =>
      'Delete the account and everything synced? Each device keeps its own lists and history.';

  @override
  String get syncSignedOut => 'Signed out. Everything stays on this device.';

  @override
  String get whoIsWatching => 'Who\'s watching?';

  @override
  String get profileYou => 'You';

  @override
  String get profiles => 'Profiles';

  @override
  String get profilesTitle => 'Profiles and parental control';

  @override
  String get profilesBody =>
      'Each profile keeps its own favorites, history and \"Continue watching\". Kids profiles never show adult content.';

  @override
  String get addProfile => 'Add profile';

  @override
  String get editProfile => 'Edit profile';

  @override
  String get profileName => 'Name';

  @override
  String get kidsProfile => 'Kids';

  @override
  String get kidsAdultTitle => 'This title is for adults, and this profile can\'t play it.';

  @override
  String get kidsProfileHint => 'Never shows adult content.';

  @override
  String get kidsProfileNoPinHint =>
      'Never shows adult content. Saving it asks for a parental PIN, so a child can\'t turn this off.';

  @override
  String get kidsPinTitle => 'A PIN so a child can\'t change this';

  @override
  String get adultPinTitle => 'A PIN so only adults can see this';

  @override
  String get lockProfile => 'Ask for the PIN';

  @override
  String get lockProfileHint => 'Only someone who knows its PIN can open this profile.';

  @override
  String get profilePin => 'This profile\'s PIN';

  @override
  String enterPinOf(String name) {
    return '$name\'s PIN';
  }

  @override
  String get enterPinMain => 'Your PIN';

  @override
  String get forgotPin => 'I forgot the PIN';

  @override
  String get forgotPinAccount =>
      'Enter your sync account\'s password to remove the parental PIN from all your devices.';

  @override
  String get forgotPinNoAccount =>
      'Without a sync account there is no way to prove it is you: the only way out is to clear this app\'s data or reinstall it, losing this device\'s profiles, lists and history.';

  @override
  String forgotPinProfile(String name) {
    return 'To use it again, $name must be deleted, with its favorites and history. Nobody will see what was watched.';
  }

  @override
  String forgotPinMain(String name) {
    return 'The favorites and history of $name will be deleted and its PIN removed. Nobody will see what was watched.';
  }

  @override
  String get forgotPinMainUnnamed =>
      'The favorites and history of this profile will be deleted and its PIN removed. Nobody will see what was watched.';

  @override
  String get showAdult => 'Show adult content';

  @override
  String get showAdultHint =>
      'Categories for adults (XXX, +18…) and whatever the provider marks as adult. Hidden by default.';

  @override
  String get deleteProfile => 'Delete profile';

  @override
  String deleteProfileQuestion(String name) {
    return 'Delete $name? Its favorites and history go with it.';
  }

  @override
  String get parentalPin => 'Parental PIN';

  @override
  String get parentalPinBody => 'Needed to change these settings. Each profile can also have its own PIN.';

  @override
  String get setPin => 'Set PIN';

  @override
  String get changePin => 'Change PIN';

  @override
  String get removePin => 'Remove PIN';

  @override
  String get enterPin => 'Enter the PIN';

  @override
  String get newPin => 'New PIN';

  @override
  String get repeatPin => 'Repeat the PIN';

  @override
  String get wrongPin => 'Wrong PIN';

  @override
  String get pinMismatch => 'The PINs don\'t match';

  @override
  String get pinSaved => 'PIN saved';

  @override
  String get pinRemoved => 'PIN removed';

  @override
  String get storageFull => 'Changes couldn\'t be saved: this device may be out of space.';

  @override
  String get noSecureStorage => 'This device has no secure storage: the password was not saved.';

  @override
  String get startupFailed => 'Capy TV couldn\'t start.';

  @override
  String get pickFieldFirst => 'Choose a field on the TV first';

  @override
  String get castNotAllowed => 'What was sent here isn\'t available on this profile.';

  @override
  String pairCheck(String address, String code) {
    return 'Check it matches the other device: $address · code $code';
  }

  @override
  String pinWait(int seconds) {
    return 'Too many tries. Wait $seconds s';
  }

  @override
  String get switchProfile => 'Switch profile';

  @override
  String get profileLocked => 'PIN';

  @override
  String get adultTag => 'Adult content';

  @override
  String get backspace => 'Delete digit';

  @override
  String get syncInvite => 'Invitation code';

  @override
  String get syncInviteHint => 'Only if your server asks for one';

  @override
  String get syncErrorInvite => 'This server only creates accounts with its invitation code';

  @override
  String get syncErrorQuota => 'The account is full: ask whoever runs the server for more space';

  @override
  String get syncErrorFull => 'This server takes no more accounts: ask whoever runs it';

  @override
  String get syncThisDevice => 'This device';

  @override
  String get syncSignOutDevice => 'Sign out';

  @override
  String syncSignOutDeviceConfirm(String name) {
    return 'Sign $name out? It keeps what it has, but gets nothing new until it signs in again.';
  }

  @override
  String syncSignedInAs(String email) {
    return 'Signed in to sync as $email';
  }

  @override
  String get webTabAccount => 'Account';

  @override
  String get webAccountTitle => 'Sign in to sync';

  @override
  String webAccountBody(String device) {
    return '$device gets your playlists, profiles, favorites and history from your account. The password travels encrypted, and only $device uses it.';
  }

  @override
  String webSignInOn(String device) {
    return 'Sign $device in';
  }

  @override
  String get webSigningIn => 'Signing in… it takes a few seconds';

  @override
  String webSignedInTitle(String device) {
    return '$device is signed in';
  }

  @override
  String webSignedInBody(String email) {
    return 'As $email. Your lists arrive in a moment.';
  }

  @override
  String webCurrentAccount(String device, String email) {
    return '$device is signed in as $email. Signing in again switches accounts.';
  }

  @override
  String webNeedQr(String device) {
    return 'To send passwords, accounts or backups from here, scan the QR code on $device: it carries the key that keeps them private on your network.';
  }

  @override
  String get syncForgot => 'Forgot your password?';

  @override
  String get syncBackToSignIn => 'Back to sign in';

  @override
  String get syncRecoveryKey => 'Recovery key';

  @override
  String get syncNewPassword => 'New password';

  @override
  String get syncCurrentPassword => 'Current password';

  @override
  String get syncRecover => 'Set new password';

  @override
  String get syncRecoverBody =>
      'Enter the recovery key you got when you created the account, and choose a new password. Your other devices will ask for it.';

  @override
  String get syncErrorRecoveryKey => 'That isn\'t a recovery key: it has 32 letters and digits';

  @override
  String get syncErrorRecovery => 'Wrong email or recovery key';

  @override
  String get syncErrorPassword => 'Wrong password';

  @override
  String get syncRecoveryTitle => 'Your recovery key';

  @override
  String get syncRecoveryBody =>
      'If you forget your password, this key is the only way back into your account: nobody can reset it for you, not even whoever runs the server. Write it down or take a photo, and keep it somewhere safe.';

  @override
  String get syncRecoverySaved => 'I\'ve written it down';

  @override
  String get syncCopy => 'Copy';

  @override
  String get syncCopied => 'Copied';

  @override
  String get syncChangePassword => 'Change password';

  @override
  String get syncChangePasswordBody => 'Your other devices are signed out until they sign in with the new password.';

  @override
  String get syncPasswordChanged => 'Password changed';

  @override
  String get syncNewRecoveryKey => 'New recovery key';

  @override
  String get syncNewRecoveryKeyBody =>
      'The recovery key you have now stops working. Enter your password to make a new one.';

  @override
  String get trendingMovie => 'Movie trending this week';

  @override
  String get trendingSeries => 'Series trending this week';

  @override
  String get about => 'About';

  @override
  String get aboutLicense =>
      'Open source, under the Mozilla Public License 2.0. It plays content from your own provider and includes none.';

  @override
  String get tmdbNotice =>
      'This product uses the TMDB API but is not endorsed or certified by TMDB. Trending movies and series, with their images, come from The Movie Database.';

  @override
  String get trendingNow => 'Trending this week';

  @override
  String forYou(String name) {
    return 'Picked for $name';
  }

  @override
  String get forYouMain => 'Picked for you';

  @override
  String get aiTitle => 'Recommendations with AI';

  @override
  String get aiBody =>
      'A language model picks titles for each profile from what it has watched and keeps in Favorites, and says why. Those titles, and some of the catalog\'s to pick from, never any for adults, go to the service that recommends: the one set up here, else your sync server\'s, else the app\'s own. Kids profiles never use it.';

  @override
  String get aiOff => 'Not set up';

  @override
  String get aiSetUp => 'Set up';

  @override
  String get aiChange => 'Change';

  @override
  String get aiRemove => 'Remove';

  @override
  String get aiUrl => 'Service address';

  @override
  String get aiUrlHint => 'Any service with the OpenAI chat API: Ollama, OpenAI, OpenRouter, your own server…';

  @override
  String get aiModel => 'Model';

  @override
  String get aiKey => 'API key';

  @override
  String get aiKeyKept => 'Leave empty to keep the current key';

  @override
  String get aiTestAndSave => 'Check and save';

  @override
  String get aiSaved => 'Recommendations are on';

  @override
  String get aiWrongKey => 'The service did not accept the key';

  @override
  String get aiWrongModel => 'The service does not have that model, or the address is wrong';

  @override
  String get aiUnreachable => 'The service did not answer: check the address';

  @override
  String get aiBusy => 'The service is busy or down for now: try again later';

  @override
  String aiServiceError(String code) {
    return 'The service answered with error $code';
  }

  @override
  String get aiUrlInsecure => 'Use an https address: plain http only for a service on this network';

  @override
  String get aiKeyLost => 'The key of your AI service couldn\'t be read on this device: set it up again';

  @override
  String get aiKeyAgain => 'A new address needs its key typed again';

  @override
  String get aiBuiltIn => 'On: included in this version of the app';

  @override
  String get aiUseBuiltIn => 'Turn back on';

  @override
  String get aiTurnedOff => 'Off on this device';

  @override
  String get aiTurnOff => 'Turn off';

  @override
  String get aiOwn => 'Use another service';

  @override
  String aiFromServer(String server) {
    return 'On: through your sync server, $server';
  }

  @override
  String get aiServerNote =>
      'The titles sent for recommendations go through your sync server, which can read them; it forwards them to its model and keeps nothing.';

  @override
  String get aiTypeOnPhone =>
      'Scan the code with your phone, open Remote and type there: the text goes into the field selected on the TV.';

  @override
  String get recentSearches => 'Recent searches';

  @override
  String get clearRecent => 'Clear';

  @override
  String get bestMatch => 'Best match';

  @override
  String get onTvNow => 'On TV';

  @override
  String get onNow => 'Now';

  @override
  String get browseGenres => 'Movies by genre';

  @override
  String seeAllCount(int count) {
    return 'See all ($count)';
  }

  @override
  String versionsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count versions', one: '1 version');
    return '$_temp0';
  }

  @override
  String versionNumber(int n) {
    return 'Version $n';
  }

  @override
  String get mostWatchedMovies => 'Most watched movies this week';

  @override
  String get mostWatchedSeries => 'Most watched series this week';

  @override
  String get tryingAnotherCopy => 'Trying another copy…';

  @override
  String get combinePlaylists => 'Combine playlists';

  @override
  String get combineBody =>
      'Pick two or more providers to use as one list. Their catalogs come together: a title they share shows once, with every provider\'s copy among its versions, and plays from the one usually fastest at that hour, or from another when one fails. Each playlist stays as it is.';

  @override
  String get pasteLinkHint => 'Or paste the link your provider sent you (get.php?username=…): it fills in everything';

  @override
  String get filledFromLink => 'Server, user and password taken from the link';

  @override
  String get combineSuggestion =>
      'Two providers: combine them to see all their titles together, and to play from the other when one fails';

  @override
  String get accountAlreadyAdded => 'That account was already here: its password is updated';

  @override
  String get surpriseMe => 'Surprise me';

  @override
  String get surpriseQuestion => 'What do you feel like?';

  @override
  String get surpriseGo => 'Pick one';

  @override
  String get surpriseAnother => 'Another one';

  @override
  String get surpriseNone => 'Nothing left for that mood: try another.';

  @override
  String get userAgentOptional => 'User-Agent (optional)';

  @override
  String get userAgentHint => 'Only if your provider asks for a particular player';

  @override
  String get guideTime => 'Guide time';

  @override
  String get guideTimeHint => 'If the guide shows programmes earlier or later than they air, put it right here.';

  @override
  String get guideTimeAsSent => 'As the provider sends it';

  @override
  String guideTimeMoved(String hours) {
    return '$hours h';
  }

  @override
  String get diagnostics => 'Diagnostics';

  @override
  String get diagnosticsCopied => 'Copied: paste it in a message to whoever is helping you.';

  @override
  String get diagnosticsHint =>
      'What the app noted lately, with no addresses or passwords, for whoever is helping you.';

  @override
  String get surpriseAtRandom => 'Your list has no genres or ratings: here is one at random.';

  @override
  String get surpriseNoInfoKids =>
      'Your list has no genres or ratings, so there is nothing here to suggest for this profile.';

  @override
  String get moodLaugh => 'A laugh';

  @override
  String get moodAction => 'Action';

  @override
  String get moodSuspense => 'Suspense';

  @override
  String get moodFamily => 'With the family';

  @override
  String get moodRomance => 'Romance';

  @override
  String get moodScary => 'Scary';

  @override
  String get moodDifferent => 'Something different';

  @override
  String get newEpisodesForYou => 'New episodes of your series';

  @override
  String get upNextForYou => 'Up next';

  @override
  String get guideToday => 'Today';

  @override
  String get guideYesterday => 'Yesterday';

  @override
  String get guideTomorrow => 'Tomorrow';

  @override
  String get guideEarlier => 'Two hours earlier';

  @override
  String get guideLater => 'Two hours later';

  @override
  String get rowEarlier => 'Earlier in this row';

  @override
  String get rowLater => 'Further in this row';

  @override
  String newEpisodeNote(int season, int number, int more) {
    String _temp0 = intl.Intl.pluralLogic(
      more,
      locale: localeName,
      other: ' and $more more',
      one: ' and 1 more',
      zero: '',
    );
    return 'S$season · E$number$_temp0';
  }

  @override
  String get screensaver => 'Screensaver';

  @override
  String minutesIdle(int minutes) {
    return 'After $minutes min';
  }

  @override
  String get movieNight => 'Movie night';

  @override
  String get nightTitle => 'What shall we watch tonight?';

  @override
  String get nightBodyTv =>
      'Everyone scans the code with their phone and says yes or no to each of these. The one with the most votes wins.';

  @override
  String get nightYes => 'Yes!';

  @override
  String get nightNo => 'No';

  @override
  String get nightWinner => 'See the winner';

  @override
  String nightVoters(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count phones have voted',
      one: '1 phone has voted',
      zero: 'Nobody has voted yet',
    );
    return '$_temp0';
  }

  @override
  String get nightWinnerTitle => 'Tonight it is';

  @override
  String get nightNotEnough => 'Not enough titles for this mood: try another.';

  @override
  String get webTabNight => 'Vote';

  @override
  String get webNightBody => 'Yes or no to each title: the TV counts everyone\'s votes.';

  @override
  String get webNightDone => 'All done!';

  @override
  String webNightDoneBody(String device) {
    return 'Look at $device: the winner shows there.';
  }

  @override
  String get webNightAgain => 'Change my votes';

  @override
  String webNightClosed(String device) {
    return 'There is no vote open on $device right now.';
  }

  @override
  String webNightProgress(String n, String total) {
    return '$n of $total';
  }

  @override
  String leftOn(String device, String ago) {
    return 'You left this on $device $ago';
  }

  @override
  String get agoNow => 'just now';

  @override
  String agoMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count minutes ago', one: '1 minute ago');
    return '$_temp0';
  }

  @override
  String agoHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count hours ago', one: '1 hour ago');
    return '$_temp0';
  }

  @override
  String get goOnHere => 'Continue here';

  @override
  String get notNow => 'Not now';

  @override
  String get avatar => 'Avatar';

  @override
  String get avatarInitial => 'Initial';

  @override
  String get changeAvatar => 'Change avatar';

  @override
  String get playerSettings => 'Player settings';

  @override
  String get settingOff => 'Off';

  @override
  String get settingOn => 'On';

  @override
  String get sleepTimer => 'Sleep timer';

  @override
  String get sleepWhenItEnds => 'When it ends';

  @override
  String get sleepDone => 'Paused by the sleep timer';

  @override
  String get sleepDoneHint => 'Sleep well.';

  @override
  String get sleepStillWatching => 'Still watching?';

  @override
  String sleepStillWatchingHint(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(seconds, locale: localeName, other: '$seconds seconds', one: '1 second');
    return 'Playback stops in $_temp0.';
  }

  @override
  String get keepWatching => 'Keep watching';

  @override
  String get exitPlayer => 'Exit';

  @override
  String get leaveAppQuestion => 'Leave Capy TV?';

  @override
  String get leaveApp => 'Leave';

  @override
  String get listUpdatedPlain => 'List updated.';

  @override
  String get guideLoading => 'Loading the guide…';

  @override
  String get restartApp => 'Start again';

  @override
  String serviceEndsSoon(String name, String date) {
    return 'Your service for $name ends on $date: renew it with your provider so it keeps working.';
  }

  @override
  String get openFailedHint => 'Open it to try again, or edit it to check its details.';

  @override
  String get noMoviesInPlaylist => 'This playlist has no movies.';

  @override
  String get noSeriesInPlaylist => 'This playlist has no series.';

  @override
  String get volumeBoost => 'Volume boost';

  @override
  String get streamInfo => 'Stream info';

  @override
  String get pictureFit => 'Picture';

  @override
  String get fitContain => 'Fit';

  @override
  String get fitCover => 'Fill';

  @override
  String get fitFill => 'Stretch';

  @override
  String get playerEpisodes => 'Episodes';

  @override
  String get playerChannels => 'Channels';

  @override
  String get lockControls => 'Lock the screen';

  @override
  String get pipOff => 'Picture-in-picture is turned off for this app in Android\'s settings';

  @override
  String get back10 => 'Back 10 seconds';

  @override
  String get reduceMotion => 'Reduce motion';

  @override
  String get trailers => 'Trailers';

  @override
  String get trailersAlways => 'Always';

  @override
  String get trailersWifi => 'Only on Wi-Fi';

  @override
  String get trailersNever => 'Never';

  @override
  String get volumeDown => 'Volume down';

  @override
  String get volumeUp => 'Volume up';

  @override
  String get previousTitle => 'Previous';

  @override
  String get nextTitle => 'Next';

  @override
  String get clearSearch => 'Clear the search';

  @override
  String ratingOf(String rating) {
    return 'rated $rating';
  }

  @override
  String pinDigits(int count, int total) {
    return '$count of $total digits';
  }

  @override
  String get forward10 => 'Forward 10 seconds';

  @override
  String get mute => 'Sound on or off';

  @override
  String get fullScreen => 'Full screen';

  @override
  String timeLeftToday(int n) {
    return '$n min left for today';
  }

  @override
  String get tapToUnlock => 'Tap the lock to unlock';

  @override
  String get infoVideo => 'Video';

  @override
  String get infoDecoder => 'Decoder';

  @override
  String get infoBitrate => 'Bitrate';

  @override
  String get infoBuffer => 'Buffer';

  @override
  String get infoDropped => 'Dropped frames';

  @override
  String get infoCopy => 'Copy';

  @override
  String get decoderHw => 'Hardware';

  @override
  String get decoderSw => 'Software';

  @override
  String get decoderSwAuto => 'Software (the hardware showed no picture)';

  @override
  String get channelsMono => 'MONO';

  @override
  String get channelsStereo => 'STEREO';

  @override
  String fpsBadge(int n) {
    return '$n FPS';
  }

  @override
  String nOfTotal(int n, int total) {
    return '$n of $total';
  }

  @override
  String get refreshList => 'Update channels and movies';

  @override
  String get listUpdating => 'Updating the list…';

  @override
  String listUpdated(int movies, int series, int channels) {
    String _temp0 = intl.Intl.pluralLogic(movies, locale: localeName, other: '$movies movies', one: '1 movie');
    String _temp1 = intl.Intl.pluralLogic(series, locale: localeName, other: '$series series', one: '1 series');
    String _temp2 = intl.Intl.pluralLogic(channels, locale: localeName, other: '$channels channels', one: '1 channel');
    return 'List updated. New: $_temp0, $_temp1 and $_temp2';
  }

  @override
  String get audioDelay => 'Audio sync';

  @override
  String get subtitleDelay => 'Subtitle sync';

  @override
  String get delayHint => 'Use + if it comes before the picture';

  @override
  String get subtitleSize => 'Subtitle size';

  @override
  String get subtitleBackground => 'Subtitle background';

  @override
  String get playNow => 'Play now';

  @override
  String get skipIntro => 'Skip intro';

  @override
  String get seriesIntro => 'Series intro';

  @override
  String get introStart => 'Mark start';

  @override
  String get introEnd => 'Mark end';

  @override
  String get introClear => 'Clear';

  @override
  String get introNotMarked => 'Not marked';

  @override
  String nextEpisodeIn(int seconds) {
    return 'Next episode in $seconds s';
  }

  @override
  String get pictureInPicture => 'Picture in picture';

  @override
  String get pipBack => 'Back to the window';

  @override
  String get sendTo => 'Send to…';

  @override
  String get noOtherDevices => 'No other device is signed in to this sync account.';

  @override
  String get deviceActive => 'Active now';

  @override
  String sentToDevice(String device) {
    return 'Sent to $device';
  }

  @override
  String get deviceProfileTitle => 'On this device';

  @override
  String get deviceProfileBody =>
      'The profile that opens when the app starts here, without asking who is watching (a kids\' TV).';

  @override
  String get deviceProfileAsk => 'Ask who\'s watching';

  @override
  String get profileAudio => 'Audio language';

  @override
  String get profileSubtitles => 'Subtitles';

  @override
  String get asInSettings => 'As in Settings';

  @override
  String get dailyLimit => 'Time per day';

  @override
  String get dailyLimitHint => 'Counted on each device. When it runs out, the PIN gives more.';

  @override
  String get noLimit => 'No limit';

  @override
  String get timeUp => 'That\'s all for today';

  @override
  String get timeUpHint => 'There\'s more tomorrow. A grown-up can give more time with the PIN.';

  @override
  String get moreTime => '30 more minutes';

  @override
  String get moreTimeNeedsPin => 'More time needs a parental PIN: set one in Profiles.';

  @override
  String hoursOnly(int h) {
    return '$h h';
  }

  @override
  String get goLive => 'Go live';

  @override
  String updateTitle(String version) {
    return 'Capy TV $version';
  }

  @override
  String get updateBody => 'A new version is ready for this device.';

  @override
  String get updateNow => 'Update';

  @override
  String get updateLater => 'Later';

  @override
  String get updateInBackground => 'Continue in background';

  @override
  String get updateDownloading => 'Downloading the update…';

  @override
  String get updateAllowTitle => 'Allow the update';

  @override
  String get updateAllowBody =>
      'Android asks for this once: on the screen that opens, allow Capy TV to install apps, then come back here.';

  @override
  String get updateAllowManual =>
      'In this device\'s settings, allow Capy TV to install unknown apps, then come back here.';

  @override
  String get openSettings => 'Open settings';

  @override
  String get updateFailed => 'The update didn\'t go through. Try again in a moment.';

  @override
  String get updateDamaged => 'The download arrived damaged and was thrown away. Try again.';

  @override
  String updateTo(String version) {
    return 'Update to $version';
  }

  @override
  String appVersion(String version) {
    return 'Version $version';
  }

  @override
  String get checkUpdates => 'Check for updates';

  @override
  String get upToDate => 'This is the latest version.';

  @override
  String get backgroundPlay => 'Keep playing outside the app';

  @override
  String get pause => 'Pause';

  @override
  String get stopPlaying => 'Stop';

  @override
  String get multiview => 'Multiview';

  @override
  String get multiviewAdd => 'Add a channel';

  @override
  String get multiviewChange => 'Change channel';

  @override
  String get multiviewRemove => 'Remove';

  @override
  String get multiviewFull => 'Full screen';

  @override
  String get record => 'Record';

  @override
  String get stopRecording => 'Stop recording';

  @override
  String get recordings => 'Recordings';

  @override
  String get recordingSaved => 'Saved in Recordings (in Settings, or next to your playlists)';

  @override
  String get recordingFailed => 'Nothing was recorded';

  @override
  String get noRecordings => 'Your recordings show here: those from the player and those scheduled from the guide.';

  @override
  String get deleteRecording => 'Delete this recording?';

  @override
  String get recordingNotDeleted => 'This recording couldn\'t be deleted: another program may have it open';

  @override
  String get cancelScheduledQuestion => 'Cancel this scheduled recording?';

  @override
  String get stopRecordingQuestion => 'Stop this recording? What was recorded is kept.';

  @override
  String get keepIt => 'Keep it';

  @override
  String get recordingUntitled => 'Channel';

  @override
  String get recordingStopped => 'The recording stopped: it couldn\'t be saved further (is the storage full?)';

  @override
  String get recordingNoRoom => 'Not enough room left on this device to record';

  @override
  String get recordingStoppedNoRoom => 'The recording stopped: this device is nearly full. What was recorded is saved.';

  @override
  String get recordingAppClosedNote => 'Android closed Capy TV meanwhile. Open it to record what is still on.';

  @override
  String get closeWithRecordingsTitle => 'Close Capy TV?';

  @override
  String get closeWithRecordingsBody =>
      'Something is being recorded or is scheduled. With the app closed it will not be recorded.';

  @override
  String get closeAnyway => 'Close anyway';

  @override
  String get keepOpen => 'Keep it open';

  @override
  String get keepAppOpenToRecord =>
      'On iPhone, keep Capy TV open on screen until it is recorded: iOS stops it in the background.';

  @override
  String get keepAppOpenToCast =>
      'On iPhone, keep Capy TV open: a live channel stops reaching the TV once the app leaves the screen.';

  @override
  String get castNoSubtitles => 'Subtitles do not reach the TV: there the video plays without them.';

  @override
  String get castOtherAudio => 'The TV plays the video\'s own audio, not the language chosen here.';

  @override
  String get sendToYourDevices => 'Your devices';

  @override
  String get sendToNearby => 'On this network';

  @override
  String get castSearching => 'Looking for Chromecasts…';

  @override
  String get castNoneFound => 'No Chromecast found on this network.';

  @override
  String get castByAddress => 'Connect by address…';

  @override
  String get castAddressHint => 'IP address, like 192.168.1.20';

  @override
  String get castAddressInvalid => 'That is no device\'s address: write its IP, like 192.168.1.20';

  @override
  String get castConnect => 'Connect';

  @override
  String castConnecting(String device) {
    return 'Connecting to $device…';
  }

  @override
  String castStarting(String device) {
    return 'Starting on $device…';
  }

  @override
  String castTrying(int n, int total) {
    return 'Trying another copy ($n of $total)…';
  }

  @override
  String get castBuffering => 'Loading…';

  @override
  String get castPaused => 'Paused';

  @override
  String castLost(String device) {
    return 'Connection to $device lost. Reconnecting…';
  }

  @override
  String get castStopped => 'Casting stopped.';

  @override
  String castConnectFailed(String device) {
    return 'Couldn\'t connect to $device.';
  }

  @override
  String castLaunchFailed(String device) {
    return '$device didn\'t open its player.';
  }

  @override
  String castCannotPlay(String device) {
    return '$device can\'t play this.';
  }

  @override
  String castRelayUnreachable(String device) {
    return '$device couldn\'t connect to this device. Check that its firewall lets it in, and that both are on the same network.';
  }

  @override
  String castProviderRefused(String device) {
    return 'Your provider refused this to $device: your account may not allow another connection right now.';
  }

  @override
  String castTakenOver(String device) {
    return '$device is now playing something else.';
  }

  @override
  String get castFinished => 'Finished.';

  @override
  String castingTo(String device) {
    return 'Casting to $device';
  }

  @override
  String castMkvMayFail(String device) {
    return 'MKV files may not play on $device.';
  }

  @override
  String get castKeepOn => 'Keep this device on and on the same Wi-Fi while casting a channel.';

  @override
  String get castPlayHere => 'Play here';

  @override
  String get stopCasting => 'Stop casting';

  @override
  String get castUnsupportedLive => 'This channel\'s format can\'t be cast. Your devices can still play it.';

  @override
  String castUnsupportedFile(String format) {
    return 'This video\'s format ($format) can\'t be cast.';
  }

  @override
  String get castUnsupportedLocal => 'Recordings and earlier programmes can\'t be sent to Chromecast yet.';

  @override
  String get castNoHls => 'Your provider doesn\'t offer this channel in the format Chromecast needs.';

  @override
  String castLostEnded(String device) {
    return 'The connection to $device was lost.';
  }

  @override
  String get recordingEncrypted => 'This channel can\'t be recorded: it is encrypted';

  @override
  String get recordingFragmented => 'This channel can\'t be recorded: the app can\'t save its format';

  @override
  String get recordingSeparateAudio => 'This channel can\'t be recorded: its sound and picture come separately';

  @override
  String get recordingCut => 'The recording stopped because the channel dropped. What was recorded is saved.';

  @override
  String get cancelRecording => 'Cancel recording';

  @override
  String get scheduledRecordings => 'Scheduled';

  @override
  String get recordedFiles => 'Recorded';

  @override
  String get recordingScheduled => 'Recording scheduled';

  @override
  String get recordingNow => 'Recording now';

  @override
  String get recordingDone => 'Recorded';

  @override
  String get recordingFailedState => 'Couldn\'t be recorded';

  @override
  String recordingFailedBecause(String why) {
    return 'Couldn\'t be recorded: $why';
  }

  @override
  String recordingPartly(String why) {
    return 'Recorded in part: $why';
  }

  @override
  String recordingMissedBecause(String why) {
    return 'Missed: $why';
  }

  @override
  String recordingRetrying(String why) {
    return 'Trying again shortly: $why';
  }

  @override
  String get problemAppClosed => 'the app was closed';

  @override
  String get problemAsleep => 'the device was asleep';

  @override
  String get problemNoNetwork => 'the channel couldn\'t be reached';

  @override
  String get problemChannelGone => 'the channel is no longer in the playlist';

  @override
  String get problemUnsupported => 'the app can\'t save this channel in the format it comes in';

  @override
  String get problemNothingCame => 'the channel sent nothing';

  @override
  String get problemNoSpace => 'the device has no room left';

  @override
  String get problemWriteFailed => 'the file couldn\'t be written';

  @override
  String get scheduleNote =>
      'Recorded while the app is running, even in the background. If it is closed at that time, the recording is missed.';

  @override
  String get recordEarly => 'Start before the programme';

  @override
  String get recordLate => 'Go on after the programme';

  @override
  String get recordMarginsHint =>
      'For a match with extra time or a channel running late. For what you schedule from now on.';

  @override
  String recordingStartsAt(String time) {
    return 'Recording starts at $time';
  }

  @override
  String recordingChannel(String channel) {
    return 'Recording $channel';
  }

  @override
  String recordingChannels(int count) {
    return 'Recording $count channels';
  }

  @override
  String get removeFromList => 'Remove';

  @override
  String get recordingPaused => 'Recordings paused';

  @override
  String get recordingPausedNote =>
      'Android lets the app record in the background for a few hours a day. Open Capy TV and they go on.';

  @override
  String get installOtherDevice => 'Install on another device';

  @override
  String get installLinkLoading => 'Getting a link…';

  @override
  String get installLinkType => 'In Downloader on the Fire TV, type this address';

  @override
  String get installLinkScan => 'On a phone, scan the code.';

  @override
  String installLinkValid(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'Valid for $minutes minutes',
      one: 'Valid for 1 minute',
    );
    return '$_temp0';
  }

  @override
  String get installLinkNoApp => 'The sync server has no copy of the app to share. Whoever runs it can put one there.';

  @override
  String get installLinkTooMany => 'Too many links in a short time. Try again later.';

  @override
  String get avatarCredits =>
      'Profile avatars drawn with DiceBear (dicebear.com): \"Croodles - Doodle your face\" by vijay verma and \"Fun Emoji Set\" by Davis Uche, adapted for the app, under CC BY 4.0 (creativecommons.org/licenses/by/4.0); Notionists by Zoish, Lorelei by Lisa Wischofsky, Open Peeps by Pablo Stanley, and Critters and Voxel Bot by DiceBear, under CC0 1.0.';

  @override
  String get titleBarSearch => 'Search in this playlist…';

  @override
  String get titleBarSearchShortcut => 'Ctrl K';

  @override
  String get playlistKindM3u => 'M3U';

  @override
  String get playlistKindCombined => 'Combined';

  @override
  String get windowMinimize => 'Minimize';

  @override
  String get windowMaximize => 'Maximize';

  @override
  String get windowRestore => 'Restore';

  @override
  String errorExpiredOn(String date) {
    return 'The account ended on $date. Ask your provider to renew it.';
  }

  @override
  String deletePlaylistInCombined(int count, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'It\'s part of the combined playlists $names, which will go on without it.',
      one: 'It\'s part of the combined playlist $names, which will go on without it.',
    );
    return '$_temp0';
  }

  @override
  String sleepSoon(int n) {
    return 'The sleep timer stops it in a minute. Tap or press any button to keep watching $n more minutes.';
  }

  @override
  String sleepExtended(int n) {
    return 'Sleep timer: $n more minutes';
  }

  @override
  String get guideFailed => 'The guide couldn\'t be downloaded.';

  @override
  String rankLabel(int n) {
    return 'Number $n';
  }

  @override
  String watchedPercent(int percent) {
    return '$percent% watched';
  }

  @override
  String get holdOkChannelHint => 'Hold OK or press Info on a channel: what it shows next, and Favorites';

  @override
  String get controlsStay => 'Player controls stay';

  @override
  String get controlsStayMoment => 'A moment';

  @override
  String controlsStaySeconds(int n) {
    return '$n seconds';
  }

  @override
  String webNoSecureStorage(String device) {
    return '$device saved the playlist, but not its password: its secure storage isn\'t working.';
  }

  @override
  String get deviceMode => 'Use this device as';

  @override
  String get deviceModeAuto => 'As it says it is';

  @override
  String get deviceModeTv => 'A TV, with a remote';

  @override
  String get deviceModeTouch => 'A phone or tablet, by touch';

  @override
  String get appliesNextStart => 'This applies the next time the app opens';

  @override
  String get playbackPosition => 'Position';

  @override
  String get previousChannel => 'Previous channel';

  @override
  String get subtitleOutline => 'Subtitle outline';

  @override
  String get subtitleBandDarkness => 'Background darkness';

  @override
  String get subtitleLift => 'Subtitle height';

  @override
  String get subtitleLiftBottom => 'At the bottom';

  @override
  String get subtitleLiftHigher => 'Higher';

  @override
  String get subtitleLiftHighest => 'Much higher';

  @override
  String get subtitlePicture => 'picture';

  @override
  String get subtitlePictureHidden =>
      'These subtitles are pictures: with the hardware decoder they can\'t show. Choose the software decoder in the player\'s settings.';

  @override
  String playingOnDevice(String device) {
    return 'Playing on $device';
  }

  @override
  String get playingOnDeviceHint =>
      'Here it stopped, so the provider sees one connection. It goes on from the same place.';

  @override
  String get keepWatchingHere => 'Keep watching here';

  @override
  String get failExpired => 'The account isn\'t active any more. Ask your provider to renew it.';

  @override
  String get failBusy =>
      'All the connections the account allows are in use on other devices. Stop one, then try again.';

  @override
  String get failUnsupported =>
      'This device can\'t play this format. In the player\'s settings, try the other video decoder.';

  @override
  String get failUnsupportedHere => 'This device can\'t play this format. Try another copy, or something else.';

  @override
  String get textSize => 'Text size';

  @override
  String get textSizeDevice => 'As the device\'s';

  @override
  String get watchAgain => 'Watch again';
}
