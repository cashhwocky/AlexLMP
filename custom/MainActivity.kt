package com.alexlmp.app

import android.content.ContentUris
import android.os.Build
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// IMPORTANT: this must extend AudioServiceActivity (not FlutterActivity),
// otherwise audio_service can't attach to the Flutter engine and playback /
// lock-screen controls silently fail.
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
                    else -> result.notImplemented()
                }
            }
    }

    private fun scanLocalAudio(): List<Map<String, Any>> {
        val songs = mutableListOf<Map<String, Any>>()
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
                    // content:// URI works on every Android version (scoped storage safe)
                    val uri = ContentUris.withAppendedId(collection, id).toString()
                    songs.add(
                        mapOf(
                            "id" to id,
                            "uri" to uri,
                            "title" to (cursor.getString(titleCol) ?: "Unknown Track"),
                            "artist" to (cursor.getString(artistCol) ?: "Unknown Artist"),
                            "album" to (cursor.getString(albumCol) ?: "Local Audio"),
                            "durationSeconds" to (durationMs / 1000).toInt(),
                            "filePath" to (cursor.getString(dataCol) ?: "")
                        )
                    )
                }
            }
        } catch (_: Exception) {
        }
        return songs
    }
}
