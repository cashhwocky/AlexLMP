package com.alexlmp.app

import android.content.ContentUris
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import java.net.URLEncoder
import java.net.URL
import java.net.HttpURLConnection
import java.io.FileOutputStream
import java.io.File
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
import android.provider.MediaStore
import android.util.Size
import java.io.ByteArrayOutputStream
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val channelName = "com.alexlmp.app/media"

    // Launcher icons (activity-aliases in AndroidManifest.xml).
    private val appIcons = listOf(
        "classic", "midnight", "sunset", "aurora", "neon",
        "mint", "ember", "gold", "ocean", "white", "bloom",
        "prism", "halo", "frost", "rose", "matrix",
        "orb", "note", "vinyl", "borealis", "bitlmp", "pixel",
    )

    private fun iconAlias(key: String) = android.content.ComponentName(
        packageName,
        "com.alexlmp.app.Icon" + key.replaceFirstChar { it.uppercase() },
    )

    private fun currentAppIcon(): String {
        val pm = packageManager
        for (k in appIcons) {
            if (k == "bloom") continue
            val st = pm.getComponentEnabledSetting(iconAlias(k))
            if (st == android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED) return k
        }
        return "bloom"
    }

    /**
     * Bloom (Material You lilac) is the default icon now. Anyone who picked
     * an icon before keeps it: turn the default Bloom entry off so they
     * don't get two icons.
     */
    private fun keepChosenIcon() {
        try {
            val pm = packageManager
            val enabled = android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            val chosen = appIcons.any {
                it != "bloom" && pm.getComponentEnabledSetting(iconAlias(it)) == enabled
            }
            val bloom = iconAlias("bloom")
            if (chosen && pm.getComponentEnabledSetting(bloom) ==
                android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
            ) {
                pm.setComponentEnabledSetting(
                    bloom,
                    android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    android.content.pm.PackageManager.DONT_KILL_APP,
                )
            }
        } catch (_: Exception) {}
    }

    private fun switchAppIcon(key: String) {
        val pm = packageManager
        val on = android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        val off = android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        val keep = android.content.pm.PackageManager.DONT_KILL_APP
        val target = iconAlias(key)
        pm.setComponentEnabledSetting(target, on, keep)
        val relaunch = android.content.Intent(android.content.Intent.ACTION_MAIN)
            .addCategory(android.content.Intent.CATEGORY_LAUNCHER)
            .setComponent(target)
            .addFlags(
                android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                    android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK
            )
        startActivity(relaunch)
        val app = applicationContext
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            for (k in appIcons) {
                if (k != key) {
                    try {
                        app.packageManager.setComponentEnabledSetting(iconAlias(k), off, keep)
                    } catch (_: Exception) {}
                }
            }
        }, 900)
    }

    private var mediaChannel: MethodChannel? = null
    private var updateTapped = false
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var djPlayer: MediaPlayer? = null
    private var djVoiceStyle: String = "nova"

    private fun initTts() {
        if (tts != null) return
        tts = TextToSpeech(applicationContext) { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts?.language = Locale.US
                ttsReady = true
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {
                        runOnUiThread { mediaChannel?.invokeMethod("djSpeaking", true) }
                    }
                    override fun onDone(utteranceId: String?) {
                        runOnUiThread { mediaChannel?.invokeMethod("djSpeaking", false) }
                    }
                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        runOnUiThread { mediaChannel?.invokeMethod("djSpeaking", false) }
                    }
                })
            }
        }
    }

    private fun stopDjAudio() {
        try { djPlayer?.stop() } catch (_: Exception) {}
        try { djPlayer?.release() } catch (_: Exception) {}
        djPlayer = null
        try { tts?.stop() } catch (_: Exception) {}
    }

    private fun downloadVoiceBytes(urlStr: String): ByteArray? {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                connectTimeout = 4500
                readTimeout = 5500
                instanceFollowRedirects = true
                requestMethod = "GET"
                setRequestProperty(
                    "User-Agent",
                    "Mozilla/5.0 (Linux; Android 14; Pixel) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
                )
            }
            if (conn.responseCode in 200..299) {
                val bytes = conn.inputStream.use { it.readBytes() }
                if (bytes.size > 800) bytes else null
            } else null
        } catch (_: Exception) {
            null
        } finally {
            try { conn?.disconnect() } catch (_: Exception) {}
        }
    }

    private fun speakDjNow(text: String, voiceArg: String? = null) {
        if (!voiceArg.isNullOrBlank()) djVoiceStyle = voiceArg
        stopDjAudio()
        runOnUiThread { mediaChannel?.invokeMethod("djSpeaking", true) }

        Thread {
            val clean = text.trim()
            val enc = URLEncoder.encode(clean, "UTF-8")

            val pollyVoice = when (djVoiceStyle) {
                "kira" -> "Salli"      // Smooth, warm American female voice
                "aria" -> "Kimberly"   // Bright, energetic American female voice
                "xavier" -> "Matthew"  // Deep, natural American male radio voice
                else -> "Joanna"       // Studio natural American female voice ("nova")
            }

            val urls = ArrayList<String>()
            urls.add("https://api.streamelements.com/kappa/v2/speech?voice=$pollyVoice&text=$enc")
            if (djVoiceStyle != "xavier") {
                urls.add("https://translate.google.com/translate_tts?ie=UTF-8&client=tw-ob&tl=en-US&q=$enc")
            } else {
                urls.add("https://translate.google.com/translate_tts?ie=UTF-8&client=tw-ob&tl=en-GB&q=$enc")
            }

            var audioBytes: ByteArray? = null
            for (u in urls) {
                audioBytes = downloadVoiceBytes(u)
                if (audioBytes != null) break
            }

            if (audioBytes != null) {
                try {
                    val outFile = File(cacheDir, "alexlmp_dj_speech.mp3")
                    FileOutputStream(outFile).use { it.write(audioBytes) }
                    runOnUiThread {
                        try {
                            val mp = MediaPlayer()
                            mp.setAudioAttributes(
                                AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_MEDIA)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                    .build()
                            )
                            mp.setDataSource(outFile.absolutePath)
                            mp.setOnCompletionListener { player ->
                                try { player.release() } catch (_: Exception) {}
                                if (djPlayer === player) djPlayer = null
                                mediaChannel?.invokeMethod("djSpeaking", false)
                            }
                            mp.setOnErrorListener { player, _, _ ->
                                try { player.release() } catch (_: Exception) {}
                                if (djPlayer === player) djPlayer = null
                                speakOfflineFallback(clean)
                                true
                            }
                            djPlayer = mp
                            mp.prepare()
                            mp.start()
                        } catch (_: Exception) {
                            speakOfflineFallback(clean)
                        }
                    }
                    return@Thread
                } catch (_: Exception) {}
            }

            runOnUiThread { speakOfflineFallback(clean) }
        }.start()
    }

    private fun speakOfflineFallback(text: String) {
        initTts()
        if (!ttsReady) {
            mediaChannel?.invokeMethod("djSpeaking", false)
            return
        }
        tts?.setPitch(if (djVoiceStyle == "xavier") 0.96f else 1.12f)
        tts?.setSpeechRate(1.06f)
        val params = android.os.Bundle()
        params.putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f)
        val res = tts?.speak(text, TextToSpeech.QUEUE_FLUSH, params, "alexlmp_dj_${System.currentTimeMillis()}")
        if (res == TextToSpeech.ERROR) {
            mediaChannel?.invokeMethod("djSpeaking", false)
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        keepChosenIcon()
        initTts()
        if (intent?.getBooleanExtra("alexlmp_update", false) == true) updateTapped = true
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra("alexlmp_update", false)) {
            updateTapped = false
            mediaChannel?.invokeMethod("updateTapped", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        mediaChannel!!
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "speakDj" -> {
                        val text = (call.argument<String>("text") ?: "").trim()
                        if (text.isEmpty()) {
                            result.success(false)
                        } else {
                            speakDjNow(text, call.argument<String>("voice"))
                            result.success(true)
                        }
                    }
                    "stopDj" -> {
                        stopDjAudio()
                        mediaChannel?.invokeMethod("djSpeaking", false)
                        result.success(null)
                    }
                    "takeUpdateTap" -> {
                        result.success(updateTapped)
                        updateTapped = false
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: ""
                        try {
                            result.success(SelfUpdater.install(this, path))
                        } catch (e: Exception) {
                            result.error("INSTALL", e.toString(), null)
                        }
                    }
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
                    "getAppIcon" -> result.success(currentAppIcon())
                    "setAppIcon" -> {
                        val key = call.argument<String>("key") ?: "bloom"
                        if (key !in appIcons) {
                            result.error("ICON", "Unknown icon: $key", null)
                        } else {
                            result.success(null)
                            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                try {
                                    switchAppIcon(key)
                                } catch (e: Exception) {
                                    android.util.Log.e("bitLMP", "setAppIcon failed", e)
                                }
                            }, 150)
                        }
                    }
                    "updateWidget" -> {
                        try {
                            AlexWidget.update(
                                applicationContext,
                                call.argument<String>("title") ?: "Nothing playing",
                                call.argument<String>("artist") ?: "",
                                call.argument<Boolean>("playing") ?: false,
                                call.argument<String>("art"),
                                call.argument<Boolean>("artChanged") ?: false,
                            )
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("WIDGET", e.toString(), null)
                        }
                    }
                    "setReverb" -> {
                        val session = call.argument<Int>("session") ?: 0
                        val level = (call.argument<Double>("level") ?: 0.0).coerceIn(0.0, 1.0)
                        try {
                            applyReverb(session, level)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("REVERB", e.toString(), null)
                        }
                    }
                    "deviceInfo" -> {
                        result.success(
                            mapOf(
                                "manufacturer" to android.os.Build.MANUFACTURER,
                                "model" to android.os.Build.MODEL,
                                "android" to android.os.Build.VERSION.RELEASE,
                                "sdk" to android.os.Build.VERSION.SDK_INT,
                                "build" to android.os.Build.DISPLAY
                            )
                        )
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
                            UpdateWorker.notify(
                                applicationContext,
                                call.argument<String>("title") ?: "Update available",
                                call.argument<String>("text") ?: "",
                                call.argument<String>("url") ?: "",
                                call.argument<String>("version")
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
        // Hourly background check for new releases.
        try { UpdateWorker.schedule(applicationContext) } catch (_: Exception) {}
        YtMusicBridge.init(applicationContext)
        YtMusicBridge.attachActivity(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, YtMusicBridge.CHANNEL)
            .setMethodCallHandler { call, result -> YtMusicBridge.handle(call, result) }
    }

    // ── Reverb on the player's audio session ───────────────────────────
    private var envReverb: android.media.audiofx.EnvironmentalReverb? = null
    private var presetReverb: android.media.audiofx.PresetReverb? = null
    private var reverbSession = -1

    private fun releaseReverb() {
        try { envReverb?.release() } catch (_: Exception) {}
        try { presetReverb?.release() } catch (_: Exception) {}
        envReverb = null
        presetReverb = null
        reverbSession = -1
    }

    /** level 0 = off, 1 = huge hall. */
    private fun applyReverb(session: Int, level: Double) {
        if (level <= 0.001 || session <= 0) {
            releaseReverb()
            return
        }
        if (reverbSession != session) {
            releaseReverb()
            try {
                envReverb = android.media.audiofx.EnvironmentalReverb(0, session)
            } catch (_: Exception) {
                // Some phones only offer the simpler preset reverb.
                presetReverb = android.media.audiofx.PresetReverb(0, session)
            }
            reverbSession = session
        }
        fun lerp(a: Int, b: Int): Int = (a + (b - a) * level).toInt()
        envReverb?.let { r ->
            runCatching { r.roomLevel = lerp(-4500, -200).toShort() }
            runCatching { r.roomHFLevel = lerp(-2000, -600).toShort() }
            runCatching { r.decayTime = lerp(700, 6000) }
            runCatching { r.decayHFRatio = lerp(600, 1100).toShort() }
            runCatching { r.reflectionsLevel = lerp(-4000, -600).toShort() }
            runCatching { r.reflectionsDelay = lerp(5, 40) }
            runCatching { r.reverbLevel = lerp(-4000, 800).toShort() }
            runCatching { r.reverbDelay = lerp(10, 60) }
            runCatching { r.diffusion = 1000.toShort() }
            runCatching { r.density = 1000.toShort() }
            r.enabled = true
        }
        presetReverb?.let { r ->
            r.preset = when {
                level < 0.25 -> android.media.audiofx.PresetReverb.PRESET_SMALLROOM
                level < 0.5 -> android.media.audiofx.PresetReverb.PRESET_MEDIUMHALL
                level < 0.75 -> android.media.audiofx.PresetReverb.PRESET_LARGEROOM
                else -> android.media.audiofx.PresetReverb.PRESET_LARGEHALL
            }
            r.enabled = true
        }
    }

    /** Posts an "update available" notification that opens [url] when tapped. */
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
