package com.capytv.app

import android.app.ActivityManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Rational
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private companion object {
        const val PIP_PLAY_PAUSE = "com.capytv.app.PIP_PLAY_PAUSE"

        /** The width, in dp, every TV screen of the app is laid out for: a 1080p TV at density 320. */
        private const val TV_WIDTH_DP = 960

        /** Android TV, Google TV and Fire TV report the TV UI mode; many TV boxes only lack a touchscreen. */
        fun deviceIsTv(context: Context): Boolean {
            val pm = context.packageManager
            val uiMode = (context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager).currentModeType
            return uiMode == Configuration.UI_MODE_TYPE_TELEVISION ||
                pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
                pm.hasSystemFeature("amazon.hardware.fire_tv") ||
                !pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN) ||
                // A cheap box may claim a touch screen it has not got: the screen it has says otherwise
                context.resources.configuration.touchscreen == Configuration.TOUCHSCREEN_NOTOUCH
        }

        /**
         * [base] with the density that makes its screen [TV_WIDTH_DP] wide, on a TV: the sizes of
         * the app (posters, text) are fixed dp, laid out for that. A box that says 160 (1920 dp
         * wide) drew everything at half size, at 240 three quarters. Only the density is set: the
         * text size, language and the rest stay the system's. Phones and tablets keep theirs.
         */
        fun tvScaled(base: Context): Context {
            return try {
                // What Settings says this device is (lib/device.dart's device.mode) wins, as there
                val mode = base.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    .getString("flutter.device.mode", "")
                if (mode == "touch" || mode != "tv" && !deviceIsTv(base)) return base
                val metrics = base.resources.displayMetrics
                val wide = maxOf(metrics.widthPixels, metrics.heightPixels)
                if (wide <= 0) return base
                val dpi = wide * DisplayMetrics.DENSITY_DEFAULT / TV_WIDTH_DP
                if (Math.abs(dpi - metrics.densityDpi) < 8) return base // already so, as on a Fire TV
                val only = Configuration()
                only.fontScale = 0f // left as it is (a new Configuration says 1 before Android 8)
                only.densityDpi = dpi
                base.createConfigurationContext(only)
            } catch (e: RuntimeException) {
                base // as the device says, rather than not at all
            }
        }
    }

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(tvScaled(newBase))
    }

    private var pip: MethodChannel? = null

    // What the player said last: whether leaving the app goes on in a small window (it is
    // playing), the picture's shape, and whether the window's button pauses or plays
    private var pipAuto = false
    private var pipAspect = Rational(16, 9)
    private var pipPlaying = true
    // In the app's language, for TalkBack; the last ones said stay when a call brings none
    private var pauseLabel = "Pause"
    private var playLabel = "Play"

    private fun readLabels(pause: String?, play: String?) {
        if (pause != null) pauseLabel = pause
        if (play != null) playLabel = play
    }

    private val pipButton = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            pip?.invokeMethod("playPause", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "iptv_player/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "isTv" -> result.success(deviceIsTv(this))
                "deviceName" -> result.success(deviceName())
                "lowMemory" -> result.success(lowMemory())
                "memoryMb" -> result.success(memoryInfo().totalMem / (1024 * 1024))
                "freeStorageMb" -> result.success(cacheDir.usableSpace / (1024 * 1024))
                // Where a recording goes: what the app may still write on that disk, now
                "freeBytes" -> result.success(java.io.File(call.argument<String>("path") ?: filesDir.path).usableSpace)
                "metered" -> result.success((getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager).isActiveNetworkMetered)
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "iptv_player/update").setMethodCallHandler { call, result ->
            when (call.method) {
                "version" -> result.success(version())
                "canInstall" -> result.success(canInstall())
                "allowInstall" -> result.success(allowInstall())
                "install" -> result.success(install(File(call.argument<String>("path")!!)))
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "iptv_player/media").also { media ->
            PlaybackService.listener = { action, at -> media.invokeMethod(action, at) }
            media.setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        val shown = PlaybackService.show(
                            this,
                            PlaybackService.Now(
                                title = call.argument<String>("title") ?: "",
                                subtitle = call.argument<String>("subtitle") ?: "",
                                // Decoded only when it changed: a pause or a seek sends none
                                art = if (call.argument<Boolean>("sameArt") == true) {
                                    lastArt
                                } else {
                                    call.argument<ByteArray>("art")?.let { art(it) }.also { lastArt = it }
                                },
                                playing = call.argument<Boolean>("playing") ?: false,
                                positionMs = call.argument<Number>("position")?.toLong() ?: 0,
                                durationMs = call.argument<Number>("duration")?.toLong() ?: 0,
                                live = call.argument<Boolean>("live") ?: false,
                                rate = call.argument<Number>("rate")?.toFloat() ?: 1f,
                                labels = call.argument<Map<String, String>>("labels") ?: emptyMap(),
                                remote = call.argument<Boolean>("remote") ?: false,
                            ),
                        )
                        result.success(shown)
                    }
                    "hide" -> {
                        PlaybackService.hide(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "iptv_player/audio").also { channel ->
            val guard = AudioGuard(applicationContext) { change -> channel.invokeMethod(change, null) }
            audioGuard = guard
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "hold" -> {
                        guard.hold(call.arguments as? Boolean ?: false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // Recordings (RecordingService.kt): the same channel the engine with no screen has, when the
        // app is closed; here it can also ask for leave to show notifications and to run unhindered
        RecordingService.channel(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
            ::askNotifications,
            ::askBattery,
        ).also { recording ->
            RecordingService.listener = { event -> recording.invokeMethod(event, null) }
            RecordingService.opened(applicationContext)
        }
        pip = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "iptv_player/pip").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "supported" -> result.success(pipSupported())
                    "enter" -> {
                        readLabels(call.argument("pause"), call.argument("play"))
                        readPip(call.argument("width"), call.argument("height"))
                        result.success(pipSupported() && enterPictureInPictureMode(pipParams()))
                    }
                    "update" -> {
                        pipAuto = call.argument<Boolean>("auto") ?: false
                        pipPlaying = call.argument<Boolean>("playing") ?: true
                        readLabels(call.argument("pause"), call.argument("play"))
                        readPip(call.argument("width"), call.argument("height"))
                        if (pipSupported()) setPictureInPictureParams(pipParams())
                        result.success(null)
                    }
                    "leave" -> {
                        // Back to the whole screen, as a tap on the window does
                        startActivity(Intent(this@MainActivity, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter(PIP_PLAY_PAUSE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pipButton, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(pipButton, filter)
        }
    }

    /** The player's sound, with background play off (see AudioGuard). */
    private var audioGuard: AudioGuard? = null

    override fun onDestroy() {
        unregisterReceiver(pipButton)
        audioGuard?.hold(false)
        // What records is the app's own code, which ends with it (swiped from the recent apps)
        RecordingService.listener = null
        if (RecordingService.busy) RecordingService.end(applicationContext)
        // Gone while the sound went on in the background (swiped from the recent apps): nothing
        // could control it any more, so it ends with the app
        if (PlaybackService.active) {
            PlaybackService.listener = null
            PlaybackService.hide(this)
            android.os.Process.killProcess(android.os.Process.myPid())
        }
        super.onDestroy()
    }

    /**
     * Back on the first screen. Flutter would finish the activity, and the app's engine with it; while
     * recordings are under way or still to come, or something is cast, the app goes behind instead, as
     * Home does.
     */
    override fun popSystemNavigator(): Boolean {
        // A cast too: finishing would take its notification and its relay with it
        if (!RecordingService.busy && !PlaybackService.active) return super.popSystemNavigator()
        moveTaskToBack(true)
        return true
    }

    private var notificationsAsked: MethodChannel.Result? = null

    /** Android 13 on keeps notifications off until asked: a recording's would not show. */
    private fun askNotifications(result: MethodChannel.Result) {
        val permission = "android.permission.POST_NOTIFICATIONS"
        if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            return result.success(true)
        }
        notificationsAsked?.success(false)
        notificationsAsked = result
        requestPermissions(arrayOf(permission), NOTIFICATIONS_REQUEST)
    }

    private var batteryAsked: MethodChannel.Result? = null

    /**
     * Android's own question, whether the app may run unhindered by its battery optimization: true
     * when it already may, or says yes. False where there is no such question (some makers' phones).
     */
    private fun askBattery(result: MethodChannel.Result) {
        val power = getSystemService(POWER_SERVICE) as PowerManager
        if (power.isIgnoringBatteryOptimizations(packageName)) return result.success(true)
        batteryAsked?.success(false)
        batteryAsked = result
        try {
            @Suppress("BatteryLife") // a recording scheduled for later is what the exemption is for
            val ask = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
            @Suppress("DEPRECATION") // one question, its answer read back below
            startActivityForResult(ask, BATTERY_REQUEST)
        } catch (e: ActivityNotFoundException) {
            batteryAsked = null
            result.success(false)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != BATTERY_REQUEST) return
        val power = getSystemService(POWER_SERVICE) as PowerManager
        batteryAsked?.success(power.isIgnoringBatteryOptimizations(packageName))
        batteryAsked = null
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATIONS_REQUEST) return
        notificationsAsked?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        notificationsAsked = null
    }

    /** The controls' picture as last sent, for the updates that keep it. */
    private var lastArt: Bitmap? = null

    /** A poster for the notification, small: Android keeps it with the session. */
    private fun art(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 512) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    /** The name the user gave the device in its settings, or its model. */
    private fun deviceName(): String =
        Settings.Global.getString(contentResolver, "device_name")?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER} ${Build.MODEL}"

    /** Little memory for everything: what Android itself calls low-RAM, or under 1.5 GB (a 1 GB TV stick). */
    private fun memoryInfo(): ActivityManager.MemoryInfo {
        val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        return ActivityManager.MemoryInfo().also { manager.getMemoryInfo(it) }
    }

    private fun lowMemory(): Boolean {
        val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        return manager.isLowRamDevice || memoryInfo().totalMem < 1536L * 1024 * 1024
    }


    // Updates from the account's sync server (lib/sync/app_update.dart), installed by Android's
    // own installer, which asks the user

    private fun version(): Map<String, Any> {
        val info = packageManager.getPackageInfo(packageName, 0)
        @Suppress("DEPRECATION")
        val build = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()
        return mapOf("name" to (info.versionName ?: ""), "build" to build)
    }

    /** Since Android 8 each app needs the user's leave to install others ("unknown sources"). */
    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    /** Opens that setting for this app; false where the device has no such screen (some TV boxes). */
    private fun allowInstall(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    private fun install(apk: File): Boolean {
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    // Picture in picture: the player in a small window over other apps

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /** The picture's shape, within what Android allows a small window (2.39:1 at most either way). */
    private fun readPip(width: Int?, height: Int?) {
        if (width == null || height == null || width <= 0 || height <= 0) return
        val ratio = width.toDouble() / height
        pipAspect = when {
            ratio > 2.39 -> Rational(239, 100)
            ratio < 1 / 2.39 -> Rational(100, 239)
            else -> Rational(width, height)
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun pipParams(): PictureInPictureParams {
        val label = if (pipPlaying) pauseLabel else playLabel
        val button = RemoteAction(
            Icon.createWithResource(this, if (pipPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play),
            label,
            label,
            PendingIntent.getBroadcast(this, 0, Intent(PIP_PLAY_PAUSE).setPackage(packageName), PendingIntent.FLAG_IMMUTABLE),
        )
        return PictureInPictureParams.Builder()
            .setAspectRatio(pipAspect)
            .setActions(listOf(button))
            .apply { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) setAutoEnterEnabled(pipAuto) }
            .build()
    }

    /** Before Android 12 a window does not open by itself: going home while it plays opens it here. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipAuto && pipSupported() && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            enterPictureInPictureMode(pipParams())
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pip?.invokeMethod("changed", isInPictureInPictureMode)
        // The window closed rather than opened back to the whole screen: the app is stopped by then
        if (!isInPictureInPictureMode && lifecycle.currentState == Lifecycle.State.CREATED) {
            pip?.invokeMethod("closed", null)
        }
    }
}

private const val NOTIFICATIONS_REQUEST = 7351
private const val BATTERY_REQUEST = 7352
