import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'platform.dart';

export 'package:window_manager/window_manager.dart' show ResizeEdge;

/// The app's window on a computer. On Windows the native title bar is hidden and the app draws
/// its own (see TitleBar), whose buttons and dragging come here. Tests put a fake in [instance].
class DesktopWindow with WindowListener {
  static DesktopWindow instance = DesktopWindow();

  /// Small enough for the stacked layout of narrow windows, big enough for the title bar.
  static const minimumSize = Size(480, 360);

  /// Whether the app shows its own title bar: on Windows, once [setUp] hid the native one.
  bool ownTitleBar = false;

  final maximized = ValueNotifier(false);

  /// The player's full screen: the title bar is hidden while it lasts.
  final fullScreen = ValueNotifier(false);

  /// Hides Windows' title bar before the first frame, so it never shows. Elsewhere, or if the
  /// window cannot be reached, the native one stays.
  Future<void> setUp() async {
    if (!isWindows) return;
    try {
      await windowManager.ensureInitialized();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setMinimumSize(minimumSize);
      maximized.value = await windowManager.isMaximized();
      windowManager.addListener(this);
      ownTitleBar = true;
    } on MissingPluginException {
      // a test host without the plugin
    } on PlatformException {
      // the native bar stays
    }
  }

  Future<void> minimize() => windowManager.minimize();

  Future<void> toggleMaximized() async =>
      await windowManager.isMaximized() ? windowManager.unmaximize() : windowManager.maximize();

  /// Closes the window, once [confirmClose] agrees while [guardClose] holds it.
  Future<void> close() => windowManager.close();

  /// Asked before the window closes while [guardClose] holds it (its own button, Alt+F4, the
  /// taskbar): true to close all the same. Set by the app.
  Future<bool> Function()? confirmClose;

  var _guarded = false;

  /// While [on] (something records or is about to), closing the window asks first. Off, the window
  /// closes as ever: one whose app hangs still closes.
  Future<void> guardClose(bool on) async {
    if (!ownTitleBar || on == _guarded) return;
    _guarded = on;
    try {
      await windowManager.setPreventClose(on);
    } on Object catch (e) {
      debugPrint('window: guard close: $e');
    }
  }

  @override
  void onWindowClose() => unawaited(_closing());

  Future<void> _closing() async {
    if (!_guarded) return; // not held: it closes by itself
    if (!(await confirmClose?.call() ?? true)) return;
    await guardClose(false);
    await windowManager.destroy();
  }

  Future<void> startDragging() => windowManager.startDragging();

  Future<void> startResizing(ResizeEdge edge) => windowManager.startResizing(edge);

  /// The player's full screen. media_kit's own does not know the native title bar is hidden and
  /// would leave a frame around the picture, so then window_manager does it.
  Future<void> setFullScreen(bool on) async {
    if (ownTitleBar) {
      await windowManager.setFullScreen(on);
    } else {
      on ? await defaultEnterNativeFullscreen() : await defaultExitNativeFullscreen();
    }
    fullScreen.value = on;
  }

  /// The player's small window (picture in picture, see Pip): the window itself made small, in a
  /// corner of its screen, over the other programs, the title bar hidden.
  final mini = ValueNotifier(false);

  /// How the window was before it went small, to go back to.
  ({Rect bounds, bool maximized, bool fullScreen})? _beforeMini;

  /// Makes the window small for the player, shaped like its picture ([ratio], width to height) in
  /// the lower right corner of the screen it is on, and over the other programs. False when it
  /// cannot (no own title bar: not on Windows).
  Future<bool> enterMini(double ratio) async {
    if (!ownTitleBar) return false;
    if (mini.value) return true;
    try {
      // Out of a full screen and of maximized first: the size it comes back to is the window's own
      final full = fullScreen.value;
      if (full) await windowManager.setFullScreen(false);
      final wasMaximized = await windowManager.isMaximized();
      if (wasMaximized) await windowManager.unmaximize();
      final normal = await windowManager.getBounds();
      _beforeMini = (bounds: normal, maximized: wasMaximized, fullScreen: full);
      mini.value = true;
      final displays = await screenRetriever.getAllDisplays();
      final areas = [for (final d in displays) (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size)];
      final area =
          areas.where((a) => a.contains(normal.center)).firstOrNull ??
          areas.firstOrNull ??
          const Rect.fromLTWH(0, 0, 1280, 720);
      final size = miniSize(area.size, ratio);
      await windowManager.setMinimumSize(miniMinimum);
      await windowManager.setBounds(
        Rect.fromLTWH(area.right - size.width - 24, area.bottom - size.height - 24, size.width, size.height),
      );
      await windowManager.setAspectRatio(ratio);
      await windowManager.setAlwaysOnTop(true);
      return true;
    } on Object catch (e) {
      debugPrint('window: mini: $e');
      await leaveMini();
      return false;
    }
  }

