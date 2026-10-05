package app.helpermcp

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.animation.PathInterpolator
import android.animation.ValueAnimator
import android.widget.LinearLayout
import android.widget.TextView
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

private const val BLUE = 0xFF4C8DFF.toInt()
private const val ORANGE = 0xFFFF8A1E.toInt()
private const val VIOLET = 0xFFA880FF.toInt()

class Ripple(val x: Float, val y: Float, val t0: Long, val color: Int)

/** everything drawn above the other apps: edge glow, the AI's pointer with halo / ripples, the label on top */
class FxView(ctx: Context) : View(ctx) {
    private val d = resources.displayMetrics.density
    var glow: Bitmap? = null
    var pointer: Bitmap? = null; var hotX = 0; var hotY = 0   // the cursor pack's pointer (the same one the PC agents use), when the relay has it
    var color = BLUE
    var cx = -1f; var cy = -1f
    var lean = 0f
    var lastActive = 0L
    var pressedAt = -9999L
    var dragging = false
    var typingUntil = 0L
    val ripples = ArrayList<Ripple>()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val arrow = Path().apply {
        val pts = listOf(0f to 0f, 0f to 23f, 5.2f to 18.2f, 8.8f to 26.5f, 12.3f to 25f, 8.7f to 16.8f, 15.6f to 16.8f)
        moveTo(pts[0].first, pts[0].second); for (i in 1 until pts.size) lineTo(pts[i].first, pts[i].second); close()
    }

    override fun onDraw(c: Canvas) {
        val now = SystemClock.uptimeMillis(); var busy = false
        glow?.let { c.drawBitmap(it, 0f, 0f, null) }
        for (r in ripples.toList()) {
            val p = (now - r.t0) / 600f
            if (p > 1.4f) { ripples.remove(r); continue }
            busy = true
            for ((delay, base) in listOf(0f to 8f, 0.27f to 4f)) {
                val q = p - delay; if (q < 0 || q > 1) continue
                val rad = (base + 72 * (1 - (1 - q) * (1 - q) * (1 - q))) * d
                paint.style = Paint.Style.FILL; paint.color = withAlpha(r.color, 0.12f * (1 - q)); c.drawCircle(r.x, r.y, rad, paint)
                paint.style = Paint.Style.STROKE; paint.strokeWidth = (3.4f * (1 - q) + 1) * d; paint.color = withAlpha(r.color, 0.9f * Math.pow((1 - q).toDouble(), 1.3).toFloat()); c.drawCircle(r.x, r.y, rad, paint)
            }
            val p0 = (now - r.t0) / 300f
            if (p0 in 0f..1f) { paint.style = Paint.Style.FILL; paint.color = withAlpha(Color.WHITE, 0.9f * (1 - p0)); c.drawCircle(r.x, r.y, (9 * (1 - p0) + 2) * d, paint) }
        }
        val age = now - lastActive
        val alpha = if (cx < 0) 0f else if (dragging || age < 2500) 1f else max(0f, 1f - (age - 2500) / 500f)
        if (alpha > 0.01f) {
            busy = true
            val k = d * 1.25f
            c.save(); c.translate(cx, cy)
            // soft light around the pointer
            paint.style = Paint.Style.FILL
            paint.shader = RadialGradient(6 * k, 8 * k, 46 * d, intArrayOf(withAlpha(color, 0.78f * alpha), withAlpha(color, 0.34f * alpha), withAlpha(color, 0f)), floatArrayOf(0f, 0.45f, 1f), Shader.TileMode.CLAMP)
            c.drawCircle(6 * k, 8 * k, 46 * d, paint); paint.shader = null
            if (dragging) { paint.style = Paint.Style.FILL; paint.color = withAlpha(color, 0.18f * alpha); c.drawCircle(0f, 0f, 22 * d, paint); paint.style = Paint.Style.STROKE; paint.strokeWidth = 2.4f * d; paint.color = withAlpha(color, 0.85f * alpha); c.drawCircle(0f, 0f, 22 * d, paint) }
            val pa = (now - pressedAt) / 200f
            val s = if (dragging) 0.9f else if (pa in 0f..1f) 1f - 0.16f * Math.sin(PI * pa).toFloat() else 1f
            c.rotate(Math.toDegrees(lean.toDouble()).toFloat())
            val pb = pointer
            if (pb != null) {
                val kk = d * 1.2f * s; paint.alpha = (alpha * 255).toInt(); paint.isFilterBitmap = true
                c.save(); c.scale(kk, kk); c.drawBitmap(pb, -hotX.toFloat(), -hotY.toFloat(), paint); c.restore(); paint.alpha = 255
                c.restore()
            } else {
            c.scale(k * s, k * s)
            paint.style = Paint.Style.STROKE; paint.strokeJoin = Paint.Join.ROUND
            paint.strokeWidth = 4.2f; paint.color = withAlpha(Color.BLACK, 0.12f * alpha); c.save(); c.translate(1.2f, 2.4f); c.drawPath(arrow, paint); c.restore()
            paint.strokeWidth = 3.4f; paint.color = withAlpha(Color.WHITE, alpha); c.drawPath(arrow, paint)
            paint.style = Paint.Style.FILL; paint.shader = LinearGradient(0f, 0f, 0f, 27f, withAlpha(Color.WHITE, alpha), withAlpha(0xFFD1E3FF.toInt(), alpha), Shader.TileMode.CLAMP); c.drawPath(arrow, paint); paint.shader = null
            paint.style = Paint.Style.STROKE; paint.strokeWidth = 1.1f; paint.color = withAlpha(color, 0.65f * alpha); c.drawPath(arrow, paint)
            c.restore()
            }
            if (now < typingUntil) {   // typing: three pulsing dots
                val ta = (typingUntil - now) / 1000f
                for (i in 0..2) { paint.style = Paint.Style.FILL; paint.color = withAlpha(color, 0.35f + 0.65f * max(0f, Math.sin(ta * 9 - i * 0.9).toFloat())); c.drawCircle(cx + (30 + i * 9) * d, cy + 40 * d, 3.2f * d, paint) }
            }
        }
        if (busy) postInvalidateOnAnimation()
    }

