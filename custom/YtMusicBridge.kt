package com.alexlmp.app

import android.content.Context
import android.net.Uri
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
import org.schabi.newpipe.extractor.services.youtube.linkHandler.YoutubeSearchQueryHandlerFactory
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.DeliveryMethod
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import java.io.BufferedInputStream
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
    private const val MAX_CHUNK_RETRIES = 3

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
                workers.execute {
                    try {
                        require(VIDEO_ID.matches(videoId)) { "Bad videoId" }
                        resolve(videoId, force = refresh)
                        val port = Proxy.ensureStarted()
                        main.post { result.success("http://127.0.0.1:$port/yt/$videoId") }
                    } catch (e: Throwable) {
                        main.post { result.error("YT_PREPARE", describe(e), null) }
                    }
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

    private fun resolve(videoId: String, force: Boolean): Resolved {
        if (!force) cache[videoId]?.let { if (System.currentTimeMillis() < it.expiresAtMs) return it }
        val lock = resolveLocks.computeIfAbsent(videoId) { Any() }
        synchronized(lock) {
            if (!force) cache[videoId]?.let { if (System.currentTimeMillis() < it.expiresAtMs) return it }
            ensureInit()

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

            val best = info.audioStreams
                .filter { it.deliveryMethod == DeliveryMethod.PROGRESSIVE_HTTP && it.isUrl && it.content.isNotBlank() }
                .sortedWith(
                    compareByDescending<AudioStream> { maxOf(it.averageBitrate, it.bitrate) }
                        .thenByDescending { it.format == MediaFormat.M4A }
                )
                .firstOrNull()
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
                    stream(videoId, rangeHeader, method == "HEAD", out)
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
            for (attempt in 0 until MAX_CHUNK_RETRIES) {
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
                            res = resolve(videoId, force = true)
                        }
                    }
                } catch (e: IOException) {
                    conn.disconnect()
                    lastError = e
                    if (attempt == MAX_CHUNK_RETRIES - 2) res = resolve(videoId, force = true)
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
