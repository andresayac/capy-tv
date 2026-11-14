import 'dart:io';

import 'package:flutter/material.dart';

import '../data/profiles.dart';
import '../data/recordings.dart';
import '../data/scheduled_recordings.dart';
import '../data/settings.dart';
import '../player/play.dart';
import '../player/recording_scheduler.dart';
import 'common.dart';
import 'theme.dart';

/// Whether to cancel [r], still to come, or stop it while it records: asked, an OK too many keeps it.
Future<bool> confirmCancelRecording(BuildContext context, ScheduledRecording r) {
  final l = context.l10n;
  final recording = r.state == ScheduleState.recording;
  return showConfirm(
    context,
    title: recording ? l.stopRecordingQuestion : l.cancelScheduledQuestion,
    message: r.title,
    confirmLabel: recording ? l.stopRecording : l.cancelRecording,
    cancelLabel: l.keepIt,
  );
}

/// The recordings scheduled from the guide, then the channels recorded: OK or a tap plays one, and
/// each can be deleted.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key, this.scheduler});

  /// The app's own unless given (tests).
  final RecordingScheduler? scheduler;

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  late final _scheduler = widget.scheduler ?? RecordingScheduler.instance;
  late Future<List<Recording>> _list = Recordings.list(profile: _profile);

  /// Each profile sees the recordings it made, and those from before profiles were noted.
  static String get _profile => ProfileStore.instance.current.id;

  @override
  void initState() {
    super.initState();
    // A scheduled one that starts or ends changes the files
    _scheduler.store.addListener(_relist);
    _scheduler.store.load().then((_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _scheduler.store.removeListener(_relist);
    super.dispose();
  }

  /// The files read again. In a block: setState must not be handed the Future itself
  void _relist() {
    if (!mounted) return;
    setState(() {
      _list = Recordings.list(profile: _profile);
    });
  }

  Future<void> _delete(Recording r) async {
    final l = context.l10n;
    final sure = await showConfirm(context, title: l.deleteRecording, message: r.title, confirmLabel: l.delete);
    if (!sure || !mounted) return;
    try {
      if (r.file.existsSync()) r.file.deleteSync();
    } on FileSystemException catch (e) {
      // Windows keeps a file another program has open: said, rather than a button that does nothing
      debugPrint('recordings: ${r.file.path} not deleted: $e');
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l.recordingNotDeleted)));
    }
    _relist();
  }

  /// Cancels a scheduled one, or stops one under way, once asked; a finished one leaves the list.
  Future<void> _cancel(ScheduledRecording r) async {
    if (r.pending && !await confirmCancelRecording(context, r)) return;
    await _scheduler.cancel(r.id);
  }

  static String _size(int bytes) =>
      bytes >= 1 << 30 ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB' : '${(bytes / (1 << 20)).round()} MB';

  String _when(DateTime t) => '${formatDate(context, t)} · ${clockText(context, t)}';

  Widget _header(String title) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 2),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.recordings)),
      body: FutureBuilder(
        future: _list,
        builder: (context, snap) {
          final all = snap.data;
          if (all == null) return const Center(child: CapyStatus(mood: CapyMood.loading));
          final scheduled = [
            for (final r in _scheduler.store.items)
              if (r.profile == null || r.profile == _profile) r,
          ];
          // One still being written has its row above, to stop it; listed here once it is done
          final writing = {
            for (final r in scheduled)
              if (r.state == ScheduleState.recording && r.file != null) File(r.file!).absolute.path,
          };
          final list = [
            for (final f in all)
              if (!writing.contains(f.file.absolute.path)) f,
          ];
          final rows = <Widget>[
            ..._margins(),
            if (list.isEmpty && scheduled.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: CapyMessage(mood: CapyMood.empty, text: l.noRecordings),
              ),
            if (scheduled.isNotEmpty) ...[
              _header(l.scheduledRecordings),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(l.scheduleNote, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
              ),
              // By id: one cancelled does not leave the focus on the button of the next
              for (final (i, r) in scheduled.indexed)
                KeyedSubtree(
                  key: ValueKey(r.id),
                  child: _scheduledRow(r, first: i == 0),
                ),
              if (list.isNotEmpty) ...[const SizedBox(height: 14), _header(l.recordedFiles)],
            ],
            for (final (i, r) in list.indexed)
              KeyedSubtree(
                key: ValueKey(r.file.path),
                child: _fileRow(r, first: i == 0 && scheduled.isEmpty),
              ),
          ];
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => rows[i],
              ),
            ),
          );
        },
      ),
    );
  }

  /// How early a scheduled recording starts and how late it ends.
  List<Widget> _margins() {
    final settings = SettingsScope.maybeOf(context); // its changes draw this again
    if (settings == null) return const [];
    final l = context.l10n;
    return [
      ChoiceRow<int>(
        label: l.recordEarly,
        value: settings.recordEarly,
        options: const [0, 1, 5],
        text: (n) => l.minutes(n),
        onChanged: (n) => settings.set(recordEarly: n),
      ),
      ChoiceRow<int>(
        label: l.recordLate,
        hint: l.recordMarginsHint,
        value: settings.recordLate,
        options: const [2, 5, 15, 30],
        text: (n) => l.minutes(n),
        onChanged: (n) => settings.set(recordLate: n),
      ),
    ];
  }

  String _problem(RecordingProblem p) {
    final l = context.l10n;
    return switch (p) {
      RecordingProblem.appClosed => l.problemAppClosed,
      RecordingProblem.asleep => l.problemAsleep,
      RecordingProblem.noNetwork => l.problemNoNetwork,
      RecordingProblem.channelGone => l.problemChannelGone,
      RecordingProblem.unsupported => l.problemUnsupported,
      RecordingProblem.nothingCame => l.problemNothingCame,
      RecordingProblem.noSpace => l.problemNoSpace,
      RecordingProblem.writeFailed => l.problemWriteFailed,
    };
  }

  Widget _scheduledRow(ScheduledRecording r, {required bool first}) {
    final l = context.l10n;
    final recording = r.state == ScheduleState.recording;
    final why = r.problem == null ? null : _problem(r.problem!);
    final state = switch (r.state) {
      // Still to come with a problem: its start failed, and it is tried again
      ScheduleState.scheduled when why != null => l.recordingRetrying(why),
      ScheduleState.scheduled => l.recordingScheduled,
      ScheduleState.recording => l.recordingNow,
      ScheduleState.done when why != null => l.recordingPartly(why),
      ScheduleState.done => l.recordingDone,
      ScheduleState.failed when why != null => l.recordingFailedBecause(why),
      ScheduleState.failed => l.recordingFailedState,
      ScheduleState.missed => l.recordingMissedBecause(why ?? l.problemAppClosed),
    };
    final hours = '${clockText(context, r.start)} – ${clockText(context, r.end)}';
    return Row(
      children: [
        Expanded(
          child: Panel(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                Icon(
                  r.pending ? Icons.fiber_manual_record_rounded : Icons.schedule_rounded,
                  size: r.pending ? 18 : 24,
                  color: recording ? AppColors.live : (r.pending ? AppColors.text : AppColors.muted),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${r.channel.title} · ${formatDate(context, r.start)} · $hours',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.muted, fontSize: 13),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        state,
                        style: TextStyle(
                          color: r.pending ? AppColors.text : AppColors.muted,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        SecondaryButton(
          autofocus: first,
          label: switch (r.state) {
            ScheduleState.scheduled => l.cancel,
            ScheduleState.recording => l.stopRecording,
            _ => l.removeFromList,
          },
          onPressed: () => _cancel(r),
        ),
      ],
    );
  }

  Widget _fileRow(Recording r, {required bool first}) {
    final l = context.l10n;
    final when = _when(r.at);
    return Row(
      children: [
        Expanded(
          child: Focusable(
            autofocus: first,
            scale: 1,
            onTap: () async {
              await playMedia(context, url: r.file.path, title: r.title, subtitle: when);
              _relist();
            },
            child: Panel(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.play_circle_outline_rounded, size: 30),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                        ),
                        const SizedBox(height: 2),
                        Text('$when · ${_size(r.bytes)}', style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(tooltip: l.delete, icon: const Icon(Icons.delete_outline_rounded), onPressed: () => _delete(r)),
      ],
    );
  }
}
