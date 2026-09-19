package app.webvpn.entry

import android.annotation.SuppressLint
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.util.Base64
import android.util.Log
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.content.Context
import androidx.annotation.VisibleForTesting
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlin.concurrent.thread

/** 底栏正上方那一行状态。 */
data class Notice(
        val text: String,
        val tone: Tone = Tone.PLAIN,
        /** 需要用户出手时不再自动消失。 */
        val sticky: Boolean = false,
        val action: Act? = null,
) {
    enum class Tone { PLAIN, ALERT, DONE }

    /**
     * 状态行上的可点动作（APP-UX §5 的「是否可点」列）。
     *
     * [UNDO_SAVE] 与 [CLEAR_ACCOUNT] 的**效果相同**（清掉本机凭据 + 关掉自动登录），分开只因语境不同、
     * 按钮该写的字不同：刚保存成功是「撤销」，凭据被否定是「清除账号」。
     */
    enum class Act { RETRY, UNDO_SAVE, CLEAR_ACCOUNT }

    companion object {
        val none = Notice("")
    }
}

/**
 * 一个标签页：一个 WebView + **它自己那一份**导航状态。
 *
 * 所有计时器和计数器都必须挂在页上，不能挂在宿主上——否则「A 页的探测重试」会花掉
 * 「B 页的预算」，切换标签页时还会把对方的定时任务顶掉。
 */
class Tab(val id: Int, var web: WebView) {

    val flow = EntryFlow()

    /** 这一页当前替哪个入口服务。可观察：底栏的高亮跟着它走。 */
    var entry by mutableStateOf(Sues.Entry.JXFW)

    /** 标签栏上的标题；页面没给就用主机名。 */
    var title by mutableStateOf("")

    var progress by mutableStateOf(0)
    var loading by mutableStateOf(false)

    /** 服务端否定了凭据：本页不再做任何自动动作，直到用户重新点入口。 */
    var autoStopped = false

    /** 认证页上那份提示文本，用来解析剩余次数。 */
    var lastPrompt: String = ""

    var probeTick: Runnable? = null

    var transientTick: Runnable? = null
    var transientReloads = 0

    var armedTick: Runnable? = null
    var captchaAttempts = 0
    var captchaLastId: String? = null

    var expiredSkips = 0

    /** 用户在官方页面上按下登录那一刻抓到的凭据，**还没定局**：只在内存里。 */
    var pending: Credential? = null
    var pendingTick: Runnable? = null

    /** 哪一份文档是应用自动填的（同一份文档不再重复填；页面侧也据此排除自己那次提交）。 */
    var filledDoc = -1

    /** 本次流程里应用已经替用户提交过几次。服务端累计失败次数、5 次锁号，必须有硬上限。 */
    var autoSubmits = 0

    /** 滑块自动拖动已用尽次数并提示过手动（只提示一次，不刷屏）。 */
    var captchaGaveUp = false

    /** 哪一份文档已经喂过页面显示偏好（同一份文档会重复回调 onPageFinished）。 */
    var tweakedDoc = -1

    /**
     * 「这一串导航已经计过一次文档了」。
     *
     * `onPageStarted` 对同一串导航可能重复回调（表单重投、服务端重定向、分片导航），
     * 而文档序号是 [filledDoc] / [tweakedDoc] 的文档身份。由 `onPageFinished` /
     * `onReceivedError` 复位；PC 用 `NavigationStarting.IsRedirected`、iOS 用同名的
     * `documentCounted`，三端等价。
     */
    var documentCounted = false

    /**
     * **状态机判过的那份文档的 URL**（由导航回调写入，`onPageFinished` 的最终值覆盖 `onPageStarted`）。
     *
     * 为什么不让判据去读 `webView.url`（`tab.web.url`）：那是个**实时属性**，与「状态机当时判的是哪一页」
     * 并不总是同一个值——仪表测试里 `loadDataWithBaseURL` 装载的页面，回调给的 URL 是那个 base URL
     * （状态机据此正确走进了认证页分支），而 `webView.getUrl()` 返回的是 `about:blank`。
     * 于是 `assistCas` 的 §6.1 主机闸会**把一页合法的认证页挡在门外**（表现就是「自动登录静默失效」）。
     * 真实 https 页面上两者一般相等，所以这个坑只在特定装载方式/重定向窗口里露出来——恰恰最难查。
     * PC 与 iOS 用的是各自的「当前源」（`CoreWebView2.Source` / `WKWebView.url`），
     * 这一份把「文档 URL」这件事变成**一个来源**，三端的语义就统一了。
     */
    var documentUrl: String = ""
}

/**
 * 标签页宿主：管每个标签页的 WebView、驱动它们各自的导航状态机、维护界面上要显示的状态。
 *
 * 界面（Compose）只读这里的 `mutableStateOf` / `mutableStateListOf`，不直接碰 WebView。
 */
