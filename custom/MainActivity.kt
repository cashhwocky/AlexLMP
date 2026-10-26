package com.alexdesrosier.audio_player

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pixelaudio/meta")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scan" -> executor.execute {
    val list = ArrayList<HashMap<String, Any?>>()
    try {
        val proj = arrayOf(
            MediaStore.Audio.Media._ID, MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST, MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION, MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.ALBUM_ID, MediaStore.Audio.Media.DATE_ADDED
        )
        contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, proj,
            MediaStore.Audio.Media.IS_MUSIC + " != 0", null, null
        )?.use { c ->
            while (c.moveToNext()) {
                val m = HashMap<String, Any?>()
                m["id"] = c.getLong(0)
                m["title"] = c.getString(1) ?: "Unknown"
                m["artist"] = c.getString(2) ?: "Unknown artist"
                m["album"] = c.getString(3) ?: "Unknown album"
                m["dur"] = c.getLong(4)
                m["path"] = c.getString(5) ?: ""
                m["albumId"] = c.getLong(6)
                m["added"] = c.getLong(7)
                list.add(m)
            }
        }
    } catch (e: Exception) {
    }
    mainHandler.post { result.success(list) }
}
                                }
                            }
                        } catch (e: Exception) {
                        }
                        mainHandler.post { result.success(list) }
                    }
                    "art" -> {
                        val path = call.argument<String>("path")
                        executor.execute {
                            var out: ByteArray? = null
                            val r = MediaMetadataRetriever()
                            try {
                                r.setDataSource(path)
                                val b = r.embeddedPicture
                                if (b != null) {
                                    val o = BitmapFactory.Options()
                                    o.inJustDecodeBounds = true
                                    BitmapFactory.decodeByteArray(b, 0, b.size, o)
                                    var s = 1
                                    while (o.outWidth / (s * 2) >= 600) s *= 2
                                    val o2 = BitmapFactory.Options()
                                    o2.inSampleSize = s
                                    val bmp = BitmapFactory.decodeByteArray(b, 0, b.size, o2)
                                    if (bmp != null) {
                                        val bo = ByteArrayOutputStream()
                                        bmp.compress(Bitmap.CompressFormat.JPEG, 88, bo)
                                        out = bo.toByteArray()
                                    }
                                }
                            } catch (e: Exception) {
                            } finally {
                                try { r.release() } catch (e: Exception) { }
                            }
                            mainHandler.post { result.success(out) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
