package app.webvpn.entry

import android.content.Context
import android.os.SystemClock
import android.view.View
import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * **宿主层**的真机测试（2026-09 审计的 A9：这一层原先三端零覆盖）。
 *
 * 为什么这一层必须单独测：状态机（`EntryFlow`）与页面判据（`Sues`）都有 JVM 单测，但
 * **「宿主有没有把它接上」**测不到——判据对了、状态机对了，接线错了照样是坏的。
 * 这里构造**真宿主 + 真 WebView**，用 `loadDataWithBaseURL` 喂自己造的页面（**不联网**、不碰学校），
 * 走的是与线上**同一个** `WebViewClient`、同一套状态机、同一批 `shared/js`。
 *
 * 覆盖三条最容易断的接线：
 *   · A3「停手前先验正文」：门户入口落到没有登录标记的页面时**不得**宣布到达；
 *   · A2「凭据只在门户主机的认证页上填」：反例（别的主机）与正例（门户主机）各一条；
 *   · A7 的接线：解密在后台线程、回主线程才提交——正例能通过就说明这一跳是通的。
 *
 * 不联网是硬要求：`openEntry` 会 `loadUrl` 学校地址，所以这里用 `newTab()` 自己起一页。
 */
@RunWith(AndroidJUnit4::class)
class EntryHostDomTest {

    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private lateinit var prefs: android.content.SharedPreferences
    private lateinit var credentialPrefs: android.content.SharedPreferences
    private lateinit var repository: CredentialRepository
    private lateinit var host: EntryHost

    private var prefsName = ""
    private var credentialPrefsName = ""

    private companion object {
        /** 测试密钥别名前缀：收尾清理按它筛（产品别名不带这个前缀，见 [purgeTestKeystoreAliases]）。 */
        const val HostTestAliasPrefix = "host-test-"
    }

    @Before
    fun setUp() {
        val suffix = System.nanoTime()
        prefsName = "entry-host-test-$suffix"
        credentialPrefsName = "cred-host-test-$suffix"
        prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        credentialPrefs = context.getSharedPreferences(credentialPrefsName, Context.MODE_PRIVATE)
        val backend = AndroidKeyStoreBackend("$HostTestAliasPrefix$suffix")
        repository = CredentialRepository(credentialPrefs, CredentialStore(backend), backend)
        host = EntryHost(context, prefs, repository)
    }

    @After
    fun tearDown() {
        onMain { host.onDestroy() }
        context.deleteSharedPreferences(prefsName)
        context.deleteSharedPreferences(credentialPrefsName)
        // 每个用例都建一把测试密钥（别名带纳秒时间戳），不收就会一直在用户的密钥库里攒
        purgeTestKeystoreAliases(HostTestAliasPrefix)
    }

    // ------------------------------------------------ A3：停手前先验正文（CORE-SPEC §2）

    @Test
    fun 门户入口落到没有登录标记的页面时不宣布到达() {
        val tab = gatewayTab()
        val page = tab.web
        load(tab, portalUrl + "/portal", "<div>请选择要访问的资源</div>")
        awaitLoaded(tab)

        // 宿主会去跑 arrival.js；这一页没有 个人信息 / 注销 / 资源站点
        awaitNotice("正在等待门户加载完成…")
        assertFalse("没验到正文就不该算到达", tab.flow.isSettled)
        assertSamePage(tab, page)
    }

    @Test
    fun 门户入口正文里有登录标记时才停手() {
        val tab = gatewayTab()
        val page = tab.web
        load(tab, portalUrl + "/portal", "<div class=\"card\">资源站点</div>")
        awaitLoaded(tab)

        awaitTrue("正文有标记就该停手") { tab.flow.isSettled }
        assertSamePage(tab, page)
    }

    // ------------------------------------------------ A2：只在门户主机的认证页上碰凭据（CORE-SPEC §6.1）

