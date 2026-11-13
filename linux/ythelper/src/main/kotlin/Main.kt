package com.alexlmp.app

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.PrintStream
import java.util.Base64

/** Sign-in needs a browser window; not on desktop yet. */
class YtLoginActivity

private fun toJson(v: Any?): Any = when (v) {
    null -> JSONObject.NULL
    is Map<*, *> -> JSONObject().also { o -> v.forEach { (k, x) -> o.put(k.toString(), toJson(x)) } }
    is Iterable<*> -> JSONArray().also { a -> v.forEach { a.put(toJson(it)) } }
    is Array<*> -> JSONArray().also { a -> v.forEach { a.put(toJson(it)) } }
    is ByteArray -> JSONObject().put("__bytes", Base64.getEncoder().encodeToString(v))
    is Number, is Boolean, is String -> v
    else -> v.toString()
}

private fun fromJson(v: Any?): Any? = when (v) {
    null, JSONObject.NULL -> null
    is JSONObject -> v.keySet().associateWith { fromJson(v.opt(it)) }
    is JSONArray -> (0 until v.length()).map { fromJson(v.opt(it)) }
    is java.math.BigDecimal -> v.toDouble()
    is java.math.BigInteger -> v.toLong()
    else -> v
}

/**
 * One JSON request per line on stdin: {"id":1,"method":"ytSearch","args":{...}}
 * One JSON reply per line on stdout: {"id":1,"ok":...} or {"id":1,"error":{...}}
 */
fun main() {
    val out = PrintStream(java.io.FileOutputStream(java.io.FileDescriptor.out), true, "UTF-8")
    System.setOut(System.err) // keep library logging off the reply channel
    val ctx = android.app.Activity()
    YtMusicBridge.init(ctx)
    Account.bind(ctx)
    val lock = Any()
    fun send(o: JSONObject) = synchronized(lock) { out.println(o.toString()) }
    out.println(JSONObject().put("ready", true).toString())

    System.`in`.bufferedReader(Charsets.UTF_8).forEachLine { line ->
        if (line.isBlank()) return@forEachLine
        val req = try { JSONObject(line) } catch (_: Exception) { return@forEachLine }
        val id = req.optLong("id")
        val call = MethodCall(req.optString("method"), fromJson(req.opt("args")))
        // Desktop sign-in: the sign-in window hands its cookies over here.
        if (call.method == "ytSaveCookies") {
            val c = call.argument<String>("cookies") ?: ""
            if (c.contains("SAPISID=")) {
                Account.saveCookies(c)
                send(JSONObject().put("id", id).put("ok", true))
            } else {
                send(JSONObject().put("id", id).put("ok", false))
            }
            return@forEachLine
        }
        try {
            YtMusicBridge.handle(call, object : MethodChannel.Result {
                override fun success(result: Any?) = send(JSONObject().put("id", id).put("ok", toJson(result)))
                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                    send(JSONObject().put("id", id).put("error",
                        JSONObject().put("code", errorCode).put("message", errorMessage ?: "")))
                override fun notImplemented() = send(JSONObject().put("id", id).put("error",
                    JSONObject().put("code", "NOT_IMPLEMENTED").put("message", "${call.method} isn't on desktop yet")))
            })
        } catch (e: Throwable) {
            send(JSONObject().put("id", id).put("error",
                JSONObject().put("code", "HELPER").put("message", "${e.javaClass.simpleName}: ${e.message}")))
        }
    }
}
