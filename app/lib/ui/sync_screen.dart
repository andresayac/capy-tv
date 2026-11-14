import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../device.dart';
import '../l10n/app_localizations.dart';
import '../sync/sync_client.dart';
import '../sync/sync_crypto.dart';
import '../sync/sync_service.dart';
import 'backdrop.dart';
import 'common.dart';
import 'remote_text_field.dart';
import 'theme.dart';

/// The sync account: sign in or create one, then see how it is going and which devices share it.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _sync = SyncService.instance;
  final _form = GlobalKey<FormState>();
  late final _server = TextEditingController(
    text: _sync.server?.toString() ?? const String.fromEnvironment('SYNC_SERVER'),
  );
  late final _email = TextEditingController(text: _sync.email);
  final _password = TextEditingController();
  final _again = TextEditingController();
  final _invite = TextEditingController();
  final _recoveryKey = TextEditingController();
  var _mode = _Mode.signIn;
  var _busy = false;
  String? _error;
  var _unreachable = false; // what failed last could not reach the server
  Future<List<Device>>? _devices;

  bool get _signedIn => _sync.status != SyncStatus.off && _sync.status != SyncStatus.expired;

  @override
  void initState() {
    super.initState();
    _sync.addListener(_changed);
    if (_signedIn) _devices = _sync.devices();
  }

  @override
  void dispose() {
    _sync.removeListener(_changed);
    for (final c in [_server, _email, _password, _again, _invite, _recoveryKey]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    // The recovery key is shown even if this screen is gone by then: it is the only time it can be
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
      _unreachable = false;
    });
    final server = SyncClient.parseServer(_server.text)!;
    RecoveryKey? made;
    try {
      switch (_mode) {
        case _Mode.signIn:
          await _sync.signIn(server: server, email: _email.text, password: _password.text);
        case _Mode.create:
          made = await _sync.createAccount(
            server: server,
            email: _email.text,
            password: _password.text,
            invite: _invite.text,
          );
        case _Mode.recover:
          await _sync.recover(
            server: server,
            email: _email.text,
            recoveryKey: RecoveryKey.parse(_recoveryKey.text)!,
            password: _password.text,
          );
      }
      for (final c in [_password, _again, _recoveryKey]) {
        c.clear();
      }
      _mode = _Mode.signIn;
      _devices = _sync.devices();
    } on SyncException catch (e) {
      if (!mounted) return;
      final l = context.l10n;
      final wrongKey = _mode == _Mode.recover && e.problem == SyncProblem.credentials;
      setState(() {
        _error = wrongKey ? l.syncErrorRecovery : _problem(l, e.problem);
        _unreachable = e.problem == SyncProblem.network;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (made != null) await showRecoveryKey(mounted ? context : navigator.context, made);
  }

  Future<void> _act(Future<void> Function() action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (done != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } on SyncException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _problem(context.l10n, e.problem);
        _unreachable = e.problem == SyncProblem.network;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOutDevice(Device d) async {
    final l = context.l10n;
    final sure = await showConfirm(
      context,
      message: l.syncSignOutDeviceConfirm(d.name),
      confirmLabel: l.syncSignOutDevice,
    );
    if (!sure) return;
    await _act(() async {
      await _sync.signOutDevice(d.id);
      _devices = _sync.devices();
    });
  }

  Future<void> _changePassword() async {
    final l = context.l10n;
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => PasswordsDialog(
        title: l.syncChangePassword,
        body: l.syncChangePasswordBody,
        labels: [l.syncCurrentPassword, l.syncNewPassword, l.syncPasswordAgain],
        action: l.syncChangePassword,
        run: (p) async {
          await _sync.changePassword(current: p[0], password: p[1]);
          return true;
        },
      ),
    );
    if (changed != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.syncPasswordChanged)));
    setState(() {
      _devices = _sync.devices(); // the others are signed out
    });
  }

  Future<void> _newRecoveryKey() async {
    final l = context.l10n;
    final key = await showDialog<RecoveryKey>(
      context: context,
      builder: (_) => PasswordsDialog(
        title: l.syncNewRecoveryKey,
        body: l.syncNewRecoveryKeyBody,
        labels: [l.syncPassword],
        action: l.syncNewRecoveryKey,
        run: (p) => _sync.newRecoveryKey(p[0]),
      ),
    );
    if (key != null && mounted) await showRecoveryKey(context, key);
  }

  Future<void> _deleteAccount() async {
    final l = context.l10n;
    final deleted = await showDialog<bool>(
      context: context,
      builder: (_) => PasswordsDialog(
        title: l.syncDeleteAccount,
        body: l.syncDeleteConfirm,
        labels: [l.syncPassword],
        action: l.syncDeleteAccount,
        run: (p) async {
          await _sync.deleteAccount(p[0]);
          return true;
        },
      ),
    );
    if (deleted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.syncSignedOut)));
    }
  }

  static String _problem(AppLocalizations l, SyncProblem p) => switch (p) {
    SyncProblem.credentials => l.syncErrorCredentials,
    SyncProblem.exists => l.syncErrorExists,
    SyncProblem.rateLimited => l.syncErrorRateLimited,
    SyncProblem.network => l.syncErrorNetwork,
    SyncProblem.signedOut => l.syncStatusExpired,
    SyncProblem.invite => l.syncErrorInvite,
    SyncProblem.full => l.syncErrorFull,
    SyncProblem.quota => l.syncErrorQuota,
    SyncProblem.server || SyncProblem.stale || SyncProblem.notFound => l.syncErrorFailed,
  };

  String _time(DateTime t) => DateUtils.isSameDay(t, DateTime.now()) ? clockText(context, t) : dayAndClock(context, t);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final text = Theme.of(context).textTheme;
    // Capy when something needs doing: signing in, or a server out of reach
    final mood = _unreachable || _sync.status == SyncStatus.offline
        ? CapyMood.offline
        : (_signedIn ? null : CapyMood.account);
    final intro = [
      if (mood == null)
        const Icon(Icons.cloud_sync_outlined, size: 48, color: AppColors.text)
      else
        CapyStatus(mood: mood, size: 48),
      const SizedBox(height: 20),
      Text(l.syncTitle, style: text.headlineMedium),
      const SizedBox(height: 12),
      Text(l.syncBody, style: text.bodyLarge?.copyWith(color: AppColors.muted, height: 1.5)),
    ];
    final main = _signedIn ? _status(l, text) : _signInForm(l);
    // Not left while an account is made or signed in to: its recovery key would not be shown
    return PosterBackdrop(
      child: PopScope(
        canPop: !_busy,
        child: Scaffold(
          appBar: AppBar(title: Text(l.sync)),
          body: SafeArea(
            top: false,
            child: isWide(context)
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: SingleChildScrollView(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: intro),
                          ),
                        ),
                        const SizedBox(width: 56),
                        Expanded(
                          flex: 6,
                          child: Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(vertical: 24),
                              child: main,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
                        children: [...intro, const SizedBox(height: 28), main],
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  void _switch(_Mode mode) => setState(() {
    _mode = mode;
    _error = null;
    _unreachable = false;
  });

  Widget _signInForm(AppLocalizations l) {
    final expired = _sync.status == SyncStatus.expired;
    final create = _mode == _Mode.create, recover = _mode == _Mode.recover;
    final newPassword = create || recover;
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (expired && !recover) ...[_statusLine(l), const SizedBox(height: 16)],
          if (recover) ...[
            Text(l.syncRecoverBody, style: const TextStyle(color: AppColors.muted, height: 1.4)),
            const SizedBox(height: 16),
          ],
          RemoteTextFormField(
            controller: _server,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: l.syncServer, hintText: 'https://sync.example.com'),
            validator: (v) => SyncClient.parseServer(v ?? '') == null ? l.syncErrorServer : null,
          ),
          const SizedBox(height: 12),
          RemoteTextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(labelText: l.syncEmail),
            validator: (v) =>
                RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : l.syncErrorEmail,
          ),
          if (recover) ...[
            const SizedBox(height: 12),
            RemoteTextFormField(
              controller: _recoveryKey,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: l.syncRecoveryKey, hintText: 'XXXX-XXXX-XXXX-XXXX-…'),
              validator: (v) => RecoveryKey.parse(v ?? '') == null ? l.syncErrorRecoveryKey : null,
            ),
          ],
          const SizedBox(height: 12),
          RemoteTextFormField(
            controller: _password,
            obscureText: true,
            textInputAction: newPassword ? TextInputAction.next : TextInputAction.done,
            onFieldSubmitted: newPassword ? null : (_) => _submit(),
            autofillHints: [newPassword ? AutofillHints.newPassword : AutofillHints.password],
            decoration: InputDecoration(labelText: recover ? l.syncNewPassword : l.syncPassword),
            validator: (v) => (v ?? '').length < (newPassword ? 8 : 1) ? l.syncErrorShort : null,
          ),
          if (newPassword) ...[
            const SizedBox(height: 12),
            RemoteTextFormField(
              controller: _again,
              obscureText: true,
              textInputAction: create ? TextInputAction.next : TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: l.syncPasswordAgain),
              validator: (v) => v != _password.text ? l.syncErrorMismatch : null,
            ),
          ],
          if (create) ...[
            const SizedBox(height: 12),
            RemoteTextFormField(
              controller: _invite,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: l.syncInvite, helperText: l.syncInviteHint),
            ),
            const SizedBox(height: 12),
            Text(l.syncPasswordNote, style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 24),
          if (_busy)
            Row(
              children: [
                const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Text(l.syncWorking),
              ],
            )
          else
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // With a remote, start on the button: the fields are one press up
                PrimaryButton(
                  autofocus: isTv,
                  icon: switch (_mode) {
                    _Mode.signIn => Icons.login_rounded,
                    _Mode.create => Icons.person_add_alt_rounded,
                    _Mode.recover => Icons.lock_reset_rounded,
                  },
                  label: switch (_mode) {
                    _Mode.signIn => l.syncSignIn,
                    _Mode.create => l.syncCreate,
                    _Mode.recover => l.syncRecover,
                  },
                  onPressed: _submit,
                ),
                if (_mode == _Mode.signIn) ...[
                  TextButton(onPressed: () => _switch(_Mode.create), child: Text(l.syncToCreate)),
                  TextButton(onPressed: () => _switch(_Mode.recover), child: Text(l.syncForgot)),
                ] else
                  TextButton(
                    onPressed: () => _switch(_Mode.signIn),
                    child: Text(create ? l.syncToSignIn : l.syncBackToSignIn),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _statusLine(AppLocalizations l) {
    final (icon, label) = switch (_sync.status) {
      SyncStatus.synced => (
        Icons.cloud_done_outlined,
        l.syncStatusSynced(_sync.lastSync == null ? '' : _time(_sync.lastSync!)),
      ),
      SyncStatus.syncing => (Icons.sync_rounded, l.syncStatusSyncing),
      SyncStatus.offline => (Icons.cloud_off_outlined, l.syncStatusOffline),
      SyncStatus.expired => (Icons.lock_clock_outlined, l.syncStatusExpired),
      SyncStatus.off => (Icons.cloud_outlined, l.syncStatusOff),
    };
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.text),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _status(AppLocalizations l, TextTheme text) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Panel(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_sync.email ?? '', style: text.titleMedium),
            Text(
              _sync.server?.host ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            _statusLine(l),
            if (_sync.status == SyncStatus.offline && _sync.problem != null) ...[
              const SizedBox(height: 6),
              Text(_problem(l, _sync.problem!), style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            ],
          ],
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          PrimaryButton(
            autofocus: true,
            icon: Icons.sync_rounded,
            label: l.syncNow,
            onPressed: _busy
                ? null
                : () => _act(() async {
                    await _sync.syncNow();
                    _devices = _sync.devices();
                  }),
          ),
          SecondaryButton(
            icon: Icons.logout_rounded,
            label: l.syncSignOut,
            onPressed: unlessBusy(_busy, () async {
              // It gets nothing new from then on: asked first, as signing another device out is
              final sure = await showConfirm(context, message: l.syncSignOutConfirm, confirmLabel: l.syncSignOut);
              if (sure) await _act(_sync.signOut, done: l.syncSignedOut);
            }),
          ),
          SecondaryButton(
            icon: Icons.password_rounded,
            label: l.syncChangePassword,
            onPressed: unlessBusy(_busy, _changePassword),
          ),
          SecondaryButton(
            icon: Icons.key_rounded,
            label: l.syncNewRecoveryKey,
            onPressed: unlessBusy(_busy, _newRecoveryKey),
          ),
          SecondaryButton(
            icon: Icons.delete_outline_rounded,
            label: l.syncDeleteAccount,
            onPressed: unlessBusy(_busy, _deleteAccount),
          ),
        ],
      ),
      const SizedBox(height: 28),
      Text(l.syncDevices, style: text.titleLarge),
      const SizedBox(height: 8),
      FutureBuilder(
        future: _devices,
        builder: (context, snap) => Column(
          children: [
            for (final d in snap.data ?? const <Device>[])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Icon(Icons.devices_rounded, size: 20, color: AppColors.muted),
                    const SizedBox(width: 12),
                    Expanded(child: Text(d.name)),
                    Text(
                      d.current ? l.syncThisDevice : l.syncSeen(_time(d.seen.toLocal())),
                      style: const TextStyle(color: AppColors.muted),
                    ),
                    // A lost phone, a TV given away: it gets nothing new
                    if (d.current)
                      const SizedBox(width: 48)
                    else
                      IconButton(
                        tooltip: l.syncSignOutDevice,
                        icon: const Icon(Icons.logout_rounded, size: 20),
                        onPressed: unlessBusy(_busy, () => _signOutDevice(d)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

enum _Mode { signIn, create, recover }

/// Asks for passwords and runs [run] with them, staying open with the reason while it fails.
/// With more than one label, the last two are a new password and its repetition.
class PasswordsDialog<T> extends StatefulWidget {
  const PasswordsDialog({
    super.key,
    required this.title,
    required this.body,
    required this.labels,
    required this.action,
    required this.run,
  });

  final String title, body, action;
  final List<String> labels;
  final Future<T> Function(List<String> passwords) run;

  @override
  State<PasswordsDialog<T>> createState() => _PasswordsDialogState<T>();
}

class _PasswordsDialogState<T> extends State<PasswordsDialog<T>> {
  final _form = GlobalKey<FormState>();
  late final _fields = [for (final _ in widget.labels) TextEditingController()];
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _fields) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.run([for (final c in _fields) c.text]);
      if (mounted) Navigator.pop(context, result);
    } on SyncException catch (e) {
      if (!mounted) return;
      final l = context.l10n;
      setState(
        () => _error = e.problem == SyncProblem.credentials
            ? l.syncErrorPassword
            : _SyncScreenState._problem(l, e.problem),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final n = _fields.length;
    final changing = n > 1;
    // Not closed while it works: a new recovery key would never be shown, or a new password take
    // effect while it seemed cancelled
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 440,
          child: Form(
            key: _form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.body, style: const TextStyle(color: AppColors.muted, height: 1.4)),
                  for (var i = 0; i < n; i++) ...[
                    SizedBox(height: i == 0 ? 20 : 12),
                    RemoteTextFormField(
                      controller: _fields[i],
                      autofocus: i == 0,
                      obscureText: true,
                      textInputAction: i < n - 1 ? TextInputAction.next : TextInputAction.done,
                      onFieldSubmitted: i < n - 1 ? null : (_) => _submit(),
                      // Darker than the dialog, which has the fields' usual color
                      decoration: InputDecoration(labelText: widget.labels[i], fillColor: AppColors.surface),
                      validator: (v) => switch (i) {
                        _ when changing && i == n - 1 => v != _fields[n - 2].text ? l.syncErrorMismatch : null,
                        _ when changing && i == n - 2 => (v ?? '').length < 8 ? l.syncErrorShort : null,
                        _ => (v ?? '').isEmpty ? l.syncErrorShort : null,
                      },
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  if (_busy) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Text(l.syncWorking),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: unlessBusy(_busy, () => Navigator.pop(context)), child: Text(l.cancel)),
          TextButton(onPressed: unlessBusy(_busy, _submit), child: Text(widget.action)),
        ],
      ),
    );
  }
}

/// Shows an account's recovery key for the user to write down. It is the only time it is shown.
/// Neither Back nor an OK too many closes it: on a TV, "I wrote it down" answers only after a few
/// seconds, as the focus is on it from the start.
Future<void> showRecoveryKey(BuildContext context, RecoveryKey key) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _RecoveryKeyDialog(recoveryKey: key),
);

class _RecoveryKeyDialog extends StatefulWidget {
  const _RecoveryKeyDialog({required this.recoveryKey});

  final RecoveryKey recoveryKey;

  @override
  State<_RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<_RecoveryKeyDialog> {
  var _copied = false;
  late var _ready = !isTv;

  @override
  void initState() {
    super.initState();
    if (!_ready) {
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _ready = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final text = widget.recoveryKey.text;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(l.syncRecoveryTitle),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.syncRecoveryBody, style: const TextStyle(color: AppColors.muted, height: 1.5)),
                const SizedBox(height: 20),
                Panel(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                  // Two lines of four groups, to copy one at a time
                  child: Text(
                    '${text.substring(0, 19)}\n${text.substring(20)}',
                    key: const ValueKey('recoveryKey'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 2,
                      height: 1.6,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (!isTv)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                setState(() => _copied = true);
              },
              child: Text(_copied ? l.syncCopied : l.syncCopy),
            ),
          TextButton(
            autofocus: true,
            onPressed: _ready ? () => Navigator.pop(context) : null,
            child: Text(l.syncRecoverySaved),
          ),
        ],
      ),
    );
  }
}
