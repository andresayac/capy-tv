// Why a stream did not open, as far as it can be told: what mpv's log says, the server asked for
// its first byte when mpv said nothing, and a provider's refusal looked into (an account that
// ended, every connection it allows in use); and how the "unavailable" panel says it. A part of
// player_screen.dart: the screen mixes it in, and gives it what it names below.
part of 'player_screen.dart';

mixin _PlayerFailure on State<PlayerScreen> {
  // What it needs of the player screen
  Player get player;
  PlayItem get _stream; // the copy that did not open
  int get _session; // a new one per item opened: a late answer knows it is stale
  bool get _failed; // the "unavailable" panel shows

  _FailCause? _failCause; // what mpv said of the stream that did not open

  /// mpv does not always say why a stream did not open (it may read a 404's page as a playlist):
  /// the server is asked once, for its first byte, and its answer read.
  Future<void> _askWhy() async {
    final stream = _stream, session = _session;
    _FailCause? cause;
    try {
      // package:http, not dart:io's HttpClient: on the web the latter exists but throws when used
      final res = await http
          .get(Uri.parse(stream.url), headers: {...stream.headers, 'Range': 'bytes=0-0'})
          .timeout(const Duration(seconds: 5));
      cause = switch (res.statusCode) {
        404 || 410 => _FailCause.missing,
        401 || 403 => _FailCause.denied,
        _ => null,
      };
    } on Object {
      // A network that never answered (or a browser that would not make the request): the usual
      cause = _FailCause.network;
    }
    if (cause != null && mounted && session == _session && _failed) _setCause(cause);
  }

  /// Why it did not open, as far as it is known; a provider's refusal is looked into: the account
  /// may have ended, or every connection it allows be in use elsewhere.
  void _setCause(_FailCause cause) {
    setState(() => _failCause = cause);
    if (cause == _FailCause.denied) unawaited(_askAccount());
  }

  Future<void> _askAccount() async {
    final session = _session;
    if (currentCatalog.value?.source case final XtreamSource x) {
      _FailCause? cause;
      try {
        final info = await x.login();
        final most = info.maxConnections, now = info.activeConnections;
        if (most != null && now != null && now >= most) cause = _FailCause.busy;
      } on SourceException catch (e) {
        if (e.error == SourceError.inactiveAccount) cause = _FailCause.expired;
      } on Object {
        // Nothing more to tell
      }
      if (cause != null && mounted && session == _session && _failCause == _FailCause.denied) {
        setState(() => _failCause = cause);
      }
    }
  }

  /// What the "unavailable" panel says of why.
  String _failureText(AppLocalizations l) =>
      // The stream opened but its picture never moved: likely the device's hardware decoder
      widget.engine.hardware && (player.state.width ?? 0) > 0
      ? l.decoderHint
      : switch (_failCause) {
          _FailCause.missing => l.failMissing,
          _FailCause.denied => l.failDenied,
          _FailCause.expired => l.failExpired,
          _FailCause.busy => l.failBusy,
          _FailCause.network => l.failNetwork,
          _FailCause.unsupported => kIsWeb ? l.failUnsupportedHere : l.failUnsupported,
          null => l.unavailableHint,
        };
}

/// Why a stream did not open, as far as mpv's log tells.
enum _FailCause { missing, denied, expired, busy, network, unsupported }

_FailCause? _causeOf(String line) {
  final status = int.tryParse(RegExp(r'HTTP error (\d{3})').firstMatch(line)?.group(1) ?? '');
  if (status == 404 || status == 410) return _FailCause.missing;
  if (status == 401 || status == 403) return _FailCause.denied;
  final l = line.toLowerCase();
  const network = [
    'failed to resolve',
    'connection refused',
    'network is unreachable',
    'timed out',
    'no route to host',
  ];
  if (network.any(l.contains)) return _FailCause.network;
  const unsupported = ['failed to recognize file format', 'codec not found', 'unsupported codec'];
  return unsupported.any(l.contains) ? _FailCause.unsupported : null;
}
