package android.net

import java.net.URLDecoder
import java.net.URLEncoder

/** Just enough of android.net.Uri for the bridge: query parameters + encode. */
class Uri private constructor(private val raw: String) {
    private val params: Map<String, String> by lazy {
        val q = raw.substringAfter('?', "").substringBefore('#')
        if (q.isEmpty()) emptyMap() else q.split('&').filter { it.isNotEmpty() }.associate {
            val k = it.substringBefore('=')
            val v = it.substringAfter('=', "")
            dec(k) to dec(v)
        }
    }
    fun getQueryParameter(key: String): String? = params[key]
    override fun toString() = raw

    companion object {
        private fun dec(s: String) = try { URLDecoder.decode(s, "UTF-8") } catch (_: Exception) { s }
        @JvmStatic fun parse(s: String): Uri = Uri(s)
        @JvmStatic fun encode(s: String?): String =
            URLEncoder.encode(s ?: "", "UTF-8").replace("+", "%20").replace("%7E", "~")
    }
}
