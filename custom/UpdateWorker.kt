package com.alexlmp.app

import android.content.Context
import android.net.Uri
import android.os.Build
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * Checks GitHub for a new AlexLMP release about once an hour, even while the
 * app is closed, and posts a notification once per new version.
 */
class UpdateWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {

    override fun doWork(): Result {
        val ctx = applicationContext
        // Same switches the app uses (Settings > Update notifications, "Skip").
        val flutter = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        if (!flutter.getBoolean("flutter.update_check", true)) return Result.success()
        val skipped = flutter.getString("flutter.update_skip", null)

        val conn = URL("https://api.github.com/repos/$REPO/releases/latest")
            .openConnection() as HttpURLConnection
        return try {
            conn.connectTimeout = 15000
            conn.readTimeout = 15000
            conn.setRequestProperty("User-Agent", "AlexLMP-update-check")
            conn.setRequestProperty("Accept", "application/vnd.github+json")
            if (conn.responseCode != 200) return Result.retry()
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val json = org.json.JSONObject(body)
            val latest = json.optString("tag_name").removePrefix("v").removePrefix("V")
            if (latest.isEmpty()) return Result.success()

            val installed = try {
                ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: ""
            } catch (_: Exception) { "" }
            if (compare(latest, installed) <= 0 || latest == skipped) return Result.success()
            if (prefs(ctx).getString(KEY_NOTIFIED, null) == latest) return Result.success()

            var url = json.optString("html_url", "https://github.com/$REPO/releases")
            val assets = json.optJSONArray("assets")
            if (assets != null) {
                for (i in 0 until assets.length()) {
                    val a = assets.getJSONObject(i)
                    if (a.optString("name").lowercase().endsWith(".apk")) {
                        url = a.optString("browser_download_url", url)
                        break
                    }
                }
            }
            notify(ctx, "AlexLMP $latest is available", "Tap to update.", url, latest)
            Result.success()
        } catch (_: Exception) {
            Result.retry()
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        private const val REPO = "cashhwocky/AlexLMP"
        private const val WORK_NAME = "alexlmp_update_check"
        private const val KEY_NOTIFIED = "notified_version"

        private fun prefs(ctx: Context) =
            ctx.getSharedPreferences("alexlmp_updates", Context.MODE_PRIVATE)

        /** Starts the hourly check (does nothing if it's already scheduled). */
        fun schedule(ctx: Context) {
            val req = PeriodicWorkRequestBuilder<UpdateWorker>(1, TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .build()
            WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(
                WORK_NAME, ExistingPeriodicWorkPolicy.UPDATE, req
            )
        }

        /** 1 if a is newer than b, -1 if older, 0 if the same. */
        fun compare(a: String, b: String): Int {
            val pa = a.split('.', '+', '-').map { it.toIntOrNull() ?: 0 }
            val pb = b.split('.', '+', '-').map { it.toIntOrNull() ?: 0 }
            for (i in 0 until maxOf(pa.size, pb.size)) {
                val x = pa.getOrElse(i) { 0 }
                val y = pb.getOrElse(i) { 0 }
                if (x != y) return x.compareTo(y)
            }
            return 0
        }

        fun notify(ctx: Context, title: String, text: String, url: String, version: String?) {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE)
                as android.app.NotificationManager
            val channelId = "alexlmp_updates"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(
                    android.app.NotificationChannel(
                        channelId, "App updates",
                        android.app.NotificationManager.IMPORTANCE_DEFAULT
                    ).apply { description = "New AlexLMP versions" }
                )
            }
            // Opens AlexLMP, which downloads and installs the update itself.
            val open = android.content.Intent(ctx, MainActivity::class.java)
                .putExtra("alexlmp_update", true)
                .putExtra("alexlmp_update_url", url)
                .addFlags(
                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                        android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
            val pi = android.app.PendingIntent.getActivity(
                ctx, 4242, open,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                    android.app.PendingIntent.FLAG_IMMUTABLE
            )
            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                android.app.Notification.Builder(ctx, channelId)
            else android.app.Notification.Builder(ctx)
            val n = builder
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(pi)
                .setAutoCancel(true)
                .build()
            nm.notify(4242, n)
            // Only one notification per version, wherever it came from.
            if (version != null) prefs(ctx).edit().putString(KEY_NOTIFIED, version).apply()
        }
    }
}

/**
 * Installs an AlexLMP update APK the app downloaded itself, through Android's
 * own package installer (no browser, no Downloads folder). Android still shows
 * its one "Update this app?" confirmation.
 */
object SelfUpdater {
    const val ACTION_RESULT = "com.alexlmp.app.UPDATE_INSTALL_RESULT"

    /** Returns "ok", "needs_permission" or throws with the reason. */
    fun install(activity: android.app.Activity, path: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            val i = android.content.Intent(
                android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + activity.packageName)
            )
            activity.startActivity(i)
            return "needs_permission"
        }
        val file = java.io.File(path)
        val installer = activity.packageManager.packageInstaller
        val params = android.content.pm.PackageInstaller.SessionParams(
            android.content.pm.PackageInstaller.SessionParams.MODE_FULL_INSTALL
        )
        params.setAppPackageName(activity.packageName)
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(
                android.content.pm.PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED
            )
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            file.inputStream().use { input ->
                session.openWrite("AlexLMP.apk", 0, file.length()).use { out ->
                    input.copyTo(out, 1 shl 16)
                    session.fsync(out)
                }
            }
            val intent = android.content.Intent(activity, UpdateInstallReceiver::class.java)
                .setAction(ACTION_RESULT)
            var flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 31) flags = flags or android.app.PendingIntent.FLAG_MUTABLE
            val pi = android.app.PendingIntent.getBroadcast(activity, 4343, intent, flags)
            session.commit(pi.intentSender)
        }
        return "ok"
    }
}

/** Shows Android's install confirmation, or the reason an install failed. */
class UpdateInstallReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: android.content.Intent) {
        val status = intent.getIntExtra(
            android.content.pm.PackageInstaller.EXTRA_STATUS,
            android.content.pm.PackageInstaller.STATUS_FAILURE
        )
        when (status) {
            android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<android.content.Intent>(
                    android.content.Intent.EXTRA_INTENT
                )
                if (confirm != null) {
                    confirm.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                    ctx.startActivity(confirm)
                }
            }
            android.content.pm.PackageInstaller.STATUS_SUCCESS -> {}
            else -> {
                val msg = intent.getStringExtra(
                    android.content.pm.PackageInstaller.EXTRA_STATUS_MESSAGE
                ) ?: "status $status"
                android.widget.Toast.makeText(
                    ctx, "AlexLMP update didn't install: $msg", android.widget.Toast.LENGTH_LONG
                ).show()
            }
        }
    }
}
