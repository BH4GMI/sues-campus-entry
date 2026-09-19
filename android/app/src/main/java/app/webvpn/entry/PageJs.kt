package app.webvpn.entry

import android.content.res.AssetManager

/**
 * 注入页面的几段 JS。**正文只有一份来源：仓库根下的 `shared/js/`**（三端共用，PC 端打包的是
 * 同一批文件），这里只负责加载与填充占位符。
 *
 * 全部来自实测页面（见 `docs/PROTOCOL.md`），只做两类事：回报**观察到**的页面状态，以及执行
 * 不涉及凭据的小动作（勾「记住我」、把滑块拖过去）。
 *
 * 判断一律留在 Kotlin 一侧（`Sues`）：标记表只有一份，也能被单测覆盖，不必在 JS 里再写一套。
 * 改这些文件等于改三端的页面契约——先改 `docs/CORE-SPEC.md` 与 `docs/PROTOCOL.md`，再动文件。
 */
object PageJs {

    private val cache = HashMap<String, String>()

    /** 脚本来源。真机是 assets；JVM 单测换成直接读源码树（见 `SliderDragTest`）。 */
    @Volatile
    private var loader: ((String) -> String)? = null

    /** 宿主启动时指定来源：`shared/js` 被打进 assets 根目录（见 `app/build.gradle`）。 */
    fun prepare(assets: AssetManager) {
        prepareSource { name ->
            assets.open(name).bufferedReader().use { it.readText() }
        }
    }

    @Synchronized
    fun prepareSource(source: (String) -> String) {
        loader = source
        cache.clear()
    }

    @Synchronized
    private fun raw(name: String): String = cache.getOrPut(name) {
        val source = loader ?: error("PageJs 尚未 prepare：宿主或单测必须先指定 shared/js 的来源")
        source(name).trimEnd().also { check(it.isNotEmpty()) { "shared/js/$name 是空文件" } }
    }

    /** 探测门户上的教务系统入口，返回 `portal|<入口地址>` 或 `other`。判据见 `docs/CORE-SPEC.md` §3。 */
    val PROBE: String get() = raw("probe.js")

    /**
     * 停手前的最后一道判据：正文里有没有「确实登录进去了」的标记（`docs/CORE-SPEC.md` §2）。
     * 返回 `arrival|<命中的标记>` / `arrival|none` / `arrival|err`。
     */
    val ARRIVAL: String get() = raw("arrival.js")

    /** 勾上统一身份认证页那个挂着保密提示的复选框（`name=rememberMe`，是「记住我」）。 */
    val TICK_NOTICE: String get() = raw("tick-notice.js")

    /** 观察认证页并**原样回报**：优先级在 [Sues.casKind]，见 `docs/CORE-SPEC.md` §2。 */
    val CAS_STATE: String get() = raw("cas-state.js").replace("__EXPIRED_MARK__", Sues.PASSWORD_EXPIRED_MARK)

    /** 处理「密码已过期」提示页：按文字找「点击跳过」，找不到就重载（那正是该按钮做的事）。 */
    val SKIP_EXPIRED: String get() = raw("skip-expired.js")

    /** 滑块监视器：接管时机与「同一张图只报一次」的约定见 `docs/CORE-SPEC.md` §5.1。 */
    val CAPTCHA_WATCH: String get() = raw("captcha-watch.js")

    /** 停掉页面侧监视器（用户接管、放弃、退到后台、或视图销毁时都必须停）。幂等。 */
    val CAPTCHA_STOP: String get() = raw("captcha-stop.js")

    /** 量滑块几何。**只量，不算**：拖动换算全在 [SliderDrag] 里，那里能被单测覆盖。 */
    val SLIDER_GEOMETRY: String get() = raw("slider-geometry.js")

    /** 按 [SliderDrag.Plan] 拖动：按下给手柄、移动与抬起给 `document`（页面就是这么监听的）。 */
    fun dragJs(plan: SliderDrag.Plan): String = raw("drag.js").replace(
            "__DELTA__", String.format(java.util.Locale.US, "%.2f", plan.delta))

    /**
     * 在统一身份认证页上填写账号密码、勾「记住我」，然后按下**页面自己的**登录按钮：
     * 加密发生在页面 `login.js` 的那次点击里，应用只做用户在键盘和鼠标上会做的动作。
     */
    fun fillAndSubmitJs(username: String, password: String): String =
            raw("fill-and-submit.js")
                    .replace("__USERNAME__", jsLiteral(username))
                    .replace("__PASSWORD__", jsLiteral(password))

    /**
     * 捕获用户在官方认证页上**自己按下登录**那一刻的账号密码；是否接受由原生决定。
     * 监听器持有具名引用，`credential-stop.js` 才能真正摘掉它。
     */
    val CREDENTIAL_WATCH: String get() = raw("credential-watch.js")

    /** 真正摘掉凭据监视器（具名监听器 + 标志位双保险）。幂等。 */
    val CREDENTIAL_STOP: String get() = raw("credential-stop.js")

    /**
     * 关掉（或恢复）站点的「通知公告」弹窗。结构与安全边界见 `docs/PROTOCOL.md` §9：
     * 整层摘掉（弹窗 + 遮罩 + 滚动锁，三者一起），只认确实装着公告卡片的那种弹窗，可逆。
     */
    fun noticeDialogJs(hide: Boolean): String =
            raw("notice-dialog.js").replace("__HIDE__", if (hide) "true" else "false")

    /**
     * 把一段文本变成可以安全塞进注入脚本的字符串字面量。
     *
     * 必须自己转义：账号或密码里可能出现引号、反斜杠、换行，直接拼进 JS 会把脚本拼坏，
     * 而拼坏的表现是「静默不填」——最难查的那种。
     */
    fun jsLiteral(text: String): String = buildString(text.length + 2) {
        append('"')
        for (c in text) {
            when {
                c == '\\' -> append("\\\\")
                c == '"' -> append("\\\"")
                c == '\n' -> append("\\n")
                c == '\r' -> append("\\r")
                c == '\u2028' -> append("\\u2028")
                c == '\u2029' -> append("\\u2029")
                c < ' ' -> append("\\u").append(c.code.toString(16).padStart(4, '0'))
                else -> append(c)
            }
        }
        append('"')
    }
}
