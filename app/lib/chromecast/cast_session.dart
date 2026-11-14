import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'cast_link.dart';
import 'cast_message.dart';
import 'hls_rewrite.dart';

/// What the receiver shows the media as: metadataType 1 (movie), 2 (TV show), or 0 (generic).
enum CastMediaKind { movie, episode, live, other }

/// One thing the receiver can be asked to play.
class CastMedia {
  const CastMedia({
    required this.url,
    required this.contentType,
    this.live = false,
    this.hls = false,
    this.title = '',
    this.subtitle = '',
    this.image,
    this.seriesTitle,
    this.season,
    this.episode,
    this.startAt,
    this.kind = CastMediaKind.other,
    this.hlsFormat,
  });

  final String url;
  final String contentType;
  final bool live;
  final bool hls;
  final String title;
  final String subtitle;
  final String? image;
  final String? seriesTitle;
  final int? season;
  final int? episode;
  final Duration? startAt; // where a movie or episode resumes
  final CastMediaKind kind;

  /// What [hls]'s segments are, read from its playlists; null when not known: Transport Stream.
  final HlsFormat? hlsFormat;

  /// The LOAD message's media object.
  Map<String, dynamic> toLoad() => {
    'contentId': url,
    'contentUrl': url,
    'contentType': contentType,
    'streamType': live ? 'LIVE' : 'BUFFERED',
    if (hls) 'hlsSegmentFormat': (hlsFormat ?? HlsFormat.ts).segment,
    if (hls) 'hlsVideoSegmentFormat': ?(hlsFormat ?? HlsFormat.ts).video,
    'metadata': <String, dynamic>{
      'metadataType': switch (kind) {
        CastMediaKind.movie => 1,
        CastMediaKind.episode => 2,
        _ => 0,
      },
      if (kind == CastMediaKind.episode && seriesTitle != null) 'seriesTitle': seriesTitle,
      if (kind == CastMediaKind.episode && season != null) 'season': season,
      if (kind == CastMediaKind.episode && episode != null) 'episode': episode,
      if (title.isNotEmpty) 'title': title,
      if (subtitle.isNotEmpty) 'subtitle': subtitle,
      if (image != null)
        'images': [
          {'url': image},
        ],
    },
  };
}

enum CastPhase { connecting, launching, loading, buffering, playing, paused, idle, reconnecting, ended }

/// Why a session ended.
enum CastEnd {
  stopped, // by this app, by someone at the receiver, or our app there closing itself
  connectFailed,
  launchFailed, // the receiver did not open its media player
  cannotPlay, // none of the candidates played
  takenOver, // another app or another sender's media replaced ours
  lost, // the receiver could not be reached again, or forgot our session or our media
  finished, // the media played to its end
}

class CastException implements Exception {
  const CastException(this.end);

  final CastEnd end;

  @override
  String toString() => 'CastException(${end.name})';
}

class CastStatus {
  const CastStatus({
    required this.phase,
    this.position = Duration.zero,
    this.duration,
    this.volume,
    this.muted = false,
    this.end,
    this.candidate = 0,
  });

  final CastPhase phase;
  final Duration position;
  final Duration? duration; // null for live
  final double? volume; // the receiver's, 0 to 1
  final bool muted;
  final CastEnd? end; // with phase ended
  final int candidate; // which of the loaded candidates plays

  @override
  String toString() => 'CastStatus(${phase.name}${end == null ? '' : '/${end!.name}'}, $position, #$candidate)';
}

/// How long the session waits for what. Tests make them short.
class CastTimings {
  const CastTimings({
    this.heartbeat = const Duration(seconds: 5),
    this.deadline = const Duration(seconds: 15),
    this.launch = const Duration(seconds: 20),
    this.load = const Duration(seconds: 30),
    this.reconnect = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
      Duration(seconds: 15),
    ],
    this.poll = const Duration(seconds: 2),
  });

  final Duration heartbeat; // between PINGs
  final Duration deadline; // for a PONG, and for any reply
  final Duration launch; // for the media player to open
  final Duration load; // for a candidate to start
  final List<Duration> reconnect; // the waits before each try, once the link drops
  final Duration poll; // between status requests
}

