package com.capytv.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.PowerManager

/**
 * Playback that goes on with the app in the background (lib/player/background_play.dart): a
 * foreground service, so Android keeps the app running, with a media session for the controls in
 * the notification, on the lock screen and on headsets. A call or another app's sound pauses it,
 * as do headphones coming out.
 */
class PlaybackService : Service() {
    /** What plays, as the player says it, with the words for the buttons in the app's language. */
    data class Now(
        val title: String,
        val subtitle: String,
        val art: Bitmap?,
        val playing: Boolean,
        val positionMs: Long,
        val durationMs: Long,
        val live: Boolean,
        val rate: Float,
        val labels: Map<String, String>,
        val remote: Boolean = false, // it plays elsewhere (a Chromecast): no sound here to manage
    )

    companion object {
        /** The player's side: "play", "pause", "stop", or "seek" with the position in ms. */
        var listener: ((String, Long?) -> Unit)? = null

        private var now: Now? = null
        private var running: PlaybackService? = null

        // Asked to start and not started yet: Android wants it in the foreground once all the same,
        // so a hide meanwhile waits for it (as RecordingService does)
        private var starting = false
        private var shown: Now? = null // the last shown, for that once

        val active: Boolean get() = running != null

        /**
         * Shows [it], starting the service the first time. False when Android did not let it start:
         * from 12 on, an app in the background may not start one (as RecordingService says too).
         */
        fun show(context: Context, it: Now): Boolean {
            now = it
            shown = it
            if (starting) return true // under way: it shows the latest when it starts
            running?.let { service -> service.refresh(); return true }
            val intent = Intent(context, PlaybackService::class.java)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
                starting = true
                true
            } catch (e: IllegalStateException) { // ForegroundServiceStartNotAllowedException, 31+
                false
            }
        }

        fun hide(context: Context) {
            now = null
            if (starting) return // it goes once started, as Android wants
            context.stopService(Intent(context, PlaybackService::class.java))
        }

