package app.helpermcp

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Path
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.URLEncoder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.hypot
import kotlin.math.min

class Shot(val jpeg: ByteArray, val meta: JSONObject)

/** The agent: an accessibility service (it can tap, swipe, type and take screenshots) that speaks the same protocol as the PC agents. */
class HelperService : AccessibilityService() {
    companion object {
        @Volatile var inst: HelperService? = null
        @Volatile var phase = "off"        // off (service not enabled) | ready | connecting | wait | ok | lost
        @Volatile var code: String? = null
        @Volatile var running = false
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var fx: Fx
    @Volatile private var ended = false
    private var scale = 1f
    private val allowed = HashSet<String>()
    private var opSeen = false
    private var askMode = true
    private var wake: PowerManager.WakeLock? = null

    override fun onServiceConnected() {
        Crash.install(this)
        inst = this; fx = Fx(this); phase = if (running) phase else "ready" }
    override fun onAccessibilityEvent(e: AccessibilityEvent?) { }
    override fun onInterrupt() { }
    override fun onDestroy() { endSession(); inst = null; phase = "off"; super.onDestroy() }

    // ------------------------------------------------------------------------------------------ session
    fun startSession(relay: String, ask: Boolean) {
        if (running) return
        running = true; ended = false; allowed.clear(); opSeen = false; askMode = ask; phase = "connecting"
        fx.onEnd = { endSession() }
        Thread { try { loop(relay) } finally { main.post { try { val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager; if (cm.primaryClip?.getItemAt(0)?.text?.toString() == code) cm.clearPrimaryClip() } catch (_: Throwable) { } }; running = false; code = null; phase = "ready"; fx.hide(); wake?.let { if (it.isHeld) it.release() } } }.start()
    }

    fun endSession() { ended = true; fx.hide() }

    private fun register(relay: String, resume: String?): JSONObject {
        val body = JSONObject().put("os", "Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})").put("host", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("user", "android").put("mode", if (askMode) "ask" else "full")
        if (resume != null) body.put("resume", resume)
        val (st, data) = Net.req(relay, "POST", "/a/register", null, body.toString().toByteArray(), timeoutMs = 20000)
        if (st != 200) throw RuntimeException("register: HTTP $st")
        return JSONObject(String(data))
    }

    private fun loop(relay: String) {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        try { wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "helpermcp:session").also { it.acquire(6 * 3600 * 1000L) } } catch (_: Throwable) { }
        var token: String; var wait = 1000L
        var reg: JSONObject
        while (true) {   // the server can be unreachable at the start: keep trying
            if (ended) return
            try { reg = register(relay, null); break } catch (_: Throwable) { Thread.sleep(wait.coerceAtMost(10000)); wait = (wait * 1.7).toLong() }
        }
        token = reg.getString("token"); code = reg.getString("code")
        main.post { try { (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("code", code)) } catch (_: Throwable) { } }
        fx.show(); fx.setState("wait"); phase = "wait"; Sound.play("ok")
        Thread { loadPointer(relay) }.start()
        var fails = 0; var delay = 1000L; var lost = false
        try {
            while (!ended) {
                try {
                    val (st, body) = Net.req(relay, "GET", "/a/poll", token, timeoutMs = 22000)
                    when (st) {
                        410 -> { ended = true; break }
                        401 -> { reg = register(relay, code); token = reg.getString("token"); code = reg.getString("code"); continue }
                    }
                    fails = 0; delay = 1000
                    if (lost) { lost = false; phase = if (opSeen) "ok" else "wait"; fx.setState(phase) }
                    if (st == 200 && body.isNotEmpty()) handle(relay, token, JSONObject(String(body)))
                } catch (e: Throwable) {
                    if (ended) break
                    fails++; if (fails >= 2 && !lost) { lost = true; phase = "lost"; fx.setState("lost") }
                    Thread.sleep(delay.coerceAtMost(10000)); delay = (delay * 1.7).toLong()
                }
            }
        } finally { try { Net.req(relay, "POST", "/a/bye", token, "{}".toByteArray(), timeoutMs = 5000) } catch (_: Throwable) { } }
    }

    /** the pointer of the operator's cursor pack (data/cursor/pointer.cur on the relay): the AI's pointer looks the same on every device */
    private fun loadPointer(relay: String) {
        try {
            val (st, b) = Net.req(relay, "GET", "/cursor/pointer.cur", null, timeoutMs = 8000)
            if (st != 200 || b.size < 30) return
            fun u16(o: Int) = (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8)
            fun u32(o: Int) = u16(o) or (u16(o + 2) shl 16)
            val n = u16(4); var best = -1; var bw = 0
            for (i in 0 until n) { val o = 6 + 16 * i; val w = (b[o].toInt() and 0xFF).let { if (it == 0) 256 else it }; if (best < 0 || (w <= 48 && w > bw)) { best = o; bw = w } }
            val w = bw; val h = (b[best + 1].toInt() and 0xFF).let { if (it == 0) 256 else it }; val hx = u16(best + 4); val hy = u16(best + 6); val off = u32(best + 12)
            val bmp: Bitmap
            if ((b[off].toInt() and 0xFF) == 0x89) { bmp = android.graphics.BitmapFactory.decodeByteArray(b, off, b.size - off) ?: return }
            else {
                if (u16(off + 14) != 32) return
                val hs = u32(off); val px = IntArray(w * h)
                for (y in 0 until h) for (x in 0 until w) {
                    val o = off + hs + ((h - 1 - y) * w + x) * 4
                    px[y * w + x] = ((b[o + 3].toInt() and 0xFF) shl 24) or ((b[o + 2].toInt() and 0xFF) shl 16) or ((b[o + 1].toInt() and 0xFF) shl 8) or (b[o].toInt() and 0xFF)
                }
                bmp = Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
            }
            fx.setPointer(bmp, hx, hy)
        } catch (_: Throwable) { }
    }

    private fun handle(relay: String, token: String, cmd: JSONObject) {
        val id = cmd.getString("id"); val tool = cmd.getString("tool"); val args = cmd.optJSONObject("args") ?: JSONObject()
        if (tool == "bye") { ended = true; return }
        if (!opSeen) { opSeen = true; phase = "ok"; fx.setState("ok") }
        var data: Any? = null; var error: String? = null
        val quiet = tool == "screenshot" || tool == "sysinfo"
        if (!quiet) fx.setBusy(true)
        try {
            if (askMode && tool in GUI || tool == "start_process" && askMode) askPermission(tool, args)
            data = exec(tool, args)
        } catch (e: Throwable) { error = e.message ?: e.javaClass.simpleName }
        if (!quiet) fx.setBusy(false)
        for (attempt in 0 until 4) {
            try {
                if (data is Shot) Net.req(relay, "POST", "/a/result", token, data.jpeg, "image/jpeg", 60000, mapOf("X-Result-Id" to id, "X-Result-Meta" to URLEncoder.encode(data.meta.toString(), "UTF-8")))
                else {
                    val r = JSONObject().put("id", id).put("ok", error == null)
                    if (error == null) r.put("data", data ?: JSONObject().put("text", "ok")) else r.put("error", error)
                    Net.req(relay, "POST", "/a/result", token, r.toString().toByteArray(), timeoutMs = 60000)
                }
                break
            } catch (_: Throwable) { Thread.sleep(1000L * (attempt + 1)) }
        }
        if (ended) return
    }

    private val GUI = setOf("click", "move", "drag", "scroll", "type_text", "press_key", "actions")

    // ------------------------------------------------------------------------------------------ questions
    private fun stepText(st: JSONObject): String {
        val x = st.opt("x"); val y = st.opt("y")
        return when (st.optString("do")) {
            "move" -> t("подвинуть палец к ($x, $y)", "move the pointer to ($x, $y)")
            "click" -> if (st.optBoolean("double")) t("двойное нажатие ($x, $y)", "double tap ($x, $y)") else if (st.optString("button") == "right") t("долгое нажатие ($x, $y)", "long press ($x, $y)") else t("нажать ($x, $y)", "tap ($x, $y)")
            "drag" -> (if (st.optBoolean("hold")) t("перенести", "drag and drop") else t("провести пальцем", "swipe")) + " ($x, $y) → (${st.opt("x2")}, ${st.opt("y2")})"
            "scroll" -> t("прокрутить (${st.optInt("amount", 3)})", "scroll (${st.optInt("amount", 3)})")
            "type" -> t("ввести \"${cut(st.optString("text"))}\"", "type \"${cut(st.optString("text"))}\"")
            "key" -> t("нажать ${st.optString("keys")}", "press ${st.optString("keys")}")
            "wait" -> t("подождать ${st.optInt("ms", 500)} мс", "wait ${st.optInt("ms", 500)} ms")
            else -> st.optString("do")
        }
    }
    private fun cut(s: String) = if (s.length > 60) s.take(60) + "…" else s

    private fun stepsOf(tool: String, a: JSONObject): List<JSONObject> {
        val raw = ArrayList<JSONObject>()
        if (tool == "actions") { val arr = a.optJSONArray("steps") ?: JSONArray(); for (i in 0 until arr.length()) raw.add(arr.getJSONObject(i)) }
        else { val o = JSONObject(a.toString()); o.put("do", when (tool) { "type_text" -> "type"; "press_key" -> "key"; else -> tool }); raw.add(o) }
        val out = ArrayList<JSONObject>()
        for (st in raw) {   // a move right before a tap on the same spot shows as one step
            val last = out.lastOrNull()
            if (last != null && last.optString("do") == "move" && st.optString("do") == "click" && last.opt("x") == st.opt("x") && last.opt("y") == st.opt("y")) out.removeAt(out.size - 1)
            out.add(st)
        }
        return out
    }

    private fun askPermission(tool: String, a: JSONObject) {
        val group = if (tool == "start_process") "apps" else "input"
        if (group in allowed) return
        val lines = if (tool == "start_process") listOf(t("открыть ", "open ") + cut(a.optString("command", a.optString("name", "")))) else stepsOf(tool, a).map { stepText(it) }
        val label = if (group == "apps") t("запуск приложений", "launching apps") else t("нажатия и ввод", "taps and typing")
        when (fx.ask(lines, label)) {
            "a" -> allowed.add(group)
            "n" -> throw RuntimeException("The user denied this action. Do not repeat it; ask the operator what to do instead.")
            "esc" -> { endSession(); throw RuntimeException("The user ended the session (pressed Stop). Stop all work on this phone now and tell the operator; do not retry.") }
        }
    }

    // ------------------------------------------------------------------------------------------ tools
    private fun exec(tool: String, a: JSONObject): Any = when (tool) {
        "sysinfo" -> ok(sysinfo().toString(2))
        "screenshot" -> screenshot(a)
        "click" -> { click(a); ok() }
        "move" -> { fx.active(); fx.glideBlocking(px(a, "x"), py(a, "y")); ok() }
        "drag" -> { drag(a); ok() }
        "scroll" -> { scroll(a); ok() }
        "type_text" -> { typeText(a.getString("text")); ok() }
        "press_key" -> { pressKey(a.getString("keys")); ok() }
        "start_process" -> { launch(a.optString("command", a.optString("name", ""))); ok() }
        "actions" -> actions(a)
        else -> throw RuntimeException("'$tool' is not available on Android. Use screenshot, click, drag, scroll, type_text, press_key, actions, start_process and sysinfo.")
    }

    private fun ok(text: String = "ok") = JSONObject().put("text", text)
    private fun px(a: JSONObject, k: String) = (a.getDouble(k) * scale).toFloat()
    private fun py(a: JSONObject, k: String) = px(a, k)

    private fun sysinfo(): JSONObject {
        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        return JSONObject().put("os", "Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})").put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("screen", "${fx.width}x${fx.height}").put("battery", bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).toString() + "%")
            .put("foreground_app", rootInActiveWindow?.packageName?.toString() ?: "?").put("screenshot_scale", scale.toDouble())
            .put("note", "Android: screenshot, click, drag, scroll, type_text, press_key (home, back, recents, notifications, enter, ...), actions, start_process (app name, package or URL).")
    }

