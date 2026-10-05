package app.helpermcp

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import org.json.JSONObject
import java.io.File

/** checks the relay for a newer APK and installs it (the system asks the user to confirm) */
object Update {
    @Volatile var available: JSONObject? = null
    @Volatile var progress = ""          // "" | "downloading 40%" | error text
    private var lastCheck = 0L

    fun check(relay: String, force: Boolean = false) {
        if (!force && System.currentTimeMillis() - lastCheck < 30 * 60 * 1000) return
        lastCheck = System.currentTimeMillis()
        Thread {
            try {
                val (st, b) = Net.req(relay, "GET", "/apk/version", null, timeoutMs = 8000)
                if (st == 200) { val j = JSONObject(String(b)); available = if (j.optInt("versionCode") > BuildConfig.VERSION_CODE) j else null }
            } catch (_: Throwable) { }
        }.start()
    }

    fun install(ctx: Context, relay: String) {
        if (progress.startsWith("downloading")) return
        progress = "downloading 0%"
        Thread {
            try {
                val c = java.net.URL(relay.trimEnd('/') + "/apk").openConnection() as java.net.HttpURLConnection
                c.connectTimeout = 15000; c.readTimeout = 30000
                val total = c.contentLengthLong
                val file = File(ctx.cacheDir, "update.apk")
                c.inputStream.use { ins -> file.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024); var done = 0L
                    while (true) { val n = ins.read(buf); if (n < 0) break; out.write(buf, 0, n); done += n; if (total > 0) progress = "downloading ${done * 100 / total}%" }
                } }
                val pi = ctx.packageManager.packageInstaller
                val id = pi.createSession(PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL))
                pi.openSession(id).use { s ->
                    file.inputStream().use { ins -> s.openWrite("app", 0, file.length()).use { out -> ins.copyTo(out); s.fsync(out) } }
                    val pending = PendingIntent.getBroadcast(ctx, id, Intent(ctx, InstallReceiver::class.java), PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                    s.commit(pending.intentSender)
                }
                progress = ""
            } catch (e: Throwable) { progress = "error: ${e.message}" }
        }.start()
    }
}

class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val i = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java) else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                i?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK); if (i != null) ctx.startActivity(i)
            }
            PackageInstaller.STATUS_SUCCESS -> Update.available = null
            else -> Update.progress = "error: " + (intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "install failed")
        }
    }
}
