// FILE: custom/MainActivity.kt
package com.alexdesrosier.audio_player

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun outputInfo(): HashMap<String, Any?> {
        val map = HashMap<String, Any?>()
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val priority = intArrayOf(
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                26,
                27,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_USB_DEVICE,
                AudioDeviceInfo.TYPE_HDMI
            )
            var best: AudioDeviceInfo? = null
            var bestRank = Int.MAX_VALUE
            for (d in devices) {
                var rank = -1
                for (i in priority.indices) {
                    if (priority[i] == d.type) {
                        rank = i
                        break
                    }
                }
                if (rank >= 0 && rank < bestRank) {
                    best = d
                    bestRank = rank
                }
            }
            val b = best
            if (b != null) {
                val kind = when (b.type) {
                    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, 26, 27, AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth"
                    AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired"
                    AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE -> "usb"
                    AudioDeviceInfo.TYPE_HDMI -> "hdmi"
                    else -> "other"
                }
                var name = b.productName?.toString() ?: ""
                if (name.isBlank()) {
                    name = when (kind) {
                        "bluetooth" -> "Bluetooth device"
                        "wired" -> "Wired headphones"
                        "usb" -> "USB audio"
                        "hdmi" -> "HDMI"
                        else -> "External device"
                    }
                }
                map["name"] = name
                map["kind"] = kind
            } else {
                map["name"] = Build.MODEL
                map["kind"] = "phone"
            }
        } catch (e: Exception) {
            map["name"] = Build.MODEL
            map["kind"] = "phone"
        }
        return map
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pixelaudio/meta")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cacheDir" -> result.success(cacheDir.absolutePath)
                    "filesDir" -> result.success(filesDir.absolutePath)
                    "outputDevice" -> result.success(outputInfo())
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
