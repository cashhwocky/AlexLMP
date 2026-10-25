// FILE: custom/MainActivity.kt
package com.alexdesrosier.audio_player

import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pixelaudio/meta")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cacheDir" -> result.success(cacheDir.absolutePath)
                    "filesDir" -> result.success(filesDir.absolutePath)
                    "read" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.success(null)
                        } else {
                            executor.execute {
                                var out: HashMap<String, Any?>? = null
                                val r = MediaMetadataRetriever()
                                try {
                                    r.setDataSource(path)
                                    val m = HashMap<String, Any?>()
                                    m["title"] = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
                                    m["artist"] = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                                    m["album"] = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
                                    m["art"] = r.embeddedPicture
                                    out = m
                                } catch (e: Exception) {
                                    out = null
                                } finally {
                                    try {
                                        r.release()
                                    } catch (e: Exception) {
                                    }
                                }
                                val finalOut = out
                                mainHandler.post { result.success(finalOut) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
