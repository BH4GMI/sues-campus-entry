package app.webvpn.entry

import android.view.View
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * `shared/js` 的 **DOM 层**向量，在真机真实 WebView 上跑。
 *
 * 为什么必须单独有这一份（2026-09 审计的 A10）：`docs/CORE-SPEC.md` §7 里那几条带标签的向量
 * （嵌套 `<div>`、`<br>`、`&amp;`）考的不是「文本怎么判定」，而是**「正文怎么从 DOM 取出来」**
 * ——实现在 `shared/js/cas-state.js` 的 `innerText` 上。原生单测喂进去的是**已经取好的字符串**，
 * 永远碰不到这一步；JVM 里没有 DOM，为几条向量引入 jsdom 那样的库又是白拿一个依赖。
 * 真机上本来就有 WebView，用它跑既不引依赖，又是在**真正的目标引擎**上验证。
 *
 * 这几条同时钉住「别退化成 innerHTML + 正则剥标签」：
 * · 只读第一个子文本节点 → `<br>` 那条会丢掉剩余次数；
 * · 剥标签不还原实体 → `&amp;` 那条的正文会变成 `账号&amp;密码错误`。
 *
 * WebView 是**没有窗口**的（手动 measure/layout 给视口），原因见 [evaluate] 的注释：
 * 这台真机（MIUI）会拦下仪表测试里的 Activity 启动。
 */
@RunWith(AndroidJUnit4::class)
class PageDomTest {

    private val baseUrl = "https://webvpn.sues.edu.cn/"

    @Before
    fun setUp() {
        // 真机上脚本来源就是打进 assets 的那批（见 app/build.gradle 的 assets.srcDir）
        PageJs.prepare(InstrumentationRegistry.getInstrumentation().targetContext.assets)
    }

    // ------------------------------------------------ cas-state.js：正文怎么取出来

    @Test
    fun 嵌套标签不截断正文() {
        val observation = observe(
                "<div id=\"msg1\">密码错误。<div>再输错2次</div>，账号将被锁定。</div>")

        assertEquals("嵌套标签不影响判定", Sues.CasKind.REJECTED, Sues.casKind(observation))
        assertEquals("嵌套标签里的次数要读得出来", 2, Sues.lockoutRemaining(observation.prompt))
    }

    @Test
    fun 换行标签不改变正文也不丢次数() {
        val observation = observe("<div id=\"msg1\">密码错误<br>再输错1次</div>")

        assertEquals(Sues.CasKind.REJECTED, Sues.casKind(observation))
        // 这条是真正的分水岭：只读第一个子文本节点会得到「密码错误」，次数就丢了
        assertEquals("`<br>` 之后的次数必须还在", 1, Sues.lockoutRemaining(observation.prompt))
    }

    @Test
    fun HTML实体要还原成字符() {
        val observation = observe("<div id=\"msg1\">账号&amp;密码错误</div>")

        assertEquals(Sues.CasKind.REJECTED, Sues.casKind(observation))
        // 剥标签不还原实体会得到 `账号&amp;密码错误`：判定也许还对，正文是错的
        assertEquals("实体必须解码", "账号&密码错误", observation.prompt)
    }

    @Test
    fun 过期页的提示走正文而不是错误框() {
        val observation = observe("<div>密码已过期，请重新设置</div>")

        assertEquals("过期优先于表单/滑块", Sues.CasKind.EXPIRED, Sues.casKind(observation))
    }

    @Test
    fun 表单与滑块按真实DOM回报() {
        val withForm = observe(
                "<form><input id=\"username\"><input id=\"password\" type=\"password\"></form>")
        assertTrue("有账号密码框就要看到表单", withForm.hasForm)
        assertEquals(Sues.CasKind.FORM, Sues.casKind(withForm))

        val withCaptcha = observe("<div class=\"ap-container\"></div>")
        assertTrue("有滑块容器就要看到滑块", withCaptcha.hasCaptcha)
        assertEquals(Sues.CasKind.CAPTCHA, Sues.casKind(withCaptcha))
    }

    @Test
    fun 没有错误框时正文为空() {
        val observation = observe("<div>这是一个普通的认证页</div>")

        assertEquals("没有 #msg1 就是空正文，不能拿整页正文当提示", "", observation.prompt)
        assertNull(Sues.lockoutRemaining(observation.prompt))
    }

    // ------------------------------------------------ skip-expired.js：按文字找按钮

