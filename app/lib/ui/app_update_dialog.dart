import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../sync/app_update.dart';
import '../sync/sync_service.dart';
import 'common.dart';
import 'theme.dart';

/// Offers [release] and, if taken, downloads it and hands it to Android's installer.
Future<void> showAppUpdate(BuildContext context, AppRelease release) {
  AppUpdate.offered();
  return showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _UpdateDialog(release));
}

enum _Step { offer, downloading, allow, failed }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog(this.release);

  final AppRelease release;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  var _step = _Step.offer;
  var _problem = '';
  var _noSettings = false; // the device has no screen for the permission: said in words instead
  File? _apk;
  AppLifecycleListener? _back;

  @override
  void dispose() {
    _back?.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    final l = context.l10n;
    setState(() => _step = _Step.downloading);
    final File apk;
    try {
      apk = await SyncService.instance.downloadUpdate(widget.release);
    } on UpdateDamaged {
      return _fail(l.updateDamaged);
    } on Object {
      return _fail(l.updateFailed);
    }
    if (mounted) await _install(apk);
  }

  Future<void> _install(File apk) async {
    _apk = apk;
    if (!await AppUpdate.canInstall()) {
      // Android asks once that the user allow it; back from its settings, it goes on by itself
      _back ??= AppLifecycleListener(
        onResume: () async {
          if (mounted && _step == _Step.allow && await AppUpdate.canInstall()) await _install(apk);
        },
      );
      if (mounted) setState(() => _step = _Step.allow);
      return;
    }
    final handed = await AppUpdate.install(apk);
    if (!mounted) return;
    // The installer is over the app now, and closes it to install
    handed ? Navigator.pop(context) : _fail(context.l10n.updateFailed);
  }

  Future<void> _openSettings() async {
    if (!await AppUpdate.allowInstall() && mounted) setState(() => _noSettings = true);
  }

  void _fail(String problem) {
    if (mounted) {
      setState(() {
        _step = _Step.failed;
        _problem = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final r = widget.release;
    const muted = TextStyle(color: AppColors.muted, height: 1.5);
    final alone = _step == _Step.downloading || (_step == _Step.allow && _noSettings);
    final close = SecondaryButton(
      // Anew for each step: with no other button, a remote's focus lands on it
      key: ValueKey((_step, _noSettings)),
      // Closing it does not stop a download: it goes on, and Update now later installs it at once
      label: switch (_step) {
        _Step.offer => l.updateLater,
        _Step.downloading => l.updateInBackground,
        _ => l.cancel,
      },
      autofocus: alone,
      onPressed: () => Navigator.pop(context),
    );
    // Back does what that button does, whatever the step: on a TV remote it is the way out, and
    // nothing is lost by it (the download goes on)
    return AlertDialog(
      title: Text(_step == _Step.allow ? l.updateAllowTitle : l.updateTitle(r.label)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: switch (_step) {
          _Step.offer => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r.notes.isNotEmpty ? r.notes : l.updateBody, style: const TextStyle(height: 1.5)),
              const SizedBox(height: 8),
              Text('${(r.size / 1e6).toStringAsFixed(1)} MB', style: muted),
            ],
          ),
          _Step.downloading => ValueListenableBuilder(
            valueListenable: AppUpdate.downloaded,
            builder: (context, share, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.updateDownloading),
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  value: share,
                  color: AppColors.text,
                  backgroundColor: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 8),
                Text(share == null ? '' : '${(share * 100).floor()} %', style: muted),
              ],
            ),
          ),
          _Step.allow => Text(_noSettings ? l.updateAllowManual : l.updateAllowBody, style: muted),
          _Step.failed => Text(_problem, style: muted),
        },
      ),
      actions: [
        close,
        switch (_step) {
          _Step.offer => PrimaryButton(
            icon: Icons.system_update_rounded,
            label: l.updateNow,
            autofocus: true,
            onPressed: _update,
          ),
          _Step.downloading => const SizedBox.shrink(),
          _Step.allow when _noSettings => const SizedBox.shrink(),
          _Step.allow => PrimaryButton(label: l.openSettings, autofocus: true, onPressed: _openSettings),
          _Step.failed => PrimaryButton(
            label: l.retry,
            autofocus: true,
            // Downloaded already, only the installer failed: that again
            onPressed: () => _apk != null ? _install(_apk!) : _update(),
          ),
        },
      ],
    );
  }
}
