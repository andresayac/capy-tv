// The player's side panels: audio and subtitles, speed, the episodes or channels, its settings,
// and the subtitle choices they make. A part of player_screen.dart.
part of 'player_screen.dart';

/// Solid panel sliding in from the right (full width on narrow screens).
class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: Alignment.centerRight,
      child: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: SizedBox(
          width: w < 560 ? w - 32 : 400,
          child: Panel(
            color: AppColors.surface,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      ),
    );
  }
}

/// One selectable row in a side panel.
class _Option extends StatelessWidget {
  const _Option({
    required this.label,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
    this.detail,
    this.oneLine = false,
  });

  final String label;
  final String? detail; // a second line: what is on a channel now
  final bool selected, autofocus;

  /// Its label on one line, cut with an ellipsis: in a list whose rows all have one height.
  final bool oneLine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Focusable(
      autofocus: autofocus,
      selected: selected,
      radius: 14,
      scale: 1.02,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: detail == null ? 13 : 9),
        color: selected ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: detail == null && !oneLine ? null : 1,
                    overflow: detail == null && !oneLine ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? AppColors.text : AppColors.muted,
                    ),
                  ),
                  if (detail case final d?)
                    Text(
                      d,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: AppColors.subtle),
                    ),
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.text : null,
                border: selected ? null : Border.all(color: AppColors.subtle, width: 1.5),
              ),
              child: selected ? const Icon(Icons.check_rounded, size: 14, color: AppColors.black) : null,
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _panelTitle(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
  child: Semantics(header: true, child: Text(text, style: Theme.of(context).textTheme.titleLarge)),
);

class _TracksPanel extends StatefulWidget {
  const _TracksPanel({required this.player, required this.direct});

  final Player player;
  final bool direct; // Android's hardware decoder: see chooseSubtitle

  @override
  State<_TracksPanel> createState() => _TracksPanelState();
}