  /// The picture's shape changed while small (another channel): the window takes it, as wide.
  Future<void> fitMini(double ratio) async {
    if (!mini.value) return;
    try {
      final b = await windowManager.getBounds();
      if ((b.width / b.height - ratio).abs() < 0.02) return;
      await windowManager.setAspectRatio(ratio);
      await windowManager.setBounds(Rect.fromLTWH(b.left, b.bottom - b.width / ratio, b.width, b.width / ratio));
    } on Object catch (e) {
      debugPrint('window: mini: $e');
    }
  }

  /// The window as it was before it went small: its size and place, maximized, in full screen.
  Future<void> leaveMini() async {
    final before = _beforeMini;
    if (!mini.value) return;
    _beforeMini = null;
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setAspectRatio(0);
      await windowManager.setMinimumSize(minimumSize);
      if (before != null) {
        await windowManager.setBounds(before.bounds);
        if (before.maximized) await windowManager.maximize();
        if (before.fullScreen) await windowManager.setFullScreen(true);
      }
    } on Object catch (e) {
      debugPrint('window: mini: $e');
    }
    mini.value = false;
  }

  /// The smallest the small window may be made.
  static const miniMinimum = Size(240, 135);

  /// The small window's size on a screen whose free area is [screen]: a quarter of its width, at
  /// least 320 and at most 520, shaped as [ratio]; a tall picture no taller than 45 % of it.
  @visibleForTesting
  static Size miniSize(Size screen, double ratio) {
    var width = (screen.width * 0.25).clamp(320.0, 520.0);
    var height = width / ratio;
    if (height > screen.height * 0.45) {
      height = screen.height * 0.45;
      width = height * ratio;
    }
    return Size(width, height);
  }

  /// Asked of the window each time its size changes: out of a full screen entered maximized,
  /// window_manager reports leaving full screen where it means unmaximized.
  @override
  void onWindowEvent(String eventName) {
    const sizes = {'maximize', 'unmaximize', 'restore', 'resized', 'enter-full-screen', 'leave-full-screen'};
    if (sizes.contains(eventName)) windowManager.isMaximized().then((m) => maximized.value = m);
    // Where it was and how big, kept a moment after it stops moving: "moved" and "resized" come at
    // the end of a drag, "move" and "resize" as it goes and when something else moves it (Windows'
    // own snapping, a keyboard shortcut)
    if (sizes.contains(eventName) || const {'moved', 'move', 'resize'}.contains(eventName)) {
      _saving?.cancel();
      _saving = Timer(const Duration(milliseconds: 600), () => unawaited(_save()));
    }
  }

  Timer? _saving;
  static const _boundsKey = 'window.bounds', _maximizedKey = 'window.maximized';

  /// The size, place and maximizing it was left with, as the app starts again: unless that is no
  /// longer on a screen (one since unplugged), where the window opens centred as at first. After
  /// the app's preferences store is set up (see main), before the first frame.
  Future<void> restore() async {
    if (!ownTitleBar) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = (prefs.getString(_boundsKey) ?? '').split(',').map(double.tryParse).toList();
      if (p.length == 4 && !p.contains(null)) {
        final bounds = Rect.fromLTWH(p[0]!, p[1]!, p[2]!, p[3]!);
        final screens = [
          for (final d in await screenRetriever.getAllDisplays())
            (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size),
        ];
        if (fitsOnAScreen(bounds, screens)) await windowManager.setBounds(bounds);
      }
      if (prefs.getBool(_maximizedKey) ?? false) await windowManager.maximize();
    } on Object catch (e) {
      debugPrint('window: restore: $e'); // where Windows puts it, then
    }
  }

  Future<void> _save() async {
    if (fullScreen.value || mini.value) return; // the player's: not the window's own size
    try {
      final prefs = await SharedPreferences.getInstance();
      final isMaximized = await windowManager.isMaximized();
      await prefs.setBool(_maximizedKey, isMaximized);
      // Maximized, what it goes back to is kept from before
      if (isMaximized) return;
      final b = await windowManager.getBounds();
      await prefs.setString(_boundsKey, [b.left, b.top, b.width, b.height].join(','));
    } on Object catch (e) {
      debugPrint('window: save: $e');
    }
  }

  /// Whether a window at [bounds] is usable on one of [screens]: no smaller than it may be, and its
  /// title bar on a screen, where it can be dragged from.
  @visibleForTesting
  static bool fitsOnAScreen(Rect bounds, List<Rect> screens) =>
      bounds.width >= minimumSize.width &&
      bounds.height >= minimumSize.height &&
      screens.any((s) => s.contains(bounds.topCenter + const Offset(0, 16)));
}
