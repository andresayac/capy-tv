// Profiles and the parental PIN in the real app: a kids profile, a PIN, a locked profile, and
// "Who's watching?". Screenshots go to build/screenshots/profiles-*.png.
//   flutter test integration_test/profiles_flow_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptv_player/data/playlists.dart';
import 'package:iptv_player/data/profiles.dart';
import 'package:iptv_player/data/settings.dart';
import 'package:iptv_player/device.dart';
import 'package:iptv_player/main.dart';
import 'package:iptv_player/ui/profiles_screen.dart';
import 'package:iptv_player/ui/screensaver.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

final shots = Shots('profiles');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  IdleWatcher.enabled = false; // the screensaver would come during long waits

  testWidgets('a kids profile, a PIN and a locked profile', (t) async {
    await shots.init();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    PlaylistStore.instance.reset();
    await ProfileStore.instance.load();
    await detectDevice(); // as main() does: on a TV, as a TV
    await useLandscapeFullScreen();
    final settings = await AppSettings.load();
    await t.pumpWidget(
      RepaintBoundary(
        key: shots.root,
        child: SettingsScope(
          settings: settings,
          child: const IptvApp(locale: Locale('en')),
        ),
      ),
    );
    final store = ProfileStore.instance;
    Future<void> tapText(String text) async {
      expect(await waitFor(t, () => shown(find.text(text).hitTestable())), isTrue, reason: '"$text" should show');
      await t.tap(find.text(text).hitTestable().first);
      await t.pump();
    }

    // Save is at the end of the form, which may run past the screen
    Future<void> save() async {
      final form = find.descendant(of: find.byType(Form), matching: find.byType(Scrollable)).first;
      await t.scrollUntilVisible(find.text('Save'), 200, scrollable: form);
      await tapText('Save');
    }

    // Once the screen with the field is up; a tap first so the field listens again
    Future<void> typeName(String name) async {
      expect(await waitFor(t, () => shown(find.byType(TextFormField).hitTestable())), isTrue);
      await t.tap(find.byType(TextFormField));
      await t.pump();
      await t.enterText(find.byType(TextFormField), name);
      await t.pump();
    }

    Future<void> typePin(String pin) async {
      expect(await waitFor(t, () => shown(find.byIcon(Icons.backspace_outlined))), isTrue, reason: 'the PIN pad');
      for (final d in pin.split('')) {
        await t.tap(find.descendant(of: find.byType(Dialog), matching: find.text(d)));
        await t.pump(const Duration(milliseconds: 100));
      }
      await settle(t, const Duration(milliseconds: 600));
    }

    // One profile: the app looks as it always did, with a way to profiles
    await tapText('Profiles');
    expect(await waitFor(t, () => shown(find.text('Profiles and parental control'))), isTrue);
    await shots.take(t, 'manage');

    // A kids profile
    await tapText('Add profile');
    await typeName('Leo');
    await tapText('Kids');
    await shots.take(t, 'add-kids');
    // A colourful one came with it; another one from the window, which opens on the kids' ones:
    // scrolled up to it first
    await tapText('Change avatar');
    await shots.take(t, 'avatars');
    final pick = find.descendant(of: find.byType(AlertDialog), matching: find.byType(AvatarPicture)).at(16);
    await t.ensureVisible(pick);
    await t.pump();
    await t.tap(pick);
    expect(await waitFor(t, () => !shown(find.byType(AlertDialog))), isTrue, reason: 'picked, the window closes');
    await save();

    // A kids profile and no PIN yet: it asks for one, typed twice
    await typePin('2580');
    await shots.take(t, 'repeat-pin');
    await typePin('2580');
    expect(store.hasPin, isTrue);
    expect(await waitFor(t, () => shown(find.text('Leo'))), isTrue);

    // The main profile gets a name and a PIN of its own
    await tapText('You');
    await typeName('Ana');
    await tapText('Ask for the PIN');
    await typePin('2580');
    await typePin('2580');
    await save();
    expect(await waitFor(t, () => shown(find.text('Ana'))), isTrue);
    await shots.take(t, 'manage-done');
    await t.tap(find.byType(BackButton));

    // Who is watching shows on the welcome screen, and switches
    expect(await waitFor(t, () => shown(find.byIcon(Icons.swap_horiz_rounded))), isTrue);
    await shots.take(t, 'welcome');
    await t.tap(find.byIcon(Icons.swap_horiz_rounded));
    expect(await waitFor(t, () => shown(find.text("Who's watching?"))), isTrue);
    await shots.take(t, 'who');

    // Ana's profile is locked: a wrong PIN, then the right one
    await tapText('Ana');
    await typePin('1111');
    expect(await waitFor(t, () => shown(find.text('Wrong PIN'))), isTrue);
    await shots.take(t, 'wrong-pin');
    await typePin('2580');
    expect(await waitFor(t, () => !shown(find.text("Who's watching?"))), isTrue);
    expect(store.current.name, 'Ana');

    // Leo's is not
    await t.tap(find.byIcon(Icons.swap_horiz_rounded));
    await tapText('Leo');
    expect(await waitFor(t, () => !shown(find.text("Who's watching?"))), isTrue);
    expect((store.current.name, store.current.showsAdult), ('Leo', false));
    await shots.take(t, 'kids-welcome');
  });
}
