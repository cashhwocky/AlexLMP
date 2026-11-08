package com.alexlmp.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.security.MessageDigest
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.channel.ChannelInfo
import org.schabi.newpipe.extractor.channel.ChannelInfoItem
import org.schabi.newpipe.extractor.playlist.PlaylistInfo
import org.schabi.newpipe.extractor.playlist.PlaylistInfoItem
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException
import org.schabi.newpipe.extractor.localization.ContentCountry
import org.schabi.newpipe.extractor.localization.Localization
import org.schabi.newpipe.extractor.services.youtube.YoutubeJavaScriptPlayerManager
import org.schabi.newpipe.extractor.services.youtube.linkHandler.YoutubeSearchQueryHandlerFactory
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.DeliveryMethod
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import java.io.BufferedInputStream
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.atomic.AtomicInteger
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.zip.GZIPInputStream

/**
 * YouTube Music support for AlexLMP.
 *
 * - ytSearch:  searches YouTube Music songs (NewPipeExtractor, "music_songs" filter).
 * - ytPrepare: resolves a videoId to an audio stream and returns a local URL
 *              (http://127.0.0.1:<port>/yt/<videoId>) that just_audio plays.
 *
 * The local proxy is what makes full-length playback reliable:
 *   * it sends the User-Agent that matches the YouTube client the stream URL was issued for
 *     (a mismatch is a common cause of HTTP 403),
 *   * it downloads the song in small range chunks instead of one long request
 *     (long single requests get throttled or cut off by YouTube),
 *   * if YouTube rejects a chunk (403/410, e.g. the URL expired) it resolves a fresh URL
 *     and continues from the same byte, so playback doesn't stop mid-song.
 */
object YtMusicBridge {
    const val CHANNEL = "com.alexlmp.app/ytmusic"

    private const val DEFAULT_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0"
    private const val CHUNK_SIZE = 1L shl 20 // 1 MiB per upstream request
    private const val MAX_CHUNK_RETRIES = 6

    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newCachedThreadPool()

    @Volatile private var initialized = false
    private val downloader = HttpDownloader()

    // ── Resolved stream cache ───────────────────────────────────────────────

    private class Resolved(
        val url: String,
        val userAgent: String,
        val mimeType: String,
        val contentLength: Long, // -1 if unknown
        val expiresAtMs: Long,
    )

    private val cache = ConcurrentHashMap<String, Resolved>()

    /** Data saver: pick the lowest-bitrate audio instead of the best. */
    @Volatile private var dataSaver = false
    private val resolveLocks = ConcurrentHashMap<String, Any>()

    // ── Keep CPU + Wi-Fi awake while music plays ────────────────────────────
    //
    // Without these, Android can put the CPU to sleep / throttle Wi-Fi once the app is
    // in the background, so streaming stalls (especially between songs, when the next
    // track has to be fetched) until the app is opened again.

    @Volatile private var appContext: Context? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    fun init(context: Context) {
        appContext = context.applicationContext
        Account.bind(context)
    }