    /**
     * APP-UX §4.1 第 5 条改口的那件事：那个按钮的**实测形态是 `<input type=button>`**，
     * 本文档早先写成 `<button>`（按选择器去找就会找不到）。这条向量在真机引擎上把两种形态都跑一遍。
     */
    @Test
    fun 点击跳过要按文字找且认得input形态() {
        val asInput = clickSkip("<input type=\"button\" value=\"点击跳过\">")
        assertEquals("实测形态（input）必须点得到", "clicked|INPUT", asInput)

        val asButton = clickSkip("<button>点击跳过</button>")
        assertEquals("button 形态也要点得到", "clicked|BUTTON", asButton)
    }

    @Test
    fun 找不到跳过按钮时退回重载() {
        // 没有那个按钮 → 脚本自己 reload；这里只要求它别乱点别的元素
        val result = clickSkip("<button>登 录</button><a href=\"#\">忘记密码</a>")

        assertTrue("既不是 clicked 也不是 reloaded：$result", result.startsWith("reloaded") || result == "reloaded")
    }

    // ------------------------------------------------ 真机 WebView 骨架

    private fun observe(body: String): Sues.CasObservation =
            Sues.casObservation(evaluate("<html><body>$body</body></html>", PageJs.CAS_STATE))

    private fun clickSkip(body: String): String =
            evaluate("<html><body>$body</body></html>", PageJs.SKIP_EXPIRED)

    /**
     * 在一个**没有窗口**的 WebView 里装载 [html]（用 `loadDataWithBaseURL`，**不联网**），
     * 跑 [script] 并取回它的返回值。
     *
     * 为什么不借一个 Activity（两种都试过，都不行）：
     *   · 宿主 Activity 放 `src/androidTest` → 它属于**测试 APK 自己的进程**，
     *     `ActivityScenario` 拒绝跨进程启动（真机报 `Intent in process app.webvpn.entry
     *     resolved to different process app.webvpn.entry.test`）；
     *   · 放 debug 变体（同进程）→ 这台真机（MIUI）把它拦下来，日志是硬的：
     *     `ActivityStarterImpl: MIUILOG- Permission Denied Activity KeyguardLocked` 与
     *     `ActivityTaskManager: Abort background activity starts from 10267`。
     *     仪表测试本身就是「后台启动 Activity」，于是 `ActivityScenario.launch` **永远等不到
     *     RESUMED**——UTP 给的超时是一年，表现就是整轮挂死而非失败。
     *
     * 而这一层要验的是 **DOM → 正文**，**不需要窗口，只需要布局**：WebView 用 application context
     * 建出来，手动 `measure` + `layout` 给它一个真实视口，渲染器照样排版。
     * 这一点由最后两条用例自证——若没有真正布局，`skip-expired.js` 里的 `offsetParent !== null`
     * 会让脚本退化成 `reload`，那两条会当场失败。
     */
    private fun evaluate(html: String, script: String): String {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val holder = arrayOfNulls<WebView>(1)
        var result: String? = null
        val pageLoaded = CountDownLatch(1)
        val scriptDone = CountDownLatch(1)

        // WebView 只能在有 Looper 的线程上建；回调也都投递到主线程，所以两段都跑在主线程、
        // 两个 latch 则在**测试线程**上等（在主线程上 await 会与回调互等到超时）。
        instrumentation.runOnMainSync {
            val view = WebView(instrumentation.targetContext)
            view.settings.javaScriptEnabled = true
            view.webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) {
                    pageLoaded.countDown()
                }
            }
            val width = 1080
            val height = 1920
            view.measure(
                    View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            view.layout(0, 0, width, height)
            holder[0] = view
            view.loadDataWithBaseURL(baseUrl, html, "text/html", "utf-8", null)
        }

        assertTrue("页面 30 秒内没加载完", pageLoaded.await(30, TimeUnit.SECONDS))

        instrumentation.runOnMainSync {
            holder[0]!!.evaluateJavascript(script) { value ->
                result = value
                scriptDone.countDown()
            }
        }

        assertTrue("脚本 30 秒内没返回", scriptDone.await(30, TimeUnit.SECONDS))

        instrumentation.runOnMainSync { holder[0]!!.destroy() }

        // 用 Kotlin 的 error()（返回 Nothing）而不是 JUnit 的 fail()（返回 Unit）：后者接不上 elvis。
        // 还要**剥掉 JSON 引号**：`evaluateJavascript` 回传的是 JSON 字面量（`"clicked|INPUT"`），
        // 原生侧 `Sues.casObservation` / `Sues.arrivalMark` 都会先 trim('"')，测试里必须做同一件事
        //（第一版就是漏了这一步：值其实全对，断言全对不上）。
        return (result ?: error("脚本没有返回值")).trim().trim('"')
    }
}
