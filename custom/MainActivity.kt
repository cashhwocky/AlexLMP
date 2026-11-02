package com.alexlmp.app

import android.content.ContentUris
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import java.io.ByteArrayOutputStream
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val channelName = "com.alexlmp.app/media"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanDeviceAudio" -> {
                        Thread {
                            val songs = scanLocalAudio()
                            runOnUiThread { result.success(songs) }
                        }.start()
                    }
                    "getArt" -> {
                        val uri = call.argument("uri") as? String
                        val path = call.argument("path") as? String
                        Thread {
                            val bytes = loadArt(uri, path)
                            runOnUiThread { result.success(bytes) }
                        }.start()
                    }
                    "keepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        if (on) {
                            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "getWallpaperColor" -> {
                        // Material You accent from the wallpaper (Android 12+).
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            try {
                                result.success(getColor(android.R.color.system_accent1_200))
                            } catch (_: Exception) {
                                result.success(0)
                            }
                        } else {
                            result.success(0)
                        }
                    }
                    "openUrl" -> {
                        val url = call.argument<String>("url") ?: ""
                        try {
                            startActivity(
                                android.content.Intent(
                                    android.content.Intent.ACTION_VIEW,
                                    Uri.parse(url)
                                ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_URL", e.toString(), null)
                        }
                    }
                    "showUpdateNotification" -> {
                        try {
                            showUpdateNotification(
                                call.argument<String>("title") ?: "Update available",
                                call.argument<String>("text") ?: "",
                                call.argument<String>("url") ?: ""
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("NOTIFY", e.toString(), null)
                        }
                    }
                    "setHighRefreshRate" -> {
                        val on = call.argument<Boolean>("on") ?: true
                        try {
                            applyRefreshRate(on)
                        } catch (_: Exception) {
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        YtMusicBridge.init(applicationContext)
        YtMusicBridge.attachActivity(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, YtMusicBridge.CHANNEL)
            .setMethodCallHandler { call, result -> YtMusicBridge.handle(call, result) }
    }

    /** Posts an "update available" notification that opens [url] when tapped. */
    private fun showUpdateNotification(title: String, text: String, url: String) {
        val nm = getSystemService(android.content.Context.NOTIFICATION_SERVICE)
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
        val open = android.content.Intent(android.content.Intent.ACTION_VIEW, Uri.parse(url))
        val pi = android.app.PendingIntent.getActivity(
            this, 4242, open,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            android.app.Notification.Builder(this, channelId)
        else android.app.Notification.Builder(this)
        val n = builder
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        nm.notify(4242, n)
    }

    /** Ask for the screen's fastest refresh rate (90/120 Hz) at the current
     *  resolution, or let the system choose again when [on] is false. */
    private fun applyRefreshRate(on: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        @Suppress("DEPRECATION")
        val d = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
                 else windowManager.defaultDisplay) ?: return
        val cur = d.mode
        val modeId = if (on) {
            d.supportedModes
                .filter {
                    it.physicalWidth == cur.physicalWidth &&
                        it.physicalHeight == cur.physicalHeight
                }
                .maxByOrNull { it.refreshRate }?.modeId ?: return
        } else {
            0
        }
        val lp = window.attributes
        if (lp.preferredDisplayModeId == modeId) return
        lp.preferredDisplayModeId = modeId
        window.attributes = lp
    }

    private fun loadArt(uriStr: String?, path: String?): ByteArray? {
        if (!uriStr.isNullOrEmpty() && uriStr.startsWith("content://") &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        ) {
            try {
                val bmp = contentResolver.loadThumbnail(Uri.parse(uriStr), Size(512, 512), null)
                val out = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, 90, out)
                return out.toByteArray()
            } catch (_: Exception) {
            }
        }
        try {
            val retriever = MediaMetadataRetriever()
            if (!path.isNullOrEmpty()) {
                retriever.setDataSource(path)
            } else if (!uriStr.isNullOrEmpty()) {
                retriever.setDataSource(this, Uri.parse(uriStr))
            } else {
                retriever.release()
                return null
            }
            val pic = retriever.embeddedPicture
            retriever.release()
            return pic
        } catch (_: Exception) {
        }
        return null
    }

    private fun scanLocalAudio(): List<Any> {
        val songs = ArrayList<Any>()
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATA
        )

        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0"
        val sortOrder = "${MediaStore.Audio.Media.DATE_ADDED} DESC"

        try {
            contentResolver.query(collection, projection, selection, null, sortOrder)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val titleCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                val artistCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
                val albumCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
                val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
                val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)

                while (cursor.moveToNext()) {
                    val durationMs = cursor.getLong(durationCol)
                    if (durationMs < 3000) continue
                    val id = cursor.getLong(idCol)
                    val uri = ContentUris.withAppendedId(collection, id).toString()
                    val item = HashMap<String, Any>()
                    item["id"] = id
                    item["uri"] = uri
                    item["title"] = cursor.getString(titleCol) ?: "Unknown Track"
                    item["artist"] = cursor.getString(artistCol) ?: "Unknown Artist"
                    item["album"] = cursor.getString(albumCol) ?: "Local Audio"
                    item["durationSeconds"] = (durationMs / 1000).toInt()
                    item["filePath"] = cursor.getString(dataCol) ?: ""
                    songs.add(item)
                }
            }
        } catch (_: Exception) {
        }
        return songs
    }
}
