package android.webkit

class CookieManager private constructor() {
    fun removeAllCookies(@Suppress("UNUSED_PARAMETER") cb: Any?) {}
    fun flush() {}
    companion object {
        private val I = CookieManager()
        @JvmStatic fun getInstance(): CookieManager = I
    }
}

open class WebView
open class WebViewClient
