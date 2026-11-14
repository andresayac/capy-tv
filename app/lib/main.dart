import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'data/app_language.dart';
import 'data/desktop_prefs.dart';
import 'data/image_store.dart';
import 'data/library.dart';
import 'data/poster_wall.dart';
import 'data/profiles.dart';
import 'data/recommender.dart';
import 'data/settings.dart';
import 'data/storage_health.dart';
import 'data/stream_stats.dart';
import 'data/trending.dart';
import 'desktop_window.dart';
import 'device.dart';
import 'diagnostics.dart';
import 'l10n/app_localizations.dart';
import 'platform.dart';
import 'player/background_recorder.dart';
import 'player/hls_recorder.dart';
import 'player/recording_scheduler.dart';
import 'ready.dart';
import 'remote/companion_server.dart';
import 'remote/remote_input.dart';
import 'sync/sync_service.dart';
import 'ui/common.dart';
import 'ui/pair_screen.dart';
import 'ui/playlists_screen.dart';
import 'ui/profiles_screen.dart';
import 'ui/remote_keys.dart';
import 'ui/screensaver.dart';
import 'ui/theme.dart';
import 'ui/title_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Diagnostics.start(); // before anything can go wrong
  MediaKit.ensureInitialized();
  await detectDevice();
  // A recording made with no screen (Android ended the app and woke it for one) stops as the app
  // opens, to go on here in the same file: the preferences are read again after it wrote them
  if (await RecordingKeepAlive.takeOver()) await (await SharedPreferences.getInstance()).reload();
  await useLandscapeFullScreen();
  // On Windows the app draws its own title bar, in black, instead of the native one
  await DesktopWindow.instance.setUp();
  // With a remote there is no touch to fall back on: the focused item is always marked
  if (isTv) FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  // A 1 GB TV stick has a few hundred MB for everything; a computer can keep whole screens of them
  PaintingBinding.instance.imageCache.maximumSizeBytes = imageBudget.decodedMb << 20;
  ImageStore.instance
    ..maxDownloads = imageBudget.downloads
    ..diskBytes = imagesOnDiskMb(imageBudget.diskMb, freeStorageMb) << 20;
  PlatformDispatcher.instance.onError = (e, _) {
    debugPrint('uncaught: ${e.runtimeType}'); // not its text: it may carry an address with an account
    return true;
  };
  if (isWindows || isLinux) SharedPreferencesStorePlatform.instance = AtomicPrefsStore();
  await DesktopWindow.instance.restore(); // its size and place from last time: the store is set now
  final AppSettings settings;
  try {
    settings = await AppSettings.load();
  } on Object catch (e) {
    debugPrint('startup: the settings could not be read: ${e.runtimeType}');
    return runApp(const _CannotStart());
  }
  await _step('profiles', ProfileStore.instance.load);
  // Before the first frame, so the welcome screen has its images; this week's are asked for after
  await _step('trending', Trending.load);
  await _step('posters', PosterWall.load);
  await _step('recommender', Recommender.load);
  await _step('stream stats', StreamStats.load);
  // Earlier versions kept live channels on disk here, a file that only grew
  await _step('timeshift', () async {
    final old = Directory('${(await getApplicationCacheDirectory()).path}/timeshift');
    if (old.existsSync()) old.deleteSync(recursive: true);
  });
  followAppLanguage();
  unawaited(Trending.refresh(language: tmdbLanguage(appLocale)));
  // The sync server's model, for devices without one of their own; the key stays there
  final sync = SyncService.instance;
  sync.aiModel.addListener(
    () => Recommender.useServer(switch (sync.aiModel.value) {
      final model? => AiService.through(
        (messages, json) => sync.aiChat(messages, json: json),
        model: model,
        baseUrl: sync.server?.host ?? '',
      ),
      null => null,
    }),
  );
  await _step('sync', sync.start); // reads the account, then syncs in the background
  // Recordings scheduled from the guide: due ones start, those whose time passed meanwhile are missed.
  // HLS channels are recorded piece by piece
  hlsRecorder = startHlsChannelRecorder;
  unawaited(RecordingScheduler.instance.start());
  // On a computer, closing the window while something records or is still to asks first
  final recordings = RecordingScheduler.instance.busy;
  recordings.addListener(() => unawaited(DesktopWindow.instance.guardClose(recordings.value)));
  DesktopWindow.instance.confirmClose = _confirmClose;
  runApp(SettingsScope(settings: settings, child: const IptvApp()));
  // The page's splash goes once there is a frame under it (web; nothing on the native platforms)
  WidgetsBinding.instance.addPostFrameCallback((_) => notifyReady());
}

