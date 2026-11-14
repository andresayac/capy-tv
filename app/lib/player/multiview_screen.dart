import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/catalog.dart';
import '../data/library.dart';
import '../data/profiles.dart';
import '../data/settings.dart';
import '../data/watch_time.dart';
import '../device.dart';
import '../remote/remote_input.dart';
import '../ui/common.dart';
import '../ui/theme.dart';
import 'play.dart';
import 'props.dart';

/// Several live channels at once, up to four, from a channel's player (its Multiview button): one
/// plays its sound, the others only their picture. OK or a tap gives a channel the sound; the bar
/// below changes, removes, or opens in full screen the one that has it. Each channel is a player
/// of its own and so one of the provider's connections: past what the account allows, a channel
/// shows as unavailable.
class MultiviewScreen extends StatefulWidget {
  const MultiviewScreen({super.key, required this.first, required this.channels});

  final PlayItem first;

  /// The channels the player went through: what can be added without a catalog, and the queue a
  /// channel opened in full screen zaps through.
  final List<PlayItem> channels;

  /// As many as the device can decode at once: a 1 GB stick two, the rest more.
  static int get most => switch (deviceTier) {
    DeviceTier.low => 2,
    DeviceTier.medium => 3,
    DeviceTier.high => 4,
  };

  @override
  State<MultiviewScreen> createState() => _MultiviewScreenState();
}

/// A channel on screen, with its own player.
class _Tile {
  _Tile(this.item, this.engine);

  final PlayItem item;
  final PlaybackEngine engine;
  var started = false, failed = false;
  Timer? watchdog;
  // A channel that stopped moving once it played: opened again, after a pause that grows
  Duration lastPosition = Duration.zero;
  DateTime moved = DateTime.now();
  var reopens = 0;
  DateTime? playingSince; // since it last started
  final subs = <StreamSubscription>[];
  final focus = FocusNode();

  Player get player => engine.player;

  void dispose() {
    watchdog?.cancel();
    for (final s in subs) {
      s.cancel();
    }
    focus.dispose();
    unawaited(engine.dispose()); // as in the player: a decoder stuck on a bad stream must not hold the screen
  }
}

class _MultiviewScreenState extends State<MultiviewScreen> {
  final _tiles = <_Tile>[];
  var _sound = 0; // the tile whose sound plays
  Timer? _stallCheck;
  AppLifecycleListener? _lifecycle;

  // A profile with a time per day: counted here too, as in the player
  Duration? _timeLeft;
  var _unsaved = Duration.zero;
  Timer? _clock;

  /// Live pictures that do not move for this long dropped: they are opened again.
  static const _stallLimit = Duration(seconds: 12);
  static const _maxReopens = 5;

  /// What can be added: the catalog's channels (for this profile), else the player's.
  late final List<PlayItem> _choices = () {
    final catalog = currentCatalog.value;
    final live = catalog?.loaded?.live;
    if (catalog == null || live == null || live.isEmpty) return widget.channels;
    final source = catalog.source;
    return [
      for (final c in live)
        PlayItem(url: source.liveUrl(c), title: c.name, ref: MediaRef.channel(c)).withHeaders(source.headersFor),
    ];
  }();

  @override
  void initState() {
    super.initState();
    // The settings (decoder, languages) come from above, once this is in the tree
    WidgetsBinding.instance.addPostFrameCallback((_) => _add(widget.first));
    _stallCheck = Timer.periodic(const Duration(seconds: 2), (_) => _checkStalls());
    WatchTime.left(ProfileStore.instance.current).then((left) {
      if (!mounted || left == null) return;
      _timeLeft = left;
      _clock = Timer.periodic(const Duration(seconds: 1), (_) => _countTime());
    });
    // Away, the provider's connections go; back, each channel is live again rather than an old buffer
    _lifecycle = AppLifecycleListener(
      onPause: () {
        for (final t in _tiles) {
          t.watchdog?.cancel();
          unawaited(t.player.stop());
        }
      },
      onResume: () {
        for (final t in _tiles) {
          t
            ..started = false
            ..failed = false
            ..reopens = 0;
          unawaited(_open(t));
        }
        if (mounted) setState(() {});
      },
    );
  }

