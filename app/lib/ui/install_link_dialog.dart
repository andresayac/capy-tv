import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../sync/sync_client.dart';
import '../sync/sync_service.dart';
import 'common.dart';
import 'connect_screen.dart' show QrCard;
import 'theme.dart';

/// An install link from the account's server (server/README.md, "App updates"): an address to type
/// on a device with no session, such as Downloader on a Fire TV, and its QR, for a phone.
Future<void> showInstallLink(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => InstallLinkDialog(request: SyncService.instance.installLink),
);

typedef InstallLink = ({Uri address, DateTime expires});

class InstallLinkDialog extends StatefulWidget {
  const InstallLinkDialog({super.key, required this.request});

  /// Asks the server for a link; null when it has no release (see [SyncService.installLink]).
  final Future<InstallLink?> Function() request;

  /// What to type: the address without its scheme, which apps like Downloader add.
  static String typed(Uri address) => address.toString().replaceFirst(RegExp('^https?://'), '');

  @override
  State<InstallLinkDialog> createState() => _InstallLinkDialogState();
}

class _InstallLinkDialogState extends State<InstallLinkDialog> {
  InstallLink? _link;
  SyncProblem? _problem;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  Future<void> _ask() async {
    InstallLink? link;
    SyncProblem? problem;
    try {
      link = await widget.request();
      if (link == null) problem = SyncProblem.notFound;
    } on SyncException catch (e) {
      problem = e.problem;
    } on Object {
      problem = SyncProblem.server;
    }
    if (mounted) {
      setState(() {
        _link = link;
        _problem = problem;
      });
    }
  }

  static String _problemText(AppLocalizations l, SyncProblem p) => switch (p) {
    SyncProblem.notFound => l.installLinkNoApp,
    SyncProblem.network => l.syncErrorNetwork,
    SyncProblem.signedOut => l.syncStatusExpired,
    SyncProblem.rateLimited => l.installLinkTooMany,
    _ => l.syncErrorFailed,
  };

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    const muted = TextStyle(color: AppColors.muted, height: 1.5);
    final link = _link, problem = _problem;
    // Short screens (phones lie down) get a smaller code
    final qr = (MediaQuery.sizeOf(context).height * 0.3).clamp(96.0, 180.0);
    return AlertDialog(
      scrollable: true,
      title: Text(l.installOtherDevice),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: switch ((link, problem)) {
          (_, final SyncProblem p) => Text(_problemText(l, p), style: muted),
          (final InstallLink link, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Its own size, as the dialog measures what it holds and the QR cannot say (QrCard's padding)
              SizedBox.square(
                dimension: qr + 36,
                child: QrCard(data: link.address.toString(), size: qr),
              ),
              const SizedBox(width: 28),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.installLinkType, style: muted),
                    const SizedBox(height: 6),
                    // On one line, smaller if it must: a broken address is hard to type
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        InstallLinkDialog.typed(link.address),
                        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(l.installLinkScan, style: muted),
                    Text(l.installLinkValid(_minutesLeft(link.expires)), style: muted),
                  ],
                ),
              ),
            ],
          ),
          _ => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(width: 18),
              Flexible(child: Text(l.installLinkLoading)),
            ],
          ),
        },
      ),
      actions: [SecondaryButton(label: l.close, autofocus: true, onPressed: () => Navigator.pop(context))],
    );
  }

  /// The server's links last 30 minutes: a device clock that is off says no more, nor less than one.
  static int _minutesLeft(DateTime expires) => (expires.difference(DateTime.now()).inSeconds / 60).round().clamp(1, 30);
}