    private fun withAlpha(col: Int, a: Float) = (col and 0x00FFFFFF) or ((a.coerceIn(0f, 1f) * 255).toInt() shl 24)
}

const val SECURE_WORKS = false
class Fx(private val svc: AccessibilityService) {
    private val main = Handler(Looper.getMainLooper())
    private val wm = svc.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val d = svc.resources.displayMetrics.density
    private var view: FxView? = null
    private var pill: TextView? = null
    private var card: View? = null
    var state = "wait"            // wait | ok | lost
    private var busy = false
    private var pulse: ValueAnimator? = null
    private var pulseV = 0f
    fun captureMode(on: Boolean) { if (SECURE_WORKS) return; val l = CountDownLatch(1); main.post { for (v in listOf<View?>(view, pill, card)) v?.visibility = if (on) View.INVISIBLE else View.VISIBLE; l.countDown() }; l.await(1, TimeUnit.SECONDS); if (on) Thread.sleep(60) }
    fun setBusy(b: Boolean) = main.post {
        if (busy == b) return@post; busy = b; pulse?.cancel()
        if (b) pulse = ValueAnimator.ofFloat(0f, 1f).apply { duration = 700; repeatMode = ValueAnimator.REVERSE; repeatCount = ValueAnimator.INFINITE; addUpdateListener { pulseV = it.animatedValue as Float; pill?.let { p -> updatePill(p) } }; start() }
        else { pulseV = 0f; pill?.let { updatePill(it) } }
    }
    private var startedAt = 0L
    var onEnd: (() -> Unit)? = null
    private var vel = floatArrayOf(0f, 0f); private var rotTgt = 0f; private var movingAt = -9999L
    private var anim: ValueAnimator? = null
    val width get() = wm.currentWindowMetrics.bounds.width()
    val height get() = wm.currentWindowMetrics.bounds.height()
    private fun colorOf() = if (state == "ok") BLUE else ORANGE
    private fun dp(v: Int) = (v * d).toInt()