  void _checkStalls() {
    if (!mounted) return;
    final now = DateTime.now();
    for (final t in _tiles) {
      if (!t.started || t.failed) continue;
      final p = t.player.state.position;
      if (p > t.lastPosition) {
        t
          ..lastPosition = p
          ..moved = now;
        // Playing a whole minute since it came back: the next drop starts the count afresh
        final since = t.playingSince;
        if (t.reopens > 0 && since != null && now.difference(since) > const Duration(minutes: 1)) t.reopens = 0;
      } else if (now.difference(t.moved) > _stallLimit) {
        _reopen(t);
      }
    }
  }

  /// [tile] froze or ended once it played: opened again, with a growing pause, a few times.
  void _reopen(_Tile tile) {
    if (tile.reopens >= _maxReopens) {
      setState(() => tile.failed = true);
      unawaited(tile.player.stop());
      return;
    }
    final wait = Duration(seconds: 1 << tile.reopens++);
    setState(() => tile.started = false);
    tile.moved = DateTime.now().add(wait + const Duration(seconds: 20)); // the open's own watchdog meanwhile
    Future<void>.delayed(wait, () {
      if (mounted && _tiles.contains(tile)) unawaited(_open(tile));
    });
  }

  /// A second of watching, while any channel plays: said at 5 and 1 minute left, as the player
  /// does; at none, the channel with the sound goes to the usual player, which stops it there and
  /// offers more time with the PIN.
  void _countTime() {
    final left = _timeLeft;
    if (!mounted || left == null || !_tiles.any((t) => t.started && t.player.state.playing)) return;
    _timeLeft = left - const Duration(seconds: 1);
    _unsaved += const Duration(seconds: 1);
    for (final m in const [5, 1]) {
      if (_timeLeft == Duration(minutes: m)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.timeLeftToday(m))));
      }
    }
    if (_unsaved >= const Duration(seconds: 15)) _noteTime();
    if (_timeLeft! <= Duration.zero) {
      _clock?.cancel();
      _noteTime();
      unawaited(_fullScreen());
    }
  }

  void _noteTime() {
    if (_unsaved == Duration.zero) return;
    WatchTime.add(ProfileStore.instance.current.id, _unsaved);
    _unsaved = Duration.zero;
  }

  @override
  void dispose() {
    _clock?.cancel();
    _noteTime();
    _stallCheck?.cancel();
    _lifecycle?.dispose();
    for (final t in _tiles) {
      t.dispose();
    }
    sayStopped(this);
    super.dispose();
  }

  /// Opens [item] in a new tile, or in the tile at [at] in place of its channel.
  Future<void> _add(PlayItem item, {int? at}) async {
    final engine = await PlaybackEngine.start(SettingsScope.maybeOf(context));
    if (!mounted) return unawaited(engine.dispose());
    final tile = _Tile(item, engine);
    setState(() {
      if (at != null && at < _tiles.length) {
        _tiles[at].dispose();
        _tiles[at] = tile;
      } else {
        _tiles.add(tile);
      }
    });
    // Something plays: no screensaver
    sayPlaying(this, (title: _tiles[_sound].item.title, subtitle: null));
    // The remote on the channel just added, rather than lost with the + that was there
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _tiles.contains(tile)) tile.focus.requestFocus();
    });
    await _open(tile);
  }

  Future<void> _open(_Tile tile) async {
    for (final s in tile.subs) {
      unawaited(s.cancel());
    }
    tile.subs
      ..clear()
      ..add(
        tile.player.stream.position.listen((p) {
          if (tile.started || p < const Duration(milliseconds: 500) || !mounted) return;
          // Started once there is a picture: time going by on a black tile (a device out of
          // decoders) is a channel that did not open. Unless it has no picture at all (a radio)
          final st = tile.player.state;
          bool real(String id) => id != 'auto' && id != 'no';
          final soundOnly = !st.tracks.video.any((v) => real(v.id)) && st.tracks.audio.any((a) => real(a.id));
          if ((st.width ?? 0) == 0 && !soundOnly) return;
          tile.watchdog?.cancel();
          tile.playingSince = DateTime.now();
          setState(() => tile.started = true);
        }),
      )
      // Before it has a picture, an error is a channel that does not open
      ..add(tile.player.stream.error.listen((_) => (tile.player.state.width ?? 0) == 0 ? _fail(tile) : null))
      // A live channel does not end: it dropped
      ..add(tile.player.stream.completed.listen((done) => done && tile.started && mounted ? _reopen(tile) : null));
    tile.watchdog?.cancel();
    tile.watchdog = Timer(const Duration(seconds: 20), () => _fail(tile));
    tile
      ..lastPosition = Duration.zero
      ..moved = DateTime.now().add(const Duration(seconds: 20));
    // A tile is a small picture of a live channel: little kept ahead and nothing behind, no
    // subtitles; only the one heard decodes its sound (see _hear)
    await setPlayerProperty(tile.player, 'demuxer-max-bytes', '16MiB');
    await setPlayerProperty(tile.player, 'demuxer-max-back-bytes', '0');
    await setPlayerProperty(tile.player, 'sid', 'no');
    _hear();
    await tile.player.open(Media(tile.item.url, httpHeaders: tile.item.headers));
  }

  void _fail(_Tile tile) {
    if (!mounted || tile.started || tile.failed || !_tiles.contains(tile)) return;
    setState(() => tile.failed = true);
    unawaited(tile.player.stop()); // lets go of the provider's connection
  }

  /// Only the tile with the sound is heard, and only it decodes its audio.
  void _hear() {
    for (var i = 0; i < _tiles.length; i++) {
      final heard = i == _sound;
      _tiles[i].player.setVolume(heard ? 100 : 0);
      unawaited(_tiles[i].player.setAudioTrack(heard ? AudioTrack.auto() : AudioTrack.no()));
    }
  }

  /// Gives the tile at [i] the sound; one that did not open is tried again.
  void _select(int i) {
    final tile = _tiles[i];
    setState(() {
      _sound = i;
      if (tile.failed) tile.failed = false;
    });
    if (!tile.started && tile.watchdog?.isActive != true) unawaited(_open(tile));
    _hear();
  }

  Future<PlayItem?> _pick() => showDialog<PlayItem>(
    context: context,
    builder: (_) => _ChannelPicker(channels: _choices, showing: {for (final t in _tiles) t.item.url}),
  );

  Future<void> _addChannel() async {
    final item = await _pick();
    if (item != null && mounted && _tiles.length < MultiviewScreen.most) await _add(item);
  }

  Future<void> _changeChannel() async {
    final at = _sound;
    final item = await _pick();
    if (item != null && mounted) await _add(item, at: at);
  }

  void _remove() {
    if (_tiles.length < 2) return;
    setState(() {
      _tiles.removeAt(_sound).dispose();
      _sound = 0;
    });
    _hear();
    _tiles.first.focus.requestFocus();
  }

  /// The channel with the sound in the usual player, alone, zapping through the channels it came
  /// with.
  Future<void> _fullScreen() async {
    final item = _tiles[_sound].item;
    final index = widget.channels.indexWhere((c) => c.url == item.url);
    // Let go of every channel first: the provider would see this one asked for twice at once
    _stallCheck?.cancel();
    for (final t in _tiles) {
      t.watchdog?.cancel();
      for (final s in t.subs) {
        unawaited(s.cancel());
      }
    }
    await Future.wait([for (final t in _tiles) t.player.stop()]);
    if (!mounted) return;
    unawaited(playQueue(context, index >= 0 ? widget.channels : [item], index: index >= 0 ? index : 0, replace: true));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cells = <Widget>[
      for (var i = 0; i < _tiles.length; i++) _cell(i),
      if (_tiles.length < MultiviewScreen.most)
        _Frame(
          key: const ValueKey('add'),
          autofocus: _tiles.isEmpty,
          onTap: _addChannel,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add_rounded, size: 40),
                const SizedBox(height: 8),
                Text(l.multiviewAdd, style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
    ];
    // Two side by side; three or four in two rows
    final rows = cells.length <= 2 ? [cells] : [cells.sublist(0, 2), cells.sublist(2)];
    return Scaffold(
      backgroundColor: AppColors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Column(
                children: [
                  for (final row in rows)
                    Expanded(
                      child: Row(
                        children: [
                          for (final c in row) Expanded(child: c),
                          if (row.length == 1) const Spacer(),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  // A remote and a phone have Back; a computer gets a button for it
                  if (!isTv)
                    SecondaryButton(
                      icon: Icons.arrow_back_rounded,
                      label: MaterialLocalizations.of(context).backButtonTooltip,
                      onPressed: () => Navigator.maybePop(context),
                    ),
                  if (_tiles.isNotEmpty) ...[
                    SecondaryButton(
                      icon: Icons.swap_horiz_rounded,
                      label: l.multiviewChange,
                      onPressed: _changeChannel,
                    ),
                    if (_tiles.length > 1)
                      SecondaryButton(icon: Icons.close_rounded, label: l.multiviewRemove, onPressed: _remove),
                    SecondaryButton(icon: Icons.fullscreen_rounded, label: l.multiviewFull, onPressed: _fullScreen),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(int i) {
    final l = context.l10n;
    final tile = _tiles[i];
    final sound = i == _sound;
    return _Frame(
      key: ObjectKey(tile), // its own as cells come and go: the focus stays with it
      focusNode: tile.focus,
      autofocus: i == 0,
      selected: sound,
      onTap: () => _select(i),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Video(
            key: ObjectKey(tile.engine.controller),
            controller: tile.engine.controller,
            controls: NoVideoControls,
            fill: AppColors.black,
          ),
          if (tile.failed)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CapyStatus(mood: CapyMood.video, size: 48),
                    const SizedBox(height: 8),
                    Text(l.channelUnavailable, textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          else if (!tile.started)
            const Center(child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5))),
          // Which channel, and the one heard
          Positioned(
            left: 10,
            bottom: 10,
            right: 10,
            child: Align(
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(color: AppColors.scrim, borderRadius: BorderRadius.circular(8)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (sound) ...[const Icon(Icons.volume_up_rounded, size: 16), const SizedBox(width: 6)],
                      Flexible(
                        child: Text(
                          tile.item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A cell of the grid: focusable by a remote, outlined when its sound is the one heard.
class _Frame extends StatelessWidget {
  const _Frame({
    super.key,
    required this.child,
    required this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final bool autofocus, selected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: Focusable(
      focusNode: focusNode,
      autofocus: autofocus,
      scale: 1,
      radius: 10,
      onTap: onTap,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? AppColors.text : AppColors.stroke, width: selected ? 3 : 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ColoredBox(color: AppColors.surface, child: child),
        ),
      ),
    ),
  );
}

/// The channels to add, with a search.
class _ChannelPicker extends StatefulWidget {
  const _ChannelPicker({required this.channels, required this.showing});

  final List<PlayItem> channels;
  final Set<String> showing; // already on screen

  @override
  State<_ChannelPicker> createState() => _ChannelPickerState();
}

class _ChannelPickerState extends State<_ChannelPicker> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final q = _query.trim().toLowerCase();
    final list = [
      for (final c in widget.channels)
        if (!widget.showing.contains(c.url) && (q.isEmpty || c.title.toLowerCase().contains(q))) c,
    ];
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: AppColors.surfaceHigh,
      child: SizedBox(
        width: 520,
        height: size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: l.search),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? Center(
                      child: CapyMessage(mood: CapyMood.empty, text: l.noResults),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      itemExtent: 60,
                      itemCount: list.length,
                      itemBuilder: (_, i) => Focusable(
                        autofocus: i == 0, // a remote starts on the list, not in the search box
                        scale: 1,
                        radius: 10,
                        onTap: () => Navigator.pop(context, list[i]),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              SizedBox.square(
                                dimension: 40,
                                child: NetImage(list[i].ref?.image, fit: BoxFit.contain, icon: Icons.live_tv_rounded),
                              ),
                              const SizedBox(width: 14),
                              Expanded(child: Text(list[i].title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
