package app.helpermcp

import android.content.Context
import java.io.File

/** keeps the last crash so the app can show it (there is no logcat on a friend's phone) */
object Crash {
    fun install(ctx: Context) {
        val old = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try { File(ctx.filesDir, "crash.txt").writeText(java.util.Date().toString() + " " + t.name + "\n" + e.stackTraceToString().take(1500)) } catch (_: Throwable) { }
            old?.uncaughtException(t, e)
        }
    }
    fun last(ctx: Context): String? = try { File(ctx.filesDir, "crash.txt").takeIf { it.exists() }?.readText() } catch (_: Throwable) { null }
}
