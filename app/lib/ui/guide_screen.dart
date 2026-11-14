import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/epg.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/scheduled_recordings.dart';
import '../data/source.dart';
import '../device.dart';
import '../player/play.dart';
import '../player/recording_scheduler.dart';
import 'common.dart';
import 'live_groups.dart';
import 'recordings_screen.dart' show confirmCancelRecording;
import 'theme.dart';

const _fullRowHeight = 76.0;
const _todaySpan = Duration(hours: 14);

String _hm(BuildContext context, DateTime d) => clockText(context, d);

/// How far into [e] we are, 0..1.
double progressOf(EpgEntry e, [DateTime? at]) {
  final t = at ?? DateTime.now();
  final total = e.end.difference(e.start).inSeconds;
  return total <= 0 ? 0 : (t.difference(e.start).inSeconds / total).clamp(0, 1);
}

/// Plays a channel live with its category as the zapping queue.
void playChannel(BuildContext context, ContentSource source, List<LiveChannel> channels, int index) => playQueue(
  context,
  [for (final c in channels) PlayItem(url: source.liveUrl(c), title: c.name, ref: MediaRef.channel(c))],
  index: index,
);

/// What happens when a programme is chosen: live if it is on now, catch-up if it already
/// aired and the channel keeps an archive, otherwise its details.
void openProgramme(BuildContext context, ContentSource source, List<LiveChannel> channels, int index, EpgEntry e) {
  final c = channels[index];
  if (e.isNow()) return playChannel(context, source, channels, index);
  // Only within the days the channel keeps: older, the provider has nothing to give
  final catchup = c.keeps(e.end) ? source.catchupUrl(c, e.start, e.end.difference(e.start)) : null;
  if (catchup != null) {
    playMedia(context, url: catchup, title: c.name, subtitle: '${e.title} · ${_hm(context, e.start)}');
    return;
  }
  showProgrammeSheet(context, c, e);
}

/// A programme's details; one that has not ended can be recorded (or cancelled, once scheduled),
/// when the playlist is known: [playlistId], or the one open.
Future<void> showProgrammeSheet(
  BuildContext context,
  LiveChannel c,
  EpgEntry e, {
  String? playlistId,
  RecordingScheduler? scheduler,
}) => showModalBottomSheet(
  context: context,
  showDragHandle: true,
  backgroundColor: AppColors.surfaceHigh,
  // As tall as it needs, up to the screen, and scrolling past that: a phone on its side, a long
  // synopsis or large text would leave Record off the screen
  isScrollControlled: true,
  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
  builder: (sheet) => ProgrammeSheet(
    channel: c,
    entry: e,
    playlistId: playlistId ?? currentLibrary.value?.playlistId,
    scheduler: scheduler ?? RecordingScheduler.instance,
  ),
);

class ProgrammeSheet extends StatelessWidget {
  const ProgrammeSheet({
    super.key,
    required this.channel,
    required this.entry,
    required this.playlistId,
    required this.scheduler,
  });