    @Test
    fun 别的主机上的认证页不会被自动填写() {
        assertTrue("测试凭据要能落盘", repository.save("20250001", "Test-Password-1".toCharArray()))
        val tab = gatewayTab()
        val page = tab.web
        load(tab, "https://jxfw.sues.edu.cn/cas/login", casForm)
        awaitLoaded(tab)

        // 反例没有「正向信号」可等：宿主在这里**正确地什么都不做**，所以只能给足时间
        //（后台解密 + 回主线程）再断言没发生。这是反例唯一诚实的写法。
        SystemClock.sleep(2_500)

        assertEquals("非门户主机上的 /cas/login 不该被碰｜${state(tab)}", 0, tab.autoSubmits)
        assertEquals("更不该记成「这份文档已经填过」｜${state(tab)}", -1, tab.filledDoc)
        assertSamePage(tab, page)
    }

    @Test
    fun 门户主机上的认证页会被自动填写() {
        assertTrue("测试凭据要能落盘", repository.save("20250001", "Test-Password-1".toCharArray()))
        assertNotNull("测试凭据要能读回（否则「没填」说明不了闸的问题）", repository.load())
        val tab = gatewayTab()
        val page = tab.web
        load(tab, portalUrl + "/cas/login", casForm)
        awaitLoaded(tab)

        // 前提：宿主从这一页看到的确实是「有表单的认证页」
        val seen = Sues.casObservation(probePage(tab, PageJs.CAS_STATE))
        assertTrue("这一页应当被识别为有账号密码表单，实际 $seen", seen.hasForm)

        awaitTrue("门户主机上的认证页应当被自动填写并提交｜${state(tab)}") { tab.filledDoc > 0 }
        // 再等一拍：「页面没有提交按钮」那条作废路径会把计数退回去，别把中间那一瞬当成成功
        SystemClock.sleep(1_500)
        assertTrue("填写要站得住，不是被作废的那一瞬｜${state(tab)}", tab.filledDoc > 0)
        assertEquals("恰好替用户提交一次｜${state(tab)}", 1, tab.autoSubmits)
        assertSamePage(tab, page)
    }

    // ------------------------------------------------ 骨架

    private val portalUrl = "https://webvpn.sues.edu.cn"

    /**
     * 一个足够真实的认证页。
     *
     * 提交按钮必须**照实测形态**写：`<input class="login_btn" value="登 录">`（见 `docs/PROTOCOL.md`）。
     * `fill-and-submit.js` 找的是 `input.login_btn, button.login_btn` 且文字含「登录」——夹具里写成
     * `<button type="button">` 时它会返回 `nobutton`，宿主**按设计作废**这次自动提交；
     * 这正是第一版两条正例「偶发通过」的原因：作废路径先把计数 +1、几毫秒后再退回去，
     * 50ms 的轮询偶尔正好采到那一瞬——**假通过**。
     *
     * **基地址里不要带查询串**（另一个踩过的坑）：`loadDataWithBaseURL` 的 baseUrl 带 `?service=x` 时，
     * 这一页根本没有被装载——`webView.url` 停在 `about:blank`、`onPageStarted` 也不来，
     * 于是断言要么失败、要么**平凡通过**（反例那两条就是这么被骗过去的）。
     * 判据本身不需要查询串：`/cas/login` 这个**路径**就够了，带 `?service=…` 的形状由 `SuesTest` 覆盖。
     */
    private val casForm = """
        <form action="#">
          <input id="username" name="username">
          <input id="password" name="password" type="password">
          <input class="login_btn" type="button" value="登 录">
        </form>
    """.trimIndent()

    /**
     * 起一个标签页，并把状态机置于「从首页点了校园网关」的前置上。
     *
     * 这两步就是 `enterFromHome` 做的**除导航外**的部分；不走 `openEntry` 是因为它会真的
     * `loadUrl` 学校地址（测试不该向学校发请求）。
     *
     * 另外两件保险：
     *   · `blockNetworkLoads = true`——**这一份测试不允许有任何网络流量**。宿主的「渲染进程被回收
     *     就重建」那条路会 `loadUrl` 学校地址，把 WebView 的网络直接关掉，非 `data:` 的加载发不出去；
     *   · 手动 measure/layout 给渲染器一个视口（`PageDomTest` 里同样这么做），减少无谓的进程回收。
     */
    private fun gatewayTab(): Tab {
        var tab: Tab? = null
        onMain {
            val created = host.newTab()
            created.web.settings.blockNetworkLoads = true
            created.web.measure(
                    View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(1920, View.MeasureSpec.EXACTLY))
            created.web.layout(0, 0, 1080, 1920)
            created.flow.start(Sues.Entry.WEBVPN, false)
            tab = created
        }
        return tab!!
    }