/// A cast to one receiver, in its Default Media Receiver: launched or joined, loaded, controlled, and
/// followed through drops and other senders.
///
/// After [CastEnd.cannotPlay] or [CastEnd.finished] the link stays open: [load] again, or [stop]. Any
/// other end closes it, and [load] then throws.
class CastSession {
  CastSession._(this._host, this._port, this._timings);

  /// The Default Media Receiver: it needs no registration.
  static const appId = 'CC1AD845';

  static const _loadFailures = {'LOAD_FAILED', 'LOAD_CANCELLED', 'INVALID_REQUEST', 'ERROR'};

  /// The receiver's idle screen app, listed when nothing else runs.
  static const _backdrop = 'E8C28D3C';

  /// How close to its end a movie that went unseen counts as finished.
  static const _nearEnd = Duration(seconds: 5);

  final String _host;
  final int _port;
  final CastTimings _timings;
  final _status = ValueNotifier(const CastStatus(phase: CastPhase.connecting));
  CastLink? _link;
  StreamSubscription<CastReceived>? _sub;
  InternetAddress _local = InternetAddress.anyIPv4;
  InternetAddress? _remote;
  String? _sessionId; // our app's, on the receiver
  String? _transportId; // where its media messages go
  double? _volume;
  var _muted = false;
  Timer? _poll, _tick;
  final _asked = <int>{}; // requestIds of our media GET_STATUS not yet answered: their replies list all

  var _phase = CastPhase.connecting;
  CastEnd? _end;
  CastEnd? _closed; // why the link closed, once over: what load() throws
  var _over = false; // ended for good: the link is closed
  var _stopping = false; // stop() or detach() runs: what the receiver says is not a takeover
  Completer<bool>? _back; // while reconnecting: true once the link is back

  List<CastMedia> _candidates = const [];
  var _candidate = 0;
  var _loads = 0; // counts load() calls: a newer one supersedes the one before
  _Attempt? _attempt; // the LOAD waiting for an answer
  int? _mediaSessionId; // what our last LOAD produced, once the receiver says
  final _seen = <int>{}; // every media session id the receiver has mentioned
  var _reloaded = false; // a live channel gets one reload after an error
  Timer? _steady; // runs while a reload plays: once it has held, the next error gets a reload too

  // The last media status, for the position in between
  var _base = Duration.zero;
  var _rate = 1.0;
  final _since = Stopwatch();
  Duration? _duration;

  /// Connects (TLS, 10 s also for the handshake), CONNECT + heartbeat, launches or joins the Default
  /// Media Receiver CC1AD845. Throws CastException(connectFailed | launchFailed).
  static Future<CastSession> connect(String host, {int port = 8009, CastTimings timings = const CastTimings()}) async {
    final session = CastSession._(host, port, timings);
    await session._start();
    return session;
  }

  /// The local end of the link: the interface a relay binds to.
  InternetAddress get localAddress => _local;

  /// The receiver's address, once connected: the one a relay lets in.
  InternetAddress? get remoteAddress => _remote;

  ValueListenable<CastStatus> get status => _status;

  /// Tries [candidates] in order until one plays. One fails on LOAD_FAILED, LOAD_CANCELLED or
  /// INVALID_REQUEST to its LOAD, on IDLE/ERROR before it plays, or without BUFFERING or PLAYING
  /// within [CastTimings.load]. When none plays the phase is ended, with [CastEnd.cannotPlay].
  Future<void> load(List<CastMedia> candidates) async {
    if (_over || _stopping) throw CastException(_closed ?? CastEnd.stopped);
    _settle(_Outcome.over);
    final gen = ++_loads;
    _candidates = List.unmodifiable(candidates);
    _reloaded = false;
    await _run(gen, 0, _candidates.length);
  }

