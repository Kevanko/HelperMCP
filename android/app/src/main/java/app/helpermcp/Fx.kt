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
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.Display
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
private const val GREEN = 0xFF3DDC84.toInt()
private const val VIOLET = 0xFFA880FF.toInt()

class Ripple(val x: Float, val y: Float, val t0: Long, val color: Int)

/** everything drawn above the other apps: edge glow, the AI's pointer with halo / ripples, the label on top */
class FxView(ctx: Context) : View(ctx) {
    private val d = resources.displayMetrics.density
    var glow: Bitmap? = null
    @Volatile var glowPx: IntArray? = null; @Volatile var glowW = 0
    @Volatile var drawn = 0
    @Volatile var glowAt = 0L
    var freeze = false; var pending: (() -> Unit)? = null   // while a screenshot is taken the glow is not swapped, so it can be taken out exactly
    @Volatile var hideTop = false   // the pointer, ripples and dots are not part of a screenshot
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
        drawn++
        val now = SystemClock.uptimeMillis(); var busy = false
        glow?.let { c.drawBitmap(it, 0f, 0f, null) }
        for (r in (if (hideTop) emptyList() else ripples.toList())) {
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
        val alpha = if (hideTop || cx < 0) 0f else if (dragging || age < 2500) 1f else max(0f, 1f - (age - 2500) / 500f)
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
fun captureMode(on: Boolean) {
        val l = CountDownLatch(1); val d0 = view?.drawn ?: 0
        main.post { view?.let { it.hideTop = on; it.freeze = on; it.invalidate(); if (!on) { it.pending?.invoke(); it.pending = null } }; for (v in listOf<View?>(pill, card)) v?.visibility = if (on) View.INVISIBLE else View.VISIBLE; l.countDown() }
        l.await(1, TimeUnit.SECONDS)
        if (on) { while (SystemClock.uptimeMillis() - (view?.glowAt ?: 0L) < 900) Thread.sleep(30) }   // a glow that was just swapped may not be on the screen yet
        if (on) { val t0 = SystemClock.uptimeMillis(); while ((view?.drawn ?: 0) <= d0 + 0 && SystemClock.uptimeMillis() - t0 < 900) Thread.sleep(10); Thread.sleep(350) }   // wait until the screen really shows the frame without the label
    }

    /** bg = (captured - glow) / (1 - alpha): the edge glow is a known translucent layer, so it can be taken out of a screenshot exactly */
    fun removeGlow(b: Bitmap): Bitmap {
        val g = view?.glowPx ?: return b; val w = b.width; val h = b.height
        if (w != view?.glowW || w * h != g.size) return b
        val px = IntArray(w * h); b.getPixels(px, 0, w, 0, 0, w, h)
        // which colour is really on the screen (a swap can be a frame behind): the right one never takes a channel below zero
        var best = view?.color ?: BLUE; var bestErr = Long.MAX_VALUE
        for (c in intArrayOf(BLUE, ORANGE, GREEN)) {
            var err = 0L; var i = 0
            while (i < px.size) {
                val gp = g[i]; val a = gp ushr 24
                if (a in 100..249) { val p = px[i]; for (sh in intArrayOf(16, 8, 0)) { val d = (p shr sh and 255) - (c shr sh and 255) * a / 255; if (d < 0) err += -d } }
                i += 7
            }
            if (err < bestErr) { bestErr = err; best = c }
        }
        val rgb = best and 0x00FFFFFF
        for (i in px.indices) {
            val a0 = g[i] ushr 24; if (a0 == 0) continue
            val gp = (a0 shl 24) or rgb
            val a = gp ushr 24; if (a >= 250) continue
            val k = 255f / (255 - a); val p = px[i]
            val r = (((p shr 16 and 255) - (gp shr 16 and 255) * a / 255) * k).toInt().coerceIn(0, 255)
            val gg = (((p shr 8 and 255) - (gp shr 8 and 255) * a / 255) * k).toInt().coerceIn(0, 255)
            val bb = (((p and 255) - (gp and 255) * a / 255) * k).toInt().coerceIn(0, 255)
            px[i] = (0xFF shl 24) or (r shl 16) or (gg shl 8) or bb
        }
        b.setPixels(px, 0, w, 0, 0, w, h); return b
    }
    private val busyOff = Runnable { applyBusy(false) }
    fun setBusy(b: Boolean) = main.post {
        main.removeCallbacks(busyOff)
        if (b) applyBusy(true) else main.postDelayed(busyOff, 2500)   // the halo stays through the gap between two calls of the AI
    }
    private var haloLevel = 0f
    private var levelAnim: ValueAnimator? = null
    private fun applyBusy(b: Boolean) {
        if (busy == b) return; busy = b
        if (b && pulse == null) pulse = ValueAnimator.ofFloat(0f, 1f).apply { duration = 700; repeatMode = ValueAnimator.REVERSE; repeatCount = ValueAnimator.INFINITE; addUpdateListener { pulseV = it.animatedValue as Float; pill?.let { p -> updatePill(p) } }; start() }
        levelAnim?.cancel()   // the halo comes in softly and goes out softly, it never snaps
        levelAnim = ValueAnimator.ofFloat(haloLevel, if (b) 1f else 0f).apply {
            duration = if (b) 350L else 1400L; interpolator = android.view.animation.AccelerateDecelerateInterpolator()
            addUpdateListener { haloLevel = it.animatedValue as Float; pill?.let { p -> updatePill(p) } }
            if (!b) addListener(object : android.animation.AnimatorListenerAdapter() { override fun onAnimationEnd(a: android.animation.Animator) { if (!busy) { pulse?.cancel(); pulse = null; pulseV = 0f; haloLevel = 0f; pill?.let { p -> updatePill(p) } } } })
            start()
        }
    }
    private var startedAt = 0L
    var onEnd: (() -> Unit)? = null
    private var vel = floatArrayOf(0f, 0f); private var rotTgt = 0f; private var movingAt = -9999L
    private var anim: ValueAnimator? = null
    val width get() = wm.currentWindowMetrics.bounds.width()
    val height get() = wm.currentWindowMetrics.bounds.height()
    private fun colorOf() = when (state) { "ok" -> BLUE; "done" -> GREEN; else -> ORANGE }
    private fun dp(v: Int) = (v * d).toInt()

    fun show() = main.post {
        if (view != null) return@post
        startedAt = SystemClock.elapsedRealtime()
        val v = FxView(svc); view = v
        wm.addView(v, WindowManager.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, PixelFormat.TRANSLUCENT)
            .apply { layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES; setFitInsetsTypes(0) })
        val p = TextView(svc).apply {
            setTextColor(Color.WHITE); textSize = 14f; typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER
            setPadding(dp(18 + 22), dp(8 + 22), dp(18 + 22), dp(8 + 22))   // the label is not touchable: taps go through it
        }
        pill = p
        wm.addView(p, WindowManager.LayoutParams(WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, PixelFormat.TRANSLUCENT).apply { gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL; y = dp(8); layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES })
        pendingPointer?.let { v.pointer = it.first; v.hotX = it.second; v.hotY = it.third }
        applyState(); tick()
    }

