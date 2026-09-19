package app.webvpn.entry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 落点与页面身份判断。这些规则来自实测（见 `docs/PROTOCOL.md`），改之前先看那份文档。
 */
class SuesTest {

    /** 真实前缀的形状：网关按目标主机算出来的编码，代码里不认任何具体取值。 */
    private val prefix =
            "https://webvpn.sues.edu.cn/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b"
    private val ssoUrl = "$prefix/student/sso/login"
    private val jxfwHome = "$prefix/student/home"
    private val casUrl =
            "https://webvpn.sues.edu.cn/https/f3f652d234256d43300d8db9d6562d/cas/login?service=x"

    @Test
    fun 没有前缀时两个入口的落点() {
        assertEquals(Sues.PORTAL, Sues.entryUrl(null, Sues.Entry.JXFW))
        assertEquals(Sues.PORTAL, Sues.entryUrl(null, Sues.Entry.WEBVPN))
    }

    @Test
    fun 记得前缀时教务系统直打SSO支点() {
        assertEquals(ssoUrl, Sues.entryUrl(prefix, Sues.Entry.JXFW))
        assertFalse("门户卡片那条 /student/home 要二次登录，不能用", Sues.entryUrl(prefix, Sues.Entry.JXFW).endsWith("/student/home"))
    }

    @Test
    fun webvpn入口永远是门户首页() {
        assertEquals(Sues.PORTAL, Sues.entryUrl(prefix, Sues.Entry.WEBVPN))
    }

    @Test
    fun 前缀只认形状且换编码同样成立() {
        assertTrue(Sues.isPrefix(prefix))
        assertTrue(Sues.isPrefix("https://webvpn.sues.edu.cn/https/0123456789abcdef"))
        assertTrue(Sues.isPrefix("http://webvpn.sues.edu.cn/https/abc123"))
        for (bad in listOf(
                "",
                "https://webvpn.sues.edu.cn",
                "https://webvpn.sues.edu.cn/https/",
                "https://webvpn.sues.edu.cn/https/zzzz",
                "$prefix/student/home",
                "webvpn.sues.edu.cn/https/abc123",
                "/https/abc123")) {
            assertFalse("不该认：$bad", Sues.isPrefix(bad))
        }
    }

    @Test
    fun 从门户给的地址推前缀() {
        assertEquals(prefix, Sues.prefixFrom("/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b/student/home", Sues.PORTAL))
        assertEquals(prefix, Sues.prefixFrom(jxfwHome, Sues.PORTAL))
        assertNull("老教务走 /http/，不是教务系统入口", Sues.prefixFrom("/http/faef598869237d556d468ca88d1b203b/eams/index.action", Sues.PORTAL))
        assertNull(Sues.prefixFrom(null, Sues.PORTAL))
        assertNull(Sues.prefixFrom("", Sues.PORTAL))
    }

    @Test
    fun 页面身份() {
        assertTrue(Sues.isCasPage(casUrl))
        assertFalse(Sues.isCasPage(ssoUrl))

        assertTrue(Sues.isJxfwPage(jxfwHome))
        assertTrue(Sues.isJxfwPage(ssoUrl))
        assertFalse("认证页在 cas 编码下，不是教务系统", Sues.isJxfwPage(casUrl))
        assertFalse("老教务 /http/ 不算", Sues.isJxfwPage("https://webvpn.sues.edu.cn/http/abc123/eams/index.action"))

        assertTrue(Sues.isSecondLoginPage("$prefix/student/login?refer=https://jxfw.sues.edu.cn/student/home"))
        assertFalse("SSO 支点不是二次登录页", Sues.isSecondLoginPage(ssoUrl))
    }

    @Test
    fun 解析探测结果() {
        assertEquals("/https/abc123/student/home", Sues.probeHref("\"portal|/https/abc123/student/home\""))
        // evaluateJavascript 回传的是 JSON 字符串，斜杠可能被转义成 \/
        assertEquals(jxfwHome, Sues.probeHref("portal|" + jxfwHome.replace("/", "\\/")))
        assertNull(Sues.probeHref("other"))
        assertNull(Sues.probeHref("expired"))
        assertNull(Sues.probeHref(null))
        assertNull(Sues.probeHref("portal|"))
    }