  Future<void> play() => _control({'type': 'PLAY'});

  Future<void> pause() => _control({'type': 'PAUSE'});

  Future<void> seek(Duration to) => _control({'type': 'SEEK', 'currentTime': to.inMilliseconds / 1000});

  /// The receiver's volume, 0 to 1.
  Future<void> setVolume(double level) => _receiverControl({
    'type': 'SET_VOLUME',
    'volume': {'level': level.clamp(0.0, 1.0)},
  });

  Future<void> setMuted(bool muted) => _receiverControl({
    'type': 'SET_VOLUME',
    'volume': {'muted': muted},
  });

  /// Stops the media and our app on the receiver, and closes the link: ended, [CastEnd.stopped]. While
  /// reconnecting it does so over a link of its own, for the receiver plays on without us.
  Future<void> stop() async {
    if (_over) return;
    _stopping = true;
    _loads++;
    _settle(_Outcome.over);
    final transport = _transportId, media = _mediaSessionId, session = _sessionId;
    var link = _link;
    CastLink? own;
    if (link == null && session != null) {
      try {
        link = own = await CastLink.connect(_host, _port, heartbeat: _timings.heartbeat, deadline: _timings.deadline);
        if (transport != null) own.open(transport);
      } on Object {
        // Out of reach: nothing to stop it with
      }
    }
    if (link != null) {
      if (transport != null && media != null) {
        link.sendRequest(CastNs.media, {'type': 'STOP', 'mediaSessionId': media}, to: transport);
      }
      if (session != null) {
        try {
          await link.request(CastNs.receiver, {'type': 'STOP', 'sessionId': session}, timeout: _timings.heartbeat);
        } on Object {
          // Closed below all the same
        }
      }
    }
    await own?.close();
    await _finish(CastEnd.stopped);
  }

  /// Closes the link and leaves the receiver playing: ended, [CastEnd.stopped], for this object only.
  /// No CLOSE is sent: a sender leaving on purpose may make a receiver stop once it has none left.
  Future<void> detach() async {
    if (_over) return;
    _stopping = true;
    _loads++;
    await _finish(CastEnd.stopped);
  }

  Future<void> _start() async {
    final CastLink link;
    try {
      link = await CastLink.connect(_host, _port, heartbeat: _timings.heartbeat, deadline: _timings.deadline);
    } on Object {
      _over = true;
      throw const CastException(CastEnd.connectFailed);
    }
    var failure = CastEnd.connectFailed;
    try {
      final status = await link.request(CastNs.receiver, {'type': 'GET_STATUS'}, timeout: _timings.deadline);
      var app = _app(status, (a) => a['appId'] == appId);
      if (app == null) {
        failure = CastEnd.launchFailed;
        _phase = CastPhase.launching;
        _publish();
        app = await _launch(link);
      } else {
        _readVolume(status);
      }
      _sessionId = app.sessionId;
      _transportId = app.transportId;
      link.open(app.transportId);
      // What plays already is another sender's, or ours from before: noted so it is not taken for
      // what our LOAD makes
      try {
        _noteSeen(
          await link.request(CastNs.media, {'type': 'GET_STATUS'}, to: app.transportId, timeout: _timings.deadline),
        );
      } on TimeoutException {
        // A player that does not say: nothing to note
      }
      if (link.isClosed) throw const SocketException.closed();
    } on Object {
      _over = true;
      await link.close();
      throw CastException(failure);
    }
    _attach(link);
    _phase = CastPhase.idle;
    _poll = Timer.periodic(_timings.poll, (_) => _pollStatus());
    // The position moves between statuses
    final tick = _timings.poll < const Duration(milliseconds: 500) ? _timings.poll : const Duration(milliseconds: 500);
    _tick = Timer.periodic(tick, (_) {
      if (_phase == CastPhase.playing) _publish();
    });
    _publish();
  }

