package app.helpermcp

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL

/** The live picture of the phone for the viewer: H.264 video through MediaProjection (one "Start now" tap by the friend), or, until that is granted or if it is refused, a few screenshots a second. Same frames as the PC agents: [u32 len][type][payload]. */
class Cast(private val svc: HelperService, private val relay: () -> String, private val token: () -> String, private val phone: Phone) {
    companion object {
        @Volatile var projection: MediaProjection? = null
        @Volatile var denied = false      // the friend said no: pictures only until the session ends
        @Volatile var asking = 0L
        @Volatile var info = ""
        private var vd: VirtualDisplay? = null
        fun shutdown(ctx: Context) {
            try { vd?.release() } catch (_: Throwable) { }; vd = null
            try { projection?.stop() } catch (_: Throwable) { }; projection = null; asking = 0
            try { ctx.stopService(Intent(ctx, CastService::class.java)) } catch (_: Throwable) { }
        }
    }

    @Volatile private var run = false
    @Volatile private var needKey = false
    private var th: Thread? = null

    fun control(a: JSONObject): String {
        if (a.has("on") && !a.optBoolean("on")) { run = false; return "stopped" }
        if (a.optBoolean("key")) needKey = true
        if (!run || th?.isAlive != true) { run = true; th = Thread { loop() }.also { it.isDaemon = true; it.start() } }
        return "streaming (" + (if (projection != null) "video" else if (denied) "pictures, the friend refused video" else "pictures, video not allowed yet") + ")" + (if (info.isNotEmpty()) " last error: $info" else "")
    }

    fun release() { run = false; shutdown(svc) }

    private fun frame(t: Char, p: ByteArray): ByteArray { val o = ByteArray(5 + p.size); val n = p.size; o[0] = (n ushr 24).toByte(); o[1] = (n ushr 16).toByte(); o[2] = (n ushr 8).toByte(); o[3] = n.toByte(); o[4] = t.code.toByte(); System.arraycopy(p, 0, o, 5, n); return o }
    private fun meta(j: JSONObject): ByteArray { val b = j.toString().toByteArray(); return byteArrayOf((b.size ushr 8).toByte(), b.size.toByte()) + b }

    private fun loop() {
        while (run) {
            try {
                val c = URL(relay().trimEnd('/') + "/a/stream").openConnection() as HttpURLConnection
                c.requestMethod = "POST"; c.doOutput = true; c.setChunkedStreamingMode(16384); c.connectTimeout = 15000; c.readTimeout = 30000
                c.setRequestProperty("Authorization", "Bearer " + token()); c.setRequestProperty("Content-Type", "application/octet-stream")
                try { BufferedOutputStream(c.outputStream, 65536).use { pump(it) }; c.responseCode } finally { c.disconnect() }
            } catch (e: Throwable) { info = (e.message ?: e.javaClass.simpleName).take(120) }
            if (run) Thread.sleep(1000)
        }
    }

    private fun realSize(): Pair<Int, Int> { val b = (svc.getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager).currentWindowMetrics.bounds; return b.width() to b.height() }

    private class Enc(val codec: MediaCodec, val surface: android.view.Surface, val w: Int, val h: Int, val realW: Int, val realH: Int) { var config: ByteArray? = null }

