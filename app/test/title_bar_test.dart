// The app's own title bar on Windows: what it shows with and without a playlist, its window
// buttons, Ctrl+K and the search reaching Home's Search tab, full screen hiding it, and how it
// lives with dialogs, the focus, the screens out of the playlist and the screensaver.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/data/catalog.dart';
import 'package:iptv_player/data/epg.dart';
import 'package:iptv_player/data/library.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/desktop_window.dart';
import 'package:iptv_player/l10n/app_localizations.dart';
import 'package:iptv_player/remote/remote_input.dart';
import 'package:iptv_player/ui/account_screen.dart';
import 'package:iptv_player/ui/home_screen.dart';
import 'package:iptv_player/ui/profiles_screen.dart';
import 'package:iptv_player/ui/screensaver.dart';
import 'package:iptv_player/ui/search_tab.dart';
import 'package:iptv_player/ui/theme.dart';
import 'package:iptv_player/ui/title_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_test.dart' show FakeSource;

/// The window the bar drives, with no window: what was asked of it.
class FakeWindow extends DesktopWindow {
  FakeWindow() {
    ownTitleBar = true;
  }

  final calls = <String>[];

  @override
  Future<void> minimize() async => calls.add('minimize');

  @override
  Future<void> toggleMaximized() async {
    calls.add('maximize');
    maximized.value = !maximized.value;
  }

  @override
  Future<void> close() async => calls.add('close');

  @override
  Future<void> startDragging() async => calls.add('drag');

  @override
  Future<void> startResizing(ResizeEdge edge) async => calls.add('resize ${edge.name}');

  @override
  Future<void> setFullScreen(bool on) async => fullScreen.value = on;
}

late AppSettings settings;
late Library library;
late FakeWindow window;

/// The app's frame, as main.dart builds it, around [home].
Widget frame(Widget home) => SettingsScope(
  settings: settings,
  child: MaterialApp(
    theme: buildTheme(),
    locale: const Locale('en'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    navigatorKey: appNavigator,
    navigatorObservers: [titleBarRoutes],
    builder: (_, child) => IdleWatcher(
      navigator: appNavigator,
      child: WindowFrame(
        child: LibraryScope(library: library, child: child!),
      ),
    ),
    home: home,
  ),
);

const playlist = Playlist(id: 'p', name: 'My provider', type: PlaylistType.xtream, url: 'http://x', username: 'u');

/// A playlist open in the bar without Home.
OpenPlaylist opened({
  Playlist playlist = playlist,
  Future<({int movies, int series, int channels})> Function()? refresh,
  ValueListenable<bool>? updating,
  VoidCallback? switchPlaylist,
}) => OpenPlaylist(
  playlist: playlist,
  refresh: refresh ?? () async => (movies: 0, series: 0, channels: 0),
  updating: updating ?? ValueNotifier(false),
  switchPlaylist: switchPlaylist ?? () {},
);

Finder inBar(Finder f) => find.descendant(of: find.byType(TitleBar), matching: f);

final barField = inBar(find.byType(TextField));

String barText(WidgetTester t) => t.widget<TextField>(barField).controller!.text;

/// Until the Search tab shows [results]: the index is built in an isolate, so real time goes by
/// too. Not pumpAndSettle, which a blinking caret never lets end.
Future<void> searched(WidgetTester t, Finder results) async {
  await t.pump(const Duration(milliseconds: 300)); // the search waits for the typing to pause
  for (var i = 0; i < 50 && results.hitTestable().evaluate().isEmpty; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

final movieFound = find.descendant(of: find.byType(SearchTab), matching: find.text('A Film'));

/// The text in the Search tab's own field, seen or not.
String searchTabText(WidgetTester t) => t
    .widget<TextField>(
      find.descendant(
        of: find.byType(SearchTab, skipOffstage: false),
        matching: find.byType(TextField, skipOffstage: false),
        skipOffstage: false,
      ),
    )
    .controller!
    .text;

Future<void> ctrlK(WidgetTester t) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.keyK);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
}

bool barFocused(WidgetTester t) => t
    .widget<TextField>(
      find.descendant(
        of: find.byType(TitleBar, skipOffstage: false),
        matching: find.byType(TextField, skipOffstage: false),
        skipOffstage: false,
      ),
    )
    .focusNode!
    .hasFocus;

/// Something open over Home, as a movie's details.
void push(String text) =>
    unawaited(appNavigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text(text)))));