class _TracksPanelState extends State<_TracksPanel> {
  Player get player => widget.player;
  String aid = '', sid = '';
  var _pictureHidden = false; // subtitles chosen that are pictures, and cannot show

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final sel = await selectedTracks(player);
    if (!mounted) return;
    setState(() {
      aid = sel.audio;
      sid = sel.sub;
    });
  }

  Future<void> _pick(Future<void> Function() action) async {
    await action();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // On the web the player reports nothing (a <video> has no track list): movi read the file's
    // own, and those are what there is to choose.
    final fromPlayer = realTracks(player.state.tracks.audio);
    final audio = fromPlayer.isNotEmpty ? fromPlayer : moviAudioTracks(player);
    final subs = realTracks(player.state.tracks.subtitle);
    // An HLS channel's qualities (or a file's video streams): left to the player by default, which
    // picks as the device allows (hls-bitrate), or chosen by hand
    final video = realTracks(player.state.tracks.video);
    final vid = player.state.track.video.id;
    return ListView(
      shrinkWrap: true,
      children: [
        if (video.length > 1) ...[
          _panelTitle(context, l.quality),
          _Option(
            label: l.automatic,
            selected: vid == 'auto' || !video.any((t) => t.id == vid),
            onTap: () => _pick(() => player.setVideoTrack(VideoTrack.auto())),
          ),
          for (final (i, t) in video.indexed)
            _Option(
              label: _qualityOf(l, t, i),
              selected: t.id == vid,
              onTap: () => _pick(() => player.setVideoTrack(t)),
            ),
          const SizedBox(height: 18),
        ],
        _panelTitle(context, l.audio),
        if (audio.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(l.notAvailable, style: const TextStyle(color: AppColors.muted)),
          ),
        for (final (i, t) in audio.indexed)
          _Option(
            label: niceTrack(l, t, i),
            selected: t.id == aid,
            autofocus: t.id == aid,
            onTap: () => _pick(() => chooseAudio(player, t)),
          ),
        if (audio.isNotEmpty) _Delay(player: player, property: 'audio-delay', label: l.audioDelay, hint: l.delayHint),
        const SizedBox(height: 18),
        _panelTitle(context, l.subtitles),
        _Option(
          label: l.off,
          selected: sid.isEmpty || sid == 'no',
          onTap: () => _pick(() async {
            setState(() => _pictureHidden = false);
            await player.setSubtitleTrack(SubtitleTrack.no());
          }),
        ),
        for (final (i, t) in subs.indexed)
          _Option(
            label: isPictureSubtitle(t) ? '${niceTrack(l, t, i)} · ${l.subtitlePicture}' : niceTrack(l, t, i),
            selected: t.id == sid,
            onTap: () => _pick(() async {
              final shown = await chooseSubtitle(player, t, direct: widget.direct);
              if (mounted) setState(() => _pictureHidden = !shown);
            }),
          ),
        if (_pictureHidden)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Text(l.subtitlePictureHidden, style: const TextStyle(color: AppColors.muted, height: 1.4)),
            ),
          ),
        if (subs.isNotEmpty) ...[
          _Delay(player: player, property: 'sub-delay', label: l.subtitleDelay, hint: l.delayHint),
          if (SettingsScope.maybeOf(context) case final settings?) ...[
            _Setting(
              icon: Icons.format_size_rounded,
              title: l.subtitleSize,
              value: '${settings.subtitleScale} %',
              choices: [
                for (final (scale, label) in const [(75, 'S'), (100, 'M'), (125, 'L'), (150, 'XL'), (200, 'XXL')])
                  _Choice(label, settings.subtitleScale == scale, () => settings.set(subtitleScale: scale)),
              ],
            ),
            _Setting(
              icon: Icons.subtitles_outlined,
              title: l.subtitleBackground,
              value: settings.subtitleBackground ? l.settingOn : l.settingOff,
              choices: [
                for (final on in const [false, true])
                  _Choice(
                    on ? l.settingOn : l.settingOff,
                    settings.subtitleBackground == on,
                    () => settings.set(subtitleBackground: on),
                  ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

/// A sharp black line around subtitle text: shadows with no blur, all the way round.
const _subtitleOutline = [
  Shadow(offset: Offset(-1.5, -1.5)),
  Shadow(offset: Offset(0, -1.5)),
  Shadow(offset: Offset(1.5, -1.5)),
  Shadow(offset: Offset(-1.5, 0)),
  Shadow(offset: Offset(1.5, 0)),
  Shadow(offset: Offset(-1.5, 1.5)),
  Shadow(offset: Offset(0, 1.5)),
  Shadow(offset: Offset(1.5, 1.5)),
];

/// Subtitles that are pictures (Blu-ray's, DVD's, DVB's): no text for the app to draw, so mpv
/// draws them on the picture itself.
bool isPictureSubtitle(SubtitleTrack t) =>
    const {'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle', 'xsub'}.contains(t.codec?.toLowerCase());

/// Picks [t]; one that is a picture is drawn by mpv on the picture, a text one by the app (only
/// one of them at once, or text would show twice). False when a picture cannot show: Android's
/// hardware decoder draws straight to the screen, where nothing can draw over it ([direct]).
Future<bool> chooseSubtitle(Player player, SubtitleTrack t, {required bool direct}) async {
  await player.setSubtitleTrack(t);
  final picture = isPictureSubtitle(t);
  await setPlayerProperty(player, 'sub-visibility', picture ? 'yes' : 'no');
  _drawsPictures[player] = picture;
  return !picture || !direct;
}

/// Players that mpv draws subtitles on, as [chooseSubtitle] left them: the next title opened goes
/// back to the app's own text, or a text track would show twice.
final _drawsPictures = Expando<bool>();

Future<void> _textSubtitlesAgain(Player player) async {
  if (_drawsPictures[player] != true) return;
  _drawsPictures[player] = false;
  await setPlayerProperty(player, 'sub-visibility', 'no');
}

/// A quality as people know them: "1080p · 5.2 Mb/s"; else as any other track.
String _qualityOf(AppLocalizations l, VideoTrack t, int index) {
  final parts = [
    if (t.h case final h? when h > 0) '${h}p',
    if (t.bitrate case final b? when b > 0) '${(b / 1e6).toStringAsFixed(1)} Mb/s',
  ];
  return parts.isEmpty ? niceTrack(l, t, index) : parts.join(' · ');
}

/// Moves the sound or the subtitles against the picture, a tenth of a second at a time, for a
/// stream that sends them out of step. For this session ([property]: mpv's "audio-delay" or
/// "sub-delay", in seconds; more is later).
class _Delay extends StatefulWidget {
  const _Delay({required this.player, required this.property, required this.label, required this.hint});

  final Player player;
  final String property, label, hint;

  @override
  State<_Delay> createState() => _DelayState();
}

class _DelayState extends State<_Delay> {
  var _seconds = 0.0;

  @override
  void initState() {
    super.initState();
    playerProperty(widget.player, widget.property).then((v) {
      if (mounted) setState(() => _seconds = double.tryParse(v) ?? 0);
    });
  }

  Future<void> _set(double seconds) async {
    final s = (seconds * 10).round() / 10; // no 0.30000000000000004
    await setPlayerProperty(widget.player, widget.property, '$s');
    if (mounted) setState(() => _seconds = s);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 10, 0, 4),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              Text(widget.hint, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            ],
          ),
        ),
        _RoundButton(icon: Icons.remove_rounded, size: 40, tooltip: '−0.1 s', onTap: () => _set(_seconds - 0.1)),
        SizedBox(
          width: 64,
          child: Text(
            '${_seconds > 0 ? '+' : ''}${_seconds.toStringAsFixed(1)} s',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
        _RoundButton(icon: Icons.add_rounded, size: 40, tooltip: '+0.1 s', onTap: () => _set(_seconds + 0.1)),
        _RoundButton(
          icon: Icons.restart_alt_rounded,
          size: 40,
          tooltip: '0 s',
          onTap: _seconds == 0 ? null : () => _set(0),
        ),
      ],
    ),
  );
}

class _SpeedPanel extends StatefulWidget {
  const _SpeedPanel({required this.player});

  final Player player;

  @override
  State<_SpeedPanel> createState() => _SpeedPanelState();
}

class _SpeedPanelState extends State<_SpeedPanel> {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final rate = widget.player.state.rate;
    return ListView(
      shrinkWrap: true,
      children: [
        _panelTitle(context, l.speed),
        for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
          _Option(
            label: r == 1.0 ? l.normalSpeed : '${r}x',
            selected: rate == r,
            autofocus: rate == r,
            onTap: () async {
              await widget.player.setRate(r);
              if (mounted) setState(() {});
            },
          ),
      ],
    );
  }
}

/// The episodes or channels being played through, the one playing in focus.
class _QueuePanel extends StatelessWidget {
  const _QueuePanel({required this.title, required this.items, required this.current, required this.onPick});

  final String title;
  final List<PlayItem> items;
  final int current;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    // Channels: each with its number, as the provider gives it, and what is on now
    final live = items.isNotEmpty && items.first.isLive;
    final numbers = live
        ? {for (final c in currentCatalog.value?.loaded?.live ?? const <LiveChannel>[]) c.id: c.number}
        : const <String, int?>{};
    final guide = live ? currentGuide.value : null;
    final row = _queueRow(context, live: live);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelTitle(context, title),
        Expanded(
          child: ListView.builder(
            controller: ScrollController(initialScrollOffset: math.max(0, (current - 2) * row)),
            itemExtent: row,
            itemCount: items.length,
            itemBuilder: (_, i) {
              final item = items[i];
              final number = live ? numbers[item.ref?.id] : null;
              return _Option(
                oneLine: true,
                label: live ? [?number?.toString(), item.title].join('  ') : item.subtitle ?? item.title,
                detail: live ? guide?.nowOn(item.ref?.epgId)?.title : null,
                selected: i == current,
                autofocus: i == current,
                onTap: () => onPick(i),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The height of a row of [_QueuePanel]: what it holds, its lines measured in the app's font and at
/// the text's size (Settings, or the system's). Around them 3 + 3 of space, the focus ring's 3 + 3
/// and the row's padding, 13 + 13 for one line or 9 + 9 for two (a channel and what is on). Never
/// less than it was; a fixed 58 cut a line by a pixel where the font measures taller.
double _queueRow(BuildContext context, {required bool live}) {
  final style = DefaultTextStyle.of(context).style;
  final scaler = MediaQuery.textScalerOf(context);
  double line(double size, FontWeight weight) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'Ág',
        style: style.merge(TextStyle(fontSize: size, fontWeight: weight)),
      ),
      textScaler: scaler,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  final title = line(15, FontWeight.w700);
  final measured = live ? 12 + 18 + title + line(13, FontWeight.w400) : 12 + 26 + title;
  return math.max(live ? 66.0 : 58.0, measured.ceilToDouble() + 1);
}

/// The player's settings for this session: sleep timer, picture, volume boost, stream info.
class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel({
    required this.sleep,
    required this.live,
    required this.boost,
    required this.info,
    required this.fit,
    required this.fitLabel,
    required this.onChanged,
    required this.onBoost,
    required this.onInfo,
    required this.onFit,
    required this.hardware,
    required this.onDecoder,
    this.intro,
    this.onIntro,
  });

  final SleepTimer sleep;
  final bool live, info;
  final int boost;
  final String fit;
  final String Function(String fit) fitLabel;
  final VoidCallback onChanged; // the sleep timer changed
  final ValueChanged<int> onBoost;
  final ValueChanged<bool> onInfo;
  final ValueChanged<String> onFit;
  final bool hardware;
  final Future<bool> Function(bool hardware) onDecoder; // the decoder in use after

  /// An episode's: the series' opening titles as marked, and the way to mark them.
  final Intro? Function()? intro;
  final Future<void> Function({bool start, bool end, bool clear})? onIntro;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  late var _boost = widget.boost;
  late var _info = widget.info;
  late var _fit = widget.fit;
  late var _hardware = widget.hardware;

  SleepTimer get _sleep => widget.sleep;

  void _setSleep(void Function() change) {
    setState(change);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final left = _sleep.left;
    return ListView(
      shrinkWrap: true,
      children: [
        _panelTitle(context, l.playerSettings),
        _Setting(
          icon: Icons.bedtime_outlined,
          title: l.sleepTimer,
          value: _sleep.atEnd
              ? l.sleepWhenItEnds
              : left != null
              ? l.minutes(left.inMinutes + 1)
              : l.settingOff,
          choices: [
            _Choice(l.settingOff, !_sleep.on, () => _setSleep(_sleep.off), autofocus: true),
            for (final m in SleepTimer.choices)
              _Choice(l.minutes(m), _sleep.minutes == m, () => _setSleep(() => _sleep.after(m))),
            if (!widget.live) _Choice(l.sleepWhenItEnds, _sleep.atEnd, () => _setSleep(_sleep.whenItEnds)),
          ],
        ),
        _Setting(
          icon: Icons.aspect_ratio_rounded,
          title: l.pictureFit,
          value: widget.fitLabel(_fit),
          choices: [
            for (final f in _pictureFits)
              _Choice(widget.fitLabel(f), _fit == f, () {
                setState(() => _fit = f);
                widget.onFit(f);
              }),
          ],
        ),
        _Setting(
          icon: Icons.volume_up_outlined,
          title: l.volumeBoost,
          value: _boost == 0 ? l.settingOff : '+$_boost dB',
          choices: [
            for (final db in const [0, 3, 6, 9, 12])
              _Choice(db == 0 ? l.settingOff : '+$db dB', _boost == db, () {
                setState(() => _boost = db);
                widget.onBoost(db);
              }),
          ],
        ),
        if ((widget.intro, widget.onIntro) case (final intro?, final mark?))
          _Setting(
            icon: Icons.skip_next_outlined,
            title: l.seriesIntro,
            value: switch (intro()) {
              (start: final s?, end: final e?) => '${_fmt(s)} – ${_fmt(e)}',
              (start: final s?, end: null) => '${_fmt(s)} – ?',
              (start: null, end: final e?) => '? – ${_fmt(e)}',
              _ => l.introNotMarked,
            },
            choices: [
              _Choice(l.introStart, false, () async {
                await mark(start: true);
                if (mounted) setState(() {});
              }),
              _Choice(l.introEnd, false, () async {
                await mark(end: true);
                if (mounted) setState(() {});
              }),
              if (intro() != null)
                _Choice(l.introClear, false, () async {
                  await mark(clear: true);
                  if (mounted) setState(() {});
                }),
            ],
          ),
        _Setting(
          icon: Icons.info_outline_rounded,
          title: l.streamInfo,
          value: _info ? l.settingOn : l.settingOff,
          choices: [
            for (final on in const [false, true])
              _Choice(on ? l.settingOn : l.settingOff, _info == on, () {
                setState(() => _info = on);
                widget.onInfo(on);
              }),
          ],
        ),
        _Setting(
          icon: Icons.memory_rounded,
          title: l.infoDecoder,
          value: _hardware ? l.decoderHw : l.decoderSw,
          choices: [
            for (final hw in const [true, false])
              _Choice(hw ? l.decoderHw : l.decoderSw, _hardware == hw, () async {
                setState(() => _hardware = hw);
                // What it really is after: a tap while another switch went on changes nothing
                final now = await widget.onDecoder(hw);
                if (mounted) setState(() => _hardware = now);
              }),
          ],
        ),
      ],
    );
  }
}

class _Choice {
  const _Choice(this.label, this.selected, this.onTap, {this.autofocus = false});

  final String label;
  final bool selected, autofocus;
  final VoidCallback onTap;
}

/// A setting: its name and value, and its choices as chips below.
class _Setting extends StatelessWidget {
  const _Setting({required this.icon, required this.title, required this.value, required this.choices});

  final IconData icon;
  final String title, value;
  final List<_Choice> choices;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 10, 4, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: AppColors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            Text(value, style: const TextStyle(color: AppColors.muted)),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in choices)
              Focusable(
                radius: AppRadius.pill,
                scale: 1.05,
                autofocus: c.autofocus && c.selected,
                onTap: c.onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  color: c.selected ? AppColors.text : AppColors.surfaceHigh,
                  child: Text(
                    c.label,
                    style: TextStyle(fontWeight: FontWeight.w600, color: c.selected ? AppColors.black : AppColors.text),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}
