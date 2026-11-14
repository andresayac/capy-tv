// What the player draws over the video: the top bar (what plays, its badges, the way back), the
// controls along the bottom, the programme on now, and the panels that take the screen when it
// stopped (unavailable, asleep, sent to another device). A part of player_screen.dart: an extension
// of the screen's state, so build() lays these out as before.
part of 'player_screen.dart';

extension _PlayerOverlay on _PlayerScreenState {
  /// Shown when the stream does not start: what happened and what to do next.
  Widget _unavailable() {
    final l = context.l10n;
    return Semantics(
      liveRegion: true, // said as it comes: nothing plays, and why
      child: _unavailablePanel(l),
    );
  }

  Widget _unavailablePanel(AppLocalizations l) {
    return Panel(
      color: AppColors.scrim,
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        // A short screen with big text: Retry must still be within reach
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CapyStatus(mood: CapyMood.video, size: 68),
              const SizedBox(height: 14),
              Text(
                _item.isLive ? l.channelUnavailable : l.videoUnavailable,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                // The stream opened but its picture never moved: likely the device's hardware decoder
                _failureText(l),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  PrimaryButton(icon: Icons.refresh_rounded, label: l.retry, focusNode: _retryFocus, onPressed: _open),
                  if (_item.isLive && _hasNext)
                    SecondaryButton(icon: Icons.skip_next_rounded, label: l.nextChannel, onPressed: () => _go(1)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Over a dark screen once the sleep timer stopped the player.
  /// Over a dark screen once it was sent to [device], which plays it.
  Widget _sentPanel(String device) {
    final l = context.l10n;
    return ColoredBox(
      color: const Color(0xEB000000),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.devices_rounded, size: 44),
              const SizedBox(height: 14),
              Semantics(
                liveRegion: true,
                child: Text(
                  l.playingOnDevice(device),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(
                  l.playingOnDeviceHint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted),
                ),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  PrimaryButton(
                    icon: Icons.play_arrow_rounded,
                    label: l.keepWatchingHere,
                    focusNode: _wakeFocus,
                    onPressed: _wake,
                  ),
                  SecondaryButton(
                    icon: Icons.close_rounded,
                    label: l.exitPlayer,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sleepPanel() {
    final l = context.l10n;
    return ColoredBox(
      color: const Color(0xEB000000),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bedtime_outlined, size: 44),
              const SizedBox(height: 14),
              Text(l.sleepDone, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(l.sleepDoneHint, style: const TextStyle(color: AppColors.muted)),
              const SizedBox(height: 22),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  PrimaryButton(
                    icon: Icons.play_arrow_rounded,
                    label: l.keepWatching,
                    focusNode: _wakeFocus,
                    onPressed: _wake,
                  ),
                  SecondaryButton(
                    icon: Icons.close_rounded,
                    label: l.exitPlayer,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Back, the poster, the title and year, the episode; and on the right what the stream is.
  List<Widget> _nowAndNext() {
    final l = context.l10n;
    // The guide's, or the provider's for this channel alone (Airing), asked when the list showed it
    final on =
        currentAiring.value?.upcoming(liveChannelOf(_item.ref), currentGuide.value) ??
        currentGuide.value?.upcoming(_item.ref?.epgId, count: 2) ??
        const [];
    if (on.isEmpty) return const [];
    final now = on.first;
    final span = now.end.difference(now.start).inSeconds;
    final done = span <= 0 ? 0.0 : (DateTime.now().difference(now.start).inSeconds / span).clamp(0.0, 1.0);
    const style = TextStyle(color: Colors.white70, fontSize: 13);
    return [
      const SizedBox(height: 4),
      Text('${l.onNow} · ${now.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
          width: 160,
          child: LinearProgressIndicator(
            value: done,
            minHeight: 2,
            color: AppColors.text,
            backgroundColor: Colors.white24,
          ),
        ),
      ),
      if (on.length > 1)
        Text('${l.upNext} · ${on[1].title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
    ];
  }

  Widget _topBar(PlayerState st, bool big) {
    final l = context.l10n;
    final ref = _item.ref;
    final year = ref?.kind == MediaKind.live ? null : ref?.year;
    final left = _sleep.left;
    return Row(
      children: [
        _RoundButton(
          icon: Icons.arrow_back_rounded,
          text: big ? MaterialLocalizations.of(context).backButtonTooltip : null,
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onTap: () => Navigator.maybePop(context),
        ),
        const SizedBox(width: 12),
        if (ref?.image case final image?) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.square(
              dimension: big ? 52 : 44,
              child: NetImage(image, fit: _item.isLive ? BoxFit.contain : BoxFit.cover, icon: null),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    // The screen's name to a screen reader, as an app bar's title is
                    child: Semantics(
                      header: true,
                      namesRoute: true,
                      child: Text(
                        _item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: big ? 24 : 18, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                      ),
                    ),
                  ),
                  if (year != null) ...[
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white38),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '$year',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.muted),
                      ),
                    ),
                  ],
                ],
              ),
              if (_item.subtitle != null)
                Text(
                  _item.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70),
                ),
              // A channel: what is on, and after it, as the TV app shows; shown when the provider says
              // it for a channel the guide leaves out (Airing)
              if (_item.isLive)
                if (currentAiring.value case final onAir?)
                  ListenableBuilder(
                    listenable: onAir,
                    builder: (_, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _nowAndNext(),
                    ),
                  )
                else
                  ..._nowAndNext(),
            ],
          ),
        ),
        // On a narrow screen the title comes first
        if (MediaQuery.sizeOf(context).width >= 700)
          for (final b in _badges(st, l)) _Badge(b),
        if (_recordingSince case final since?)
          _Badge('REC ${_fmt(DateTime.now().difference(since))}', icon: Icons.fiber_manual_record_rounded),
        if (_sleep.on)
          _Badge(
            _sleep.atEnd
                ? l.sleepWhenItEnds
                : left!.inMinutes >= 1
                ? l.minutes(left.inMinutes + 1)
                : _fmt(left),
            icon: Icons.bedtime_outlined,
          ),
        if (_late) ...[
          const SizedBox(width: 6),
          _RoundButton(
            icon: Icons.skip_next_rounded,
            text: '−${_fmt(_behind)} · ${l.goLive}',
            size: 38,
            onTap: _goLive,
          ),
        ] else if (_live) ...[
          const SizedBox(width: 6),
          _LiveBadge(label: l.live),
        ],
      ],
    );
  }

