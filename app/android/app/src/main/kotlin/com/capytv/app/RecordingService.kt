package com.capytv.app

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps the app running while recordings scheduled from the guide are under way
 * (lib/player/recording_scheduler.dart): a foreground service with a notification saying so, and
 * the processor kept awake, and the Wi-Fi while one records, so a recording goes on with the
 * screen off. The recording itself is
 * the app's own code; without this Android stops or freezes an app in the background. Its type is
 * dataSync: what it keeps going is a download, the channel into a file.
 *
 * Waiting for one, an exact alarm ([RecordingAlarm]) wakes the app at its time and starts the
 * service, which an exact alarm may do from the background. Android 15 allows dataSync six hours a
 * day, so there it does not run meanwhile; before 15 it runs then too (asleep), which also keeps
 * Android from closing the app to free memory. A wake-up that finds the app ended (Android closed
 * it, or the device started again) records all the same: this service starts a Flutter engine with
 * no screen that runs the app's scheduler ([recordWithoutApp]), until the app opens and takes over.
 */
class RecordingService : Service() {
    companion object {
        private const val TAG = "RecordingService"
        private var title = ""
        private var text = ""
        private var channelName = "Recordings"
        private var pausedTitle = ""
        private var pausedText = ""
        private var awake = true // the processor kept awake: something records, or nothing wakes the app
        private var recording = false // something records now (not only waits): the Wi-Fi kept awake too
        private var running: RecordingService? = null
        private var starting = false
        private var hideOnStart = false // hidden while it started: it goes once started, as Android wants
        private var armed = false
        private var lock: PowerManager.WakeLock? = null

        /** Told "woken" when the wake-up came and "stopped" when the service went; null once the app's engine is gone. */
        var listener: ((String) -> Unit)? = null

        // The engine that records with the app closed (see recordWithoutApp), its channel, what tells
        // it, and the app's engines waiting for it to let go (see takeOver)
        private var headless: FlutterEngine? = null
        private var headlessChannel: MethodChannel? = null
        private var headlessListener: ((String) -> Unit)? = null
        private val handovers = mutableListOf<MethodChannel.Result>()
        private val main by lazy { Handler(Looper.getMainLooper()) }

        /** Whether what is told now goes to the engine with no screen: the app's own is not there. */
        private val alone: Boolean get() = listener != null && listener === headlessListener

        /**
         * The channel lib/player/recording_scheduler.dart's RecordingKeepAlive talks through, on
         * [messenger]: the app's engine, or the one that records with the app closed, which has no
         * [askNotifications] nor [askBattery] (no screen to ask on).
         */
        fun channel(
            context: Context,
            messenger: BinaryMessenger,
            askNotifications: ((MethodChannel.Result) -> Unit)?,
            askBattery: ((MethodChannel.Result) -> Unit)? = null,
        ): MethodChannel = MethodChannel(messenger, "iptv_player/recording").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> result.success(
                        show(
                            context,
                            call.argument<String>("title") ?: "",
                            call.argument<String>("text") ?: "",
                            call.argument<String>("channel") ?: "Recordings",
                            call.argument<Boolean>("waiting") ?: false,
                            call.argument<String>("pausedTitle") ?: "",
                            call.argument<String>("pausedText") ?: "",
                        ),
                    )
                    "hide" -> {
                        hide(context)
                        result.success(null)
                    }
                    "askNotifications" -> askNotifications?.invoke(result) ?: result.success(false)
                    "askBattery" -> askBattery?.invoke(result) ?: result.success(false)
                    "wakeAt" -> result.success(
                        wakeAt(
                            context,
                            call.argument<Number>("at")?.toLong(),
                            call.argument<String>("title") ?: "",
                            call.argument<String>("text") ?: "",
                            call.argument<String>("channel") ?: "Recordings",
                            call.argument<String>("closed") ?: "",
                        ),
                    )
                    "takeOver" -> takeOver(result)
                    else -> result.notImplemented()
                }
            }
        }

        /**
         * Android ended the app and the wake-up came: a Flutter engine with no screen runs the app's
         * recording scheduler (main.dart's recordWhileClosed), which records what is due as the app
         * would, in its files. It ends once nothing is left to do here, or as the app opens and takes
         * over ([takeOver]). False when it could not start.
         */
        private fun recordWithoutApp(context: Context): Boolean {
            if (headless != null) return true
            return try {
                val app = context.applicationContext
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(app)
                loader.ensureInitializationComplete(app, null)
                val engine = FlutterEngine(app)
                val channel = channel(app, engine.dartExecutor.binaryMessenger, null)
                // Of what the app asks the device (MainActivity's), the scheduler needs the room left
                // where recordings go: one does not fill the device
                MethodChannel(engine.dartExecutor.binaryMessenger, "iptv_player/device").setMethodCallHandler { call, result ->
                    when (call.method) {
                        "freeBytes" -> result.success(java.io.File(call.argument<String>("path") ?: app.filesDir.path).usableSpace)
                        else -> result.notImplemented()
                    }
                }
                val tell: (String) -> Unit = { event -> channel.invokeMethod(event, null) }
                headless = engine
                headlessChannel = channel
                headlessListener = tell
                listener = tell
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "recordWhileClosed"),
                )
                true
            } catch (e: Exception) {
                Log.w(TAG, "could not record with the app closed", e)
                endHeadless()
                false
            }
        }

        /**
         * The app's engine is about to start its own scheduler: the one with no screen stops what it
         * records first (the app goes on in the same files) and ends. Answers whether there was one.
         */
        private fun takeOver(result: MethodChannel.Result) {
            val channel = headlessChannel ?: return result.success(false)
            handovers.add(result)
            if (handovers.size > 1) return // asked already: one answer for both
            val giveUp = Runnable { endHeadless() }
            main.postDelayed(giveUp, 15_000L) // one that does not answer is ended all the same
            channel.invokeMethod(
                "close",
                null,
                object : MethodChannel.Result {
                    override fun success(value: Any?) {
                        finish()
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        finish()
                    }

                    override fun notImplemented() {
                        finish()
                    }

                    private fun finish() {
                        main.removeCallbacks(giveUp)
                        endHeadless()
                    }
                },
            )
        }

        /** The engine with no screen goes, if there is one; those waiting for it are answered. */
        private fun endHeadless() {
            val engine = headless
            headless = null
            headlessChannel = null
            if (alone) listener = null
            headlessListener = null
            // Not while one of its calls is still being answered
            if (engine != null) main.post { engine.destroy() }
            val waiting = handovers.toList()
            handovers.clear()
            for (r in waiting) r.success(engine != null)
        }

        val active: Boolean get() = running != null || starting

        /** Something records or is still to: leaving the app is to leave it running, as Home does. */
        val busy: Boolean get() = active || armed

        /**
         * Says [title] and [text], starting the service the first time; [waiting] for one still to come,
         * which needs no service where the wake-up starts it in time and Android counts its time
         * (15+). False when Android did not let it start: an app in the background may not start one.
         */
        fun show(
            context: Context,
            title: String,
            text: String,
            channelName: String,
            waiting: Boolean,
            pausedTitle: String,
            pausedText: String,
        ): Boolean {
            this.title = title
            this.text = text
            this.channelName = channelName
            this.pausedTitle = pausedTitle
            this.pausedText = pausedText
            awake = !waiting || !armed
            recording = !waiting
            hideOnStart = false
            if (waiting && armed && Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
                if (active) hide(context)
                // With the app closed, its engine with no screen waits for nothing: the wake-up starts another
                if (alone) endHeadless()
                return true
            }
            running?.let { service -> service.refresh(); return true }
            if (starting) return true // under way: it says the latest when it starts
            val intent = Intent(context, RecordingService::class.java)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
                starting = true
                true
            } catch (e: IllegalStateException) {
                Log.w(TAG, "service not started", e)
                false
            }
        }

        fun hide(context: Context) {
            if (starting) {
                hideOnStart = true
                return
            }
            context.stopService(Intent(context, RecordingService::class.java))
            // With the app closed, nothing is left for its engine with no screen to do
            if (alone) endHeadless()
        }

        /**
         * Wakes the app at [at] (ms since 1970) to start a recording, saying [title] and [text] from
         * then; null: no wake-up. A wake-up that finds the app ended meanwhile says [closed] instead,
         * opening the app. Kept, to be set again once the device starts anew ([rearm]). False when
         * this device lets no app wake it at an exact time.
         */
        fun wakeAt(context: Context, at: Long?, title: String, text: String, channelName: String, closed: String): Boolean {
            remember(context, at, title, text, channelName, closed)
            val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val wake = PendingIntent.getBroadcast(
                context,
                0,
                Intent(context, RecordingAlarm::class.java)
                    .putExtra("title", title)
                    .putExtra("text", text)
                    .putExtra("channel", channelName)
                    .putExtra("closed", closed),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            armed = false
            alarms.cancel(wake)
            if (at == null) return true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !alarms.canScheduleExactAlarms()) return false
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, wake)
                } else {
                    alarms.setExact(AlarmManager.RTC_WAKEUP, at, wake)
                }
                armed = true
                true
            } catch (e: SecurityException) {
                Log.w(TAG, "wake-up not set", e)
                false
            }
        }

        /** The wake-up came: the service from now on, and the app told. */
        fun woken(context: Context, title: String, text: String, channelName: String, closed: String) {
            armed = false
            forget(context)
            val tell = listener
            if (tell == null) {
                // Android ended the app meanwhile (or the device started again): an engine with no
                // screen records instead, its scheduler looking as it starts. Where it cannot start,
                // a notice says to open the app, which records what is still on
                if (!recordWithoutApp(context)) {
                    tellClosed(context, title, closed, channelName)
                    return
                }
                lock(context).acquire(60_000L)
                show(context, title, text, channelName, false, pausedTitle, pausedText)
                return
            }
            // Till the service holds it: starting the recording takes the app a moment
            lock(context).acquire(60_000L)
            show(context, title, text, channelName, false, pausedTitle, pausedText)
            tell("woken")
        }

        /** The app goes: what kept it running goes. The wake-up stays, to say then to open the app. */
        fun end(context: Context) {
            if (active) hide(context)
        }

        /** The app is open: a notice that said to open it is done with. */
        fun opened(context: Context) {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(CLOSED)
        }

        /** The device started again, and Android forgot the wake-up: set again as it was kept. */
        fun rearm(context: Context) {
            val kept = context.getSharedPreferences(KEPT, Context.MODE_PRIVATE)
            val at = kept.getLong("at", 0L)
            if (at == 0L) return
            val title = kept.getString("title", "") ?: ""
            val text = kept.getString("text", "") ?: ""
            val channel = kept.getString("channel", "Recordings") ?: "Recordings"
            val closed = kept.getString("closed", "") ?: ""
            val now = System.currentTimeMillis()
            when {
                at > now -> wakeAt(context, at, title, text, channel, closed)
                // Its time came while the device was off: it may still be on
                now - at < 3 * 60 * 60 * 1000L -> woken(context, title, text, channel, closed)
                else -> forget(context)
            }
        }

        private fun remember(context: Context, at: Long?, title: String, text: String, channelName: String, closed: String) {
            if (at == null) return forget(context)
            context.getSharedPreferences(KEPT, Context.MODE_PRIVATE).edit()
                .putLong("at", at)
                .putString("title", title)
                .putString("text", text)
                .putString("channel", channelName)
                .putString("closed", closed)
                .apply()
        }

        private fun forget(context: Context) {
            context.getSharedPreferences(KEPT, Context.MODE_PRIVATE).edit().clear().apply()
        }

        private fun tellClosed(context: Context, title: String, closed: String, channelName: String) {
            if (closed.isEmpty()) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(NotificationChannel(CHANNEL, channelName, NotificationManager.IMPORTANCE_LOW))
                Notification.Builder(context, CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
                PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE)
            }
            manager.notify(
                CLOSED,
                builder
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentIntent(open)
                    .setVisibility(Notification.VISIBILITY_PUBLIC)
                    .setContentTitle(title)
                    .setContentText(closed)
                    .setStyle(Notification.BigTextStyle().bigText(closed))
                    .setAutoCancel(true)
                    .build(),
            )
        }

        private fun lock(context: Context): PowerManager.WakeLock = lock
            ?: (context.applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CapyTV:recording")
                .apply { setReferenceCounted(false) }
                .also { lock = it }

        private const val CHANNEL = "recording"
        private const val NOTIFICATION = 2
        private const val PAUSED = 3
        private const val CLOSED = 4
        private const val KEPT = "recording_wake"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * The Wi-Fi radio kept from saving power while a channel comes into a file with the screen off.
     * High performance is the mode that acts with the screen off (low latency acts only with it on
     * and the app in front); Android 14 and later may still treat it as low latency.
     */
    private var wifi: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).cancel(PAUSED)
        @Suppress("DEPRECATION")
        wifi = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "CapyTV:recording")
            .apply { setReferenceCounted(false) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        running = this
        starting = false
        refresh()
        if (hideOnStart) {
            hideOnStart = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    /** Android 15 lets dataSync run six hours a day: past that it goes, and says so. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        cutShort()
    }

    override fun onDestroy() {
        running = null
        starting = false
        hideOnStart = false
        lock?.let { if (it.isHeld) it.release() }
        wifi?.let { if (it.isHeld) it.release() }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        listener?.invoke("stopped")
        // What kept it running is gone: so is the engine that recorded with the app closed
        endHeadless()
        super.onDestroy()
    }

    fun refresh() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION, notification())
            }
        } catch (e: RuntimeException) {
            // Not allowed now (Android 15's daily time for it used up)
            Log.w(TAG, "foreground not allowed", e)
            cutShort()
            return
        }
        val cpu = lock(this)
        if (awake) cpu.acquire() else if (cpu.isHeld) cpu.release()
        // Only while one records: waiting hours for the next, the radio may save power
        wifi?.let { if (recording && !it.isHeld) it.acquire() else if (!recording && it.isHeld) it.release() }
    }

    /** The app cannot go on in the background: it says so, and goes on once opened. */
    private fun cutShort() {
        if (pausedTitle.isNotEmpty()) {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(
                PAUSED,
                builder().setContentTitle(pausedTitle).setContentText(pausedText)
                    .setStyle(Notification.BigTextStyle().bigText(pausedText))
                    .setAutoCancel(true)
                    .build(),
            )
        }
        stopSelf()
    }

    private fun notification(): Notification = builder()
        .setContentTitle(title)
        .setContentText(text)
        .setOngoing(true)
        .setShowWhen(false)
        .build()

    private fun builder(): Notification.Builder {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, channelName, NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        return builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(open)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
    }
}

/** The wake-up for a scheduled recording (see [RecordingService.wakeAt]). */
class RecordingAlarm : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        RecordingService.woken(
            context,
            intent.getStringExtra("title") ?: "",
            intent.getStringExtra("text") ?: "",
            intent.getStringExtra("channel") ?: "Recordings",
            intent.getStringExtra("closed") ?: "",
        )
    }
}

/** The device started again: Android forgot the wake-up for the next recording, set again here. */
class RecordingBoot : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) RecordingService.rearm(context)
    }
}
