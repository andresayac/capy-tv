import 'dart:async';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chromecast/chromecast_service.dart';
import '../data/airing.dart';
import '../data/catalog.dart';
import '../data/combined.dart';
import '../data/epg.dart';
import '../data/kids.dart';
import '../data/library.dart';
import '../data/matching.dart';
import '../data/models.dart';
import '../data/playlist_session.dart';
import '../data/playlists.dart';
import '../data/poster_wall.dart';
import '../data/profiles.dart';
import '../data/settings.dart';
import '../data/source.dart';
import '../data/trending.dart';
import '../data/xtream.dart';
import '../device.dart';
import '../platform.dart';
import '../player/play.dart';
import '../remote/remote_input.dart';
import '../sync/app_update.dart';
import '../sync/cast.dart';
import '../sync/sync_service.dart';
import 'account_screen.dart';
import 'app_update_dialog.dart';
import 'cast_screen.dart';
import 'catalog.dart';
import 'common.dart';
import 'detail_screens.dart';
import 'guide_screen.dart';
import 'home_tab.dart';
import 'live_groups.dart';
import 'profiles_screen.dart';
import 'search_tab.dart';
import 'theme.dart';
import 'title_bar.dart';

/// Whether lists held for [age] are brought again by themselves on coming back to the app. Not over
/// something playing, whose line that would take, nor on a TV stick, where the old catalog and the
/// new one do not fit at once: there the app's next start updates them, behind.
@visibleForTesting
bool updatesListsOnReturn(Duration age) => age > XtreamSource.listsFresh && nowPlaying.value == null && !lowMemory;

