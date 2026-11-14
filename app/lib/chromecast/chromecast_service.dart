import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/catalog.dart';
import '../data/combined.dart';
import '../data/library.dart';
import '../data/m3u.dart';
import '../data/source.dart';
import '../data/xtream.dart';
import '../player/background_play.dart';
import '../player/play.dart';
import 'cast_discovery.dart';
import 'cast_plan.dart';
import 'cast_relay.dart';
import 'cast_session.dart';
import 'hls_rewrite.dart';

/// What a Chromecast plays for this app: the device, the item, the session, and the relay a live
/// channel goes through.
/// What kept a cast through the relay from playing (see [ChromecastCast.trouble]).
enum CastTrouble { unreached, refused }

class ChromecastCast {
  ChromecastCast._(this.device, this.item, this.session, this._relay, this.plan, this._words, this._library);

  final ChromecastDevice device;
  final PlayItem item;
  final CastSession session;
  final CastRelay? _relay;
  final CastPlan plan;
  final CastWords? _words;
  final Library? _library; // the profile's and playlist's it was cast from, whatever is open later
  DateTime? _saved;

  /// Why the TV could not play it, when the relay it went through can tell: the TV never reached
  /// this device, or the provider refused the account. Null otherwise, and for a copy the TV
  /// played straight from the provider.
  CastTrouble? get trouble {
    final relay = _relay, st = session.status.value, candidates = plan.candidates;
    if (relay == null || st.candidate >= candidates.length) return null;
    if (candidates[st.candidate].route == CastRoute.direct) return null;
    if (!relay.reached) return CastTrouble.unreached;
    return switch (relay.refused) {
      401 || 403 => CastTrouble.refused, // unauthorized, forbidden
      _ => null,
    };
  }

  ({CastPhase phase, Duration? duration})? _told; // what the notification was last told
  VoidCallback? _listener;
  var _over = false;

  ValueListenable<CastStatus> get status => session.status;
}

/// The notification's words, in the app's language: "Casting to" its device, and its buttons'.
typedef CastWords = ({String castingTo, Map<String, String> labels});

/// The plan refuses the item: why, for the dialog to say.
class ChromecastRefused implements Exception {
  const ChromecastRefused(this.plan);

  final CastPlan plan;
}

/// Chromecasts for this app: finding them on this network and the one cast at a time, which goes
/// on when the player closes (the Home chip leads back to it).
class ChromecastService {
  ChromecastService._();

  static final instance = ChromecastService._();

  /// The cast on now; null when none.
  final current = ValueNotifier<ChromecastCast?>(null);

  /// Chromecasts found on this network so far.
  final devices = ValueNotifier<List<ChromecastDevice>>(const []);

  /// Chromecasts reached by an address typed by hand (where they are not found: another network
  /// through a VPN, a Wi-Fi that keeps devices apart), the latest first.
  final typed = ValueNotifier<List<ChromecastDevice>>(const []);
  static const _typedKey = 'chromecast.addresses';

  @visibleForTesting
  static CastDiscovery Function()? discoveryForTests;

  CastDiscovery? _discovery;
  var _generation = 0; // a cast that connects after a newer one, or after a stop, is given up

  /// The device the latest cast goes to; none after a stop. A cast given up while it connected
  /// leaves the receiver's app running when a newer one goes to the same device, which joins it.
  String? _castingTo;

  /// Looks for Chromecasts while "Send to" shows them, until [stopDiscovery]: each time afresh, so
  /// a search that failed or stalled before gets another go rather than none until a restart. On
  /// Windows, where starting and stopping the system's search over and over fails, its browser
  /// stays alive between them and only its rounds end (see BonsoirCastDiscovery.keepAlive).
  Future<void> discover() async {
    var discovery = _discovery;
    if (discovery == null) {
      // Made and listened to before anything waits: two openings at once share one
      discovery = _discovery = discoveryForTests?.call() ?? BonsoirCastDiscovery();
      discovery.devices.listen((found) => devices.value = found);
      final prefs = await SharedPreferences.getInstance();
      typed.value = [for (final a in prefs.getStringList(_typedKey) ?? const <String>[]) ?parseCastAddress(a)];
    }
    try {
      await discovery.start();
    } on Object catch (e) {
      debugPrint('chromecast: discovery: $e'); // "Connect by address" still works
    }
  }

