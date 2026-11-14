import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../data/matching.dart';
import '../data/models.dart';
import '../data/settings.dart';
import '../data/source.dart';
import '../data/trending.dart';
import '../device.dart';
import 'backdrop.dart';

/// A trailer playing silently behind a hero page, the way streaming services do: YouTube's own
/// player (its terms allow no other), without controls, for a short stretch past the studio logos.
/// It fades in once it plays and calls [onEnd] when the stretch is over; until then, and when it
/// cannot play, the page's backdrop shows. Only while its screen is on top.
class TrailerBackdrop extends StatefulWidget {
  const TrailerBackdrop({super.key, required this.load, required this.onPlaying, required this.onEnd});

  /// The YouTube id of the trailer, or null.
  final Future<String?> Function() load;

  /// Whether the trailer is on screen; false too when it cannot play.
  final ValueChanged<bool> onPlaying;
  final VoidCallback onEnd;

  /// Where a web view can show YouTube's player; elsewhere (Linux, tests) only the backdrops. Not
  /// with little memory: the player's web view takes more than a 1 GB TV stick has to spare.
  static bool get supported =>
      !kIsWeb &&
      !lowMemory &&
      PosterBackdrop.motion &&
      InAppWebViewPlatform.instance != null && // none in unit tests, which pass for Android
      const {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }.contains(defaultTargetPlatform);

  static const delay = Duration(milliseconds: 2500); // the backdrop first, then it comes to life
  // Seconds: from just before the logos end, as it plays unseen for [reveal]; about 23 on screen
  static const start = 6, length = 27;

  /// After it starts playing: YouTube hides what it puts over the start (title, pause, its logo)
  /// about 3 s in (measured in Edge, as WebView2 on Windows, 2026-11-13), and it is not shown before.
  static const reveal = Duration(seconds: 4);

  @override
  State<TrailerBackdrop> createState() => _TrailerBackdropState();
}

class _TrailerBackdropState extends State<TrailerBackdrop> {
  String? _url; // the page that plays it
  String? _waiting; // the page, held while another screen covers this one
  var _asleep = false; // out of sight when it was to start: nothing asked for until it is back
  var _shown = false;
  var _over = false;
  Timer? _timer, _reveal;

  // The web view exists on the platform's side. Removed before that, the plugin updates a view that
  // is gone (flutter_inappwebview_windows 0.7.0-beta.3), so a covered screen keeps it till then
  var _created = false;

  // Web views are made one after another: two made at once fail on Windows (the same plugin). Each
  // waits for the one before to exist, or for a few seconds
  static Future<void> _queue = Future.value();
  final _made = Completer<void>();

  void _madeNow() {
    if (!_made.isCompleted) _made.complete();
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer(TrailerBackdrop.delay, _start);
  }

  Future<void> _start() async {
    if (!mounted) return;
    // On a tab out of sight or under another screen: which trailer, and its page, are asked for
    // once it is back, not for a hero nobody may come back to
    if (!_inSight) {
      _asleep = true;
      return;
    }
    // "Only on Wi-Fi": none on mobile data, asked as each would start (the network may change)
    if (SettingsScope.maybeOf(context)?.trailers == 'wifi' && await networkMetered()) {
      if (mounted) widget.onPlaying(false);
      return;
    }
    if (!mounted) return;
    final id = await widget.load();
    final url = id == null ? null : await _Host.page(id);
    if (!mounted) return;
    if (url == null) return widget.onPlaying(false);
    final before = _queue;
    _queue = _made.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    await before;
    if (!mounted) return;
    // A web view is not made while another screen covers this one, or as this one goes: on
    // Windows it fails there (the same plugin). It is made once this one is in sight again
    if (!_inSight) {
      _waiting = url;
      return;
    }
    _play(url);
  }

  void _play(String url) {
    setState(() => _url = url);
    // In case the player never says it is done
    _timer = Timer(const Duration(seconds: TrailerBackdrop.length + 15), _end);
  }

  /// On the tab shown, and on the screen on top: not one another is coming over (its tickers still
  /// run while it slides in) or one going away.
  bool get _inSight => TickerMode.valuesOf(context).enabled && (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asleep && _inSight) {
      // Back in sight: the backdrop for a moment again, then the trailer as when it first came
      _asleep = false;
      _timer?.cancel();
      _timer = Timer(TrailerBackdrop.delay, _start);
      return;
    }
    final url = _waiting;
    if (url != null && _inSight) {
      // In sight again: the backdrop first, as when it came, then the trailer. Not at once: one
      // passing through (its screen closed right away) would be made only to be removed while it
      // is made, which fails on Windows (the same plugin)
      _waiting = null;
      _timer?.cancel();
      _timer = Timer(TrailerBackdrop.delay, () {
        if (!mounted) return;
        _inSight ? _play(url) : _waiting = url;
      });
    }
  }

  @override
  void dispose() {
    _madeNow(); // the next one need not wait for it
    _timer?.cancel();
    _reveal?.cancel();
    super.dispose();
  }

  void _message(String m) {
    if (!mounted || _over) return;
    switch (m) {
      case '1': // playing
        // Shown later, once YouTube has hidden what it puts over the start (title, pause)
        _reveal ??= Timer(TrailerBackdrop.reveal, () {
          if (mounted && !_over) setState(() => _shown = true);
        });
        widget.onPlaying(true);
      case '0': // ended: at the end of the stretch
        _end();
      case final e when e.startsWith('error'):
        debugPrint('Trailer: YouTube $e');
        setState(() => _over = true);
        widget.onPlaying(false);
    }
  }

  /// Fades out, then lets the carousel move on.
  void _end() {
    if (!mounted || _over) return;
    setState(() {
      _over = true;
      _shown = false;
    });
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      widget.onPlaying(false);
      widget.onEnd();
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    // Another tab or screen on top: no player, and no sound or data spent on it, once it may go
    final covered = !_inSight;
    if (url == null || (covered && _created)) return const SizedBox.shrink();
    // Never a place for the remote: the web view can take the focus (Android's platform view), and
    // from behind the page's buttons, unseen and with no ring, its middle drew the arrows away from them
    return ExcludeFocus(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _shown && !covered ? 1 : 0,
          duration: const Duration(milliseconds: 800),
          child: _over && !_shown
              ? const SizedBox.expand()
              : InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(url)),
                  initialSettings: InAppWebViewSettings(
                    // Nothing YouTube sets (cookies, storage) is kept for the next trailer
                    incognito: true,
                    cacheEnabled: false,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    transparentBackground: true,
                    supportZoom: false,
                    disableContextMenu: true,
                    disableHorizontalScroll: true,
                    disableVerticalScroll: true,
                  ),
                  // Only from the page the app serves itself, never from what YouTube's player loads
                  onWebViewCreated: (c) {
                    c.addJavaScriptHandler(
                      handlerName: 'trailer',
                      callback: (JavaScriptHandlerFunctionData data) {
                        if (data.isMainFrame && data.origin.host == '127.0.0.1') _message('${data.args.firstOrNull}');
                      },
                    );
                    _madeNow();
                    // Covered while it was being made: it can go now
                    if (mounted) setState(() => _created = true);
                  },
                ),
        ),
      ),
    );
  }
}