/// Frames for what the typing set going (routes sliding away); the caret's blinking never settles.
Future<void> typed(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'screensaverMinutes': 0});
    settings = await AppSettings.load();
    library = await Library.load('test', mainProfileId);
    DesktopWindow.instance = window = FakeWindow();
  });

  tearDown(() {
    DesktopWindow.instance = DesktopWindow();
    openPlaylist.value = null;
    remoteSearch
      ..text = ''
      ..fromTitleBar = false;
  });

  testWidgets('outside a playlist: the logo, the app name and the window buttons', (t) async {
    late Size screen;
    await t.pumpWidget(
      frame(
        Builder(
          builder: (context) {
            screen = MediaQuery.sizeOf(context);
            return const Scaffold(body: Text('Welcome'));
          },
        ),
      ),
    );
    expect(inBar(find.text('Capy TV')), findsOneWidget);
    for (final button in ['Minimize', 'Maximize', 'Close']) {
      expect(inBar(find.byTooltip(button)), findsOneWidget, reason: button);
    }
    expect(barField, findsNothing);
    expect(inBar(find.byTooltip('Update channels and movies')), findsNothing);
    // The screen is told the room it has, under the bar
    expect(screen.height, 600 - TitleBar.height);
    expect(t.getTopLeft(find.text('Welcome')).dy, greaterThanOrEqualTo(TitleBar.height));

    await t.tap(find.byTooltip('Minimize'));
    await t.tap(find.byTooltip('Maximize'));
    await t.pump();
    expect(find.byTooltip('Restore'), findsOneWidget, reason: 'maximized, it restores');
    await t.tap(find.byTooltip('Restore'));
    await t.tap(find.byTooltip('Close'));
    expect(window.calls, ['minimize', 'maximize', 'maximize', 'close']);
  });

  testWidgets('the empty bar moves the window, a double click maximizes, the top edge resizes', (t) async {
    await t.pumpWidget(frame(const Scaffold(body: Text('Welcome'))));
    await t.dragFrom(const Offset(400, 20), const Offset(120, 40));
    expect(window.calls, ['drag']);

    window.calls.clear();
    await t.tapAt(const Offset(400, 20));
    await t.pump(kDoubleTapMinTime);
    await t.tapAt(const Offset(400, 20));
    await t.pumpAndSettle();
    expect(window.calls, ['maximize']);

    // Maximized, there is no edge to resize from
    window.calls.clear();
    await t.dragFrom(const Offset(400, 1), const Offset(0, 60));
    expect(window.calls, ['drag']);
    window.maximized.value = false;
    await t.pump();
    window.calls.clear();
    await t.dragFrom(const Offset(400, 1), const Offset(0, 60));
    expect(window.calls, ['resize top']);
    await t.pump(kDoubleTapTimeout);
  });

  testWidgets('in a playlist: its name and kind, update, switch and the search', (t) async {
    await t.pumpWidget(frame(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    expect(inBar(find.text('My provider · Xtream Codes', findRichText: true)), findsOneWidget);
    expect(inBar(find.byTooltip('Update channels and movies')), findsOneWidget);
    expect(inBar(find.byTooltip('Switch playlist')), findsOneWidget);
    expect(inBar(find.text('Search in this playlist…')), findsOneWidget);
    expect(inBar(find.text('Ctrl K')), findsOneWidget);
    expect(inBar(find.text('Capy TV')), findsNothing, reason: 'the playlist takes the name’s place');
    for (final button in ['Minimize', 'Maximize', 'Close']) {
      expect(inBar(find.byTooltip(button)), findsOneWidget, reason: button);
    }
  });

  testWidgets('Ctrl+K goes to the search; what is typed shows in Home’s Search tab', (t) async {
    await t.pumpWidget(frame(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    expect(barFocused(t), isFalse);
    await ctrlK(t);
    expect(barFocused(t), isTrue);

    t.testTextInput.enterText('film');
    await searched(t, movieFound);
    expect(movieFound.hitTestable(), findsWidgets, reason: 'the Search tab shows, with the movie');
    expect(find.text('Movies · 1').hitTestable(), findsOneWidget);
    expect(searchTabText(t), 'film', reason: 'its own field shows what was typed');
    expect(barFocused(t), isTrue, reason: 'the typing stays in the bar');

    // Escape leaves the search for the screen
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(barFocused(t), isFalse);
  });

  testWidgets('Ctrl+K is the bar’s: the focused screen never sees the K', (t) async {
    var keys = 0;
    final screen = FocusNode();
    addTearDown(screen.dispose);
    await t.pumpWidget(
      frame(
        Focus(
          focusNode: screen,
          autofocus: true,
          // As the player, where K pauses
          onKeyEvent: (_, e) {
            if (e.logicalKey == LogicalKeyboardKey.keyK) keys++;
            return KeyEventResult.handled;
          },
          child: const Scaffold(body: Text('Player')),
        ),
      ),
    );
    openPlaylist.value = opened();
    await t.pump();
    await ctrlK(t);
    expect(barFocused(t), isTrue);
    expect(keys, 0);
    // Escape gives the keys back to the screen
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect((barFocused(t), screen.hasFocus), (false, true));
    // Outside a playlist there is no search: Ctrl+K is the screen's
    openPlaylist.value = null;
    await t.pump();
    await ctrlK(t);
    expect(keys, greaterThan(0));
  });

  testWidgets('a click out of the search, or Enter, gives the keys back to the screen', (t) async {
    var spaces = 0;
    final screen = FocusNode();
    addTearDown(screen.dispose);
    await t.pumpWidget(
      frame(
        Focus(
          focusNode: screen,
          autofocus: true,
          // As the player, where Space pauses
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.space) spaces++;
            return KeyEventResult.handled;
          },
          child: const Scaffold(body: Center(child: Text('Player'))),
        ),
      ),
    );
    openPlaylist.value = opened();
    await t.pump();

    // A click on the search, then on the picture
    await t.tap(barField, kind: PointerDeviceKind.mouse);
    await t.pump();
    expect(barFocused(t), isTrue);
    await t.tapAt(const Offset(400, 300), kind: PointerDeviceKind.mouse);
    await t.pump();
    expect((barFocused(t), screen.hasFocus), (false, true));
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    expect(spaces, 1);

    // Enter ends the typing the same way
    await ctrlK(t);
    expect(barFocused(t), isTrue);
    t.testTextInput.enterText('film');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pump();
    expect((barFocused(t), screen.hasFocus), (false, true));
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    expect(spaces, 2);
  });

  testWidgets('a search from the bar closes what is open over Home', (t) async {
    await t.pumpWidget(frame(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    push('Details');
    await t.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    expect(inBar(find.text('My provider · Xtream Codes', findRichText: true)), findsOneWidget, reason: 'still in it');

    await ctrlK(t);
    t.testTextInput.enterText('film');
    await searched(t, movieFound);
    await t.pump(const Duration(milliseconds: 500)); // done sliding away
    expect(find.text('Details'), findsNothing);
    expect(movieFound.hitTestable(), findsWidgets);
    expect(barFocused(t), isTrue);
    t.testTextInput.enterText('film a');
    await t.pump();
    expect(barText(t), 'film a', reason: 'the next keys still go to the bar');
  });

  testWidgets('typed on the phone, a search closes what is open over Home, but never a player', (t) async {
    await t.pumpWidget(frame(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    push('Details');
    await t.pumpAndSettle();
    nowPlaying.value = (title: 'A channel', subtitle: null);
    remoteSearch.send('film');
    await t.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget, reason: 'someone may be watching');

    nowPlaying.value = null;
    remoteSearch.send('film');
    await searched(t, movieFound);
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Details'), findsNothing);
    expect(movieFound.hitTestable(), findsWidgets);
  });

  testWidgets('clearing the bar’s search empties the Search tab and closes nothing', (t) async {
    await t.pumpWidget(frame(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    await ctrlK(t);
    t.testTextInput.enterText('film');
    await searched(t, movieFound);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);

    // A movie found plays over Home, the bar still showing the search: its X closes nothing
    push('Player');
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: barField, matching: find.byType(IconButton)));
    await t.pumpAndSettle();
    expect(find.text('Player'), findsOneWidget);
    expect((barText(t), searchTabText(t)), ('', ''));

    // Nor does typing back to nothing
    await ctrlK(t);
    t.testTextInput.enterText('f');
    await typed(t);
    expect(find.text('Player'), findsNothing, reason: 'something typed still closes it for the results');
    push('Player');
    await typed(t);
    await ctrlK(t);
    t.testTextInput.enterText('');
    await typed(t);
    expect(find.text('Player'), findsOneWidget);
    expect(searchTabText(t), '');
  });

  testWidgets('update shows the progress and what is new; the arrow switches playlist', (t) async {
    await t.pumpWidget(frame(const Scaffold(body: Text('Home'))));
    final lists = Completer<({int movies, int series, int channels})>();
    final updating = ValueNotifier(false);
    var switched = 0;
    openPlaylist.value = opened(
      playlist: const Playlist(id: 'm', name: 'Lab', type: PlaylistType.m3u, url: 'http://x/list.m3u'),
      // As Home's: told while it runs
      refresh: () {
        updating.value = true;
        return lists.future.whenComplete(() => updating.value = false);
      },
      updating: updating,
      switchPlaylist: () => switched++,
    );
    await t.pump();
    expect(inBar(find.text('Lab · M3U', findRichText: true)), findsOneWidget);

    await t.tap(find.byTooltip('Update channels and movies'));
    await t.pump();
    expect(find.text('Updating the list…'), findsOneWidget);
    expect(inBar(find.byType(CircularProgressIndicator)), findsOneWidget);
    // Meanwhile nothing else of the playlist can be pressed
    await t.tap(find.byTooltip('Switch playlist'));
    expect(switched, 0);
    expect(t.widget<TextField>(barField).enabled, isFalse);
    lists.complete((movies: 2, series: 1, channels: 3));
    await t.pumpAndSettle();
    expect(find.text('Updating the list…'), findsNothing);
    expect(find.text('List updated. New: 2 movies, 1 series and 3 channels'), findsOneWidget);
    expect(inBar(find.byType(CircularProgressIndicator)), findsNothing);

    await t.tap(find.byTooltip('Switch playlist'));
    expect(switched, 1);

    // An update Home began by itself: the button turns, the rest stays at hand
    updating.value = true;
    await t.pump();
    expect(inBar(find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(t.widget<TextField>(barField).enabled, isTrue);
    await t.tap(find.byTooltip('Switch playlist'));
    expect(switched, 2);
    updating.value = false;

    openPlaylist.value = null;
    await t.pump();
    expect(inBar(find.text('Capy TV')), findsOneWidget);
  });

  testWidgets('while Settings updates the list the bar is still, and the end closes only its dialog', (t) async {
    await t.pumpWidget(frame(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    push('Settings');
    await t.pumpAndSettle();
    final lists = Completer<({int movies, int series, int channels})>();
    unawaited(refreshList(t.element(find.text('Settings')), () => lists.future));
    await t.pump();
    expect(find.text('Updating the list…'), findsOneWidget);

    // Neither the search, nor Ctrl+K, nor the arrow can close it, or what is under it
    expect(t.widget<TextField>(barField).enabled, isFalse);
    await ctrlK(t);
    expect(barFocused(t), isFalse);
    await t.tap(inBar(find.byTooltip('Switch playlist')));
    await t.pump(const Duration(milliseconds: 500)); // not settled: the dialog's circle turns
    expect(find.text('Updating the list…'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    // Something else closes it meanwhile (a phone casting does): Home stays when the update ends
    appNavigator.currentState!.popUntil((r) => r.isFirst);
    await t.pumpAndSettle();
    lists.complete((movies: 0, series: 0, channels: 0));
    await t.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);

    // Not closed by anything else, it goes away by itself, and only it
    push('Settings');
    await t.pumpAndSettle();
    final again = Completer<({int movies, int series, int channels})>();
    unawaited(refreshList(t.element(find.text('Settings')), () => again.future));
    await t.pump();
    again.complete((movies: 0, series: 0, channels: 0));
    await t.pumpAndSettle();
    expect(find.text('Updating the list…'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
    expect(t.widget<TextField>(barField).enabled, isTrue);
  });

  testWidgets('over the profile picker the bar leaves the playlist out', (t) async {
    await t.pumpWidget(frame(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    unawaited(changeProfile(t.element(find.byType(HomeScreen)), playlist.id));
    await t.pumpAndSettle();
    expect(find.byType(ProfilesScreen), findsOneWidget);
    expect(inBar(find.text('Capy TV')), findsOneWidget);
    expect(barField, findsNothing);
    expect(inBar(find.byTooltip('Update channels and movies')), findsNothing);
    expect(inBar(find.byTooltip('Switch playlist')), findsNothing);
    await ctrlK(t);
    expect(find.byType(ProfilesScreen), findsOneWidget, reason: 'Ctrl+K is not the bar’s there');

    // Back in the playlist, all of it again
    appNavigator.currentState!.pop();
    await t.pumpAndSettle();
    expect(inBar(find.text('My provider · Xtream Codes', findRichText: true)), findsOneWidget);
    expect(barField, findsOneWidget);
  });

  testWidgets('a Search tab built anew, as after an update, starts from the bar’s search', (t) async {
    remoteSearch.send('film', fromTitleBar: true);
    await t.pumpWidget(
      frame(
        Scaffold(
          body: SearchTab(catalog: Catalog(FakeSource()), guide: ValueNotifier(EpgGuide.empty)),
        ),
      ),
    );
    await searched(t, movieFound);
    expect(searchTabText(t), 'film');
    expect(movieFound.hitTestable(), findsWidgets);

    // Another playlist starts with nothing searched
    openPlaylist.value = opened();
    expect(remoteSearch.text, '');
  });

  testWidgets('the mouse on the bar is no idle time, and leaves the screensaver', (t) async {
    await settings.set(screensaverMinutes: 1);
    await t.pumpWidget(frame(const Scaffold(body: Text('Home'))));
    openPlaylist.value = opened();
    await t.pump();
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(300, 20));
    addTearDown(mouse.removePointer);

    // Moving about the bar for two minutes
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(seconds: 30));
      await mouse.moveTo(Offset(300.0 + i * 10, 20));
    }
    await t.pump(const Duration(seconds: 30));
    expect(find.byType(ScreenSaver), findsNothing);

    // Then still: the screensaver, under a bar without the playlist
    await t.pump(const Duration(seconds: 40));
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(ScreenSaver), findsOneWidget);
    expect(inBar(find.text('Capy TV')), findsOneWidget);
    expect(barField, findsNothing);
    // A nudge stays; a click on the bar leaves
    await mouse.moveTo(const Offset(310, 22));
    await t.pump();
    expect(find.byType(ScreenSaver), findsOneWidget);
    await t.tapAt(const Offset(300, 20), kind: PointerDeviceKind.mouse);
    await t.pumpAndSettle();
    expect(find.byType(ScreenSaver), findsNothing);
    expect(barField, findsOneWidget);

    // And so does the mouse moved on purpose over it
    await t.pump(const Duration(seconds: 61));
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(ScreenSaver), findsOneWidget);
    await mouse.moveTo(const Offset(340, 20));
    await mouse.moveTo(const Offset(380, 20));
    await t.pumpAndSettle();
    expect(find.byType(ScreenSaver), findsNothing);
  });

  testWidgets('full screen hides the bar, and leaving it shows it again', (t) async {
    late Size screen;
    await t.pumpWidget(
      frame(
        Builder(
          builder: (context) {
            screen = MediaQuery.sizeOf(context);
            return const Scaffold(body: Text('Player'));
          },
        ),
      ),
    );
    openPlaylist.value = opened();
    await t.pump();
    await DesktopWindow.instance.setFullScreen(true);
    await t.pump();
    expect(find.byType(TitleBar), findsNothing);
    expect(screen.height, 600);
    expect(t.getTopLeft(find.text('Player')).dy, lessThan(TitleBar.height));
    await ctrlK(t);
    expect(barFocused(t), isFalse, reason: 'hidden, it takes no keys');

    await DesktopWindow.instance.setFullScreen(false);
    await t.pump();
    expect(find.byType(TitleBar), findsOneWidget);
    expect(screen.height, 600 - TitleBar.height);
  });

  testWidgets('the player\'s small window hides the bar too, and takes no Ctrl+K', (t) async {
    late Size screen;
    await t.pumpWidget(
      frame(
        Builder(
          builder: (context) {
            screen = MediaQuery.sizeOf(context);
            return const Scaffold(body: Text('Player'));
          },
        ),
      ),
    );
    openPlaylist.value = opened();
    await t.pump();
    DesktopWindow.instance.mini.value = true;
    await t.pump();
    expect(find.byType(TitleBar), findsNothing);
    expect(screen.height, 600);
    await ctrlK(t);
    expect(barFocused(t), isFalse);

    DesktopWindow.instance.mini.value = false;
    await t.pump();
    expect(find.byType(TitleBar), findsOneWidget);
    expect(screen.height, 600 - TitleBar.height);
  });

  testWidgets('without its own title bar (Android, TVs) the frame adds nothing', (t) async {
    DesktopWindow.instance = DesktopWindow();
    await t.pumpWidget(frame(HomeScreen(playlist: playlist, source: FakeSource())));
    await t.pumpAndSettle();
    expect(find.byType(TitleBar), findsNothing);
    expect(t.getTopLeft(find.byType(HomeScreen)).dy, 0);
  });
}
