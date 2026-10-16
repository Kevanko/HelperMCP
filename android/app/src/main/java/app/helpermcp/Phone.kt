package app.helpermcp

import android.app.ActivityManager
import android.app.AppOpsManager
import android.app.admin.DevicePolicyManager
import android.app.usage.UsageStatsManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/** Files, system state and utilities for the phone: the same tools the PC agents have (tree, find, read_file, edit_file, push_file, fetch_file, system, util), over the shared storage. */
class Phone(private val ctx: Context, private val relay: () -> String, private val token: () -> String, private val launch: (String) -> Unit) {
    private val root: File = Environment.getExternalStorageDirectory()   // /storage/emulated/0 (= /sdcard)
    private val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US)
    private val main = Handler(Looper.getMainLooper())
    private val SKIP = setOf(".git", "node_modules", ".thumbnails", ".cache")

    fun filesOk() = Environment.isExternalStorageManager()
    fun usageOk(): Boolean = try { (ctx.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager).unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName) == AppOpsManager.MODE_ALLOWED } catch (_: Throwable) { false }

    // ------------------------------------------------------------------------------------------ files
    /** "~", "", "/sdcard/x" and relative paths all mean the shared storage; without "All files access" only the app's own folders open (the permission screen is opened for the friend) */
    private fun file(p: String?): File {
        var s = (p ?: "").trim()
        s = when {
            s.isEmpty() || s == "~" || s == "." -> root.path
            s.startsWith("~/") -> root.path + s.substring(1)
            s == "/sdcard" || s.startsWith("/sdcard/") -> root.path + s.substring(7)
            s.startsWith("/") -> s
            else -> File(root, s).path
        }
        val f = File(s)
        val own = listOfNotNull(ctx.filesDir.parent, ctx.externalCacheDir?.parent).any { f.path.startsWith(it) } || f.path.startsWith(ctx.cacheDir.path)
        if (!filesOk() && !own) {
            try { openSettings("files") } catch (_: Throwable) { }
            throw RuntimeException("The friend has not allowed file access yet. I opened the permission screen on the phone: ask them to switch on \"Allow access to manage all files\" for HelperMCP (or tap \"Allow file access\" in the app), then repeat this call.")
        }
        return f
    }

    private fun human(n: Long): String { var v = n.toDouble(); for (u in listOf("B", "K", "M", "G")) { if (v < 1024 || u == "G") return if (u == "B") "${v.toLong()}B" else "%.1f%s".format(Locale.US, v, u); v /= 1024 }; return "$n" }
    private fun glob(g: String) = Regex(g.lowercase().map { when (it) { '*' -> ".*"; '?' -> "."; else -> Regex.escape(it.toString()) } }.joinToString(""))
    private fun ok(text: String) = JSONObject().put("text", text)

    fun tree(a: JSONObject): JSONObject {
        val start = file(a.optString("path")); val depth = a.optInt("depth", 2).coerceIn(1, 6); val cap = a.optInt("max", 300)
        val rx = a.optString("pattern").takeIf { it.isNotBlank() }?.let { glob(it) }
        val out = ArrayList<String>(); out.add(start.path); var more = 0
        fun walk(d: File, lvl: Int) {
            val ents = d.listFiles()
            if (ents == null) { out.add("  ".repeat(lvl) + "[cannot open]"); return }
            for (e in ents.sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))) {
                val isd = e.isDirectory
                if (!isd && rx != null && !rx.matches(e.name.lowercase())) continue
                if (out.size > cap) { more++; continue }
                if (isd) { out.add("  ".repeat(lvl) + e.name + "/  (" + (e.list()?.size ?: "?") + ")"); if (lvl < depth && e.name !in SKIP) walk(e, lvl + 1) }
                else out.add("  ".repeat(lvl) + e.name + "  " + human(e.length()))
            }
        }
        walk(start, 1)
        if (more > 0) out.add("... $more more (raise max, lower depth or use find)")
        return ok(out.joinToString("\n"))
    }

    fun find(a: JSONObject): JSONObject {
        val start = file(a.optString("path")); val name = glob(a.optString("name").ifBlank { "*" }); val cap = a.optInt("max", 100); val maxd = a.optInt("depth", 20)
        val rx = a.optString("text").takeIf { it.isNotBlank() }?.let { Regex(it, RegexOption.IGNORE_CASE) }
        val out = ArrayList<String>(); val t0 = SystemClock.uptimeMillis(); val baseDepth = start.path.count { it == '/' }
        for (f in start.walkTopDown().onEnter { it.name !in SKIP && it.path.count { c -> c == '/' } - baseDepth < maxd }) {
            if (SystemClock.uptimeMillis() - t0 > 25_000) return ok(out.joinToString("\n") + "\n... stopped after 25 s (narrow the path)")
            if (!f.isFile || !name.matches(f.name.lowercase())) continue
            if (rx == null) out.add(f.path + "  " + human(f.length()))
            else {
                if (f.length() > 5_000_000) continue
                val raw = try { f.readBytes() } catch (_: Throwable) { continue }
                if (raw.take(4096).any { it == 0.toByte() }) continue
                var i = 0
                for (line in decode(raw).first.lineSequence()) { i++; if (rx.containsMatchIn(line)) { out.add("${f.path}:$i: ${line.trim().take(160)}"); if (out.size >= cap) break } }
            }
            if (out.size >= cap) return ok(out.joinToString("\n") + "\n... stopped at $cap results (raise max or narrow path / name)")
        }
        return ok(out.joinToString("\n").ifEmpty { "nothing found" })
    }

    /** (text, charset, bom) so an edit writes the file back the way it was */
    private fun decode(raw: ByteArray): Triple<String, java.nio.charset.Charset, ByteArray> {
        if (raw.size >= 3 && raw[0] == 0xEF.toByte() && raw[1] == 0xBB.toByte() && raw[2] == 0xBF.toByte()) return Triple(String(raw, 3, raw.size - 3, Charsets.UTF_8), Charsets.UTF_8, raw.copyOf(3))
        if (raw.size >= 2 && raw[0] == 0xFF.toByte() && raw[1] == 0xFE.toByte()) return Triple(String(raw, 2, raw.size - 2, Charsets.UTF_16LE), Charsets.UTF_16LE, raw.copyOf(2))
        val dec = Charsets.UTF_8.newDecoder()
        return try { Triple(dec.decode(java.nio.ByteBuffer.wrap(raw)).toString(), Charsets.UTF_8, ByteArray(0)) } catch (_: Throwable) { Triple(String(raw, Charsets.ISO_8859_1), Charsets.ISO_8859_1, ByteArray(0)) }
    }

    fun listDir(a: JSONObject): JSONObject {
        val d = file(a.optString("path")); val ents = d.listFiles() ?: throw RuntimeException("cannot open ${d.path}")
        return ok(ents.sortedBy { it.name.lowercase() }.take(500).joinToString("\n") { (if (it.isDirectory) "d " else "- ") + "%12d ".format(it.length()) + fmt.format(Date(it.lastModified())) + " " + it.name })
    }

    fun readFile(a: JSONObject): Any {
        val f = file(a.optString("path"))
        if (!f.isFile) throw RuntimeException("not a file: ${f.path}")
        if (f.name.lowercase().let { it.endsWith(".jpg") || it.endsWith(".jpeg") || it.endsWith(".png") || it.endsWith(".webp") || it.endsWith(".gif") || it.endsWith(".bmp") }) {   // an image comes back as an image, scaled down
            val cap = a.optInt("max_width", 1600).coerceIn(200, 4000)
            val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeFile(f.path, o)
            val w0 = o.outWidth; val h0 = o.outHeight; var ss = 1; while (w0 / ss > cap * 2) ss *= 2
            val bmp = BitmapFactory.decodeFile(f.path, BitmapFactory.Options().apply { inSampleSize = ss }) ?: throw RuntimeException("not a picture")
            val out = if (bmp.width > cap) Bitmap.createScaledBitmap(bmp, cap, bmp.height * cap / bmp.width, true) else bmp
            val bo = ByteArrayOutputStream(); out.compress(Bitmap.CompressFormat.JPEG, a.optInt("quality", 80).coerceIn(20, 95), bo)
            return Shot(bo.toByteArray(), JSONObject().put("width", out.width).put("height", out.height).put("text", "${w0}x$h0 image"))
        }
        if (a.has("offset") || a.has("lines") || a.has("tail")) {
            val lines = decode(f.readBytes()).first.lines(); val n = lines.size
            val (start, cnt) = if (a.optInt("tail") > 0) maxOf(0, n - a.optInt("tail")) to a.optInt("tail") else maxOf(0, a.optInt("offset", 1) - 1) to a.optInt("lines", 200)
            val part = lines.drop(start).take(cnt)
            return ok(part.mapIndexed { i, s -> "${start + i + 1}\t$s" }.joinToString("\n") + "\n[lines ${start + 1}-${start + part.size} of $n]")
        }
        val max = a.optInt("max_bytes", 200_000)
        return ok(f.inputStream().use { s -> val b = ByteArray(max); val k = s.read(b).coerceAtLeast(0); String(b, 0, k, Charsets.UTF_8) })
    }

    fun writeFile(a: JSONObject): JSONObject {
        val f = file(a.optString("path")); f.parentFile?.mkdirs()
        val data = if (a.optBoolean("base64")) android.util.Base64.decode(a.getString("content"), android.util.Base64.DEFAULT) else a.getString("content").toByteArray()
        FileOutputStream(f, a.optBoolean("append")).use { it.write(data) }
        return ok("written")
    }

    fun editFile(a: JSONObject): JSONObject {
        val f = file(a.optString("path")); val (text, cs, bom) = decode(f.readBytes())
        var old = a.getString("old"); var new = a.optString("new", "")
        if (!text.contains(old) && text.contains("\r\n") && !old.contains("\r\n")) { old = old.replace("\n", "\r\n"); new = new.replace("\n", "\r\n") }   // the AI writes \n, the file has CRLF
        val n = if (old.isEmpty()) 0 else text.split(old).size - 1
        if (n == 0) throw RuntimeException("old text not found (it must match exactly, spaces and line breaks included; read_file with offset/lines to copy it)")
        if (n > 1 && !a.optBoolean("all")) throw RuntimeException("old text found $n times: add surrounding lines to make it unique, or all=true")
        f.writeBytes(bom + text.replace(old, new).toByteArray(cs))
        return ok("replaced $n")
    }

    /** operator -> phone: download a link (a relay link from the viewer upload, or any http link) to path */
    fun pushFile(a: JSONObject): JSONObject {
        val f = file(a.getString("path")); f.parentFile?.mkdirs(); val part = File(f.path + ".part"); var n = 0L
        val c = URL(a.getString("url")).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 15000; c.readTimeout = 120000; c.setRequestProperty("User-Agent", "helpermcp")
            if (c.responseCode >= 400) throw RuntimeException("download failed: HTTP ${c.responseCode}")
            c.inputStream.use { i -> FileOutputStream(part).use { o -> val b = ByteArray(1 shl 16); while (true) { val k = i.read(b); if (k < 0) break; o.write(b, 0, k); n += k } } }
        } finally { c.disconnect() }
        f.delete(); if (!part.renameTo(f)) throw RuntimeException("could not save ${f.path}")
        return ok("saved ${f.path} (${human(n)})")
    }

    /** phone -> relay, streamed from disk; a folder travels as one zip */
    fun fetchFile(a: JSONObject): JSONObject {
        var f = file(a.getString("path")); var tmp: File? = null
        if (f.isDirectory) { tmp = File(ctx.cacheDir, f.name + ".zip"); zipDir(f, tmp); f = tmp }
        if (!f.isFile) throw RuntimeException("no such file: ${f.path}")
        try {
            val c = URL(relay().trimEnd('/') + "/a/file?name=" + java.net.URLEncoder.encode(f.name, "UTF-8")).openConnection() as HttpURLConnection
            try {
                c.requestMethod = "POST"; c.doOutput = true; c.connectTimeout = 15000; c.readTimeout = 600000
                c.setRequestProperty("Authorization", "Bearer " + token()); c.setRequestProperty("Content-Type", "application/octet-stream"); c.setFixedLengthStreamingMode(f.length())
                f.inputStream().use { i -> c.outputStream.use { i.copyTo(it, 1 shl 16) } }
                val d = JSONObject(String((if (c.responseCode < 400) c.inputStream else c.errorStream).readBytes()))
                if (c.responseCode >= 400) throw RuntimeException(d.optString("error", "upload failed: HTTP ${c.responseCode}"))
                return ok("${d.getString("url")}  (${d.optLong("size")} bytes, link valid 24 h)")
            } finally { c.disconnect() }
        } finally { tmp?.delete() }
    }

    private fun zipDir(src: File, dest: File) {
        ZipOutputStream(BufferedOutputStream(FileOutputStream(dest))).use { z ->
            for (f in src.walkTopDown().filter { it.isFile }) try { z.putNextEntry(ZipEntry(src.name + "/" + f.relativeTo(src).path.replace('\\', '/'))); f.inputStream().use { it.copyTo(z) }; z.closeEntry() } catch (_: Throwable) { }
        }
    }


    /** make, copy, move, rename, delete, stat and look inside a file without downloading it (the viewer's Files tab) */
    fun fsop(a: JSONObject): Any {
        val op = a.getString("op"); val p = file(a.getString("path"))
        return when (op) {
            "mkdir" -> { p.mkdirs(); ok("created folder ${p.path}") }
            "newfile" -> { if (p.exists()) throw RuntimeException("already exists: ${p.path}"); p.parentFile?.mkdirs(); p.createNewFile(); ok("created file ${p.path}") }
            "copy", "move" -> {
                var d = file(a.getString("dest")); if (d.isDirectory) d = File(d, p.name)
                if (d.absolutePath == p.absolutePath) throw RuntimeException("source and destination are the same")
                if (d.exists() && !a.optBoolean("overwrite")) throw RuntimeException("already exists: ${d.path} (overwrite:true replaces it)")
                if (d.exists()) d.deleteRecursively()
                if (op == "copy") p.copyRecursively(d) else if (!p.renameTo(d)) { p.copyRecursively(d); p.deleteRecursively() }
                ok("${if (op == "copy") "copied" else "moved"} to ${d.path}")
            }
            "rename" -> { val n = a.optString("name"); if (n.isBlank() || n.contains('/')) throw RuntimeException("bad name"); if (!p.renameTo(File(p.parentFile, n))) throw RuntimeException("could not rename"); ok("renamed to $n") }
            "delete" -> { if (!p.exists()) throw RuntimeException("not found: ${p.path}"); if (!(if (p.isDirectory) p.deleteRecursively() else p.delete())) throw RuntimeException("could not delete ${p.path}"); ok("deleted: ${p.path}") }
            "stat" -> ok(JSONObject().put("path", p.path).put("dir", p.isDirectory).put("size", if (p.isDirectory) 0 else p.length()).put("modified", fmt.format(Date(p.lastModified()))).toString())
            "preview" -> preview(p, a)
            else -> throw RuntimeException("unknown op '$op' (mkdir, newfile, copy, move, rename, delete, stat, preview)")
        }
    }

    private fun preview(f: File, a: JSONObject): Any {
        if (f.isDirectory) throw RuntimeException("that is a folder")
        val n = f.name.lowercase()
        if (n.endsWith(".jpg") || n.endsWith(".jpeg") || n.endsWith(".png") || n.endsWith(".webp") || n.endsWith(".gif") || n.endsWith(".bmp")) return readFile(JSONObject().put("path", f.path).put("max_width", 1100).put("quality", 72))
        val mx = a.optInt("max", 65536); val o = JSONObject().put("size", f.length()).put("modified", fmt.format(Date(f.lastModified()))).put("truncated", f.length() > mx)
        if (n.endsWith(".zip") || n.endsWith(".apk") || n.endsWith(".jar") || n.endsWith(".docx") || n.endsWith(".xlsx")) {
            java.util.zip.ZipFile(f).use { z -> val arr = JSONArray(); var c = 0; for (e in z.entries()) { if (c++ < 300) arr.put(JSONArray().put(e.name).put(e.size)) }; o.put("kind", "archive").put("entries", arr).put("count", c) }
            return ok(o.toString())
        }
        val buf = ByteArray(mx); val k = f.inputStream().use { it.read(buf).coerceAtLeast(0) }; val b = buf.copyOf(k)
        val bom16 = k >= 2 && ((b[0] == 0xFF.toByte() && b[1] == 0xFE.toByte()) || (b[0] == 0xFE.toByte() && b[1] == 0xFF.toByte()))
        if (!bom16 && b.take(4096).any { it == 0.toByte() }) {
            val sb = StringBuilder(); var r = 0
            while (r < minOf(512, k)) { val e = minOf(r + 16, k); sb.append("%08x  %-47s  %s\n".format(r, (r until e).joinToString(" ") { "%02x".format(b[it]) }, (r until e).map { val c = b[it].toInt() and 255; if (c in 32..126) c.toChar() else '.' }.joinToString(""))); r += 16 }
            o.put("kind", "binary").put("text", sb.toString())
        } else o.put("kind", "text").put("text", String(b, if (bom16) Charsets.UTF_16 else Charsets.UTF_8).trimStart('\uFEFF'))
        return ok(o.toString())
    }

    // ------------------------------------------------------------------------------------------ system state
    private fun label(pkg: String): String = try { ctx.packageManager.getApplicationLabel(ctx.packageManager.getApplicationInfo(pkg, 0)).toString() } catch (_: Throwable) { pkg }
    private fun mem(): ActivityManager.MemoryInfo = ActivityManager.MemoryInfo().also { (ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(it) }
    private fun batt(): Intent? = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    private fun battText(): String {
        val b = batt() ?: return "?"; val lvl = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) * 100 / b.getIntExtra(BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)
        val plug = when (b.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)) { 0 -> "on battery"; BatteryManager.BATTERY_PLUGGED_AC -> "charging (AC)"; BatteryManager.BATTERY_PLUGGED_USB -> "charging (USB)"; else -> "charging (wireless)" }
        return "$lvl%%, $plug, %.1f C".format(Locale.US, b.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) / 10.0)
    }
    private fun ago(ms: Long): String { val m = ms / 60000; return if (m < 1) "now" else if (m < 60) "${m}m ago" else if (m < 1440) "${m / 60}h ago" else "${m / 1440}d ago" }
    private fun netKind(c: NetworkCapabilities?) = listOf(NetworkCapabilities.TRANSPORT_WIFI to "Wi-Fi", NetworkCapabilities.TRANSPORT_CELLULAR to "mobile data", NetworkCapabilities.TRANSPORT_ETHERNET to "ethernet", NetworkCapabilities.TRANSPORT_VPN to "VPN", NetworkCapabilities.TRANSPORT_BLUETOOTH to "bluetooth").filter { c?.hasTransport(it.first) == true }.joinToString("+") { it.second }.ifEmpty { "none" }

    fun system(a: JSONObject): JSONObject {
        val secs = a.optJSONArray("sections")?.let { j -> (0 until j.length()).map { j.getString(it) } } ?: listOf("overview", "disks", "network", "processes")
        val top = a.optInt("top", 15).coerceIn(3, 60); val sb = StringBuilder()
        for (s in secs) {
            sb.append("== ").append(s).append('\n')
            sb.append(try { when (s) {
                "overview" -> overview()
                "disks" -> disks()
                "network" -> network()
                "processes" -> recent(top)
                "apps" -> apps(top.coerceAtLeast(30), null, false)
                "services", "startup" -> privileged()
                else -> "not available on a phone (use: overview, disks, network, processes, apps, services)"
            } } catch (e: Throwable) { "error: ${e.message}" }.trimEnd()).append('\n')
        }
        return ok(sb.toString().trimEnd())
    }

    private fun overview(): String {
        val m = mem(); val dm = ctx.resources.displayMetrics; val pm = ctx.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager; val km = ctx.getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        return "${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}), security patch ${Build.VERSION.SECURITY_PATCH}\n" +
            "battery ${battText()}\nRAM ${human(m.totalMem - m.availMem)} used of ${human(m.totalMem)} (${100 - m.availMem * 100 / m.totalMem}%)${if (m.lowMemory) ", LOW MEMORY" else ""}\n" +
            "uptime ${ago(SystemClock.elapsedRealtime()).removeSuffix(" ago")}, screen ${dm.widthPixels}x${dm.heightPixels} @${dm.densityDpi}dpi, ${if (pm.isInteractive) "on" else "off"}${if (km.isKeyguardLocked) ", locked" else ""}\n" +
            "foreground app: ${HelperService.inst?.rootInActiveWindow?.packageName ?: "?"}\n" +
            "access: files ${if (filesOk()) "allowed" else "NOT allowed"}, usage stats ${if (usageOk()) "allowed" else "NOT allowed (needed for recent apps)"}"
    }

    private fun disks(): String {
        fun line(n: String, f: File): String { val s = StatFs(f.path); val tot = s.totalBytes; val free = s.availableBytes; return "$n  ${human(tot - free)} used of ${human(tot)}, ${human(free)} free (${100 - free * 100 / tot}%)  ${f.path}" }
        val out = ArrayList<String>(); out.add(line("shared storage", root)); out.add(line("app data    ", Environment.getDataDirectory()))
        ctx.getExternalFilesDirs(null).drop(1).filterNotNull().forEach { out.add(line("sd card     ", it)) }
        return out.joinToString("\n")
    }

    private fun network(): String {
        val cm = ctx.getSystemService(ConnectivityManager::class.java); val n = cm.activeNetwork ?: return "no network"
        val c = cm.getNetworkCapabilities(n); val lp = cm.getLinkProperties(n); val sb = StringBuilder()
        sb.append(netKind(c)).append("  down ${(c?.linkDownstreamBandwidthKbps ?: 0) / 1000} / up ${(c?.linkUpstreamBandwidthKbps ?: 0) / 1000} Mbit/s")
        c?.signalStrength?.takeIf { it != Int.MIN_VALUE }?.let { sb.append("  signal $it") }
        sb.append("  internet=${c?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true}  metered=${c?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true}\n")
        if (lp != null) sb.append("${lp.interfaceName}  ${lp.linkAddresses.joinToString { it.address.hostAddress ?: "" }}\ngateway ${lp.routes.firstOrNull { it.isDefaultRoute }?.gateway?.hostAddress}  dns ${lp.dnsServers.joinToString { it.hostAddress ?: "" }}  private-dns ${if (lp.isPrivateDnsActive) lp.privateDnsServerName ?: "on" else "off"}")
        if (cm.allNetworks.any { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true }) sb.append("\nVPN is ON")
        return sb.toString()
    }

    /** Android hides other apps' CPU and memory; what it does show (with usage access) is which apps were used and for how long */
    private fun recentRows(): List<Triple<String, String, android.app.usage.UsageStats>> {
        val usm = ctx.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager; val now = System.currentTimeMillis()
        return usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, now - 86_400_000L, now).filter { it.lastTimeUsed > now - 86_400_000L && it.packageName != ctx.packageName }
            .sortedByDescending { it.lastTimeUsed }.map { Triple(label(it.packageName), it.packageName, it) }
    }
    private fun recent(top: Int): String {
        if (!usageOk()) return "Usage access is not allowed, so Android hides which apps run. Ask the friend to tap \"Allow usage access\" in the app (or util {op:\"open\", name:\"settings:usage\"} opens that screen). Until then only the foreground app is known: ${HelperService.inst?.rootInActiveWindow?.packageName ?: "?"}"
        val now = System.currentTimeMillis()
        return "apps used in the last 24 h (most recent first; Android does not show other apps' CPU / RAM):\n" + recentRows().take(top).joinToString("\n") { (l, p, u) -> "%-9s fg %-5s %s (%s)".format(ago(now - u.lastTimeUsed), "${u.totalTimeInForeground / 60000}m", l, p) }
    }

    private fun enabledPkgs(key: String) = (Settings.Secure.getString(ctx.contentResolver, key) ?: "").split(':').filter { it.contains('/') }.map { it.substringBefore('/') }.toSet()
    private fun admins(): Set<String> = (ctx.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager).activeAdmins?.map { it.packageName }?.toSet() ?: emptySet()

    /** the things spyware and remote-control scams rely on: accessibility services, device admins, notification access */
    private fun privileged(): String {
        val acc = enabledPkgs(Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES); val nl = enabledPkgs("enabled_notification_listeners"); val ad = admins()
        fun l(t: String, s: Set<String>) = "$t: " + (s.joinToString(", ") { label(it) + " (" + it + ")" }.ifEmpty { "none" })
        return listOf(l("accessibility services on", acc), l("device administrators", ad), l("notification access", nl)).joinToString("\n")
    }

    private fun isSys(p: android.content.pm.PackageInfo) = ((p.applicationInfo?.flags ?: 0) and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
    private val stores = setOf("com.android.vending", "com.sec.android.app.samsungapps", "com.huawei.appmarket", "com.xiaomi.mipicks", "com.amazon.venezia", "com.heytap.market", "com.vivo.appstore")
    /** installed apps, newest first; ! marks an app that did not come from a store or holds a risky power (accessibility, device admin, notification access, draw over other apps) */
    fun apps(top: Int, filter: String?, system: Boolean): String {
        val pm = ctx.packageManager; val acc = enabledPkgs(Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES); val nl = enabledPkgs("enabled_notification_listeners"); val ad = admins()
        val ops = ctx.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager; val fmtD = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        @Suppress("DEPRECATION") val all = pm.getInstalledPackages(0)
        val rows = all.filter { p ->
            val sys = isSys(p)
            val l = if (filter != null) label(p.packageName) else ""
            if (filter != null) l.contains(filter, true) || p.packageName.contains(filter, true) else system || !sys
        }.sortedByDescending { it.firstInstallTime }
        val out = rows.take(top).map { p ->
            val inst = try { pm.getInstallSourceInfo(p.packageName).installingPackageName } catch (_: Throwable) { null }
            val flags = ArrayList<String>()
            if (p.packageName in acc) flags.add("ACCESSIBILITY"); if (p.packageName in ad) flags.add("DEVICE-ADMIN"); if (p.packageName in nl) flags.add("reads notifications")
            val ov = try { ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW, p.applicationInfo!!.uid, p.packageName) == AppOpsManager.MODE_ALLOWED } catch (_: Throwable) { false }
            if (ov) flags.add("draws over apps")
            if (p.applicationInfo?.enabled == false) flags.add("disabled")
            val bad = (inst !in stores && !isSys(p)) || flags.any { it == it.uppercase() }
            (if (bad) "! " else "  ") + "${label(p.packageName)} (${p.packageName}) ${p.versionName ?: ""}  from ${inst ?: "unknown source"}  installed ${fmtD.format(Date(p.firstInstallTime))}" + (if (flags.isEmpty()) "" else "  [" + flags.joinToString(", ") + "]")
        }
        return (if (out.isEmpty()) "no apps match" else out.joinToString("\n")) + (if (rows.size > top) "\n... ${rows.size - top} more (use util {op:\"apps\", name:\"...\"} to search)" else "") + "\n(! = not from a store, or accessibility / device admin power)"
    }

    /** the compact snapshot for the live System panel (an S frame): RAM, battery, recently used apps */
    private var snapAt = 0L; private var snapRows: JSONArray = JSONArray()
    fun snap(): String {
        val m = mem()
        if (SystemClock.uptimeMillis() - snapAt > 10_000) {
            snapAt = SystemClock.uptimeMillis(); val rows = JSONArray(); val now = System.currentTimeMillis()
            if (usageOk()) try { for ((l, p, u) in recentRows().take(12)) rows.put(JSONArray().put(0).put(l).put(-1).put(0).put("fg ${u.totalTimeInForeground / 60000}m, ${ago(now - u.lastTimeUsed)}").put(p).put("")) } catch (_: Throwable) { }
            snapRows = rows
        }
        val st = StatFs(root.path); val cm = ctx.getSystemService(ConnectivityManager::class.java)
        return JSONObject().put("cpu", -1).put("mem", (100 - m.availMem * 100 / m.totalMem).toInt()).put("ramFree", m.availMem).put("ramTotal", m.totalMem).put("n", 0)
            .put("x", "battery ${battText()} | ${netKind(cm.getNetworkCapabilities(cm.activeNetwork))} | storage ${human(st.availableBytes)} free").put("p", snapRows).toString()
    }

    // ------------------------------------------------------------------------------------------ settings screens, utilities
    private val SCREENS = mapOf("files" to Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, "usage" to Settings.ACTION_USAGE_ACCESS_SETTINGS, "accessibility" to Settings.ACTION_ACCESSIBILITY_SETTINGS,
        "apps" to Settings.ACTION_MANAGE_ALL_APPLICATIONS_SETTINGS, "battery" to Settings.ACTION_BATTERY_SAVER_SETTINGS, "wifi" to Settings.ACTION_WIFI_SETTINGS, "storage" to Settings.ACTION_INTERNAL_STORAGE_SETTINGS,
        "security" to Settings.ACTION_SECURITY_SETTINGS, "admin" to "android.settings.DEVICE_ADMIN_SETTINGS", "notifications" to Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS, "overlay" to Settings.ACTION_MANAGE_OVERLAY_PERMISSION, "settings" to Settings.ACTION_SETTINGS)
    fun openSettings(name: String) {
        val n = name.removePrefix("settings:").trim()
        val i = if (n.startsWith("app:")) Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + n.substring(4)))
        else Intent(SCREENS[n] ?: throw RuntimeException("unknown screen '$n'. Available: ${SCREENS.keys.joinToString()}, app:<package>"))
        if (n == "files") i.data = Uri.parse("package:" + ctx.packageName)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK); ctx.startActivity(i)
    }

    fun util(a: JSONObject): JSONObject {
        val name = a.optString("name"); val value = a.optString("value")
        return when (val op = a.getString("op")) {
            "apps" -> ok(apps(a.optInt("top", 40), name.ifBlank { null }, name.isNotBlank()))
            "kill" -> { (ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).killBackgroundProcesses(name); ok("asked Android to stop the background processes of $name (an app in the foreground is not touched: open util {op:\"open\", name:\"settings:app:$name\"} and tap Force stop)") }
            "uninstall" -> { openSettings("app:$name"); ok("opened the app page of $name: tap Uninstall (or Disable) there; the friend confirms the system dialog") }
            "open" -> { val w = name.ifBlank { a.optString("url", a.optString("path")) }
                if (w.startsWith("settings:")) openSettings(w) else launch(w); ok("opened $w") }
            "clipboard_set" -> { val l = CountDownLatch(1); main.post { try { (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("helper", value)) } finally { l.countDown() } }; l.await(3, TimeUnit.SECONDS); ok("copied") }
            "clipboard_get" -> { var s: String? = null; val l = CountDownLatch(1); main.post { try { s = (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip?.getItemAt(0)?.text?.toString() } finally { l.countDown() } }; l.await(3, TimeUnit.SECONDS)
                ok(s ?: "(empty, or Android blocks reading the clipboard while HelperMCP is in the background: ask the friend to copy again and read right away)") }
            "net_test" -> { val host = a.optString("host", name); val port = a.optInt("port", 443); val t0 = SystemClock.uptimeMillis()
                val ips = InetAddress.getAllByName(host); val t1 = SystemClock.uptimeMillis()
                val tcp = try { Socket().use { it.connect(InetSocketAddress(ips[0], port), 5000) }; "open (${SystemClock.uptimeMillis() - t1} ms)" } catch (e: Throwable) { "FAILED: ${e.message}" }
                ok("$host -> ${ips.joinToString { it.hostAddress ?: "" }} (DNS ${t1 - t0} ms); tcp $port $tcp") }
            "download" -> { val r = pushFile(JSONObject().put("url", a.getString("url")).put("path", a.getString("path"))); r }
            "zip" -> { val src = file(a.getString("path")); val dest = file(a.optString("dest", src.path + ".zip")); zipDir(if (src.isDirectory) src else throw RuntimeException("zip works on folders"), dest); ok("zipped to ${dest.path} (${human(dest.length())})") }
            "unzip" -> { val src = file(a.getString("path")); val dest = file(a.optString("dest", src.parent ?: root.path)); dest.mkdirs(); var n = 0
                ZipInputStream(src.inputStream().buffered()).use { z -> while (true) { val e = z.nextEntry ?: break; val t = File(dest, e.name); if (!t.canonicalPath.startsWith(dest.canonicalPath)) continue
                    if (e.isDirectory) t.mkdirs() else { t.parentFile?.mkdirs(); FileOutputStream(t).use { z.copyTo(it) }; n++ } } }
                ok("unzipped $n files to ${dest.path}") }
            else -> throw RuntimeException("util op '$op' is not available on Android. Available: apps, kill, uninstall, open (url, app, or settings:<screen>), clipboard_get, clipboard_set, net_test, download, zip, unzip.")
        }
    }
}
