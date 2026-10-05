package app.helpermcp

import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

/** the same HTTP protocol as the PC agents: register, long-poll, result, bye */
object Net {
    fun req(base: String, method: String, path: String, token: String?, body: ByteArray? = null, ctype: String = "application/json",
            timeoutMs: Int = 25000, extra: Map<String, String> = emptyMap()): Pair<Int, ByteArray> {
        val c = URL(base.trimEnd('/') + path).openConnection() as HttpURLConnection
        try {
            c.requestMethod = method; c.connectTimeout = 15000; c.readTimeout = timeoutMs
            if (token != null) c.setRequestProperty("Authorization", "Bearer $token")
            for ((k, v) in extra) c.setRequestProperty(k, v)
            if (body != null) { c.doOutput = true; c.setRequestProperty("Content-Type", ctype); c.outputStream.use { it.write(body) } }
            val code = c.responseCode
            val data = (if (code < 400) c.inputStream else c.errorStream)?.use { it.readBytes() } ?: ByteArray(0)
            return code to data
        } finally { c.disconnect() }
    }
}

val ru: Boolean get() = Locale.getDefault().language == "ru"
fun t(r: String, e: String) = if (ru) r else e
