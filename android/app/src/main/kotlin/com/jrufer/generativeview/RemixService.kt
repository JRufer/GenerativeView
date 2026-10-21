package com.jrufer.generativeview

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the app waiting for remixes with the screen locked.
 *
 * While any remix is out, this runs as a foreground service with a quiet
 * notification ("Waiting for 2 remixes"), which keeps the process and its
 * network access alive, and holds a partial wake lock so the app's checks on
 * the server keep running. The app stops it as soon as nothing is out.
 */
class RemixService : Service() {
    companion object {
        const val CHANNEL_WAITING = "remix_waiting"
        const val CHANNEL_DONE = "remix_done"
        const val EXTRA_COUNT = "count"
        const val ID_WAITING = 4101
        const val ACTION_OPEN_REMIXES = "com.jrufer.generativeview.OPEN_REMIXES"

        /** How long the wake lock may be held at most: as long as a remix is waited for. */
        private const val MOST_MS = 3L * 60 * 60 * 1000

        @Volatile
        var running = false
            private set

        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_WAITING, "Remixes waiting", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while remixes are being made on your server, so the app keeps waiting with the screen locked."
                    setShowBadge(false)
                },
            )
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_DONE, "Remixes done", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "When a remix comes back and is saved."
                },
            )
        }

        /** Opens the app; with [remixes], at the Remixes collection. */
        fun openApp(context: Context, remixes: Boolean): PendingIntent {
            val intent = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            if (remixes) intent.action = ACTION_OPEN_REMIXES
            return PendingIntent.getActivity(
                context,
                if (remixes) 1 else 0,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        fun builder(context: Context, channel: String): Notification.Builder =
            if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(context, channel)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

        /** The "waiting" notification for [count] remixes. */
        fun waiting(context: Context, count: Int): Notification =
            builder(context, CHANNEL_WAITING)
                .setSmallIcon(R.drawable.ic_stat_remix)
                .setContentTitle(if (count == 1) "Waiting for a remix" else "Waiting for $count remixes")
                .setContentText("They are saved beside their originals when they come back.")
                .setContentIntent(openApp(context, false))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val count = intent?.getIntExtra(EXTRA_COUNT, 0) ?: 0
        if (count <= 0) {
            stopSelf()
            return START_NOT_STICKY
        }
        ensureChannels(this)
        val notification = waiting(this, count)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ID_WAITING, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID_WAITING, notification)
        }
        running = true
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GenerativeView:remix").apply {
                setReferenceCounted(false)
                acquire(MOST_MS)
            }
        }
        // Not brought back by the system on its own: the app picks up
        // whatever is still out when it next starts.
        return START_NOT_STICKY
    }

    // Android 15 limits how long a data-sync service runs; past that, stop.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}