class EntryHost(
        /**
         * 只需要一个 [Context]（取 assets、建 WebView）。
         *
         * 早先这里写的是 `AppCompatActivity`：那会让宿主**只有 Activity 才能构造**，而仪表测试里
         * 起 Activity 会被系统/厂商拦下（这台 MIUI 真机的日志：`Abort background activity starts`），
         * 于是整层宿主逻辑零覆盖（审计 A9）。收窄成 Context 后，测试可以用 `targetContext` 构造
         * 真宿主 + 真 WebView；生产侧照旧传 Activity。
         */
        private val context: Context,
        private val prefs: SharedPreferences,
        private val repository: CredentialRepository,
) {

    private companion object {
        const val TAG = "教务直达"
        const val KEY_PREFIX = "jxfw_prefix"
        const val KEY_SAVE_ACCOUNT = "save_account"
        const val KEY_SAVE_DECIDED = "save_account_decided"
        const val KEY_HIDE_NOTICES = "hide_notices"

        /** 探测的节奏。**发数上限在 [EntryFlow.PROBE_MAX_ATTEMPTS]**：那是判据，住在状态机里才测得到。 */
        const val PROBE_INTERVAL_MS = 600L
        const val CAPTCHA_MAX_ATTEMPTS = 3

        /**
         * 每次流程里应用替用户提交凭据的硬上限。
         *
         * 正常流程恰好一次（认证页表单）。服务端若不置错误文案、只回一张干净的表单
         * （异常但并非不可能），没有上限的话应用会一份文档接一份文档地填下去——
         * 每一次都在消耗失败次数，直达锁号。留到第二次是给「中间多一张表单页」的
         * 站点改动留余地，超过它就交回用户。
         */
        const val AUTO_SUBMIT_MAX = 2
        const val ARMED_TIMEOUT_MS = 20_000L
        const val TRANSIENT_TIMEOUT_MS = 15_000L
        const val TRANSIENT_MAX_RELOADS = 1
        const val EXPIRED_MAX_SKIPS = 1
        const val NOTICE_TIMEOUT_MS = 2_000L

        /** 抓到的凭据迟迟没有定局就丢弃：不落盘、也不留在内存里。 */
        const val PENDING_TIMEOUT_MS = 90_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private var nextTabId = 1
    private var container: FrameLayout? = null
    private var noticeTick: Runnable? = null

    init {
        // 页面契约 JS 打在 assets 里（来源是仓库根 shared/js）；JVM 单测会换成源码树来源
        PageJs.prepare(context.assets)
        // 密钥库解密 + 读盘不占界面线程（这个构造发生在 onCreate 里）：
        // 「界面线程不做 IO / 密钥库调用」是三端一致的规则，PC 用 Task.Run、iOS 用 detached task。
        thread(name = "cred-load") {
            val name = repository.savedUsername()
            main.post { if (name != null) savedUsername = name }
        }
    }

    // ---------------------------------------------------------------- 界面状态

    val tabs = mutableStateListOf<Tab>()

    var activeId by mutableStateOf(-1)
        private set

    var notice by mutableStateOf(Notice.none)
        private set

    /** 是否还没决定过要不要保存账号（决定过就不再自动显示首页）。 */
    var home by mutableStateOf(!prefs.getBoolean(KEY_SAVE_DECIDED, false))
        private set

    var saveAccount by mutableStateOf(prefs.getBoolean(KEY_SAVE_ACCOUNT, true))
        private set

    /** 已保存的账号（界面打码显示）。**由后台线程读出后回主线程赋值**，所以初值是 null。 */
    var savedUsername by mutableStateOf<String?>(null)
        private set

    var showAccount by mutableStateOf(false)
        private set

    /**
     * 是否把教务系统首页那串「通知公告」卡片收起来。
     *
     * 默认收起：那是用户明确提的要求。判据与安全边界见 [PageJs.noticeCardsJs]——
     * 认不准就什么都不做，所以它不会因为站点改版而误伤别的区块。
     */
    var hideNotices by mutableStateOf(prefs.getBoolean(KEY_HIDE_NOTICES, true))
        private set

    val activeTab: Tab? get() = tabs.firstOrNull { it.id == activeId }

    // ---------------------------------------------------------------- 界面动作

    /** 首页上选了某个入口：记下这次同意，然后进去。 */
    fun enterFromHome(entry: Sues.Entry) {
        prefs.edit()
                .putBoolean(KEY_SAVE_DECIDED, true)
                .putBoolean(KEY_SAVE_ACCOUNT, saveAccount)
                .apply()
        home = false
        openEntry(entry)
    }

    /** 底栏点了某个入口：把**当前**标签页带过去。 */
    fun openEntry(entry: Sues.Entry) {
        val tab = activeTab ?: newTab()
        tab.entry = entry
        tab.flow.start(entry, hasCachedPrefix())
        resetRuntime(tab)
        // APP-UX §5「打开」行：这一跳可能几百毫秒，先说一句正在打开哪个入口
        showNotice(Notice(if (entry == Sues.Entry.WEBVPN) "正在打开校园网关…" else "正在打开教务系统…"))
        val url = Sues.entryUrl(prefix(), entry)
        Log.d(TAG, "[${tab.id}] 打开入口=$entry 落点=$url")
        tab.web.loadUrl(url)
    }

    fun openHome() {
        showAccount = false
        home = true
    }

    fun openAccount() {
        showAccount = true
    }

    fun closeAccount() {
        showAccount = false
    }

    fun changeSaveAccount(on: Boolean) {
        saveAccount = on
        // 只改意愿，不写「已决定」：首页是否出现取决于用户有没有真的进去过（见 enterFromHome）
        prefs.edit().putBoolean(KEY_SAVE_ACCOUNT, on).apply()
        if (!on) {
            tabs.forEach { dropPending(it) }
            showNotice(Notice("已关闭自动登录；已保存的账号还在本机，可以随时清除"))
        }
    }

    /**
     * 收起/恢复站点的「通知公告」弹窗。
     *
     * 立刻在当前页生效，不必等下一次加载；结构与安全边界见 [PageJs.noticeDialogJs]。
     */
    fun changeHideNotices(on: Boolean) {
        hideNotices = on
        prefs.edit().putBoolean(KEY_HIDE_NOTICES, on).apply()
        val tab = activeTab ?: return
        tab.tweakedDoc = -1
        tab.web.evaluateJavascript(PageJs.noticeDialogJs(on)) { result ->
            Log.d(TAG, "[${tab.id}] 通知公告：${if (on) "收起" else "恢复"} -> $result")
        }
    }

    fun clearAccount() {
        repository.clear()
        savedUsername = null
        showAccount = false
        showNotice(Notice("已清除账号", Notice.Tone.DONE))
    }

    /**
     * 清除缓存、退出登录：清掉 WebView 里的会话与缓存，**保留已保存的账号密码**。
     *
     * 登录状态就是 cookie（实测学校的凭证全在 cookie 里，见 `docs/PROTOCOL.md` §5），所以清掉
     * cookie 就等于退出登录。已保存的凭据与「自动登录」意愿都不动——下次打开还会自动填回来，
     * 这正是它和「改用其他账号」的区别。
     */
    fun clearSession() {
        clearWebSession {
            showAccount = false
            openEntry(activeTab?.entry ?: Sues.Entry.JXFW)
            showNotice(Notice("已退出登录；保存的账号还在", Notice.Tone.DONE))
        }
    }

    /** 改用其他账号：清掉会话**和**本机凭据，回首页重新走一遍。 */
    fun switchAccount() {
        repository.clear()
        savedUsername = null
        clearWebSession {
            tabs.forEach { tab -> tab.flow.start(tab.entry, hasCachedPrefix = false) }
            showAccount = false
            home = true
        }
    }

    /**
     * 清掉 WebView 的会话与缓存。
     *
     * 删 cookie 是异步的，必须等回调再往下走：否则紧接着那次加载会带着旧 cookie 出去，
     * 用户看到的就是「点了退出却还是登录状态」。
     */
    private fun clearWebSession(then: () -> Unit) {
        val cookies = CookieManager.getInstance()
        cookies.removeAllCookies { _ ->
            cookies.flush()
            main.post {
                tabs.forEach { tab ->
                    resetRuntime(tab)
                    tab.web.clearCache(true)
                    tab.web.clearHistory()
                }
                then()
            }
        }
    }

    fun switchTo(id: Int) {
        if (tabs.none { it.id == id }) return
        activeTab?.web?.onPause()
        activeId = id
        attachActive()
        activeTab?.web?.onResume()
        showNotice(Notice.none)
    }

    fun closeTab(id: Int) {
        val index = tabs.indexOfFirst { it.id == id }
        if (index < 0) return
        val tab = tabs.removeAt(index)
        release(tab)
        if (tabs.isEmpty()) {
            activeId = -1
            container?.removeAllViews()
            home = true
            return
        }
        if (activeId == id) {
            activeId = tabs[minOf(index, tabs.size - 1)].id
            attachActive()
        }
    }

    fun onNoticeAction() {
        when (notice.action) {
            Notice.Act.RETRY -> activeTab?.let { it.web.reload() }
            Notice.Act.UNDO_SAVE -> {
                repository.clear()
                savedUsername = null
                changeSaveAccount(false)
                showNotice(Notice("已撤销保存", Notice.Tone.DONE))
            }
            Notice.Act.CLEAR_ACCOUNT -> {
                // 与「撤销保存」同一套动作：清掉本机凭据并关掉自动登录
                repository.clear()
                savedUsername = null
                changeSaveAccount(false)
                showNotice(Notice("已清除账号", Notice.Tone.DONE))
            }
            null -> Unit
        }
    }

    // ---------------------------------------------------------------- WebView 宿主

    /** Compose 给出的 WebView 宿主；切换标签页时只是把对应的 WebView 挂上去。 */
    fun attachContainer(view: FrameLayout) {
        container = view
        attachActive()
    }

    private fun attachActive() {
        val host = container ?: return
        val active = activeTab ?: run { host.removeAllViews(); return }
        host.removeAllViews()
        (active.web.parent as? ViewGroup)?.removeView(active.web)
        host.addView(active.web, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    /**
     * 渲染进程被系统回收之后重建这一页的 WebView。
     *
     * **平台契约**：`onRenderProcessGone` 返回后，那个 WebView 实例不可再用（渲染进程已经没了）；
     * 只能换一个实例，再按同一个入口重新加载。标签页的身份（id / 入口）保持不变——用户看到的是
     * 「这一页重新加载」，不是「凭空多了一个标签页」。
     *
     * 顺序要紧：先把计时器与待定凭据清掉（此刻 `tab.web` 还是那个已死的实例，`removeCallbacks`
     * 才落在它自己的 Handler 上；换过实例之后就落错地方了），再销毁、再换新的。
     */
    private fun rebuildWebView(tab: Tab) {
        resetRuntime(tab)
        dropPending(tab)

        val dead = tab.web
        (dead.parent as? ViewGroup)?.removeView(dead)
        dead.removeJavascriptInterface("entry")
        dead.destroy()

        val fresh = WebView(context)
        configure(fresh)
        tab.web = fresh
        fresh.addJavascriptInterface(Bridge(tab), "entry")
        fresh.webViewClient = client(tab)
        fresh.webChromeClient = chrome(tab)
        if (tab.id == activeId) attachActive()

        // 与「重新点入口」同一套复位：状态机从头开始，落点仍用同一个入口
        tab.flow.start(tab.entry, hasCachedPrefix())
        val url = Sues.entryUrl(prefix(), tab.entry)
        Log.w(TAG, "[${tab.id}] 重建 WebView 完成，重新打开 $url")
        fresh.loadUrl(url)
        alert(tab, "页面被系统回收了，已重新加载", null)
    }

    // ---------------------------------------------------------------- 生命周期

    fun onPause() {
        tabs.forEach { it.web.evaluateJavascript(PageJs.CAPTCHA_STOP, null) }
    }

    /**
     * 回到前台：把滑块监视器装回去。
     *
     * [onPause] 停掉它是因为页面计时器不该在后台跑；但回来时若不重装，自动拖滑块就
     * **静默失效**了——页面还在认证页上等滑块，应用却不再管。监视器自带幂等护栏
     * （`__capWatch`），重复注入无害。
     */
    fun onResume() {
        tabs.forEach { it.web.evaluateJavascript(PageJs.CAPTCHA_WATCH, null) }
    }

    fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        noticeTick = null
        tabs.forEach { release(it) }
        tabs.clear()
        activeId = -1
    }

    // ---------------------------------------------------------------- 内部：新建与释放

    /**
     * 开一个新标签页。
     *
     * `internal` + `@VisibleForTesting`：仪表测试（`EntryHostDomTest`）需要一个**不联网**的标签页——
     * 它拿到 tab 后用 `loadDataWithBaseURL` 喂自己造的页面，走的是**同一个** WebViewClient
     * 与同一套状态机。走 `openEntry` 会真的向学校发出请求，测试不能那么做。
     */
    @VisibleForTesting
    internal fun newTab(): Tab {
        val web = WebView(context)
        configure(web)
        val tab = Tab(nextTabId++, web)
        web.addJavascriptInterface(Bridge(tab), "entry")
        web.webViewClient = client(tab)
        web.webChromeClient = chrome(tab)
        tabs.add(tab)
        if (activeId < 0) {
            activeId = tab.id
            attachActive()
        }
        return tab
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configure(web: WebView) = with(web.settings) {
        javaScriptEnabled = true
        domStorageEnabled = true
        useWideViewPort = true
        loadWithOverviewMode = true
        setSupportZoom(true)
        builtInZoomControls = true
        displayZoomControls = false
        javaScriptCanOpenWindowsAutomatically = true
        // 站点会用 window.open / target=_blank 新开页面；不开这个开关就收不到 onCreateWindow，
        // 那些链接会被悄悄丢掉（或者把当前页替换掉，用户就回不去了）。
        setSupportMultipleWindows(true)
        // 校内站点与网关改写后的页面里仍可能夹着 http 资源；与浏览器同样的宽松度，避免整页空白。
        mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
        // 门户是桌面端页面：把 UA 里的 Mobile/Android 对调，让页面给出电脑版布局。
        userAgentString = userAgentString.replace("Mobile", "eliboM").replace("Android", "diordnA")
        // 深色模式下不要把学校页面反色：登录页必须保持原样可读。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            @Suppress("DEPRECATION")
            forceDark = WebSettings.FORCE_DARK_OFF
        }
    }

    private fun release(tab: Tab) {
        resetRuntime(tab)
        dropPending(tab)
        (tab.web.parent as? ViewGroup)?.removeView(tab.web)
        tab.web.removeJavascriptInterface("entry")
        tab.web.destroy()
    }

    /** 把这一页的计时器与计数器全部归零。 */
    private fun resetRuntime(tab: Tab) {
        stopProbeTimer(tab)
        cancelTransient(tab)
        cancelArmed(tab)
        tab.captchaAttempts = 0
        tab.captchaLastId = null
        tab.captchaGaveUp = false
        tab.transientReloads = 0
        tab.expiredSkips = 0
        tab.autoStopped = false
        tab.autoSubmits = 0
        tab.lastPrompt = ""
        tab.filledDoc = -1
        tab.tweakedDoc = -1
        tab.documentCounted = false
        tab.documentUrl = ""
    }

    /**
     * 页面侧的显示偏好。
     *
     * **只在教务系统里生效**：认证页、门户页上一律不动——那里多注入一行脚本，都是在登录流程里
     * 添变量，而我们刚被「在登录流程里想当然」坑过两次。
     */
    private fun applyPagePrefs(tab: Tab, url: String) {
        if (!hideNotices || !Sues.isJxfwPage(url)) return
        // 同一份文档 onPageFinished 会重复回调，只喂一次
        if (tab.tweakedDoc == tab.flow.documentOrdinal) return
        tab.tweakedDoc = tab.flow.documentOrdinal
        tab.web.evaluateJavascript(PageJs.noticeDialogJs(true)) { result ->
            Log.d(TAG, "[${tab.id}] 收起公告弹窗：$result")
        }
    }

    // ---------------------------------------------------------------- 内部：WebView 回调

    private fun client(tab: Tab) = object : WebViewClient() {

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            tab.loading = true
            if (isBlankDocument(url)) return
            // 同一串导航里 onPageStarted 可能重复回调（表单重投、服务端重定向、分片导航），
            // 而**文档序号**是 filledDoc / tweakedDoc 的「文档身份」：多记一次会让
            // 「这份文档我已经填过」失效，白耗一次自动提交额度。
            // 用「一串导航只记一次」把它钉死，由 onPageFinished / onReceivedError 复位——
            // 与 PC 的 `!e.IsRedirected`、iOS 的 `documentCounted` 是同一件事。
            tab.documentUrl = url
            if (!tab.documentCounted) {
                tab.documentCounted = true
                tab.flow.onDocumentStarted()
            }
        }

        override fun onPageFinished(view: WebView, url: String) {
            tab.documentCounted = false
            tab.loading = false
            if (isBlankDocument(url)) return
            // 判据要用**这份文档的 URL**（回调给的），不是 `webView.url` 那个实时属性：见 [documentUrl]
            tab.documentUrl = url
            val action = tab.flow.onDocumentFinished(url)
            Log.d(TAG, "[${tab.id}] onPageFinished $url -> $action")
            run(tab, action)
            applyPagePrefs(tab, url)
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (request.isForMainFrame) {
                // 与 onPageFinished 一样复位「这一串导航记过账了」：失败的主框架导航
                // 也要让下一份文档能重新记账
                tab.documentCounted = false
                alert(tab, "网络不通，请检查后重试", Notice.Act.RETRY)
            }
        }

        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
            // 登录凭据不能经过证书无效的连接；WebView 官方要求取消，且不提供绕过入口。
            handler.cancel()
            alert(tab, "证书校验失败，已停止连接", null)
        }

        /**
         * 渲染进程被系统回收（内存压力下很常见，本应用还要解码整幅滑块图，命中概率不低）。
         *
         * 整页会变白，而且**不会**来 `onPageFinished`——状态机会以为还停在原来那份文档上
         * （停手标志、文档序号、拖动次数全保持旧值），界面上也没有任何出口。
         *
         * 平台契约：返回 `false`（默认）系统会**杀掉整个应用进程**；要自己处置就必须返回 `true`，
         * 并且此后不能再使用这个 WebView 实例。所以这里重建它（见 [rebuildWebView]）。
         * PC 的 `ProcessFailed`、iOS 的 `webViewWebContentProcessDidTerminate` 是同一件事。
         *
         * 注：这个回调与 `RenderProcessGoneDetail` 都是 API 26 起才有，minSdk 24 的设备上不会被调用。
         */
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            Log.w(TAG, "[${tab.id}] 网页进程被系统回收，重建这一页")
            // 平台要求不能在回调栈里直接销毁 WebView：丢到主线程队列的下一轮再重建
            main.post { if (tabs.any { it.id == tab.id }) rebuildWebView(tab) }
            return true
        }
    }

    /**
     * `about:blank`（以及空串）**不是一份页面**，不该进状态机的账。
     *
     * 新建 WebView 的初始空白页也会走 `onPageStarted` / `onPageFinished`。把它记成一份文档，
     * 就会让紧接着那份**真页面**的 `onPageFinished` 被「每份文档只处理一次」的账本吞掉
     * （`EntryFlow` 的 `_handled == _docs`）——表现是**自动登录偶发失效**，而且完全看时序，
     * 日志里只有一条「什么都没发生」。这是 2026-09 做宿主层测试时用真实 WebView 查出来的。
     */
    private fun isBlankDocument(url: String) = url.isEmpty() || url == "about:blank"

    private fun chrome(tab: Tab) = object : WebChromeClient() {

        override fun onConsoleMessage(msg: ConsoleMessage): Boolean {
            // 页面里只有我们自己的脚本会用这个前缀说话（公告弹窗、滑块等），收进日志便于事后核对；
            // 站点自己的 console 输出照旧走 WebView 默认通道，不掺和。
            // 前缀是**跨端协议字符串**，与 shared/js/notice-dialog.js 的 LOG 常量逐字对应。
            // 刻意用 ASCII 技术标识而不是产品显示名：改名不该动协议，改这里必须同时改那一行。
            val text = msg.message()
            if (text.startsWith("campus-entry")) {
                Log.d(TAG, "[${tab.id}] $text")
                return true
            }
            return false
        }

        override fun onProgressChanged(view: WebView?, newProgress: Int) {
            tab.progress = newProgress
        }

        override fun onReceivedTitle(view: WebView?, title: String?) {
            val text = title.orEmpty().trim().ifEmpty {
                tab.web.url?.let { android.net.Uri.parse(it).host }.orEmpty()
            }
            if (text.isNotEmpty()) tab.title = text
        }

        /**
         * 站点要新开标签页（`window.open` / `target="_blank"`）。
         *
         * 用标准做法把请求交给新 WebView（`WebViewTransport`），而不是自己去 `loadUrl`：
         * 站点可能依赖那次跳转的上下文（POST、opener、referer）。
         */
        override fun onCreateWindow(
                view: WebView,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: Message,
        ): Boolean {
            val opened = newTab()
            opened.flow.adopt()
            opened.title = "新标签页"
            (resultMsg.obj as? WebView.WebViewTransport)?.let { transport ->
                transport.webView = opened.web
                resultMsg.sendToTarget()
            }
            switchTo(opened.id)
            Log.d(TAG, "[${tab.id}] 站点新开标签页 → [${opened.id}]，已切过去（共 ${tabs.size} 个）")
            return true
        }

        override fun onCloseWindow(window: WebView) {
            // 页面调 window.close()。**不能在这个回调栈里销毁 WebView**：平台契约要求销毁前
            // 先脱离视图系统，而且这个回调还没返回。丢到主线程队列的下一轮再关
            //（`it.web === window` 的身份判断照旧，避免中途换过实例时关错页）。
            main.post { tabs.firstOrNull { it.web === window }?.let { closeTab(it.id) } }
        }
    }

    // ---------------------------------------------------------------- 内部：状态机的动作

    private fun run(tab: Tab, action: EntryFlow.Action) = when (action) {
        EntryFlow.Action.NOTHING -> Unit
        EntryFlow.Action.INSPECT_CAS -> inspectCas(tab)
        EntryFlow.Action.ASSIST_CAS -> assistCas(tab)
        EntryFlow.Action.SKIP_EXPIRED -> skipExpired(tab)
        EntryFlow.Action.REJECT_CREDENTIALS -> rejectCredentials(tab)
        EntryFlow.Action.TRANSIENT -> onTransient(tab)
        EntryFlow.Action.SETTLE -> settle(tab)
        EntryFlow.Action.CLEAR_PREFIX -> clearPrefix(tab)
        EntryFlow.Action.SECOND_LOGIN -> alert(tab, "这里还要再登录一次，请手动", null)
        EntryFlow.Action.PROBE_PORTAL -> probe(tab)
        EntryFlow.Action.VERIFY_ARRIVAL -> verifyArrival(tab)
    }

    /**
     * 停手前的最后一道判据：**正文**里有没有「确实登录进去了」的标记（`docs/CORE-SPEC.md` §2）。
     * URL 落在门户主机只说明「到过」——换票中转页、门户自己的错误页都满足它。
     * 确认不了就**不宣布到达**（也不清待判决、不落盘凭据），只留一条状态。
     */
    private fun verifyArrival(tab: Tab) {
        tab.web.evaluateJavascript(PageJs.ARRIVAL) { value ->
            val mark = Sues.arrivalMark(value)
            if (mark == null) {
                Log.w(TAG, "[${tab.id}] 门户页正文没有登录成功的标记，暂不算到达：${tab.web.url}")
                notice(tab, Notice("正在等待门户加载完成…"))
                return@evaluateJavascript
            }
            Log.d(TAG, "[${tab.id}] 门户页正文确认到达（标记=$mark）")
            run(tab, tab.flow.confirmArrival())
        }
    }

    private fun inspectCas(tab: Tab) {
        // 「脚本这一跳之间页面换没换」比的是**文档 URL**（由导航回调维护，见 [Tab.documentUrl]），
        // 不是 `webView.url`：后者在初始空白页返回 **null**（平台明文如此），于是
        // `samePage("", null)` 直接为假，认证页的观察结果会被**静默丢掉**——真机上表现为
        // 「认证页不勾记住我、不装监视器、不自动填」，而日志里一条错都没有。
        //
        // 刻意**不**比文档序号：某些装载方式会对**同一份文档**多来一次 `onPageStarted`
        //（序号自增而页面并未更换），比序号会把观察结果误丢——仪表测试里表现为**偶发**失败。
        val url = tab.documentUrl
        tab.web.evaluateJavascript(PageJs.CAS_STATE) { value ->
            if (url.isNotEmpty() && !Sues.samePage(url, tab.documentUrl)) return@evaluateJavascript
            val seen = Sues.casObservation(value)
            Log.d(TAG, "[${tab.id}] 认证页：过期=${seen.expired} 表单=${seen.hasForm}" +
                    " 滑块=${seen.hasCaptcha} 提示=${seen.prompt.take(80)}")
            tab.lastPrompt = seen.prompt
            run(tab, tab.flow.onCasObserved(seen))
        }
    }

    /**
     * 认证页上该做的辅助：勾「记住我」、装监视器、以及（用户已同意且已存凭据时）**填写并提交一次**。
     *
     * 自动填写是这个应用唯一一处「替用户提交凭据」的地方，因此边界写死在这里：
     * 当前文档必须是认证页（由状态机保证）、必须同时有 `#username` 与 `#password`、
     * 每个文档只填一次、每次流程至多 [AUTO_SUBMIT_MAX] 次、而且只有用户明确同意保存账号时才做。
     */
    private fun assistCas(tab: Tab) {
        // §6.1 的第一道闸：只有**学校的**统一身份认证页才允许被辅助。
        // 网关把它改写的第三方页面、教务系统自己的 CAS 形态登录页，路径里同样有 /cas/login；
        // 主机判据在这里一次把关，后面所有「碰凭据」的动作就不必各判一遍。
        // 判的是**状态机判过的那份文档的 URL**（见 Tab.documentUrl），不是 webView.url 那个实时属性。
        val url = tab.documentUrl.ifEmpty { tab.web.url.orEmpty() }
        if (!Sues.isCredentialPage(url)) {
            Log.w(TAG, "[${tab.id}] 这一页不是学校的统一身份认证页，不动它：$url")
            return
        }
        val web = tab.web
        web.evaluateJavascript(PageJs.TICK_NOTICE, null)
        web.evaluateJavascript(PageJs.CAPTCHA_WATCH, null)
        if (saveAccount) web.evaluateJavascript(PageJs.CREDENTIAL_WATCH, null)

        val doc = tab.flow.documentOrdinal
        if (tab.filledDoc == doc) return
        if (!saveAccount) {
            notice(tab, Notice("本次登录不会保存账号", sticky = true))
            return
        }
        if (tab.autoSubmits >= AUTO_SUBMIT_MAX) {
            // 不是重试，是硬上限：连续替用户提交只会消耗失败次数（5 次锁号）
            Log.w(TAG, "[${tab.id}] 自动提交已达上限 ${tab.autoSubmits} 次，交回用户")
            notice(tab, Notice("自动登录没有成功，请手动登录", sticky = true))
            return
        }
        // 解密（KeyStore + AES-GCM）挪到后台线程再回主线程继续：界面线程不做 IO / 密钥库调用。
        // 这一跳也顺手解决了「等密钥库的时候文档可能已经换了」——回到主线程后重新对一次文档身份。
        thread(name = "cred-load-${tab.id}") {
            val credential = repository.load()
            main.post {
                if (credential == null) {
                    notice(tab, Notice("登录一次，之后自动登录", sticky = true))
                    return@post
                }
                if (tab.filledDoc == tab.flow.documentOrdinal) {
                    // 这一跳之间已经替这份文档填过了（或文档没变）：不重复提交
                    credential.clear()
                    return@post
                }
                try {
                    tab.filledDoc = tab.flow.documentOrdinal
                    tab.autoSubmits++
                    // 判决标志先置上：提交的回应是另一份文档（docs/PROTOCOL.md §6），
                    // 等回调再置会来不及。页面上真没表单时再作废。
                    tab.flow.onAutoSubmitted()
                    notice(tab, Notice("正在自动填写账号…"))
                    val password = String(credential.password)
                    web.evaluateJavascript(PageJs.fillAndSubmitJs(credential.username, password)) { result ->
                        val text = result.orEmpty()
                        Log.d(TAG, "[${tab.id}] 自动填写并提交：$text")
                        if (text.contains("noform") || text.contains("nobutton")) {
                            // 页面上没有可填的表单：撤销标记，交给用户
                            tab.filledDoc = -1
                            tab.autoSubmits--
                            tab.flow.onAutoSubmitAborted()
                            notice(tab, Notice("这一页要你手动登录", sticky = true))
                        }
                    }
                } finally {
                    credential.clear()
                }
            }
        }
    }

    private fun skipExpired(tab: Tab) {
        tab.web.evaluateJavascript(PageJs.CAPTCHA_STOP, null)
        if (tab.expiredSkips >= EXPIRED_MAX_SKIPS) {
            Log.w(TAG, "[${tab.id}] 密码已过期：跳过 ${tab.expiredSkips} 次后仍回到这一页，停手")
            alert(tab, "密码已过期，请点页面上的「点击跳过」继续", null)
            return
        }
        tab.expiredSkips++
        notice(tab, Notice("密码已过期，正在跳过…"))
        tab.web.evaluateJavascript(PageJs.SKIP_EXPIRED) { result ->
            Log.d(TAG, "[${tab.id}] 跳过密码过期提示：$result（第 ${tab.expiredSkips} 次）")
        }
    }

    /**
     * 服务端否定了凭据：立刻停手，把页面交回用户。**不重试**——服务端累计失败次数，5 次锁号。
     *
     * 如果这次提交用的就是已存凭据（归因看 [EntryFlow.consumeAutoVerdict] 的待判决标志，
     * 不能看文档序号——提交的回应是**另一份**文档），还要**删掉它并关闭自动登录**：
     * 留着错的凭据，等于每次打开应用都自动替用户消耗一次失败次数。
     *
     * 归因不是已存凭据时（用户手动输错），用户仍同意保存账号——这时要在否定页上
     * **重新装上凭据监视器**：用户改对密码再登一次，理应被捕获到（首登承诺才算兑现）。
     */
    private fun rejectCredentials(tab: Tab) {
        tab.autoStopped = true
        stopProbeTimer(tab)
        cancelTransient(tab)
        cancelArmed(tab)
        tab.web.evaluateJavascript(PageJs.CAPTCHA_STOP, null)
        dropPending(tab)

        val usedSaved = tab.flow.consumeAutoVerdict()
        if (usedSaved) {
            repository.clear()
            savedUsername = null
            changeSaveAccount(false)
            Log.w(TAG, "[${tab.id}] 已存凭据被服务端否定，已删除并关闭自动登录")
        }
        if (saveAccount) {
            // 用户手动输错：监视器继续留着，改对的那次提交照样捕获
            tab.web.evaluateJavascript(PageJs.CREDENTIAL_WATCH, null)
        } else {
            tab.web.evaluateJavascript(PageJs.CREDENTIAL_STOP, null)
        }
        val remaining = Sues.lockoutRemaining(tab.lastPrompt)
        Log.d(TAG, "[${tab.id}] 凭据被否定（来自已存凭据=$usedSaved，剩余=${remaining ?: "未说明"}），停手")
        // 文案分两段：先说是哪种否定，再按 APP-UX §5「剩余次数」那行**追加**次数信息。
        // 措辞规则（含 N ≤ 1 的改口）在 Sues.remainingClause 里，能被单测钉住。
        val head = if (usedSaved) "保存的账号已失效，请手动登录" else "账号或密码不对，请手动登录"
        val tail = Sues.remainingClause(remaining).orEmpty()
        // 动作也照 APP-UX §5 的「是否可点」列：用已存凭据 →「清除账号」，手动输错 →「重试」
        alert(tab, head + tail, if (usedSaved) Notice.Act.CLEAR_ACCOUNT else Notice.Act.RETRY)
    }

    private fun settle(tab: Tab) {
        cancelTransient(tab)
        val pending = tab.pending
        tab.pending = null
        cancelPending(tab)
        if (pending != null) {
            // 加密（KeyStore）+ 同步落盘（commit）挪到后台线程，结果回主线程再更新界面状态：
            // 界面线程不做 IO / 密钥库调用（PC 用 Task.Run、iOS 用 detached task）。
            thread(name = "cred-save-${tab.id}") {
                val saved = try {
                    repository.save(pending.username, pending.password)
                } finally {
                    pending.clear()
                }
                main.post {
                    savedUsername = if (saved) pending.username else null
                    Log.d(TAG, "[${tab.id}] 登录成功，保存账号=${mask(pending.username)} 落盘=$saved")
                    notice(tab, Notice(
                            if (saved) "已记住账号，下次自动登录" else "账号没能保存，请重试",
                            if (saved) Notice.Tone.DONE else Notice.Tone.ALERT,
                            sticky = !saved,
                            action = if (saved) Notice.Act.UNDO_SAVE else null))
                }
            }
        } else {
            Log.d(TAG, "[${tab.id}] 已到目的地，停手：${tab.web.url}")
            notice(tab, Notice("已进入教务系统", Notice.Tone.DONE))
        }
    }

    private fun clearPrefix(tab: Tab) {
        // 直打教务系统却落到不认识的页面，而且本次没经过认证页：编码已经不认了。
        prefs.edit().remove(KEY_PREFIX).apply()
        alert(tab, "入口地址已失效，已清除记录；请点「教务系统」重新进入", null)
    }

    private fun onTransient(tab: Tab) {
        notice(tab, Notice("正在跳转…"))
        if (tab.transientTick != null || tab.transientReloads >= TRANSIENT_MAX_RELOADS) return
        val tick = Runnable {
            tab.transientTick = null
            if (Sues.isTransientPage(tab.web.url.orEmpty())) {
                tab.transientReloads++
                Log.d(TAG, "[${tab.id}] 中转页停留超时，重载一次")
                tab.web.reload()
            }
        }
        tab.transientTick = tick
        tab.web.postDelayed(tick, TRANSIENT_TIMEOUT_MS)
    }

    // ---------------------------------------------------------------- 内部：探索门户

    private fun probe(tab: Tab) {
        // 与 inspectCas 同一个道理：比**文档 URL**，不比 `webView.url`（可能是 null），也不比文档序号
        //（同一份文档可能多来一次 onPageStarted）
        val url = tab.documentUrl.ifEmpty { tab.web.url.orEmpty() }
        tab.web.evaluateJavascript(PageJs.PROBE) { value ->
            if (url.isNotEmpty() && !Sues.samePage(url, tab.documentUrl)) return@evaluateJavascript
            val prefix = Sues.prefixFrom(Sues.probeHref(value), url)
            if (prefix == null) {
                // 「还要不要再探一发」由状态机说了算，宿主只排任务。
                // 上限的账本与判据在同一层（EntryFlow），所以它能被单测钉住。
                if (tab.flow.onProbeMissed(url)) {
                    postProbe(tab)
                } else {
                    Log.w(TAG, "[${tab.id}] 门户探测已达上限 ${EntryFlow.PROBE_MAX_ATTEMPTS} 发，交回用户")
                    alert(tab, "没在门户里找到教务系统入口，请自行点击", null)
                }
                return@evaluateJavascript
            }
            prefs.edit().putString(KEY_PREFIX, prefix).apply()
            Log.d(TAG, "[${tab.id}] 读到教务系统前缀=$prefix")
            tab.web.loadUrl(prefix + Sues.SSO_PATH)
        }
    }

    private fun postProbe(tab: Tab) {
        val tick = Runnable {
            tab.probeTick = null
            probe(tab)
        }
        tab.probeTick = tick
        tab.web.postDelayed(tick, PROBE_INTERVAL_MS)
    }

    // ---------------------------------------------------------------- 内部：滑块

    private fun onArmed(tab: Tab, armed: Boolean, expectsSlide: Boolean) {
        if (tab.autoStopped) return
        if (armed) {
            // armed=true 的含义就是「这一页的滑块归应用管」，两种文档形态都会到这里：
            //   · 「独立滑动文档」（没有 #password）一渲染出 .ap-container 就 armed；
            //   · 「表单与滑块同页」在**真实 submit** 之后 armed（页面脚本监听 submit，不轮询）。
            // 早先这里额外要求 expectsSlide——而它表示「这份文档没有密码框」，于是同页那一形态
            // 提交后两个分支都不命中：不拖、不提示、不超时，captchaAttempts 永不增长。
            // 判据只有一个：armed。expectsSlide 留下来只做诊断（日志一眼看出当前是哪种形态）。
            if (tab.captchaAttempts >= CAPTCHA_MAX_ATTEMPTS) {
                // 预算已经用尽：不要再宣称「正在自动完成安全验证…」——那是句谎话
                if (!tab.captchaGaveUp) {
                    tab.captchaGaveUp = true
                    alert(tab, "自动验证已达上限，请手动拖动", null)
                }
                return
            }
            Log.d(TAG, "[${tab.id}] 接管滑块（同页表单=${!expectsSlide}，已拖 ${tab.captchaAttempts} 次）")
            notice(tab, Notice("正在自动完成安全验证…", sticky = true))
            val tick = Runnable {
                tab.armedTick = null
                alert(tab, "验证没能自动完成，请手动拖动", null)
            }
            cancelArmed(tab)
            tab.armedTick = tick
            tab.web.postDelayed(tick, ARMED_TIMEOUT_MS)
        } else {
            // 只撤超时定时器，不清状态行：监视器第一次上报必然是 armed=false
            //（页面有密码框、还没提交），把它当成「收起提示」会把「登录一次，之后
            // 自动登录」这类本该留下的提示在 400ms 内擦掉。提示由后续的判决
            //（成功/失败/到期）来替换，滑块监视器不拥有状态行。
            cancelArmed(tab)
        }
    }

    private fun onCaptcha(tab: Tab, background: String, slider: String) {
        val id = "$background|$slider"
        if (id == tab.captchaLastId) return
        tab.captchaLastId = id
        if (tab.captchaAttempts >= CAPTCHA_MAX_ATTEMPTS) {
            // 用尽后换新图也不能装作没事：明确交回用户一次（只说一次）
            if (!tab.captchaGaveUp) {
                tab.captchaGaveUp = true
                main.post { alert(tab, "自动验证已达上限，请手动拖动", null) }
            }
            return
        }
        thread(name = "slider-${tab.id}") {
            // 两张位图必须**成对**回收：解码第二张失败、或求解抛异常时，第一张也不能漏
            //（PC 用 try/finally、iOS 用 defer，这里是同一件事）。
            var bg: Bitmap? = null
            var sl: Bitmap? = null
            val x: Int? = try {
                val b = decode(background) ?: return@thread
                bg = b
                val s = decode(slider) ?: return@thread
                sl = s
                SliderSolver.solve(pixels(b), b.width, b.height, pixels(s), s.width, s.height)
            } catch (e: Exception) {
                // 裸线程里的未捕获异常会终止整个进程：求解出错按「没算出来」处理，交给用户手动拖
                Log.w(TAG, "[${tab.id}] 滑块求解出错", e)
                null
            } finally {
                bg?.recycle()
                sl?.recycle()
            }
            if (x == null) {
                main.post { alert(tab, "验证没能自动完成，请手动拖动", null) }
                return@thread
            }
            // 这一跳之间用户可能已经关掉/切走这一页：标签页没了就不要再碰它的 WebView
            main.post { if (!tab.autoStopped && tabs.any { it.id == tab.id }) dragTo(tab, x) }
        }
    }

    /**
     * 把缺口偏移 [x] 换成一次拖动。
     *
     * 几何从页面上量（[PageJs.SLIDER_GEOMETRY]），换算在 [SliderDrag] 里算——那段算术必须能被
     * 单测覆盖。它曾经只写在注入的 JS 字面量里，于是「把提交值域当成滑轨长度」这种 5% 的系统性
     * 偏差在电脑上一条测试都拦不住，一路活到了真机上（三次拖动全部偏短）。
     */
    private fun dragTo(tab: Tab, x: Int) {
        tab.web.evaluateJavascript(PageJs.SLIDER_GEOMETRY) { raw ->
            when (val probe = SliderDrag.probe(raw)) {
                is SliderDrag.Probe.Failed -> {
                    Log.w(TAG, "[${tab.id}] 量不到滑块几何：${probe.reason}")
                    alert(tab, "验证没能自动完成，请手动拖动", null)
                }
                is SliderDrag.Probe.Ready -> {
                    val geometry = probe.geometry
                    val plan = SliderDrag.plan(x, geometry)
                    if (plan == null) {
                        Log.w(TAG, "[${tab.id}] 换算不出光标位置：缺口=$x 几何=$geometry")
                        alert(tab, "验证没能自动完成，请手动拖动", null)
                        return@evaluateJavascript
                    }
                    tab.captchaAttempts++
                    cancelArmed(tab)
                    Log.d(TAG, "[${tab.id}] 缺口=$x 光标=${plan.cursor}（当前 ${geometry.cursorNow}）" +
                            " 预计提交=${plan.submitted} 位移=${plan.delta}" +
                            " 滑轨=${geometry.slidingScope} 值域=${geometry.cutScope}" +
                            " 容器宽=${geometry.containerWidth} 图宽=${geometry.backgroundWidth}" +
                            " 一致=${geometry.containerMatchesImage}")
                    tab.web.evaluateJavascript(PageJs.dragJs(plan)) { result ->
                        Log.d(TAG, "[${tab.id}] 拖动结果=$result（第 ${tab.captchaAttempts} 次）")
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- 内部：凭据

    /**
     * 用户在官方页面上按下登录，页面把值交了过来。
     *
     * 这里再做一次同意校验：**用户没同意保存时一律丢弃**（页面侧虽然也判过，但这件事不能只靠一侧）。
     */
    private fun onCredentialCaptured(tab: Tab, username: String, password: String) {
        // 第二重校验（第一重是同意与否）：**当前文档必须真的是学校的统一身份认证页**。
        // 页面侧的监视器只装在那种页面上，但这一条不能只靠页面侧——页面脚本可以主动伪造一次提交。
        // 判的是**状态机判过的那份文档的 URL**（见 Tab.documentUrl）：用 `webView.url` 这个实时属性，
        // 一旦它正好是 about:blank 或还在跳转，用户**真实输入**的凭据会被静默丢弃
        //（症状就是「明明勾了记住账号，下次还要重登」）。
        val url = tab.documentUrl.ifEmpty { tab.web.url.orEmpty() }
        if (!Sues.isCredentialPage(url)) {
            Log.w(TAG, "[${tab.id}] 当前文档不是学校的统一身份认证页，丢弃抓到的凭据：$url")
            return
        }
        if (!saveAccount) {
            Log.d(TAG, "[${tab.id}] 用户未同意保存账号，丢弃抓到的凭据")
            return
        }
        if (tab.filledDoc == tab.flow.documentOrdinal) {
            Log.d(TAG, "[${tab.id}] 这次提交是应用自己填的，不必重复保存")
            return
        }
        if (username.isBlank() || password.isEmpty()) return

        // 用户本人的提交：此后服务端的判决不再属于应用那次自动提交
        tab.flow.onUserSubmitted()
        dropPending(tab)
        tab.pending = Credential(username, password.toCharArray())
        val tick = Runnable {
            tab.pendingTick = null
            Log.d(TAG, "[${tab.id}] 抓到的凭据 ${PENDING_TIMEOUT_MS / 1000} 秒内没有定局，丢弃")
            dropPending(tab)
        }
        tab.pendingTick = tick
        main.postDelayed(tick, PENDING_TIMEOUT_MS)
        Log.d(TAG, "[${tab.id}] 抓到账号=${mask(username)}，等登录结果再决定是否保存")
    }

    private fun dropPending(tab: Tab) {
        cancelPending(tab)
        tab.pending?.clear()
        tab.pending = null
    }

    /** 日志与界面上的账号一律打码：别人从旁边扫一眼看不到完整学号。 */
    private fun mask(username: String): String =
            if (username.length <= 4) "****" else username.take(4) + "****"

    // ---------------------------------------------------------------- 内部：计时器

    /**
     * 只停探测定时器，**不碰重试计数**——计数在 [EntryFlow] 里，由状态机按 URL 自己管。
     *
     * 2026-09-20 修：早先这里把「停定时器」与「清计数」合成一个 `cancelProbe`，重试路径顺手调了它，
     * 于是计数每轮被清零、上限永远到不了，「没找到入口」的提示成了死代码。根因是职责混装 +
     * 宿主层没有测试；现在两件事分开，账本住在可单测的状态机里。
     */
    private fun stopProbeTimer(tab: Tab) {
        tab.probeTick?.let { tab.web.removeCallbacks(it) }
        tab.probeTick = null
    }

    private fun cancelTransient(tab: Tab) {
        tab.transientTick?.let { tab.web.removeCallbacks(it) }
        tab.transientTick = null
    }

    private fun cancelArmed(tab: Tab) {
        tab.armedTick?.let { tab.web.removeCallbacks(it) }
        tab.armedTick = null
    }

    private fun cancelPending(tab: Tab) {
        tab.pendingTick?.let { main.removeCallbacks(it) }
        tab.pendingTick = null
    }

    // ---------------------------------------------------------------- 内部：状态行

    /** 状态行只服务**当前**标签页：后台页的动作不打扰用户，只写日志。 */
    private fun notice(tab: Tab, value: Notice) {
        if (tab.id != activeId) return
        showNotice(value)
    }

    private fun alert(tab: Tab, text: String, action: Notice.Act?) {
        notice(tab, Notice(text, Notice.Tone.ALERT, sticky = true, action = action))
    }

    private fun showNotice(value: Notice) {
        noticeTick?.let { main.removeCallbacks(it) }
        noticeTick = null
        notice = value
        if (value.text.isNotEmpty() && !value.sticky) {
            val tick = Runnable { if (notice === value) notice = Notice.none }
            noticeTick = tick
            main.postDelayed(tick, NOTICE_TIMEOUT_MS)
        }
    }

    // ---------------------------------------------------------------- 内部：杂项

    private fun prefix(): String? = prefs.getString(KEY_PREFIX, null)

    private fun hasCachedPrefix(): Boolean = prefix() != null

    private fun decode(dataUrl: String): Bitmap? = try {
        val base64 = if (dataUrl.startsWith("data:")) dataUrl.substringAfter(',', "") else dataUrl
        if (base64.isEmpty()) {
            null
        } else {
            val bytes = Base64.decode(base64, Base64.DEFAULT)
            // 不预乘 alpha：保住滑块 PNG 半透明边缘的 RGB（与参考实现一致）
            android.graphics.BitmapFactory.decodeByteArray(
                    bytes, 0, bytes.size,
                    android.graphics.BitmapFactory.Options().apply { inPremultiplied = false })
        }
    } catch (e: Exception) {
        Log.w(TAG, "验证码图片解码失败", e)
        null
    }

    private fun pixels(bitmap: Bitmap): IntArray {
        val out = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(out, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return out
    }

    /** 页面侧通过 `window.entry` 回调进来。每个标签页一个实例，回调必须落在它自己那一页上。 */
    private inner class Bridge(private val tab: Tab) {

        @JavascriptInterface
        fun armed(armed: Boolean, expectsSlide: Boolean) {
            main.post { onArmed(tab, armed, expectsSlide) }
        }

        @JavascriptInterface
        fun captcha(background: String, slider: String) {
            // 与 armed/credential 一样回主线程：**JavaBridge 线程不是主线程**，而
            // captchaLastId / captchaAttempts / captchaGaveUp 都是「这一页的状态」，
            // 只能有一个线程碰（主线程）。这里原来直接调 onCaptcha，是三个回调里唯一的例外。
            main.post { onCaptcha(tab, background, slider) }
        }

        @JavascriptInterface
        fun credential(username: String, password: String) {
            main.post { onCredentialCaptured(tab, username, password) }
        }

        @JavascriptInterface
        fun log(message: String) {
            Log.d(TAG, "[${tab.id}] $message")
        }
    }
}