/// Serves the page the player is embedded in, on this device only. YouTube's player refuses to
/// play ("player configuration error") unless the page that embeds it has an address, which pages
/// loaded from memory lack on some platforms (Windows); a page on 127.0.0.1 has one everywhere.
class _Host {
  static Future<String?>? _origin;

  /// The address of the page that plays [id], or null when the server cannot start.
  static Future<String?> page(String id) async {
    final origin = await (_origin ??= _start());
    return origin == null ? null : '$origin/trailer?v=${Uri.encodeQueryComponent(id)}';
  }

  static Future<String?> _start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      server.listen((req) {
        final id = req.uri.queryParameters['v'] ?? '';
        final res = req.response;
        if (req.method != 'GET' || req.uri.path != '/trailer' || !RegExp(r'^[\w-]{6,20}$').hasMatch(id)) {
          res.statusCode = HttpStatus.notFound;
        } else {
          res.headers.contentType = ContentType.html;
          res.write(_page(id, origin));
        }
        res.close();
      });
      return origin;
    } on SocketException catch (e) {
      debugPrint('Trailer: $e');
      _origin = null; // tried again next time
      return null;
    }
  }

  /// YouTube's player covering the page like a backdrop, muted, without controls, playing
  /// [TrailerBackdrop.length] seconds; it reports its state to the app. Muted, YouTube turns its
  /// captions on by itself: they go as it plays.
  static String _page(String id, String origin) =>
      '''
<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{margin:0;height:100%;overflow:hidden;background:transparent}
#p{position:absolute;top:50%;left:50%;width:100vw;height:56.25vw;min-height:100vh;min-width:177.78vh;transform:translate(-50%,-50%);pointer-events:none}
</style></head>
<body><div id="p"></div>
<script>
function send(m){window.flutter_inappwebview.callHandler('trailer',String(m))}
function onYouTubeIframeAPIReady(){
  new YT.Player('p',{
    videoId:'$id',
    host:'https://www.youtube-nocookie.com',
    playerVars:{autoplay:1,mute:1,controls:0,disablekb:1,fs:0,iv_load_policy:3,playsinline:1,rel:0,
      start:${TrailerBackdrop.start},end:${TrailerBackdrop.start + TrailerBackdrop.length},origin:'$origin'},
    events:{
      onReady:function(e){e.target.mute();setTimeout(function(){var s=e.target.getPlayerState();if(s===-1||s===5)e.target.playVideo()},1500)},
      onStateChange:function(e){if(e.data===1){e.target.unloadModule('captions');e.target.unloadModule('cc')}send(e.data)},
      onError:function(e){send('error '+e.data)}
    }
  });
}
</script>
<script src="https://www.youtube.com/iframe_api" onerror="send('error')"></script>
</body></html>
''';
}

/// By the source, as ids are each provider's (another playlist's movie 12 is another movie).
final _movieTrailers = Expando<Map<String, Future<String?>>>();

/// The trailer of a provider's movie: the provider's own from its full record, else TMDB's; once
/// per movie while its playlist is open.
Future<String?> movieTrailer(ContentSource source, Movie movie) =>
    (_movieTrailers[source] ??= {})[movie.id] ??= () async {
      var m = movie;
      if (source case final MovieDetails s) {
        try {
          m = await s.movieDetail(movie);
        } on Object {
          // The listing's name and year will do
        }
      }
      return youtubeId(m.trailer) ??
          await Trending.findTrailer(
            series: false,
            tmdbId: m.tmdbId,
            title: m.name,
            originalTitle: m.originalName,
            year: m.year ?? yearInTitle(m.name),
          );
    }();

/// The trailer of a provider's series: its own, else TMDB's. Series records rarely carry a TMDB id,
/// so by name and year.
Future<String?> seriesTrailer(Series s) async =>
    youtubeId(s.trailer) ??
    await Trending.findTrailer(series: true, tmdbId: s.tmdbId, title: s.name, year: s.year ?? yearInTitle(s.name));