        private const val CHANNEL = "playback"
        private const val NOTIFICATION = 1
        private const val PLAY_PAUSE = "com.capytv.app.PLAY_PAUSE"
        private const val STOP = "com.capytv.app.STOP"
    }

    private lateinit var session: MediaSession

    // A stream (heard here, or relayed to a Chromecast) keeps coming with the screen off: the CPU
    // and the Wi-Fi stay awake while it plays, not while it is paused
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private lateinit var audio: AudioManager
    private var focus: AudioFocusRequest? = null
    private var resumeOnFocus = false

    private val onFocus = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            // Another app plays for good, or for a while (a call, directions)
            AudioManager.AUDIOFOCUS_LOSS -> {
                resumeOnFocus = false
                hasFocus = false // asked for again when it plays here once more
                send("pause")
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                resumeOnFocus = now?.playing == true
                send("pause")
            }
            AudioManager.AUDIOFOCUS_GAIN -> if (resumeOnFocus) {
                resumeOnFocus = false
                send("play")
            }
        }
    }

    // Headphones out: not on through the speaker
    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (now?.playing == true) send("pause")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = this
        wake = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CapyTV:playback")
            .apply { setReferenceCounted(false) }
        // High performance, the mode that acts with the screen off: low latency acts only with it on
        // and the app in front, so it did nothing here. Android 14 and later may still treat it as low latency
        @Suppress("DEPRECATION")
        wifi = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "CapyTV:playback")
            .apply { setReferenceCounted(false) }
        session = MediaSession(this, "Capy TV").apply {
            // Android 7 hands headset and Bluetooth buttons only to sessions that say they take them
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                @Suppress("DEPRECATION")
                setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            }
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = send("play")
                override fun onPause() = send("pause")
                override fun onStop() = send("stop")
                override fun onSeekTo(pos: Long) = send("seek", pos)

                // Android 13 on shows only the session's own actions: Stop is one of them
                override fun onCustomAction(action: String, extras: Bundle?) {
                    if (action == STOP) send("stop")
                }
            })
            isActive = true
        }
        audio = getSystemService(AUDIO_SERVICE) as AudioManager
    }

    private var hearing = false // the sound is here: audio focus held, headphones watched
    private var hasFocus = false

    private fun requestFocus() {
        hasFocus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focus?.let { audio.requestAudioFocus(it) } == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(onFocus, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN) ==
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    // Takes the audio focus and watches headphones while the sound plays here; a cast lets go of
    // both (another app's sound must not pause the TV, nor should a cast stop the phone's music).
    private fun hear(here: Boolean) {
        if (here == hearing) return
        hearing = here
        if (here) {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attributes)
                    .setOnAudioFocusChangeListener(onFocus)
                    .build()
            }
            requestFocus()
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(noisy, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(noisy, filter)
            }
        } else {
            unregisterReceiver(noisy)
            hasFocus = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focus?.let { audio.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audio.abandonAudioFocus(onFocus)
            }
            resumeOnFocus = false
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val started = starting
        starting = false
        when (intent?.action) {
            PLAY_PAUSE -> send(if (now?.playing == true) "pause" else "play")
            STOP -> send("stop")
        }
        // Hidden while it started: in the foreground once, as Android wants, then gone
        val last = shown
        if (now == null && started && last != null) {
            foreground(notification(last))
            stopSelf()
            return START_NOT_STICKY
        }
        refresh()
        return START_NOT_STICKY
    }

    /** Awake while it plays; paused, the device may sleep. */
    private fun stayAwake(playing: Boolean) {
        if (playing) {
            if (wake?.isHeld == false) wake?.acquire()
            if (wifi?.isHeld == false) wifi?.acquire()
        } else {
            if (wake?.isHeld == true) wake?.release()
            if (wifi?.isHeld == true) wifi?.release()
        }
    }

    override fun onDestroy() {
        running = null
        if (wake?.isHeld == true) wake?.release()
        if (wifi?.isHeld == true) wifi?.release()
        hear(false)
        session.isActive = false
        session.release()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
        // Shown again while it was going (a cast taking the controls back from a player that
        // closed): on again, rather than its controls and its wake gone with this one
        now?.let { show(applicationContext, it) }
    }

    private fun send(action: String, at: Long? = null) {
        listener?.invoke(action, at)
    }

    /** The session and the notification, as [now] says. */
    fun refresh() {
        val n = now ?: return stopSelf()
        hear(!n.remote)
        stayAwake(n.playing)
        // Lost for good to another app, then played again: the focus is not ours until asked
        if (n.playing && !n.remote && !hasFocus) requestFocus()
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, n.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, n.subtitle)
                .apply {
                    if (!n.live && n.durationMs > 0) putLong(MediaMetadata.METADATA_KEY_DURATION, n.durationMs)
                    if (n.art != null) putBitmap(MediaMetadata.METADATA_KEY_ART, n.art)
                }
                .build(),
        )
        var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_STOP
        if (!n.live) actions = actions or PlaybackState.ACTION_SEEK_TO
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .addCustomAction(
                    PlaybackState.CustomAction.Builder(
                        STOP,
                        n.labels["stop"] ?: "Stop",
                        android.R.drawable.ic_menu_close_clear_cancel,
                    ).build(),
                )
                .setState(
                    if (n.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    if (n.live) PlaybackState.PLAYBACK_POSITION_UNKNOWN else n.positionMs,
                    if (n.playing) n.rate else 0f,
                )
                .build(),
        )
        foreground(notification(n))
    }

    private fun foreground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION, notification)
        }
    }

    private fun notification(n: Now): Notification {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, n.labels["channel"] ?: "Playback", NotificationManager.IMPORTANCE_LOW),
            )
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        fun button(icon: Int, label: String, action: String) = Notification.Action.Builder(
            android.graphics.drawable.Icon.createWithResource(this, icon),
            label,
            PendingIntent.getService(this, action.hashCode(), Intent(this, PlaybackService::class.java).setAction(action), PendingIntent.FLAG_IMMUTABLE),
        ).build()
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        return builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(n.title)
            .setContentText(n.subtitle)
            .setLargeIcon(n.art)
            .setContentIntent(open)
            .setOngoing(n.playing)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(
                if (n.playing) {
                    button(android.R.drawable.ic_media_pause, n.labels["pause"] ?: "Pause", PLAY_PAUSE)
                } else {
                    button(android.R.drawable.ic_media_play, n.labels["play"] ?: "Play", PLAY_PAUSE)
                },
            )
            .addAction(button(android.R.drawable.ic_menu_close_clear_cancel, n.labels["stop"] ?: "Stop", STOP))
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0, 1))
            .build()
    }
}