    private fun tick() {
        val p = pill ?: return
        updatePill(p); main.postDelayed({ tick() }, 500)
    }

    // ---- the camera hole / notch: its real outline, not the bounding box the system reports (a punch hole is a circle, a waterdrop is a drop)
    private var holePath: Path? = null
    private var holeRect: android.graphics.Rect? = null
    private var holeKey = ""
    var holeSrc = "none"; private set

    private fun displayCutout(): android.view.DisplayCutout? {
        try { val c = (svc.getSystemService(Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager).getDisplay(Display.DEFAULT_DISPLAY)?.cutout; if (c != null) return c } catch (_: Throwable) { }
        return try { wm.currentWindowMetrics.windowInsets.displayCutout } catch (_: Throwable) { null }
    }

    private fun isCentral(r: android.graphics.Rect, w: Int) = r.top < dp(48) && r.bottom <= dp(120) && kotlin.math.abs((r.left + r.right) / 2 - w / 2) < w * 0.16

    /** a path out of the framework's own cutout description (config_mainBuiltInDisplayCutout), for Android versions that do not hand out the path */
    private fun pathFromResource(w: Int): Path? = try {
        val res = android.content.res.Resources.getSystem()
        val id = res.getIdentifier("config_mainBuiltInDisplayCutout", "string", "android")
        val spec = if (id != 0) res.getString(id).trim() else ""
        if (spec.isEmpty() || "@bottom" in spec) null else {
            val sc = if ("@dp" in spec) d else 1f
            val ox = if ("@left" in spec) 0f else if ("@right" in spec) w.toFloat() else w / 2f
            val tk = Regex("[MmLlHhVvCcQqZz]|-?\\d*\\.?\\d+(?:[eE][-+]?\\d+)?").findAll(spec.replace(Regex("@\\w+"), " ")).map { it.value }.toList()
            val p = Path(); var i = 0; var cmd = 'M'; var cx = 0f; var cy = 0f; var sx0 = 0f; var sy0 = 0f; var ok = true
            fun n() = tk[i++].toFloat()
            fun X(v: Float) = ox + v * sc
            fun Y(v: Float) = v * sc
            while (i < tk.size && ok) {
                if (tk[i][0].isLetter()) { cmd = tk[i][0]; i++; if (cmd == 'Z' || cmd == 'z') { p.close(); cx = sx0; cy = sy0; continue } }
                val rel = cmd.isLowerCase(); val bx = if (rel) cx else 0f; val by = if (rel) cy else 0f
                when (cmd.uppercaseChar()) {
                    'M' -> { cx = bx + n(); cy = by + n(); p.moveTo(X(cx), Y(cy)); sx0 = cx; sy0 = cy; cmd = if (rel) 'l' else 'L' }
                    'L' -> { cx = bx + n(); cy = by + n(); p.lineTo(X(cx), Y(cy)) }
                    'H' -> { cx = bx + n(); p.lineTo(X(cx), Y(cy)) }
                    'V' -> { cy = by + n(); p.lineTo(X(cx), Y(cy)) }
                    'C' -> { val x1 = bx + n(); val y1 = by + n(); val x2 = bx + n(); val y2 = by + n(); cx = bx + n(); cy = by + n(); p.cubicTo(X(x1), Y(y1), X(x2), Y(y2), X(cx), Y(cy)) }
                    'Q' -> { val x1 = bx + n(); val y1 = by + n(); cx = bx + n(); cy = by + n(); p.quadTo(X(x1), Y(y1), X(cx), Y(cy)) }
                    else -> ok = false
                }
            }
            if (ok) p else null
        }
    } catch (_: Throwable) { null }

    private fun loadHole() {
        val w = width; if (holeKey == "$w") return
        val rects = displayCutout()?.boundingRects ?: emptyList()
        holeKey = "$w"
        if (rects.isEmpty()) { holePath = null; holeRect = null; holeSrc = "none"; return }
        fun clipOf(r: android.graphics.Rect) = android.graphics.Region(r.left - dp(3), maxOf(0, r.top - dp(3)), r.right + dp(3), r.bottom + dp(3))
        fun covers(p: Path) = rects.all { r -> val g = android.graphics.Region(); g.setPath(p, clipOf(r)); !g.isEmpty && g.bounds.width() >= r.width() * 0.3f }
        var path: Path? = null; var src = "fallback"
        try { if (Build.VERSION.SDK_INT >= 34) displayCutout()?.cutoutPath?.let { if (!it.isEmpty && covers(it)) { path = Path(it); src = "api" } } } catch (_: Throwable) { }
        if (path == null) pathFromResource(w)?.let { if (covers(it)) { path = it; src = "resource" } }
        // some makers declare the cutout as a plain rectangle (realme: 116x140 around a round camera): that box is a margin, not the hole
        if (path != null && rects.size == 1 && rects[0].height() >= rects[0].width() * 0.9f) {
            val g = android.graphics.Region(); g.setPath(path!!, clipOf(rects[0])); val it = android.graphics.RegionIterator(g); val q = android.graphics.Rect(); var n = 0; while (it.next(q)) n++
            if (n == 1 && g.bounds.width() >= rects[0].width() - 3) { path = null; src = "box->circle" }
        }
        if (path == null) {   // nothing better: a circle for a square-ish box (punch hole), a rounded bar for a wide one (notch)
            val p = Path()
            for (r in rects) {
                val rf = android.graphics.RectF(r)
                if (r.height() >= r.width() * 0.9f) { val dm = r.width() * 0.86f; p.addOval(rf.centerX() - dm / 2, rf.centerY() - dm / 2, rf.centerX() + dm / 2, rf.centerY() + dm / 2, Path.Direction.CW) }
                else p.addRoundRect(rf, rf.height() * 0.5f, rf.height() * 0.5f, Path.Direction.CW)
            }
            path = p
        }
        holePath = path; holeSrc = src
        val c = rects.firstOrNull { isCentral(it, w) }
        holeRect = c?.let { r -> val g = android.graphics.Region(); g.setPath(path!!, clipOf(r)); if (g.isEmpty) r else g.bounds }
    }

    private fun cutout(): android.graphics.Rect? { loadHole(); return holeRect }
    fun holeInfo() = "src=$holeSrc rect=${holeRect?.let { "${it.left},${it.top},${it.right},${it.bottom}" }}"

    private var expandUntil = 0L
    private var expandedNow = true
    private var padKey = ""
    private fun updatePill(p: TextView) {
        val s = ((SystemClock.elapsedRealtime() - startedAt) / 1000).toInt()
        val clock = if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60) else "%02d:%02d".format(s / 60, s % 60)
        // collapsed: an island that looks like the camera hole stretched, a dot on the left and the time on the right; it opens for a few seconds on a change and stays open while something needs attention
        val exp = (state != "ok" && state != "done") || SystemClock.uptimeMillis() < expandUntil
        val cut = cutout(); val m = dp(22)
        if (exp != expandedNow) { expandedNow = exp; p.textSize = if (exp) 14f else 11f; padKey = "" }
        val lp = p.layoutParams as WindowManager.LayoutParams
        var innerH: Int; var ny: Int
        if (exp) {
            val key = "e"; if (padKey != key) { padKey = key; p.setPadding(m + dp(18), m + dp(8), m + dp(18), m + dp(8)) }
            p.text = when (state) {
                "ok" -> "●  " + t("Удалённое управление", "Remote control") + "  $clock"
                "done" -> "✓  " + t("Работа выполнена", "Work finished")
                "lost" -> "◌  " + t("Связь потеряна, переподключение…", "Connection lost, reconnecting…")
                "paused" -> "||  " + t("Пауза: помощник ждёт", "Paused: the helper is waiting")
                else -> "◌  " + t("Ожидание помощника…", "Waiting for the helper…")
            }
            ny = if (cut != null) cut.bottom + dp(6) - m else dp(8)   // under the camera, never over it
        } else {
            val fm = p.paint.fontMetrics; val lineH = fm.descent - fm.ascent
            val targetH = if (cut != null) cut.height() + dp(4) else dp(26)
            val padV = max(dp(2), ((targetH - lineH) / 2).toInt()); innerH = (lineH + 2 * padV).toInt()
            val key = "c$padV"; if (padKey != key) { padKey = key; p.setPadding(m + dp(12), m + padV, m + dp(12), m + padV) }
            val right = if (state == "done") "✓" else clock
            val dotW = p.paint.measureText("●"); val timeW = p.paint.measureText(right)
            val base = dp(if (cut != null) 8 else 6).toFloat()
            // the camera hole sits exactly in the middle of the capsule: the shorter wing is padded to the length of the longer one
            val g1 = base + max(0f, timeW - dotW); val g2 = base + max(0f, dotW - timeW)
            val gap = (g1 + (cut?.width() ?: 0) + g2).toInt()
            val sb = android.text.SpannableStringBuilder("●"); sb.setSpan(android.text.style.ForegroundColorSpan(colorOf()), 0, 1, 0)
            sb.append(" "); sb.setSpan(object : android.text.style.ReplacementSpan() {
                override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?) = gap
                override fun draw(canvas: Canvas, text: CharSequence?, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) { }
            }, 1, 2, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            sb.append(right); p.text = sb
            val sbTop = try { wm.currentWindowMetrics.windowInsets.getInsets(android.view.WindowInsets.Type.statusBars()).top } catch (_: Throwable) { 0 }
            val centre = if (cut != null) (cut.top + cut.bottom) / 2 else (if (sbTop > 0) sbTop / 2 else dp(14))
            ny = centre - innerH / 2 - m
        }
        if (lp.y != ny) { lp.y = ny; try { wm.updateViewLayout(p, lp) } catch (_: Throwable) { } }
        val bg = (p.background as? PillBg) ?: PillBg(m).also { p.background = it }
        bg.col = colorOf(); bg.level = haloLevel; bg.pulse = pulseV; bg.island = !exp
        bg.r = if (exp) dp(20).toFloat() else (if (p.height > 0) (p.height - 2 * m) / 2f else dp(13).toFloat()); bg.stroke = dp(2).toFloat(); bg.invalidateSelf()
    }

