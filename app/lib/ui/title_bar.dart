import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../data/playlists.dart';
import '../desktop_window.dart';
import '../l10n/app_localizations.dart';
import '../remote/remote_input.dart';
import 'account_screen.dart';
import 'common.dart';
import 'theme.dart';

/// The playlist open in Home, as the title bar shows it, with Home's ways to update its lists
/// and to go back to the playlists.
class OpenPlaylist {
  const OpenPlaylist({
    required this.playlist,
    required this.refresh,
    required this.updating,
    required this.switchPlaylist,
  });

  final Playlist playlist;
  final Future<({int movies, int series, int channels})> Function() refresh;

  /// True while its lists are being updated, whoever asked: the bar, Settings or Home by itself.
  final ValueListenable<bool> updating;
  final VoidCallback switchPlaylist;
}

/// Set by Home while it is open; null outside a playlist (welcome, playlists, profiles).
final openPlaylist = ValueNotifier<OpenPlaylist?>(null);

/// The app navigator's routes as the bar needs them; in MaterialApp's navigatorObservers.
final titleBarRoutes = TitleBarRoutes();

/// The routes on the app's navigator, for the title bar: a dialog only its work closes (the list
/// being updated) stops the bar's playlist controls, and a screen out of the playlist (see
/// [TitleBar.noPlaylist]) leaves the playlist out of the bar.
class TitleBarRoutes extends NavigatorObserver with ChangeNotifier {
  final _routes = <Route<dynamic>>[];

  /// A dialog on top that cannot be dismissed: nothing in the bar may close it, or what is under it.
  bool get blocked => switch (_routes.lastOrNull) {
    final PopupRoute<dynamic> r => !r.barrierDismissible,
    _ => false,
  };

  /// A screen out of the playlist is open over it: the profile picker, the screensaver.
  bool get outside => _routes.any((r) => r.settings == TitleBar.noPlaylist);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) _routes.clear(); // a navigator that starts anew
    _routes.add(route);
    notifyListeners();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    notifyListeners();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (newRoute == null) {
      if (i >= 0) _routes.removeAt(i);
    } else if (i >= 0) {
      _routes[i] = newRoute;
    } else {
      _routes.add(newRoute);
    }
    notifyListeners();
  }
}

