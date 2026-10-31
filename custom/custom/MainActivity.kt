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
                    else -> result.notImplemented()
                }
            }
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
