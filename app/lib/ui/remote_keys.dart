import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The keys of a TV remote, as the app takes them on a TV (over the app's usual ones).
const tvShortcuts = <ShortcutActivator, Intent>{
  // A remote has no Tab key: up and down leave a text field for the next control instead of trying
  // to move the caret between lines (single-line fields would swallow them)
  SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up, ignoreTextFields: false),
  SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
    TraversalDirection.down,
    ignoreTextFields: false,
  ),
  HeldOk(): DoNothingIntent(),
};

/// OK held down. Android sends it again and again while it is down, and each one would press the
/// focused item once more: a locked profile picked with OK held typed into the PIN pad that came
/// up, so the PIN was always wrong.
class HeldOk extends ShortcutActivator {
  const HeldOk();

  static const _keys = [
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  ];

  @override
  Iterable<LogicalKeyboardKey> get triggers => _keys;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) => event is KeyRepeatEvent && _keys.contains(event.logicalKey);

  @override
  String debugDescribeKeys() => 'OK held down';
}

/// Back with a keyboard on a computer: Esc, or Alt+← as in browsers.
class GoBackIntent extends Intent {
  const GoBackIntent();
}

const desktopShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.escape): GoBackIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): GoBackIntent(),
};

/// Goes back on [navigator] (a dialog first, as Esc always did): not while typing, where the keys
/// are the field's. The player takes Esc first, to leave full screen.
class GoBackAction extends Action<GoBackIntent> {
  GoBackAction(this.navigator);

  final GlobalKey<NavigatorState> navigator;

  @override
  bool isEnabled(GoBackIntent intent) =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() == null;

  @override
  Object? invoke(GoBackIntent intent) => navigator.currentState?.maybePop();
}

/// Up or down with a remote: to the next stop that way, as always; with none (text under the last
/// button, a synopsis, About under Settings' last row) the page scrolls instead, so all of it can
/// be read. A TV has no other way to scroll.
class ScrollWhenStuckAction extends DirectionalFocusAction {
  @override
  void invoke(DirectionalFocusIntent intent) {
    final node = FocusManager.instance.primaryFocus;
    final context = node?.context;
    if (node == null || context == null) return;
    if (intent.ignoreTextFields && context.widget is EditableText) return;
    // Right at a row's end stays there: the nearest stop that way is on another row, diagonally
    if (intent.direction == TraversalDirection.right && _atRowEnd(node, context)) return;
    if (node.focusInDirection(intent.direction)) return;
    final up = intent.direction == TraversalDirection.up;
    if (!up && intent.direction != TraversalDirection.down) return;
    final page = Scrollable.maybeOf(context, axis: Axis.vertical);
    if (page == null) return;
    final p = page.position;
    final to = (p.pixels + (up ? -1 : 1) * p.viewportDimension * 0.4).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (to != p.pixels) p.animateTo(to, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
  }

  /// [node] is the last of a row that scrolls sideways (a rail of posters, of chips), scrolled to
  /// its end: nothing further right in it. Not a page view's (the hero's buttons go on to its
  /// arrows), nor a row still to scroll (more is built as it does).
  static bool _atRowEnd(FocusNode node, BuildContext context) {
    final row = Scrollable.maybeOf(context, axis: Axis.horizontal);
    if (row == null || row.position is PageMetrics) return false;
    final p = row.position;
    if (p.pixels < p.maxScrollExtent - 1) return false;
    final me = node.rect;
    for (final other in node.nearestScope?.traversalDescendants ?? const <FocusNode>[]) {
      final c = other.context;
      if (identical(other, node) || c == null || !c.mounted) continue;
      if (Scrollable.maybeOf(c, axis: Axis.horizontal) != row) continue;
      if (other.rect.left >= me.right - 1) return false; // one further right, in the same row
    }
    return true;
  }
}