/// Android woke the app for a scheduled recording after it had ended it: RecordingService.kt runs
/// this in a Flutter engine with no screen. It records what is due as the app would (its scheduler,
/// its files, its notification) until nothing is left, or the app opens and takes over.
@pragma('vm:entry-point')
Future<void> recordWhileClosed() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await AppSettings.load(); // the app's language, for what the notification says
  } on Object catch (e) {
    debugPrint('recording while closed: the settings could not be read: ${e.runtimeType}');
  }
  followAppLanguage();
  hlsRecorder = startHlsChannelRecorder;
  debugPrint('recording while closed: started');
  await RecordingScheduler.instance.start();
}

/// The window is closing with recordings under way or still to come: whether to close all the same.
/// Staying open has the focus.
Future<bool> _confirmClose() async {
  final context = appNavigator.currentContext;
  if (context == null) return true;
  final l = context.l10n;
  return showConfirm(
    context,
    title: l.closeWithRecordingsTitle,
    message: l.closeWithRecordingsBody,
    confirmLabel: l.closeAnyway,
    cancelLabel: l.keepOpen,
  );
}

/// Rows drag with the mouse too: a wheel only scrolls them with Shift held, which nothing says.
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {...super.dragDevices, PointerDeviceKind.mouse};
}

/// One thing read at startup: whatever is damaged in it, the app still opens.
Future<void> _step(String what, Future<void> Function() work) async {
  try {
    await work();
  } on Object catch (e) {
    debugPrint('startup: $what failed: ${e.runtimeType}');
  }
}

/// All that is left when not even the settings can be read: the window, and another try.
class _CannotStart extends StatelessWidget {
  const _CannotStart();

  @override
  Widget build(BuildContext context) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(AppLocalizations.of(context).startupFailed),
              const SizedBox(height: 16),
              TextButton(autofocus: true, onPressed: main, child: Text(AppLocalizations.of(context).retry)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// On a phone on its side the screens' top bars are lower: a usual one is a sixth of its height.
class _ShortBars extends StatelessWidget {
  const _ShortBars({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isShort(context)) return child;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(appBarTheme: theme.appBarTheme.copyWith(toolbarHeight: 48)),
      child: child,
    );
  }
}

/// The app's "Reduce motion" over the system's: what reads disableAnimations stands still for either.
class _ReduceMotion extends StatelessWidget {
  const _ReduceMotion({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final settings = SettingsScope.maybeOf(context);
    final reduce = settings?.reduceMotion ?? false;
    final size = settings?.textSize ?? 0;
    // The app's own text size, else the device's; never past twice, where no screen can be laid out
    final text = (size > 0 ? TextScaler.linear(size / 100) : mq.textScaler).clamp(maxScaleFactor: 2);
    return MediaQuery(
      data: mq.copyWith(disableAnimations: mq.disableAnimations || reduce, textScaler: text),
      child: child,
    );
  }
}

/// For messages about things that happen outside any screen, like a phone sending a playlist.
final appMessenger = GlobalKey<ScaffoldMessengerState>();

class IptvApp extends StatelessWidget {
  const IptvApp({super.key, this.locale});

  /// Forces a UI language (tests); null takes the one chosen in Settings, else the system's.
  final Locale? locale;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: appLanguage,
    builder: (context, chosen, _) => _app(locale ?? (chosen.isEmpty ? null : Locale(chosen))),
  );