    @Test
    fun 拆主机与路径() {
        assertEquals("webvpn.sues.edu.cn", Sues.hostOf(casUrl))
        assertEquals("/wengine-vpn/failed", Sues.pathOf("https://webvpn.sues.edu.cn/wengine-vpn/failed"))
        assertEquals("", Sues.pathOf(Sues.PORTAL))
        assertEquals("", Sues.hostOf(""))
        assertEquals("", Sues.pathOf(""))
    }

    @Test
    fun 换票中转页必须带主机名才认() {
        assertTrue(Sues.isTransientPage("https://webvpn.sues.edu.cn/wengine-vpn/failed"))
        assertTrue(Sues.isTransientPage("https://webvpn.sues.edu.cn/wengine-vpn/failed?x=1"))
        assertFalse("门户首页不是中转页", Sues.isTransientPage(Sues.PORTAL))
        assertFalse("别的站点上恰好同名的路径不算", Sues.isTransientPage("https://example.com/wengine-vpn/failed"))
        assertFalse(Sues.isTransientPage(""))
    }

    @Test
    fun 剩余次数是追加的一句且N不大于一时改口() {
        assertNull(Sues.remainingClause(null))
        assertEquals("；还可以试 3 次", Sues.remainingClause(3))
        assertEquals("；还可以试 2 次", Sues.remainingClause(2))
        assertEquals("；再错一次就锁定了，请先确认密码", Sues.remainingClause(1))
        assertEquals("；再错一次就锁定了，请先确认密码", Sues.remainingClause(0))
    }

    @Test
    fun 到达判据只认正文里那三个标记() {
        assertEquals("个人信息", Sues.arrivalMark("\"arrival|个人信息\""))
        assertEquals("注销", Sues.arrivalMark("arrival|注销"))
        assertEquals("资源站点", Sues.arrivalMark("arrival|资源站点"))
        // 没命中 / 脚本出错 / 形状不认得：一律「没确认」，不猜
        assertNull(Sues.arrivalMark("arrival|none"))
        assertNull(Sues.arrivalMark("arrival|err"))
        assertNull(Sues.arrivalMark("arrival|"))
        assertNull(Sues.arrivalMark("null"))
        assertNull(Sues.arrivalMark(null))
    }

    @Test
    fun 中转页既不是教务系统也不是认证页() {
        val url = "https://webvpn.sues.edu.cn/wengine-vpn/failed"
        assertFalse(Sues.isCasPage(url))
        assertFalse(Sues.isJxfwPage(url))
        assertFalse(Sues.isSecondLoginPage(url))
    }

    @Test
    fun 凭据页必须是门户主机() {
        assertTrue(Sues.isCredentialPage(casUrl))
        assertFalse(Sues.isCredentialPage("https://jxfw.sues.edu.cn/cas/login?service=x"))
        assertFalse(Sues.isCredentialPage("https://example.com/cas/login"))
        // 只是身份判据变了没变：路径对就算认证页，但不算凭据页
        assertTrue(Sues.isCasPage("https://example.com/cas/login"))
        assertFalse(Sues.isCredentialPage("$prefix/student/home"))
    }

    @Test
    fun 密码错误只看文案不看地址() {
        // 认证页提交前后的地址逐字节相同，所以身份只能是内容
        assertTrue(Sues.hasCredentialError("密码错误。再输错3次，账号将被锁定。"))
        assertTrue(Sues.hasCredentialError("密码不正确"))
        assertTrue(Sues.hasCredentialError("用户名或密码错误"))
        assertTrue(Sues.hasCredentialError("账号&密码错误"))
        assertTrue(Sues.hasCredentialError("用户不存在"))
        assertFalse("密码过期是另一条路径，不消耗失败次数", Sues.hasCredentialError("密码已过期"))
        assertFalse(Sues.hasCredentialError("请输入用户名"))
        assertFalse(Sues.hasCredentialError(""))
    }