    fun show() = main.post {
        if (view != null) return@post
        startedAt = SystemClock.elapsedRealtime()
        val v = FxView(svc); view = v
        wm.addView(v, WindowManager.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, PixelFormat.TRANSLUCENT)
            .apply { layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES })
        val p = TextView(svc).apply {
            setTextColor(Color.WHITE); textSize = 14f; typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER
            setPadding(dp(18 + 22), dp(8 + 22), dp(18 + 22), dp(8 + 22)); setOnLongClickListener { onEnd?.invoke(); true }   // long press only: an injected tap that lands here must not end the session
        }
        pill = p
        wm.addView(p, WindowManager.LayoutParams(WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, PixelFormat.TRANSLUCENT).apply { gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL; y = dp(8) })
        pendingPointer?.let { v.pointer = it.first; v.hotX = it.second; v.hotY = it.third }
        applyState(); tick()
    }

    private fun tick() {
        val p = pill ?: return
        updatePill(p); main.postDelayed({ tick() }, 1000)
    }

    private fun updatePill(p: TextView) {
        val s = ((SystemClock.elapsedRealtime() - startedAt) / 1000).toInt()
        p.text = when (state) {
            "ok" -> "●  " + t("Удалённое управление", "Remote control") + "  %02d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60) + "   ✕"
            "lost" -> "◌  " + t("Связь потеряна, переподключение…", "Connection lost, reconnecting…") + "   ✕"
            else -> "◌  " + t("Ожидание помощника…", "Waiting for the helper…") + "   ✕"
        }
        val bg = (p.background as? PillBg) ?: PillBg(dp(22)).also { p.background = it }
        bg.col = colorOf(); bg.busy = busy; bg.pulse = pulseV; bg.r = dp(20).toFloat(); bg.stroke = dp(2).toFloat(); bg.invalidateSelf()
    }

    fun setState(s: String) = main.post { if (state != s) { state = s; applyState() } }

    private fun applyState() {
        val v = view ?: return
        v.color = colorOf(); pill?.let { updatePill(it) }
        val w = width; val h = height; val col = colorOf()
        Thread {
            val bmp = buildGlow(w, h, col, dp(36))
            main.post { v.glow = bmp; v.invalidate() }
        }.start()
    }

    /** alpha of every pixel is a fade of its distance to the nearest screen edge: no seams, nothing overlaps */
    private fun buildGlow(w: Int, h: Int, color: Int, depth: Int): Bitmap {
        val prof = IntArray(depth) { dd ->
            val t = (dd + 0.5) / depth
            val a = if (t <= 0.35) 0.59 + (0.18 - 0.59) * t / 0.35 else 0.18 * (1 - (t - 0.35) / 0.65)
            ((a * 255).toInt() shl 24) or (color and 0x00FFFFFF)
        }
        val px = IntArray(w * h)
        for (y in 0 until h) for (x in 0 until w) {
            val dd = min(min(x, y), min(w - 1 - x, h - 1 - y))
            if (dd < depth) px[y * w + x] = prof[dd]
        }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }

    fun hide() = main.post {
        anim?.cancel()
        for (v in listOf<View?>(view, pill, card)) try { if (v != null) wm.removeView(v) } catch (_: Throwable) { }
        view = null; pill = null; card = null
    }

    fun setPointer(b: Bitmap?, hx: Int, hy: Int) = main.post { view?.let { it.pointer = b; it.hotX = hx; it.hotY = hy; it.invalidate() }; pendingPointer = Triple(b, hx, hy) }
    private var pendingPointer: Triple<Bitmap?, Int, Int>? = null
    fun active() = main.post { view?.let { it.lastActive = SystemClock.uptimeMillis(); it.invalidate() } }
    fun typing() = main.post { view?.let { it.typingUntil = SystemClock.uptimeMillis() + 1600; it.lastActive = SystemClock.uptimeMillis(); it.invalidate() } }
    fun press() = main.post { view?.let { it.pressedAt = SystemClock.uptimeMillis(); it.invalidate() } }
    fun ripple(x: Float, y: Float, right: Boolean = false) = main.post { view?.let { it.ripples.add(Ripple(x, y, SystemClock.uptimeMillis(), if (right) VIOLET else colorOf())); it.lastActive = SystemClock.uptimeMillis(); it.invalidate() } }
    fun dragging(on: Boolean) = main.post { view?.let { it.dragging = on; it.lastActive = SystemClock.uptimeMillis(); it.invalidate() } }

    /** the pointer glides to (x, y): a slightly curved path, slow start, fast middle, soft landing; the tip turns into the direction of movement */
    fun glide(x: Float, y: Float, then: (() -> Unit)? = null) = main.post {
        val v = view ?: run { then?.invoke(); return@post }
        v.lastActive = SystemClock.uptimeMillis()
        if (v.cx < 0) { v.cx = x; v.cy = y; v.invalidate(); then?.invoke(); return@post }
        val x0 = v.cx; val y0 = v.cy; val dist = hypot(x - x0, y - y0)
        if (dist < 2 * d) { then?.invoke(); return@post }
        val dur = min(1300L, (340 + dist / d * 1.1).toLong())
        var nx = -(y - y0) / dist; var ny = (x - x0) / dist; if (ny > 0) { nx = -nx; ny = -ny }
        val bend = min(90 * d, dist * 0.12f); val qx = (x0 + x) / 2 + nx * bend; val qy = (y0 + y) / 2 + ny * bend
        anim?.cancel()
        anim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = dur; interpolator = PathInterpolator(0.45f, 0f, 0.15f, 1f)
            addUpdateListener { a ->
                val k = a.animatedValue as Float; val m = 1 - k
                val px = m * m * x0 + 2 * m * k * qx + k * k * x; val py = m * m * y0 + 2 * m * k * qy + k * k * y
                steer(v, px, py); v.lastActive = SystemClock.uptimeMillis(); v.invalidate()
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(a: android.animation.Animator) { steer(v, x, y); then?.invoke() }
                override fun onAnimationCancel(a: android.animation.Animator) { }
            })
            start()
        }
    }

    private fun steer(v: FxView, px: Float, py: Float) {
        val now = SystemClock.uptimeMillis()
        vel[0] = vel[0] * 0.6f + (px - v.cx) * 0.4f; vel[1] = vel[1] * 0.6f + (py - v.cy) * 0.4f
        v.cx = px; v.cy = py
        if (hypot(vel[0], vel[1]) > 1.6f * d / 2) { rotTgt = atan2(vel[1], vel[0]) + 3 * PI.toFloat() / 4; movingAt = now }
        else if (now - movingAt > 450) rotTgt = 0f
        var diff = ((rotTgt - v.lean + PI.toFloat()) % (2 * PI.toFloat()) + 2 * PI.toFloat()) % (2 * PI.toFloat()) - PI.toFloat()
        v.lean += diff * 0.2f
    }

    fun glideBlocking(x: Float, y: Float) { val l = CountDownLatch(1); glide(x, y) { l.countDown() }; l.await(2, TimeUnit.SECONDS) }

    /** the question: returns "y" (yes), "a" (always), "n" (no) or "esc" (end the session) */
    fun ask(lines: List<String>, label: String): String {
        val latch = CountDownLatch(1); var answer = "n"
        main.post {
            val c = LinearLayout(svc).apply {
                orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(14), dp(16), dp(14))
                background = GradientDrawable().apply { cornerRadius = dp(18).toFloat(); setColor(0xF2101826.toInt()); setStroke(dp(2), 0xFFFFC107.toInt()) }
            }
            c.addView(TextView(svc).apply { text = if (lines.size == 1) t("Разрешить: ", "Allow: ") + lines[0] + "?" else t("Разрешить действия:", "Allow these actions:"); setTextColor(0xFFFFC107.toInt()); textSize = 16f; typeface = Typeface.DEFAULT_BOLD })
            if (lines.size > 1) lines.forEachIndexed { i, l -> c.addView(TextView(svc).apply { text = "${i + 1}. $l"; setTextColor(Color.WHITE); textSize = 15f; setPadding(dp(8), dp(2), 0, 0) }) }
            val row = LinearLayout(svc).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(12), 0, 0) }
            fun btn(txt: String, key: String, bg: Int) = TextView(svc).apply {
                text = txt; setTextColor(Color.WHITE); textSize = 15f; typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER; setPadding(dp(8), dp(12), dp(8), dp(12))
                background = GradientDrawable().apply { cornerRadius = dp(12).toFloat(); setColor(bg) }
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(dp(3), 0, dp(3), 0) }
                setOnClickListener { answer = key; latch.countDown() }
            }
            row.addView(btn(t("Да", "Yes"), "y", 0xFF2E7D32.toInt())); row.addView(btn(t("Всегда", "Always"), "a", 0xFF1565C0.toInt()))
            row.addView(btn(t("Нет", "No"), "n", 0xFF6D4C41.toInt())); row.addView(btn(t("Стоп", "Stop"), "esc", 0xFFC62828.toInt()))
            c.addView(row)
            c.addView(TextView(svc).apply { text = t("«Всегда» — не спрашивать про: ", "“Always” = stop asking about: ") + label; setTextColor(0xFFB0A070.toInt()); textSize = 12f; setPadding(0, dp(6), 0, 0) })
            card = c
            wm.addView(c, WindowManager.LayoutParams(width - dp(24), WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, PixelFormat.TRANSLUCENT).apply { gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL; y = dp(28) })
        }
        Sound.play("ask")
        try { (svc.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator).vibrate(VibrationEffect.createOneShot(60, VibrationEffect.DEFAULT_AMPLITUDE)) } catch (_: Throwable) { }
        latch.await(10, TimeUnit.MINUTES)
        main.post { card?.let { try { wm.removeView(it) } catch (_: Throwable) { } }; card = null }
        return answer
    }
}

