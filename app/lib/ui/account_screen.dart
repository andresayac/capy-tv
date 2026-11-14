import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../data/app_language.dart';
import '../data/catalog.dart';
import '../data/combined.dart';
import '../data/library.dart';
import '../data/matching.dart';
import '../data/models.dart';
import '../data/playlists.dart';
import '../data/profiles.dart';
import '../data/settings.dart';
import '../data/trending.dart';
import '../device.dart';
import '../diagnostics.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../player/background_play.dart';
import '../sync/app_update.dart';
import '../sync/sync_service.dart';
import 'ai_settings.dart';
import 'app_update_dialog.dart';
import 'backdrop.dart';
import 'common.dart';
import 'connect_screen.dart';
import 'install_link_dialog.dart';
import 'profiles_screen.dart';
import 'recordings_screen.dart';
import 'sync_screen.dart';
import 'theme.dart';

/// This app's version and, on Android with sync, a newer one on the account's server; with sync,
/// on every platform, a link to install the app on another device.
class _AppVersion extends StatelessWidget {
  const _AppVersion();

  Future<void> _check(BuildContext context) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    await SyncService.instance.checkForUpdate();
    final release = AppUpdate.available.value;
    if (!context.mounted) return;
    release == null
        ? messenger.showSnackBar(SnackBar(content: Text(l.upToDate)))
        : await showAppUpdate(context, release);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final synced = SyncService.instance.signedIn;
    return FutureBuilder(
      future: AppUpdate.installed(),
      builder: (context, own) {
        final v = own.data;
        if (v == null && !synced) return const SizedBox.shrink();
        return ValueListenableBuilder(
          valueListenable: AppUpdate.available,
          builder: (context, release, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (release != null || synced) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (release != null)
                      PrimaryButton(
                        icon: Icons.system_update_rounded,
                        label: l.updateTo(release.label),
                        onPressed: () => showAppUpdate(context, release),
                      )
                    else if (v != null)
                      SecondaryButton(
                        icon: Icons.update_rounded,
                        label: l.checkUpdates,
                        onPressed: () => _check(context),
                      ),
                    // A link to the server's release, for a device with no session yet (a Fire TV)
                    if (synced)
                      SecondaryButton(
                        icon: Icons.install_mobile_rounded,
                        label: l.installOtherDevice,
                        onPressed: () => showInstallLink(context),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// What the app noted lately, for whoever helps when something fails: copied to paste in a
/// message, and on a TV, where nothing is pasted, shown to be read out or photographed.
class _DiagnosticsButton extends StatelessWidget {
  const _DiagnosticsButton();

  Future<void> _open(BuildContext context) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final report = await Diagnostics.report(extra: ['tv: $isTv', 'sync: ${SyncService.instance.status.name}']);
    if (!context.mounted) return;
    if (!isTv) {
      await Clipboard.setData(ClipboardData(text: report));
      messenger.showSnackBar(SnackBar(content: Text(l.diagnosticsCopied)));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.diagnostics),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: Text(
              // The newest first: what went wrong just now is what matters
              report.split('\n').reversed.join('\n'),
              style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
        ),
        actions: [PrimaryButton(label: l.close, autofocus: true, onPressed: () => Navigator.pop(ctx))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SecondaryButton(icon: Icons.bug_report_outlined, label: l.diagnostics, onPressed: () => _open(context)),
        const SizedBox(height: 6),
        Text(l.diagnosticsHint, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
      ],
    );
  }
}

/// The provider's lists again through [refresh] (see HomeScreen): a dialog while they come, then
/// how much is new. Settings' button and the title bar's.
Future<void> refreshList(
  BuildContext context,
  Future<({int movies, int series, int channels})> Function() refresh,
) async {
  final l = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  Future<String> update() async {
    try {
      final news = await refresh();
      return l.listUpdated(news.movies, news.series, news.channels);
    } on PartsMissing catch (e) {
      return l.listPartsMissing(e.names.join(', '));
    } catch (e) {
      return errorText(l, e);
    }
  }

  final message = update();
  unawaited(_showWorking(context, l.listUpdating, message));
  messenger.showSnackBar(SnackBar(content: Text(await message)));
}

/// A dialog nobody can dismiss saying [text] until [done] completes. Then it closes itself, and
/// only itself, whatever was opened or closed over it meanwhile.
Future<void> _showWorking(BuildContext context, String text, Future<void> done) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _Working(text: text, done: done),
);

class _Working extends StatefulWidget {
  const _Working({required this.text, required this.done});

  final String text;
  final Future<void> done;

  @override
  State<_Working> createState() => _WorkingState();
}

class _WorkingState extends State<_Working> {
  ModalRoute<dynamic>? _route; // its own

  @override
  void initState() {
    super.initState();
    widget.done.then((_) => _close(), onError: (Object _) => _close());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  void _close() {
    final route = _route;
    final navigator = route?.navigator;
    if (!mounted || route == null || navigator == null || !route.isActive) return;
    route.isCurrent ? navigator.pop() : navigator.removeRoute(route);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false, // Back too: it closes itself
    child: AlertDialog(
      content: Row(
        children: [
          const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.text),
                // Updating the list: how much of it has come
                ListenableBuilder(
                  listenable: listProgress,
                  builder: (context, _) => switch (listProgressText(context)) {
                    final text? => Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(text, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                    ),
                    null => const SizedBox.shrink(),
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Account status plus app settings.
class AccountScreen extends StatelessWidget {
  const AccountScreen({
    super.key,
    required this.playlist,
    this.account,
    required this.onSwitchPlaylist,
    this.onRefresh,
  });

  final Playlist playlist;
  final AccountInfo? account;
  final VoidCallback onSwitchPlaylist;

  /// Asks the provider for the lists again (see HomeScreen); says how much is new.
  final Future<({int movies, int series, int channels})> Function()? onRefresh;

  /// After a change of provider: favorites and history of another playlist are looked for in this
  /// one, where every id is different (see matching.dart).
  Future<void> _moveHistory(BuildContext context) async {
    final l = context.l10n;
    final others = (PlaylistStore.instance.playlists ?? const <Playlist>[]).where((p) => p.id != playlist.id);
    final from = await showDialog<Playlist>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l.moveHistoryChoose),
        children: [
          // Rows with the focus ring, as everywhere else: a tint alone is hard to see from the sofa
          for (final (i, p) in others.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              child: Focusable(
                autofocus: i == 0,
                scale: 1,
                radius: AppRadius.button,
                onTap: () => Navigator.pop(ctx, p),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Text(p.name, style: const TextStyle(fontSize: 16)),
                ),
              ),
            ),
        ],
      ),
    );
    final catalog = currentCatalog.value;
    if (from == null || catalog == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Future<String> move() async {
      try {
        // Every profile's favorites and history
        final migration = LibraryMigration(source: catalog.source, catalog: await catalog.load());
        var moved = 0;
        final missing = <String>{};
        for (final profile in ProfileStore.instance.profiles) {
          final stored = await Library.stored(from.id, profile.id);
          if (stored == null) continue;
          final result = await migration.run(stored, playlist.id, profileId: profile.id);
          moved += result.moved;
          missing.addAll(result.missing);
        }
        return l.moveHistoryDone(moved, missing.length);
      } catch (e) {
        return errorText(l, e);
      }
    }

    final message = move();
    unawaited(_showWorking(context, l.moveHistoryWorking, message));
    messenger.showSnackBar(SnackBar(content: Text(await message)));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final a = account;
    final settings = SettingsScope.of(context);
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(k, style: const TextStyle(color: AppColors.muted)),
          ),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    String langLabel(String code) => switch (code) {
      '' => l.automatic,
      'off' => l.off,
      _ => l.languageName(code),
    };
    Widget choice<T>({
      required String label,
      required T value,
      required List<T> options,
      required String Function(T) text,
      required ValueChanged<T> onChanged,
      bool autofocus = false,
    }) => ChoiceRow<T>(
      label: label,
      value: value,
      options: options,
      text: text,
      onChanged: onChanged,
      autofocus: autofocus, // the first setting, so a remote starts on the page
    );

    return PosterBackdrop(
      child: Scaffold(
        appBar: AppBar(title: Text(l.settings)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                Panel(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const AppLogo(size: 40),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(playlist.name, style: Theme.of(context).textTheme.titleMedium),
                                Text(
                                  playlist.type == PlaylistType.combined
                                      ? [
                                          for (final id in playlist.members)
                                            ?PlaylistStore.instance.playlists
                                                ?.where((x) => x.id == id)
                                                .firstOrNull
                                                ?.name,
                                        ].join(' + ')
                                      : ProfileStore.instance.current.kids
                                      ? ''
                                      : playlist.address,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: AppColors.muted, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (a != null) ...[
                        const SizedBox(height: 12),
                        const Divider(color: AppColors.stroke),
                        row(
                          l.status,
                          a.isTrial
                              ? '${accountStatusText(l, a.status)} · ${l.trialAccount}'
                              : accountStatusText(l, a.status),
                        ),
                        row(l.expires, a.expires == null ? l.neverExpires : formatDate(context, a.expires!)),
                        if (a.maxConnections != null)
                          row(l.connections, l.connectionsValue(a.activeConnections ?? 0, a.maxConnections!)),
                        if (a.formats.isNotEmpty) row(l.outputFormats, a.formats.join(', ')),
                        if (a.serverTimezone != null) row(l.serverTimezone, a.serverTimezone!),
                        // A notice the panel publishes (maintenance, say): as plain text, no links
                        if (a.message != null) row(l.providerMessage, a.message!),
                      ],
                      // What the list has, as the app shows it: a movie with several versions once
                      FutureBuilder(
                        future: currentCatalog.value?.load(),
                        builder: (context, snap) {
                          final data = snap.data;
                          if (data == null) return const SizedBox.shrink();
                          final count = NumberFormat.decimalPattern(Localizations.localeOf(context).toLanguageTag());
                          return Column(
                            children: [
                              if (a == null) ...[const SizedBox(height: 12), const Divider(color: AppColors.stroke)],
                              row(l.movies, count.format(oneOfEachTitle(data.movies, data).length)),
                              row(l.series, count.format(data.series.length)),
                              row(l.playerChannels, count.format(data.live.length)),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                Text(l.playback, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Panel(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Column(
                    children: [
                      choice<String>(
                        autofocus: true,
                        label: l.appLanguage,
                        value: settings.language,
                        // Each in its own words: whoever cannot read this one finds theirs
                        options: ['', for (final l in AppLocalizations.supportedLocales) l.languageCode],
                        text: (code) =>
                            code.isEmpty ? l.appLanguageDevice : lookupAppLocalizations(Locale(code)).languageSelf,
                        onChanged: (code) async {
                          await settings.set(language: code);
                          // This week's titles and their synopses, in that language
                          unawaited(Trending.refresh(language: tmdbLanguage(appLocale)));
                        },
                      ),
                      choice<String>(
                        label: l.preferredAudio,
                        value: settings.audioLanguage,
                        options: ['', ...preferenceLanguages],
                        text: langLabel,
                        onChanged: (v) => settings.set(audioLanguage: v),
                      ),
                      choice<String>(
                        label: l.preferredSubtitles,
                        value: settings.subtitleLanguage,
                        options: ['', 'off', ...preferenceLanguages],
                        text: langLabel,
                        onChanged: (v) => settings.set(subtitleLanguage: v),
                      ),
                      // How subtitles look, for whoever reads them: here, not only in the player
                      choice<int>(
                        label: l.subtitleSize,
                        value: settings.subtitleScale,
                        options: const [75, 100, 125, 150, 200],
                        text: (v) => '$v %',
                        onChanged: (v) => settings.set(subtitleScale: v),
                      ),
                      choice<bool>(
                        label: l.subtitleBackground,
                        value: settings.subtitleBackground,
                        options: const [false, true],
                        text: (v) => v ? l.settingOn : l.settingOff,
                        onChanged: (v) => settings.set(subtitleBackground: v),
                      ),
                      if (settings.subtitleBackground)
                        choice<int>(
                          label: l.subtitleBandDarkness,
                          value: settings.subtitleBandDarkness,
                          options: const [50, 70, 90, 100],
                          text: (v) => '$v %',
                          onChanged: (v) => settings.set(subtitleBandDarkness: v),
                        )
                      else
                        choice<bool>(
                          label: l.subtitleOutline,
                          value: settings.subtitleOutline,
                          options: const [false, true],
                          text: (v) => v ? l.settingOn : l.settingOff,
                          onChanged: (v) => settings.set(subtitleOutline: v),
                        ),
                      choice<int>(
                        label: l.subtitleLift,
                        value: settings.subtitleLift,
                        options: const [0, 10, 20],
                        text: (v) => switch (v) {
                          10 => l.subtitleLiftHigher,
                          20 => l.subtitleLiftHighest,
                          _ => l.subtitleLiftBottom,
                        },
                        onChanged: (v) => settings.set(subtitleLift: v),
                      ),
                      choice<int>(
                        label: l.screensaver,
                        value: settings.screensaverMinutes,
                        options: {0, 2, 5, 10, 15, settings.screensaverMinutes}.toList()..sort(),
                        text: (m) => m == 0 ? l.off : l.minutesIdle(m),
                        onChanged: (m) => settings.set(screensaverMinutes: m),
                      ),
                      choice<String>(
                        label: l.trailers,
                        value: settings.trailers,
                        options: [
                          'always',
                          if (isAndroid || settings.trailers == 'wifi') 'wifi', // only Android tells
                          'never',
                        ],
                        text: (v) => switch (v) {
                          'wifi' => l.trailersWifi,
                          'never' => l.trailersNever,
                          _ => l.trailersAlways,
                        },
                        onChanged: (v) => settings.set(trailers: v),
                      ),
                      choice<bool>(
                        label: l.reduceMotion,
                        value: settings.reduceMotion,
                        options: const [false, true],
                        text: (v) => v ? l.settingOn : l.settingOff,
                        onChanged: (v) => settings.set(reduceMotion: v),
                      ),
                      choice<int>(
                        label: l.textSize,
                        value: settings.textSize,
                        options: {0, 85, 100, 115, 130, 150, 175, settings.textSize}.toList()..sort(),
                        text: (v) => v == 0 ? l.textSizeDevice : '$v %',
                        onChanged: (v) => settings.set(textSize: v),
                      ),
                      choice<int>(
                        label: l.controlsStay,
                        value: settings.controlsSeconds,
                        options: const [0, 8, 15],
                        text: (v) => v == 0 ? l.controlsStayMoment : l.controlsStaySeconds(v),
                        onChanged: (v) => settings.set(controlsSeconds: v),
                      ),
                      if (BackgroundPlay.available)
                        choice<bool>(
                          label: l.backgroundPlay,
                          value: settings.backgroundPlay,
                          options: const [false, true],
                          text: (v) => v ? l.settingOn : l.off,
                          onChanged: (v) => settings.set(backgroundPlay: v),
                        ),
                      // What only matters when something does not play: last, apart from the everyday
                      Padding(
                        padding: const EdgeInsets.only(top: 16, bottom: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Semantics(
                            header: true,
                            child: Text(
                              l.advanced,
                              style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ),
                      if (playlist.type == PlaylistType.xtream)
                        choice<String>(
                          label: l.liveFormat,
                          value: settings.liveFormat,
                          options: const ['ts', 'm3u8'],
                          text: (v) => v == 'ts' ? l.liveFormatTs : l.liveFormatHls,
                          onChanged: (v) => settings.set(liveFormat: v),
                        ),
                      // On every device: when a picture does not start, the player says to change it here
                      choice<String>(
                        label: l.decoder,
                        value: settings.decoder,
                        options: const ['hardware', 'software'],
                        text: (v) => v == 'hardware' ? l.decoderHardware : l.decoderSoftware,
                        onChanged: (v) => settings.set(decoder: v),
                      ),
                      // A box that says it has a touch screen it has not got is taken for a phone
                      if (isAndroid)
                        // Not one of the settings: its own state, to show the choice at once
                        StatefulBuilder(
                          builder: (context, setState) => choice<String>(
                            label: l.deviceMode,
                            value: deviceMode,
                            options: const ['', 'tv', 'touch'],
                            text: (v) => switch (v) {
                              'tv' => l.deviceModeTv,
                              'touch' => l.deviceModeTouch,
                              _ => l.deviceModeAuto,
                            },
                            onChanged: (v) async {
                              if (v == deviceMode) return;
                              await setDeviceMode(v);
                              if (!context.mounted) return;
                              setState(() {});
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.appliesNextStart)));
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (offersCompanion && !adultActionsHidden)
                      SecondaryButton(
                        icon: Icons.phonelink_rounded,
                        label: l.connectPhone,
                        onPressed: () => adultOnly(
                          context,
                          () =>
                              Navigator.of(context)
                                  .push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen(tab: 'remote'))),
                        ),
                      ),
                    if (onRefresh != null)
                      SecondaryButton(
                        icon: Icons.refresh_rounded,
                        label: l.refreshList,
                        onPressed: () => refreshList(context, onRefresh!),
                      ),
                    if (!adultActionsHidden)
                      SecondaryButton(
                        icon: Icons.swap_horiz_rounded,
                        label: l.switchPlaylist,
                        onPressed: () => adultOnly(context, onSwitchPlaylist),
                      ),
                    // They are the device's, whoever recorded them
                    if (!ProfileStore.instance.current.kids)
                      SecondaryButton(
                        icon: Icons.video_library_outlined,
                        label: l.recordings,
                        onPressed: () =>
                            Navigator.of(context)
                                .push(MaterialPageRoute<void>(builder: (_) => const RecordingsScreen())),
                      ),
                    if (ProfileStore.instance.profiles.length > 1)
                      SecondaryButton(
                        icon: Icons.switch_account_outlined,
                        label: l.switchProfile,
                        onPressed: () => changeProfile(context, playlist.id),
                      ),
                    if (!adultActionsHidden)
                      SecondaryButton(
                        icon: Icons.manage_accounts_outlined,
                        label: l.profilesTitle,
                        onPressed: () => openProfileSettings(context),
                      ),
                    // Not a child's: it would lock the parents out
                    if (!ProfileStore.instance.current.kids)
                      SecondaryButton(
                        icon: Icons.pin_outlined,
                        label: l.profilePin,
                        onPressed: () => profilePinSettings(context),
                      ),
                    if (!adultActionsHidden)
                      SecondaryButton(
                        icon: Icons.cloud_sync_outlined,
                        label: l.sync,
                        onPressed: () => adultOnly(
                          context,
                          () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SyncScreen())),
                        ),
                      ),
                    if ((PlaylistStore.instance.playlists?.length ?? 0) > 1 && !adultActionsHidden)
                      SecondaryButton(
                        icon: Icons.move_down_rounded,
                        label: l.moveHistory,
                        onPressed: () => adultOnly(context, () => _moveHistory(context)),
                      ),
                    SecondaryButton(
                      icon: Icons.history_toggle_off_rounded,
                      label: l.clearHistory,
                      onPressed: () async {
                        // An OK too many on a remote must not take it from every device
                        final sure = await showConfirm(
                          context,
                          message: l.clearHistoryQuestion,
                          confirmLabel: l.clearHistory,
                        );
                        if (!sure || !context.mounted) return;
                        await LibraryScope.maybeOf(context)?.clearHistory();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.historyCleared)));
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Text(l.aiTitle, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const AiSettingsPanel(),
                const SizedBox(height: 28),
                Text(l.about, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Panel(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.aboutLicense, style: const TextStyle(color: AppColors.muted, height: 1.5)),
                      const SizedBox(height: 12),
                      FutureBuilder(
                        future: Diagnostics.version(),
                        builder: (context, v) =>
                            Text(l.appVersion(v.data ?? '…'), style: const TextStyle(color: AppColors.muted)),
                      ),
                      const _AppVersion(),
                      const SizedBox(height: 12),
                      const _DiagnosticsButton(),
                      // CC BY asks for the artists' credit where their drawings show
                      const SizedBox(height: 12),
                      Text(l.avatarCredits, style: const TextStyle(color: AppColors.muted, height: 1.5)),
                      // TMDB asks for this wherever its data is used
                      if (Trending.apiKey.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(l.tmdbNotice, style: const TextStyle(color: AppColors.muted, height: 1.5)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
