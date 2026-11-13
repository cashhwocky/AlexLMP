package android.net.wifi

class WifiManager {
    class WifiLock {
        var isHeld = false
            private set
        fun setReferenceCounted(@Suppress("UNUSED_PARAMETER") v: Boolean) {}
        fun acquire() { isHeld = true }
        fun release() { isHeld = false }
    }
    fun createWifiLock(@Suppress("UNUSED_PARAMETER") mode: Int, @Suppress("UNUSED_PARAMETER") tag: String) = WifiLock()
    companion object { const val WIFI_MODE_FULL_HIGH_PERF = 3 }
}