/// Shell of an open playlist: Home, Live TV, Movies, Series and Search; the account and
/// settings open from the side bar (wide) or the Home header.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.playlist, required this.source, this.account});

  final Playlist playlist;
  final ContentSource source;
  final AccountInfo? account; // Xtream only

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  var _tab = 0;

  /// The tabs opened so far: one is built the first time it shows, not at once with Home, where
  /// Movies' and Series' rows and posters would all load for a tab maybe never opened.
  final _visited = <int>{};
  final _bodyKey = GlobalKey();
  // One focus scope per tab: hidden tabs cannot hold or grab the focus, and each tab
  // remembers what was focused in it for when the remote comes back. At a tab's edge the
  // arrows carry on outside it, to the navigation.
  final _scopes = List.generate(
    5,
    (i) => FocusScopeNode(debugLabel: 'tab $i', directionalTraversalEdgeBehavior: TraversalEdgeBehavior.parentScope),
  );
  FocusNode? _liveEntry; // the selected category, reported by LiveTab
  final _navNodes = List.generate(5, (i) => FocusNode(debugLabel: 'nav $i'));
  // The provider's lists, replaced when they are updated (see [_refresh])
  late var _source = widget.source;
  late var _catalog = Catalog(widget.source);
  var _generation = 0; // the tabs are built anew from each update
  var _listsAt = DateTime.now();
  Future<({int movies, int series, int channels})>? _refreshing;
  ContentSource? _incoming; // the lists [_refreshing] brings, until it is over
  final _updating = ValueNotifier(false); // while [_refreshing] runs
  final _guide = ValueNotifier(EpgGuide.loading);
  // What the desktop title bar shows of this playlist, and does with it
  late final _inTitleBar = OpenPlaylist(
    playlist: widget.playlist,
    refresh: _refresh,
    updating: _updating,
    switchPlaylist: _switchPlaylist,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    currentCatalog.value = _catalog;
    currentAiring.value = Airing.of(_source);
    openPlaylist.value = _inTitleBar;
    remoteSearch.addListener(_showSearch);
    castRequest.addListener(_onCast);
    AppUpdate.available.addListener(_offerUpdate);
    ProfileStore.instance.addListener(_profileGone);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onCast(); // one that opened this playlist
      _offerUpdate(); // found before Home opened
      _warnExpiry();
    });
    // Warm the catalog up while the user looks at Home; browse, search and "more like this" share it.
    // Then, quietly, note its best posters for the screens outside a playlist, and the TMDB id of
    // watched movies: it finds them again with another provider. This playlist's library, taken
    // now: by the time the catalog comes another playlist may be open
    final library = currentLibrary.value;
    final catalogDone = _catalog.load().then((data) {
      unawaited(PosterWall.remember(data, adultHidden: _source.hideAdult));
      // A catalog in another language than the app's: the trends' titles in that one too. Read off
      // the UI's thread, as the catalog comes in and the screen is busiest
      final names = [for (final m in data.movies.take(Trending.namesForLanguage)) m.name];
      unawaited(compute(Trending.guessLanguage, names).then(Trending.alsoIn));
      if ((library, _source) case (final Library l, final MovieDetails s)) {
        addTmdbIds(l, s, open: () => mounted && currentLibrary.value == l);
      }
    }, onError: (Object _) {});
    // The guide is often tens of MB of XML: read once the catalog is in, however that went, so the
    // two do not compete for a modest device's memory and cores. The UI fills in when it arrives
    unawaited(
      catalogDone.whenComplete(() {
        if (!mounted) return;
        widget.source.guide().then(
          (g) {
            if (mounted) _guide.value = currentGuide.value = g;
          },
          onError: (Object _) {
            if (mounted) _guide.value = EpgGuide.failed; // no longer on its way: the guide says so
          },
        );
      }),
    );
  }

  /// Something another device sent to play here, in this playlist: whatever is open over Home
  /// closes, and it plays from where it was there.
  void _onCast() {
    final r = castRequest.value;
    if (r == null || r.playlistId != widget.playlist.id || !mounted) return;
    castRequest.value = null;
    // Sent a while ago, it waited behind "Who's watching?": this may be someone else
    if (DateTime.now().difference(r.at) > SyncService.castFor) return;
    if (!libraryShows(r.ref, _catalog.loaded, _source)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.castNotAllowed)));
      return;
    }
    final home = ModalRoute.of(context);
    Navigator.of(context).popUntil((route) => route == home);
    // What was open closes and something else plays: say where it came from
    if (r.from.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.sentFrom(r.from))));
    }
    playFromLibrary(context, _source, r.ref, from: r.position);
  }

  /// A newer app on the account's sync server: offered when nothing is open over Home (never over
  /// the player), once a day at most. Settings has it all along.
  void _offerUpdate() {
    final release = AppUpdate.available.value;
    if (release == null || !mounted || !AppUpdate.offerDue || ModalRoute.of(context)?.isCurrent != true) return;
    showAppUpdate(context, release);
  }

  /// The provider's service ending within a week: said once a day, so it is renewed before the
  /// playlist stops opening. Nothing is limited, and kids are not told.
  Future<void> _warnExpiry() async {
    final ends = widget.account?.expires;
    if (ends == null || ProfileStore.instance.current.kids) return;
    final left = ends.difference(DateTime.now());
    if (left.isNegative || left > const Duration(days: 7)) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'expiryTold.${widget.playlist.id}', today = DateTime.now().toIso8601String().substring(0, 10);
    if (prefs.getString(key) == today || !mounted) return;
    await prefs.setString(key, today);
    if (!mounted) return;
    final l = context.l10n;
    final date = DateFormat.MMMMd(Localizations.localeOf(context).toLanguageTag()).format(ends);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l.serviceEndsSoon(widget.playlist.name, date)), duration: const Duration(seconds: 8)),
    );
  }

  /// Back to the app after a while (a TV that slept, a phone in a pocket): lists older than a
  /// session's are updated by themselves (see [updatesListsOnReturn]).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (updatesListsOnReturn(DateTime.now().difference(_listsAt))) {
      _refresh().catchError((Object _) => (movies: 0, series: 0, channels: 0)); // quietly: the old ones stay
    } else if (_source case final XtreamSource x when ProfileStore.instance.current.dailyMinutes != null) {
      // A time per day counts by the provider's clock, asked again: a date moved ahead on the
      // device while the app was away gives no new day (a refresh logs in anyway)
      unawaited(x.login().then((_) {}, onError: (Object _) {}));
    }
  }

  /// The provider's lists again, whatever their age: fetched in the background and, once in, shown
  /// instead of the ones there were (the tabs are built anew from them). Throws if the provider
  /// cannot be reached; the old lists stay, except on a low-memory device (a TV stick), which has
  /// no room for both: there the old ones go as the new ones are asked for. Says how many titles
  /// and channels are new.
  Future<({int movies, int series, int channels})> _refresh() => _refreshing ??= () async {
    _updating.value = true;
    try {
      // Of the old lists, only what tells what is new: the lists themselves need not stay
      final had = await () async {
        final old = await _catalog.load().catchError((Object _) => CatalogData(live: [], movies: [], series: []));
        return (
          movies: {for (final m in old.movies) old.keyOf(m)},
          series: {for (final s in old.series) old.keyOf(s)},
          channels: {for (final c in old.live) c.id},
        );
      }();
      if (!mounted) throw StateError('closed');
      // As it opened (PlaylistSession): only what the profile may see, and the panel's clock
      final source = await PlaylistSession.fresh(
        widget.playlist,
        ProfileStore.instance.current,
        liveFormat: SettingsScope.of(context).liveFormat,
      );
      _incoming = source;
      if (!mounted) throw StateError('closed');
      final catalog = Catalog(source);
      void showNew() {
        setState(() {
          _source = source;
          _catalog = catalog;
          _generation++;
          _listsAt = DateTime.now();
        });
        currentCatalog.value = catalog;
        currentAiring.value = Airing.of(source);
      }

      // As updatesListsOnReturn says: the old catalog and the new one do not fit in a stick at once.
      // The old source lets go of its lists too, the same objects the old catalog had
      if (lowMemory) {
        final old = _source;
        showNew();
        if (old case final ListHolder h) h.forgetLists();
      }
      final data = await catalog.load();
      if (source case final CombinedSource c when c.failed.isNotEmpty) throw PartsMissing(c.failed.toList());
      // A list the provider did not send this time (it failed) would leave a tab empty
      if ((had.movies.isNotEmpty && data.movies.isEmpty) ||
          (had.series.isNotEmpty && data.series.isEmpty) ||
          (had.channels.isNotEmpty && data.live.isEmpty)) {
        throw const SourceException(SourceError.unreachable);
      }
      final news = (
        movies: {for (final m in data.movies) data.keyOf(m)}.difference(had.movies).length,
        series: {for (final s in data.series) data.keyOf(s)}.difference(had.series).length,
        channels: {for (final c in data.live) c.id}.difference(had.channels).length,
      );
      if (!mounted) return news;
      if (!lowMemory) showNew();
      unawaited(
        source.guide().then((g) {
          if (mounted) _guide.value = currentGuide.value = g;
        }, onError: (Object _) {}),
      );
      _select(_tab); // what had the remote's focus is gone: the tab's first item gets it
      return news;
    } finally {
      _refreshing = null;
      _incoming = null;
      if (mounted) _updating.value = false;
    }
  }();

  /// The profile this playlist was opened for.
  final _profile = ProfileStore.instance.current.id;

  /// Deleted on another device (by sync) while its playlist is open here: the playlist closes, as
  /// when it is deleted here, so nothing more is saved for it; whoever is here picks again.
  void _profileGone() {
    if (!mounted || ProfileStore.instance.profiles.any((p) => p.id == _profile)) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  void dispose() {
    // What they still bring is for nobody now: it stops, rather than compete with the next playlist
    // (an earlier one an update replaced is left be: a screen over Home may have been using it)
    for (final s in {widget.source, _source, ?_incoming}) {
      if (s case final Closable c) c.close();
    }
    WidgetsBinding.instance.removeObserver(this);
    castRequest.removeListener(_onCast);
    AppUpdate.available.removeListener(_offerUpdate);
    ProfileStore.instance.removeListener(_profileGone);
    if (currentCatalog.value == _catalog) currentCatalog.value = null;
    if (currentGuide.value == _guide.value) currentGuide.value = null;
    if (currentAiring.value == Airing.of(_source)) currentAiring.value = null;
    if (openPlaylist.value == _inTitleBar) openPlaylist.value = null;
    remoteSearch.removeListener(_showSearch);
    _updating.dispose();
    _guide.dispose();
    for (final s in _scopes) {
      s.dispose();
    }
    for (final n in _navNodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _openAccount() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => AccountScreen(
        playlist: widget.playlist,
        account: widget.account,
        onSwitchPlaylist: _switchPlaylist,
        onRefresh: _refresh,
      ),
    ),
  );

  void _switchPlaylist() => Navigator.of(context).popUntil((r) => r.isFirst);

  void _showSearch() {
    if (!remoteSearch.fromTitleBar) {
      // Typed on the phone: what is open over Home closes for the results, but not a player,
      // which someone may be watching
      if (nowPlaying.value != null) return;
      final home = ModalRoute.of(context);
      if (home != null && !home.isCurrent) Navigator.of(context).popUntil((route) => route == home);
      // The Search tab not built yet (it is on its first visit): built now, what was sent goes to
      // it once it listens
      if (!_visited.contains(HomeTab.search)) {
        final text = remoteSearch.text;
        setState(() => _visited.add(HomeTab.search));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) remoteSearch.send(text);
        });
      }
      return _select(HomeTab.search);
    }
    // Cleared in the title bar: only the Search tab empties, whatever is open stays
    if (remoteSearch.text.isEmpty) return;
    // Typed in the title bar: what is open over Home closes for the results, and the focus stays
    // in the bar for the rest of the typing
    final home = ModalRoute.of(context);
    if (home != null && !home.isCurrent) Navigator.of(context).popUntil((route) => route == home);
    if (_tab != HomeTab.search) setState(() => _tab = HomeTab.search);
  }

  /// Shows tab [i] and moves the focus into it: back to what was focused there before, or its
  /// first item. Without this a remote would stay on the button that switched tabs, now hidden.
  void _select(int i) {
    setState(() => _tab = i);
    // Touch users need no focus, and focusing a search field would pop the keyboard up
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Under another screen (lists updated from Settings): the remote stays there, not on a Home
      // nobody sees
      if (!mounted || _tab != i || ModalRoute.of(context)?.isCurrent == false) return;
      _focusTab(i);
    });
  }

  /// Into tab [i]: back to what was focused there, or where it starts.
  void _focusTab(int i) {
    final scope = _scopes[i];
    if (scope.focusedChild != null) {
      scope.focusedChild!.requestFocus();
    } else if (i == HomeTab.live && _liveEntry?.context != null) {
      _liveEntry!.requestFocus();
    } else {
      scope.requestFocus();
      scope.nextFocus();
    }
  }

  List<Widget>? _bodies;
  Object? _bodiesFor;

  /// The tabs, made anew only when what they show changes. The same widgets each time are not
  /// built again, so switching tabs does not rebuild every tab already opened.
  List<Widget> _tabBodies() {
    final now = (_source, _catalog, _generation, widget.playlist);
    if (_bodies case final bodies? when _bodiesFor == now) return bodies;
    _bodiesFor = now;
    return _bodies = [
      HomeTab(
        source: _source,
        catalog: _catalog,
        title: widget.playlist.name,
        onAccount: _openAccount,
        onProfiles: () => changeProfile(context, widget.playlist.id),
        onBrowse: _select,
      ),
      CatalogTab(kind: CatalogKind.movies, source: _source, catalog: _catalog),
      CatalogTab(kind: CatalogKind.series, source: _source, catalog: _catalog),
      LiveTab(source: _source, guide: _guide, onEntry: (n) => _liveEntry = n),
      SearchTab(catalog: _catalog, guide: _guide),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // The live format setting applies right away to new channel URLs
    switch (_source) {
      case final XtreamSource s:
        s.liveFormat = SettingsScope.of(context).liveFormat;
      case final CombinedSource s:
        s.liveFormat = SettingsScope.of(context).liveFormat;
    }
    final bodies = _tabBodies();
    final tabs = [
      (icon: Icons.home_rounded, label: l.home, body: bodies[0]),
      (icon: Icons.movie_rounded, label: l.movies, body: bodies[HomeTab.movies]),
      (icon: Icons.video_library_rounded, label: l.series, body: bodies[HomeTab.series]),
      (icon: Icons.live_tv_rounded, label: l.liveTv, body: bodies[HomeTab.live]),
      (icon: Icons.search_rounded, label: l.search, body: bodies[HomeTab.search]),
    ];
    _visited.add(_tab);
    // The key keeps every tab's state when the layout switches (window resized, tablet rotated)
    final body = IndexedStack(
      key: _bodyKey,
      index: _tab,
      children: [
        for (final (i, t) in tabs.indexed)
          ExcludeFocus(
            excluding: i != _tab,
            // Tabs out of sight neither animate nor play trailers
            child: TickerMode(
              enabled: i == _tab,
              child: FocusScope(
                node: _scopes[i],
                child: _visited.contains(i)
                    ? KeyedSubtree(key: ValueKey(_generation), child: t.body)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
      ],
    );
    // Back from another tab goes to Home; from Home, with the only playlist there is (opened by
    // itself at start), it asks before leaving: the screen behind is one never seen
    final only = (PlaylistStore.instance.playlists?.length ?? 0) <= 1;
    return PopScope(
      canPop: _tab == 0 && !only,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _tab != 0 ? _select(0) : _askToLeave();
      },
      child: LayoutBuilder(
        builder: (context, box) {
          if (isWide(context, width: box.maxWidth)) {
            return Scaffold(
              body: Stack(
                children: [
                  // The rail is to the tabs what a camera cutout is: they keep their content clear of
                  // it, while artwork goes under it and rows slide under it as they scroll
                  Positioned.fill(
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        padding: MediaQuery.paddingOf(context).copyWith(left: _SideNav.width(context)),
                        viewPadding: MediaQuery.viewPaddingOf(context).copyWith(left: _SideNav.width(context)),
                      ),
                      child: body,
                    ),
                  ),
                  // Over the content, so it can open without moving it
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: _SideNav(
                      items: [for (final t in tabs) (icon: t.icon, label: t.label)],
                      focusNodes: _navNodes,
                      selected: _tab,
                      onSelected: _select,
                      onEnterContent: () => _focusTab(_tab),
                      onAccount: _openAccount,
                      accountLabel: l.settings,
                    ),
                  ),
                ],
              ),
            );
          }
          return _narrow(tabs, body);
        },
      ),
    );
  }

  Future<void> _askToLeave() async {
    final l = context.l10n;
    final leave = await showConfirm(context, title: l.leaveAppQuestion, confirmLabel: l.leaveApp);
    if (!leave || !mounted) return;
    // Android hands the app back to the launcher; elsewhere the playlists are what is left
    if (isAndroid) {
      await SystemNavigator.pop();
    } else {
      Navigator.of(context).pop();
    }
  }

  Widget _narrow(List<({IconData icon, String label, Widget body})> tabs, Widget body) {
    return Scaffold(
      body: body,
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.black,
          border: Border(top: BorderSide(color: AppColors.stroke)),
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              for (final (i, t) in tabs.indexed)
                Expanded(
                  child: _NavItem(
                    icon: t.icon,
                    label: t.label,
                    selected: i == _tab,
                    compact: true,
                    onTap: () => _select(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SideNav extends StatefulWidget {
  const _SideNav({
    required this.items,
    required this.focusNodes,
    required this.selected,
    required this.onSelected,
    required this.onEnterContent,
    required this.onAccount,
    required this.accountLabel,
  });

  final List<({IconData icon, String label})> items;
  final List<FocusNode> focusNodes;
  final int selected;
  final ValueChanged<int> onSelected;
  final VoidCallback onEnterContent; // Right: back to where the focus was in the content
  final VoidCallback onAccount;
  final String accountLabel;

  /// Phones in landscape are wide but short: there the rail keeps to its icons, narrow, with every
  /// item in sight. It opens, names and all, over the content while a keyboard is on it; a touch
  /// gets the name on a long press, a screen reader always. TVs are short too, but keep the names
  /// under the icons, as a computer does, and never open.
  static bool short(BuildContext context) => isShort(context);

  /// A TV's 540 points: the names under the icons, a little closer together, so all of it fits.
  static bool low(BuildContext context) => !short(context) && MediaQuery.sizeOf(context).height < lowHeight;

  /// What the rail takes from the content (opened, it lies over it).
  static double width(BuildContext context) => (short(context) ? 72 : 108) + MediaQuery.paddingOf(context).left;

  @override
  State<_SideNav> createState() => _SideNavState();
}

class _SideNavState extends State<_SideNav> {
  var _open = false;
  final _settings = FocusNode(debugLabel: 'Settings');
  var _fromSettings = false; // Settings opened from here: back from it, the focus stays on it

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    // Right goes back to where the focus was in the content, not to what is level with the rail
    onKeyEvent: (_, e) {
      if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;
      widget.onEnterContent();
      return KeyEventResult.handled;
    },
    onFocusChange: (inside) {
      // Coming in from the content, the remote lands on the current section, not on whichever
      // item happens to be level with where it left; back from Settings, on Settings
      final nodes = widget.focusNodes;
      if (inside && _fromSettings && _settings.hasPrimaryFocus) {
        _fromSettings = false;
      } else if (inside && !nodes[widget.selected].hasPrimaryFocus) {
        nodes[widget.selected].requestFocus();
      }
      final open = inside && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
      if (open != _open) setState(() => _open = open);
    },
    child: _rail(context),
  );

  Widget _rail(BuildContext context) {
    final short = _SideNav.short(context), low = _SideNav.low(context), open = short && _open;
    final cutout = MediaQuery.paddingOf(context).left;
    // Items sit in the middle of the whole rail, cutout and all, so they look centered and still
    // keep clear of it; opened, they stay where they were and the names come in to their right
    final side = 10 + cutout / 2;
    final inset = EdgeInsets.only(left: side, right: open ? 10 : side);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      // A phone in landscape has its camera cutout on this side: the rail grows by it, so its
      // items keep their room
      width: open ? 220 + cutout : _SideNav.width(context),
      // See-through over the artwork and rows passing under it; solid once open, for its names
      decoration: BoxDecoration(
        color: open ? const Color(0xF2111111) : const Color(0xBF000000),
        boxShadow: open ? const [BoxShadow(color: Color(0xAA000000), blurRadius: 40)] : null,
      ),
      child: SafeArea(
        left: false,
        right: false,
        child: CustomScrollView(
          // Account sits at the bottom when there is room, and the rail scrolls when there is not
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: short ? 8 : (low ? 8 : 20)),
                  if (!short) ...[const Center(child: AppLogo(size: 58)), SizedBox(height: low ? 12 : 28)],
                  for (final (i, t) in widget.items.indexed)
                    Padding(
                      padding: inset.copyWith(top: short ? 3 : 4, bottom: short ? 3 : 4),
                      child: _NavItem(
                        focusNode: widget.focusNodes[i],
                        icon: t.icon,
                        label: t.label,
                        selected: i == widget.selected,
                        iconOnly: short,
                        named: open,
                        dense: low,
                        onTap: () => widget.onSelected(i),
                      ),
                    ),
                  const Spacer(),
                  // While something casts, the way back to its remote
                  ValueListenableBuilder(
                    valueListenable: ChromecastService.instance.current,
                    builder: (context, cast, _) => cast == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: inset.copyWith(top: 4, bottom: 4),
                            child: _NavItem(
                              icon: Icons.cast_connected_rounded,
                              label: cast.device.name,
                              selected: false,
                              iconOnly: short,
                              named: open,
                              dense: low,
                              onTap: () =>
                                  Navigator.of(context)
                                      .push(MaterialPageRoute<void>(builder: (_) => const CastScreen())),
                            ),
                          ),
                  ),
                  Padding(
                    padding: inset.copyWith(top: 4, bottom: short ? 8 : 16),
                    child: _NavItem(
                      focusNode: _settings,
                      icon: Icons.settings_rounded,
                      label: widget.accountLabel,
                      selected: false,
                      iconOnly: short,
                      named: open,
                      dense: low,
                      onTap: () {
                        _fromSettings = true;
                        widget.onAccount();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
    this.dense = false,
    this.iconOnly = false,
    this.named = false,
    this.focusNode,
  });

  final IconData icon;
  final String label;
  final bool selected, compact;

  /// A little closer to the next item (a TV's short rail).
  final bool dense;

  /// Just the icon, on a light block when selected; [named] adds the name beside it (the rail
  /// opened). Without it the name is for long presses and screen readers.
  final bool iconOnly, named;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => iconOnly ? _block() : _stacked();

  Widget _block() {
    final color = selected ? AppColors.black : (named ? AppColors.muted : AppColors.subtle);
    return Tooltip(
      message: named ? '' : label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        selected: selected,
        button: true,
        excludeSemantics: true,
        child: Focusable(
          focusNode: focusNode,
          onTap: onTap,
          radius: AppRadius.card,
          scale: 1.03,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 44,
            decoration: BoxDecoration(
              color: selected ? AppColors.text : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            // The icon stays where it was as the rail opens; the name comes in beside it
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: double.infinity,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 14),
                    Icon(icon, size: 24, color: color),
                    if (named) ...[
                      const SizedBox(width: 14),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: color,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stacked() => Focusable(
    focusNode: focusNode,
    onTap: onTap,
    radius: AppRadius.card,
    scale: 1.03,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: EdgeInsets.symmetric(vertical: compact ? 6 : (dense ? 9 : 12)),
      color: selected && !compact ? AppColors.surfaceHigh : Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 24 : 26, color: selected ? AppColors.text : AppColors.muted), // over artwork
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 11 : 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? AppColors.text : AppColors.muted,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Live TV: categories on the left (or as chips on phones) and the channels of the selected one.
class LiveTab extends StatefulWidget {
  const LiveTab({super.key, required this.source, required this.guide, this.onEntry});

  final ContentSource source;
  final ValueNotifier<EpgGuide> guide;

  /// Reports the selected category's focus node: where a remote enters the tab.
  final ValueChanged<FocusNode>? onEntry;

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> with AutomaticKeepAliveClientMixin {
  String? _selected;
  Timer? _tick;
  // One stable node per category row, so the focus never jumps between rows on a rebuild
  final _rowFocus = <String, FocusNode>{};

  FocusNode _focusOf(String id) => _rowFocus.putIfAbsent(id, () => FocusNode(debugLabel: 'category $id'));

  final _channelsKey = GlobalKey();

  /// Left from a channel in the grid's first column: to the category they are in, not to whichever
  /// row of the list is level with it.
  KeyEventResult _leftToCategory(KeyEvent e, String selected) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.arrowLeft) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus;
    final box = _channelsKey.currentContext?.findRenderObject();
    if (focused == null || box is! RenderBox || !box.hasSize) return KeyEventResult.ignored;
    final left = box.localToGlobal(Offset.zero).dx;
    // Within a channel's width of the grid's left edge: the first column
    if (focused.rect.left - left > focused.rect.width * 0.6) return KeyEventResult.ignored;
    _focusOf(selected).requestFocus();
    return KeyEventResult.handled;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Keeps "on now" and its progress bar current
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final n in _rowFocus.values) {
      n.dispose();
    }
    super.dispose();
  }

  /// [id] on screen, and where Live TV opens next time in this playlist, for this profile.
  void _choose(String id) {
    setState(() => _selected = id);
    final lib = LibraryScope.maybeOf(context);
    if (lib != null) SettingsScope.maybeOf(context)?.keepLiveCategory(lib.playlistId, lib.profileId, id);
  }

  void _openGuide(List<Category> cats, String selected) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          GuideScreen(source: widget.source, guide: widget.guide, categories: cats, initialCategory: selected),
    ),
  );

  Widget _header(BuildContext context, List<Category> cats, String selected) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.liveTv, style: Theme.of(context).textTheme.headlineMedium),
            // What OK held does is shown nowhere else; a mouse right-clicks, a phone holds its finger
            if (isTv)
              Text(context.l10n.holdOkChannelHint, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          ],
        ),
      ),
      IconButton(
        tooltip: context.l10n.tvGuide,
        icon: const Icon(Icons.view_timeline_rounded),
        onPressed: () => _openGuide(cats, selected),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      bottom: false,
      // Decided on the space actually given, not the window: they differ while the screen rotates
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = isWide(context, width: box.maxWidth, min: 640);
          return AsyncView<List<Category>>(
            load: widget.source.liveCategories,
            isEmpty: (c) => c.isEmpty,
            loading: const Center(child: ListLoading()),
            builder: (context, provided) {
              // Favorites and Recently watched first, then the provider's
              final lib = LibraryScope.maybeOf(context);
              final cats = [...liveGroups(context.l10n, lib, widget.source), ...provided];
              final settings = SettingsScope.maybeOf(context);
              final last = lib == null ? null : settings?.lastLiveCategory(lib.playlistId, lib.profileId);
              final selected = switch (_selected ?? last) {
                final id? when cats.any((c) => c.id == id) => id,
                _ => cats.first.id,
              };
              if (wide) widget.onEntry?.call(_focusOf(selected));
              final channels = KeyedSubtree(
                key: ValueKey(selected),
                child: AsyncView<List<LiveChannel>>(
                  load: () => liveChannelsIn(widget.source, lib, selected),
                  isEmpty: (l) => l.isEmpty,
                  loading: const Center(child: ListLoading()),
                  builder: (context, list) => ValueListenableBuilder<EpgGuide>(
                    valueListenable: widget.guide,
                    builder: (context, guide, _) => wide
                        ? _ChannelGrid(source: widget.source, channels: list, guide: guide)
                        : _ChannelList(source: widget.source, channels: list, guide: guide),
                  ),
                ),
              );
              if (!wide) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 4), child: _header(context, cats, selected)),
                    SizedBox(
                      height: chipRowHeight(context),
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        children: [
                          for (final c in cats)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: AppChip(
                                label: categoryLabel(context.l10n, c.name),
                                selected: c.id == selected,
                                onTap: () => _choose(c.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(child: channels),
                  ],
                );
              }
              return Row(
                children: [
                  SizedBox(
                    width: isShort(context) ? 240 : 300,
                    // The header stays put while the categories scroll, so the guide is always one tap away
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 20, 8, 8),
                          child: _header(context, cats, selected),
                        ),
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 0, 8, 20),
                            children: [
                              for (final c in cats)
                                _CategoryRow(
                                  name: categoryLabel(context.l10n, c.name),
                                  focusNode: _focusOf(c.id),
                                  selected: c.id == selected,
                                  onTap: () => _choose(c.id),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Focus(
                      key: _channelsKey,
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: (_, e) => _leftToCategory(e, selected),
                      child: channels,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.name, required this.selected, required this.onTap, this.focusNode});

  final String name;
  final bool selected;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Focusable(
      focusNode: focusNode,
      onTap: onTap,
      selected: selected,
      radius: 12,
      scale: 1.02,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: selected ? Colors.white.withValues(alpha: 0.08) : Colors.transparent),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 4,
              height: 18,
              decoration: BoxDecoration(
                color: selected ? AppColors.text : null,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppColors.text : AppColors.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChannelGrid extends StatelessWidget {
  const _ChannelGrid({required this.source, required this.channels, required this.guide});

  final ContentSource source;
  final List<LiveChannel> channels;
  final EpgGuide guide;

  @override
  Widget build(BuildContext context) => GridView.builder(
    scrollCacheExtent: listReadAhead,
    padding: EdgeInsets.fromLTRB(16, isShort(context) ? 16 : 72, 24, 24), // a phone on its side has no height to spare
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 220,
      childAspectRatio: 1.0,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
    ),
    itemCount: channels.length,
    itemBuilder: (context, i) {
      final c = channels[i];
      return Focusable(
        autofocus: i == 0,
        onTap: () => playChannel(context, source, channels, i),
        onLongPress: () => showChannelGuide(context, source, c, guide: guide),
        child: ColoredBox(
          color: AppColors.surface,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (c.number != null)
                      Text(
                        '${c.number}',
                        style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
                      ),
                    const Spacer(),
                    // Said to a screen reader too, not only shown
                    if (LibraryScope.maybeOf(context)?.isFavorite(MediaRef.channel(c)) ?? false)
                      Icon(
                        Icons.favorite_rounded,
                        size: 16,
                        color: AppColors.text,
                        semanticLabel: context.l10n.inMyList,
                      ),
                    if (c.hasArchive) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.history_rounded,
                        size: 18,
                        color: AppColors.text,
                        semanticLabel: context.l10n.catchupDays(c.archiveDays),
                      ),
                    ],
                  ],
                ),
                Expanded(
                  child: Center(
                    child: NetImage(c.icon ?? guide.iconOf(c.epgId), fit: BoxFit.contain, icon: Icons.tv_rounded),
                  ),
                ),
                const SizedBox(height: 8),
                // What is on: the guide's, or the provider's for this channel alone (Airing)
                ListenableBuilder(
                  listenable: Airing.of(source),
                  builder: (context, _) {
                    final now = Airing.of(source).now(c, guide);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.name,
                          maxLines: now == null ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        if (now != null) ...[const SizedBox(height: 6), NowOnAir(now)],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({required this.source, required this.channels, required this.guide});

  final ContentSource source;
  final List<LiveChannel> channels;
  final EpgGuide guide;

  @override
  Widget build(BuildContext context) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
    itemCount: channels.length,
    separatorBuilder: (_, _) => const SizedBox(height: 10),
    itemBuilder: (context, i) {
      final c = channels[i];
      return Focusable(
        onTap: () => playChannel(context, source, channels, i),
        onLongPress: () => showChannelGuide(context, source, c, guide: guide),
        scale: 1.02,
        child: ColoredBox(
          color: AppColors.surface,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Container(
                  width: 64,
                  height: 48,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(10)),
                  child: NetImage(c.icon ?? guide.iconOf(c.epgId), fit: BoxFit.contain, icon: Icons.tv_rounded),
                ),
                const SizedBox(width: 14),
                Expanded(
                  // What is on: the guide's, or the provider's for this channel alone (Airing)
                  child: ListenableBuilder(
                    listenable: Airing.of(source),
                    builder: (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (Airing.of(source).now(c, guide) case final now?)
                          Padding(padding: const EdgeInsets.only(top: 4), child: NowOnAir(now))
                        else if (c.hasArchive)
                          Text(
                            context.l10n.catchupDays(c.archiveDays),
                            style: const TextStyle(color: AppColors.text, fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                ),
                if (LibraryScope.maybeOf(context)?.isFavorite(MediaRef.channel(c)) ?? false) ...[
                  Icon(Icons.favorite_rounded, size: 16, color: AppColors.text, semanticLabel: context.l10n.inMyList),
                  const SizedBox(width: 10),
                ],
                if (c.number != null)
                  Text(
                    '${c.number}',
                    style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
                  ),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      );
    },
  );
}