/** the label's background: a dark pill with a plain outline; while the AI works a soft blurred halo (a fade in every direction) breathes around it */
class PillBg(private val margin: Int) : android.graphics.drawable.Drawable() {
    var col = BLUE; var busy = false; var pulse = 0f; var r = 40f; var stroke = 4f
    private val p = Paint(Paint.ANTI_ALIAS_FLAG)
    private var halo: android.graphics.Bitmap? = null; private var haloKey = ""
    override fun draw(c: Canvas) {
        val m = margin.toFloat(); val rect = android.graphics.RectF(bounds.left + m, bounds.top + m, bounds.right - m, bounds.bottom - m)
        if (busy && bounds.width() > 0) {
            val key = "$col ${bounds.width()} ${bounds.height()} $r"
            if (halo == null || haloKey != key) {   // the blur is made once; only its opacity breathes (cheap enough for a busy phone)
                val bmp = android.graphics.Bitmap.createBitmap(bounds.width(), bounds.height(), android.graphics.Bitmap.Config.ARGB_8888); val bc = Canvas(bmp)
                val rr = android.graphics.RectF(m, m, bounds.width() - m, bounds.height() - m); val q = Paint(Paint.ANTI_ALIAS_FLAG); q.color = col
                q.maskFilter = android.graphics.BlurMaskFilter(m, android.graphics.BlurMaskFilter.Blur.NORMAL); bc.drawRoundRect(rr, r, r, q)
                q.maskFilter = android.graphics.BlurMaskFilter(m * 0.5f, android.graphics.BlurMaskFilter.Blur.NORMAL); bc.drawRoundRect(rr, r, r, q)
                halo?.recycle(); halo = bmp; haloKey = key
            }
            p.reset(); p.alpha = ((0.45f + 0.55f * pulse) * 255).toInt(); c.drawBitmap(halo!!, bounds.left.toFloat(), bounds.top.toFloat(), p)
        }
        p.reset(); p.isAntiAlias = true; p.color = 0xF20F1724.toInt(); c.drawRoundRect(rect, r, r, p)
        p.style = Paint.Style.STROKE; p.strokeWidth = stroke; p.color = col; c.drawRoundRect(rect, r, r, p)
    }
    override fun setAlpha(a: Int) {}
    override fun setColorFilter(f: android.graphics.ColorFilter?) {}
    @Suppress("OVERRIDE_DEPRECATION") override fun getOpacity() = PixelFormat.TRANSLUCENT
}
