import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/source.dart';

/// The app's navigator and messenger, for things that happen outside any screen (a phone acting
/// as a remote, a playlist arriving from the local network).
final appNavigator = GlobalKey<NavigatorState>();

/// What is playing right now, shown on the phone remote. Null when nothing is. The screens that
/// play say so with [sayPlaying] and [sayStopped]; lists refreshed in the background give it the
/// line ([streamPlaying]).
final ValueNotifier<({String title, String? subtitle})?> nowPlaying = ValueNotifier(null)
  ..addListener(() => streamPlaying.value = nowPlaying.value != null);

Object? _saidBy; // the screen behind nowPlaying

/// [screen] plays [what] from now on.
void sayPlaying(Object screen, ({String title, String? subtitle}) what) {
  _saidBy = screen;
  nowPlaying.value = what;
}

/// [screen] plays nothing any more. Unless another has said otherwise since: a screen that replaces
/// a player starts playing before the old one goes, a transition later, maybe with the same title.
void sayStopped(Object screen) {
  if (_saidBy != screen) return;
  _saidBy = null;
  nowPlaying.value = null;
}

/// Text typed on the phone remote with no text field focused on screen, or in the desktop title
/// bar's search: the open playlist shows its Search tab with it.
class RemoteSearch extends ChangeNotifier {
  String text = '';

  /// Typed in the title bar: what is open over Home closes, and the typing stays in the bar.
  bool fromTitleBar = false;

  void send(String t, {bool fromTitleBar = false}) {
    text = t;
    this.fromTitleBar = fromTitleBar;
    notifyListeners();
  }
}

final remoteSearch = RemoteSearch();

/// Remote buttons, by the names the companion page sends.
const remoteKeys = <String, (LogicalKeyboardKey, PhysicalKeyboardKey)>{
  'up': (LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp),
  'down': (LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown),
  'left': (LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft),
  'right': (LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight),
  'ok': (LogicalKeyboardKey.select, PhysicalKeyboardKey.select),
  'playpause': (LogicalKeyboardKey.mediaPlayPause, PhysicalKeyboardKey.mediaPlayPause),
  'chup': (LogicalKeyboardKey.channelUp, PhysicalKeyboardKey.channelUp),
  'chdown': (LogicalKeyboardKey.channelDown, PhysicalKeyboardKey.channelDown),
};

/// Told of what the phone does as a remote (keys, text), which never reaches HardwareKeyboard:
/// someone is there, as with a real remote. The screensaver answers true when that only woke it,
/// and the key goes no further, as a real remote's does.
bool Function()? remoteWakes;

/// Presses a remote button: the key travels from the focused element up through its ancestors,
/// exactly as a key from a real remote does, so every screen reacts the way it already does to
/// one. 'back' goes back like the remote's back button. Returns whether anything handled it.
bool pressRemoteKey(String name) {
  if (remoteWakes?.call() ?? false) return true;
  if (name == 'back') {
    appNavigator.currentState?.maybePop();
    return true;
  }
  final key = remoteKeys[name];
  if (key == null) return false;
  final (logical, physical) = key;
  // The remote is a keyboard of sorts: show the focus ring
  FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  final now = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);
  final handled = _dispatch(KeyDownEvent(physicalKey: physical, logicalKey: logical, timeStamp: now));
  _dispatch(KeyUpEvent(physicalKey: physical, logicalKey: logical, timeStamp: now));
  return handled;
}

bool _dispatch(KeyEvent event) {
  final focused = FocusManager.instance.primaryFocus ?? FocusManager.instance.rootScope;
  for (final node in [focused, ...focused.ancestors]) {
    final result = node.onKeyEvent?.call(node, event) ?? KeyEventResult.ignored;
    if (result == KeyEventResult.handled) return true;
    if (result == KeyEventResult.skipRemainingHandlers) return false;
  }
  return false;
}

/// A field that takes text from the phone while it has the focus without being one to type into:
/// a TV's form field, which only becomes one when OK opens its window (see RemoteTextFormField).
class RemoteTextTarget extends InheritedWidget {
  const RemoteTextTarget({super.key, required this.take, required this.secret, required super.child});

  /// Puts [text] in the field, in place of what it had.
  final ValueChanged<String> take;

  /// A password's: what comes unsealed from the phone does not go in.
  final bool secret;

  @override
  bool updateShouldNotify(RemoteTextTarget old) => false;
}

/// Types [text] into the focused text field, replacing what it had; without one, searches.
bool typeRemoteText(String text, {bool sealed = true}) {
  remoteWakes?.call();
  // A TV's form field with the focus: what was typed is for it, not for a search behind the form
  final target = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<RemoteTextTarget>();
  if (target != null) {
    if (!sealed && target.secret) return false;
    target.take(text);
    return true;
  }
  final field = _focusedField();
  if (field != null) {
    if (!sealed && field.widget.obscureText) return false;
    field.userUpdateTextEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
      SelectionChangedCause.keyboard,
    );
    return true;
  }
  if (text.isEmpty) return true; // sent empty: nothing to search, and no reason to leave the screen
  remoteSearch.send(text);
  return true;
}

EditableTextState? _focusedField() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  if (context is StatefulElement && context.state is EditableTextState) return context.state as EditableTextState;
  return context.findAncestorStateOfType<EditableTextState>();
}