  /// Launches the Default Media Receiver and waits until the receiver lists it.
  Future<_App> _launch(CastLink link) async {
    final done = Completer<_App>();
    late final int requestId;
    final sub = link.messages.listen(
      (m) {
        if (m.namespace != CastNs.receiver || done.isCompleted) return;
        final id = m.body['requestId'];
        if (m.body['type'] == 'LAUNCH_ERROR' && (id == requestId || id == null || id == 0)) {
          done.completeError(const CastException(CastEnd.launchFailed));
        } else if (m.body['type'] == 'RECEIVER_STATUS') {
          final app = _app(m.body, (a) => a['appId'] == appId);
          if (app == null) return;
          _readVolume(m.body);
          done.complete(app);
        }
      },
      onDone: () {
        if (!done.isCompleted) done.completeError(const CastException(CastEnd.launchFailed));
      },
    );
    requestId = link.sendRequest(CastNs.receiver, {'type': 'LAUNCH', 'appId': appId});
    try {
      return await done.future.timeout(_timings.launch);
    } finally {
      await sub.cancel();
    }
  }

  void _attach(CastLink link) {
    _asked.clear(); // request ids start again on each link
    _link = link;
    _local = link.localAddress;
    _remote = link.remoteAddress;
    _sub = link.messages.listen(_onMessage);
    link.done.then((_) => _onLinkDone(link));
  }

  /// The link dropped: try to get back to our app, or end if nothing is left to get back to.
  void _onLinkDone(CastLink link) {
    if (_over || link != _link) return;
    _sub?.cancel();
    _sub = null;
    _link = null;
    if (_stopping) {
      unawaited(_finish(CastEnd.stopped));
    } else if (_phase == CastPhase.ended) {
      unawaited(_finish(CastEnd.lost));
    } else {
      unawaited(_reconnect());
    }
  }

  /// Tries again after each of [CastTimings.reconnect]; our app must still run, found by its sessionId.
  Future<void> _reconnect() async {
    final back = _back ??= Completer<bool>(); // the same one when it dropped again on the way back
    _base = _position;
    _since.reset();
    final resume = _phase;
    _phase = CastPhase.reconnecting;
    if (_attempt != null) _mediaSessionId = null; // that LOAD goes again once back: what it made is not ours
    _settle(_Outcome.lost);
    _publish();
    for (final wait in _timings.reconnect) {
      await Future<void>.delayed(wait);
      // Not while stop() runs either: it has a link of its own, and one more would only be closed
      if (_over || _stopping) return;
      CastLink? link;
      try {
        link = await CastLink.connect(_host, _port, heartbeat: _timings.heartbeat, deadline: _timings.deadline);
        final status = await link.request(CastNs.receiver, {'type': 'GET_STATUS'}, timeout: _timings.deadline);
        if (_over || _stopping) return await link.close();
        final app = _app(status, (a) => a['sessionId'] == _sessionId);
        if (app == null) {
          await link.close();
          return await _finish(CastEnd.lost);
        }
        _readVolume(status);
        _transportId = app.transportId;
        link.open(app.transportId);
        _attach(link);
        // Not if it ended meanwhile, nor while stop() runs
        if (_phase == CastPhase.reconnecting && !_stopping) _phase = resume;
        _since.start();
        _publish();
        // Where it got to meanwhile, ours missing if it ended unseen. A LOAD that was waiting is sent
        // again after this: the media sessions listed now are not what it makes
        try {
          final reply = await link.request(
            CastNs.media,
            {'type': 'GET_STATUS'},
            to: app.transportId,
            timeout: _timings.deadline,
          );
          _noteSeen(reply);
          final statuses = reply['status'];
          if (statuses is List) _checkOurs(statuses);
        } on Object {
          // The polls tell
        }
        if (_over || _link != link) return; // dropped again: that reconnect goes on with [back]
        _back = null;
        back.complete(true);
        return;
      } on Object {
        await link?.close();
        if (_over) return;
      }
    }
    await _finish(CastEnd.lost);
  }

