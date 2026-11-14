import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/library.dart';
import '../data/playlists.dart';
import '../data/profiles.dart';
import '../data/settings.dart';
import '../l10n/app_localizations.dart';
import '../sync/sync_service.dart';
import 'backdrop.dart';
import 'common.dart';
import 'remote_text_field.dart';
import 'sync_screen.dart';
import 'theme.dart';
import 'title_bar.dart';

/// Shows "Who's watching?" instead of [child] until a profile is picked, when there are several.
class ProfileGate extends StatelessWidget {
  const ProfileGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ProfileStore.instance,
    builder: (context, _) => ProfileStore.instance.choosing ? const ProfilesScreen() : child,
  );
}

/// Leaves whatever is open and goes back to "Who's watching?".
void switchProfile(BuildContext context) {
  Navigator.of(context).popUntil((r) => r.isFirst);
  ProfileStore.instance.switchProfile();
}

/// The playlist to open again once a profile is picked from inside it (see [changeProfile]); the
/// playlists screen does it.
final reopenAfterProfile = ValueNotifier<String?>(null);

/// "Who's watching?" from inside the playlist [playlistId]: the profile picked takes over right
/// there, the playlist opening again with its favorites, history and adult setting. The same
/// profile, or going back, leaves everything as it was. The desktop title bar leaves the playlist out
/// meanwhile.
Future<void> changeProfile(BuildContext context, String playlistId) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    settings: TitleBar.noPlaylist,
    builder: (_) => ProfilesScreen(reopen: playlistId),
  ),
);

/// Profiles and parental control, behind the PIN when there is one.
Future<void> openProfileSettings(BuildContext context) async {
  if (!await confirmPin(context) || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ManageProfilesScreen()));
}

extension ProfileName on Profile {
  String displayName(AppLocalizations l) => name.isEmpty ? l.profileYou : name;
}

/// The avatars the app comes with (drawn with DiceBear, see docs/credits.md), in the order they are
/// offered: black and white drawings of people, then [kidsAvatars]. A profile keeps the name (and
/// syncs it), so names never change; new ones go at the end of their style. The TV app has the same
/// list in tizen/src/avatars.json.
final avatars = [
  for (final n in [1, 2, 5, 8, 10, 11, 18, 19, 22, 35, 38, 47, 9, 21, 28, 33, 39, 52, 55, 59, 60, 63, 76, 100])
    'notionists-$n',
  for (final n in [2, 5, 6, 9, 15, 17, 20, 23, 26, 33, 40, 48, 3, 7, 29, 30, 37, 50, 63, 76, 85, 95, 100, 119])
    'lorelei-$n',
  for (final n in [1, 7, 12, 15, 25, 30, 33, 36, 38, 64, 67, 95]) 'open-peeps-$n',
  for (final n in [13, 14, 19, 21, 30, 35, 41, 49, 59, 68, 72, 119]) 'croodles-$n',
  ...kidsAvatars,
];

/// The colourful ones, for kids: monsters, robots and emoji.
final kidsAvatars = [
  for (final n in [6, 10, 12, 16, 21, 24, 35, 37, 46, 47, 48, 55]) 'critters-$n',
  for (final n in [2, 4, 5, 10, 18, 22, 29, 31, 35, 36, 44, 47]) 'voxel-bot-$n',
  for (final n in [4, 6, 21, 24, 28, 40, 51, 80, 88, 106, 118, 146]) 'fun-emoji-$n',
];

/// For a new profile: the first avatar of its kind (colourful for kids, drawings for others) nobody
/// has yet.
String defaultAvatar({required bool kids}) {
  final taken = {for (final p in ProfileStore.instance.profiles) ?p.avatar};
  final kind = kids ? kidsAvatars : avatars.where((a) => !kidsAvatars.contains(a));
  return kind.firstWhere((a) => !taken.contains(a), orElse: () => kind.first);
}

/// One of the app's avatars, round.
class AvatarPicture extends StatelessWidget {
  const AvatarPicture(this.name, {super.key, this.size = 40});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => ClipOval(
    child: SvgPicture.asset('assets/avatars/$name.svg', width: size, height: size, fit: BoxFit.cover),
  );
}

