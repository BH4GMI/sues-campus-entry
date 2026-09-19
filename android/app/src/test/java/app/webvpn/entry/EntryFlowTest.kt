package app.webvpn.entry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 每个标签页各持一份的导航状态机。
 *
 * 这些用例是「多标签页不会互相干扰」的根据：状态的所有权必须在页这一层，
 * 而不是活动那一层。改判据之前先看 `docs/CORE-SPEC.md` §2、§4。
 */
class EntryFlowTest {

    private val prefix =
            "https://webvpn.sues.edu.cn/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b"
    private val ssoUrl = "$prefix/student/sso/login"
    private val jxfwHome = "$prefix/student/home"
    private val casUrl =
            "https://webvpn.sues.edu.cn/https/f3f652d234256d43300d8db9d6562d/cas/login?service=x"
    private val secondLogin = "$prefix/student/login?refer=https://jxfw.sues.edu.cn/student/home"
    private val transient = "https://webvpn.sues.edu.cn/wengine-vpn/failed"

    /** 走一份新文档：开始加载 → 加载完成。 */
    private fun EntryFlow.visit(url: String): EntryFlow.Action {
        onDocumentStarted()
        return onDocumentFinished(url)
    }

    private val expired = Sues.CasObservation(expired = true, hasForm = false, hasCaptcha = true,
            prompt = "根据密码安全策略，您的密码已过期，请及时更新！")
    private val rejected = Sues.CasObservation(expired = false, hasForm = true, hasCaptcha = false,
            prompt = "密码错误。再输错3次，账号将被锁定。")
    private val normalForm = Sues.CasObservation(expired = false, hasForm = true, hasCaptcha = true, prompt = "")

