// What the player tells the system, and what it hears from it: Android's media controls (in the
// notification, on the lock screen, a headset's buttons), the small picture-in-picture window, and
// the sound's focus (a call, another app, headphones out). A part of player_screen.dart: the screen
// mixes it in, and gives it what it names below.
part of 'player_screen.dart';

mixin _PlayerSystem on State<PlayerScreen> {
  // What it needs of the player screen
  Player get player;
  PlayItem get _item;
  bool get _live;
  bool get _stopped;
  bool get _pip; // the small window can be opened here
  bool get _background; // sound on in the background: Android's controls for it
  Future<void> _togglePlay({bool user});
  void _seekTo(Duration t);
  Future<void> _saveProgress();

  ({bool auto, bool playing, int? w, int? h})? _pipSaid; // what the window was last told
  ({String title, bool playing, Duration duration, double rate})? _mediaSaid; // what the controls were last told
  (String, Uint8List?)? _art; // the poster's address and picture, for the controls
  Object? _artSent = _noArtSent; // the picture the controls have, to send it only when it changes
  static const _noArtSent = Object();

  /// Paused by a call or another app's sound for a while: plays on when it is over.
  var _pausedForSound = false;

  /// Android's sound, with background play off (AudioGuard): a call or another app for a while
  /// pauses the player, which plays on after; another app for good, or headphones out, only pause.
  void _onSound(String change) {
    if (!mounted || _stopped) return;
    final playing = player.state.playing;
    switch (change) {
      case 'pause' when playing:
        _pausedForSound = true;
        _togglePlay(user: false);
      case 'lost':
        _pausedForSound = false;
        if (playing) _togglePlay(user: false);
      case 'play' when _pausedForSound:
        _pausedForSound = false;
        if (!playing) _togglePlay(user: false);
    }
  }

  /// Keeps the small window in step: it opens on leaving the app only while something plays.
  void _tellPip() {
    if (!_pip || !mounted) return;
    final st = player.state;
    final said = (
      // With sound on in the background, leaving the app keeps it as sound, not as a window
      auto: st.playing && !_stopped && !_background,
      playing: st.playing,
      w: st.videoParams.dw ?? st.width,
      h: st.videoParams.dh ?? st.height,
    );
    if (said == _pipSaid) return;
    _pipSaid = said;
    Pip.update(
      auto: said.auto,
      playing: said.playing,
      width: said.w,
      height: said.h,
      pause: context.l10n.pause,
      play: context.l10n.play,
    );
  }

  /// Keeps Android's controls in step with the player (see [BackgroundPlay]); [moved] after a seek,
  /// which they do not follow by themselves.
  void _tellMedia({bool moved = false}) {
    if (!_background || !mounted || _stopped) return;
    final st = player.state;
    final said = (title: _item.title, playing: st.playing, duration: st.duration, rate: st.rate);
    if (said == _mediaSaid && !moved) return;
    _mediaSaid = said;
    final l = context.l10n;
    // The controls are this player's while it shows them (a cast's come back when it closes)
    if (!BackgroundPlay.owns(this)) {
      BackgroundPlay.claim(
        this,
        _onMediaAction,
        onRegain: () {
          _mediaSaid = null;
          _artSent = _noArtSent; // another's picture was there meanwhile
          _tellMedia();
        },
      );
      _artSent = _noArtSent;
    }
    final art = _art?.$2, sameArt = identical(art, _artSent);
    _artSent = art;
    BackgroundPlay.show(
      this,
      title: _item.title,
      subtitle: _item.subtitle ?? (_live ? l.live : ''),
      art: sameArt ? null : art,
      sameArt: sameArt,
      playing: st.playing,
      position: st.position,
      duration: st.duration,
      live: _live,
      rate: st.rate,
      labels: {'channel': l.playback, 'play': l.play, 'pause': l.pause, 'stop': l.stopPlaying},
    ).then((shown) {
      // Not let to show them (the app was in the background): tried again on coming back
      if (!shown && mounted) {
        _mediaSaid = null;
        _artSent = _noArtSent;
      }
    });
    _loadArt();
  }

  /// The poster for the controls, fetched once per title.
  Future<void> _loadArt() async {
    final url = _item.ref?.image;
    if (url == null) {
      // A channel with no logo: not the previous one's
      if (_art != null) {
        _art = null;
        _tellMedia(moved: true);
      }
      return;
    }
    if (_art?.$1 == url) return;
    _art = (url, null);
    try {
      // As the app's other images: the provider's headers, the disk's copy, few at a time
      final bytes = await ImageStore.instance.bytes(url).timeout(const Duration(seconds: 8));
      if (!mounted || _art?.$1 != url) return;
      _art = (url, bytes);
      _tellMedia(moved: true);
    } on Object {
      // The controls go without it
    }
  }

  /// What Android's controls ask: the notification's buttons, a headset's, a call coming in.
  void _onMediaAction(String action, Duration? at) {
    if (!mounted) return;
    final playing = player.state.playing;
    switch (action) {
      case 'play' when !playing:
      case 'pause' when playing:
        _togglePlay();
      case 'seek' when at != null && !_live:
        _seekTo(at);
      case 'stop':
        _closeFromOutside();
    }
  }

  /// Closed from Android's controls, likely with the app in the background: as Back, whatever is
  /// open over the player.
  Future<void> _closeFromOutside() async {
    final route = ModalRoute.of(context), navigator = Navigator.of(context);
    await _saveProgress();
    if (!mounted || route == null) return;
    navigator.popUntil((r) => r == route);
    navigator.pop();
  }
}