    private fun makeEncoder(): Enc {
        val (rw, rh) = realSize(); val sc = minOf(1f, 720f / minOf(rw, rh), 1280f / maxOf(rw, rh))
        val codec = MediaCodec.createEncoderByType("video/avc")
        val vc = codec.codecInfo.getCapabilitiesForType("video/avc").videoCapabilities
        val w = ((rw * sc).toInt() / vc.widthAlignment) * vc.widthAlignment; val h = ((rh * sc).toInt() / vc.heightAlignment) * vc.heightAlignment
        fun fmt(full: Boolean) = MediaFormat.createVideoFormat("video/avc", w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 2_500_000); setInteger(MediaFormat.KEY_FRAME_RATE, 30); setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            if (full) {
                setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)   // no B-frames: every frame can be shown at once
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                setInteger(MediaFormat.KEY_LATENCY, 1); setInteger(MediaFormat.KEY_PRIORITY, 0)
                setInteger("prepend-sps-pps-to-idr-frames", 1)
                setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 500_000)   // a still screen still gives a new viewer a picture
            }
        }
        try { codec.configure(fmt(true), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE) } catch (_: Throwable) { codec.reset(); codec.configure(fmt(false), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE) }
        val s = codec.createInputSurface(); codec.start()
        return Enc(codec, s, w, h, rw, rh)
    }

    private fun attach(e: Enc) {
        val p = projection ?: return; val dpi = svc.resources.displayMetrics.densityDpi
        val v = vd
        if (v == null) {   // Android 14 allows one virtual display per projection: it is kept and re-pointed, never created twice
            p.registerCallback(object : MediaProjection.Callback() { override fun onStop() { projection = null; vd = null; info = "the friend stopped the screen sharing" } }, Handler(Looper.getMainLooper()))
            vd = p.createVirtualDisplay("helpermcp", e.w, e.h, dpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, e.surface, null, null)
        } else { v.resize(e.w, e.h, dpi); v.surface = e.surface }
    }

    private fun sps(b: ByteArray): ByteArray? { for (i in 0 until b.size - 8) if (b[i].toInt() == 0 && b[i + 1].toInt() == 0 && (b[i + 2].toInt() == 1 || (b[i + 2].toInt() == 0 && b[i + 3].toInt() == 1))) { val o = i + (if (b[i + 2].toInt() == 1) 3 else 4); if ((b[o].toInt() and 31) == 7) return b.copyOfRange(o + 1, o + 4) }; return null }
    private fun startsWithSps(b: ByteArray) = b.size > 5 && b[0].toInt() == 0 && b[1].toInt() == 0 && ((b[2].toInt() == 1 && (b[3].toInt() and 31) == 7) || (b[2].toInt() == 0 && b[3].toInt() == 1 && (b[4].toInt() and 31) == 7))

    /** one upload: pictures at first, video as soon as the projection exists; S frames (system snapshot) every 2 s */
    private fun pump(out: OutputStream) {
        var enc: Enc? = null; var lastS = 0L; var lastShot = 0L; var lastHash = ""; var cfgSent = false
        val bi = MediaCodec.BufferInfo()
        fun send(b: ByteArray) { out.write(b); out.flush() }
        try {
            while (run) {
                val now = SystemClock.uptimeMillis()
                if (projection == null && !denied && asking == 0L && !HelperService.paused) { asking = now; try { svc.startActivity(Intent(svc, ProjectionActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (e: Throwable) { info = "cannot ask for video: ${e.message}" } }
                if (projection != null && enc == null) {
                    try { enc = makeEncoder().also { attach(it); cfgSent = false } } catch (e: Throwable) { info = "video encoder: ${e.message}"; denied = true; try { enc?.codec?.release() } catch (_: Throwable) { }; enc = null }
                }
                if (enc != null && projection == null) { try { enc.codec.stop(); enc.codec.release() } catch (_: Throwable) { }; enc = null }   // the friend stopped sharing: back to pictures
                if (enc != null) {
                    val (rw, rh) = realSize()
                    if (rw != enc.realW || rh != enc.realH) { try { enc.codec.stop(); enc.codec.release() } catch (_: Throwable) { }; enc = null; continue }   // the phone was turned: new size
                    if (needKey) { needKey = false; try { enc.codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }) } catch (_: Throwable) { } }
                    val i = enc.codec.dequeueOutputBuffer(bi, 40_000)
                    if (i >= 0) {
                        val buf = enc.codec.getOutputBuffer(i); val data = ByteArray(bi.size); buf?.position(bi.offset); buf?.get(data); enc.codec.releaseOutputBuffer(i, false)
                        if (bi.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) enc.config = data
                        else if (data.isNotEmpty()) {
                            val key = bi.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            if (!cfgSent) {
                                val cfg = enc.config ?: (if (startsWithSps(data)) data else null)
                                val s = cfg?.let { sps(it) } ?: sps(data)
                                if (s != null) { send(frame('C', meta(JSONObject().put("codec", "avc1.%02x%02x%02x".format(s[0], s[1], s[2])).put("w", enc.w).put("h", enc.h).put("ox", 0).put("oy", 0).put("sc", enc.realW.toDouble() / enc.w)))); cfgSent = true }
                            }
                            if (cfgSent) {
                                val body = if (key && !startsWithSps(data) && enc.config != null) enc.config!! + data else data
                                send(frame('V', byteArrayOf(if (key) 1 else 0) + body))
                            }
                        }
                    }
                } else if (now - lastShot >= 350) {
                    lastShot = now
                    try {
                        val sh = svc.liveShot()
                        if (sh.meta.optString("h") != lastHash) { lastHash = sh.meta.optString("h"); send(frame('K', meta(JSONObject().put("w", 0).put("h", 0).put("ox", sh.meta.optInt("ox")).put("oy", sh.meta.optInt("oy")).put("sc", sh.meta.optDouble("sc", 1.0))) + sh.jpeg)) }
                    } catch (e: Throwable) { info = (e.message ?: "screenshot failed").take(100); Thread.sleep(500) }
                } else Thread.sleep(20)
                if (now - lastS >= 2000) { lastS = now; try { send(frame('S', phone.snap().toByteArray())) } catch (e: java.io.IOException) { throw e } catch (_: Throwable) { } }
            }
        } finally {
            try { enc?.codec?.stop(); enc?.codec?.release() } catch (_: Throwable) { }
            try { vd?.surface = null } catch (_: Throwable) { }   // nobody watches: nothing is captured, the permission is kept for the next viewer
        }
    }
}