  final LiveChannel channel;
  final EpgEntry entry;
  final String? playlistId;
  final RecordingScheduler scheduler;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scheduler.store,
    builder: (context, _) {
      final l = context.l10n, e = entry, id = playlistId;
      final r = id == null ? null : scheduler.store.find(id, channel.id, e.start);
      final pending = r != null && r.pending;
      final canRecord = id != null && e.end.isAfter(DateTime.now());
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(channel.name, style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 4),
            Text(e.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('${_hm(context, e.start)} – ${_hm(context, e.end)}', style: const TextStyle(color: AppColors.text)),
            if (e.description != null) ...[
              const SizedBox(height: 12),
              Text(e.description!, style: const TextStyle(height: 1.5)),
            ],
            if (pending || canRecord) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  if (pending)
                    SecondaryButton(
                      autofocus: true,
                      icon: r.state == ScheduleState.recording ? Icons.stop_rounded : Icons.close_rounded,
                      label: r.state == ScheduleState.recording ? l.stopRecording : l.cancelRecording,
                      onPressed: () async {
                        if (await confirmCancelRecording(context, r)) await scheduler.cancel(r.id);
                      },
                    )
                  else
                    PrimaryButton(
                      autofocus: true,
                      icon: Icons.fiber_manual_record_rounded,
                      label: l.record,
                      onPressed: () => scheduler.schedule(
                        playlistId: id!,
                        channel: MediaRef.channel(channel),
                        title: e.title,
                        start: e.start,
                        end: e.end,
                      ),
                    ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      !pending
                          ? ''
                          : r.state == ScheduleState.recording
                          ? l.recordingNow
                          : l.recordingStartsAt(_hm(context, r.from)),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // An iPhone stops the app in the background: there it has to stay on screen
              Text(
                RecordingKeepAlive.survivesBackground ? l.scheduleNote : l.keepAppOpenToRecord,
                style: const TextStyle(color: AppColors.muted, fontSize: 13),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// Programme grid: channels down the side, time across, a live "now" line.
class GuideScreen extends StatefulWidget {
  const GuideScreen({
    super.key,
    required this.source,
    required this.guide,
    required this.categories,
    this.initialCategory,
  });

  final ContentSource source;
  final ValueNotifier<EpgGuide> guide;
  final List<Category> categories;
  final String? initialCategory;

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  late String? _category = widget.initialCategory ?? widget.categories.firstOrNull?.id;
  final _selectedChip = GlobalKey();
  final _body = ScrollController();
  final _header = ScrollController();
  final _channelList = ScrollController();
  final _rowList = ScrollController();
  DateTime? _start;
  var _day = 0; // days before today on screen; -1 tomorrow
  var _compact = false; // phone-sized: narrow channel column, shorter rows and less past time

  /// Days before today the guide goes back to: three, or as many as the list's channels keep of
  /// what they aired, up to a week (what loadXmltv keeps for them).
  late final int _daysBack = [
    3,
    for (final c in currentCatalog.value?.loaded?.live ?? const <LiveChannel>[])
      if (c.archiveDays > 3) math.min(c.archiveDays, maxCatchupDays),
  ].reduce(math.max);
  double get _rowHeight => (_compact ? 68 : _fullRowHeight) * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
  Timer? _tick;

  DateTime get _from => _start!;
  Duration get _span => _day == 0 ? _todaySpan : const Duration(hours: 24);

  /// Today from just before now; another day whole, from its midnight: an earlier one to find
  /// what it aired, tomorrow to see what comes (and record it).
  void _showDay(int day) {
    final now = DateTime.now();
    setState(() {
      _day = day;
      if (day == 0) {
        final boundary = DateTime(now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30);
        _start = _compact ? boundary : boundary.subtract(const Duration(hours: 1));
      } else {
        _start = DateTime(now.year, now.month, now.day - day);
      }
    });
    if (_body.hasClients) _body.jumpTo(0);
  }

  /// The guide once more, after it could not be downloaded: Home's, so every screen has it.
  Future<void> _retryGuide() async {
    widget.guide.value = EpgGuide.loading;
    EpgGuide guide;
    try {
      guide = await widget.source.guide();
    } on Object {
      guide = EpgGuide.failed;
    }
    if (!mounted) return; // Home may be gone with it
    widget.guide.value = guide;
    if (!identical(guide, EpgGuide.failed)) currentGuide.value = guide;
  }

  /// Moves the grid [hours] later (earlier when negative), as far as the day on screen goes.
  void _step(int hours) {
    if (!_body.hasClients) return;
    final p = _body.position;
    final to = (p.pixels + hours * 60 * _pxPerMinute).clamp(p.minScrollExtent, p.maxScrollExtent);
    _body.animateTo(to, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
  }

  double get _channelWidth => _compact ? 112 : 210;
  double get _pxPerMinute => _compact ? 4 : 5; // one hour = 240 or 300 px

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A phone either way up: narrow, or short on its side (always wider than 600 then)
    _compact = isShort(context) || MediaQuery.sizeOf(context).width < 600;
    if (_start != null) return;
    // Start on the half-hour boundary before now, an hour earlier where there is room. The grid
    // opens at that start: blocks are clipped to it, so every title is readable and the "now"
    // line sits a little to the right.
    final now = DateTime.now();
    final boundary = DateTime(now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30);
    _start = _compact ? boundary : boundary.subtract(const Duration(hours: 1));
  }

  @override
  void initState() {
    super.initState();
    _body.addListener(() {
      if (_header.hasClients) _header.jumpTo(_body.offset);
    });
    // The channel column and the programme rows scroll up and down together
    _rowList.addListener(() => _follow(_rowList, _channelList));
    _channelList.addListener(() => _follow(_channelList, _rowList));
    // Bring the current category chip into view (it may be far down a long list)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chip = _selectedChip.currentContext;
      if (chip != null) Scrollable.ensureVisible(chip, alignment: 0.05);
    });
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final c in [_body, _header, _channelList, _rowList]) {
      c.dispose();
    }
    super.dispose();
  }

  static void _follow(ScrollController from, ScrollController to) {
    // One list each (not while a category's lists replace the previous ones)
    if (from.positions.length != 1 || to.positions.length != 1) return;
    if ((to.offset - from.offset).abs() > 0.5) to.jumpTo(from.offset);
  }

  double _x(DateTime t) => t.difference(_from).inSeconds / 60 * _pxPerMinute;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final width = _span.inMinutes * _pxPerMinute;
    // Which day: today, or one before it for what channels with catch-up kept
    final days = [
      for (final d in [0, -1, for (var d = 1; d <= _daysBack; d++) d])
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: AppChip(
            label: switch (d) {
              0 => l.guideToday,
              -1 => l.guideTomorrow,
              1 => l.guideYesterday,
              _ => MaterialLocalizations.of(context).formatMediumDate(DateTime.now().subtract(Duration(days: d))),
            },
            selected: d == _day,
            onTap: () => _showDay(d),
          ),
        ),
      // With a mouse, no swipe: two hours either way (a remote moves along the programmes)
      if (!isTv) ...[
        const SizedBox(width: 8),
        IconButton(icon: const Icon(Icons.chevron_left_rounded), tooltip: l.guideEarlier, onPressed: () => _step(-2)),
        IconButton(icon: const Icon(Icons.chevron_right_rounded), tooltip: l.guideLater, onPressed: () => _step(2)),
      ],
    ];
    final categories = [
      for (final c in widget.categories)
        Padding(
          key: c.id == _category ? _selectedChip : null,
          padding: const EdgeInsets.only(right: 8),
          child: AppChip(
            autofocus: c.id == _category,
            label: categoryLabel(context.l10n, c.name),
            selected: c.id == _category,
            onTap: () {
              setState(() => _category = c.id);
              // Its programmes start again at the beginning: the hours above them too
              if (_header.hasClients) _header.jumpTo(0);
            },
          ),
        ),
    ];
    // Not a lazy ListView: every chip must exist so the selected one can be scrolled into view
    Widget chipRow(List<Widget> chips) => SizedBox(
      height: chipRowHeight(context),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: chips),
      ),
    );
    // A phone on its side has room for two or three channels under four rows of headings: the
    // days and categories share one, under a lower title bar
    final short = isShort(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.tvGuide), toolbarHeight: short ? 44 : null),
      body: Column(
        children: [
          // What OK held does is shown nowhere else; a mouse right-clicks, a phone holds its finger
          if (isTv)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(l.holdOkHint, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
              ),
            ),
          if (short)
            chipRow([
              ...days,
              const SizedBox(height: 24, child: VerticalDivider(width: 17, color: AppColors.muted)),
              ...categories,
            ])
          else ...[
            chipRow(days),
            chipRow(categories),
          ],
          // Time ruler, kept in sync with the grid's horizontal scroll
          Row(
            children: [
              SizedBox(width: _channelWidth),
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: SingleChildScrollView(
                    controller: _header,
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    child: SizedBox(
                      width: width,
                      child: Stack(
                        children: [
                          for (var m = 0; m < _span.inMinutes; m += 30)
                            Positioned(
                              left: m * _pxPerMinute + 6,
                              top: 6,
                              child: Text(
                                _hm(context, _from.add(Duration(minutes: m))),
                                style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
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
          const Divider(height: 1, color: AppColors.stroke),
          // Not downloaded, and no copy kept: said once, with the way to try again
          ValueListenableBuilder<EpgGuide>(
            valueListenable: widget.guide,
            builder: (context, guide, _) => !identical(guide, EpgGuide.failed)
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
                    child: Row(
                      children: [
                        const Icon(Icons.cloud_off_rounded, color: AppColors.muted),
                        const SizedBox(width: 12),
                        Expanded(child: Text(l.guideFailed)),
                        SecondaryButton(icon: Icons.refresh_rounded, label: l.retry, onPressed: _retryGuide),
                      ],
                    ),
                  ),
          ),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey(_category),
              child: AsyncView<List<LiveChannel>>(
                load: () => liveChannelsIn(widget.source, LibraryScope.maybeOf(context), _category ?? ''),
                isEmpty: (c) => c.isEmpty,
                loading: const Center(child: ListLoading()),
                builder: (context, channels) => ListenableBuilder(
                  listenable: Listenable.merge([widget.guide, ScheduledRecordings.instance]),
                  builder: (context, _) => _grid(context, widget.guide.value, channels, width),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Logo over a one-line name, for the narrow channel column of phones.
  Widget _compactChannel(EpgGuide guide, LiveChannel c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 28,
          child: NetImage(c.icon ?? guide.iconOf(c.epgId), fit: BoxFit.contain, icon: Icons.tv_rounded),
        ),
        const SizedBox(height: 4),
        Text(
          c.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
        ),
      ],
    ),
  );

  /// Built row by row as they scroll into view: a category can have hundreds of channels.
  Widget _grid(BuildContext context, EpgGuide guide, List<LiveChannel> channels, double width) {
    final now = DateTime.now();
    final to = _from.add(_span);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _channelWidth,
          child: ListView.builder(
            controller: _channelList,
            padding: const EdgeInsets.only(bottom: 32),
            itemExtent: _rowHeight,
            itemCount: channels.length,
            itemBuilder: (context, i) => _channelCell(context, guide, channels, i),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: _body,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Stack(
                children: [
                  ListView.builder(
                    controller: _rowList,
                    padding: const EdgeInsets.only(bottom: 32),
                    itemExtent: _rowHeight,
                    itemCount: channels.length,
                    itemBuilder: (context, i) => _programmeRow(context, guide, channels, i, now, to),
                  ),
                  // The "now" line
                  Positioned(
                    left: _x(now) - 1,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(child: Container(width: 2, color: AppColors.live)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _channelCell(BuildContext context, EpgGuide guide, List<LiveChannel> channels, int i) {
    final c = channels[i];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      child: Focusable(
        scale: 1.02,
        radius: 12,
        onTap: () => playChannel(context, widget.source, channels, i),
        child: ColoredBox(
          color: AppColors.surface,
          child: _compact
              ? _compactChannel(guide, c)
              : Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: SizedBox(
                        width: 48,
                        child: NetImage(c.icon ?? guide.iconOf(c.epgId), fit: BoxFit.contain, icon: Icons.tv_rounded),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        c.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _programmeRow(
    BuildContext context,
    EpgGuide guide,
    List<LiveChannel> channels,
    int i,
    DateTime now,
    DateTime to,
  ) {
    final c = channels[i];
    final playlist = currentLibrary.value?.playlistId;
    double left(EpgEntry e) => _x(e.start.isBefore(_from) ? _from : e.start);
    return Stack(
      children: [
        for (final e in guide.between(c.epgId, _from, to))
          Positioned(
            left: left(e),
            width: (_x(e.end.isAfter(to) ? to : e.end) - left(e) - 4).clamp(24, double.infinity),
            top: 4,
            bottom: 4,
            child: _ProgrammeBlock(
              entry: e,
              archive: c.keeps(e.end, now),
              recording: switch (playlist == null ? null : ScheduledRecordings.instance.find(playlist, c.id, e.start)) {
                final r? when r.pending => r.state,
                _ => null,
              },
              onTap: () => openProgramme(context, widget.source, channels, i, e),
              // Also for one on now, which a tap plays: its details, and recording it
              onLongPress: () => showProgrammeSheet(context, c, e),
            ),
          ),
        if (!guide.has(c.epgId))
          Positioned(
            left: 4,
            top: 4,
            bottom: 4,
            width: _x(now) + 300,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              // Not "no guide" while it is still on its way
              child: Text(
                identical(guide, EpgGuide.loading)
                    ? context.l10n.guideLoading
                    : identical(guide, EpgGuide.failed)
                    ? context.l10n.guideFailed
                    : context.l10n.noGuide,
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }
}

class _ProgrammeBlock extends StatelessWidget {
  const _ProgrammeBlock({
    required this.entry,
    required this.archive,
    required this.recording,
    required this.onTap,
    required this.onLongPress,
  });

  final EpgEntry entry;
  final bool archive; // aired and replayable through catch-up
  final ScheduleState? recording; // scheduled to be recorded, or recording
  final VoidCallback onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final now = entry.isNow();
    final past = entry.end.isBefore(DateTime.now());
    return Focusable(
      scale: 1.0,
      radius: 10,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Opacity(
        opacity: past && !archive ? 0.55 : 1,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
          decoration: BoxDecoration(
            color: now ? AppColors.surfaceHigh : AppColors.surface,
            border: now ? const Border(left: BorderSide(color: AppColors.text, width: 3)) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  if (recording != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(
                        Icons.fiber_manual_record_rounded,
                        size: 12,
                        color: recording == ScheduleState.recording ? AppColors.live : AppColors.text,
                      ),
                    ),
                  if (archive)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.history_rounded, size: 14, color: AppColors.text),
                    ),
                  Expanded(
                    child: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: now ? FontWeight.w700 : FontWeight.w600, fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                '${_hm(context, entry.start)} – ${_hm(context, entry.end)}',
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Title of what is on now plus a thin progress bar, for channel cards.
class NowOnAir extends StatelessWidget {
  const NowOnAir(this.entry, {super.key});

  final EpgEntry entry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.muted, fontSize: 12),
      ),
      const SizedBox(height: 5),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Container(
          height: 3,
          color: Colors.white12,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: progressOf(entry),
            child: Container(decoration: const BoxDecoration(color: AppColors.text)),
          ),
        ),
      ),
    ],
  );
}
