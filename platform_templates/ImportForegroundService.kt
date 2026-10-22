package com.amindada021.userinfo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the Flutter CSV import process prioritized while the phone is locked.
 * The Flutter import and SQLite transaction continue in the app process.
 * This is NOT a reliable restart/resume mechanism if Android kills the process,
 * the user force-stops the app, or the OS data-sync service quota is exceeded.
 */
class ImportForegroundService : Service() {
    companion object {
        const val ACTION_PROGRESS = "com.amindada021.userinfo.IMPORT_PROGRESS"
        private const val CHANNEL_ID = "userinfo_csv_import"
        private const val NOTIFICATION_ID = 2104
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var currentText = "در حال ورود اطلاعات CSV"

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "ایمپورت اطلاعات UserInfo",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        // Android requires startForeground shortly after service startup.
        startForeground(NOTIFICATION_ID, notification(currentText))
        val power = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "UserInfo:CsvImport").apply {
            setReferenceCounted(false)
            acquire(6L * 60L * 60L * 1000L)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PROGRESS) {
            val number = intent.getIntExtra("fileIndex", 0)
            val count = intent.getIntExtra("fileCount", 0)
            val percent = intent.getIntExtra("percent", -1)
            currentText = "فایل $number از $count" +
                if (percent >= 0) " — $percent٪" else " — در حال خواندن"
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, notification(currentText))
        }
        return START_NOT_STICKY
    }

    private fun notification(description: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("ایمپورت UserInfo")
            .setContentText(description)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(pending)
            .build()
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