    /** what this phone reports about its camera and where the label really ended up: read through sysinfo, to fix a wrong placement from facts */
    fun diag(): org.json.JSONObject {
        val o = org.json.JSONObject(); val l = CountDownLatch(1)
        main.post {
            try {
                fun rects(c: android.view.DisplayCutout?) = org.json.JSONArray().also { a -> c?.boundingRects?.forEach { a.put("${it.left},${it.top},${it.right},${it.bottom}") } }
                o.put("density", d.toDouble()).put("window", "$width x $height")
                o.put("cutout_display", try { rects((svc.getSystemService(Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager).getDisplay(Display.DEFAULT_DISPLAY)?.cutout) } catch (e: Throwable) { "err ${e.message}" })
                o.put("cutout_pill_insets", try { rects(pill?.rootWindowInsets?.displayCutout) } catch (e: Throwable) { "err ${e.message}" })
                o.put("cutout_metrics", try { rects(wm.currentWindowMetrics.windowInsets.displayCutout) } catch (e: Throwable) { "err ${e.message}" })
                try { val ins = wm.currentWindowMetrics.windowInsets; o.put("safe_top", ins.displayCutout?.safeInsetTop ?: 0); o.put("status_bar_h", ins.getInsets(android.view.WindowInsets.Type.statusBars()).top)
                    if (Build.VERSION.SDK_INT >= 31) o.put("round_corners", (0..3).map { ins.getRoundedCorner(it)?.radius ?: 0 }.toString()) } catch (_: Throwable) { }
                o.put("cutout_used", cutout()?.let { "${it.left},${it.top},${it.right},${it.bottom}" } ?: "none"); o.put("hole", holeInfo())
                try { val id = android.content.res.Resources.getSystem().getIdentifier("config_mainBuiltInDisplayCutout", "string", "android"); o.put("cutout_spec", if (id != 0) android.content.res.Resources.getSystem().getString(id).take(300) else "no resource") } catch (_: Throwable) { }
                pill?.let { p -> val xy = IntArray(2); p.getLocationOnScreen(xy); o.put("label", "x=${xy[0]} y=${xy[1]} w=${p.width} h=${p.height} text=${p.text} expanded=$expandedNow state=$state") }
            } catch (e: Throwable) { o.put("diag_error", e.toString()) }
            l.countDown()
        }
        l.await(2, TimeUnit.SECONDS); return o
    }

    fun resetClock() = main.post { startedAt = SystemClock.elapsedRealtime() }

    fun setState(s: String) = main.post { if (state != s) { state = s; expandUntil = SystemClock.uptimeMillis() + (if (s == "done") 7000 else 3500); applyState() } }

    private var glowGen = 0
    private fun applyState() {
        val v = view ?: return
        v.color = colorOf(); pill?.let { updatePill(it) }
        loadHole(); val hp = holePath
        val w = width; val h = height; val col = colorOf(); val sh = shapeNow(); val gen = ++glowGen
        Thread {
            sh.masks = hp?.let { maskOf(it, dp(36), w, h) }?.let { listOf(it) } ?: emptyList()
            val px = buildGlow(w, h, col, dp(36), sh)
            val bmp = Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
            val apply = { v.glowAt = SystemClock.uptimeMillis(); v.glowW = w; v.glowPx = px; v.glow = bmp; v.invalidate() }
            main.post { if (gen == glowGen) { if (v.freeze) v.pending = apply else apply() } }   // a slower, older build must never overwrite a newer one
        }.start()
    }

    private class HoleMask(val x0: Int, val y0: Int, val w: Int, val h: Int, val d: FloatArray)   // d < 0: inside the hole, otherwise the distance to it in px
    private class Shape(val rTL: Float, val rTR: Float, val rBL: Float, val rBR: Float) { var masks: List<HoleMask> = emptyList() }

    /** what this particular phone looks like: the radius of each screen corner */
    private fun shapeNow(): Shape {
        var r = floatArrayOf(0f, 0f, 0f, 0f)
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                val ins = wm.currentWindowMetrics.windowInsets
                val pos = intArrayOf(android.view.RoundedCorner.POSITION_TOP_LEFT, android.view.RoundedCorner.POSITION_TOP_RIGHT, android.view.RoundedCorner.POSITION_BOTTOM_LEFT, android.view.RoundedCorner.POSITION_BOTTOM_RIGHT)
                for (i in 0..3) r[i] = ins.getRoundedCorner(pos[i])?.radius?.toFloat() ?: 0f
            }
            if (r.all { it == 0f }) {   // older Android: the radius the system itself uses for its corner masks
                val id = android.content.res.Resources.getSystem().getIdentifier("rounded_corner_radius", "dimen", "android")
                if (id != 0) { val v = android.content.res.Resources.getSystem().getDimensionPixelSize(id).toFloat(); r = floatArrayOf(v, v, v, v) }
            }
        } catch (_: Throwable) { }
        return Shape(r[0], r[1], r[2], r[3])
    }

    /** the hole filled on a small bitmap and a distance map around it (two chamfer passes): the glow hugs the true outline */
    private fun maskOf(path: Path, depth: Int, w: Int, h: Int): HoleMask? {
        val b = android.graphics.RectF(); path.computeBounds(b, true); val pad = depth + 3
        val x0 = max(0, b.left.toInt() - pad); val y0 = max(0, b.top.toInt() - pad); val x1 = min(w, b.right.toInt() + pad + 1); val y1 = min(h, b.bottom.toInt() + pad + 1)
        val mw = x1 - x0; val mh = y1 - y0; if (mw <= 0 || mh <= 0 || mw.toLong() * mh > 6_000_000L) return null
        val bmp = Bitmap.createBitmap(mw, mh, Bitmap.Config.ALPHA_8); val c = Canvas(bmp); c.translate(-x0.toFloat(), -y0.toFloat())
        c.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = Color.BLACK })
        val buf = java.nio.ByteBuffer.allocate(mw * mh); bmp.copyPixelsToBuffer(buf); val a = buf.array(); bmp.recycle()
        val big = 1e9f; val dd = FloatArray(mw * mh) { if ((a[it].toInt() and 255) > 127) 0f else big }
        for (y in 0 until mh) for (x in 0 until mw) {
            val i = y * mw + x; var v = dd[i]
            if (x > 0) v = min(v, dd[i - 1] + 1f)
            if (y > 0) { v = min(v, dd[i - mw] + 1f); if (x > 0) v = min(v, dd[i - mw - 1] + 1.414f); if (x < mw - 1) v = min(v, dd[i - mw + 1] + 1.414f) }
            dd[i] = v
        }
        for (y in mh - 1 downTo 0) for (x in mw - 1 downTo 0) {
            val i = y * mw + x; var v = dd[i]
            if (x < mw - 1) v = min(v, dd[i + 1] + 1f)
            if (y < mh - 1) { v = min(v, dd[i + mw] + 1f); if (x < mw - 1) v = min(v, dd[i + mw + 1] + 1.414f); if (x > 0) v = min(v, dd[i + mw - 1] + 1.414f) }
            dd[i] = v
        }
        for (i in dd.indices) if ((a[i].toInt() and 255) > 127) dd[i] = -1f
        return HoleMask(x0, y0, mw, mh, dd)
    }

    /** signed distance from (px, py) to a rounded rectangle (negative inside) */
    private fun sdRound(px: Float, py: Float, cx: Float, cy: Float, hw: Float, hh: Float, r: Float): Float {
        val qx = kotlin.math.abs(px - cx) - (hw - r); val qy = kotlin.math.abs(py - cy) - (hh - r)
        val ox = max(qx, 0f); val oy = max(qy, 0f)
        return kotlin.math.sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0f) - r
    }

    /** alpha of every pixel is a fade of its distance to the nearest edge of the real screen shape (rounded corners) and to the true outline of every camera hole: no seams, nothing overlaps */
    private fun buildGlow(w: Int, h: Int, color: Int, depth: Int, sh: Shape): IntArray {
        val prof = IntArray(depth) { dd ->
            val t = (dd + 0.5) / depth
            val a = if (t <= 0.35) 0.59 + (0.18 - 0.59) * t / 0.35 else 0.18 * (1 - (t - 0.35) / 0.65)
            val al = (a * 255).toInt()
            (al shl 24) or (color and 0x00FFFFFF)
        }
        val px = IntArray(w * h)
        val hw = w / 2f; val hh = h / 2f; val maxR = max(max(sh.rTL, sh.rTR), max(sh.rBL, sh.rBR)); val band = depth + maxR + 2
        for (y in 0 until h) for (x in 0 until w) {
            val edge = min(min(x, y), min(w - 1 - x, h - 1 - y))
            var near = edge < band
            if (!near) for (m in sh.masks) if (x >= m.x0 && x < m.x0 + m.w && y >= m.y0 && y < m.y0 + m.h) { near = true; break }
            if (!near) continue
            val fx = x + 0.5f; val fy = y + 0.5f
            val r = if (fy < hh) (if (fx < hw) sh.rTL else sh.rTR) else (if (fx < hw) sh.rBL else sh.rBR)
            var dist = -sdRound(fx, fy, hw, hh, hw, hh, r)   // depth below the surface of the screen shape
            if (dist < 0f) continue                          // outside a rounded corner: not part of the screen
            for (m in sh.masks) {
                if (x < m.x0 || x >= m.x0 + m.w || y < m.y0 || y >= m.y0 + m.h) continue
                val v = m.d[(y - m.y0) * m.w + (x - m.x0)]
                if (v < 0f) { dist = -1f; break }            // inside the camera hole
                dist = min(dist, v)
            }
            if (dist < 0f) continue
            val di = dist.toInt(); if (di < depth) px[y * w + x] = prof[di]
        }
        return px
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
    var col = BLUE; var level = 0f; var pulse = 0f; var r = 40f; var stroke = 4f; var island = false
    private val p = Paint(Paint.ANTI_ALIAS_FLAG)
    private var halo: android.graphics.Bitmap? = null; private var haloKey = ""
    override fun draw(c: Canvas) {
        val m = margin.toFloat(); val rect = android.graphics.RectF(bounds.left + m, bounds.top + m, bounds.right - m, bounds.bottom - m)
        if (level > 0.01f && bounds.width() > 0) {
            val key = "$col ${bounds.width()} ${bounds.height()} $r"
            if (halo == null || haloKey != key) {   // the blur is made once; only its opacity breathes (cheap enough for a busy phone)
                val bmp = android.graphics.Bitmap.createBitmap(bounds.width(), bounds.height(), android.graphics.Bitmap.Config.ARGB_8888); val bc = Canvas(bmp)
                val rr = android.graphics.RectF(m, m, bounds.width() - m, bounds.height() - m); val q = Paint(Paint.ANTI_ALIAS_FLAG); q.color = col
                q.maskFilter = android.graphics.BlurMaskFilter(m, android.graphics.BlurMaskFilter.Blur.NORMAL); bc.drawRoundRect(rr, r, r, q)
                q.maskFilter = android.graphics.BlurMaskFilter(m * 0.5f, android.graphics.BlurMaskFilter.Blur.NORMAL); bc.drawRoundRect(rr, r, r, q)
                halo?.recycle(); halo = bmp; haloKey = key
            }
            p.reset(); p.alpha = ((0.45f + 0.55f * pulse) * level * 255).toInt(); c.drawBitmap(halo!!, bounds.left.toFloat(), bounds.top.toFloat(), p)
        }
        if (island) { p.reset(); p.isAntiAlias = true; p.color = 0xFF000000.toInt(); c.drawRoundRect(rect, r, r, p); return }   // the island is plain black: it reads as the camera hole stretched
        p.reset(); p.isAntiAlias = true; p.color = 0xF20F1724.toInt(); c.drawRoundRect(rect, r, r, p)
        p.style = Paint.Style.STROKE; p.strokeWidth = stroke; p.color = col; c.drawRoundRect(rect, r, r, p)
    }
    override fun setAlpha(a: Int) {}
    override fun setColorFilter(f: android.graphics.ColorFilter?) {}
    @Suppress("OVERRIDE_DEPRECATION") override fun getOpacity() = PixelFormat.TRANSLUCENT
}
