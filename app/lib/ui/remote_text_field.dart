import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../device.dart';
import '../remote/remote_input.dart';
import 'common.dart';
import 'theme.dart';

/// A form's text field, as a TV remote can fill it in. Elsewhere a plain [TextFormField].
///
/// On a TV the field shows what it holds, and OK opens a small window with that field alone, its
/// keyboard open. Moving between fields with the keyboard up confuses TV keyboards (Fire TV's goes on
/// showing, and typing into, the field before), and a remote cannot tap a field to get its keyboard
/// back; one field at a time, there is nothing to confuse.
class RemoteTextFormField extends StatelessWidget {
  const RemoteTextFormField({
    super.key,
    required this.controller,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.obscureText = false,
    this.autofillHints,
    this.autofocus = false,
    this.onChanged,
    this.onFieldSubmitted,
    this.validator,
  });

  final TextEditingController controller;
  final InputDecoration decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final bool autocorrect, enableSuggestions, obscureText, autofocus;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onChanged, onFieldSubmitted;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    if (!isTv && obscureText) return _SecretField(this);
    if (!isTv) {
      return TextFormField(
        controller: controller,
        decoration: decoration,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        obscureText: obscureText,
        autofillHints: autofillHints,
        autofocus: autofocus,
        onChanged: onChanged,
        onFieldSubmitted: onFieldSubmitted,
        validator: validator,
      );
    }
    return FormField<String>(
      initialValue: controller.text,
      validator: validator == null ? null : (_) => validator!(controller.text),
      builder: (state) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final text = controller.text;
          // Typed on the phone with this field focused, it comes here (see typeRemoteText)
          return RemoteTextTarget(
            secret: obscureText,
            take: (typed) {
              controller.text = typed;
              state.didChange(typed);
              onChanged?.call(typed);
            },
            child: Focusable(
              autofocus: autofocus,
              scale: 1,
              radius: AppRadius.button,
              onTap: () => _edit(context, state),
              child: InputDecorator(
                // No outline: its floating label sits half over the top edge, which the focus ring's
                // clip cut off; without one it floats inside, and the ring rounds the corners
                decoration: decoration.copyWith(
                  errorText: state.errorText,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                ),
                isEmpty: text.isEmpty,
                child: Text(
                  obscureText ? '•' * text.length : text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The field alone, with its keyboard: OK on the keyboard or the window keeps what was typed.
  Future<void> _edit(BuildContext context, FormFieldState<String> state) async {
    final typed = await showDialog<String>(context: context, builder: (_) => _FieldWindow(this));
    if (typed == null || !context.mounted) return;
    controller.text = typed;
    state.didChange(typed);
    onChanged?.call(typed);
    // As the keyboard's own key would: on to the next field, or done
    if (textInputAction == TextInputAction.next) {
      FocusScope.of(context).nextFocus();
    } else if (onFieldSubmitted != null) {
      onFieldSubmitted!(typed);
    } else {
      unawaited(SystemSound.play(SystemSoundType.click));
    }
  }
}

/// A password's field off a TV: what is typed, shown or hidden with the eye at its end.
class _SecretField extends StatefulWidget {
  const _SecretField(this.field);

  final RemoteTextFormField field;

  @override
  State<_SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<_SecretField> {
  var _shown = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.field, l = context.l10n;
    return TextFormField(
      controller: f.controller,
      decoration: f.decoration.copyWith(
        suffixIcon:
            f.decoration.suffixIcon ??
            IconButton(
              tooltip: _shown ? l.hidePassword : l.showPassword,
              icon: Icon(_shown ? Icons.visibility_off_rounded : Icons.visibility_rounded),
              onPressed: () => setState(() => _shown = !_shown),
            ),
      ),
      keyboardType: f.keyboardType,
      textInputAction: f.textInputAction,
      textCapitalization: f.textCapitalization,
      autocorrect: false,
      enableSuggestions: false,
      obscureText: !_shown,
      autofillHints: f.autofillHints,
      autofocus: f.autofocus,
      onChanged: f.onChanged,
      onFieldSubmitted: f.onFieldSubmitted,
      validator: f.validator,
    );
  }
}

/// The window with the field alone. It owns what is typed until it is gone: its closing animation
/// still shows the field.
class _FieldWindow extends StatefulWidget {
  const _FieldWindow(this.field);

  final RemoteTextFormField field;

  @override
  State<_FieldWindow> createState() => _FieldWindowState();
}

class _FieldWindowState extends State<_FieldWindow> {
  late final _typing = TextEditingController(text: widget.field.controller.text)
    ..selection = TextSelection.collapsed(offset: widget.field.controller.text.length);
  var _shown = false; // a password, shown to check what was typed

  @override
  void dispose() {
    _typing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, f = widget.field;
    return AlertDialog(
      title: f.decoration.labelText == null ? null : Text(f.decoration.labelText!),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 420),
        child: TextField(
          controller: _typing,
          autofocus: true,
          keyboardType: f.keyboardType,
          textCapitalization: f.textCapitalization,
          autocorrect: f.autocorrect,
          enableSuggestions: f.enableSuggestions,
          obscureText: f.obscureText && !_shown,
          autofillHints: f.autofillHints,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: f.decoration.hintText),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        if (f.obscureText)
          SecondaryButton(
            icon: _shown ? Icons.visibility_off_rounded : Icons.visibility_rounded,
            label: _shown ? l.hidePassword : l.showPassword,
            onPressed: () => setState(() => _shown = !_shown),
          ),
        SecondaryButton(label: l.cancel, onPressed: () => Navigator.pop(context)),
        PrimaryButton(label: l.save, onPressed: () => Navigator.pop(context, _typing.text)),
      ],
    );
  }
}