  Widget _overlay(PlayerState st, bool big) {
    final l = context.l10n;
    final pos = _drag ?? st.position;
    final side = big ? 28.0 : 16.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Shade where the controls are, so they read on bright footage
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xB3000000), Colors.transparent, Colors.transparent, Color(0xD9000000)],
                stops: [0, 0.24, 0.55, 1],
              ),
            ),
          ),
        ),
        // Top: what plays and what the stream is
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(padding: EdgeInsets.fromLTRB(side, 12, side, 0), child: _topBar(st, big)),
          ),
        ),
        // Center: −10 · play/pause · +10 (the "unavailable" panel takes its place)
        if (!_failed)
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_live || _item.isLive)
                  _CircleButton(
                    icon: Icons.replay_10_rounded,
                    label: l.back10,
                    size: big ? 64 : 52,
                    onTap: () => _seekBy(-_skip),
                  ),
                SizedBox(width: big ? 48 : 28),
                _PlayButton(playing: st.playing, size: big ? 96 : 76, onTap: _togglePlay, focusNode: _playFocus),
                SizedBox(width: big ? 48 : 28),
                if (!_live || _late)
                  _CircleButton(
                    icon: Icons.forward_10_rounded,
                    label: l.forward10,
                    size: big ? 64 : 52,
                    onTap: () => _seekBy(_skip),
                  ),
              ],
            ),
          ),
        // Bottom: progress, then this title's controls on the left and the picture's and sound's on
        // the right
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            minimum: EdgeInsets.fromLTRB(side, 0, side, big ? 22 : 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_live)
                  Row(
                    children: [
                      _Time(_fmt(pos)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: _ProgressBar(
                          position: pos,
                          duration: st.duration,
                          buffered: st.position + st.buffer,
                          onDrag: (t) {
                            _update(() => _drag = t);
                            _poke();
                          },
                          onSeek: (t) {
                            _seekTo(t);
                            _update(() => _drag = null);
                            _poke();
                          },
                          onKeySkip: _seekBy,
                          touch: _touch,
                        ),
                      ),
                      const SizedBox(width: 6),
                      // The length, or what is left of it; the space around it takes a finger too
                      Semantics(
                        button: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _update(() => _showLeft = !_showLeft),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            child: _Time(_showLeft ? '−${_fmt(st.duration - pos)}' : _fmt(st.duration)),
                          ),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if ((widget.library, _item.ref) case (final library?, final ref?)
                        when ref.kind == MediaKind.movie || ref.kind == MediaKind.live)
                      _RoundButton(
                        icon: library.isFavorite(ref) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        tooltip: library.isFavorite(ref) ? l.inMyList : l.myList,
                        onTap: () async {
                          await library.toggleFavorite(ref);
                          if (mounted) _update(() {});
                        },
                      ),
                    if (widget.items.length > 1)
                      _RoundButton(
                        icon: Icons.playlist_play_rounded,
                        tooltip: _item.isLive ? l.playerChannels : l.playerEpisodes,
                        onTap: _openList,
                      ),
                    if (!_item.isLive && _hasNext)
                      _RoundButton(
                        icon: Icons.skip_next_rounded,
                        text: big ? l.nextEpisode : null,
                        tooltip: l.nextEpisode,
                        onTap: () => _go(1),
                      ),
                    _RoundButton(
                      icon: st.volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                      tooltip: l.mute,
                      onTap: _toggleMute,
                    ),
                    if (!_mobile && MediaQuery.sizeOf(context).width >= 760)
                      SizedBox(
                        width: 110,
                        child: Slider(
                          value: st.volume.clamp(0, 100),
                          max: 100,
                          onChanged: (v) => setAudioVolume(player, v),
                        ),
                      ),
                    // A narrow window: what does not fit scrolls rather than falling off the edge
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!_live) _RoundButton(text: '${_rate(st.rate)}x', tooltip: l.speed, onTap: _openSpeed),
                            _RoundButton(text: _fitLabel(l, _fit), tooltip: l.pictureFit, onTap: _nextFit),
                            _RoundButton(
                              icon: Icons.subtitles_outlined,
                              tooltip: l.audioAndSubtitles,
                              onTap: _openTracks,
                            ),
                            if (_item.isLive) ...[
                              _RoundButton(
                                icon: _recording != null
                                    ? Icons.stop_circle_outlined
                                    : Icons.fiber_manual_record_outlined,
                                tooltip: _recording != null ? l.stopRecording : l.record,
                                onTap: _toggleRecording,
                              ),
                              _RoundButton(icon: Icons.grid_view_rounded, tooltip: l.multiview, onTap: _openMultiview),
                            ],
                            if (canSend(ref: _item.ref, item: _item))
                              _RoundButton(icon: Icons.cast_rounded, tooltip: l.sendTo, onTap: _sendTo),
                            if (_pip)
                              _RoundButton(
                                icon: Icons.picture_in_picture_alt_rounded,
                                tooltip: l.pictureInPicture,
                                onTap: _enterPip,
                              ),
                            if (_mobile && !isTv) // a touch screen
                              // Not with a screen reader: its way out shows for three seconds only
                              if (!MediaQuery.accessibleNavigationOf(context))
                                _RoundButton(icon: Icons.lock_outline_rounded, tooltip: l.lockControls, onTap: _lock),
                            _RoundButton(
                              icon: Icons.settings_outlined,
                              tooltip: l.playerSettings,
                              onTap: _openSettings,
                            ),
                            if (!_mobile)
                              _RoundButton(
                                icon: _fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                                tooltip: l.fullScreen,
                                onTap: () => _setFullscreen(!_fullscreen),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 1, 1.25, 0.5: a speed as short as it goes.
  static String _rate(double r) => r == r.roundToDouble() ? '${r.round()}' : '$r';
}
