package io.flutter.plugin.common

class MethodCall(val method: String, val arguments: Any?) {
    @Suppress("UNCHECKED_CAST")
    fun <T> argument(key: String): T? = (arguments as? Map<String, Any?>)?.get(key) as T?
    fun hasArgument(key: String): Boolean = (arguments as? Map<*, *>)?.containsKey(key) == true
}

class MethodChannel {
    interface Result {
        fun success(result: Any?)
        fun error(errorCode: String, errorMessage: String?, errorDetails: Any?)
        fun notImplemented()
    }
}