    @Test
    fun 密码过期按正文判定() {
        assertTrue(Sues.isPasswordExpired("根据密码安全策略，您的密码已过期，请及时更新！"))
        assertFalse(Sues.isPasswordExpired("密码错误。再输错3次，账号将被锁定。"))
    }

    @Test
    fun 解析剩余次数不写死句式() {
        assertEquals(3, Sues.lockoutRemaining("密码错误。再输错3次，账号将被锁定。"))
        assertEquals(2, Sues.lockoutRemaining("密码错误。 再输错2次 ，账号将被锁定。"))
        assertEquals(1, Sues.lockoutRemaining("密码错误 再输错1次"))
        assertEquals(2, Sues.lockoutRemaining("还可尝试2次"))
        assertEquals(1, Sues.lockoutRemaining("剩余1次"))
        assertNull("没有次数信息", Sues.lockoutRemaining("密码错误，请重试。"))
        assertNull("与失败次数无关的数字不算", Sues.lockoutRemaining("请在30次心跳内完成"))
        assertNull(Sues.lockoutRemaining(""))
    }

    @Test
    fun 剩余一次就必须硬性阻断() {
        assertTrue(Sues.isLockoutCritical(0))
        assertTrue(Sues.isLockoutCritical(1))
        assertFalse(Sues.isLockoutCritical(2))
        assertFalse("解析不到次数时不阻断，但依旧不重试", Sues.isLockoutCritical(null))
    }

    @Test
    fun 解析认证页观察值() {
        val seen = Sues.casObservation("\"obs|0|1|0|密码错误。再输错3次，账号将被锁定。\"")
        assertFalse(seen.expired)
        assertTrue(seen.hasForm)
        assertFalse(seen.hasCaptcha)
        assertEquals("密码错误。再输错3次，账号将被锁定。", seen.prompt)
        assertEquals(3, Sues.lockoutRemaining(seen.prompt))

        // 提示文本里带竖线也不能被截断：只切前四个竖线，其余原样留在文本里
        assertEquals("a|b", Sues.casObservation("obs|0|0|0|a|b").prompt)

        assertTrue(Sues.casObservation("obs|1|0|1|").expired)
        val nothing = Sues.CasObservation(false, false, false, "")
        assertEquals(nothing, Sues.casObservation("other"))
        assertEquals(nothing, Sues.casObservation(null))
        assertEquals(nothing, Sues.casObservation(""))
    }

    @Test
    fun 过期优先于提示文本() {
        // 真机教过一次：过期提示的文案本身写在 #msg1 / .form-error 里，所以「先看有没有提示文本」
        // 会把它整个挡住——页面上明明写着密码已过期，应用却去装滑块监视器，既不跳过也不提示。
        assertEquals(Sues.CasKind.EXPIRED, Sues.casKind(Sues.CasObservation(
                expired = true, hasForm = false, hasCaptcha = true,
                prompt = "根据密码安全策略，您的密码已过期，请及时更新！")))

        // 反过来：只是账号密码不对，就不该当成过期（过期不消耗失败次数，两者处置完全不同）
        assertEquals(Sues.CasKind.REJECTED, Sues.casKind(Sues.CasObservation(
                expired = false, hasForm = true, hasCaptcha = false,
                prompt = "密码错误。再输错3次，账号将被锁定。")))

        assertEquals(Sues.CasKind.FORM, Sues.casKind(Sues.CasObservation(false, true, true, "")))
        assertEquals(Sues.CasKind.CAPTCHA, Sues.casKind(Sues.CasObservation(false, false, true, "")))
        assertEquals("只是表单校验提示，不算任何特殊状态", Sues.CasKind.OTHER,
                Sues.casKind(Sues.CasObservation(false, false, false, "请输入用户名")))
    }
}
