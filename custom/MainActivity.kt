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
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val executor = Executors.newFixedThreadPool(4)
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var visitorData: String? = null

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

    private fun postJson(urlStr: String, body: JSONObject, headers: Map<String, String>): JSONObject? {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                connectTimeout = 10000
                readTimeout = 10000
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Accept", "application/json")
                for ((k, v) in headers) setRequestProperty(k, v)
            }
            conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val stream = if (conn.responseCode in 200..299) conn.inputStream else conn.errorStream
            val text = BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).use { it.readText() }
            JSONObject(text)
        } catch (e: Exception) {
            null
        } finally {
            conn?.disconnect()
        }
    }

    private fun getJson(urlStr: String): JSONObject? {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 8000
                readTimeout = 8000
                setRequestProperty("User-Agent", "Mozilla/5.0")
            }
            if (conn.responseCode !in 200..299) return null
            val text = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { it.readText() }
            JSONObject(text)
        } catch (_: Exception) {
            null
        } finally {
            conn?.disconnect()
        }
    }

    private fun ensureVisitorData(): String? {
        if (!visitorData.isNullOrBlank()) return visitorData
        try {
            val body = JSONObject().apply {
                put("context", JSONObject().apply {
                    put("client", JSONObject().apply {
                        put("clientName", "WEB_REMIX")
                        put("clientVersion", "1.20250310.01.00")
                        put("hl", "en")
                        put("gl", "US")
                    })
                })
            }
            val res = postJson(
                "https://music.youtube.com/youtubei/v1/visitor_id?prettyPrint=false",
                body,
                mapOf("User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            )
            val vd = res?.optJSONObject("responseContext")?.optString("visitorData")
            if (!vd.isNullOrBlank()) visitorData = vd
        } catch (_: Exception) {}
        return visitorData
    }

    private fun ytSearchSongs(query: String): List<HashMap<String, Any?>> {
        val results = mutableListOf<HashMap<String, Any?>>()
        try {
            val body = JSONObject().apply {
                put("context", JSONObject().apply {
                    put("client", JSONObject().apply {
                        put("clientName", "WEB_REMIX")
                        put("clientVersion", "1.20250310.01.00")
                        put("hl", "en")
                        put("gl", "US")
                    })
                })
                put("query", query)
                put("params", "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D")
            }
            val headers = mapOf(
                "User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
                "X-YouTube-Client-Name" to "67",
                "X-YouTube-Client-Version" to "1.20250310.01.00",
                "Origin" to "https://music.youtube.com",
                "Referer" to "https://music.youtube.com/"
            )
            val json = postJson("https://music.youtube.com/youtubei/v1/search?prettyPrint=false", body, headers) ?: return results
            val items = mutableListOf<JSONObject>()
            collectMusicResponsiveItems(json, items)

            for (item in items) {
                val videoId = item.optJSONObject("playlistItemData")?.optString("videoId")
                    ?: findVideoId(item)
                    ?: continue
                if (videoId.isBlank()) continue

                val flexCols = item.optJSONArray("flexColumns") ?: continue
                var title = ""
                var artist = ""
                var album = "YouTube Music"
                var duration = ""

                if (flexCols.length() > 0) {
                    val runs0 = flexCols.optJSONObject(0)
                        ?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")
                        ?.optJSONObject("text")
                        ?.optJSONArray("runs")
                    if (runs0 != null && runs0.length() > 0) {
                        title = runs0.optJSONObject(0)?.optString("text") ?: ""
                    }
                }
                if (flexCols.length() > 1) {
                    val runs1 = flexCols.optJSONObject(1)
                        ?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")
                        ?.optJSONObject("text")
                        ?.optJSONArray("runs")
                    if (runs1 != null) {
                        val parts = mutableListOf<String>()
                        for (i in 0 until runs1.length()) {
                            val t = runs1.optJSONObject(i)?.optString("text") ?: ""
                            if (t != " • " && t != " & " && t != ", " && t.isNotBlank()) {
                                parts.add(t)
                            }
                        }
                        if (parts.isNotEmpty()) artist = parts[0]
                        if (parts.size > 1) {
                            val last = parts.last()
                            if (last.contains(":")) {
                                duration = last
                                if (parts.size > 2) album = parts[1]
                            } else {
                                album = parts[1]
                            }
                        }
                    }
                }

                var thumb = "https://i.ytimg.com/vi/$videoId/hqdefault.jpg"
                val thumbs = item.optJSONObject("thumbnail")
                    ?.optJSONObject("musicThumbnailRenderer")
                    ?.optJSONObject("thumbnail")
                    ?.optJSONArray("thumbnails")
                if (thumbs != null && thumbs.length() > 0) {
                    val lastThumb = thumbs.optJSONObject(thumbs.length() - 1)?.optString("url")
                    if (!lastThumb.isNullOrBlank()) thumb = lastThumb.replace("w120-h120", "w544-h544").replace("w60-h60", "w544-h544")
                }

                if (title.isNotBlank()) {
                    val map = HashMap<String, Any?>()
                    map["videoId"] = videoId
                    map["title"] = title
                    map["artist"] = if (artist.isBlank()) "YouTube Music" else artist
                    map["album"] = album
                    map["duration"] = duration
                    map["art"] = thumb
                    results.add(map)
                    if (results.size >= 25) break
                }
            }
        } catch (_: Exception) {}
        return results
    }

    private fun collectMusicResponsiveItems(node: Any?, out: MutableList<JSONObject>) {
        if (node is JSONObject) {
            val renderer = node.optJSONObject("musicResponsiveListItemRenderer")
            if (renderer != null) {
                out.add(renderer)
                return
            }
            val keys = node.keys()
            while (keys.hasNext()) {
                collectMusicResponsiveItems(node.opt(keys.next()), out)
            }
        } else if (node is JSONArray) {
            for (i in 0 until node.length()) {
                collectMusicResponsiveItems(node.opt(i), out)
            }
        }
    }

    private fun findVideoId(node: Any?): String? {
        if (node is JSONObject) {
            val we = node.optJSONObject("watchEndpoint")
            if (we != null && we.has("videoId")) return we.optString("videoId")
            val keys = node.keys()
            while (keys.hasNext()) {
                val found = findVideoId(node.opt(keys.next()))
                if (!found.isNullOrBlank()) return found
            }
        } else if (node is JSONArray) {
            for (i in 0 until node.length()) {
                val found = findVideoId(node.opt(i))
                if (!found.isNullOrBlank()) return found
            }
        }
        return null
    }

    // Multi-client InnerTube + Piped fallback
    private fun resolveYtStream(videoId: String): HashMap<String, Any?>? {
        val vd = ensureVisitorData()

        data class ClientSpec(
            val name: String,
            val version: String,
            val id: String,
            val ua: String,
            val extra: Map<String, Any>
        )

        val clients = listOf(
            ClientSpec(
                name = "ANDROID_VR",
                version = "1.61.48",
                id = "28",
                ua = "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                extra = mapOf(
                    "deviceMake" to "Oculus",
                    "deviceModel" to "Quest 3",
                    "androidSdkVersion" to 32,
                    "osName" to "Android",
                    "osVersion" to "12L"
                )
            ),
            ClientSpec(
                name = "IOS",
                version = "20.03.02",
                id = "5",
                ua = "com.google.ios.youtube/20.03.02 (iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X;)",
                extra = mapOf(
                    "deviceMake" to "Apple",
                    "deviceModel" to "iPhone16,2",
                    "osName" to "iPhone",
                    "osVersion" to "18.2.1.22C161"
                )
            ),
            ClientSpec(
                name = "ANDROID_TESTSUITE",
                version = "1.9",
                id = "30",
                ua = "com.google.android.youtube/1.9 (Linux; U; Android 14; en_US) gzip",
                extra = mapOf(
                    "androidSdkVersion" to 34,
                    "osName" to "Android",
                    "osVersion" to "14"
                )
            )
        )

        for (c in clients) {
            try {
                val clientObj = JSONObject().apply {
                    put("clientName", c.name)
                    put("clientVersion", c.version)
                    put("hl", "en")
                    put("gl", "US")
                    if (!vd.isNullOrBlank()) put("visitorData", vd)
                    for ((k, v) in c.extra) put(k, v)
                }
                val body = JSONObject().apply {
                    put("context", JSONObject().apply { put("client", clientObj) })
                    put("videoId", videoId)
                    put("contentCheckOk", true)
                    put("racyCheckOk", true)
                }
                val headers = mutableMapOf(
                    "User-Agent" to c.ua,
                    "X-YouTube-Client-Name" to c.id,
                    "X-YouTube-Client-Version" to c.version,
                    "Origin" to "https://www.youtube.com"
                )
                if (!vd.isNullOrBlank()) headers["X-Goog-Visitor-Id"] = vd

                val json = postJson("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", body, headers) ?: continue
                val streamingData = json.optJSONObject("streamingData") ?: continue
                val adaptive = streamingData.optJSONArray("adaptiveFormats") ?: continue

                var bestUrl: String? = null
                var bestBitrate = -1
                var bestMime = "audio/mp4"

                for (i in 0 until adaptive.length()) {
                    val fmt = adaptive.optJSONObject(i) ?: continue
                    val mime = fmt.optString("mimeType", "")
                    if (!mime.startsWith("audio/")) continue
                    val url = fmt.optString("url", "")
                    if (url.isBlank()) continue
                    val br = fmt.optInt("bitrate", 0)
                    val score = if (mime.contains("mp4")) br + 50000 else br
                    if (score > bestBitrate) {
                        bestBitrate = score
                        bestUrl = url
                        bestMime = mime
                    }
                }

                if (!bestUrl.isNullOrBlank()) {
                    val details = json.optJSONObject("videoDetails")
                    val out = HashMap<String, Any?>()
                    out["url"] = bestUrl
                    out["mime"] = bestMime
                    out["userAgent"] = c.ua
                    out["title"] = details?.optString("title")
                    out["artist"] = details?.optString("author")?.removeSuffix(" - Topic")
                    return out
                }
            } catch (_: Exception) {}
        }

        // Fallback to Piped instances if InnerTube requires JS signatureCipher
        val pipedInstances = listOf(
            "https://pipedapi.kavin.rocks",
            "https://pipedapi.tokhmi.xyz",
            "https://pipedapi.syncpundit.io"
        )
        for (host in pipedInstances) {
            try {
                val pJson = getJson("$host/streams/$videoId") ?: continue
                val streams = pJson.optJSONArray("audioStreams") ?: continue
                var bestUrl: String? = null
                var bestBr = -1
                var bestMime = "audio/mp4"
                for (i in 0 until streams.length()) {
                    val s = streams.optJSONObject(i) ?: continue
                    val u = s.optString("url", "")
                    if (u.isBlank()) continue
                    val br = s.optInt("bitrate", 0)
                    if (br > bestBr) {
                        bestBr = br
                        bestUrl = u
                        bestMime = s.optString("mimeType", "audio/mp4")
                    }
                }
                if (!bestUrl.isNullOrBlank()) {
                    val out = HashMap<String, Any?>()
                    out["url"] = bestUrl
                    out["mime"] = bestMime
                    out["userAgent"] = "Mozilla/5.0"
                    return out
                }
            } catch (_: Exception) {}
        }

        return null
    }

    private fun downloadYtTrack(videoId: String, title: String, artist: String, artUrl: String?, directUrl: String?): HashMap<String, Any?>? {
        val streamInfo = if (!directUrl.isNullOrBlank()) {
            hashMapOf<String, Any?>("url" to directUrl, "mime" to "audio/mp4", "userAgent" to "Mozilla/5.0")
        } else {
            resolveYtStream(videoId)
        } ?: return null

        val streamUrl = streamInfo["url"] as? String ?: return null
        val ua = streamInfo["userAgent"] as? String ?: "Mozilla/5.0"
        val mime = streamInfo["mime"] as? String ?: "audio/mp4"
        val ext = if (mime.contains("webm") || mime.contains("opus")) "ogg" else "m4a"

        try {
            val ytDir = File(filesDir, "yt_cache").apply { mkdirs() }
            val safeName = "${title}_${artist}".replace(Regex("[^a-zA-Z0-9._-]"), "_").take(60)
            val audioFile = File(ytDir, "${safeName}_$videoId.$ext")

            if (!audioFile.exists() || audioFile.length() < 1024) {
                val conn = (URL(streamUrl).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 15000
                    readTimeout = 30000
                    setRequestProperty("User-Agent", ua)
                    setRequestProperty("Range", "bytes=0-")
                }
                conn.inputStream.use { input ->
                    FileOutputStream(audioFile).use { output ->
                        input.copyTo(output, 64 * 1024)
                    }
                }
                conn.disconnect()
            }

            var localArtPath: String? = null
            if (!artUrl.isNullOrBlank()) {
                try {
                    val artFile = File(cacheDir, "yt_art_$videoId.jpg")
                    if (!artFile.exists()) {
                        val aConn = (URL(artUrl).openConnection() as HttpURLConnection).apply {
                            connectTimeout = 8000
                            readTimeout = 8000
                        }
                        aConn.inputStream.use { input ->
                            FileOutputStream(artFile).use { output -> input.copyTo(output) }
                        }
                        aConn.disconnect()
                    }
                    if (artFile.exists()) localArtPath = artFile.absolutePath
                } catch (_: Exception) {}
            }

            val out = HashMap<String, Any?>()
            out["path"] = audioFile.absolutePath
            out["art"] = localArtPath
            out["title"] = title
            out["artist"] = artist
            return out
        } catch (e: Exception) {
            return null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pixelaudio/meta")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cacheDir" -> result.success(cacheDir.absolutePath)
                    "filesDir" -> result.success(filesDir.absolutePath)
                    "outputDevice" -> result.success(outputInfo())
                    "ytSearch" -> {
                        val query = call.argument<String>("query") ?: ""
                        executor.execute {
                            val res = ytSearchSongs(query)
                            mainHandler.post { result.success(res) }
                        }
                    }
                    "ytStream" -> {
                        val videoId = call.argument<String>("videoId") ?: ""
                        val title = call.argument<String>("title") ?: "Track"
                        val artist = call.argument<String>("artist") ?: "Artist"
                        val artUrl = call.argument<String>("art")
                        val directUrl = call.argument<String>("directUrl")
                        executor.execute {
                            val res = downloadYtTrack(videoId, title, artist, artUrl, directUrl)
                            mainHandler.post { result.success(res) }
                        }
                    }
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