    /**
     * 宿主在渲染进程被回收时会**换掉** `tab.web`（A6 的恢复路径）。测试里若真发生了，
     * 说明这一轮跑在异常环境上——**说出来**，而不是让断言静默地测到另一页。
     */
    private fun assertSamePage(tab: Tab, original: WebView) =
            assertSame("WebView 被重建了（渲染进程被回收），这一轮结果不可信", original, tab.web)

    /** 把 [body] 当成 [baseUrl] 这一页的正文装载进去——`webView.url` 就是 [baseUrl]。 */
    private fun load(tab: Tab, baseUrl: String, body: String) {
        onMain {
            tab.web.loadDataWithBaseURL(
                    baseUrl, "<html><body>$body</body></html>", "text/html", "utf-8", null)
        }
    }

    /**
     * 前提断言：**这一页真的装载了**（状态机看到了新文档）。
     *
     * 没有它，反例会**平凡通过**——踩过一次：`loadDataWithBaseURL` 的 baseUrl 带查询串时
     * 页面根本没装载，于是「没有自动填写」断言在什么都没发生的页面上当然成立。
     * 每个用例装载之后都要先过这一关。
     */
    private fun awaitLoaded(tab: Tab) =
            awaitTrue("页面应当装载完成（文档序号 > 0）｜${state(tab)}") {
                tab.flow.documentOrdinal > 0
            }

    private fun noticeText(): String {
        var text = ""
        onMain { text = host.notice.text }
        return text
    }

    /**
     * 失败时把**宿主自己看到的东西**打出来。
     *
     * 上一版断言只写「没等到」，查起来只能靠 logcat 猜（而 logcat 会滚掉）；这里一次给全：
     * `webView.url` 与 `documentUrl`（§6.1 主机闸的输入——**两者不一致正是那次查出来的坑**）、
     * 文档序号（状态机认不认这是一份新文档）、两个记账字段、以及状态行。
     */
    private fun state(tab: Tab): String {
        var url = ""
        onMain { url = tab.web.url.orEmpty() }
        return "url=$url docUrl=${tab.documentUrl} doc=${tab.flow.documentOrdinal} " +
                "filledDoc=${tab.filledDoc} autoSubmits=${tab.autoSubmits} " +
                "saveAccount=${host.saveAccount} savedName=${host.savedUsername} " +
                "settled=${tab.flow.isSettled} notice=「${noticeText()}」"
    }

    /** 从测试侧直接问页面一句：宿主看到的那份 DOM 到底是什么样（定位「闸」还是「DOM」的问题）。 */
    private fun probePage(tab: Tab, script: String): String {
        val done = java.util.concurrent.CountDownLatch(1)
        var value = ""
        onMain {
            tab.web.evaluateJavascript(script) { raw ->
                value = raw.orEmpty()
                done.countDown()
            }
        }
        done.await(5, java.util.concurrent.TimeUnit.SECONDS)
        return value.trim().trim('"')
    }

    private fun awaitNotice(expected: String) =
            awaitTrue("状态行应变成「$expected」") { noticeText() == expected }

    /**
     * 有上界地等一个条件成立。判定读的是**宿主的可观察状态**（状态行 / 状态机 / 记账），
     * 不是内部实现细节。
     */
    private fun awaitTrue(what: String, timeoutMs: Long = 8_000, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return
            SystemClock.sleep(50)
        }
        assertTrue("$what（等了 ${timeoutMs}ms 仍未成立）", condition())
    }

    private fun onMain(block: () -> Unit) =
            InstrumentationRegistry.getInstrumentation().runOnMainSync(block)
}