  /// Stops looking: the network is no longer asked, and on Android its multicast lock goes.
  Future<void> stopDiscovery() async {
    try {
      await _discovery?.stop();
    } on Object catch (e) {
      debugPrint('chromecast: discovery: $e');
    }
  }

  /// Keeps [device], typed by hand, for next time.
  Future<void> remember(ChromecastDevice device) async {
    final list = [device, ...typed.value.where((d) => d.id != device.id)].take(5).toList();
    typed.value = list;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_typedKey, [for (final d in list) '${d.host}:${d.port}']);
  }

  /// Casts [item] to [device] from [from] (movies and episodes). Throws [ChromecastRefused] for
  /// what cannot be cast, [CastException] when the device cannot be reached or does not start;
  /// how the loading goes then shows in the cast's status.
  ///
  /// On phones and tablets a notification stays while it casts, with its controls: it keeps this
  /// device going with the screen off, which a channel relayed from here needs.
  Future<ChromecastCast> cast(
    ChromecastDevice device,
    PlayItem item, {
    Duration? from,
    CastWords? words,
    Library? library,
  }) async {
    final generation = ++_generation; // at once: a stop from now on gives this one up
    _castingTo = device.id;
    // Whose it is, as it is asked for: another profile may be in by the time the TV answers
    final lib = library ?? currentLibrary.value;
    // What the list says its streams need (an M3U's User-Agent), whichever screen it is sent from:
    // only the player's queue had it, and a title's page sent it without
    if (currentCatalog.value?.source case final source?) item = item.withHeaders(source.headersFor);
    // Refused before what casts now is cut off for it
    final plan = planFor(item);
    if (!plan.castable) throw ChromecastRefused(plan);
    await _stopCurrent();
    final session = await CastSession.connect(device.host, port: device.port);
    // Stopped, or another cast asked for, while it connected: the TV does not start. A newer one
    // to this same TV has joined the receiver's app: let go of it without stopping it
    Future<Never> givenUp(CastRelay? relay) async {
      await (_castingTo == device.id ? session.detach() : session.stop());
      await relay?.close();
      throw const CastException(CastEnd.stopped);
    }

    if (generation != _generation) await givenUp(null);
    CastRelay? relay;
    if (plan.candidates.any((c) => c.route != CastRoute.direct)) {
      // On the interface the device reached this one through; it alone may fetch
      // F04-020: a relay that cannot start leaves no session open on the TV, with no one to end it
      try {
        relay = await CastRelay.start(session.localAddress, allow: session.remoteAddress);
      } on Object {
        await session.stop();
        rethrow;
      }
      if (generation != _generation) await givenUp(relay);
    }
    // F04-006: what the stream's segments are (fMP4, packed audio), read from its playlists, as a
    // receiver takes Transport Stream unless told. Its first HLS candidate only: the others are
    // other servers, asked only if it fails. Not read in time, or at all: Transport Stream, as before
    HlsFormat? format;
    final hls = plan.candidates.where((c) => c.route == CastRoute.hls).firstOrNull;
    if (hls != null) {
      format = await relay!.formatOf(hls).timeout(formatWait, onTimeout: () => null).catchError((Object e) => null);
      if (generation != _generation) await givenUp(relay);
    }
    final ref = item.ref;
    final media = [
      for (final c in plan.candidates)
        CastMedia(
          url: c.route == CastRoute.direct ? c.url : relay!.serve(c),
          contentType: c.contentType,
          live: c.live,
          hls: c.route == CastRoute.hls,
          title: ref?.kind == MediaKind.episode ? ref!.title : item.title,
          subtitle: item.subtitle ?? '',
          image: ref?.image,
          kind: switch (ref?.kind) {
            MediaKind.movie => CastMediaKind.movie,
            MediaKind.episode => CastMediaKind.episode,
            MediaKind.live => CastMediaKind.live,
            _ => CastMediaKind.other,
          },
          seriesTitle: ref?.seriesTitle,
          season: ref?.season,
          episode: ref?.number,
          startAt: c.live || from == null || from <= Duration.zero ? null : from,
          hlsFormat: c == hls ? format : null,
        ),
    ];
    final cast = ChromecastCast._(device, item, session, relay, plan, words, lib);
    current.value = cast;
    BackgroundPlay.claim(
      cast,
      (action, at) => _onAction(cast, action, at),
      onRegain: () {
        cast._told = null; // its notification again, once the player that took over lets go
        _tell(cast, cast.session.status.value);
      },
    );
    session.status.addListener(cast._listener = () => _onStatus(cast));
    unawaited(session.load(media).catchError((Object e) => debugPrint('chromecast: load: $e')));
    return cast;
  }

  /// How long a cast waits to read what an HLS stream's segments are before it starts anyway.
  @visibleForTesting
  static Duration formatWait = const Duration(seconds: 5);

  /// How [item] casts, knowing what the account it is of allows: an Xtream account with no HLS is
  /// told at once, rather than the TV trying for half a minute.
  static CastPlan planFor(PlayItem item) => castPlan(
    item,
    accountFormats: accountFormatsFor(currentCatalog.value?.source, item.url),
    panelExport: panelExportHas(currentCatalog.value?.source, item.url),
  );

  /// Whether [url] is an entry of an M3U list that is a panel's export (see
  /// [M3uSource.isPanelExport]), in [source] or in the part of it that has it.
  @visibleForTesting
  static bool panelExportHas(ContentSource? source, String url) {
    final sources = switch (source) {
      final CombinedSource c => [for (final p in c.parts) p.source],
      final ContentSource s => [s],
      null => const <ContentSource>[],
    };
    return sources.any((s) => s is M3uSource && s.has(url) && s.isPanelExport);
  }

  /// The outputs the Xtream account [url] is a stream of allows, as its login said; null when not
  /// known (not Xtream, not logged in yet).
  @visibleForTesting
  static Set<String>? accountFormatsFor(ContentSource? source, String url) {
    final sources = switch (source) {
      final CombinedSource c => [for (final p in c.parts) p.source],
      final ContentSource s => [s],
      null => const <ContentSource>[],
    };
    for (final s in sources) {
      if (s is XtreamSource && s.serves(url)) return s.allowedFormats.isEmpty ? null : s.allowedFormats.toSet();
    }
    return null;
  }

  /// Notes [ref] at [position] in the library of [began]'s playlist and profile. Not always in
  /// [began], the one the cast started with: that playlist opened again since is another copy, and
  /// [began] would write its old favorites and history over what was done in it. The one open now
  /// then, when it is that playlist's and profile's; else as kept on the device now.
  static Future<void> _note(
    Library began,
    MediaRef ref,
    Duration position,
    Duration duration, {
    bool quiet = false,
  }) async {
    final open = currentLibrary.value;
    final library = open != null && open.playlistId == began.playlistId && open.profileId == began.profileId
        ? open
        : await Library.load(began.playlistId, began.profileId);
    await library.record(ref, position: position, duration: duration, quiet: quiet);
  }

  /// Progress of what plays on the TV goes to the library as if played here: every 10 seconds, and
  /// once more when it ends. A finished cast lets go of its relay.
  void _onStatus(ChromecastCast cast) {
    final st = cast.session.status.value;
    final ref = cast.item.ref;
    final library = cast._library;
    if (ref != null &&
        library != null &&
        ref.kind != MediaKind.live &&
        (st.duration ?? Duration.zero) > Duration.zero) {
      final now = DateTime.now();
      final ended = st.phase == CastPhase.ended;
      if (st.phase == CastPhase.playing &&
              (cast._saved == null || now.difference(cast._saved!) >= const Duration(seconds: 10)) ||
          ended && cast._saved != null) {
        cast._saved = now;
        unawaited(_note(library, ref, st.position, st.duration!, quiet: !ended));
      }
    }
    _tell(cast, st);
    final candidates = cast.plan.candidates;
    final relayed = st.candidate < candidates.length && candidates[st.candidate].route != CastRoute.direct;
    _keepAwake(st.phase != CastPhase.ended && relayed);
    if (st.phase == CastPhase.ended) _end(cast);
  }

  var _awake = false;

  /// While the TV takes the stream through this device (the relay), it must not sleep: a laptop or
  /// a TV box with no player of its own on would, and the TV be left with nothing. Phones and
  /// tablets have the notification's service to keep them going.
  void _keepAwake(bool on) {
    if (on == _awake || BackgroundPlay.available) return;
    _awake = on;
    unawaited(
      (on ? WakelockPlus.enable() : WakelockPlus.disable()).catchError(
        (Object e) => debugPrint('chromecast: wakelock: $e'),
      ),
    );
  }

  /// A cast that is over lets go of everything: the receiver's app, the relay, the notification.
  void _end(ChromecastCast cast) {
    if (cast._over) return;
    cast._over = true;
    if (cast._listener case final listener?) cast.session.status.removeListener(listener);
    if (current.value == cast) current.value = null;
    _quiet(cast);
    _keepAwake(false);
    // Ended as finished or "cannot play", the link is still open: the TV goes back to its screen
    unawaited(cast.session.stop().catchError((Object _) {}));
    unawaited(cast._relay?.close());
  }

  /// Keeps the notification in step with the TV.
  void _tell(ChromecastCast cast, CastStatus st) {
    final words = cast._words;
    // Only the cast on now, while it is on: a stop under way does not bring it back
    if (words == null || !BackgroundPlay.available || st.phase == CastPhase.ended || current.value != cast) return;
    final told = (phase: st.phase, duration: st.duration);
    if (told == cast._told) return;
    cast._told = told;
    unawaited(
      BackgroundPlay.show(
        cast,
        remote: true,
        title: cast.item.title,
        subtitle: words.castingTo,
        playing: st.phase == CastPhase.playing,
        position: st.position,
        duration: st.duration ?? Duration.zero,
        live: cast.item.isLive,
        rate: 1,
        labels: words.labels,
      ).then((shown) {
        if (shown || cast._told != told) return;
        // The TV took it with the app gone to the background, where Android starts no service: no
        // controls, and nothing keeping the CPU and the Wi-Fi on. Again once the app is back
        cast._told = null;
        _tellOnReturn(cast);
      }),
    );
  }

  /// Tells [cast]'s state again when the app comes back to the screen, if it is still the one on.
  void _tellOnReturn(ChromecastCast cast) {
    late final AppLifecycleListener back;
    back = AppLifecycleListener(
      onResume: () {
        back.dispose();
        if (current.value == cast) _tell(cast, cast.session.status.value);
      },
    );
  }

  /// The notification's buttons, and a headset's, go to the TV.
  void _onAction(ChromecastCast cast, String action, Duration? at) {
    if (current.value != cast) return;
    switch (action) {
      case 'play':
        unawaited(cast.session.play());
      case 'pause':
        unawaited(cast.session.pause());
      case 'seek' when at != null && !cast.item.isLive:
        unawaited(cast.session.seek(at));
      case 'stop':
        unawaited(stop());
    }
  }

  void _quiet(ChromecastCast cast) {
    if (cast._told != null) unawaited(BackgroundPlay.hide(cast));
    cast._told = null;
    BackgroundPlay.release(cast);
  }

  /// Stops what casts, on the TV too, and a cast still connecting.
  Future<void> stop() async {
    _generation++;
    _castingTo = null;
    await _stopCurrent();
  }

  Future<void> _stopCurrent() async {
    final cast = current.value;
    if (cast == null) return;
    cast._over = true;
    // Where it was, said at once: the last kept may be ten seconds behind, and waited to be synced
    final st = cast.session.status.value, ref = cast.item.ref, library = cast._library;
    if (cast._saved != null &&
        ref != null &&
        library != null &&
        ref.kind != MediaKind.live &&
        (st.duration ?? Duration.zero) > Duration.zero) {
      unawaited(_note(library, ref, st.position, st.duration!));
    }
    if (cast._listener case final listener?) cast.session.status.removeListener(listener);
    current.value = null;
    _quiet(cast);
    _keepAwake(false);
    try {
      await cast.session.stop();
    } on Object catch (e) {
      debugPrint('chromecast: stop: $e'); // the TV is gone anyway
    }
    await cast._relay?.close();
  }
}