    private fun capture(): Bitmap {
        repeat(5) {
            val latch = CountDownLatch(1); var bmp: Bitmap? = null; var err = 0
            takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
                override fun onSuccess(r: ScreenshotResult) {
                    try { val hb = r.hardwareBuffer; bmp = Bitmap.wrapHardwareBuffer(hb, r.colorSpace)?.copy(Bitmap.Config.ARGB_8888, false); hb.close() } catch (_: Throwable) { }
                    latch.countDown()
                }
                override fun onFailure(code: Int) { err = code; latch.countDown() }
            })
            latch.await(8, TimeUnit.SECONDS)
            bmp?.let { return it }
            if (err == ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT) Thread.sleep(450) else return@repeat
        }
        throw RuntimeException("Screenshot failed (a protected screen, or the service has no screenshot permission).")
    }

    private fun screenshot(a: JSONObject): Shot {
        val maxW = a.optInt("max_width", 900).coerceIn(200, 4000); val q = a.optInt("quality", 70).coerceIn(20, 95)
        val view = a.optBoolean("view")
        fx.captureMode(true)   // the overlay (glow, label, pointer) is not part of what the operator sees
        val bmp = try { capture() } finally { fx.captureMode(false) }
        val sc = if (bmp.width > maxW) bmp.width.toFloat() / maxW else 1f
        val out = if (sc > 1f) Bitmap.createScaledBitmap(bmp, (bmp.width / sc).toInt(), (bmp.height / sc).toInt(), true) else bmp
        val bo = ByteArrayOutputStream(); out.compress(Bitmap.CompressFormat.JPEG, q, bo)
        if (!view) scale = sc   // a live-viewer frame must not change the coordinates the AI works with
        return Shot(bo.toByteArray(), JSONObject().put("width", out.width).put("height", out.height).put("scale", sc.toDouble()))
    }

    private fun gesture(path: Path, dur: Long, hold: Long = 0): Boolean {
        val latch = CountDownLatch(1); var done = false
        val g = if (hold > 0) {
            val first = GestureDescription.StrokeDescription(Path(path).also { }, 0, hold, true)
            GestureDescription.Builder().addStroke(first).build()
        } else GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, dur)).build()
        main.post {
            dispatchGesture(g, object : GestureResultCallback() {
                override fun onCompleted(d: GestureDescription?) { done = true; latch.countDown() }
                override fun onCancelled(d: GestureDescription?) { latch.countDown() }
            }, null)
        }
        latch.await(dur + hold + 4000, TimeUnit.MILLISECONDS)
        return done
    }

    private fun tap(x: Float, y: Float, dur: Long = 50): Boolean = gesture(Path().apply { moveTo(x, y); lineTo(x + 0.5f, y) }, dur)

    private fun click(a: JSONObject) {
        val x = px(a, "x"); val y = py(a, "y"); val right = a.optString("button") == "right"
        fx.active(); fx.glideBlocking(x, y); Thread.sleep(50)
        repeat(if (a.optBoolean("double")) 2 else 1) {
            fx.ripple(x, y, right); fx.press()
            if (!tap(x, y, if (right) 650 else 50)) throw RuntimeException("The tap was not delivered (is the service allowed to perform gestures?)")
            Thread.sleep(110)
        }
    }

    private fun drag(a: JSONObject) {
        val x1 = px(a, "x"); val y1 = py(a, "y"); val x2 = px(a, "x2"); val y2 = py(a, "y2")
        val dens = resources.displayMetrics.density
        fx.active(); fx.glideBlocking(x1, y1); Thread.sleep(60)
        val dur = min(1500L, (320 + hypot(x2 - x1, y2 - y1) / dens * 0.9).toLong())
        fx.dragging(true); fx.ripple(x1, y1)
        fx.glide(x2, y2)
        val path = Path().apply { moveTo(x1, y1); lineTo(x2, y2) }
        val hold = a.optBoolean("hold")
        val ok = if (hold) holdDrag(x1, y1, x2, y2, dur) else gesture(path, dur)
        fx.dragging(false); fx.ripple(x2, y2)
        if (!ok) throw RuntimeException("The swipe was not delivered")
    }

    /** long-press first, then move (drag and drop of icons and list items) */
    private fun holdDrag(x1: Float, y1: Float, x2: Float, y2: Float, dur: Long): Boolean {
        val latch = CountDownLatch(1); var done = false
        val s1 = GestureDescription.StrokeDescription(Path().apply { moveTo(x1, y1); lineTo(x1 + 0.5f, y1) }, 0, 600, true)
        val s2 = s1.continueStroke(Path().apply { moveTo(x1 + 0.5f, y1); lineTo(x2, y2) }, 600, dur, false)
        main.post {
            dispatchGesture(GestureDescription.Builder().addStroke(s1).build(), object : GestureResultCallback() {
                override fun onCompleted(d: GestureDescription?) {
                    dispatchGesture(GestureDescription.Builder().addStroke(s2).build(), object : GestureResultCallback() {
                        override fun onCompleted(d2: GestureDescription?) { done = true; latch.countDown() }
                        override fun onCancelled(d2: GestureDescription?) { latch.countDown() }
                    }, null)
                }
                override fun onCancelled(d: GestureDescription?) { latch.countDown() }
            }, null)
        }
        latch.await(dur + 6000, TimeUnit.MILLISECONDS)
        return done
    }

    private fun scroll(a: JSONObject) {
        val amount = a.optInt("amount", 3); val h = fx.height.toFloat(); val w = fx.width.toFloat()
        val x = if (a.has("x")) px(a, "x") else w / 2; val y = if (a.has("y")) py(a, "y") else h / 2
        val dist = (amount.coerceIn(-20, 20) * h * 0.1f).coerceIn(-h * 0.6f, h * 0.6f)
        fx.active(); fx.glideBlocking(x, y + dist / 2); Thread.sleep(40)
        // positive = down = the content moves up: the finger goes up (the pointer travels with it)
        fx.dragging(true); fx.glide(x, y - dist / 2)
        val ok = gesture(Path().apply { moveTo(x, y + dist / 2); lineTo(x, y - dist / 2) }, 380)
        fx.dragging(false)
        if (!ok) throw RuntimeException("The scroll was not delivered")
    }

    private fun focusedInput(): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        return root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: findEditable(root)
    }
    private fun findEditable(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (n.isEditable && n.isFocused) return n
        for (i in 0 until n.childCount) { val c = n.getChild(i) ?: continue; findEditable(c)?.let { return it } }
        return null
    }

    private fun typeText(text: String) {
        fx.typing()
        val node = focusedInput() ?: throw RuntimeException("No focused text field. Tap a text field first (click), then type_text.")
        val base = if (node.isShowingHintText) "" else (node.text?.toString() ?: "")
        // typed in small portions so the dots under the pointer follow it
        var acc = base
        val chunk = maxOf(1, text.length / 40)
        var i = 0
        while (i < text.length) {
            acc += text.substring(i, min(text.length, i + chunk)); i += chunk
            val b = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, acc) }
            if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, b)) throw RuntimeException("The field did not accept the text")
            Thread.sleep(18); fx.typing()
        }
        val sel = Bundle().apply { putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, acc.length); putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, acc.length) }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
    }

    private fun pressKey(keys: String) {
        fx.active()
        when (val k = keys.lowercase().trim()) {
            "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
            "back", "esc", "escape" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "recents", "app_switcher", "overview" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
            "quick_settings" -> performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)
            "power", "power_menu" -> performGlobalAction(GLOBAL_ACTION_POWER_DIALOG)
            "lock" -> performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
            "screenshot" -> performGlobalAction(GLOBAL_ACTION_TAKE_SCREENSHOT)
            "enter", "return", "search", "go", "done" -> {
                val n = focusedInput() ?: throw RuntimeException("No focused text field for enter")
                n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
            }
            "backspace", "delete" -> {
                val n = focusedInput() ?: throw RuntimeException("No focused text field")
                val cur = n.text?.toString() ?: ""
                if (cur.isNotEmpty()) n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, cur.dropLast(1)) })
            }
            "volume_up" -> (getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager).adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, android.media.AudioManager.ADJUST_RAISE, android.media.AudioManager.FLAG_SHOW_UI)
            "volume_down" -> (getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager).adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, android.media.AudioManager.ADJUST_LOWER, android.media.AudioManager.FLAG_SHOW_UI)
            else -> throw RuntimeException("Unknown key '$k'. Available: home, back, recents, notifications, quick_settings, power, lock, screenshot, enter, backspace, volume_up, volume_down.")
        }
        Thread.sleep(250)
    }

    /** an app (by name or package) or a link */
    private fun launch(spec: String) {
        if (spec.isBlank()) throw RuntimeException("Say what to open: an app name, a package name or a link")
        fx.active()
        val intent: Intent? = if (spec.startsWith("http://") || spec.startsWith("https://") || spec.contains("://")) Intent(Intent.ACTION_VIEW, Uri.parse(spec))
        else packageManager.getLaunchIntentForPackage(spec) ?: run {
            val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val hit = packageManager.queryIntentActivities(main, 0).firstOrNull { it.loadLabel(packageManager).toString().equals(spec, true) }
                ?: packageManager.queryIntentActivities(main, 0).firstOrNull { it.loadLabel(packageManager).toString().contains(spec, true) }
            hit?.let { packageManager.getLaunchIntentForPackage(it.activityInfo.packageName) }
        }
        if (intent == null) throw RuntimeException("No app or package matches '$spec'")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK); startActivity(intent); Thread.sleep(600)
    }

    private fun actions(a: JSONObject): JSONObject {
        val steps = a.optJSONArray("steps") ?: throw RuntimeException("steps is required")
        val done = ArrayList<String>()
        for (i in 0 until min(steps.length(), 20)) {
            val st = steps.getJSONObject(i); val d = st.optString("do")
            try {
                when (d) {
                    "move" -> { fx.active(); fx.glideBlocking(px(st, "x"), py(st, "y")) }
                    "click" -> click(st)
                    "drag" -> drag(st)
                    "scroll" -> scroll(st)
                    "type" -> typeText(st.getString("text"))
                    "key" -> pressKey(st.getString("keys"))
                    "wait" -> Thread.sleep(min(5000, st.optInt("ms", 500)).toLong())
                    else -> throw RuntimeException("unknown step '$d'")
                }
            } catch (e: Throwable) { throw RuntimeException("step ${i + 1} ($d) failed: ${e.message}. Steps before it were done: ${if (done.isEmpty()) "none" else done.joinToString(", ")}.") }
            done.add("${i + 1}:$d")
        }
        return ok("ok, ${done.size} step(s) done")
    }
}
