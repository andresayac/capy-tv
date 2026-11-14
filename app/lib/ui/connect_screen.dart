import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/settings.dart';
import '../device.dart';
import '../l10n/app_localizations.dart';
import '../remote/companion_server.dart';
import '../remote/companion_strings.dart';
import 'backdrop.dart';
import 'common.dart';
import 'theme.dart';

/// Shows the code a phone scans to open the companion page: add playlists with the phone's
/// keyboard, use it as a remote, move backups. [tab] is the part of the page it opens on
/// ('add', 'remote' or 'backup'); with [closeOnPlaylist] the screen goes back once a playlist
/// arrives, as when it was opened to add one.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.tab = 'add', this.closeOnPlaylist = false});

  final String tab;
  final bool closeOnPlaylist;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _server = CompanionServer.instance;
  StreamSubscription<CompanionEvent>? _events;
  var _started = false;
  String? _received; // name of a playlist that just arrived

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _server
        .hold(settings: SettingsScope.maybeOf(context), strings: companionStrings(context.l10n))
        .then((_) => mounted ? setState(() {}) : null);
    _events = _server.events.listen((e) {
      if (e is! PlaylistReceived || !mounted) return;
      setState(() => _received = e.name);
      if (widget.closeOnPlaylist) {
        Future<void>.delayed(const Duration(milliseconds: 1600), () => mounted ? Navigator.maybePop(context) : null);
      }
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    _server.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final wide = isWide(context, min: 760);
    return PosterBackdrop(
      child: Scaffold(
        appBar: AppBar(title: Text(l.connectPhone)),
        body: ListenableBuilder(
          listenable: _server,
          builder: (context, _) {
            final url = _server.url;
            if (url == null) return const Center(child: CapyStatus(mood: CapyMood.loading));
            if (!_server.reachable) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: CapyMessage(
                    mood: CapyMood.offline,
                    text: l.connectNoNetwork,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              );
            }
            // The QR carries the key that seals passwords and backups; the address shown for typing does not
            final link = _server.link(widget.tab).toString();
            final code = QrCard(data: link, size: wide ? 300 : 240);
            final info = _Instructions(address: url.toString(), status: _status(l));
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: wide
                      ? Row(
                          children: [
                            code,
                            const SizedBox(width: 56),
                            Expanded(child: info),
                          ],
                        )
                      : Column(children: [code, const SizedBox(height: 28), info]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _status(AppLocalizations l) {
    final (icon, text, done) = switch ((_received, _server.remotes)) {
      (final name?, _) => (Icons.check_circle_rounded, l.playlistReceived(name), true),
      (_, > 0) => (Icons.phonelink_rounded, l.connectRemoteOn, true),
      _ => (Icons.hourglass_empty_rounded, l.connectWaiting, false),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Panel(
        key: ValueKey(text),
        color: done ? AppColors.text : AppColors.surfaceHigh,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: done ? AppColors.black : AppColors.muted),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                text,
                style: TextStyle(fontWeight: FontWeight.w600, color: done ? AppColors.black : AppColors.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A QR code on white, as phones read it best.
class QrCard extends StatelessWidget {
  const QrCard({super.key, required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppRadius.panel)),
    child: QrImageView(
      data: data,
      size: size,
      padding: EdgeInsets.zero,
      backgroundColor: Colors.white,
      eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
      dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
      semanticsLabel: data,
    ),
  );
}

class _Instructions extends StatelessWidget {
  const _Instructions({required this.address, required this.status});

  final String address;
  final Widget status;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.connectPhone, style: text.headlineMedium),
        const SizedBox(height: 12),
        Text(l.connectPhoneBody, style: text.bodyLarge?.copyWith(color: AppColors.muted)),
        const SizedBox(height: 16),
        Row(
          children: [
            const Icon(Icons.wifi_rounded, size: 18, color: AppColors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(l.connectSameNetwork(deviceName), style: const TextStyle(color: AppColors.muted)),
            ),
          ],
        ),
        const SizedBox(height: 24),
        status,
        const SizedBox(height: 24),
        Text(l.connectOrOpen, style: const TextStyle(color: AppColors.subtle, fontSize: 13)),
        const SizedBox(height: 4),
        SelectableText(address, style: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.2)),
      ],
    );
  }
}
