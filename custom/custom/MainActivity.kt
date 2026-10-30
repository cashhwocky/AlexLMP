package com.alexlmp.app

import android.content.ContentUris
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.File
import com.ryanheise.audioservice.AudioServiceActivity
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import com.yausername.ffmpeg.FFmpeg
import com.yausername.aria2c.Aria2c
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val channelName = "com.alexlmp.app/media"
    @Volatile private var ytdlReady = false

    private fun ensureYtDlInitialized() {
        if (ytdlReady) return
        synchronized(this) {
            if (ytdlReady) return
            try {
                YoutubeDL.getInstance().init(applicationContext)
                try {
                    FFmpeg.getInstance().init(applicationContext)
                } catch (_: Throwable) {
                }
                try {
                    Aria2c.getInstance().init(applicationContext)
                } catch (_: Throwable) {
                }
                ytdlReady = true
            } catch (_: Throwable) {
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Pre-warm native yt-dlp + background binary self-update
        Thread {
            ensureYtDlInitialized()
            try {
                YoutubeDL.getInstance().updateYoutubeDL(
                    applicationContext,
                    YoutubeDL.UpdateChannel._NIGHTLY
                )
            } catch (_: Throwable) {
            }
        }.start()

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
                    "nativeYtDlpDownload" -> {
                        val target = (call.argument("target") as? String) ?: ""
                        val outputDir = (call.argument("dir") as? String) ?: ""
                        Thread {
                            val outMap = runNativeYtDlp(target, outputDir)
                            runOnUiThread { result.success(outMap) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun runNativeYtDlp(target: String, outputDirPath: String): Any? {
        if (target.isEmpty() || outputDirPath.isEmpty()) return null
        ensureYtDlInitialized()
        if (!ytdlReady) return null

        val dir = File(outputDirPath)
        if (!dir.exists()) dir.mkdirs()

        val stamp = System.currentTimeMillis()
        val beforeNames = HashSet<String>()
        dir.listFiles()?.forEach { f -> beforeNames.add(f.name) }

        val queryOrUrl = if (target.startsWith("http://") ||
            target.startsWith("https://") ||
            target.startsWith("ytsearch")
        ) {
            target
        } else {
            "ytsearch1:$target official audio"
        }

        try {
            val request = YoutubeDLRequest(queryOrUrl)
            request.addOption("--no-playlist")
            request.addOption("--no-mtime")
            request.addOption("--geo-bypass")
            request.addOption("--no-check-certificates")
            request.addOption("-f", "bestaudio[ext=m4a]/bestaudio/best")
            request.addOption("-x")
            request.addOption("--audio-format", "m4a")
            request.addOption("--audio-quality", "0")
            request.addOption(
                "-o",
                File(dir, "%(artist,uploader,channel)s - %(title)s_$stamp.%(ext)s").absolutePath
            )

            YoutubeDL.getInstance().execute(request, null, null)

            var downloadedFile: File? = null
            dir.listFiles()?.forEach { f ->
                if (f.isFile && f.length() > 1024) {
                    if (!beforeNames.contains(f.name) || f.name.contains("_$stamp")) {
                        downloadedFile = f
                    }
                }
            }

            if (downloadedFile != null) {
                val cleanName = downloadedFile!!.nameWithoutExtension
                    .replace("_$stamp", "")
                    .replace("NA - ", "")
                    .trim()
                val res = HashMap<String, Any>()
                res["path"] = downloadedFile!!.absolutePath
                res["name"] = cleanName
                return res
            }
        } catch (_: Throwable) {
        }
        return null
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