  Widget _app(Locale? locale) => MaterialApp(
    onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
    debugShowCheckedModeBanner: false,
    locale: locale,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(),
    navigatorKey: appNavigator,
    scrollBehavior: const _AppScrollBehavior(),
    navigatorObservers: [titleBarRoutes],
    scaffoldMessengerKey: appMessenger,
    // An idle screen shows this week's backdrops, whatever screen it was on; using the desktop
    // title bar is no idle time
    builder: (context, child) => _ReduceMotion(
      child: _ShortBars(
        child: IdleWatcher(
          navigator: appNavigator,
          child: WindowFrame(
            child: _CompanionNotices(
              child: ValueListenableBuilder<Library?>(
                valueListenable: currentLibrary,
                builder: (_, library, _) => LibraryScope(
                  library: library,
                  child: isTv
                      ? Shortcuts(
                          shortcuts: tvShortcuts,
                          child: Actions(actions: {DirectionalFocusIntent: ScrollWhenStuckAction()}, child: child!),
                        )
                      // A keyboard goes back too, without tabbing to the back arrow
                      : isWindows || isLinux || isMacOS
                      ? Shortcuts(
                          shortcuts: desktopShortcuts,
                          child: Actions(actions: {GoBackIntent: GoBackAction(appNavigator)}, child: child!),
                        )
                      : child!,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    onGenerateInitialRoutes: initialRoutes,
    // capytv://open/pair?... links from another device's companion page
    onGenerateRoute: (s) => switch (PairScreen.forRoute(s.name)) {
      final screen? => MaterialPageRoute(
        builder: (_) => ProfileGate(child: screen),
        settings: s,
      ),
      null => null,
    },
  );
}

/// What the app starts on: always the profile's choice and the playlists under it, also when a link
/// started it, or it would go in as whoever was last.
@visibleForTesting
List<Route<void>> initialRoutes(String name) => [
  MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/'),
    builder: (_) => const ProfileGate(child: PlaylistsScreen()),
  ),
  if (PairScreen.forRoute(name) case final screen?)
    MaterialPageRoute<void>(
      settings: RouteSettings(name: name),
      builder: (_) => ProfileGate(child: screen),
    ),
];

/// Tells the user what a phone did through the companion page, wherever they are in the app.
class _CompanionNotices extends StatefulWidget {
  const _CompanionNotices({required this.child});

  final Widget child;

  @override
  State<_CompanionNotices> createState() => _CompanionNoticesState();
}

class _CompanionNoticesState extends State<_CompanionNotices> {
  late final StreamSubscription<CompanionEvent> _events;
  var _toldStorage = false;
  var _toldExpired = false;

  /// A session ended elsewhere (a new password on the phone): said once, wherever one is, or
  /// "Continue watching" would fall behind for weeks with nobody knowing why.
  void _syncExpired() {
    final expired = SyncService.instance.status == SyncStatus.expired;
    if (!expired) _toldExpired = false;
    if (!expired || _toldExpired || !mounted) return;
    _toldExpired = true;
    appMessenger.currentState?.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).syncExpiredNotice)));
  }

  void _storage() {
    if (!storageFailed.value || _toldStorage || !mounted) return;
    _toldStorage = true; // every ten seconds with a movie going, or it would never leave
    appMessenger.currentState?.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).storageFull)));
  }

  @override
  void initState() {
    super.initState();
    storageFailed.addListener(_storage);
    SyncService.instance.addListener(_syncExpired);
    // It may have ended before the app was up
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncExpired());
    _events = CompanionServer.instance.events.listen((e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      final text = switch (e) {
        PlaylistReceived(:final name, :final noPassword) => [
          l.playlistReceived(name),
          if (noPassword) l.noSecureStorage,
        ].join('\n'),
        BackupReceived(:final result) => [
          l.backupReceived(result.added, result.updated),
          if (result.noPassword > 0) l.noSecureStorage,
        ].join('\n'),
        RemoteConnected() => l.phoneConnected,
        SyncSignedIn(:final email) => l.syncSignedInAs(email),
      };
      appMessenger.currentState?.showSnackBar(SnackBar(content: Text(text)));
    });
  }

  @override
  void dispose() {
    storageFailed.removeListener(_storage);
    SyncService.instance.removeListener(_syncExpired);
    _events.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
