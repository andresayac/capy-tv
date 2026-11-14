import 'package:flutter/material.dart';

import '../data/library.dart';
import '../data/playlist_session.dart';
import '../data/playlists.dart';
import '../data/profiles.dart';
import '../data/secrets.dart';
import '../data/settings.dart';
import '../data/source.dart';
import '../data/xtream.dart';
import '../device.dart';
import '../platform.dart';
import '../sync/cast.dart';
import '../sync/sync_service.dart';
import 'backdrop.dart';
import 'common.dart';
import 'connect_screen.dart';
import 'home_screen.dart';
import 'profiles_screen.dart';
import 'recordings_screen.dart';
import 'remote_text_field.dart';
import 'sync_screen.dart';
import 'theme.dart';

/// Entry screen: the saved playlists (Xtream accounts or M3U URLs).
class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

/// Whether the app goes straight into a playlist as it starts: there is just [playlists] one to
/// choose from, this screen is the one showing and nothing else is opening.
@visibleForTesting
bool opensByItself(int? playlists, {required bool onTop, required bool busy}) => playlists == 1 && onTop && !busy;

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  // Shared with the companion server: a playlist sent from a phone shows up here at once
  final _store = PlaylistStore.instance;
  String? _opening; // id of the playlist being opened
  var _opened = 0; // playlists opened so far: a later one may open while an earlier one closes

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    ProfileStore.instance.addListener(_changed);
    castRequest.addListener(_onCast);
    _store.load().then((_) {
      _changed();
      _openTheOnlyOne();
    });
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    ProfileStore.instance.removeListener(_changed);
    castRequest.removeListener(_onCast);
    super.dispose();
  }

  /// Something another device sent to play here, in a playlist that is not the one open (that
  /// one's Home plays it): back here, and that playlist opens, its Home playing it.
  void _onCast() {
    final r = castRequest.value;
    if (r == null || !mounted || currentLibrary.value?.playlistId == r.playlistId) return;
    final p = _store.playlists?.where((x) => x.id == r.playlistId).firstOrNull;
    if (p == null) return;
    final here = ModalRoute.of(context);
    Navigator.of(context).popUntil((route) => route == here);
    _open(p);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // A profile picked from inside a playlist: open it again, for that profile
    final id = reopenAfterProfile.value;
    if (id == null || ProfileStore.instance.choosing) return;
    reopenAfterProfile.value = null;
    final p = _store.playlists?.where((x) => x.id == id).firstOrNull;
    if (p != null) _open(p);
  }

  /// As the app starts, and only then: coming back here is the way to add, change or delete one.
  void _openTheOnlyOne() {
    if (!mounted) return;
    final all = _store.playlists;
    final onTop = ModalRoute.of(context)?.isCurrent ?? true; // a link from another device opened over this
    if (opensByItself(all?.length, onTop: onTop, busy: _opening != null || reopenAfterProfile.value != null)) {
      _open(all!.single);
    }
  }

  /// The list is saved all the same: only its password was not.
  Future<void> _saving(Future<void> saved) async {
    try {
      await saved;
    } on SecretsUnavailable {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.noSecureStorage)));
    }
  }

  Future<void> _add() async {
    if (!await confirmPin(context) || !mounted) return;
    final p = await Navigator.of(context).push<Playlist>(MaterialPageRoute(builder: (_) => const AddPlaylistScreen()));
    if (p == null) return;
    // The same account again: its new password, not a second list of it
    if ((_store.playlists ?? const <Playlist>[]).where((x) => x.sameAccount(p)).firstOrNull case final had?) {
      await _saving(_store.update(had.copyWith(password: p.password)));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.accountAlreadyAdded)));
      }
      return;
    }
    await _saving(_store.add(p));
    // A second provider, and none combined yet: say what they can do together
    final all = _store.playlists ?? const <Playlist>[];
    final providers = all.where((x) => x.type != PlaylistType.combined).length;
    if (providers >= 2 && !all.any((x) => x.type == PlaylistType.combined) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.combineSuggestion),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(label: context.l10n.combinePlaylists, onPressed: _combine),
        ),
      );
    }
  }

  /// New server, user or password for the same playlist: favorites and history stay with it.
  Future<void> _edit(Playlist p) async {
    if (!await confirmPin(context) || !mounted) return;
    final edited = await Navigator.of(context).push<Playlist>(
      MaterialPageRoute(
        builder: (_) =>
            p.type == PlaylistType.combined ? CombinePlaylistsScreen(initial: p) : AddPlaylistScreen(initial: p),
      ),
    );
    if (edited == null) return;
    setState(() => _failed.remove(p.id)); // checked: it may open now
    await _saving(_store.update(edited));
  }

  /// Several providers as one list: their catalogs together, each title once with every copy.
  Future<void> _combine() async {
    if (!await confirmPin(context) || !mounted) return;
    final p = await Navigator.of(context)
        .push<Playlist>(MaterialPageRoute(builder: (_) => const CombinePlaylistsScreen()));
    if (p != null) await _saving(_store.add(p));
  }

  /// A phone types the playlist instead of the remote; the screen closes once it arrives.
  Future<void> _addFromPhone() async {
    if (!await confirmPin(context) || !mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen(tab: 'add', closeOnPlaylist: true)));
  }

  Future<void> _delete(Playlist p) async {
    if (!await confirmPin(context) || !mounted) return;
    final l = context.l10n;
    // A combined playlist that joins it goes on without it, and would not say so when opened
    final combined = [
      for (final c in _store.playlists ?? const <Playlist>[])
        if (c.type == PlaylistType.combined && c.members.contains(p.id)) '"${c.name}"',
    ];
    final notes = [
      if (combined.isNotEmpty) l.deletePlaylistInCombined(combined.length, combined.join(', ')),
      if (SyncService.instance.signedIn) l.deletePlaylistEverywhere,
    ];
    final ok = await showConfirm(
      context,
      title: l.deletePlaylistQuestion(p.name),
      message: notes.isEmpty ? null : notes.join('\n\n'),
      confirmLabel: l.delete,
    );
    if (!ok) return;
    await _saving(_store.remove(p));
  }

  /// Why a playlist did not open, by id: on its card until it is tried again or edited, rather than
  /// in a message gone in a few seconds (at start, the only playlist opens by itself).
  final _failed = <String, String>{};

  Future<void> _open(Playlist p) async {
    final turn = ++_opened;
    setState(() {
      _opening = p.id;
      _failed.remove(p.id);
    });
    try {
      final session = await PlaylistSession.open(
        p,
        ProfileStore.instance.current,
        liveFormat: SettingsScope.of(context).liveFormat,
      );
      if (!mounted) return;
      session.publish();
      final home = MaterialPageRoute<void>(
        builder: (_) => HomeScreen(playlist: p, source: session.source, account: session.account),
      );
      await Navigator.of(context).push(home);
      // Only once Home is off the screen: it is still built while it slides away
      await home.completed;
      session.close();
    } catch (e) {
      if (mounted) setState(() => _failed[p.id] = errorText(context.l10n, e));
    } finally {
      if (mounted && turn == _opened) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final list = _store.playlists;
    final text = Theme.of(context).textTheme;
    final profiles = ProfileStore.instance;
    final intro = [
      const Align(alignment: Alignment.centerLeft, child: AppLogo(size: 56)),
      // Whose favorites and history these are, and the way to someone else's
      if (profiles.profiles.length > 1) ...[
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: Focusable(
            radius: AppRadius.pill,
            scale: 1.03,
            onTap: () => switchProfile(context),
            child: Container(
              color: AppColors.surface,
              padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProfileAvatar(profile: profiles.current, size: 30),
                  const SizedBox(width: 10),
                  Text(profiles.current.displayName(l), style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  const Icon(Icons.swap_horiz_rounded, size: 18, color: AppColors.muted),
                ],
              ),
            ),
          ),
        ),
      ],
      const SizedBox(height: 28),
      Text(l.welcomeTitle, style: text.displaySmall),
      const SizedBox(height: 12),
      Text(l.welcomeBody, style: text.bodyLarge?.copyWith(color: AppColors.muted, height: 1.5)),
    ];
    final playlists = [
      if (list == null)
        const Center(child: CapyStatus(mood: CapyMood.loading, size: 64))
      else ...[
        if (list.isNotEmpty) ...[Text(l.playlists, style: text.titleLarge), const SizedBox(height: 12)],
        for (final (i, p) in list.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            // The card opens it; editing and deleting are stops of their own beside it, which Right
            // reaches (inside it, Flutter's traversal never would)
            child: Panel(
              radius: 20,
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Focusable(
                      autofocus: i == 0,
                      scale: 1.02,
                      radius: 20,
                      // One at a time; the card stays a stop for the remote meanwhile
                      onTap: () => _opening == null ? _open(p) : null,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceHigh,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(switch (p.type) {
                                PlaylistType.xtream => Icons.dns_rounded,
                                PlaylistType.m3u => Icons.playlist_play_rounded,
                                PlaylistType.combined => Icons.layers_rounded,
                              }, color: AppColors.text),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                                  // While it opens, how much of its list has come (an M3U downloads here)
                                  ListenableBuilder(
                                    listenable: listProgress,
                                    builder: (context, _) => Text(
                                      (_opening == p.id ? listProgressText(context) : null) ??
                                          switch (p.type) {
                                            _
                                                when ProfileStore.instance.current.kids &&
                                                    p.type != PlaylistType.combined =>
                                              '',
                                            PlaylistType.xtream => '${p.username} · ${p.address}',
                                            PlaylistType.m3u => p.address,
                                            PlaylistType.combined => [
                                              for (final id in p.members)
                                                ?list.where((x) => x.id == id).firstOrNull?.name,
                                            ].join(' + '),
                                          },
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: AppColors.muted, fontSize: 13),
                                    ),
                                  ),
                                  if (_failed[p.id] case final why?) ...[
                                    const SizedBox(height: 6),
                                    Semantics(
                                      liveRegion: true,
                                      child: Text(
                                        why,
                                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                      ),
                                    ),
                                    Text(
                                      l.openFailedHint,
                                      style: const TextStyle(color: AppColors.muted, fontSize: 13),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_opening == p.id)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else if (!adultActionsHidden)
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: l.editPlaylist,
                      onPressed: () => _edit(p),
                    ),
                  if (!adultActionsHidden)
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      tooltip: l.delete,
                      onPressed: () => _delete(p),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        // On a TV the phone is the easy way to type a server and a password
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final phone in isTv ? [true, false] : [false, if (offersCompanion) true])
              if (list.isEmpty && phone == isTv)
                PrimaryButton(
                  autofocus: true,
                  icon: phone ? Icons.qr_code_rounded : Icons.add_rounded,
                  label: phone ? l.addFromPhone : l.addPlaylist,
                  onPressed: phone ? _addFromPhone : _add,
                )
              else
                SecondaryButton(
                  icon: phone ? Icons.qr_code_rounded : Icons.add_rounded,
                  label: phone ? l.addFromPhone : l.addPlaylist,
                  onPressed: phone ? _addFromPhone : _add,
                ),
            if (list.where((p) => p.type != PlaylistType.combined).length >= 2 && !adultActionsHidden)
              SecondaryButton(icon: Icons.layers_outlined, label: l.combinePlaylists, onPressed: _combine),
            if (!adultActionsHidden)
              SecondaryButton(
                icon: Icons.people_outline_rounded,
                label: l.profiles,
                onPressed: () => openProfileSettings(context),
              ),
            // Here too, with no playlist to open: one whose provider is down still has its recordings.
            // They are the device's, whoever recorded them; a browser keeps none
            if (!isWeb && !ProfileStore.instance.current.kids)
              SecondaryButton(
                icon: Icons.video_library_outlined,
                label: l.recordings,
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RecordingsScreen())),
              ),
            // On a new device, signing in brings the lists from the others. Not for a child: it
            // signs devices out and joins the account (the parental PIN, as Settings asks)
            if (!adultActionsHidden)
              ListenableBuilder(
                listenable: SyncService.instance,
                builder: (context, _) => SecondaryButton(
                  icon: switch (SyncService.instance.status) {
                    SyncStatus.off => Icons.cloud_outlined,
                    SyncStatus.offline => Icons.cloud_off_outlined,
                    SyncStatus.expired => Icons.lock_clock_outlined,
                    SyncStatus.syncing || SyncStatus.synced => Icons.cloud_done_outlined,
                  },
                  label: l.sync,
                  onPressed: () => adultOnly(
                    context,
                    () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SyncScreen())),
                  ),
                ),
              ),
          ],
        ),
      ],
    ];
    return PosterBackdrop(
      hero: true,
      child: Scaffold(
        body: SafeArea(
          child: isWide(context)
              // Landscape, like a TV: the welcome on the left, the playlists and their actions on
              // the right, all on the first screen
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        // As the playlists beside it: it scrolls when it does not fit (a phone on its
                        // side, large text), rather than being cut off
                        child: Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: intro),
                          ),
                        ),
                      ),
                      const SizedBox(width: 56),
                      Expanded(
                        flex: 6,
                        child: Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(vertical: 32),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: playlists),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 48, 24, 40),
                      children: [...intro, const SizedBox(height: 32), ...playlists],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Form for a new playlist, or to change [initial]; validates it against the server before saving.
