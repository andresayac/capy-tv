import 'package:flutter/material.dart';

import '../data/recommender.dart';
import '../sync/sync_client.dart' show SyncClient;
import 'common.dart';
import 'profiles_screen.dart';
import 'remote_text_field.dart';
import 'theme.dart';

/// Account's section for the language model that picks titles for each profile ([Recommender]):
/// what it does, what it sends, and setting it up. Behind the parental PIN, when there is one.
class AiSettingsPanel extends StatelessWidget {
  const AiSettingsPanel({super.key});

  Future<void> _setUp(BuildContext context) async {
    if (!await confirmPin(context) || !context.mounted) return;
    final saved = await showDialog<bool>(context: context, builder: (_) => const _AiDialog());
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.aiSaved)));
    }
  }

  Future<void> _forgetOwn(BuildContext context) async {
    if (await confirmPin(context)) await Recommender.configure(null);
  }

  Future<void> _turn(BuildContext context, {required bool on}) async {
    if (await confirmPin(context)) await Recommender.turn(on: on);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return ValueListenableBuilder(
      valueListenable: Recommender.service,
      builder: (context, s, _) => Panel(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.aiBody, style: const TextStyle(color: AppColors.muted, height: 1.5)),
            const SizedBox(height: 14),
            Text(switch (s) {
              null when Recommender.off => l.aiTurnedOff,
              null => l.aiOff,
              _ when s.viaServer => l.aiFromServer(s.baseUrl),
              _ when Recommender.usingBuiltIn => l.aiBuiltIn,
              _ => '${s.model} · ${Uri.tryParse(s.baseUrl)?.host ?? s.baseUrl}',
            }, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (Recommender.keyLost) ...[
              const SizedBox(height: 6),
              Text(l.aiKeyLost, style: const TextStyle(color: AppColors.errorText, height: 1.4)),
            ],
            // Unlike everything else, what goes to the server for this is readable there
            if (s != null && s.viaServer) ...[
              const SizedBox(height: 6),
              Text(l.aiServerNote, style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4)),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (Recommender.off && Recommender.canTurnOn)
                  SecondaryButton(
                    icon: Icons.restart_alt_rounded,
                    label: l.aiUseBuiltIn,
                    onPressed: () => _turn(context, on: true),
                  )
                else
                  SecondaryButton(
                    icon: Icons.auto_awesome_outlined,
                    label: s == null ? l.aiSetUp : (Recommender.usingOwn ? l.aiChange : l.aiOwn),
                    onPressed: () => _setUp(context),
                  ),
                if (Recommender.usingOwn)
                  SecondaryButton(icon: Icons.close_rounded, label: l.aiRemove, onPressed: () => _forgetOwn(context)),
                if (s != null)
                  SecondaryButton(
                    icon: Icons.block_rounded,
                    label: l.aiTurnOff,
                    onPressed: () => _turn(context, on: false),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Address, model and key of the service; checked with a short question before it is saved.
class _AiDialog extends StatefulWidget {
  const _AiDialog();

  @override
  State<_AiDialog> createState() => _AiDialogState();
}

class _AiDialogState extends State<_AiDialog> {
  final _form = GlobalKey<FormState>();
  final _current = Recommender.service.value;
  // The key that an empty field keeps; never the one built into the app, for another service
  late final _kept = Recommender.usingOwn ? _current : null;
  late final _url = TextEditingController(text: Recommender.usingOwn ? _current!.baseUrl : AiService.defaultUrl);
  late final _model = TextEditingController(text: Recommender.usingOwn ? _current!.model : '');
  final _key = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    final l = context.l10n;
    final s = AiService(
      baseUrl: _url.text.trim(),
      model: _model.text.trim(),
      // Empty: the key set up before, so it need not be typed again on a remote; only for the
      // service it was set up for, never sent to another address
      apiKey: _key.text.trim().isNotEmpty
          ? _key.text.trim()
          : _kept != null && _sameService(_kept.baseUrl, _url.text.trim())
          ? _kept.apiKey
          : '',
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Recommender.test(s);
      await Recommender.configure(s);
      if (mounted) Navigator.pop(context, true);
    } on AiException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = switch (e.problem) {
          AiProblem.key when _key.text.trim().isEmpty && _kept != null => l.aiKeyAgain,
          AiProblem.key => l.aiWrongKey,
          AiProblem.model => l.aiWrongModel,
          AiProblem.busy => l.aiBusy,
          AiProblem.service when int.tryParse(e.detail) != null => l.aiServiceError(e.detail),
          AiProblem.service => l.aiUnreachable,
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // Darker than the dialog, which has the fields' usual color
    InputDecoration field(String label, {String? helper}) =>
        InputDecoration(labelText: label, helperText: helper, helperMaxLines: 2, fillColor: AppColors.surface);
    return AlertDialog(
      title: Text(l.aiTitle),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RemoteTextFormField(
                  controller: _url,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                  decoration: field(l.aiUrl, helper: l.aiUrlHint),
                  validator: (v) => switch (Uri.tryParse(v?.trim() ?? '')) {
                    final u? when u.isScheme('https') && u.host.isNotEmpty => null,
                    final u? when u.isScheme('http') && u.host.isNotEmpty =>
                      SyncClient.isLocal(u.host) ? null : l.aiUrlInsecure,
                    _ => l.aiUrl,
                  },
                ),
                const SizedBox(height: 12),
                RemoteTextFormField(
                  controller: _model,
                  textInputAction: TextInputAction.next,
                  decoration: field(l.aiModel),
                  validator: (v) => (v ?? '').trim().isEmpty ? l.aiModel : null,
                ),
                const SizedBox(height: 12),
                RemoteTextFormField(
                  controller: _key,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: field(l.aiKey, helper: _kept == null ? null : l.aiKeyKept),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: unlessBusy(_busy, () => Navigator.pop(context)), child: Text(l.cancel)),
        TextButton(onPressed: unlessBusy(_busy, _submit), child: Text(l.aiTestAndSave)),
      ],
    );
  }
}

/// The same service: scheme, host and port alike, whatever the path.
bool _sameService(String a, String b) {
  final x = Uri.tryParse(a), y = Uri.tryParse(b);
  return x != null && y != null && x.scheme == y.scheme && x.host == y.host && x.port == y.port;
}
