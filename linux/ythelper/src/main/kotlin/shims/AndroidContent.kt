package android.content

import org.json.JSONObject
import java.io.File

/** Saved settings in ~/.config/alexlmp/<name>.json */
interface SharedPreferences {
    fun getString(key: String, def: String?): String?
    fun edit(): Editor
    interface Editor {
        fun putString(key: String, value: String?): Editor
        fun remove(key: String): Editor
        fun clear(): Editor
        fun apply()
        fun commit(): Boolean
    }
}

open class Context {
    open val applicationContext: Context get() = this
    open val cacheDir: File get() = dir("XDG_CACHE_HOME", ".cache")
    open val filesDir: File get() = dir("XDG_DATA_HOME", ".local/share")

    private fun dir(env: String, fallback: String): File {
        val base = System.getenv(env)?.takeIf { it.isNotBlank() }
            ?: File(System.getProperty("user.home"), fallback).path
        return File(base, "alexlmp").apply { mkdirs() }
    }

    open fun getSystemService(name: String): Any? = when (name) {
        POWER_SERVICE -> android.os.PowerManager()
        WIFI_SERVICE -> android.net.wifi.WifiManager()
        else -> null
    }

    open fun getSharedPreferences(name: String, @Suppress("UNUSED_PARAMETER") mode: Int): SharedPreferences {
        val base = System.getenv("XDG_CONFIG_HOME")?.takeIf { it.isNotBlank() }
            ?: File(System.getProperty("user.home"), ".config").path
        val f = File(File(base, "alexlmp").apply { mkdirs() }, "$name.json")
        return FilePrefs(f)
    }

    open fun startActivity(@Suppress("UNUSED_PARAMETER") intent: Intent) {}

    companion object {
        const val POWER_SERVICE = "power"
        const val WIFI_SERVICE = "wifi"
        const val MODE_PRIVATE = 0
    }
}

private class FilePrefs(private val file: File) : SharedPreferences {
    @Synchronized private fun read(): JSONObject =
        try { if (file.exists()) JSONObject(file.readText()) else JSONObject() } catch (_: Exception) { JSONObject() }

    override fun getString(key: String, def: String?): String? = read().optString(key, def ?: "").ifEmpty { def }

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val ops = ArrayList<(JSONObject) -> Unit>()
        private var wipe = false
        override fun putString(key: String, value: String?) = apply { ops.add { it.put(key, value) } }
        override fun remove(key: String) = apply { ops.add { it.remove(key) } }
        override fun clear() = apply { wipe = true }
        override fun apply() { commit() }
        override fun commit(): Boolean = synchronized(this@FilePrefs) {
            val o = if (wipe) JSONObject() else read()
            ops.forEach { it(o) }
            file.writeText(o.toString())
            file.setReadable(false, false); file.setReadable(true, true)
            true
        }
    }
}

class Intent(@Suppress("UNUSED_PARAMETER") ctx: Context?, @Suppress("UNUSED_PARAMETER") cls: Class<*>?)
