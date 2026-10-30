package com.skillcraft.app

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
 * Keeps a skill run going when SkillCraft leaves the screen.
 *
 * Off-screen apps lose the fast cores (runs measured ~3x slower) and vivo's
 * background manager kills them after a few minutes. A foreground service
 * keeps the process important, and a partial wake lock keeps the CPU awake
 * while the screen is off. Runs only for the duration of a run.
 */
class RunService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // Notification "Stop": let Dart cancel the run; it stops us after.
            onStopRequested?.invoke()
            return START_NOT_STICKY
        }
        val label = intent?.getStringExtra(EXTRA_LABEL) ?: "a skill"
        val notification = buildNotification(label)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SkillCraft:run").apply {
                setReferenceCounted(false)
                // Safety net: no run lasts this long; never hold the CPU forever.
                acquire(MAX_RUN_MS)
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun buildNotification(label: String): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Skill runs", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while a skill is running"
                },
            )
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, RunService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        return builder
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle("Running $label")
            .setContentText("SkillCraft keeps working while you use other apps.")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    companion object {
        const val ACTION_STOP = "com.skillcraft.app.STOP_RUN"
        const val EXTRA_LABEL = "label"
        private const val CHANNEL_ID = "runs"
        private const val NOTIFICATION_ID = 7
        private const val MAX_RUN_MS = 30 * 60 * 1000L

        /** Set by MainActivity; forwards the notification's Stop to Dart. */
        var onStopRequested: (() -> Unit)? = null

        fun start(context: Context, label: String) {
            val intent = Intent(context, RunService::class.java).putExtra(EXTRA_LABEL, label)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RunService::class.java))
        }
    }
}