/// Every screen on Windows, under the app's own title bar (the native one is hidden, see
/// [DesktopWindow]); in the player's full screen, the screens alone. Elsewhere just [child].
class WindowFrame extends StatelessWidget {
  const WindowFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final window = DesktopWindow.instance;
    if (!window.ownTitleBar) return child;
    // An overlay of its own for the bar's tooltips and text selection, above the screens'
    return Overlay.wrap(
      child: ListenableBuilder(
        // The player's small window too: its picture alone
        listenable: Listenable.merge([window.fullScreen, window.mini]),
        builder: (context, _) {
          final full = window.fullScreen.value || window.mini.value;
          final media = MediaQuery.of(context);
          final bar = full ? 0.0 : TitleBar.height;
          return Stack(
            children: [
              Positioned.fill(
                top: bar,
                // The screens size themselves to what the bar leaves of the window
                child: MediaQuery(
                  data: media.copyWith(size: Size(media.size.width, math.max(0, media.size.height - bar))),
                  child: child,
                ),
              ),
              // Kept while hidden, and with it what was typed
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: TitleBar.height,
                child: Offstage(offstage: full, child: const TitleBar()),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Windows' title bar, drawn by the app in black: the logo; in a playlist its name and kind, a
/// button to update its lists and one to switch playlist, and a search in it (Ctrl+K); then
/// minimize, maximize and close. Dragged by anything empty it moves the window, and a double click
/// there maximizes or restores it.
class TitleBar extends StatefulWidget {
  const TitleBar({super.key});

  static const height = 40.0;

  /// The settings of a route that, open over Home, leaves the playlist out of the bar (the profile
  /// picker, the screensaver): the logo and the app's name, as outside a playlist.
  static const noPlaylist = RouteSettings(name: 'no-playlist');

  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar> {
  final _query = TextEditingController();
  final _field = FocusNode(debugLabel: 'title bar search');
  late OpenPlaylist? _open = openPlaylist.value;
  var _outside = titleBarRoutes.outside; // a screen out of the playlist over it
  var _blocked = titleBarRoutes.blocked; // a dialog only its work closes
  FocusNode? _screen; // the last focus on the screens: leaving the search goes back to it
  var _left = 0; // times the search was left: Escape, Enter, a click away

  @override
  void initState() {
    super.initState();
    openPlaylist.addListener(_playlistChanged);
    titleBarRoutes.addListener(_routesChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
    FocusManager.instance.addListener(_focusMoved);
    _field.addListener(_fieldFocus);
  }

  @override
  void dispose() {
    openPlaylist.removeListener(_playlistChanged);
    titleBarRoutes.removeListener(_routesChanged);
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    FocusManager.instance.removeListener(_focusMoved);
    _field.removeListener(_fieldFocus);
    _query.dispose();
    _field.dispose();
    super.dispose();
  }

  /// The playlist the bar shows: none under a screen out of it.
  OpenPlaylist? get _shown => _outside ? null : _open;

  /// Home and the navigator tell while they build, when the bar cannot change: then after that frame.
  void _later(VoidCallback apply) {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => mounted ? apply() : null);
    } else {
      apply();
    }
  }

  /// Another playlist starts with an empty search, here and in its Search tab (see SearchTab).
  void _playlistChanged() {
    if (remoteSearch.fromTitleBar) remoteSearch.text = '';
    _later(() {
      if (_open == openPlaylist.value) return;
      _query.clear();
      setState(() => _open = openPlaylist.value);
    });
  }

  void _routesChanged() => _later(() {
    if ((_outside, _blocked) == (titleBarRoutes.outside, titleBarRoutes.blocked)) return;
    setState(() {
      _outside = titleBarRoutes.outside;
      _blocked = titleBarRoutes.blocked;
    });
  });

  /// Ctrl+K goes to the search, wherever the focus was, before the focused screen sees the key
  /// (the player's K pauses). Not while the bar is hidden (full screen) or has no search.
  KeyEventResult _onKey(KeyEvent e) {
    final keyboard = HardwareKeyboard.instance;
    if (e is KeyUpEvent || e.logicalKey != LogicalKeyboardKey.keyK) return KeyEventResult.ignored;
    if (!keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isShiftPressed) return KeyEventResult.ignored;
    final window = DesktopWindow.instance;
    if (_open == null ||
        titleBarRoutes.outside ||
        titleBarRoutes.blocked ||
        window.fullScreen.value ||
        window.mini.value) {
      return KeyEventResult.ignored;
    }
    if (e is KeyDownEvent) {
      _field.requestFocus();
      _query.selection = TextSelection(baseOffset: 0, extentOffset: _query.text.length);
    }
    return KeyEventResult.handled;
  }

  void _search(String text) {
    final typing = _field.hasFocus, left = _left;
    remoteSearch.send(text, fromTitleBar: true);
    // Closing what was open over Home hands it the focus: back here for the next keys, unless
    // the search was left meanwhile
    if (typing) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_field.hasFocus && _left == left) _field.requestFocus();
      });
    }
  }

  void _focusMoved() {
    final focused = FocusManager.instance.primaryFocus;
    if (focused != null && _onScreen(focused)) _screen = focused;
  }

  /// Whether [node] is on the screens, under the navigator; the bar is not.
  bool _onScreen(FocusNode node) {
    final screens = appNavigator.currentState?.focusNode;
    return screens != null && node.ancestors.contains(screens);
  }

  /// Escape, or a click out of the search, gives the focus back to where it was on the screen, so
  /// its keys work again.
  void _leave() {
    _left++;
    final back = _screen;
    if (back != null && back.parent != null && back.canRequestFocus && _onScreen(back)) {
      back.requestFocus();
    } else {
      _field.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
    }
  }

  /// The focus that leaves the search for no screen (Enter, the field disabled) goes back too.
  void _fieldFocus() {
    if (_field.hasFocus) return;
    final now = FocusManager.instance.primaryFocus;
    if (now == null || (now is FocusScopeNode && !_onScreen(now))) _leave();
  }

  void _refresh(OpenPlaylist open) {
    final context = appNavigator.currentContext;
    if (context != null) unawaited(refreshList(context, open.refresh));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final window = DesktopWindow.instance;
    final open = _shown;
    return Material(
      color: AppColors.black,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.stroke)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Under everything else: whatever is empty moves the window
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => window.startDragging(),
              onDoubleTap: window.toggleMaximized,
            ),
            Row(
              children: [
                const SizedBox(width: 12),
                const IgnorePointer(child: AppLogo(size: 22)),
                const SizedBox(width: 10),
                Expanded(
                  child: open == null
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: IgnorePointer(
                            child: Text(l.appTitle, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          ),
                        )
                      : Row(
                          children: [
                            Flexible(
                              flex: 2,
                              child: ValueListenableBuilder(
                                valueListenable: open.updating,
                                builder: (_, updating, _) => _PlaylistSelector(
                                  playlist: open.playlist,
                                  updating: updating,
                                  enabled: !_blocked,
                                  onRefresh: () => _refresh(open),
                                  onSwitch: open.switchPlaylist,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              flex: 3,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 440),
                                child: _searchField(l),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                        ),
                ),
                _CaptionButton(icon: Icons.remove_rounded, label: l.windowMinimize, onTap: window.minimize),
                ValueListenableBuilder(
                  valueListenable: window.maximized,
                  builder: (_, maximized, _) => _CaptionButton(
                    icon: maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
                    size: maximized ? 14 : 16,
                    label: maximized ? l.windowRestore : l.windowMaximize,
                    onTap: window.toggleMaximized,
                  ),
                ),
                _CaptionButton(icon: Icons.close_rounded, label: l.close, onTap: window.close, close: true),
              ],
            ),
            // The bar covers the window's top edge: it resizes from here, as the other edges do
            ValueListenableBuilder(
              valueListenable: window.maximized,
              builder: (_, maximized, _) => maximized ? const SizedBox.shrink() : const _TopEdge(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField(AppLocalizations l) => SizedBox(
    height: 30,
    child: CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _leave},
      child: ValueListenableBuilder(
        valueListenable: _query,
        builder: (context, value, _) => TextField(
          controller: _query,
          focusNode: _field,
          enabled: !_blocked,
          onChanged: _search,
          onTapOutside: (_) => _leave(),
          textInputAction: TextInputAction.search,
          textAlignVertical: TextAlignVertical.center,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            hintText: l.titleBarSearch,
            contentPadding: const EdgeInsets.only(right: 8),
            constraints: const BoxConstraints.tightFor(height: 30),
            prefixIcon: const Icon(Icons.search_rounded, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 30),
            suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            suffixIcon: value.text.isEmpty
                ? Padding(padding: const EdgeInsets.only(right: 8), child: _KeyHint(l.titleBarSearchShortcut))
                : IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    tooltip: l.clearSearch,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _query.clear();
                      _search('');
                    },
                  ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
              borderSide: const BorderSide(color: AppColors.text, width: 2), // the ring's width
            ),
          ),
        ),
      ),
    ),
  );
}

/// The open playlist: its name and kind, which switch playlist like the arrow after them, and the
/// button that updates its lists.
class _PlaylistSelector extends StatelessWidget {
  const _PlaylistSelector({
    required this.playlist,
    required this.updating,
    required this.enabled,
    required this.onRefresh,
    required this.onSwitch,
  });

  final Playlist playlist;
  final bool updating; // its lists: the update button turns meanwhile
  final bool enabled; // not under a dialog only its work closes
  final VoidCallback onRefresh, onSwitch;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final kind = switch (playlist.type) {
      PlaylistType.xtream => l.playlistKindXtream,
      PlaylistType.m3u => l.playlistKindM3u,
      PlaylistType.combined => l.playlistKindCombined,
    };
    final color = enabled ? AppColors.text : AppColors.subtle;
    return Container(
      height: 30,
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(AppRadius.button)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: _BarButton(
              tooltip: playlist.name,
              onTap: enabled ? onSwitch : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: playlist.name,
                        style: TextStyle(color: color, fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: ' · $kind',
                        style: const TextStyle(color: AppColors.muted),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
          _BarButton(
            tooltip: l.refreshList,
            onTap: enabled && !updating ? onRefresh : null,
            child: SizedBox(
              width: 30,
              child: updating
                  ? const Center(
                      child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : Icon(Icons.refresh_rounded, size: 18, color: color),
            ),
          ),
          _BarButton(
            tooltip: l.switchPlaylist,
            onTap: enabled ? onSwitch : null,
            child: SizedBox(width: 28, child: Icon(Icons.expand_more_rounded, size: 20, color: color)),
          ),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.tooltip, required this.onTap, required this.child});

  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: const Duration(milliseconds: 500),
    // The ring a keyboard's Tab brings, as on every other button
    child: Focusable(
      onTap: onTap,
      scale: 1,
      radius: AppRadius.button,
      child: SizedBox(height: 30, child: Center(widthFactor: 1, child: child)),
    ),
  );
}

/// "Ctrl K" in the empty search: the way to it from the keyboard.
class _KeyHint extends StatelessWidget {
  const _KeyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.stroke),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      text,
      style: const TextStyle(color: AppColors.subtle, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );
}

/// Minimize, maximize or close, the way Windows' own are: the bar's full height, a grey when the
/// mouse is on them; close in a light grey with a black cross, where Windows has red.
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = 16,
    this.close = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;
  final bool close;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  var _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final lit = _hover || _down;
    final background = switch ((widget.close, _down, _hover)) {
      (true, true, _) => AppColors.text,
      (true, false, true) => AppColors.muted,
      (false, true, _) => AppColors.stroke,
      (false, false, true) => AppColors.surfaceHigh,
      _ => Colors.transparent,
    };
    return Tooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = _down = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTap: () {
            setState(() => _down = false);
            widget.onTap();
          },
          child: Container(
            width: 46,
            height: TitleBar.height,
            color: background,
            child: Icon(widget.icon, size: widget.size, color: widget.close && lit ? AppColors.black : AppColors.text),
          ),
        ),
      ),
    );
  }
}

/// The window's top edge and corners, which the bar covers, for resizing.
class _TopEdge extends StatelessWidget {
  const _TopEdge();

  static const _thickness = 4.0, _corner = 10.0;

  Widget _edge(ResizeEdge edge, MouseCursor cursor) => MouseRegion(
    cursor: cursor,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => DesktopWindow.instance.startResizing(edge),
    ),
  );

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    top: 0,
    height: _thickness,
    child: Row(
      children: [
        SizedBox(width: _corner, child: _edge(ResizeEdge.topLeft, SystemMouseCursors.resizeUpLeftDownRight)),
        Expanded(child: _edge(ResizeEdge.top, SystemMouseCursors.resizeUpDown)),
        SizedBox(width: _corner, child: _edge(ResizeEdge.topRight, SystemMouseCursors.resizeUpRightDownLeft)),
      ],
    ),
  );
}