  /// Runs candidates [from] to [to] (excluded) for the load() numbered [gen].
  Future<void> _run(int gen, int from, int to) async {
    _mediaSessionId = null; // what played before is not followed any more, even while the link is down
    var i = from;
    while (i < to) {
      if (gen != _loads || _over) return;
      final back = _back;
      if (back != null) {
        if (!await back.future) return;
        continue;
      }
      switch (await _try(i)) {
        case _Outcome.playing || _Outcome.over:
          return;
        case _Outcome.failed:
          i++;
        case _Outcome.lost:
          break; // the same one once the link is back
      }
    }
    if (gen == _loads && !_over) await _finish(CastEnd.cannotPlay, keep: true);
  }

  /// Sends the LOAD of candidate [i]; completes with how it went.
  Future<_Outcome> _try(int i) {
    final link = _link!, transport = _transportId!, media = _candidates[i];
    _candidate = i;
    _phase = CastPhase.loading;
    _end = null;
    _mediaSessionId = null; // statuses of the one before are not ours any more
    _steady?.cancel();
    _steady = null;
    _duration = null;
    _base = media.live ? Duration.zero : media.startAt ?? Duration.zero;
    _since.reset();
    _publish();
    final body = _fit(_loadRequest(media), transport);
    if (body == null) return Future.value(_Outcome.failed);
    final before = {..._seen};
    final a = _attempt = _Attempt(link.sendRequest(CastNs.media, body, to: transport), media, before);
    a.timer = Timer(_timings.load, () {
      if (_attempt == a) _settle(_Outcome.failed);
    });
    return a.result.future;
  }

  Map<String, dynamic> _loadRequest(CastMedia media) => {
    'type': 'LOAD',
    'sessionId': _sessionId,
    'media': media.toLoad(),
    'autoplay': true,
    if (!media.live && media.startAt != null) 'currentTime': media.startAt!.inMilliseconds / 1000,
  };

