package android.os

import java.util.concurrent.Executors

/** Desktop stand-in: "main thread" = one background thread that sends replies. */
class Looper private constructor() {
    companion object {
        private val MAIN = Looper()
        @JvmStatic fun getMainLooper(): Looper = MAIN
    }
}

class Handler(@Suppress("UNUSED_PARAMETER") looper: Looper) {
    fun post(r: Runnable): Boolean {
        EXEC.execute(r)
        return true
    }
    companion object {
        private val EXEC = Executors.newSingleThreadExecutor { Thread(it, "main").apply { isDaemon = true } }
    }
}

class Bundle

class PowerManager {
    class WakeLock {
        var isHeld = false
            private set
        fun setReferenceCounted(@Suppress("UNUSED_PARAMETER") v: Boolean) {}
        fun acquire(@Suppress("UNUSED_PARAMETER") timeout: Long) { isHeld = true }
        fun acquire() { isHeld = true }
        fun release() { isHeld = false }
    }
    fun newWakeLock(@Suppress("UNUSED_PARAMETER") flags: Int, @Suppress("UNUSED_PARAMETER") tag: String) = WakeLock()
    companion object { const val PARTIAL_WAKE_LOCK = 1 }
}