    @Test
    fun 没有缓存前缀时先回门户读前缀() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = false)
        assertEquals(EntryFlow.Action.PROBE_PORTAL, flow.visit(Sues.PORTAL))
    }

    @Test
    fun 用缓存前缀直打教务系统就停手() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        assertEquals(EntryFlow.Action.SETTLE, flow.visit(ssoUrl))
        assertTrue(flow.isSettled)
        // 停手之后用户在教务系统里点来点去，都不再被拽走
        assertEquals(EntryFlow.Action.NOTHING, flow.visit(jxfwHome))
    }

    @Test
    fun 缓存前缀已失效才清前缀() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        assertEquals("直打教务系统却落到不认识的页面", EntryFlow.Action.CLEAR_PREFIX,
                flow.visit("$prefix/something-else"))
    }

    @Test
    fun 经过认证页之后落在门户不算前缀失效() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        assertEquals(EntryFlow.Action.INSPECT_CAS, flow.visit(casUrl))
        // 登录完成后落到门户首页：这时该重新读前缀，而不是把好前缀删掉
        assertEquals(EntryFlow.Action.PROBE_PORTAL, flow.visit("$prefix/"))
    }

    @Test
    fun 停手之后落到换票中转页也不重载() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.WEBVPN, hasCachedPrefix = true)
        assertEquals(EntryFlow.Action.VERIFY_ARRIVAL, flow.visit(Sues.PORTAL))
        assertEquals(EntryFlow.Action.SETTLE, flow.confirmArrival())
        // §4 第 2 条先于第 3 条：停手了就不再有「等它自己跳 + 超时重载」这回事
        assertEquals(EntryFlow.Action.NOTHING, flow.visit(transient))
    }

    @Test
    fun 换票中转页不清前缀等待它自己跳() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        assertEquals(EntryFlow.Action.TRANSIENT, flow.visit(transient))
        assertFalse("中转页不是终点，不能算停手", flow.isSettled)
        assertEquals("随后正常落到教务系统", EntryFlow.Action.SETTLE, flow.visit(jxfwHome))
    }

    @Test
    fun 认证页的三种状态各走各的() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)

        assertEquals(EntryFlow.Action.INSPECT_CAS, flow.visit(casUrl))
        assertEquals("过期优先，先跳过它", EntryFlow.Action.SKIP_EXPIRED, flow.onCasObserved(expired))
        assertEquals("服务端否定凭据：停手不重试", EntryFlow.Action.REJECT_CREDENTIALS, flow.onCasObserved(rejected))
        assertEquals("正常表单：勾记住我 + 装监视器", EntryFlow.Action.ASSIST_CAS, flow.onCasObserved(normalForm))
    }

    @Test
    fun 见过认证页会把停手复位() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        assertEquals(EntryFlow.Action.SETTLE, flow.visit(jxfwHome))
        assertTrue(flow.isSettled)
        // 会话过期被弹回认证页：这时要重新接手
        assertEquals(EntryFlow.Action.INSPECT_CAS, flow.visit(casUrl))
        assertFalse(flow.isSettled)
        assertEquals(EntryFlow.Action.PROBE_PORTAL, flow.visit(Sues.PORTAL))
    }

    @Test
    fun 停手之后不再替用户导航() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.WEBVPN, hasCachedPrefix = true)
        assertEquals("WebVPN 落到门户要先验正文", EntryFlow.Action.VERIFY_ARRIVAL, flow.visit(Sues.PORTAL))
        assertEquals(EntryFlow.Action.SETTLE, flow.confirmArrival())
        // 用户在门户里自己点来点去，不该被应用拽走
        assertEquals(EntryFlow.Action.NOTHING, flow.visit("$prefix/other/page"))
        assertEquals(EntryFlow.Action.NOTHING, flow.visit(secondLogin))
    }

    @Test
    fun 门户入口要先验正文才停手() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.WEBVPN, hasCachedPrefix = true)
        assertEquals(EntryFlow.Action.VERIFY_ARRIVAL, flow.visit(Sues.PORTAL))
        // §2：URL 落在门户主机只说明「到过」，没验正文之前不算到达
        assertFalse(flow.isSettled)
        assertEquals(EntryFlow.Action.SETTLE, flow.confirmArrival())
        assertTrue(flow.isSettled)
        assertEquals(EntryFlow.Action.NOTHING, flow.visit(Sues.PORTAL + "/other"))
    }

    @Test
    fun 教务系统入口按地址形状到达不看门户标记() {
        // 那三个标记是**门户**的（教务系统首页没有它们），所以 /https/<编码>/student/ 那一支
        // 不能被要求验正文——否则主路径永不落定。
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        assertEquals(EntryFlow.Action.SETTLE, flow.visit(jxfwHome))
        assertTrue(flow.isSettled)
    }

    @Test
    fun 二次登录页只提示不自动填() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = false)
        assertEquals(EntryFlow.Action.SECOND_LOGIN, flow.visit(secondLogin))
    }

    @Test
    fun 同一份文档重复回调只处理一次() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        assertEquals(EntryFlow.Action.SETTLE, flow.visit(jxfwHome))
        // onPageFinished 会对同一份文档重复回调，地址逐字节相同，只能靠文档序号去重
        assertEquals(EntryFlow.Action.NOTHING, flow.onDocumentFinished(jxfwHome))
        assertEquals(EntryFlow.Action.NOTHING, flow.onDocumentFinished(jxfwHome))
    }

    @Test
    fun 站点自己开的标签页不劫持用户() {
        val flow = EntryFlow()
        flow.adopt()
        // 门户、教务系统、二次登录页……都不替用户导航
        assertEquals(EntryFlow.Action.NOTHING, flow.visit(Sues.PORTAL))
        assertEquals(EntryFlow.Action.NOTHING, flow.visit(jxfwHome))
        assertEquals(EntryFlow.Action.NOTHING, flow.visit(transient))
        // 但认证页照样辅助：新开的页面如果要登录，一样自动填
        assertEquals(EntryFlow.Action.INSPECT_CAS, flow.visit(casUrl))
        assertEquals(EntryFlow.Action.ASSIST_CAS, flow.onCasObserved(normalForm))
        // 登录完落地也不劫持
        assertEquals(EntryFlow.Action.NOTHING, flow.visit(Sues.PORTAL))
    }

    @Test
    fun 重新点入口会把这一页的状态清干净() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        flow.visit(jxfwHome)
        assertTrue(flow.isSettled)

        flow.start(Sues.Entry.WEBVPN, hasCachedPrefix = true)
        assertFalse("换入口等于重新走一遍", flow.isSettled)
        assertEquals(Sues.Entry.WEBVPN, flow.entry)
        assertEquals(EntryFlow.Action.VERIFY_ARRIVAL, flow.visit(Sues.PORTAL))
    }

    // ------------------------------------------------ 门户探测的自续重试（S1 回归）

    /**
     * 上限的账本住在状态机里，所以这条用例能钉住它。
     * 回归的缺陷：宿主在重试路径上顺手把计数清零 → 上限永远到不了 → 无限轮询，
     * 「没在门户里找到教务系统入口」的提示成了死代码。
     * 循环必须有界：真回归时要"失败"，不能把测试跑成挂死。
     */
    @Test
    fun 门户探测最多自续十五发然后交回用户() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = false)
        assertEquals(EntryFlow.Action.PROBE_PORTAL, flow.visit(Sues.PORTAL))

        var retries = 0
        while (flow.onProbeMissed(Sues.PORTAL) && retries < 100) retries++
        assertEquals(EntryFlow.PROBE_MAX_ATTEMPTS, retries)
    }

    @Test
    fun 换一页会重新计探测次数() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = false)
        repeat(EntryFlow.PROBE_MAX_ATTEMPTS) { assertTrue(flow.onProbeMissed(Sues.PORTAL)) }
        assertFalse(flow.onProbeMissed(Sues.PORTAL))
        // 门户自己跳一步就到新页面：预算应当重来
        assertTrue(flow.onProbeMissed(Sues.PORTAL + "/login"))
    }

    @Test
    fun 重新点入口会把探测次数清零() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = false)
        for (i in 0 until 100) if (!flow.onProbeMissed(Sues.PORTAL)) break
        assertFalse(flow.onProbeMissed(Sues.PORTAL))
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = false)
        assertTrue(flow.onProbeMissed(Sues.PORTAL))
    }

    // ------------------------------------------------ 否定的归因：待判决标志，不是文档序号

    /**
     * 登录提交是整页导航，服务端的否定落在**下一份新文档**上（PROTOCOL §6）。
     * 第一版用「文档序号相等」归因，永远差一——已存凭据被否定时不会删，
     * 留下「每次冷启动自动消耗一次失败次数」直达锁号的隐患。
     */
    @Test
    fun 自动提交后的否定落在下一份文档上也归因给应用() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        flow.visit(casUrl)                       // 认证页（文档 N）
        flow.onCasObserved(normalForm)           // 应用填写并提交
        flow.onAutoSubmitted()                   // 按下登录的那一刻
        flow.onDocumentStarted()                 // 服务端回应是一份新文档（N+1）
        assertEquals(EntryFlow.Action.INSPECT_CAS, flow.onDocumentFinished(casUrl))
        assertEquals(EntryFlow.Action.REJECT_CREDENTIALS, flow.onCasObserved(rejected))
        assertTrue("否定必须归因给应用那次提交", flow.consumeAutoVerdict())
    }

    @Test
    fun 用户自己提交后的否定不归因给应用() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        flow.visit(casUrl)
        flow.onAutoSubmitted()      // 应用提交过一次……
        flow.onUserSubmitted()      // ……但用户随后又自己提交了：判决属于用户
        flow.onDocumentStarted()
        flow.onDocumentFinished(casUrl)
        flow.onCasObserved(rejected)
        assertFalse(flow.consumeAutoVerdict())
    }

    @Test
    fun 判决读走即清_第二次否定不会再次归因给应用() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        flow.visit(casUrl)
        flow.onAutoSubmitted()
        flow.onDocumentStarted()
        flow.onDocumentFinished(casUrl)
        flow.onCasObserved(rejected)
        assertTrue(flow.consumeAutoVerdict())
        // 用户手动改过后还是错：否定还在来，但不能再算到应用头上
        flow.onDocumentStarted()
        flow.onDocumentFinished(casUrl)
        flow.onCasObserved(rejected)
        assertFalse(flow.consumeAutoVerdict())
    }

    @Test
    fun 登录成功与重开流程都会清掉待判决() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        flow.visit(casUrl)
        flow.onAutoSubmitted()
        flow.onDocumentStarted()
        assertEquals(EntryFlow.Action.SETTLE, flow.onDocumentFinished(jxfwHome))
        assertFalse("到达目的地即正面判决", flow.consumeAutoVerdict())

        flow.onAutoSubmitted()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        assertFalse("重开流程即作废", flow.consumeAutoVerdict())
    }

    @Test
    fun 页面没填成就把待判决作废() {
        val flow = EntryFlow()
        flow.start(Sues.Entry.JXFW, hasCachedPrefix = true)
        flow.visit(casUrl)
        flow.onAutoSubmitted()       // 乐观置位……
        flow.onAutoSubmitAborted()   // ……页面没有表单/按钮，根本没提交
        assertFalse(flow.consumeAutoVerdict())
    }
}