  /// [body], with its metadata cut down until it fits in a frame; null when even the bare media does
  /// not.
  Map<String, dynamic>? _fit(Map<String, dynamic> body, String to) {
    bool fits() =>
        CastMessage(
          source: CastLink.senderId,
          destination: to,
          namespace: CastNs.media,
          payload: jsonEncode({'requestId': 0x7fffffff, ...body}),
        ).frameSize <=
        CastMessage.maxFrame;
    final metadata = (body['media'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>;
    final cuts = <void Function()>[
      () => metadata.remove('images'),
      () => metadata.remove('subtitle'),
      () {
        for (final key in ['title', 'seriesTitle']) {
          final v = metadata[key];
          if (v is String && v.length > 200) metadata[key] = v.substring(0, 200);
        }
      },
      () => metadata.removeWhere((key, _) => key != 'metadataType'),
    ];
    for (final cut in cuts) {
      if (fits()) return body;
      cut();
    }
    return fits() ? body : null;
  }

  /// BUFFERING: the candidate started in time. An IDLE/ERROR still makes way for the next until it
  /// plays; after as long again buffering it is taken as the one, playing slowly.
  void _started() {
    final a = _attempt;
    if (a == null || a.started) return;
    a.started = true;
    a.timer?.cancel();
    a.timer = Timer(_timings.load, () {
      if (_attempt == a) _settle(_Outcome.playing);
    });
  }

  void _settle(_Outcome outcome) {
    final a = _attempt;
    if (a == null) return;
    _attempt = null;
    a.timer?.cancel();
    a.result.complete(outcome);
  }

  void _onMessage(CastReceived m) {
    if (_over) return;
    final type = m.body['type'];
    switch (m.namespace) {
      case CastNs.connection:
        if (type != 'CLOSE' || _stopping) return;
        if (m.from == _transportId) {
          unawaited(_onAppClosed());
        } else if (m.from == CastLink.receiverId) {
          unawaited(_link?.close()); // as a dropped link
        }
      case CastNs.receiver:
        if (type == 'RECEIVER_STATUS') _onReceiverStatus(m.body);
      case CastNs.media:
        final id = m.body['requestId'];
        if (type == 'MEDIA_STATUS') {
          _onMediaStatus(id is int ? id : 0, m.body['status']);
        } else if (_loadFailures.contains(type) && id is int && id == _attempt?.requestId) {
          _settle(_Outcome.failed);
        }
    }
  }

  void _onReceiverStatus(Map<String, dynamic> body) {
    _readVolume(body);
    if (!_stopping && _app(body, (a) => a['sessionId'] == _sessionId) == null) return _appGone(body);
    _publish();
  }

  /// Our app closed its connection to us. What runs now is asked, for the CLOSE may come before the
  /// receiver's status, or alone.
  Future<void> _onAppClosed() async {
    final link = _link;
    if (link == null) return;
    var status = const <String, dynamic>{};
    try {
      status = await link.request(CastNs.receiver, {'type': 'GET_STATUS'}, timeout: _timings.deadline);
    } on TimeoutException {
      // Not said: no other app is known
    } on Object {
      return; // the link went down: the reconnect finds out
    }
    if (_over || _stopping || link != _link) return;
    _appGone(status);
  }

  /// Our app no longer runs. Another app in its place took the receiver over; none, or only the idle
  /// screen, means it closed: stopped with the TV's remote, or on its own after a while idle.
  void _appGone(Map<String, dynamic> receiverStatus) {
    final apps = _object(receiverStatus['status'])?['applications'];
    final other =
        apps is List &&
        apps.any(
          (a) =>
              a is Map<String, dynamic> &&
              a['sessionId'] != _sessionId &&
              a['isIdleScreen'] != true &&
              a['appId'] != _backdrop,
        );
    unawaited(_finish(other ? CastEnd.takenOver : CastEnd.stopped));
  }

  void _onMediaStatus(int requestId, Object? statuses) {
    if (statuses is! List || _stopping) return;
    final full = requestId != 0 && _asked.remove(requestId); // a reply to our GET_STATUS: all there is
    for (final item in statuses) {
      if (item is! Map<String, dynamic>) continue;
      final id = _idOf(item);
      if (id == null) continue;
      final a = _attempt;
      // Ours is new since the LOAD and answers it by its requestId; or (Google TV) comes with
      // requestId 0 and our content, the newest if more do. The requestId outranks the content
      if (a != null && id != _mediaSessionId && !a.before.contains(id)) {
        final known = _mediaSessionId;
        if (requestId == a.requestId) {
          _mediaSessionId = id;
          a.answered = true;
        } else if (!a.answered && (known == null || id > known) && _isFor(item, a.media)) {
          _mediaSessionId = id;
        }
      }
      _seen.add(id);
      if (id == _mediaSessionId) _apply(item);
      if (_over) return;
    }
    if (full) _checkOurs(statuses);
  }

  /// [statuses] list all our app has; ours missing while no LOAD waits means it ended unseen, as when
  /// its IDLE came while the link was down. Another session in its place took over; with none, it
  /// finished if it was near its end, else the receiver forgot it.
  void _checkOurs(List<dynamic> statuses) {
    final ours = _mediaSessionId;
    if (ours == null || _attempt != null || _stopping || _over) return;
    final ids = {
      for (final s in statuses)
        if (s is Map<String, dynamic>) _idOf(s),
    }..remove(null);
    if (ids.contains(ours)) return;
    final d = _duration, live = _candidate < _candidates.length && _candidates[_candidate].live;
    if (ids.isNotEmpty) {
      unawaited(_finish(CastEnd.takenOver));
    } else if (!live && d != null && _position >= d - _nearEnd) {
      unawaited(_finish(CastEnd.finished, keep: true));
    } else {
      unawaited(_finish(CastEnd.lost));
    }
  }

  static int? _idOf(Map<String, dynamic> status) {
    final id = status['mediaSessionId'] ?? _object(status['extendedStatus'])?['mediaSessionId'];
    return id is int ? id : null;
  }

  static bool _isFor(Map<String, dynamic> status, CastMedia media) {
    for (final m in [_object(status['media']), _object(_object(status['extendedStatus'])?['media'])]) {
      if (m != null && (m['contentId'] == media.url || m['contentUrl'] == media.url)) return true;
    }
    return false;
  }

  /// A status of our media session.
  void _apply(Map<String, dynamic> s) {
    final media = _object(s['media']);
    final d = media?['duration'];
    if (d is num && d > 0 && d.isFinite) _duration = Duration(milliseconds: (d * 1000).round());
    final t = s['currentTime'], r = s['playbackRate'];
    // Not an IDLE's: a receiver that lost the stream may say 0, which saved would lose where one was
    _base = s['playerState'] != 'IDLE' && t is num ? Duration(milliseconds: (t * 1000).round()) : _position;
    _rate = r is num ? r.toDouble() : 1;
    _since
      ..reset()
      ..start();
    switch (s['playerState']) {
      case 'PLAYING' || 'BUFFERING' || 'PAUSED':
        _phase = switch (s['playerState']) {
          'PLAYING' => CastPhase.playing,
          'PAUSED' => CastPhase.paused,
          _ => CastPhase.buffering,
        };
        if (_phase == CastPhase.buffering) {
          _started();
        } else {
          _settle(_Outcome.playing);
        }
        // A reload still playing after as long as a load may take did its job: the next error gets one too
        if (_phase == CastPhase.playing && _reloaded) {
          _steady ??= Timer(_timings.load, () {
            _steady = null;
            if (_phase == CastPhase.playing) _reloaded = false;
          });
        }
      case 'IDLE':
        switch (s['idleReason']) {
          case 'ERROR':
            if (_attempt != null) {
              _settle(_Outcome.failed);
            } else {
              _failedWhilePlaying();
            }
            return;
          case 'FINISHED':
            _base = _duration ?? _position; // played to its end: seen whole
            unawaited(_finish(CastEnd.finished, keep: true));
            return;
          case 'INTERRUPTED':
            unawaited(_finish(CastEnd.takenOver)); // another sender's LOAD replaced ours
            return;
          case 'CANCELLED':
            if (!_stopping) unawaited(_finish(CastEnd.stopped)); // stopped at the receiver
            return;
          default: // IDLE with LOADING in extendedStatus, or before it starts: still loading
            final loading = _object(s['extendedStatus'])?['playerState'] == 'LOADING';
            _phase = _attempt != null || loading ? CastPhase.loading : CastPhase.idle;
        }
    }
    _publish();
  }

  /// IDLE/ERROR once it played: a live channel is loaded once more, anything else cannot play. So is a
  /// live channel whose reload fails before it has held.
  void _failedWhilePlaying() {
    final media = _candidates[_candidate];
    if (media.live && !_reloaded) {
      _reloaded = true;
      unawaited(_run(++_loads, _candidate, _candidate + 1));
    } else {
      unawaited(_finish(CastEnd.cannotPlay, keep: true));
    }
  }

  void _noteSeen(Map<String, dynamic> reply) {
    final statuses = reply['status'];
    if (statuses is! List) return;
    for (final s in statuses) {
      final id = s is Map<String, dynamic> ? s['mediaSessionId'] : null;
      if (id is int) _seen.add(id);
    }
  }

  void _pollStatus() {
    final link = _link, transport = _transportId;
    if (link == null || transport == null || (_attempt == null && _mediaSessionId == null)) return;
    _asked.add(link.sendRequest(CastNs.media, {'type': 'GET_STATUS'}, to: transport));
    if (_asked.length > 8) _asked.remove(_asked.first); // never answered
  }

  Future<void> _control(Map<String, dynamic> body) async {
    final link = _link, transport = _transportId, media = _mediaSessionId;
    if (link == null || transport == null || media == null) return;
    try {
      await link.request(CastNs.media, {...body, 'mediaSessionId': media}, to: transport, timeout: _timings.deadline);
    } on Object {
      // The status says how it went
    }
  }

  Future<void> _receiverControl(Map<String, dynamic> body) async {
    final link = _link;
    if (link == null) return;
    try {
      await link.request(CastNs.receiver, body, timeout: _timings.deadline);
    } on Object {
      // The status says how it went
    }
  }

  /// Ends with [end]. With [keep] (cannot play, finished) the link stays for another load; when it then
  /// closes on its own (the app idles out, a drop) the status keeps that end, and [load] throws [end].
  /// While stop() or detach() runs the end is [CastEnd.stopped], unless it had ended already: what
  /// ended it (cannot play, finished) is what is said, not the stop that followed.
  Future<void> _finish(CastEnd end, {bool keep = false}) async {
    if (_over || (_stopping && keep)) return;
    final why = _stopping ? CastEnd.stopped : end;
    final earlier = !keep && _phase == CastPhase.ended ? _end : null;
    _base = _position;
    _since.reset();
    _phase = CastPhase.ended;
    _end = earlier ?? why;
    _settle(_Outcome.over);
    _mediaSessionId = null;
    _steady?.cancel();
    _steady = null;
    if (!keep) {
      _over = true;
      _closed = why;
      _poll?.cancel();
      _tick?.cancel();
      _back?.complete(false);
      _back = null;
    }
    if (earlier == null) _publish(); // otherwise nothing new to show
    if (!keep) {
      final link = _link;
      _link = null;
      await _sub?.cancel();
      await link?.close();
    }
  }

  void _readVolume(Map<String, dynamic> body) {
    final volume = _object(_object(body['status'])?['volume']);
    final level = volume?['level'], muted = volume?['muted'];
    if (level is num) _volume = level.toDouble();
    if (muted is bool) _muted = muted;
  }

  Duration get _position {
    var p = _base;
    if (_phase == CastPhase.playing) p += _since.elapsed * _rate;
    final d = _duration;
    if (d != null && p > d) p = d;
    return p < Duration.zero ? Duration.zero : p;
  }

  void _publish() => _status.value = CastStatus(
    phase: _phase,
    position: _position,
    duration: _duration,
    volume: _volume,
    muted: _muted,
    end: _end,
    candidate: _candidate,
  );

  /// The first app in a RECEIVER_STATUS that [pick] takes; never just the first one listed (the
  /// Backdrop app may come before ours).
  static _App? _app(Map<String, dynamic> body, bool Function(Map<String, dynamic> app) pick) {
    final apps = _object(body['status'])?['applications'];
    if (apps is! List) return null;
    for (final a in apps) {
      if (a is! Map<String, dynamic> || !pick(a)) continue;
      final session = a['sessionId'], transport = a['transportId'];
      if (session is String && transport is String) return (sessionId: session, transportId: transport);
    }
    return null;
  }

  static Map<String, dynamic>? _object(Object? v) => v is Map<String, dynamic> ? v : null;
}

typedef _App = ({String sessionId, String transportId});

enum _Outcome { playing, failed, lost, over }

/// A LOAD sent and not yet answered.
class _Attempt {
  _Attempt(this.requestId, this.media, this.before);

  final int requestId;
  final CastMedia media;
  final Set<int> before; // media session ids seen before it: none of them is its
  final result = Completer<_Outcome>();
  Timer? timer;
  var answered = false; // its media session came by its requestId
  var started = false; // it went BUFFERING
}