/// A profile's round badge: its avatar, else its initial, white on grey.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.profile, this.size = 40});

  final Profile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    // One this app does not have (chosen with a newer one, on another device): the initial
    if (profile.avatar case final a? when avatars.contains(a)) return AvatarPicture(a, size: size);
    final name = profile.displayName(context.l10n);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: AppColors.surfaceHigh, shape: BoxShape.circle),
      child: profile.kids
          ? Icon(Icons.child_care_rounded, size: size * 0.5, color: AppColors.text)
          : Text(
              name.characters.first.toUpperCase(),
              style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: AppColors.text),
            ),
    );
  }
}

/// "Who's watching?": one tile per profile, locked ones behind the PIN. Before a playlist opens
/// (see [ProfileGate]), or from inside the playlist [reopen] (see [changeProfile]).
class ProfilesScreen extends StatelessWidget {
  const ProfilesScreen({super.key, this.reopen});

  final String? reopen;

  Future<void> _choose(BuildContext context, Profile tapped) async {
    final store = ProfileStore.instance;
    final p = store.profiles.where((x) => x.id == tapped.id).firstOrNull;
    if (p == null) return; // deleted while this was on screen
    if (reopen != null && p.id == store.current.id) return Navigator.pop(context); // already theirs
    // Leaving a kids profile, or going to one with adult content, is for whoever has the PIN
    final guarded = p.locked || p.showsAdult || (store.current.kids && !p.kids);
    if (guarded && !await confirmProfilePin(context, p)) return;
    if (!context.mounted) return;
    if (reopen != null) {
      reopenAfterProfile.value = reopen;
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
    await store.select(p.id);
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: ProfileStore.instance, builder: (context, _) => _who(context));

  Widget _who(BuildContext context) {
    final l = context.l10n;
    final store = ProfileStore.instance;
    final big = MediaQuery.sizeOf(context).shortestSide >= 600;
    final size = big ? 120.0 : 84.0;
    return PosterBackdrop(
      child: Scaffold(
        // From inside a playlist there is a way back to it
        appBar: reopen == null ? null : AppBar(backgroundColor: Colors.transparent),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The screen's name to a screen reader, as an app bar's title is
                  Semantics(
                    header: true,
                    namesRoute: true,
                    child: Text(l.whoIsWatching, style: Theme.of(context).textTheme.headlineMedium),
                  ),
                  SizedBox(height: big ? 40 : 24),
                  Wrap(
                    spacing: big ? 28 : 16,
                    runSpacing: 16,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final (i, p) in store.profiles.indexed)
                        Focusable(
                          autofocus:
                              p.id == store.current.id ||
                              (i == 0 && store.profiles.every((x) => x.id != store.current.id)),
                          radius: 16,
                          onTap: () => _choose(context, p),
                          child: SizedBox(
                            width: size + 24,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Column(
                                children: [
                                  ProfileAvatar(profile: p, size: size),
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          p.displayName(l),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                                        ),
                                      ),
                                      if (p.locked) ...[
                                        const SizedBox(width: 4),
                                        const Icon(Icons.lock_rounded, size: 14, color: AppColors.muted),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: big ? 40 : 24),
                  if (!adultActionsHidden)
                    SecondaryButton(
                      icon: Icons.manage_accounts_outlined,
                      label: l.profilesTitle,
                      onPressed: () => openProfileSettings(context),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Profiles and parental control: the list of profiles and the PIN.
class ManageProfilesScreen extends StatelessWidget {
  const ManageProfilesScreen({super.key});

  /// One with a PIN of its own only for whoever knows it: from there its lock could be taken off.
  /// Forgetting it is not offered with a list open in that profile, whose next save would undo it.
  Future<void> _edit(BuildContext context, [Profile? p]) async {
    if (p != null &&
        p.hasOwnPin &&
        !await confirmProfilePin(context, p, forgot: currentLibrary.value?.profileId != p.id)) {
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditProfileScreen(profile: p)));
  }

  Future<void> _setPin(BuildContext context) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final pin = await askNewPin(context);
    if (pin == null) return;
    await ProfileStore.instance.setPin(pin);
    messenger.showSnackBar(SnackBar(content: Text(l.pinSaved)));
  }

  Future<void> _removePin(BuildContext context) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    await ProfileStore.instance.setPin(null);
    messenger.showSnackBar(SnackBar(content: Text(l.pinRemoved)));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final text = Theme.of(context).textTheme;
    return PosterBackdrop(
      child: Scaffold(
        appBar: AppBar(title: Text(l.profilesTitle)),
        body: ListenableBuilder(
          listenable: ProfileStore.instance,
          builder: (context, _) {
            final store = ProfileStore.instance;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                  children: [
                    Text(l.profilesBody, style: const TextStyle(color: AppColors.muted, height: 1.5)),
                    const SizedBox(height: 16),
                    for (final (i, p) in store.profiles.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Focusable(
                          autofocus: i == 0,
                          radius: 16,
                          scale: 1.01,
                          onTap: () => _edit(context, p),
                          child: Panel(
                            radius: 16,
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            child: Row(
                              children: [
                                ProfileAvatar(profile: p, size: 44),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p.displayName(l),
                                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                                      ),
                                      if (p.kids || p.locked || p.showsAdult)
                                        Text(
                                          [
                                            if (p.kids) l.kidsProfile,
                                            if (p.locked) l.profileLocked,
                                            if (p.showsAdult) l.adultTag,
                                          ].join(' · '),
                                          style: const TextStyle(color: AppColors.muted, fontSize: 13),
                                        ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SecondaryButton(
                        icon: Icons.person_add_alt_rounded,
                        label: l.addProfile,
                        onPressed: () => _edit(context),
                      ),
                    ),
                    if (store.profiles.length > 1) ...[
                      const SizedBox(height: 32),
                      Text(l.deviceProfileTitle, style: text.titleLarge),
                      const SizedBox(height: 6),
                      Text(l.deviceProfileBody, style: const TextStyle(color: AppColors.muted, height: 1.5)),
                      const SizedBox(height: 8),
                      ChoiceRow<String?>(
                        label: l.deviceProfileTitle,
                        value: store.deviceProfile,
                        options: [null, for (final p in store.profiles) p.id],
                        text: (id) => id == null
                            ? l.deviceProfileAsk
                            : store.profiles.firstWhere((p) => p.id == id).displayName(l),
                        // A child must not be able to undo it, and a profile's own PIN must not be skipped
                        onChanged: (id) async {
                          if (!await confirmPin(context) || !context.mounted) return;
                          final p = store.profiles.where((p) => p.id == id).firstOrNull;
                          if (p != null &&
                              p.hasOwnPin &&
                              !await confirmProfilePin(context, p, forgot: currentLibrary.value?.profileId != p.id)) {
                            return;
                          }
                          await store.setDeviceProfile(id);
                        },
                      ),
                    ],
                    const SizedBox(height: 32),
                    Text(l.parentalPin, style: text.titleLarge),
                    const SizedBox(height: 6),
                    Text(l.parentalPinBody, style: const TextStyle(color: AppColors.muted, height: 1.5)),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SecondaryButton(
                          icon: Icons.pin_outlined,
                          label: store.hasPin ? l.changePin : l.setPin,
                          onPressed: () => _setPin(context),
                        ),
                        if (store.hasPin)
                          SecondaryButton(
                            icon: Icons.lock_open_rounded,
                            label: l.removePin,
                            onPressed: () => _removePin(context),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A new profile, or changes to [profile].
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, this.profile});

  final Profile? profile;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.profile?.name);
  final _nameField = GlobalKey();
  late var _kids = widget.profile?.kids ?? false;
  late var _locked = widget.profile?.locked ?? false;
  String? _newPin; // saved with the profile
  late var _adult = widget.profile?.adult ?? false;
  late var _audio = widget.profile?.audioLanguage;
  late var _subtitles = widget.profile?.subtitleLanguage;
  late var _minutes = widget.profile?.dailyMinutes;
  // A new profile starts with an avatar of its kind, until one is picked
  late String? _avatar = widget.profile == null ? defaultAvatar(kids: false) : widget.profile!.avatar;
  late var _avatarPicked = widget.profile != null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Locking asks for a PIN of its own; off, it goes.
  Future<void> _lock(bool on) async {
    final pin = on ? await askNewPin(context) : null;
    if (on && pin == null) return;
    setState(() {
      _newPin = pin;
      _locked = on;
    });
  }

  /// Saving: a second press would make the profile twice, and close one screen too many.
  var _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _saveNow();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveNow() async {
    if (!_form.currentState!.validate()) {
      // What is missing is the name, at the top: brought into view, or Save would seem to do nothing
      if (_nameField.currentContext case final field?) {
        await Scrollable.ensureVisible(field, duration: const Duration(milliseconds: 250));
      }
      return;
    }
    final store = ProfileStore.instance;
    // With no PIN at all, anyone could walk into it: see _choose
    if (_adult && !_kids && !store.hasPin) {
      final pin = await askNewPin(context, title: context.l10n.adultPinTitle);
      if (pin == null || !mounted) return;
      await store.setPin(pin);
    }
    // A kids profile with no parental PIN is one a child turns off from another profile: it takes
    // one first, and with none nothing is saved
    if (_kids && !store.hasPin && mounted) {
      final pin = await askNewPin(context, title: context.l10n.kidsPinTitle);
      if (pin == null || !mounted) return;
      await store.setPin(pin);
    }
    final p = widget.profile;
    final String id;
    if (p == null) {
      final added = await store.add(_name.text, kids: _kids, avatar: _avatar);
      id = added.id;
      await store.update(
        added.copyWith(
          locked: _locked,
          adult: _adult && !_kids,
          audioLanguage: _audio,
          subtitleLanguage: _subtitles,
          dailyMinutes: _kids ? _minutes : null,
        ),
      );
    } else {
      id = p.id;
      await store.update(
        p.copyWith(
          name: _name.text.trim(),
          kids: _kids,
          locked: _locked,
          adult: _adult && !_kids,
          avatar: _avatar,
          noAvatar: _avatar == null,
          audioLanguage: _audio,
          subtitleLanguage: _subtitles,
          dailyMinutes: _kids ? _minutes : null,
        ),
      );
    }
    // After the rest: what was just saved comes from before the PIN
    if (_newPin != null) {
      await store.setProfilePin(id, _newPin);
    } else if (!_locked && p?.hasOwnPin == true) {
      await store.setProfilePin(id, null);
    }
    final open = currentLibrary.value;
    final changed = p != null && (p.showsAdult != (_adult && !_kids) || p.kids != _kids);
    if (mounted && changed && open != null && id == store.current.id) {
      // What is open was listed for the profile as it was
      reopenAfterProfile.value = open.playlistId;
      Navigator.of(context).popUntil((r) => r.isFirst);
      await store.select(id);
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  /// The avatars in a window that scrolls, the current one in view and in focus; the initial counts
  /// as one.
  Future<void> _pickAvatar() async {
    final initial = (widget.profile ?? const Profile(id: '', name: '')).copyWith(
      name: _name.text,
      kids: _kids,
      noAvatar: true,
    );
    final picked = await showDialog<({String? avatar})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.avatar),
        content: SingleChildScrollView(
          child: _AvatarGrid(selected: _avatar, initial: initial, onPicked: (a) => Navigator.pop(ctx, (avatar: a))),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _avatar = picked.avatar;
      _avatarPicked = true;
    });
  }

  Future<void> _delete() async {
    final l = context.l10n;
    final p = widget.profile!;
    final sure = await showConfirm(context, message: l.deleteProfileQuestion(p.displayName(l)), confirmLabel: l.delete);
    if (!sure || !mounted) return;
    // Its playlist would write its library back
    final open = currentLibrary.value?.profileId == p.id;
    if (open) Navigator.of(context).popUntil((r) => r.isFirst);
    await ProfileStore.instance.remove(p.id);
    if (mounted && !open) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final p = widget.profile;
    return PosterBackdrop(
      child: Scaffold(
        appBar: AppBar(title: Text(p == null ? l.addProfile : l.editProfile)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Form(
              key: _form,
              // Not a ListView: one would drop the name field once scrolled past, and an empty name
              // go unchecked
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    RemoteTextFormField(
                      key: _nameField,
                      controller: _name,
                      // A new profile starts on its name (with a remote its keyboard opens: the name comes
                      // first); an existing one on Change avatar, at the top where it is seen: Save is
                      // below the screen, and an OK there would leave before anything was seen
                      autofocus: p == null,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setState(() {}), // the initial among the avatars follows the name
                      decoration: InputDecoration(
                        labelText: l.profileName,
                        hintText: p?.isMain == true ? l.profileYou : null,
                      ),
                      // The main profile may stay unnamed
                      validator: (v) => (v ?? '').trim().isEmpty && p?.isMain != true ? l.required : null,
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        ProfileAvatar(
                          profile: (p ?? const Profile(id: '', name: '')).copyWith(
                            name: _name.text,
                            kids: _kids,
                            avatar: _avatar,
                            noAvatar: _avatar == null,
                          ),
                          size: 56,
                        ),
                        const SizedBox(width: 16),
                        SecondaryButton(
                          icon: Icons.face_rounded,
                          label: l.changeAvatar,
                          onPressed: _pickAvatar,
                          autofocus: p != null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _Toggle(
                      label: l.kidsProfile,
                      hint: _kids && !ProfileStore.instance.hasPin ? l.kidsProfileNoPinHint : l.kidsProfileHint,
                      value: _kids,
                      onChanged: (v) => setState(() {
                        _kids = v;
                        // The avatar it was given follows: a colourful one for a kids profile
                        if (!_avatarPicked) _avatar = defaultAvatar(kids: v);
                      }),
                    ),
                    _Toggle(label: l.lockProfile, hint: l.lockProfileHint, value: _locked, onChanged: _lock),
                    if (_locked)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 2, 0, 8),
                          child: SecondaryButton(
                            icon: Icons.pin_outlined,
                            label: _newPin != null || p?.hasOwnPin == true ? l.changePin : l.setPin,
                            onPressed: () => _lock(true),
                          ),
                        ),
                      ),
                    if (!_kids)
                      _Toggle(
                        label: l.showAdult,
                        hint: l.showAdultHint,
                        value: _adult,
                        onChanged: (v) => setState(() => _adult = v),
                      ),
                    if (_kids)
                      ChoiceRow<int?>(
                        label: l.dailyLimit,
                        hint: l.dailyLimitHint,
                        value: _minutes,
                        options: const [null, 30, 60, 90, 120, 180],
                        text: (m) => switch (m) {
                          null => l.noLimit,
                          final m when m % 60 == 0 => l.hoursOnly(m ~/ 60),
                          final m when m > 60 => l.hoursMinutes(m ~/ 60, m % 60),
                          final m => l.minutes(m),
                        },
                        onChanged: (m) => setState(() => _minutes = m),
                      ),
                    ChoiceRow<String?>(
                      label: l.profileAudio,
                      value: _audio,
                      options: const [null, ...preferenceLanguages],
                      text: (c) => c == null ? l.asInSettings : l.languageName(c),
                      onChanged: (c) => setState(() => _audio = c),
                    ),
                    ChoiceRow<String?>(
                      label: l.profileSubtitles,
                      value: _subtitles,
                      options: const [null, 'off', ...preferenceLanguages],
                      text: (c) => switch (c) {
                        null => l.asInSettings,
                        'off' => l.off,
                        final c => l.languageName(c),
                      },
                      onChanged: (c) => setState(() => _subtitles = c),
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        PrimaryButton(icon: Icons.check_rounded, label: l.save, onPressed: _saving ? null : _save),
                        if (p != null && !p.isMain)
                          SecondaryButton(
                            icon: Icons.delete_outline_rounded,
                            label: l.deleteProfile,
                            onPressed: _delete,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The avatars to pick from, and the profile's initial for none, in rows of seven; the colourful
/// ones for kids under their own title. The one picked is ringed, and brought into view: with so
/// many it can be far down.
class _AvatarGrid extends StatefulWidget {
  const _AvatarGrid({required this.selected, required this.initial, required this.onPicked});

  final String? selected;
  final Profile initial; // the profile as it would look without an avatar
  final ValueChanged<String?> onPicked;

  @override
  State<_AvatarGrid> createState() => _AvatarGridState();
}

class _AvatarGridState extends State<_AvatarGrid> {
  final _picked = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final picked = _picked.currentContext;
      if (picked != null) Scrollable.ensureVisible(picked, alignment: 0.5);
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final size = isShort(context) ? 52.0 : 60.0;
    const spacing = 6.0, columns = 7;
    // An avatar and, on each side, its ring and gap (3 + 3) and the focus ring's gap (3)
    final cell = size + 18;
    Widget choice(String? a, Widget picture) => Semantics(
      key: a == selected ? _picked : null,
      selected: a == selected,
      label: a ?? context.l10n.avatarInitial,
      child: Focusable(
        autofocus: a == selected,
        radius: AppRadius.pill,
        onTap: () => widget.onPicked(a),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // The initial is grey on the window's grey: an outline shows where it is
            border: Border.all(
              color: a == selected ? AppColors.text : (a == null ? AppColors.subtle : Colors.transparent),
              width: 3, // the same for all, so picking one moves nothing
            ),
          ),
          child: picture,
        ),
      ),
    );
    Widget grid(List<Widget> children) => Wrap(spacing: spacing, runSpacing: spacing, children: children);
    // As wide as the rows, so they fill the window; a narrower one wraps them sooner
    return SizedBox(
      width: columns * cell + (columns - 1) * spacing,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          grid([
            choice(null, ProfileAvatar(profile: widget.initial, size: size)),
            for (final a in avatars)
              if (!kidsAvatars.contains(a)) choice(a, AvatarPicture(a, size: size)),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
            child: Text(
              context.l10n.kidsProfile,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: AppColors.muted),
            ),
          ),
          grid([for (final a in kidsAvatars) choice(a, AvatarPicture(a, size: size))]),
        ],
      ),
    );
  }
}

/// A whole row that switches a setting on and off, the same with a remote, a mouse or a finger.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.hint, required this.value, required this.onChanged});

  final String label, hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    // Its name, its hint and whether it is on, said together, rather than the switch on its own
    child: MergeSemantics(
      child: Focusable(
        radius: 12,
        scale: 1.01,
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(hint, style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ExcludeFocus(
                child: Switch(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: AppColors.black,
                  activeTrackColor: AppColors.text,
                  inactiveThumbColor: AppColors.muted,
                  inactiveTrackColor: AppColors.surfaceHigh,
                  trackOutlineColor: const WidgetStatePropertyAll(AppColors.stroke),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// PIN

/// Asks for the parental PIN. True when it was right, or when there is none.
Future<bool> confirmPin(BuildContext context) async {
  final store = ProfileStore.instance;
  if (!store.hasPin) return true;
  final l = context.l10n;
  final pin = await showPinPad(
    context,
    title: l.enterPin,
    check: store.checkPin,
    wrong: l.wrongPin,
    forgot: true,
    limited: true,
  );
  if (pin != _forgotPin) return pin != null;
  if (context.mounted) await _forgotParentalPin(context);
  return false;
}

/// The way out of a forgotten parental PIN: the account's password. Without an account nothing can
/// tell a parent from a child, and a button that wiped the PIN would be the child's way past it.
Future<void> _forgotParentalPin(BuildContext context) async {
  final l = context.l10n;
  final sync = SyncService.instance;
  if (!sync.signedIn) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l.forgotPinNoAccount),
        actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: Text(l.close))],
      ),
    );
    return;
  }
  final proved = await showDialog<bool>(
    context: context,
    builder: (_) => PasswordsDialog(
      title: l.forgotPin,
      body: l.forgotPinAccount,
      labels: [l.syncPassword],
      action: l.removePin,
      run: (p) async {
        await sync.verifyPassword(p[0]);
        return true;
      },
    ),
  );
  if (proved != true) return;
  await ProfileStore.instance.setPin(null);
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.pinRemoved)));
}

/// A kids profile with no parental PIN to ask for: nothing tells a grown-up from a child, so what
/// is decided for the whole device or account is not offered.
bool get adultActionsHidden => ProfileStore.instance.current.kids && !ProfileStore.instance.hasPin;

/// Does [action], which on a kids profile takes the parental PIN.
Future<void> adultOnly(BuildContext context, VoidCallback action) async {
  if (ProfileStore.instance.current.kids && !await confirmPin(context)) return;
  if (context.mounted) action();
}

/// Asks for the PIN that opens [p]: its own, else the parental one. True when it was right, or when
/// there is none. Who forgot its own gets the way out, with what it watched gone, unless [forgot]
/// says it is no time for it: someone already in the profile, whom that would throw out.
Future<bool> confirmProfilePin(BuildContext context, Profile p, {bool forgot = true}) async {
  if (!p.hasOwnPin) return confirmPin(context);
  final l = context.l10n;
  final pin = await showPinPad(
    context,
    title: p.name.isEmpty ? l.enterPinMain : l.enterPinOf(p.displayName(l)),
    check: (pin) => ProfileStore.instance.checkProfilePin(p, pin),
    wrong: l.wrongPin,
    forgot: forgot,
    limited: true,
  );
  if (pin != _forgotPin) return pin != null;
  if (context.mounted) await _forgotProfilePin(context, p);
  return false;
}

const _forgotPin = 'forgot'; // what the pad returns for it: never four digits

/// The way out of a forgotten PIN: behind the parental one, and what the profile watched goes with
/// it, so forgetting is no way to see it. The main profile cannot go: it stays, empty and without PIN.
Future<void> _forgotProfilePin(BuildContext context, Profile p) async {
  if (!await confirmPin(context) || !context.mounted) return;
  final l = context.l10n;
  final name = p.displayName(l);
  final sure = await showConfirm(
    context,
    message: p.isMain ? (p.name.isEmpty ? l.forgotPinMainUnnamed : l.forgotPinMain(name)) : l.forgotPinProfile(name),
    confirmLabel: l.delete,
  );
  if (!sure) return;
  final store = ProfileStore.instance;
  if (!p.isMain) return store.remove(p.id);
  for (final playlist in await PlaylistStore.instance.load()) {
    await (await Library.load(playlist.id, p.id)).forgetAll();
  }
  await store.update(store.current.id == p.id ? store.current.copyWith(adult: false) : p.copyWith(adult: false));
  await Library.dropTraces(p.id); // its searches and picks: they tell what it watched too
  await store.setProfilePin(p.id, null);
}

/// Settings' way to the PIN of the profile in use, for whoever is in it: without the parental one,
/// which that person may not know.
Future<void> profilePinSettings(BuildContext context) async {
  final store = ProfileStore.instance;
  final p = store.current;
  final l = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  if (p.hasOwnPin) {
    if (!await confirmProfilePin(context, p, forgot: false) || !context.mounted) return;
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.profilePin),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.removePin)),
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: Text(l.changePin)),
        ],
      ),
    );
    if (remove == null || !context.mounted) return;
    if (remove) {
      await store.setProfilePin(p.id, null);
      messenger.showSnackBar(SnackBar(content: Text(l.pinRemoved)));
      return;
    }
  }
  final pin = await askNewPin(context);
  if (pin == null) return;
  await store.setProfilePin(p.id, pin);
  messenger.showSnackBar(SnackBar(content: Text(l.pinSaved)));
}

/// Asks for a new PIN, twice, saying what for in [title] if there is more to say. Null when cancelled.
Future<String?> askNewPin(BuildContext context, {String? title}) async {
  final l = context.l10n;
  final first = await showPinPad(context, title: title ?? l.newPin);
  if (first == null || !context.mounted) return null;
  return showPinPad(context, title: l.repeatPin, check: (p) async => p == first, wrong: l.pinMismatch);
}

/// A four-digit pad. Returns the PIN once [check] accepts it (any, without one); null when
/// cancelled. Digits come from the pad, the keyboard or a remote's number keys. With [forgot], it
/// also offers "I forgot the PIN".
Future<String?> showPinPad(
  BuildContext context, {
  required String title,
  Future<bool> Function(String pin)? check,
  String? wrong,
  bool forgot = false,
  bool limited = false,
}) => showDialog<String>(
  context: context,
  builder: (_) => _PinPad(title: title, check: check, wrong: wrong, forgot: forgot, limited: limited),
);

class _PinPad extends StatefulWidget {
  const _PinPad({required this.title, this.check, this.wrong, this.forgot = false, this.limited = false});

  final String title;
  final Future<bool> Function(String pin)? check;
  final String? wrong;
  final bool forgot;
  final bool limited; // a PIN that exists: see PinTries

  @override
  State<_PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<_PinPad> {
  static const length = 4;
  var _pin = '';
  var _error = false;
  var _checking = false;
  var _wait = 0; // seconds until another try
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (widget.limited) unawaited(_waitIfDue());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _waitIfDue() async {
    final left = await PinTries.secondsLeft();
    if (!mounted) return;
    setState(() {
      _wait = left;
      if (left > 0) _error = true;
    });
    _tick?.cancel();
    if (left == 0) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (--_wait > 0) return;
        _error = false;
        timer.cancel();
      });
    });
  }

  Future<void> _type(String digit) async {
    if (_checking || _wait > 0 || _pin.length >= length) return;
    setState(() {
      _pin += digit;
      _error = false;
    });
    if (_pin.length < length) return;
    _checking = true;
    final ok = await (widget.check?.call(_pin) ?? Future.value(true));
    if (widget.limited) await (ok ? PinTries.passed() : PinTries.failed());
    _checking = false;
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, _pin);
    } else {
      setState(() {
        _pin = '';
        _error = true;
      });
      if (widget.limited) await _waitIfDue();
    }
  }

  void _back() {
    if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final digit = switch (k) {
      LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0 => '0',
      LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => '1',
      LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => '2',
      LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => '3',
      LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => '4',
      LogicalKeyboardKey.digit5 || LogicalKeyboardKey.numpad5 => '5',
      LogicalKeyboardKey.digit6 || LogicalKeyboardKey.numpad6 => '6',
      LogicalKeyboardKey.digit7 || LogicalKeyboardKey.numpad7 => '7',
      LogicalKeyboardKey.digit8 || LogicalKeyboardKey.numpad8 => '8',
      LogicalKeyboardKey.digit9 || LogicalKeyboardKey.numpad9 => '9',
      _ => null,
    };
    if (digit != null) {
      _type(digit);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete) {
      _back();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _key(Widget child, VoidCallback onTap, {bool autofocus = false, String? label}) => Padding(
    padding: const EdgeInsets.all(5),
    child: Semantics(
      label: label,
      button: true,
      child: Focusable(
        autofocus: autofocus,
        radius: 12,
        scale: 1.06,
        onTap: onTap,
        child: Container(
          width: isShort(context) ? 60 : 64,
          height: isShort(context) ? 42 : 52,
          color: AppColors.surfaceHigh,
          alignment: Alignment.center,
          child: child,
        ),
      ),
    ),
  );

  Widget _digit(String d, {bool autofocus = false}) => _key(
    Text(d, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
    () => _type(d),
    autofocus: autofocus,
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // A phone on its side is too short for the pad under the title: they go side by side
    final short = isShort(context);
    final heading = [
      Text(widget.title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
      const SizedBox(height: 18),
      Semantics(
        liveRegion: true,
        label: context.l10n.pinDigits(_pin.length, length),
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < length; i++)
                Container(
                  width: 14,
                  height: 14,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? AppColors.text : Colors.transparent,
                    border: Border.all(color: AppColors.text, width: 1.5),
                  ),
                ),
            ],
          ),
        ),
      ),
      SizedBox(
        height: short ? 48 : 30,
        child: Center(
          widthFactor: 1, // as wide as the message: the pad sets the dialog's width
          child: _error
              ? Semantics(
                  liveRegion: true,
                  child: Text(
                    _wait > 0 ? context.l10n.pinWait(_wait) : widget.wrong ?? '',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                )
              : null,
        ),
      ),
    ];
    final forgot = widget.forgot
        ? TextButton(onPressed: () => Navigator.pop(context, _forgotPin), child: Text(l.forgotPin))
        : null;
    final pad = [
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
      ])
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [for (final d in row) _digit(d, autofocus: d == '1')],
        ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _key(const Icon(Icons.close_rounded), () => Navigator.pop(context), label: l.cancel),
          _digit('0'),
          _key(const Icon(Icons.backspace_outlined), _back, label: l.backspace),
        ],
      ),
    ];
    return Dialog(
      backgroundColor: AppColors.surface,
      // Hears the number keys of whichever key has the focus, and never has it itself: as a place to
      // go, its middle was nearer than the next row's, so a remote going down lost the keys
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Padding(
          padding: short ? const EdgeInsets.fromLTRB(24, 12, 12, 12) : const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: short
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 200,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [const SizedBox(height: 48), ...heading, ?forgot],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Column(mainAxisSize: MainAxisSize.min, children: pad),
                  ],
                )
              : Column(mainAxisSize: MainAxisSize.min, children: [...heading, ...pad, ?forgot]),
        ),
      ),
    );
  }
}