/** the one-tap system dialog "Start recording or casting?" (transparent: the friend only sees the dialog) */
class ProjectionActivity : Activity() {
    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        try { val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            // Android 14+: ask for the whole screen directly (no "A single app" drop-down for the friend to get wrong)
            startActivityForResult(if (android.os.Build.VERSION.SDK_INT >= 34) mpm.createScreenCaptureIntent(android.media.projection.MediaProjectionConfig.createConfigForDefaultDisplay()) else mpm.createScreenCaptureIntent(), 77) } catch (_: Throwable) { Cast.denied = true; finish() }
    }
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(req: Int, res: Int, data: Intent?) {
        super.onActivityResult(req, res, data)
        if (res == RESULT_OK && data != null) startForegroundService(Intent(this, CastService::class.java).putExtra("code", res).putExtra("data", data))
        else { Cast.denied = true; Cast.info = "the friend declined the screen sharing" }
        finish()
    }
}

/** Android 14 wants the projection to be created inside a running foreground service of type mediaProjection */
class CastService : Service() {
    override fun onBind(i: Intent?): IBinder? = null
    override fun onStartCommand(i: Intent?, f: Int, id: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("cast", t("Показ экрана", "Screen sharing"), NotificationManager.IMPORTANCE_LOW))
        val n = Notification.Builder(this, "cast").setSmallIcon(R.drawable.ic_launcher).setContentTitle(t("Помощник видит экран", "The helper can see the screen")).setOngoing(true).build()
        try { startForeground(7, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION) } catch (e: Throwable) { Cast.denied = true; Cast.info = "foreground service: ${e.message}"; stopSelf(); return START_NOT_STICKY }
        try {
            val data = if (android.os.Build.VERSION.SDK_INT >= 33) i?.getParcelableExtra("data", Intent::class.java) else @Suppress("DEPRECATION") i?.getParcelableExtra<Intent>("data")
            Cast.projection = (getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager).getMediaProjection(i?.getIntExtra("code", 0) ?: 0, data ?: throw RuntimeException("no permission data"))
        } catch (e: Throwable) { Cast.denied = true; Cast.info = "projection: ${e.message}"; stopSelf() }
        return START_NOT_STICKY
    }
}
