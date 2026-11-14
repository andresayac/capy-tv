package com.capytv.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build

/**
 * The player's sound while the app is on screen and background play is off (with it on,
 * PlaybackService does this): the audio focus, so a call or another app's sound pauses the player
 * and it is not heard over them, and headphones coming out pause it rather than going on through
 * the speaker. Tells the player (lib/player/audio_guard.dart) "pause" for a while (it plays on
 * when the focus comes back: "play"), or "lost" for good.
 */
class AudioGuard(private val context: Context, private val send: (String) -> Unit) {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var request: AudioFocusRequest? = null
    private var held = false

    private val onChange = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> send("lost") // another app plays for good
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> send("pause") // a call, directions
            AudioManager.AUDIOFOCUS_GAIN -> send("play")
        }
    }

    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = send("lost")
    }

    /** Takes the focus (again, after it was lost: the player plays once more) or lets it go. */
    fun hold(on: Boolean) {
        if (on) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val r = request ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build(),
                    )
                    .setOnAudioFocusChangeListener(onChange)
                    .build()
                request = r
                audio.requestAudioFocus(r)
            } else {
                @Suppress("DEPRECATION")
                audio.requestAudioFocus(onChange, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
            }
            if (!held) {
                val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    context.registerReceiver(noisy, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    @Suppress("UnspecifiedRegisterReceiverFlag")
                    context.registerReceiver(noisy, filter)
                }
            }
            held = true
        } else if (held) {
            held = false
            context.unregisterReceiver(noisy)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                request?.let { audio.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audio.abandonAudioFocus(onChange)
            }
        }
    }
}
