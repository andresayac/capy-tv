// Recording what the player plays: by hand (its Record button), or a recording scheduled from the
// guide that takes the channel this player gets rather than a connection of its own. A part of
// player_screen.dart: the screen mixes it in, and gives it what it names below.
part of 'player_screen.dart';

mixin _PlayerRecording on State<PlayerScreen> {
  // What it needs of the player screen
  Player get player;
  PlayItem get _item; // what plays
  PlayItem get _stream; // the copy of it that plays
  int get _session; // a new one per item opened: a late answer knows it is stale
  bool get _stopped;
  Media _mediaFor(PlayItem item);

  /// The player opened anew at the live picture: the screen's watch on it starts over.
  void _openedAgainLive();

  // A channel being recorded (see [Recordings]): the file, and since when; and the relay the
  // channel comes through from the first recording until another one plays. HLS goes on directly,
  // and its recorder fetches the pieces the player does
  File? _recording;
  DateTime? _recordingSince;
  RecordRelay? _relay;
  HlsRecorder? _hls;
  var _recordingBusy = false; // starting or stopping: the button waits
  _ChannelTap? _tap; // the live channel playing, for recordings scheduled of it

  /// Records the channel as it comes in, into a new file among the [Recordings]; or stops.
  Future<void> _toggleRecording() async {
    if (_recordingBusy) return; // a second press while the first is under way
    _recordingBusy = true;
    try {
      await (_recording != null ? _stopRecording() : _startRecording());
    } finally {
      _recordingBusy = false;
    }
  }

  void _tell(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// The first time, the channel is opened again through a [RecordRelay], a moment's gap, at the live
  /// picture: the player reads what the relay writes down. HLS is recorded by an [HlsRecorder]
  /// instead, the player going on as it is.
  Future<void> _startRecording() async {
    unawaited(RecordingKeepAlive.askNotifications());
    final stream = _stream, session = _session;
    bool stale() => !mounted || session != _session; // another channel meanwhile, or closed
    // Not begun where it would fill the device
    final room = await RecordingScheduler.instance.hasRoom();
    if (!mounted || stale()) return;
    if (!room) return _tell(context.l10n.recordingNoRoom);
    final file = await Recordings.newFile(
      _item.title,
      untitled: context.l10n.recordingUntitled,
      owner: ProfileStore.instance.current.id, // Recordings shows it to this profile
    );
    if (stale()) return;
    if (await _comesAsHls(stream)) return _recordHls(file);
    // Begun before the player asks the relay, which may find HLS there and go on in this file
    await _throughRelay((relay) async {
      await relay.recordTo(file);
      if (!stale()) _began(file); // else the relay went with the channel, and the file with it
    });
  }

  void _began(File file) {
    setState(() {
      _recording = file;
      _recordingSince = DateTime.now();
    });
    // Kept running meanwhile, as a scheduled recording is: in the background Android would freeze it.
    // And stopped, as those are, when the device gets nearly full
    RecordingScheduler.instance.playerRecording(this, channel: _item.title, onNoRoom: _onNoRoom);
  }

  /// The device is nearly full: stopped before it fills, what was recorded kept.
  Future<void> _onNoRoom() async {
    if (_recording == null || !mounted) return;
    await _stopRecording(tell: false);
    if (mounted) _tell(context.l10n.recordingStoppedNoRoom);
  }

  /// Asked for as the player asks for it: a provider may only let some players in.
  Future<Map<String, String>> _headersFor(PlayItem stream) async {
    final agent = await playerProperty(player, 'user-agent');
    return {if (agent.isNotEmpty) 'User-Agent': agent, ...stream.headers};
  }

  /// Whether the channel comes as HLS, a list of pieces rather than one stream: as mpv found it;
  /// by its address only when mpv does not say (a '.m3u8' may be a plain list of one stream).
  Future<bool> _comesAsHls(PlayItem stream) async {
    final format = await playerProperty(player, 'file-format');
    if (format.trim().isNotEmpty) return format.split(',').any((f) => f.trim() == 'hls' || f.trim() == 'applehttp');
    return Uri.tryParse(stream.url)?.path.toLowerCase().endsWith('.m3u8') ?? false;
  }

  /// The bandwidth of the HLS variant mpv plays (its picture's track, else its sound's), if it says.
  Future<int?> _playedBandwidth() async {
    final count = int.tryParse(await playerProperty(player, 'track-list/count')) ?? 0;
    int? sound;
    for (var i = 0; i < count; i++) {
      if (await playerProperty(player, 'track-list/$i/selected') != 'yes') continue;
      final rate = int.tryParse(await playerProperty(player, 'track-list/$i/hls-bitrate'));
      if (rate == null) continue;
      if (await playerProperty(player, 'track-list/$i/type') == 'video') return rate;
      sound ??= rate;
    }
    return sound;
  }

  /// HLS comes in pieces the player fetches one by one: an [HlsRecorder] fetches them too, into
  /// [file], and the player goes on as it is. [goingOn] when the relay found HLS on its way and
  /// the recording, begun, goes on this way.
  Future<void> _recordHls(File file, {bool goingOn = false}) async {
    final stream = _stream, session = _session;
    bool gone() => !mounted || session != _session || (goingOn && _recording != file);
    final HlsRecorder rec;
    try {
      rec = await HlsRecorder.start(
        stream.url,
        file,
        headers: await _headersFor(stream),
        bandwidth: await _playedBandwidth(),
        position: player.state.position,
        onUnusable: _onHlsUnusable,
        onWriteError: _onRecordWriteError,
        onEnded: _onHlsEnded,
      );
    } on HlsRefused catch (e) {
      if (gone()) return;
      if (goingOn) await _stopRecording(tell: false);
      if (mounted) _tell(_refusal(context.l10n, e.problem));
      return;
    }
    if (gone()) {
      await rec.stop();
      if (file.existsSync() && file.lengthSync() == 0) file.deleteSync();
      return;
    }
    _hls = rec;
    if (!goingOn) _began(file);
  }

  static String _refusal(AppLocalizations l, HlsProblem problem) => switch (problem) {
    HlsProblem.encrypted => l.recordingEncrypted,
    HlsProblem.fragmented => l.recordingFragmented,
    HlsProblem.separateAudio => l.recordingSeparateAudio,
    HlsProblem.unreachable => l.recordingFailed,
  };

  /// [use]s the relay the channel comes through: made the first time, and the player opened again
  /// through it. Null when another channel plays by then.
  Future<RecordRelay?> _throughRelay(Future<void> Function(RecordRelay relay) use) async {
    if (_relay case final relay?) {
      await use(relay);
      return relay;
    }
    final stream = _stream, session = _session;
    final made = await RecordRelay.start(
      stream.url,
      headers: await _headersFor(stream),
      onUnusable: _onRelayUnusable,
      onWriteError: _onRecordWriteError,
    );
    if (!mounted || session != _session || _relay != null) {
      await made.close();
      return mounted && session == _session ? _throughRelay(use) : null; // made meanwhile: that one
    }
    _relay = made;
    await use(made);
    _openedAgainLive(); // it opens playing, at the live picture
    await player.open(Media(made.url));
    return made;
  }

  /// Tells the recordings scheduled from the guide which live channel plays: one of it records from
  /// what this player gets, not on a connection of its own the provider may not allow alongside.
  void _tapChannel({bool off = false}) {
    final playlist = widget.library?.playlistId, ref = _item.ref;
    _ChannelTap? tap;
    if (!off && _item.isLive && playlist != null && ref != null) {
      if (_tap case final t? when t.playlistId == playlist && t.channelId == ref.id) return;
      tap = _ChannelTap(playlist, ref.id, _recordForSchedule);
    } else if (_tap == null) {
      return;
    }
    final old = _tap;
    _tap = tap;
    tap != null ? RecordingScheduler.instance.watching(tap) : RecordingScheduler.instance.left(old!);
  }

  /// This channel into [file], for a recording scheduled of it: through the relay. Null when it
  /// cannot be (HLS, or another channel plays by now).
  Future<ChannelRecorder?> _recordForSchedule(
    _ChannelTap tap,
    File file,
    void Function(Object error)? onWriteError,
  ) async {
    if (!mounted || _tap != tap || _stopped || isHlsUrl(_stream.url)) return null;
    RelayTap? recorder;
    await _throughRelay((relay) async => recorder = relay.tap(file, onWriteError: onWriteError));
    return recorder;
  }

  /// The relay cannot carry the channel: back to the channel directly. HLS (a list of pieces rather
  /// than one stream) goes on being recorded another way, in the same file; a channel it could not
  /// get is not recorded.
  Future<void> _onRelayUnusable(RelayProblem problem) async {
    final relay = _relay;
    if (relay == null || !mounted) return;
    _relay = null;
    await relay.close();
    if (!mounted) return;
    _openedAgainLive();
    await player.open(_mediaFor(_stream));
    final file = _recording;
    if (file == null || !mounted) return;
    if (problem == RelayProblem.hls) return _recordHls(file, goingOn: true);
    await _stopRecording(tell: false);
    if (mounted) _tell(context.l10n.recordingFailed);
  }

  /// The HLS channel turned into one that cannot be recorded, or its pieces stopped coming: what was
  /// recorded is kept.
  Future<void> _onHlsUnusable(HlsProblem problem) async {
    if (_recording == null || !mounted) return;
    final saved = await _stopRecording(tell: false);
    if (!mounted) return;
    _tell(problem == HlsProblem.unreachable && saved ? context.l10n.recordingCut : _refusal(context.l10n, problem));
  }

  /// The HLS playlist ended (an event that is over) and all of it is in the file.
  Future<void> _onHlsEnded() async {
    if (_recording != null && mounted) await _stopRecording();
  }

  /// The file could not be written further (no room left): what it has is kept.
  Future<void> _onRecordWriteError(Object error) async {
    if (_recording == null || !mounted) return;
    await _stopRecording(tell: false);
    if (mounted) _tell(context.l10n.recordingStopped);
  }

  /// Stops recording, the channel still coming through the relay or directly; whether something was
  /// saved, and with [tell] said so.
  Future<bool> _stopRecording({bool tell = true}) async {
    final file = _recording;
    if (file == null) return false;
    // At once: what calls this meanwhile (a write that failed, the channel changed) finds it done
    _recording = null;
    _recordingSince = null;
    RecordingScheduler.instance.playerRecordingEnded(this);
    if (mounted) setState(() {});
    final hls = _hls;
    _hls = null;
    await hls?.stop();
    await _relay?.recordTo(null);
    final saved = file.existsSync() && file.lengthSync() > 0;
    if (!saved && file.existsSync()) file.deleteSync();
    if (!mounted || !tell) return saved;
    final l = context.l10n;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(saved ? l.recordingSaved : l.recordingFailed)));
    return saved;
  }
}

/// The live channel a player plays, for recordings scheduled of it (see [LiveTap]).
class _ChannelTap implements LiveTap {
  _ChannelTap(this.playlistId, this.channelId, this._record);

  @override
  final String playlistId, channelId;
  final Future<ChannelRecorder?> Function(_ChannelTap tap, File file, void Function(Object error)? onWriteError)
  _record;

  @override
  Future<ChannelRecorder?> recordInto(File file, {void Function(Object error)? onWriteError}) =>
      _record(this, file, onWriteError);
}