    private var activityRef: WeakReference<Activity>? = null
    fun attachActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    @Synchronized
    @Suppress("DEPRECATION")
    private fun setKeepAwake(on: Boolean) {
        val ctx = appContext ?: return
        try {
            if (on) {
                val wl = wakeLock ?: (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AlexLMP:playback")
                    .apply { setReferenceCounted(false) }
                    .also { wakeLock = it }
                // Timeout is a safety net; it's renewed every time playback (re)starts.
                wl.acquire(4 * 60 * 60 * 1000L)
                val wifi = wifiLock ?: (ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                    .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "AlexLMP:stream")
                    .apply { setReferenceCounted(false) }
                    .also { wifiLock = it }
                if (!wifi.isHeld) wifi.acquire()
            } else {
                wakeLock?.let { if (it.isHeld) it.release() }
                wifiLock?.let { if (it.isHeld) it.release() }
            }
        } catch (_: Throwable) {
        }
    }

    // ── MethodChannel entry point ───────────────────────────────────────────

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ytAccount" -> runAsync(result, "YT_ACCOUNT") { Account.status() }
            "ytSignIn" -> {
                val act = activityRef?.get()
                if (act == null) {
                    result.error("YT_SIGNIN", "App window not available", null)
                } else {
                    Account.pendingSignIn?.let { main.post { it.success(false) } }
                    Account.pendingSignIn = result
                    act.startActivity(Intent(act, YtLoginActivity::class.java))
                }
            }
            "ytSignOut" -> {
                Account.signOut()
                result.success(null)
            }
            "ytLibraryPlaylists" -> runAsync(result, "YT_LIBRARY") { Account.libraryPlaylists() }
            "ytPlaylistTracks" -> {
                val id = call.argument<String>("playlistId") ?: ""
                val auth = call.argument<Boolean>("auth") ?: true
                runAsync(result, "YT_PLAYLIST") { Account.playlistTracks(id, auth) }
            }
            "ytHomeFeed" -> runAsync(result, "YT_HOME") { Account.homeFeed() }
            "ytLibraryAlbums" -> runAsync(result, "YT_LIBRARY") { Account.libraryAlbums() }
            "ytLibraryArtists" -> runAsync(result, "YT_LIBRARY") { Account.libraryArtists() }
            "ytArtistPage" -> {
                val url = call.argument<String>("url") ?: ""
                runAsync(result, "YT_ARTIST") { Account.artistPage(url) }
            }
            "ytAlbumPage" -> {
                val ref = call.argument<String>("ref") ?: ""
                runAsync(result, "YT_ALBUM") { Account.albumPage(ref) }
            }
            "ytRate" -> {
                val id = call.argument<String>("videoId") ?: ""
                val like = call.argument<Boolean>("like") ?: true
                runAsync(result, "YT_RATE") {
                    require(VIDEO_ID.matches(id)) { "Bad videoId" }
                    Account.rate(id, like)
                    true
                }
            }
            "ytLyrics" -> {
                val id = call.argument<String>("videoId") ?: ""
                runAsync(result, "YT_LYRICS") {
                    require(VIDEO_ID.matches(id)) { "Bad videoId" }
                    Account.lyrics(id)
                }
            }
            "ytTrackLinks" -> {
                val id = call.argument<String>("videoId") ?: ""
                runAsync(result, "YT_LINKS") { Account.trackLinks(id) }
            }
            "setYtDataSaver" -> {
                val on = call.argument<Boolean>("on") ?: false
                if (on != dataSaver) {
                    dataSaver = on
                    cache.clear() // pick a new quality next time a song loads
                }
                result.success(null)
            }
            "ytSaveOffline" -> {
                val id = call.argument<String>("videoId") ?: ""
                runAsync(result, "YT_OFFLINE") {
                    require(VIDEO_ID.matches(id)) { "Bad videoId" }
                    Proxy.saveOffline(id)
                }
            }
            "ytOfflineProgress" -> {
                result.success(Proxy.offlineProgress(call.argument<String>("videoId") ?: ""))
            }
            "ytDeleteOffline" -> {
                val id = call.argument<String>("videoId") ?: ""
                if (VIDEO_ID.matches(id)) Proxy.deleteOffline(id)
                result.success(null)
            }
            "ytDeleteAllOffline" -> {
                Proxy.deleteAllOffline()
                result.success(null)
            }
            "ytClearCache" -> {
                cache.clear()
                Proxy.clearCache()
                result.success(null)
            }
            "setKeepAwake" -> {
                setKeepAwake(call.argument<Boolean>("on") ?: false)
                result.success(null)
            }
            "ytSearch" -> {
                val query = (call.argument<String>("query") ?: "").trim()
                workers.execute {
                    try {
                        val items = if (query.isEmpty()) emptyList() else search(query)
                        main.post { result.success(items) }
                    } catch (e: Throwable) {
                        main.post { result.error("YT_SEARCH", describe(e), null) }
                    }
                }
            }
            "ytPrepare" -> {
                val videoId = call.argument<String>("videoId") ?: ""
                val refresh = call.argument<Boolean>("refresh") ?: false
                // The user tapped "Continue" on a content warning: from now on
                // this song is fetched with their signed-in account.
                val signedIn = call.argument<Boolean>("signedIn") ?: false
                workers.execute {
                    try {
                        require(VIDEO_ID.matches(videoId)) { "Bad videoId" }
                        if (signedIn) needsAccount.add(videoId)
                        resolve(videoId, force = refresh || signedIn)
                        val port = Proxy.ensureStarted()
                        // Download the whole song in the background so playback never
                        // depends on fetching the last part at the last moment.
                        Proxy.prefetch(videoId, restartIfFailed = refresh)
                        main.post { result.success("http://127.0.0.1:$port/yt/$videoId") }
                    } catch (e: Throwable) {
                        main.post { result.error("YT_PREPARE", describe(e), null) }
                    }
                }
            }
            "ytSearchVideos" -> {
                val query = (call.argument<String>("query") ?: "").trim()
                runAsync(result, "YT_SEARCH") {
                    if (query.isEmpty()) emptyList<Any>() else searchVideos(query)
                }
            }
            "ytSearchArtists", "ytSearchAlbums" -> {
                val query = (call.argument<String>("query") ?: "").trim()
                val artists = call.method == "ytSearchArtists"
                runAsync(result, "YT_SEARCH") {
                    if (query.isEmpty()) emptyList<Any>()
                    else if (artists) searchArtists(query) else searchAlbums(query)
                }
            }
            "ytArtistAll" -> {
                val name = (call.argument<String>("name") ?: "").trim()
                val albums = call.argument<String>("kind") == "albums"
                runAsync(result, "YT_ARTIST") {
                    if (name.isEmpty()) emptyList<Any>() else artistAll(name, albums)
                }
            }
            "ytSearchPlaylists" -> {
                val query = (call.argument<String>("query") ?: "").trim()
                runAsync(result, "YT_SEARCH") {
                    if (query.isEmpty()) emptyList<Any>() else searchPlaylists(query)
                }
            }
            "ytAlbum" -> {
                val url = call.argument<String>("url") ?: ""
                runAsync(result, "YT_ALBUM") { album(url) }
            }
            "ytArtist" -> {
                val url = call.argument<String>("url") ?: ""
                val name = call.argument<String>("name") ?: ""
                runAsync(result, "YT_ARTIST") { artist(url, name) }
            }
            else -> result.notImplemented()
        }
    }

    private fun runAsync(result: MethodChannel.Result, code: String, block: () -> Any?) {
        workers.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error(code, describe(e), null) }
            }
        }
    }

    private fun describe(e: Throwable): String {
        val parts = ArrayList<String>()
        var cur: Throwable? = e
        var depth = 0
        while (depth < 4) {
            val c = cur ?: break
            parts.add("${c.javaClass.simpleName}: ${c.message ?: ""}")
            val next = c.cause
            cur = if (next === c) null else next
            depth++
        }
        return parts.joinToString(" <- ").take(600)
    }

    // ── NewPipeExtractor ────────────────────────────────────────────────────

    private fun ensureInit() {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            val locale = Locale.getDefault()
            val country = locale.country.takeIf { it.length == 2 } ?: "US"
            val language = locale.language.takeIf { it.isNotEmpty() } ?: "en"
            NewPipe.init(downloader, Localization(language, country), ContentCountry(country))
            initialized = true
        }
    }

    private val VIDEO_ID = Regex("^[A-Za-z0-9_-]{11}$")
    private val VIDEO_ID_IN_URL = Regex("[?&]v=([A-Za-z0-9_-]{11})")

    /**
     * Tries YouTube Music's song search first. If that endpoint fails, falls back to
     * regular YouTube video search so the user still gets results. If both fail,
     * the error contains both causes so we can see what went wrong.
     */
    private fun search(query: String): List<Map<String, Any?>> {
        ensureInit()
        val musicError = try {
            return searchWith(query, YoutubeSearchQueryHandlerFactory.MUSIC_SONGS)
        } catch (e: Throwable) {
            e
        }
        try {
            return searchWith(query, YoutubeSearchQueryHandlerFactory.VIDEOS)
        } catch (e: Throwable) {
            throw IOException(
                "music: ${describe(musicError)} | videos: ${describe(e)}",
                e,
            )
        }
    }

    private fun searchWith(query: String, filter: String): List<Map<String, Any?>> {
        val extractor = ServiceList.YouTube.getSearchExtractor(
            query,
            listOf(filter),
            "",
        )
        extractor.fetchPage()
        val out = ArrayList<Map<String, Any?>>()
        for (item in extractor.initialPage.items) {
            if (item !is StreamInfoItem) continue
            val id = VIDEO_ID_IN_URL.find(item.url)?.groupValues?.get(1) ?: continue
            val thumb = item.thumbnails.maxByOrNull { it.height }?.url
            out.add(
                mapOf(
                    "videoId" to id,
                    "title" to (item.name ?: ""),
                    "artist" to (item.uploaderName ?: ""),
                    "durationSeconds" to item.duration.coerceAtLeast(0).toInt(),
                    "thumbnail" to upscaleThumb(thumb),
                )
            )
            if (out.size >= 25) break
        }
        return out
    }

    /**
     * Regular YouTube video search (music videos, live performances, covers,
     * remixes...). Live streams are skipped since they can't be played as songs.
     */
    private fun searchVideos(query: String): List<Map<String, Any?>> {
        ensureInit()
        val extractor = ServiceList.YouTube.getSearchExtractor(
            query,
            listOf(YoutubeSearchQueryHandlerFactory.VIDEOS),
            "",
        )
        extractor.fetchPage()
        val out = ArrayList<Map<String, Any?>>()
        for (item in extractor.initialPage.items) {
            if (item !is StreamInfoItem) continue
            if (item.duration <= 0) continue // live or unknown length
            val id = VIDEO_ID_IN_URL.find(item.url)?.groupValues?.get(1) ?: continue
            out.add(
                mapOf(
                    "videoId" to id,
                    "title" to (item.name ?: ""),
                    "artist" to cleanArtist(item.uploaderName),
                    "durationSeconds" to item.duration.toInt(),
                    // Video thumbnails are 16:9 (not square like song art).
                    "thumbnail" to "https://i.ytimg.com/vi/$id/hqdefault.jpg",
                    "views" to item.viewCount,
                    "uploaded" to item.textualUploadDate,
                )
            )
            if (out.size >= 30) break
        }
        return out
    }

    /** YT Music song thumbnails are tiny (60–120px); ask Google's image server for 544px. */
    private fun upscaleThumb(url: String?): String? {
        if (url == null) return null
        return url.replace(Regex("=w\\d+-h\\d+[^&?/]*$"), "=w544-h544-l90-rj")
    }

    // ── Artists & albums ────────────────────────────────────────────────────

    private fun cleanArtist(name: String?): String =
        (name ?: "").removeSuffix(" - Topic").trim()

    private fun songMap(item: StreamInfoItem, fallbackArtist: String? = null, fallbackThumb: String? = null): Map<String, Any?>? {
        val id = VIDEO_ID_IN_URL.find(item.url)?.groupValues?.get(1) ?: return null
        val artist = cleanArtist(item.uploaderName).ifEmpty { fallbackArtist ?: "" }
        return mapOf(
            "videoId" to id,
            "title" to (item.name ?: ""),
            "artist" to artist,
            "durationSeconds" to item.duration.coerceAtLeast(0).toInt(),
            "thumbnail" to (fallbackThumb ?: upscaleThumb(item.thumbnails.maxByOrNull { it.height }?.url)),
        )
    }

    private fun searchArtists(query: String): List<Map<String, Any?>> {
        ensureInit()
        val ex = ServiceList.YouTube.getSearchExtractor(
            query, listOf(YoutubeSearchQueryHandlerFactory.MUSIC_ARTISTS), "",
        )
        ex.fetchPage()
        return ex.initialPage.items.filterIsInstance<ChannelInfoItem>().take(12).map {
            mapOf(
                "url" to it.url,
                "name" to (it.name ?: ""),
                "thumbnail" to upscaleThumb(it.thumbnails.maxByOrNull { t -> t.height }?.url),
                "subscribers" to it.subscriberCount,
            )
        }
    }

    private fun albumItemMap(it: PlaylistInfoItem): Map<String, Any?> = mapOf(
        "url" to it.url,
        "title" to (it.name ?: ""),
        "artist" to cleanArtist(it.uploaderName),
        "thumbnail" to upscaleThumb(it.thumbnails.maxByOrNull { t -> t.height }?.url),
        "trackCount" to it.streamCount,
    )

    private fun searchAlbums(query: String): List<Map<String, Any?>> {
        ensureInit()
        val ex = ServiceList.YouTube.getSearchExtractor(
            query, listOf(YoutubeSearchQueryHandlerFactory.MUSIC_ALBUMS), "",
        )
        ex.fetchPage()
        return ex.initialPage.items.filterIsInstance<PlaylistInfoItem>().take(15).map { albumItemMap(it) }
    }

    /**
     * Every song (or album) by an artist for "See all": pages through
     * YouTube Music search and keeps the ones credited to that artist.
     */
    private fun artistAll(artistName: String, albums: Boolean): List<Map<String, Any?>> {
        ensureInit()
        val ex = ServiceList.YouTube.getSearchExtractor(
            artistName,
            listOf(
                if (albums) YoutubeSearchQueryHandlerFactory.MUSIC_ALBUMS
                else YoutubeSearchQueryHandlerFactory.MUSIC_SONGS
            ),
            "",
        )
        ex.fetchPage()
        val items = ArrayList<org.schabi.newpipe.extractor.InfoItem>()
        var page = ex.initialPage
        items.addAll(page.items)
        var pages = 1
        while (pages < 10 && items.size < 200 && org.schabi.newpipe.extractor.Page.isValid(page.nextPage)) {
            page = runCatching { ex.getPage(page.nextPage) }.getOrNull() ?: break
            if (page.items.isEmpty()) break
            items.addAll(page.items)
            pages++
        }
        val seen = HashSet<String>()
        return if (albums) {
            val all = items.filterIsInstance<PlaylistInfoItem>().filter { seen.add(it.url ?: "") }
            val mine = all.filter { cleanArtist(it.uploaderName).contains(artistName, ignoreCase = true) }
            (if (mine.isNotEmpty()) mine else all).map { albumItemMap(it) }
        } else {
            val all = items.filterIsInstance<StreamInfoItem>().filter { seen.add(it.url ?: "") }
            val mine = all.filter { cleanArtist(it.uploaderName).contains(artistName, ignoreCase = true) }
            (if (mine.size >= 3) mine else all).mapNotNull { songMap(it) }
        }
    }

    /** Playlists on YouTube Music (YouTube's own and community ones), e.g. "90s rock". */
    private fun searchPlaylists(query: String): List<Map<String, Any?>> {
        ensureInit()
        val ex = ServiceList.YouTube.getSearchExtractor(
            query, listOf(YoutubeSearchQueryHandlerFactory.MUSIC_PLAYLISTS), "",
        )
        ex.fetchPage()
        return ex.initialPage.items.filterIsInstance<PlaylistInfoItem>().mapNotNull {
            val id = Regex("[?&]list=([A-Za-z0-9_-]+)").find(it.url ?: "")?.groupValues?.get(1)
                ?: return@mapNotNull null
            mapOf(
                "playlistId" to id,
                "title" to (it.name ?: ""),
                "owner" to cleanArtist(it.uploaderName),
                "trackCount" to it.streamCount,
                "thumbnail" to upscaleThumb(it.thumbnails.maxByOrNull { t -> t.height }?.url),
            )
        }.take(20)
    }

    /** YT Music album links are playlists; the regular YouTube playlist page parses most reliably. */
    private fun normalizePlaylistUrl(url: String): String {
        val list = Regex("[?&]list=([A-Za-z0-9_-]+)").find(url)?.groupValues?.get(1)
        return if (list != null) "https://www.youtube.com/playlist?list=$list" else url
    }

    private fun album(url: String): Map<String, Any?> {
        ensureInit()
        val info = PlaylistInfo.getInfo(ServiceList.YouTube, normalizePlaylistUrl(url))
        val cover = upscaleThumb(info.thumbnails.maxByOrNull { it.height }?.url)
        val artist = cleanArtist(info.uploaderName)
        val tracks = info.relatedItems.mapNotNull { songMap(it, artist, cover) }
        return mapOf(
            "title" to (info.name ?: "").removePrefix("Album - ").trim(),
            "artist" to artist,
            "thumbnail" to cover,
            "tracks" to tracks,
        )
    }

    private fun artist(url: String, name: String): Map<String, Any?> {
        ensureInit()
        var artistName = name
        var avatar: String? = null
        var banner: String? = null
        var subscribers = -1L
        try {
            val info = ChannelInfo.getInfo(ServiceList.YouTube, url)
            artistName = cleanArtist(info.name).ifEmpty { name }
            avatar = upscaleThumb(info.avatars.maxByOrNull { it.height }?.url)
            banner = info.banners.maxByOrNull { it.width }?.url
            subscribers = info.subscriberCount
        } catch (_: Throwable) {
            // Header info is a nice-to-have; songs and albums below still work without it.
        }

        val songsF = java.util.concurrent.CompletableFuture.supplyAsync({
            runCatching {
                val ex = ServiceList.YouTube.getSearchExtractor(
                    artistName, listOf(YoutubeSearchQueryHandlerFactory.MUSIC_SONGS), "",
                )
                ex.fetchPage()
                val all = ex.initialPage.items.filterIsInstance<StreamInfoItem>()
                val mine = all.filter { cleanArtist(it.uploaderName).contains(artistName, ignoreCase = true) }
                (if (mine.size >= 3) mine else all).take(20).mapNotNull { songMap(it) }
            }.getOrDefault(emptyList())
        }, workers)
        val albumsF = java.util.concurrent.CompletableFuture.supplyAsync({
            runCatching {
                val ex = ServiceList.YouTube.getSearchExtractor(
                    artistName, listOf(YoutubeSearchQueryHandlerFactory.MUSIC_ALBUMS), "",
                )
                ex.fetchPage()
                val all = ex.initialPage.items.filterIsInstance<PlaylistInfoItem>()
                val mine = all.filter { cleanArtist(it.uploaderName).contains(artistName, ignoreCase = true) }
                (if (mine.isNotEmpty()) mine else all).take(20).map { albumItemMap(it) }
            }.getOrDefault(emptyList())
        }, workers)

        return mapOf(
            "name" to artistName,
            "thumbnail" to avatar,
            "banner" to banner,
            "subscribers" to subscribers,
            "songs" to songsF.get(),
            "albums" to albumsF.get(),
        )
    }

    /** Songs the user chose to play with their account (content warnings). */
    private val needsAccount = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    private fun resolve(videoId: String, force: Boolean): Resolved {
        if (!force) cache[videoId]?.let { if (System.currentTimeMillis() < it.expiresAtMs) return it }
        val lock = resolveLocks.computeIfAbsent(videoId) { Any() }
        synchronized(lock) {
            if (!force) cache[videoId]?.let { if (System.currentTimeMillis() < it.expiresAtMs) return it }
            ensureInit()
            if (needsAccount.contains(videoId)) {
                val r = resolveWithAccount(videoId)
                cache[videoId] = r
                return r
            }

            downloader.startRecordingPlayerAgents()
            val info: StreamInfo
            val agents: List<String>
            try {
                info = StreamInfo.getInfo(
                    ServiceList.YouTube,
                    "https://music.youtube.com/watch?v=$videoId",
                )
            } finally {
                agents = downloader.stopRecordingPlayerAgents()
            }

            val playable = info.audioStreams
                .filter { it.deliveryMethod == DeliveryMethod.PROGRESSIVE_HTTP && it.isUrl && it.content.isNotBlank() }
            val best = (if (dataSaver) {
                playable.sortedBy { maxOf(it.averageBitrate, it.bitrate).let { b -> if (b <= 0) Int.MAX_VALUE else b } }
            } else {
                playable.sortedWith(
                    compareByDescending<AudioStream> { maxOf(it.averageBitrate, it.bitrate) }
                        .thenByDescending { it.format == MediaFormat.M4A }
                )
            }).firstOrNull()
                ?: throw IOException("No playable audio stream for $videoId")

            val url = best.content
            val uri = Uri.parse(url)
            val expireSec = uri.getQueryParameter("expire")?.toLongOrNull()
            val expiresAt = if (expireSec != null) {
                expireSec * 1000 - 5 * 60 * 1000 // refresh 5 minutes early
            } else {
                System.currentTimeMillis() + 60 * 60 * 1000
            }
            val mime = when (best.format) {
                MediaFormat.M4A -> "audio/mp4"
                MediaFormat.WEBMA, MediaFormat.WEBMA_OPUS -> "audio/webm"
                else -> uri.getQueryParameter("mime") ?: "audio/mp4"
            }
            val resolved = Resolved(
                url = url,
                userAgent = pickUserAgent(uri.getQueryParameter("c"), agents),
                mimeType = mime,
                contentLength = uri.getQueryParameter("clen")?.toLongOrNull() ?: -1L,
                expiresAtMs = expiresAt,
            )
            cache[videoId] = resolved
            return resolved
        }
    }

    /**
     * Asks YouTube for the song as the signed-in account, confirming the
     * content warning (the same thing YouTube's own "Continue" button sends).
     * YouTube decides whether this account may play it.
     */
    private fun resolveWithAccount(videoId: String): Resolved {
        val sts = try {
            YoutubeJavaScriptPlayerManager.getSignatureTimestamp(videoId)
        } catch (_: Throwable) {
            null
        }
        data class Client(val name: String, val version: String, val no: String, val host: String, val ua: String)
        val clients = listOf(
            Client("TVHTML5", "7.20250312.16.00", "7", "https://www.youtube.com",
                "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"),
            Client("WEB_REMIX", "1.20251020.01.00", "67", "https://music.youtube.com",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"),
        )
        val problems = ArrayList<String>()
        for (c in clients) {
            try {
                val body = JSONObject()
                    .put("videoId", videoId)
                    .put("racyCheckOk", true)
                    .put("contentCheckOk", true)
                if (sts != null) {
                    body.put("playbackContext", JSONObject().put(
                        "contentPlaybackContext", JSONObject().put("signatureTimestamp", sts)))
                }
                val json = Account.player(c.host, c.name, c.version, c.no, c.ua, body)
                val ps = json.optJSONObject("playabilityStatus")
                val status = ps?.optString("status") ?: "?"
                if (status != "OK") {
                    problems.add("${c.name}: $status ${ps?.optString("reason") ?: ""}".trim())
                    continue
                }
                val formats = json.optJSONObject("streamingData")?.optJSONArray("adaptiveFormats")
                if (formats == null) {
                    problems.add("${c.name}: no streams")
                    continue
                }
                var best: JSONObject? = null
                for (i in 0 until formats.length()) {
                    val f = formats.getJSONObject(i)
                    if (!f.optString("mimeType").startsWith("audio/")) continue
                    if (best == null || f.optInt("bitrate") > best.optInt("bitrate")) best = f
                }
                val f = best
                if (f == null) {
                    problems.add("${c.name}: no audio stream")
                    continue
                }
                var url = f.optString("url")
                if (url.isEmpty()) {
                    val cipher = f.optString("signatureCipher").ifEmpty { f.optString("cipher") }
                    val q = Uri.parse("https://x/?$cipher")
                    val sig = q.getQueryParameter("s") ?: throw IOException("missing signature")
                    val sp = q.getQueryParameter("sp") ?: "sig"
                    val base = q.getQueryParameter("url") ?: throw IOException("missing url")
                    url = "$base&$sp=" + Uri.encode(
                        YoutubeJavaScriptPlayerManager.deobfuscateSignature(videoId, sig))
                }
                url = YoutubeJavaScriptPlayerManager.getUrlWithThrottlingParameterDeobfuscated(videoId, url)
                val uri = Uri.parse(url)
                val expireSec = uri.getQueryParameter("expire")?.toLongOrNull()
                return Resolved(
                    url = url,
                    userAgent = c.ua,
                    mimeType = f.optString("mimeType").substringBefore(';').ifEmpty { "audio/mp4" },
                    contentLength = f.optString("contentLength").toLongOrNull()
                        ?: uri.getQueryParameter("clen")?.toLongOrNull() ?: -1L,
                    expiresAtMs = if (expireSec != null) expireSec * 1000 - 5 * 60 * 1000
                    else System.currentTimeMillis() + 60 * 60 * 1000,
                )
            } catch (e: Throwable) {
                problems.add("${c.name}: ${describe(e)}")
            }
        }
        throw IOException("YouTube didn't allow this with your account (${problems.joinToString(" | ")})")
    }

    /**
     * googlevideo URLs carry `c=<CLIENT>`; YouTube expects the same User-Agent the
     * extractor used when it asked for that client's player response.
     */
    private fun pickUserAgent(client: String?, agents: List<String>): String {
        val c = (client ?: "").uppercase(Locale.ROOT)
        fun find(pred: (String) -> Boolean) = agents.lastOrNull(pred)
        val match = when {
            c.contains("VR") -> find { it.contains("vr", true) || it.contains("oculus", true) }
            c.startsWith("IOS") -> find { it.contains("iPhone") || it.contains("iOS") || it.contains("ios.youtube") }
            c.startsWith("ANDROID") -> find { it.contains("android", true) }
            c.startsWith("TV") -> find { it.contains("Cobalt") || it.contains("SMART-TV", true) || it.contains("TV;") }
            c.startsWith("WEB") || c.startsWith("MWEB") -> find { it.startsWith("Mozilla/") }
            else -> null
        }
        return match ?: agents.lastOrNull() ?: DEFAULT_UA
    }

    // ── HTTP downloader used by NewPipeExtractor ────────────────────────────

    private class HttpDownloader : Downloader() {
        private val recorder = ThreadLocal<MutableList<String>?>()

        fun startRecordingPlayerAgents() = recorder.set(ArrayList())
        fun stopRecordingPlayerAgents(): List<String> {
            val list = recorder.get() ?: emptyList<String>()
            recorder.remove()
            return list
        }

        override fun execute(request: Request): Response {
            val url = request.url()
            val conn = URL(url).openConnection() as HttpURLConnection
            try {
                conn.connectTimeout = 15_000
                conn.readTimeout = 30_000
                conn.instanceFollowRedirects = true
                conn.requestMethod = request.httpMethod()

                var ua: String? = null
                for ((name, values) in request.headers()) {
                    // Let the platform negotiate compression so bodies arrive decoded.
                    if (name.equals("Accept-Encoding", ignoreCase = true)) continue
                    if (name.equals("User-Agent", ignoreCase = true)) ua = values.lastOrNull()
                    for (v in values) conn.addRequestProperty(name, v)
                }
                if (ua == null) {
                    ua = DEFAULT_UA
                    conn.setRequestProperty("User-Agent", ua)
                }
                if (url.contains("/youtubei/v1/player")) recorder.get()?.add(ua)

                val body = request.dataToSend()
                if (body != null) {
                    conn.doOutput = true
                    conn.outputStream.use { it.write(body) }
                }

                val code = conn.responseCode
                if (code == 429) {
                    throw ReCaptchaException("reCaptcha Challenge requested", url)
                }
                val raw: InputStream? = if (code >= 400) conn.errorStream else conn.inputStream
                val stream = if (raw != null && "gzip".equals(conn.contentEncoding, true)) {
                    GZIPInputStream(raw)
                } else raw
                val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""

                val headers = HashMap<String, List<String>>()
                for ((k, v) in conn.headerFields) if (k != null) headers[k] = v

                return Response(code, conn.responseMessage ?: "", headers, text, conn.url.toString())
            } finally {
                conn.disconnect()
            }
        }
    }

    // ── Local streaming proxy ───────────────────────────────────────────────

    private object Proxy {
        @Volatile private var server: ServerSocket? = null

        @Synchronized
        fun ensureStarted(): Int {
            server?.let { if (!it.isClosed) return it.localPort }
            val s = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
            server = s
            Thread({
                while (!s.isClosed) {
                    try {
                        val client = s.accept()
                        workers.execute { serve(client) }
                    } catch (_: IOException) {
                    }
                }
            }, "yt-proxy-accept").apply { isDaemon = true }.start()
            return s.localPort
        }

        private class ClientGone : IOException()

        private fun serve(socket: Socket) {
            socket.use { sock ->
                try {
                    sock.soTimeout = 30_000
                    val input = BufferedInputStream(sock.getInputStream())
                    val out = sock.getOutputStream()

                    val requestLine = readLine(input) ?: return
                    var rangeHeader: String? = null
                    while (true) {
                        val line = readLine(input) ?: break
                        if (line.isEmpty()) break
                        val idx = line.indexOf(':')
                        if (idx > 0 && line.substring(0, idx).trim().equals("Range", true)) {
                            rangeHeader = line.substring(idx + 1).trim()
                        }
                    }

                    val parts = requestLine.split(" ")
                    val method = parts.getOrNull(0) ?: ""
                    val path = parts.getOrNull(1) ?: ""
                    val videoId = path.removePrefix("/yt/").substringBefore('?')
                    if (!path.startsWith("/yt/") || !VIDEO_ID.matches(videoId)) {
                        writeStatus(out, 404, "Not Found"); return
                    }
                    if (method != "GET" && method != "HEAD") {
                        writeStatus(out, 405, "Method Not Allowed"); return
                    }
                    if (!serveCached(videoId, rangeHeader, method == "HEAD", out)) {
                        stream(videoId, rangeHeader, method == "HEAD", out)
                    }
                } catch (_: ClientGone) {
                    // Player closed the connection (seek, skip, stop) — normal.
                } catch (_: Throwable) {
                }
            }
        }

        private fun stream(videoId: String, rangeHeader: String?, headOnly: Boolean, out: OutputStream) {
            var start = 0L
            var requestedEnd = -1L
            if (rangeHeader != null) {
                val m = Regex("bytes=(\\d*)-(\\d*)").find(rangeHeader)
                if (m != null) {
                    start = m.groupValues[1].toLongOrNull() ?: 0L
                    requestedEnd = m.groupValues[2].toLongOrNull() ?: -1L
                }
            }

            var res = resolve(videoId, force = false)

            // First upstream chunk tells us the total size (Content-Range) if `clen` was missing.
            val firstEnd = if (requestedEnd >= 0) minOf(requestedEnd, start + CHUNK_SIZE - 1) else start + CHUNK_SIZE - 1
            val first = openChunk(videoId, res, start, firstEnd).also { res = it.resolved }
            val total = if (res.contentLength > 0) res.contentLength else first.total

            if (total > 0 && start >= total) {
                first.conn.disconnect()
                writeRaw(out, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */$total\r\nConnection: close\r\n\r\n")
                return
            }
            val end = when {
                total <= 0 -> -1L
                requestedEnd in 0 until total -> requestedEnd
                else -> total - 1
            }

            val head = StringBuilder()
            if (rangeHeader != null && total > 0) {
                head.append("HTTP/1.1 206 Partial Content\r\n")
                head.append("Content-Range: bytes $start-$end/$total\r\n")
                head.append("Content-Length: ${end - start + 1}\r\n")
            } else {
                head.append("HTTP/1.1 200 OK\r\n")
                if (total > 0) head.append("Content-Length: ${total - start}\r\n")
            }
            head.append("Content-Type: ${res.mimeType}\r\n")
            head.append("Accept-Ranges: bytes\r\n")
            head.append("Connection: close\r\n\r\n")
            writeRaw(out, head.toString())
            if (headOnly) { first.conn.disconnect(); return }
            pipeUpstream(videoId, res, start, end, first, out)
        }

        /** Streams bytes [start, end] straight from YouTube in range chunks. */
        private fun pipeUpstream(
            videoId: String,
            initial: Resolved,
            start: Long,
            end: Long,
            first: Chunk?,
            out: OutputStream,
        ) {
            var res = initial
            var pos = start
            var pending: Chunk? = first
            var emptyStreak = 0
            val buf = ByteArray(64 * 1024)
            while (end < 0 || pos <= end) {
                val chunk = pending ?: run {
                    val chunkEnd = if (end >= 0) minOf(end, pos + CHUNK_SIZE - 1) else pos + CHUNK_SIZE - 1
                    openChunk(videoId, res, pos, chunkEnd).also { res = it.resolved }
                }
                pending = null
                if (chunk.status == 416) { chunk.conn.disconnect(); break } // past the end (unknown size case)
                var readThisChunk = 0L
                try {
                    chunk.conn.inputStream.use { ins ->
                        // A 200 (instead of 206) means the server ignored Range: skip to our offset.
                        if (chunk.status == 200 && pos > 0) {
                            var toSkip = pos
                            while (toSkip > 0) {
                                val s = ins.skip(toSkip)
                                if (s <= 0) break
                                toSkip -= s
                            }
                        }
                        while (true) {
                            val n = ins.read(buf)
                            if (n < 0) break
                            try {
                                out.write(buf, 0, n)
                            } catch (e: IOException) {
                                throw ClientGone()
                            }
                            pos += n
                            readThisChunk += n
                            if (end >= 0 && pos > end) break
                        }
                    }
                } catch (e: ClientGone) {
                    throw e
                } catch (_: IOException) {
                    // Upstream hiccup mid-chunk: the loop retries from `pos` with a fresh request.
                } finally {
                    chunk.conn.disconnect()
                }
                if (readThisChunk == 0L) {
                    if (end < 0) break
                    if (++emptyStreak >= MAX_CHUNK_RETRIES) {
                        res = resolve(videoId, force = true)
                        if (emptyStreak >= MAX_CHUNK_RETRIES * 2) break
                    }
                } else {
                    emptyStreak = 0
                }
            }
            try { out.flush() } catch (_: IOException) {}
        }

        // ── Full-song download cache ────────────────────────────────────────
        //
        // Each prepared song is downloaded to a temp file from start to finish in
        // the background (with retries + fresh links). The player reads from that
        // file, so the end of a song never depends on a last-second request to
        // YouTube. Far seeks into a part that isn't downloaded yet fall back to
        // streaming directly.

        private const val DL_CHUNK = 512L * 1024
        private const val FAR_AHEAD = 3L * 1024 * 1024

        private class Download(val videoId: String, val file: File) {
            val lock = Object()
            @Volatile var total = -1L
            @Volatile var mime = "audio/mp4"
            @Volatile var downloaded = 0L
            @Volatile var done = false
            @Volatile var failed: Throwable? = null
            val users = AtomicInteger(0)
            @Volatile var lastUsed = System.currentTimeMillis()
        }

        private val downloads = LinkedHashMap<String, Download>()
        @Volatile private var cacheCleared = false

        private fun cacheDir(): File? {
            val ctx = appContext ?: return null
            val d = File(ctx.cacheDir, "yt_audio")
            if (!d.exists()) d.mkdirs()
            return d
        }

        // ── Offline saves: kept in app storage until the user deletes them ──

        private val offline = java.util.concurrent.ConcurrentHashMap<String, Download>()

        private fun offlineDir(): File? {
            val ctx = appContext ?: return null
            val d = File(ctx.filesDir, "offline")
            if (!d.exists()) d.mkdirs()
            return d
        }

        private fun extFor(mime: String) = if (mime.contains("webm")) "webm" else "m4a"

        private fun offlineFile(videoId: String): File? =
            offlineDir()?.listFiles()?.firstOrNull {
                it.name.startsWith("$videoId.") && !it.name.endsWith(".part")
            }

        /** Downloads a whole song into app storage (blocking). */
        fun saveOffline(videoId: String): Map<String, Any?> {
            offlineFile(videoId)?.let {
                return mapOf("path" to it.absolutePath, "bytes" to it.length())
            }
            val dir = offlineDir() ?: throw IOException("No app storage available")
            // Already fully in the playback cache? Just copy it.
            val cached = synchronized(downloads) { downloads[videoId] }
            if (cached != null && cached.done && cached.failed == null && cached.file.exists()) {
                val out = File(dir, "$videoId.${extFor(cached.mime)}")
                cached.file.copyTo(out, overwrite = true)
                return mapOf("path" to out.absolutePath, "bytes" to out.length())
            }
            val d = Download(videoId, File(dir, "$videoId.part"))
            offline[videoId] = d
            try {
                runDownload(d)
                d.failed?.let { throw it }
                val out = File(dir, "$videoId.${extFor(d.mime)}")
                if (!d.file.renameTo(out)) {
                    d.file.copyTo(out, overwrite = true)
                    d.file.delete()
                }
                return mapOf("path" to out.absolutePath, "bytes" to out.length())
            } catch (e: Throwable) {
                d.file.delete()
                throw e
            } finally {
                offline.remove(videoId)
            }
        }

        /** 0..1 while a save is running, -1 if none. */
        fun offlineProgress(videoId: String): Double {
            val d = offline[videoId] ?: return -1.0
            return if (d.total > 0) d.downloaded.toDouble() / d.total else 0.0
        }

        fun deleteOffline(videoId: String) {
            offlineDir()?.listFiles()?.filter { it.name.startsWith("$videoId.") }
                ?.forEach { it.delete() }
        }

        fun deleteAllOffline() {
            offlineDir()?.listFiles()?.forEach { it.delete() }
        }

        /** Deletes downloaded songs that aren't playing right now. */
        fun clearCache() {
            synchronized(downloads) {
                val idle = downloads.values.filter { it.users.get() == 0 }
                for (d in idle) {
                    downloads.remove(d.videoId)
                    d.file.delete()
                }
            }
        }

        fun prefetch(videoId: String, restartIfFailed: Boolean) {
            obtain(videoId, restartIfFailed)
        }

        private fun obtain(videoId: String, restartIfFailed: Boolean = false): Download? {
            val dir = cacheDir() ?: return null
            synchronized(downloads) {
                if (!cacheCleared) {
                    cacheCleared = true
                    dir.listFiles()?.forEach { it.delete() }
                }
                val existing = downloads[videoId]
                if (existing != null) {
                    // A download that failed earlier (network switch, phone
                    // dozing...) is started again instead of being reused, so
                    // a broken preload never makes the song wait later.
                    val retry = existing.failed != null &&
                        (restartIfFailed || existing.users.get() == 0)
                    if (!retry) {
                        existing.lastUsed = System.currentTimeMillis()
                        return existing
                    }
                    downloads.remove(videoId)
                    if (existing.users.get() == 0) existing.file.delete()
                }
                // Keep the cache small: drop the least recently used idle songs.
                while (downloads.size >= 6) {
                    val victim = downloads.values
                        .filter { it.users.get() == 0 }
                        .minByOrNull { it.lastUsed } ?: break
                    downloads.remove(victim.videoId)
                    victim.file.delete()
                }
                val d = Download(videoId, File(dir, "$videoId.${System.nanoTime()}.part"))
                downloads[videoId] = d
                workers.execute { runDownload(d) }
                return d
            }
        }

        private fun runDownload(d: Download) {
            try {
                var res = resolve(d.videoId, force = false)
                d.mime = res.mimeType
                RandomAccessFile(d.file, "rw").use { raf ->
                    val buf = ByteArray(64 * 1024)
                    var pos = 0L
                    var fails = 0
                    while (d.total < 0 || pos < d.total) {
                        val to = if (d.total > 0) minOf(d.total - 1, pos + DL_CHUNK - 1)
                        else pos + DL_CHUNK - 1
                        var got = 0L
                        var reachedEnd = false
                        try {
                            val c = openChunk(d.videoId, res, pos, to)
                            res = c.resolved
                            if (c.status == 416) {
                                c.conn.disconnect()
                                if (d.total < 0) d.total = pos
                                reachedEnd = true
                            } else {
                                // YouTube's own size (Content-Range) is the source of truth.
                                val upstreamTotal = when {
                                    c.total > 0 -> c.total
                                    c.status == 200 -> c.conn.contentLengthLong
                                    else -> -1L
                                }
                                if (upstreamTotal > 0) {
                                    synchronized(d.lock) {
                                        d.total = upstreamTotal
                                        d.lock.notifyAll()
                                    }
                                }
                                try {
                                    c.conn.inputStream.use { ins ->
                                        if (c.status == 200 && pos > 0) {
                                            var toSkip = pos
                                            while (toSkip > 0) {
                                                val sk = ins.skip(toSkip)
                                                if (sk <= 0) break
                                                toSkip -= sk
                                            }
                                        }
                                        raf.seek(pos)
                                        while (true) {
                                            val n = ins.read(buf)
                                            if (n < 0) break
                                            raf.write(buf, 0, n)
                                            pos += n
                                            got += n
                                            synchronized(d.lock) {
                                                d.downloaded = pos
                                                d.lock.notifyAll()
                                            }
                                            if (d.total > 0 && pos >= d.total) break
                                            if (pos > to) break
                                        }
                                    }
                                } finally {
                                    c.conn.disconnect()
                                }
                            }
                        } catch (_: IOException) {
                            // handled below as a failed attempt
                        }
                        if (reachedEnd) break
                        if (got == 0L) {
                            fails++
                            if (fails > 10) throw IOException("Download stalled at $pos/${d.total}")
                            try { Thread.sleep(minOf(4000L, 300L * fails)) } catch (_: InterruptedException) {}
                            if (fails % 3 == 0) {
                                try { res = resolve(d.videoId, force = true) } catch (_: Throwable) {}
                            }
                        } else {
                            fails = 0
                        }
                    }
                }
                d.done = true
            } catch (e: Throwable) {
                d.failed = e
            } finally {
                synchronized(d.lock) { d.lock.notifyAll() }
            }
        }

        /** Serves a request from the download cache. Returns false to fall back. */
        private fun serveCached(
            videoId: String,
            rangeHeader: String?,
            headOnly: Boolean,
            out: OutputStream,
        ): Boolean {
            val d = obtain(videoId) ?: return false
            d.users.incrementAndGet()
            try {
                synchronized(d.lock) {
                    val deadline = System.currentTimeMillis() + 20_000
                    while (d.total <= 0 && d.failed == null && !d.done &&
                        System.currentTimeMillis() < deadline
                    ) {
                        d.lock.wait(500)
                    }
                }
                val total = d.total
                if (total <= 0) return false

                var start = 0L
                var requestedEnd = -1L
                if (rangeHeader != null) {
                    val m = Regex("bytes=(\\d*)-(\\d*)").find(rangeHeader)
                    if (m != null) {
                        start = m.groupValues[1].toLongOrNull() ?: 0L
                        requestedEnd = m.groupValues[2].toLongOrNull() ?: -1L
                    }
                }
                if (start >= total) {
                    writeRaw(out, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */$total\r\nConnection: close\r\n\r\n")
                    return true
                }
                // A far seek into a part that isn't downloaded yet: stream it directly.
                if (!d.done && start > d.downloaded + FAR_AHEAD) return false
                val end = if (requestedEnd in 0 until total) requestedEnd else total - 1

                val head = StringBuilder()
                if (rangeHeader != null) {
                    head.append("HTTP/1.1 206 Partial Content\r\n")
                    head.append("Content-Range: bytes $start-$end/$total\r\n")
                    head.append("Content-Length: ${end - start + 1}\r\n")
                } else {
                    head.append("HTTP/1.1 200 OK\r\n")
                    head.append("Content-Length: ${total - start}\r\n")
                }
                head.append("Content-Type: ${d.mime}\r\n")
                head.append("Accept-Ranges: bytes\r\n")
                head.append("Connection: close\r\n\r\n")
                writeRaw(out, head.toString())
                if (headOnly) return true

                RandomAccessFile(d.file, "r").use { raf ->
                    val buf = ByteArray(64 * 1024)
                    var pos = start
                    while (pos <= end) {
                        var avail: Long
                        synchronized(d.lock) {
                            while (d.downloaded <= pos && d.failed == null && !d.done) {
                                d.lock.wait(1000)
                            }
                            avail = d.downloaded
                        }
                        if (avail <= pos) {
                            // The download gave up: fetch the rest straight from YouTube.
                            pipeUpstream(videoId, resolve(videoId, force = true), pos, end, null, out)
                            return true
                        }
                        val upto = minOf(end, avail - 1)
                        raf.seek(pos)
                        while (pos <= upto) {
                            val want = minOf(buf.size.toLong(), upto - pos + 1).toInt()
                            val n = raf.read(buf, 0, want)
                            if (n <= 0) break
                            try {
                                out.write(buf, 0, n)
                            } catch (e: IOException) {
                                throw ClientGone()
                            }
                            pos += n
                        }
                    }
                }
                try { out.flush() } catch (_: IOException) {}
                return true
            } finally {
                d.users.decrementAndGet()
                d.lastUsed = System.currentTimeMillis()
            }
        }

        private class Chunk(
            val conn: HttpURLConnection,
            val status: Int,
            val total: Long,
            val resolved: Resolved,
        )

        /** Opens one upstream range request, re-resolving the stream URL if YouTube rejects it. */
        private fun openChunk(videoId: String, initial: Resolved, from: Long, to: Long): Chunk {
            var res = initial
            var lastError: IOException? = null
            // Re-resolve without letting an extraction hiccup abort the retries.
            fun freshUrl() {
                try {
                    res = resolve(videoId, force = true)
                } catch (e: Throwable) {
                    lastError = IOException("Re-resolve failed: ${e.message}", e)
                }
            }
            for (attempt in 0 until MAX_CHUNK_RETRIES) {
                if (attempt > 0) {
                    // Short back-off: 0.4s, 0.8s, 1.2s, ... (YouTube often recovers quickly).
                    try { Thread.sleep(400L * attempt) } catch (_: InterruptedException) {}
                }
                val conn = URL(res.url).openConnection() as HttpURLConnection
                try {
                    conn.connectTimeout = 15_000
                    conn.readTimeout = 30_000
                    conn.instanceFollowRedirects = true
                    conn.setRequestProperty("User-Agent", res.userAgent)
                    conn.setRequestProperty("Range", "bytes=$from-$to")
                    conn.setRequestProperty("Accept", "*/*")
                    conn.setRequestProperty("Accept-Encoding", "identity")
                    conn.setRequestProperty("Origin", "https://music.youtube.com")
                    conn.setRequestProperty("Referer", "https://music.youtube.com/")
                    val code = conn.responseCode
                    when {
                        code == 206 || code == 200 -> {
                            val cr = conn.getHeaderField("Content-Range")
                            val total = cr?.substringAfter('/', "")?.toLongOrNull() ?: -1L
                            return Chunk(conn, code, total, res)
                        }
                        code == 416 -> return Chunk(conn, 416, -1L, res)
                        else -> {
                            conn.disconnect()
                            lastError = IOException("Upstream HTTP $code")
                            // 403/410 usually means the URL expired or was rejected: get a fresh one.
                            freshUrl()
                        }
                    }
                } catch (e: IOException) {
                    conn.disconnect()
                    lastError = e
                    // Network blip: retry the same URL once, then switch to a fresh one.
                    if (attempt >= 1) freshUrl()
                }
            }
            throw lastError ?: IOException("Upstream failed")
        }

        private fun readLine(input: InputStream): String? {
            val sb = StringBuilder()
            while (true) {
                val b = input.read()
                if (b < 0) return if (sb.isEmpty()) null else sb.toString()
                if (b == '\n'.code) return sb.toString().trimEnd('\r')
                sb.append(b.toChar())
                if (sb.length > 8192) return sb.toString()
            }
        }

        private fun writeStatus(out: OutputStream, code: Int, msg: String) =
            writeRaw(out, "HTTP/1.1 $code $msg\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

        private fun writeRaw(out: OutputStream, s: String) {
            try {
                out.write(s.toByteArray(Charsets.ISO_8859_1))
                out.flush()
            } catch (e: IOException) {
                throw ClientGone()
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// YouTube Music account (read-only): sign-in cookies + InnerTube browse calls.
// Separate from the NewPipe streaming code above — playback never uses this.
// ─────────────────────────────────────────────────────────────────────────────

object Account {
    private const val YTM = "https://music.youtube.com"
    private const val CLIENT_VERSION = "1.20251020.01.00"
    private const val DESKTOP_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    const val LOGIN_URL =
        "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&continue=https%3A%2F%2Fmusic.youtube.com%2F"

    @Volatile var pendingSignIn: MethodChannel.Result? = null
    @Volatile private var context: Context? = null

    fun bind(ctx: Context) { context = ctx.applicationContext }

    private fun prefs() = context?.getSharedPreferences("yt_account", Context.MODE_PRIVATE)

    fun cookies(): String? = prefs()?.getString("cookies", null)?.takeIf { it.contains("SAPISID=") }

    fun saveCookies(c: String) {
        prefs()?.edit()?.putString("cookies", c)?.apply()
    }

    fun signOut() {
        prefs()?.edit()?.clear()?.apply()
        try {
            CookieManager.getInstance().removeAllCookies(null)
            CookieManager.getInstance().flush()
        } catch (_: Throwable) {
        }
    }

    fun finishSignIn(success: Boolean) {
        val r = pendingSignIn ?: return
        pendingSignIn = null
        Handler(Looper.getMainLooper()).post { r.success(success) }
    }

    // ── InnerTube ───────────────────────────────────────────────────────────

    private fun sapisidHash(cookies: String, origin: String = YTM): String? {
        val sapisid = Regex("(?:^|;\\s*)SAPISID=([^;]+)").find(cookies)?.groupValues?.get(1)
            ?: Regex("(?:^|;\\s*)__Secure-3PAPISID=([^;]+)").find(cookies)?.groupValues?.get(1)
            ?: return null
        val ts = System.currentTimeMillis() / 1000
        val digest = MessageDigest.getInstance("SHA-1")
            .digest("$ts $sapisid $origin".toByteArray())
            .joinToString("") { "%02x".format(it) }
        return "SAPISIDHASH ${ts}_$digest"
    }

    /** Signed-in /player request for one InnerTube client (see resolveWithAccount). */
    fun player(
        host: String,
        clientName: String,
        clientVersion: String,
        clientNo: String,
        ua: String,
        body: JSONObject,
    ): JSONObject {
        val c = cookies() ?: throw IOException("Sign in to YouTube Music in AlexLMP to play this.")
        val locale = Locale.getDefault()
        val client = JSONObject()
            .put("clientName", clientName)
            .put("clientVersion", clientVersion)
            .put("hl", locale.language.ifEmpty { "en" })
            .put("gl", locale.country.takeIf { it.length == 2 } ?: "US")
        body.put("context", JSONObject().put("client", client).put("user", JSONObject()))
        val conn = URL("$host/youtubei/v1/player?prettyPrint=false").openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("User-Agent", ua)
            conn.setRequestProperty("Origin", host)
            conn.setRequestProperty("X-Origin", host)
            conn.setRequestProperty("Referer", "$host/")
            conn.setRequestProperty("X-YouTube-Client-Name", clientNo)
            conn.setRequestProperty("X-YouTube-Client-Version", clientVersion)
            conn.setRequestProperty("Cookie", c)
            sapisidHash(c, host)?.let { conn.setRequestProperty("Authorization", it) }
            conn.setRequestProperty("X-Goog-AuthUser", "0")
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            val code = conn.responseCode
            val raw = (if (code >= 400) conn.errorStream else conn.inputStream)
            val text = raw?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
            if (code !in 200..299) throw IOException("HTTP $code: ${text.take(200)}")
            return JSONObject(text)
        } finally {
            conn.disconnect()
        }
    }

    private fun call(endpoint: String, body: JSONObject, auth: Boolean): JSONObject {
        val locale = Locale.getDefault()
        val client = JSONObject()
            .put("clientName", "WEB_REMIX")
            .put("clientVersion", CLIENT_VERSION)
            .put("hl", locale.language.ifEmpty { "en" })
            .put("gl", locale.country.takeIf { it.length == 2 } ?: "US")
        body.put("context", JSONObject().put("client", client).put("user", JSONObject()))

        val conn = URL("$YTM/youtubei/v1/$endpoint?prettyPrint=false").openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("User-Agent", DESKTOP_UA)
            conn.setRequestProperty("Origin", YTM)
            conn.setRequestProperty("X-Origin", YTM)
            conn.setRequestProperty("Referer", "$YTM/")
            conn.setRequestProperty("X-YouTube-Client-Name", "67")
            conn.setRequestProperty("X-YouTube-Client-Version", CLIENT_VERSION)
            if (auth) {
                val c = cookies() ?: throw IOException("Not signed in to YouTube Music")
                conn.setRequestProperty("Cookie", c)
                sapisidHash(c)?.let { conn.setRequestProperty("Authorization", it) }
                conn.setRequestProperty("X-Goog-AuthUser", "0")
            }
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            val code = conn.responseCode
            val raw = (if (code >= 400) conn.errorStream else conn.inputStream)
            val text = raw?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
            if (code !in 200..299) {
                if (auth && (code == 401 || code == 403)) {
                    throw IOException("YouTube rejected the sign-in (HTTP $code). Sign out and sign in again.")
                }
                throw IOException("YouTube Music HTTP $code: ${text.take(200)}")
            }
            return JSONObject(text)
        } finally {
            conn.disconnect()
        }
    }

    // ── JSON helpers (walk the response instead of hard-coding paths) ──────

    private fun collect(node: Any?, key: String, out: MutableList<JSONObject>) {
        when (node) {
            is JSONObject -> {
                val keys = node.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    val v = node.opt(k)
                    if (k == key && v is JSONObject) out.add(v) else collect(v, key, out)
                }
            }
            is JSONArray -> for (i in 0 until node.length()) collect(node.opt(i), key, out)
        }
    }

    private fun all(node: Any?, key: String): List<JSONObject> =
        ArrayList<JSONObject>().also { collect(node, key, it) }

    private fun firstString(node: Any?, key: String): String? {
        when (node) {
            is JSONObject -> {
                val direct = node.opt(key)
                if (direct is String && direct.isNotEmpty()) return direct
                val keys = node.keys()
                while (keys.hasNext()) {
                    firstString(node.opt(keys.next()), key)?.let { return it }
                }
            }
            is JSONArray -> for (i in 0 until node.length()) {
                firstString(node.opt(i), key)?.let { return it }
            }
        }
        return null
    }

    private fun text(o: JSONObject?): String {
        if (o == null) return ""
        o.optString("simpleText").takeIf { it.isNotEmpty() }?.let { return it }
        val runs = o.optJSONArray("runs") ?: return ""
        val sb = StringBuilder()
        for (i in 0 until runs.length()) sb.append(runs.optJSONObject(i)?.optString("text") ?: "")
        return sb.toString()
    }

    private fun lastThumb(node: Any?): String? {
        val lists = ArrayList<JSONArray>()
        fun find(n: Any?) {
            when (n) {
                is JSONObject -> {
                    val keys = n.keys()
                    while (keys.hasNext()) {
                        val k = keys.next()
                        val v = n.opt(k)
                        if (k == "thumbnails" && v is JSONArray) lists.add(v) else find(v)
                    }
                }
                is JSONArray -> for (i in 0 until n.length()) find(n.opt(i))
            }
        }
        find(node)
        val arr = lists.firstOrNull() ?: return null
        val url = arr.optJSONObject(arr.length() - 1)?.optString("url") ?: return null
        val fixed = if (url.startsWith("//")) "https:$url" else url
        return fixed.replace(Regex("=w\\d+-h\\d+[^&?/]*$"), "=w544-h544-l90-rj")
    }

    private fun pageType(run: JSONObject?): String? =
        run?.optJSONObject("navigationEndpoint")
            ?.optJSONObject("browseEndpoint")
            ?.optJSONObject("browseEndpointContextSupportedConfigs")
            ?.optJSONObject("browseEndpointContextMusicConfig")
            ?.optString("pageType")

    private fun browseId(run: JSONObject?): String? =
        run?.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")
            ?.optString("browseId")?.takeIf { it.isNotEmpty() }

    private fun parseDuration(s: String?): Int {
        if (s.isNullOrBlank()) return 0
        val parts = s.trim().split(":").mapNotNull { it.toIntOrNull() }
        if (parts.isEmpty() || parts.size > 3) return 0
        return parts.fold(0) { acc, v -> acc * 60 + v }
    }

    // ── Parsers ─────────────────────────────────────────────────────────────

    private fun parseSong(r: JSONObject): Map<String, Any?>? {
        if (r.optString("musicItemRendererDisplayPolicy").contains("GREY_OUT")) return null
        val cols = r.optJSONArray("flexColumns") ?: return null
        fun col(i: Int): JSONObject? = cols.optJSONObject(i)
            ?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")?.optJSONObject("text")
        val videoId = r.optJSONObject("playlistItemData")?.optString("videoId")?.takeIf { it.isNotEmpty() }
            ?: firstString(r.optJSONObject("overlay"), "videoId")
            ?: firstString(col(0), "videoId")
            ?: return null
        val title = text(col(0)).ifEmpty { return null }

        var artist = ""
        var artistId: String? = null
        var album = ""
        var albumId: String? = null
        for (c in 1 until cols.length()) {
            val runs = col(c)?.optJSONArray("runs") ?: continue
            for (i in 0 until runs.length()) {
                val run = runs.optJSONObject(i)
                when (pageType(run)) {
                    "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL" -> {
                        if (artistId == null) artistId = browseId(run)
                        val name = run?.optString("text") ?: ""
                        artist = if (artist.isEmpty()) name else "$artist, $name"
                    }
                    "MUSIC_PAGE_TYPE_ALBUM" -> if (albumId == null) {
                        albumId = browseId(run)
                        album = run?.optString("text") ?: ""
                    }
                }
            }
        }
        if (artist.isEmpty()) artist = text(col(1)).split(" • ").firstOrNull() ?: ""

        val fixed = r.optJSONArray("fixedColumns")?.optJSONObject(0)
            ?.optJSONObject("musicResponsiveListItemFixedColumnRenderer")?.optJSONObject("text")
        var duration = parseDuration(text(fixed))
        if (duration == 0) {
            val m = Regex("(\\d+:)?\\d{1,2}:\\d{2}").findAll(text(col(1))).lastOrNull()
            duration = parseDuration(m?.value)
        }
        return mapOf(
            "videoId" to videoId,
            "title" to title,
            "artist" to artist,
            "album" to album,
            "albumId" to albumId,
            "artistId" to artistId,
            "durationSeconds" to duration,
            "thumbnail" to lastThumb(r.optJSONObject("thumbnail")),
        )
    }

    private fun continuationToken(node: Any?): String? {
        all(node, "continuationCommand").firstOrNull()?.optString("token")
            ?.takeIf { it.isNotEmpty() }?.let { return it }
        return all(node, "nextContinuationData").firstOrNull()?.optString("continuation")
            ?.takeIf { it.isNotEmpty() }
    }

    // ── Public calls ────────────────────────────────────────────────────────

    fun status(): Map<String, Any?> {
        if (cookies() == null) return mapOf("signedIn" to false)
        var name: String? = null
        var photo: String? = null
        try {
            val r = call("account/account_menu", JSONObject(), auth = true)
            name = all(r, "accountName").firstOrNull()?.let { text(it) }?.ifEmpty { null }
            photo = all(r, "accountPhoto").firstOrNull()?.let { lastThumb(it) }
        } catch (_: Throwable) {
        }
        return mapOf("signedIn" to true, "name" to name, "photo" to photo)
    }

    fun libraryPlaylists(): List<Map<String, Any?>> {
        val r = call("browse", JSONObject().put("browseId", "FEmusic_liked_playlists"), auth = true)
        val out = ArrayList<Map<String, Any?>>()
        val seen = HashSet<String>()
        // Grid layout
        for (t in all(r, "musicTwoRowItemRenderer")) {
            val id = t.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")
                ?.optString("browseId") ?: continue
            if (!id.startsWith("VL")) continue
            val pid = id.removePrefix("VL")
            if (!seen.add(pid)) continue
            out.add(mapOf(
                "playlistId" to pid,
                "title" to text(t.optJSONObject("title")),
                "subtitle" to text(t.optJSONObject("subtitle")),
                "thumbnail" to lastThumb(t.optJSONObject("thumbnailRenderer")),
            ))
        }
        // List layout
        for (t in all(r, "musicResponsiveListItemRenderer")) {
            val id = t.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")
                ?.optString("browseId") ?: continue
            if (!id.startsWith("VL")) continue
            val pid = id.removePrefix("VL")
            if (!seen.add(pid)) continue
            val cols = t.optJSONArray("flexColumns")
            fun col(i: Int): JSONObject? = cols?.optJSONObject(i)
                ?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")?.optJSONObject("text")
            out.add(mapOf(
                "playlistId" to pid,
                "title" to text(col(0)),
                "subtitle" to text(col(1)),
                "thumbnail" to lastThumb(t.optJSONObject("thumbnail")),
            ))
        }
        return out
    }

    fun playlistTracks(playlistId: String, auth: Boolean): Map<String, Any?> {
        require(playlistId.isNotBlank()) { "Missing playlist id" }
        val first = call("browse", JSONObject().put("browseId", "VL$playlistId"), auth = auth && cookies() != null)
        // Only the playlist's own shelf (skips "Suggestions" sections in your own playlists).
        val shelf: Any = all(first, "musicPlaylistShelfRenderer").firstOrNull() ?: first
        val tracks = ArrayList<Map<String, Any?>>()
        val seen = HashSet<String>()
        fun addFrom(node: Any?) {
            for (r in all(node, "musicResponsiveListItemRenderer")) {
                val song = parseSong(r) ?: continue
                if (seen.add(song["videoId"] as String)) tracks.add(song)
            }
        }
        addFrom(shelf)
        var token = continuationToken(shelf)
        var pages = 0
        while (token != null && pages < 30) {
            pages++
            val next = call("browse", JSONObject().put("continuation", token), auth = auth && cookies() != null)
            val before = tracks.size
            addFrom(next)
            token = continuationToken(next)
            if (tracks.size == before) break
        }
        val header = all(first, "musicResponsiveHeaderRenderer").firstOrNull()
            ?: all(first, "musicDetailHeaderRenderer").firstOrNull()
        return mapOf(
            "title" to header?.let { text(it.optJSONObject("title")) },
            "thumbnail" to header?.let { lastThumb(it.optJSONObject("thumbnail")) },
            "tracks" to tracks,
        )
    }

    // ── Album pages (public, no sign-in needed) ────────────────────────────

    /** Finds an album's MPREb_ browse id from its OLAK playlist id (same trick ytmusicapi uses). */
    private fun albumBrowseId(listId: String): String? {
        val conn = URL("$YTM/playlist?list=$listId").openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 20_000
            conn.setRequestProperty("User-Agent", DESKTOP_UA)
            conn.setRequestProperty("Accept-Language", "en-US,en;q=0.9")
            conn.setRequestProperty("Cookie", "SOCS=CAI") // skip the EU consent page
            if (conn.responseCode != 200) return null
            val html = conn.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
            return Regex("MPREb_[A-Za-z0-9_-]+").find(html)?.value
        } finally {
            conn.disconnect()
        }
    }

    fun albumPage(ref: String): Map<String, Any?> {
        val albumBrowse = if (ref.startsWith("MPREb_")) ref else {
            val list = Regex("[?&]list=([A-Za-z0-9_-]+)").find(ref)?.groupValues?.get(1)
                ?: ref.takeIf { it.startsWith("OLAK") }
                ?: throw IOException("Not an album link")
            albumBrowseId(list) ?: throw IOException("Couldn't find the album page")
        }
        val r = call("browse", JSONObject().put("browseId", albumBrowse), auth = false)
        val header = all(r, "musicResponsiveHeaderRenderer").firstOrNull()
            ?: all(r, "musicDetailHeaderRenderer").firstOrNull()
        val title = text(header?.optJSONObject("title"))
        val subtitle = text(header?.optJSONObject("subtitle"))          // e.g. "Album • 2021"
        val second = text(header?.optJSONObject("secondSubtitle"))      // e.g. "12 songs • 41 minutes"
        var artist = text(header?.optJSONObject("straplineTextOne"))
        var artistId: String? = header?.optJSONObject("straplineTextOne")?.optJSONArray("runs")
            ?.optJSONObject(0)?.let { browseId(it) }
        if (artist.isEmpty()) {
            val runs = header?.optJSONObject("subtitle")?.optJSONArray("runs")
            if (runs != null) for (i in 0 until runs.length()) {
                val run = runs.optJSONObject(i)
                if (pageType(run) == "MUSIC_PAGE_TYPE_ARTIST") {
                    artist = run?.optString("text") ?: ""
                    artistId = browseId(run)
                    break
                }
            }
        }
        val description = all(header, "musicDescriptionShelfRenderer").firstOrNull()
            ?.let { text(it.optJSONObject("description")) }
            ?: text(header?.optJSONObject("description")).ifEmpty { null }
        val cover = lastThumb(header?.optJSONObject("thumbnail"))
        val year = Regex("\\b(19|20)\\d{2}\\b").find(subtitle)?.value
        val kind = subtitle.split(" • ").firstOrNull()?.trim()?.ifEmpty { null }

        // Track list: the album's own shelf.
        val shelf: Any = all(r, "musicShelfRenderer").firstOrNull() ?: r
        val tracks = ArrayList<Map<String, Any?>>()
        val seen = HashSet<String>()
        for (item in all(shelf, "musicResponsiveListItemRenderer")) {
            val song = parseSong(item) ?: continue
            if (!seen.add(song["videoId"] as String)) continue
            val m = HashMap(song)
            if ((m["artist"] as? String).isNullOrEmpty()) m["artist"] = artist
            if (m["thumbnail"] == null) m["thumbnail"] = cover
            m["album"] = title
            tracks.add(m)
        }

        // "More by artist" / "Other versions" carousels.
        val shelves = ArrayList<Map<String, Any?>>()
        for (c in all(r, "musicCarouselShelfRenderer")) {
            val shelfTitle = all(c, "musicCarouselShelfBasicHeaderRenderer").firstOrNull()
                ?.let { text(it.optJSONObject("title")) } ?: ""
            val items = ArrayList<Map<String, Any?>>()
            for (t in all(c, "musicTwoRowItemRenderer")) {
                val id = t.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")
                    ?.optString("browseId") ?: continue
                if (!id.startsWith("MPREb_")) continue
                items.add(mapOf(
                    "url" to id,
                    "title" to text(t.optJSONObject("title")),
                    "artist" to text(t.optJSONObject("subtitle")),
                    "thumbnail" to lastThumb(t.optJSONObject("thumbnailRenderer")),
                    "trackCount" to -1,
                ))
            }
            if (items.isNotEmpty()) shelves.add(mapOf("title" to shelfTitle, "items" to items))
        }

        return mapOf(
            "title" to title,
            "artist" to artist,
            "artistUrl" to artistId?.let { "https://www.youtube.com/channel/$it" },
            "thumbnail" to cover,
            "year" to year,
            "kind" to kind,
            "info" to second.ifEmpty { null },
            "description" to description,
            "tracks" to tracks,
            "shelves" to shelves,
        )
    }

    // ── YouTube Music home feed + library albums/artists ───────────────────

    /** Turns carousel shelves into simple maps (songs, videos, albums, playlists, artists). */
    private fun parseShelves(node: Any?): List<Map<String, Any?>> {
        val shelves = ArrayList<Map<String, Any?>>()
        for (c in all(node, "musicCarouselShelfRenderer")) {
            val header = all(c, "musicCarouselShelfBasicHeaderRenderer").firstOrNull()
            val title = header?.let { text(it.optJSONObject("title")) } ?: ""
            val strap = header?.let { text(it.optJSONObject("strapline")) } ?: ""
            val items = ArrayList<Map<String, Any?>>()
            var kind = ""
            for (t in all(c, "musicTwoRowItemRenderer")) {
                val nav = t.optJSONObject("navigationEndpoint")
                val browse = nav?.optJSONObject("browseEndpoint")?.optString("browseId") ?: ""
                val videoId = nav?.optJSONObject("watchEndpoint")?.optString("videoId") ?: ""
                val playlistId = nav?.optJSONObject("watchPlaylistEndpoint")?.optString("playlistId") ?: ""
                val itemKind = when {
                    browse.startsWith("MPREb_") -> "album"
                    browse.startsWith("UC") -> "artist"
                    browse.startsWith("VL") -> "playlist"
                    videoId.isNotEmpty() -> "video"
                    playlistId.isNotEmpty() -> "playlist"
                    else -> continue
                }
                if (kind.isEmpty()) kind = itemKind
                items.add(mapOf(
                    "kind" to itemKind,
                    "id" to when (itemKind) {
                        "artist" -> "https://www.youtube.com/channel/$browse"
                        "playlist" -> if (browse.isNotEmpty()) browse.removePrefix("VL") else playlistId
                        "video" -> videoId
                        else -> browse
                    },
                    "title" to text(t.optJSONObject("title")),
                    "subtitle" to text(t.optJSONObject("subtitle")),
                    "thumbnail" to lastThumb(t.optJSONObject("thumbnailRenderer")),
                ))
            }
            for (r in all(c, "musicResponsiveListItemRenderer")) {
                val song = parseSong(r) ?: continue
                if (kind.isEmpty()) kind = "song"
                items.add(mapOf(
                    "kind" to "song",
                    "id" to song["videoId"],
                    "title" to song["title"],
                    "subtitle" to song["artist"],
                    "thumbnail" to song["thumbnail"],
                    "durationSeconds" to song["durationSeconds"],
                ))
            }
            if (items.isNotEmpty()) {
                shelves.add(mapOf("title" to title, "strapline" to strap, "kind" to kind, "items" to items))
            }
        }
        return shelves
    }

    fun homeFeed(): Map<String, Any?> {
        val auth = cookies() != null
        val first = call("browse", JSONObject().put("browseId", "FEmusic_home"), auth = auth)
        val shelves = ArrayList<Map<String, Any?>>(parseShelves(first))
        var token = all(first, "sectionListRenderer").firstOrNull()?.let { continuationToken(it) }
        var pages = 0
        while (token != null && pages < 3) {
            pages++
            val next = call("browse", JSONObject().put("continuation", token), auth = auth)
            shelves.addAll(parseShelves(next))
            token = continuationToken(next)
        }
        return mapOf("signedIn" to auth, "shelves" to shelves)
    }

    fun libraryAlbums(): List<Map<String, Any?>> {
        val r = call("browse", JSONObject().put("browseId", "FEmusic_liked_albums"), auth = true)
        val out = ArrayList<Map<String, Any?>>()
        val seen = HashSet<String>()
        for (t in all(r, "musicTwoRowItemRenderer")) {
            val id = t.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")
                ?.optString("browseId") ?: continue
            if (!id.startsWith("MPREb_") || !seen.add(id)) continue
            out.add(mapOf(
                "url" to id,
                "title" to text(t.optJSONObject("title")),
                "artist" to text(t.optJSONObject("subtitle")),
                "thumbnail" to lastThumb(t.optJSONObject("thumbnailRenderer")),
                "trackCount" to -1,
            ))
        }
        for (t in all(r, "musicResponsiveListItemRenderer")) {
            val id = t.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")
                ?.optString("browseId") ?: continue
            if (!id.startsWith("MPREb_") || !seen.add(id)) continue
            val cols = t.optJSONArray("flexColumns")
            fun col(i: Int): JSONObject? = cols?.optJSONObject(i)
                ?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")?.optJSONObject("text")
            out.add(mapOf(
                "url" to id,
                "title" to text(col(0)),
                "artist" to text(col(1)),
                "thumbnail" to lastThumb(t.optJSONObject("thumbnail")),
                "trackCount" to -1,
            ))
        }
        return out
    }

    fun libraryArtists(): List<Map<String, Any?>> {
        val r = call("browse", JSONObject().put("browseId", "FEmusic_library_corpus_track_artists"), auth = true)
        val out = ArrayList<Map<String, Any?>>()
        val seen = HashSet<String>()
        val items = all(r, "musicResponsiveListItemRenderer") + all(r, "musicTwoRowItemRenderer")
        for (t in items) {
            val id = t.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")
                ?.optString("browseId") ?: continue
            if (!id.startsWith("UC") || !seen.add(id)) continue
            val cols = t.optJSONArray("flexColumns")
            fun col(i: Int): JSONObject? = cols?.optJSONObject(i)
                ?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")?.optJSONObject("text")
            val name = if (cols != null) text(col(0)) else text(t.optJSONObject("title"))
            val sub = if (cols != null) text(col(1)) else text(t.optJSONObject("subtitle"))
            out.add(mapOf(
                "url" to "https://www.youtube.com/channel/$id",
                "name" to name,
                "subtitle" to sub,
                "thumbnail" to lastThumb(t.optJSONObject("thumbnail") ?: t.optJSONObject("thumbnailRenderer")),
            ))
        }
        return out
    }

    // ── Artist pages (public) ───────────────────────────────────────────────

    fun artistPage(urlOrId: String): Map<String, Any?> {
        val channelId = Regex("(UC[A-Za-z0-9_-]{22})").find(urlOrId)?.value
            ?: throw IOException("Not an artist link")
        val r = call("browse", JSONObject().put("browseId", channelId), auth = false)
        val header = all(r, "musicImmersiveHeaderRenderer").firstOrNull()
            ?: all(r, "musicVisualHeaderRenderer").firstOrNull()
            ?: all(r, "musicResponsiveHeaderRenderer").firstOrNull()
        val name = text(header?.optJSONObject("title"))
        val description = text(header?.optJSONObject("description")).ifEmpty {
            all(r, "musicDescriptionShelfRenderer").firstOrNull()
                ?.let { text(it.optJSONObject("description")) } ?: ""
        }
        val banner = lastThumb(header?.optJSONObject("thumbnail"))
            ?.replace(Regex("=w\\d+-h\\d+[^&?/]*$"), "=w1200-h1200-p-l90-rj")
        val avatar = lastThumb(header?.optJSONObject("foregroundThumbnail"))
        val subscribers = all(header, "subscribeButtonRenderer").firstOrNull()
            ?.let { text(it.optJSONObject("subscriberCountText")) }
            ?.ifEmpty { null }
        val audience = text(header?.optJSONObject("monthlyListenerCount")).ifEmpty { null }

        // Top songs shelf
        val songs = ArrayList<Map<String, Any?>>()
        val songShelf = all(r, "musicShelfRenderer").firstOrNull()
        if (songShelf != null) {
            for (item in all(songShelf, "musicResponsiveListItemRenderer")) {
                val song = parseSong(item) ?: continue
                val m = HashMap(song)
                // Play count is usually the 3rd column ("12M plays").
                val cols = item.optJSONArray("flexColumns")
                for (c in 1 until (cols?.length() ?: 0)) {
                    val t = text(cols?.optJSONObject(c)
                        ?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")
                        ?.optJSONObject("text"))
                    if (t.contains("play", ignoreCase = true)) m["plays"] = t
                }
                if ((m["artist"] as? String).isNullOrEmpty()) m["artist"] = name
                songs.add(m)
            }
        }

        // Carousels: albums, singles, videos, related artists, featured playlists
        val shelves = ArrayList<Map<String, Any?>>()
        for (c in all(r, "musicCarouselShelfRenderer")) {
            val title = all(c, "musicCarouselShelfBasicHeaderRenderer").firstOrNull()
                ?.let { text(it.optJSONObject("title")) } ?: ""
            val items = ArrayList<Map<String, Any?>>()
            var kind = ""
            for (t in all(c, "musicTwoRowItemRenderer")) {
                val nav = t.optJSONObject("navigationEndpoint")
                val browse = nav?.optJSONObject("browseEndpoint")?.optString("browseId") ?: ""
                val videoId = nav?.optJSONObject("watchEndpoint")?.optString("videoId") ?: ""
                val itemKind = when {
                    browse.startsWith("MPREb_") -> "album"
                    browse.startsWith("UC") -> "artist"
                    browse.startsWith("VL") -> "playlist"
                    videoId.isNotEmpty() -> "video"
                    else -> continue
                }
                if (kind.isEmpty()) kind = itemKind
                items.add(mapOf(
                    "kind" to itemKind,
                    "id" to when (itemKind) {
                        "artist" -> "https://www.youtube.com/channel/$browse"
                        "playlist" -> browse.removePrefix("VL")
                        "video" -> videoId
                        else -> browse
                    },
                    "title" to text(t.optJSONObject("title")),
                    "subtitle" to text(t.optJSONObject("subtitle")),
                    "thumbnail" to lastThumb(t.optJSONObject("thumbnailRenderer")),
                ))
            }
            if (items.isNotEmpty()) {
                shelves.add(mapOf("title" to title, "kind" to kind, "items" to items))
            }
        }

        return mapOf(
            "name" to name,
            "description" to description.ifEmpty { null },
            "banner" to banner,
            "avatar" to avatar,
            "subscribers" to subscribers,
            "audience" to audience,
            "songs" to songs,
            "shelves" to shelves,
        )
    }

    /** Artist + album for a song (used by "Go to artist" / "Go to album"). */
    /** Likes (or un-likes) a song on your YouTube Music account. */
    fun rate(videoId: String, like: Boolean) {
        call(
            if (like) "like/like" else "like/removelike",
            JSONObject().put("target", JSONObject().put("videoId", videoId)),
            auth = true,
        )
    }

    /** YouTube Music's own lyrics for a song: plain text plus the source line. */
    fun lyrics(videoId: String): Map<String, Any?>? {
        val r = call(
            "next",
            JSONObject().put("videoId", videoId).put("isAudioOnly", true),
            auth = false,
        )
        // The player's "Lyrics" tab points at a browse page (MPLYt…).
        var browse: String? = null
        for (t in all(r, "tabRenderer")) {
            val ep = t.optJSONObject("endpoint")?.optJSONObject("browseEndpoint") ?: continue
            val id = ep.optString("browseId")
            val pt = ep.optJSONObject("browseEndpointContextSupportedConfigs")
                ?.optJSONObject("browseEndpointContextMusicConfig")
                ?.optString("pageType")
            if (pt == "MUSIC_PAGE_TYPE_TRACK_LYRICS" || id.startsWith("MPLYt")) {
                browse = id
                break
            }
        }
        if (browse == null) return null
        val b = call("browse", JSONObject().put("browseId", browse), auth = false)
        val shelf = all(b, "musicDescriptionShelfRenderer").firstOrNull() ?: return null
        val plain = text(shelf.optJSONObject("description"))
        if (plain.isBlank()) return null
        return mapOf(
            "plain" to plain,
            "source" to text(shelf.optJSONObject("footer")),
        )
    }

    fun trackLinks(videoId: String): Map<String, Any?> {
        val r = call(
            "next",
            JSONObject().put("videoId", videoId).put("isAudioOnly", true),
            auth = false,
        )
        val panel = all(r, "playlistPanelVideoRenderer")
            .firstOrNull { it.optString("videoId") == videoId }
            ?: all(r, "playlistPanelVideoRenderer").firstOrNull()
        val runs = panel?.optJSONObject("longBylineText")?.optJSONArray("runs")
        var artistId: String? = null
        var artistName: String? = null
        var albumId: String? = null
        var albumTitle: String? = null
        if (runs != null) {
            for (i in 0 until runs.length()) {
                val run = runs.optJSONObject(i)
                when (pageType(run)) {
                    "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL" -> if (artistId == null) {
                        artistId = browseId(run)
                        artistName = run?.optString("text")
                    }
                    "MUSIC_PAGE_TYPE_ALBUM" -> if (albumId == null) {
                        albumId = browseId(run)
                        albumTitle = run?.optString("text")
                    }
                }
            }
        }
        var albumPlaylist: String? = null
        var albumThumb: String? = null
        if (albumId != null) {
            try {
                val a = call("browse", JSONObject().put("browseId", albumId), auth = false)
                albumPlaylist = firstString(a, "audioPlaylistId")
                    ?: Regex("\"(OLAK5uy_[A-Za-z0-9_-]+)\"").find(a.toString())?.groupValues?.get(1)
                albumThumb = all(a, "musicResponsiveHeaderRenderer").firstOrNull()
                    ?.let { lastThumb(it.optJSONObject("thumbnail")) }
                    ?: all(a, "musicDetailHeaderRenderer").firstOrNull()
                        ?.let { lastThumb(it.optJSONObject("thumbnail")) }
            } catch (_: Throwable) {
            }
        }
        return mapOf(
            "artistUrl" to artistId?.let { "https://www.youtube.com/channel/$it" },
            "artistName" to artistName,
            "albumUrl" to albumPlaylist?.let { "https://www.youtube.com/playlist?list=$it" },
            "albumBrowseId" to albumId,
            "albumTitle" to albumTitle,
            "albumThumbnail" to albumThumb,
        )
    }
}

/** Google sign-in page in a WebView; saves the YouTube Music cookies when done. */
class YtLoginActivity : Activity() {
    private lateinit var web: WebView
    private var done = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "Sign in to YouTube Music"
        Account.bind(this)
        val cm = CookieManager.getInstance()
        cm.setAcceptCookie(true)
        web = WebView(this)
        cm.setAcceptThirdPartyCookies(web, true)
        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = true
        web.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                if (url != null && url.startsWith("https://music.youtube.com")) {
                    val cookies = cm.getCookie("https://music.youtube.com")
                    if (cookies != null && cookies.contains("SAPISID=")) {
                        cm.flush()
                        Account.saveCookies(cookies)
                        finishWith(true)
                    }
                }
            }
        }
        setContentView(web)
        web.loadUrl(Account.LOGIN_URL)
    }

    private fun finishWith(success: Boolean) {
        if (done) return
        done = true
        Account.finishSignIn(success)
        finish()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (::web.isInitialized && web.canGoBack()) web.goBack() else finishWith(false)
    }

    override fun onDestroy() {
        if (!done) {
            done = true
            Account.finishSignIn(false)
        }
        super.onDestroy()
    }
}

