import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../data/backup.dart';
import '../data/settings.dart';
import '../remote/companion_seal.dart';
import '../sync/sync_client.dart';
import 'backdrop.dart';
import 'common.dart';
import 'profiles_screen.dart';
import 'theme.dart';

/// Opened from the companion page of another device (a TV) through a
/// `capytv://open/pair?u=<address>&t=<session code>&n=<name>` link: moves lists, favorites
/// and history between this device and that one, straight over the local network.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.link});

  final Uri link;

  /// Builds the screen for an app link, or null when the link is not one of ours.
  static PairScreen? forRoute(String? name) {
    final uri = Uri.tryParse(name ?? '');
    if (uri == null || uri.path != '/pair') return null;
    final q = uri.queryParameters;
    // Any web page can open this link: only a device on this network, with the key its QR carries
    final base = Uri.tryParse(q['u'] ?? '');
    if (base == null || base.scheme != 'http' || !SyncClient.isLocal(base.host) || q['t'] == null) return null;
    try {
      CompanionSeal.fromText(q['k'] ?? '');
    } on Object {
      return null;
    }
    return PairScreen(link: uri);
  }

  /// The other device's name. One with "#" ("TV #2"), in the route Flutter makes of the link once
  /// the app is open, ends the query there: the name goes last in the link, and its rest is the
  /// fragment.
  String get device {
    final q = link.queryParameters;
    return switch (q['n']) {
      final n? when link.hasFragment => '$n#${link.fragment}',
      final n? => n,
      null => Uri.parse(q['u']!).host,
    };
  }

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  late final _q = widget.link.queryParameters;
  late final _base = Uri.parse(_q['u']!);
  late final _token = _q['t']!;
  late final _device = widget.device;
  // The key the other device's QR carried: backups travel sealed with it
  late final _seal = CompanionSeal.fromText(_q['k']!);
  String? _busy; // which action is running
  String? _message;
  var _failed = false;

  Uri _api(String path) => _base.replace(path: path, queryParameters: {'t': _token});

  Future<void> _run(String action, Future<String> Function() work) async {
    setState(() {
      _busy = action;
      _message = null;
    });
    try {
      final text = await work();
      if (mounted) {
        setState(() {
          _message = text;
          _failed = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          // One from a newer version says so: it is not this device that failed
          _message = e is BackupTooNew ? context.l10n.webBackupNewer : context.l10n.pairFailed(_device);
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<String> _send() async {
    final l = context.l10n;
    final backup = await Backup.export(settings: SettingsScope.maybeOf(context));
    final sealed = await _seal.seal('/api/backup', backup);
    final r = await http
        .post(_api('/api/backup'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'sealed': sealed}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw http.ClientException('${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return l.pairSent(j['added'] as int, j['updated'] as int, _device);
  }

  Future<String> _receive() async {
    final l = context.l10n;
    final settings = SettingsScope.maybeOf(context);
    final r = await http.get(_api('/api/backup')).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw http.ClientException('${r.statusCode}');
    final sealed = (jsonDecode(r.body) as Map<String, dynamic>)['sealed'] as String;
    final data = await _seal.open('/api/backup', sealed) as Map<String, dynamic>;
    final result = await Backup.import(data, settings: settings);
    return [l.pairReceived(result.added, result.updated), if (result.noPassword > 0) l.noSecureStorage].join('\n');
  }

  void _leave() => Navigator.of(context).pop();

  Future<void> _guarded(String action, Future<String> Function() work) async {
    if (!await confirmPin(context) || !mounted) return;
    await _run(action, work);
  }

  Future<void> _remote() => launchUrl(
    _base.replace(path: '/', queryParameters: {'t': _token}, fragment: 'remote&k=${_q['k']}'),
    mode: LaunchMode.externalApplication,
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: Navigator.of(context).canPop(),
      onPopInvokedWithResult: (didPop, _) => didPop ? null : _leave(),
      child: PosterBackdrop(
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(icon: const Icon(Icons.close_rounded), tooltip: l.close, onPressed: _leave),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                children: [
                  const Align(alignment: Alignment.centerLeft, child: Icon(Icons.devices_rounded, size: 40)),
                  const SizedBox(height: 16),
                  Text(l.pairTitle(_device), style: text.headlineMedium),
                  const SizedBox(height: 10),
                  Text(l.pairBody(_device), style: text.bodyLarge?.copyWith(color: AppColors.muted)),
                  const SizedBox(height: 10),
                  Text(l.pairCheck(_base.authority, _token), style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 28),
                  _Action(
                    icon: Icons.upload_rounded,
                    label: l.pairSend(_device),
                    busy: _busy == 'send',
                    primary: true,
                    onPressed: _busy == null ? () => _guarded('send', _send) : null,
                  ),
                  _Action(
                    icon: Icons.download_rounded,
                    label: l.pairReceive(_device),
                    busy: _busy == 'receive',
                    onPressed: _busy == null ? () => _guarded('receive', _receive) : null,
                  ),
                  _Action(icon: Icons.gamepad_rounded, label: l.pairRemote, onPressed: _remote),
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Panel(
                      color: _failed ? const Color(0xFF2A0F0E) : AppColors.surfaceHigh,
                      padding: const EdgeInsets.all(16),
                      child: Text(_message!, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy, primary;

  @override
  Widget build(BuildContext context) {
    final button = primary
        ? PrimaryButton(icon: busy ? null : icon, label: label, onPressed: onPressed)
        : SecondaryButton(icon: busy ? null : icon, label: label, onPressed: onPressed);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(child: button),
          if (busy) ...[
            const SizedBox(width: 12),
            const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ],
      ),
    );
  }
}