class AddPlaylistScreen extends StatefulWidget {
  const AddPlaylistScreen({super.key, this.initial});

  /// The playlist being edited: it keeps its id, and with it its favorites and history.
  final Playlist? initial;

  @override
  State<AddPlaylistScreen> createState() => _AddPlaylistScreenState();
}

class _AddPlaylistScreenState extends State<AddPlaylistScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial?.name);
  late final _url = TextEditingController(text: widget.initial?.url);
  late final _user = TextEditingController(text: widget.initial?.username);
  late final _pass = TextEditingController(text: widget.initial?.password);
  late final _agent = TextEditingController(text: widget.initial?.userAgent);
  late var _type = widget.initial?.type ?? PlaylistType.xtream;
  late var _guideShift = widget.initial?.guideShift ?? 0; // minutes
  var _busy = false;
  String? _error;
  var _fromLink = false; // the fields were filled in from a pasted link
  String? _link; // that link: as an M3U list, it may work where the panel's API is closed

  /// A pasted provider link: its server, user and password go to their fields.
  late var _typed = widget.initial?.url ?? ''; // the address as it was before the last change

  /// A provider's link with everything in it fills the fields: when it comes at once (pasted, or
  /// sent from the phone), not while typed a letter at a time, or the first letter of a password
  /// would be taken for all of it. Typed, it is read on saving.
  void _urlChanged(String text) {
    final before = _typed;
    _typed = text;
    if (text.length - before.length <= 1) return;
    _fromLinkIn(text);
  }

  void _fromLinkIn(String text) {
    final x = Playlist.xtreamLink(text);
    if (x == null) return;
    setState(() {
      _type = PlaylistType.xtream;
      _url.text = x.server;
      _user.text = x.username;
      _pass.text = x.password;
      _fromLink = true;
      _link = text.trim();
    });
  }

  /// The account taken from a provider's link did not check out, and not because the panel said
  /// it is no good (its API closed, or no Xtream panel behind it): the link itself is tried as the
  /// M3U list it also is. True when it was saved that way.
  Future<bool> _savedAsList(Playlist p, Object error) async {
    final link = _link;
    final x = link == null ? null : Playlist.xtreamLink(link);
    if (x == null || p.type != PlaylistType.xtream || accountRefused(error)) return false;
    if (p.url != x.server || p.username != x.username || p.password != x.password) return false; // changed since
    final list = Playlist(id: p.id, name: p.name, type: PlaylistType.m3u, url: link!);
    try {
      await list.verify();
    } on Object {
      return false;
    }
    if (mounted) Navigator.pop(context, list);
    return true;
  }

  Future<void> _save() async {
    if (_busy) return; // OK again on a TV's field while it checks: once is enough
    _fromLinkIn(_url.text); // a link typed whole
    if (!_form.currentState!.validate()) return;
    final created = Playlist.create(
      type: _type,
      url: _url.text,
      name: _name.text,
      username: _user.text,
      password: _pass.text,
      userAgent: _agent.text,
    );
    // Edited, it keeps what a newer version of the app wrote in it
    final p = widget.initial == null
        ? created.copyWith(guideShift: _guideShift)
        : created.copyWith(id: widget.initial!.id, extra: widget.initial!.extra, guideShift: _guideShift);
    // Renamed only (or its guide's time moved): nothing to check, and a provider down right now
    // would not let it be saved
    if (widget.initial case final i?
        when i.type == p.type &&
            i.url == p.url &&
            i.username == p.username &&
            i.password == p.password &&
            i.userAgent == p.userAgent) {
      Navigator.pop(context, p);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await p.verify();
      if (mounted) Navigator.pop(context, p);
    } catch (e) {
      if (await _savedAsList(p, e)) return;
      if (mounted) setState(() => _error = errorText(context.l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    String? required(String? v) => (v ?? '').trim().isEmpty ? l.required : null;
    // Said before it is sent: "host:80a" or a space in it cannot be an address
    String? address(String? v) {
      if (required(v) case final missing?) return missing;
      try {
        XtreamSource.normalizeServer(v!);
        return null;
      } on SourceException {
        return l.errorBadAddress;
      }
    }

    return PosterBackdrop(
      child: Scaffold(
        appBar: AppBar(title: Text(widget.initial == null ? l.addPlaylist : l.editPlaylist)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // Starts focused, so a TV remote has a visible place to begin
                  Wrap(
                    spacing: 8,
                    children: [
                      AppChip(
                        label: l.playlistTypeXtream,
                        icon: Icons.dns_outlined,
                        selected: _type == PlaylistType.xtream,
                        autofocus: true,
                        onTap: () => setState(() => _type = PlaylistType.xtream),
                      ),
                      AppChip(
                        label: l.playlistTypeM3u,
                        icon: Icons.link,
                        selected: _type == PlaylistType.m3u,
                        onTap: () => setState(() => _type = PlaylistType.m3u),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  RemoteTextFormField(
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(labelText: l.playlistName),
                  ),
                  const SizedBox(height: 12),
                  RemoteTextFormField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: _type == PlaylistType.xtream ? TextInputAction.next : TextInputAction.done,
                    onFieldSubmitted: _type == PlaylistType.xtream ? null : (_) => _save(),
                    onChanged: _urlChanged,
                    decoration: InputDecoration(
                      labelText: _type == PlaylistType.xtream ? l.serverUrl : l.m3uUrl,
                      hintText: _type == PlaylistType.xtream
                          ? 'http://example.com:8080'
                          : 'http://example.com/list.m3u',
                      // Providers send a link with everything in it: pasting it is enough
                      helperText: _fromLink ? l.filledFromLink : l.pasteLinkHint,
                      helperMaxLines: 2,
                    ),
                    validator: address,
                  ),
                  if (_type == PlaylistType.xtream) ...[
                    const SizedBox(height: 12),
                    RemoteTextFormField(
                      controller: _user,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(labelText: l.username),
                      validator: required,
                    ),
                    const SizedBox(height: 12),
                    RemoteTextFormField(
                      controller: _pass,
                      obscureText: true,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _save(),
                      decoration: InputDecoration(labelText: l.password),
                      validator: required,
                    ),
                    const SizedBox(height: 12),
                    RemoteTextFormField(
                      controller: _agent,
                      autocorrect: false,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _save(),
                      decoration: InputDecoration(labelText: l.userAgentOptional, helperText: l.userAgentHint),
                    ),
                  ],
                  // A provider whose guide is on the wrong clock: put right here, an hour at a time
                  const SizedBox(height: 12),
                  ChoiceRow<int>(
                    label: l.guideTime,
                    hint: l.guideTimeHint,
                    value: _guideShift,
                    options: [for (var h = -12; h <= 12; h++) h * 60],
                    text: (m) => m == 0
                        ? l.guideTimeAsSent
                        : l.guideTimeMoved(
                            '${m > 0 ? '+' : '−'}${(m.abs() / 60).toStringAsFixed(m % 60 == 0 ? 0 : 1)}',
                          ),
                    onChanged: (m) => setState(() => _guideShift = m),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    // Said as it comes: a reader's focus is on Save
                    Semantics(
                      liveRegion: true,
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _busy
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                              const SizedBox(width: 12),
                              // An M3U comes whole to be checked: how much of it has come
                              ListenableBuilder(
                                listenable: listProgress,
                                builder: (context, _) => Text(listProgressText(context) ?? l.connecting),
                              ),
                            ],
                          )
                        : PrimaryButton(icon: Icons.check_rounded, label: l.save, onPressed: _save),
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

/// Joins playlists of several providers into one: their catalogs together, each title once with
/// every provider's copy among its versions, played from the fastest at the hour and from another
/// when one fails. The playlists stay as they are; or changes [initial]'s.
class CombinePlaylistsScreen extends StatefulWidget {
  const CombinePlaylistsScreen({super.key, this.initial});

  final Playlist? initial;

  @override
  State<CombinePlaylistsScreen> createState() => _CombinePlaylistsScreenState();
}

class _CombinePlaylistsScreenState extends State<CombinePlaylistsScreen> {
  late final _name = TextEditingController(text: widget.initial?.name);
  // In the order they were picked. One taken out of a saved playlist leaves its place empty (''),
  // and one put back takes it again: ids saved in favorites and history carry those places
  late final _chosen = [...?widget.initial?.members];

  int get _picked => _chosen.where((id) => id.isNotEmpty).length;

  void _toggle(String id) {
    final at = _chosen.indexOf(id), was = widget.initial?.members.indexOf(id) ?? -1;
    if (at >= 0) {
      at < (widget.initial?.members.length ?? 0) ? _chosen[at] = '' : _chosen.removeAt(at);
    } else if (was >= 0 && was < _chosen.length && _chosen[was].isEmpty) {
      _chosen[was] = id;
    } else {
      _chosen.add(id);
    }
  }

  /// Where [id] goes among those picked, from 1.
  int _placeOf(String id) => _chosen.take(_chosen.indexOf(id)).where((x) => x.isNotEmpty).length + 1;
  List<Playlist> _all = const [];

  @override
  void initState() {
    super.initState();
    PlaylistStore.instance.load().then((all) {
      if (!mounted) return;
      setState(
        () => _all = [
          for (final p in all)
            if (p.type != PlaylistType.combined) p,
        ],
      );
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final names = [for (final id in _chosen) ?_all.where((p) => p.id == id).firstOrNull?.name];
    final name = _name.text.trim().isEmpty ? names.join(' + ') : _name.text;
    // Empty places at the end hold no one's ids
    while (_chosen.isNotEmpty && _chosen.last.isEmpty) {
      _chosen.removeLast();
    }
    Navigator.pop(context, Playlist.combine(name: name, members: _chosen, id: widget.initial?.id));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return PosterBackdrop(
      child: Scaffold(
        appBar: AppBar(title: Text(l.combinePlaylists)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(l.combineBody, style: const TextStyle(color: AppColors.muted, height: 1.5)),
                const SizedBox(height: 20),
                for (final (i, p) in _all.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Focusable(
                      autofocus: i == 0,
                      scale: 1.02,
                      radius: 16,
                      onTap: () => setState(() => _toggle(p.id)),
                      child: Panel(
                        radius: 16,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Row(
                          children: [
                            Icon(
                              _chosen.contains(p.id) ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                              color: _chosen.contains(p.id) ? AppColors.text : AppColors.muted,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                            ),
                            // The order picked: on equal speed, the first one's copy plays
                            if (_chosen.contains(p.id))
                              Text(
                                '${_placeOf(p.id)}',
                                style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                RemoteTextFormField(
                  controller: _name,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(labelText: l.playlistName),
                ),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: PrimaryButton(
                    icon: Icons.check_rounded,
                    label: l.save,
                    onPressed: _picked >= 2 ? _save : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
