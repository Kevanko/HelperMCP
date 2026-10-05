package app.helpermcp

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView

/** one screen: allow the service, press Start, tell the code to the helper */
class MainActivity : Activity() {
    private val h = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var codeView: TextView
    private lateinit var hint: TextView
    private lateinit var allow: TextView
    private lateinit var versionLine: TextView
    private lateinit var updateBtn: TextView
    private val allowViews = ArrayList<View>()
    private lateinit var start: TextView
    private lateinit var relay: EditText
    private lateinit var askSwitch: Switch
    private val prefs by lazy { getSharedPreferences("cfg", MODE_PRIVATE) }
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun button(text: String, bg: Int, onClick: () -> Unit) = TextView(this).apply {
        this.text = text; setTextColor(Color.WHITE); textSize = 17f; typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER
        setPadding(dp(16), dp(16), dp(16), dp(16)); background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(bg) }
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(12) }
        setOnClickListener { onClick() }
    }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(22), dp(36), dp(22), dp(22)); setBackgroundColor(0xFF0F1724.toInt()) }
        col.addView(TextView(this).apply { text = t("Удалённая помощь", "Remote help"); setTextColor(Color.WHITE); textSize = 28f; typeface = Typeface.DEFAULT_BOLD })
        col.addView(TextView(this).apply { text = t("Человек, которому вы назовёте код, сможет смотреть на экран и нажимать за вас. Вы видите всё, что он делает, и можете остановить в любой момент.", "The person you give the code to can look at this screen and tap for you. You see everything they do and can stop at any time."); setTextColor(0xFFB8C4D8.toInt()); textSize = 15f; setPadding(0, dp(8), 0, dp(14)) })
        updateBtn = button("", 0xFFEF6C00.toInt()) { Update.install(this, relay.text.toString().trim().ifEmpty { BuildConfig.RELAY }) }.apply { visibility = View.GONE }; col.addView(updateBtn)
        status = TextView(this).apply { setTextColor(0xFFFFB347.toInt()); textSize = 18f; typeface = Typeface.DEFAULT_BOLD; setPadding(0, dp(6), 0, dp(6)) }; col.addView(status)
        codeView = TextView(this).apply { setTextColor(0xFF0F1724.toInt()); textSize = 40f; typeface = Typeface.MONOSPACE; gravity = Gravity.CENTER; setPadding(dp(8), dp(14), dp(8), dp(14)); visibility = View.GONE
            background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(0xFFFFD54F.toInt()) } }
        col.addView(codeView, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        hint = TextView(this).apply { setTextColor(0xFF9FB0C8.toInt()); textSize = 14f; setPadding(0, dp(8), 0, dp(4)) }; col.addView(hint)
        allow = button(t("1. Разрешить управление", "1. Allow control"), 0xFF1565C0.toInt()) { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }; col.addView(allow)
        val allowHint = TextView(this).apply { text = t("В списке выберите HelperMCP и включите. Если пункт серый («ограниченные настройки»): сведения о приложении → ⋮ → «Разрешить ограниченные настройки».", "Pick HelperMCP in the list and switch it on. If it is greyed out (“restricted settings”): App info → ⋮ → “Allow restricted settings”."); setTextColor(0xFF9FB0C8.toInt()); textSize = 13f; setPadding(0, dp(6), 0, 0) }
        col.addView(allowHint); allowViews.add(allowHint)
        val appInfo = button(t("Сведения о приложении", "App info"), 0xFF37474F.toInt()) { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))) }
        col.addView(appInfo); allowViews.add(appInfo)
        start = button(t("2. Начать помощь", "2. Start help"), 0xFF2E7D32.toInt()) { toggle() }; col.addView(start)
        askSwitch = Switch(this).apply { text = t("Спрашивать подтверждение каждого действия", "Ask before every action"); setTextColor(Color.WHITE); isChecked = prefs.getBoolean("ask", true); setPadding(0, dp(18), 0, 0) }; col.addView(askSwitch)
        col.addView(TextView(this).apply { text = t("Сервер", "Server"); setTextColor(0xFF9FB0C8.toInt()); textSize = 13f; setPadding(0, dp(16), 0, 0) })
        relay = EditText(this).apply { setText(prefs.getString("relay", BuildConfig.RELAY)); setTextColor(Color.WHITE); inputType = InputType.TYPE_TEXT_VARIATION_URI; textSize = 14f }; col.addView(relay)
        versionLine = TextView(this).apply { setTextColor(0xFF6B7A94.toInt()); textSize = 12f; setPadding(0, dp(18), 0, 0) }; col.addView(versionLine)
        setContentView(ScrollView(this).apply { setBackgroundColor(0xFF0F1724.toInt()); addView(col) })
    }

    private fun toggle() {
        val s = HelperService.inst
        if (HelperService.running) { s?.endSession(); return }
        if (s == null) { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)); return }
        prefs.edit().putString("relay", relay.text.toString().trim()).putBoolean("ask", askSwitch.isChecked).apply()
        s.startSession(relay.text.toString().trim().ifEmpty { BuildConfig.RELAY }, askSwitch.isChecked)
    }

    override fun onResume() { super.onResume(); Update.check(prefs.getString("relay", BuildConfig.RELAY) ?: BuildConfig.RELAY); tick() }
    override fun onPause() { super.onPause(); h.removeCallbacksAndMessages(null) }

    private fun tick() {
        val on = HelperService.inst != null
        val up = Update.available
        updateBtn.visibility = if (up != null) View.VISIBLE else View.GONE
        if (up != null) updateBtn.text = if (Update.progress.isNotEmpty()) (if (Update.progress.startsWith("error")) Update.progress else t("Скачиваю… ", "Downloading… ") + Update.progress.substringAfter(' ')) else t("⬇ Доступно обновление ", "⬇ Update available ") + up.optString("versionName") + t(" — обновить", " — install")
        status.text = when (HelperService.phase) {
            "connecting" -> t("◌ Подключаюсь к серверу…", "◌ Connecting to the server…")
            "wait" -> t("◌ Ожидание помощника… назовите ему код", "◌ Waiting for the helper… give them the code")
            "ok" -> t("● Помощник подключён", "● Helper connected")
            "lost" -> t("◌ Связь потеряна, переподключение…", "◌ Connection lost, reconnecting…")
            else -> if (on) t("Готово к запуску", "Ready to start") else t("Сначала разрешите управление (шаг 1)", "Allow control first (step 1)")
        }
        status.setTextColor(if (HelperService.phase == "ok") 0xFF66BB6A.toInt() else 0xFFFFB347.toInt())
        val code = HelperService.code
        codeView.visibility = if (code != null && HelperService.running) View.VISIBLE else View.GONE
        codeView.text = code ?: ""
        hint.text = if (code != null && HelperService.running) t("Код скопирован в буфер. Чтобы закончить, нажмите на плашку «✕» сверху экрана или кнопку ниже.", "The code is copied. To stop, tap the “✕” label at the top of the screen or the button below.") else ""
        allow.visibility = if (on) View.GONE else View.VISIBLE
        allowViews.forEach { it.visibility = if (on) View.GONE else View.VISIBLE }
        start.text = if (HelperService.running) t("Завершить помощь", "End help") else t("2. Начать помощь", "2. Start help")
        if (System.currentTimeMillis() % 20000 < 600) Update.check(relay.text.toString().trim().ifEmpty { BuildConfig.RELAY })
        versionLine.text = "v" + BuildConfig.VERSION_NAME + (if (up != null) "  →  " + up.optString("versionName") else if (Update.checked == "ok") t("  (последняя версия)", "  (up to date)") else if (Update.checked.isNotEmpty()) "  (" + Update.checked + ")" else "")
        h.postDelayed({ tick() }, 500)
    }
}
