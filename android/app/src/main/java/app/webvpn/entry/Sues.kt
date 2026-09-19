package app.webvpn.entry

/**
 * 打开校内两个系统所需的全部判断，**纯逻辑、不依赖 Android**。
 *
 * 这样两端可以逐条对齐（`docs/PROTOCOL.md` 是同一份事实），也便于在 JVM 上直接单测。
 * 这里不碰任何凭据本身：只认地址形状、页面身份与服务端给的提示文本。
 */
object Sues {

    /** WebVPN 门户首页。 */
    const val PORTAL = "https://webvpn.sues.edu.cn"

    /** 门户主机名。只有它下面才是网关自己的路径（如换票中转页），别的站点同名路径不算。 */
    val PORTAL_HOST: String = PORTAL.removePrefix("https://")

    /** 教务系统免二次登录的入口路径；与网关前缀拼起来就是落点。 */
    const val SSO_PATH = "/student/sso/login"

    /** 教务系统在 WebVPN 下的地址形态：`/https/<主机编码>/student/…`。 */
    private val JXFW_URL = Regex("""/https/[0-9a-f]+/student/""")

    /**
     * 网关前缀只认形状：`http(s)://主机/https/<十六进制编码>`。
     *
     * 那串编码是网关按目标主机（与端口）算出来的部署细节，**不得写死**，只能从门户读出来；
     * 这里只校验形状，值一律照抄读到的内容。
     */
    private val PREFIX = Regex("""^https?://[^/]+/https/[0-9a-fA-F]+$""")

    /**
     * 换票链的中间落点：`/wengine-vpn/failed`，正文「出错啦！该网站无法访问…」。
     *
     * 它**不代表登录失败**，也不能当成「入口地址已失效」——两者都会造成误判。
     */
    private const val TRANSIENT_PATH = "/wengine-vpn/failed"

    /** 「密码已过期」提示页的判据：正文含它。只对部分账号弹出，不弹属正常路径。 */
    const val PASSWORD_EXPIRED_MARK = "密码已过期"

    /**
     * 服务端否定凭据时用的文案标记（实测自认证页的 `#msg1` / `.form-error` 容器）。
     *
     * 一律按**内容**判定：认证页提交前后的地址逐字节相同，URL 形态在这里毫无信息量。
     */
    private val CREDENTIAL_MARKS = listOf(
            "密码错误", "密码不正确", "用户名或密码", "账号或密码",
            "用户不存在", "账号不存在", "用户名不存在")

    /** 剩余次数文案里，数字前面出现这些词才认（服务端措辞不固定，不写死句式）。 */
    private val LOCKOUT_KEYWORDS = listOf("再", "还", "剩余", "剩", "可再", "尝试", "输错", "错误")

    private val LOCKOUT_COUNT = Regex("""(\d+)\s*次""")

    /** 回看多少个字符，来确认这个「N次」确实是在说剩余次数。 */
    private const val LOCKOUT_LOOKBACK = 12

    /** 两个入口。默认教务系统，WebVPN 是次要入口。 */
    enum class Entry { JXFW, WEBVPN }

    /** 统一身份认证页（会话过期时网关会把请求弹到这里）。 */
    fun isCasPage(url: String): Boolean = url.contains("/cas/login")

    /**
     * **允许填写 / 捕获凭据的页面**（CORE-SPEC §6.1）：主机必须是门户主机，且 URL 含 `/cas/login`。
     * 第三条「文档同时存在 #username 与 #password」在页面脚本里判（它返回 noform，宿主据此作废）。
     *
     * 为什么不能只看路径：网关会把第三方页面改写到自己主机下，教务系统自己也有 CAS 形态的登录页。
     * 只看 `/cas/login` 就会把本机保存的学校凭据填进一个**不该填**的页面——而 DESIGN.md 与
     * 两端界面文案都明写着「账号密码只在学校自己的统一身份认证页上输入」。
     */
    fun isCredentialPage(url: String): Boolean = isCasPage(url) && hostOf(url) == PORTAL_HOST

    /** 已经在教务系统里。 */
    fun isJxfwPage(url: String): Boolean = JXFW_URL.containsMatchIn(url)

    /**
     * 教务系统自己的登录页（要求二次登录）。
     *
     * 门户卡片「新教务系统学生端」指向 `/student/home`，会被 302 到这里；实测它要二次登录，
     * 所以落点必须用 [SSO_PATH] 那条支点，不能用卡片地址。
     */
    fun isSecondLoginPage(url: String): Boolean =
            isJxfwPage(url) && url.contains("/student/login")

    /** 地址里的主机名（去掉端口）；取不到返回空串。 */
    fun hostOf(url: String): String =
            Regex("""^[a-zA-Z]+://([^/?#]+)""").find(url)
                    ?.groupValues?.get(1)?.substringBefore(':').orEmpty()

    /** 地址里的路径（含开头的 `/`）；没有路径返回空串。 */
    fun pathOf(url: String): String =
            Regex("""^[a-zA-Z]+://[^/?#]*(/[^?#]*)?""").find(url)
                    ?.groupValues?.get(1).orEmpty()

    /**
     * 换票中转页（[TRANSIENT_PATH]）。
     *
     * 判据必须带主机名——别的站点上恰好同名的路径不能被当成网关的中转页。
     */
    fun isTransientPage(url: String): Boolean =
            hostOf(url) == PORTAL_HOST && pathOf(url).startsWith(TRANSIENT_PATH)

    /** 正文是不是「密码已过期」提示页。这条路径**不消耗**失败次数，与密码错误本质不同。 */
    fun isPasswordExpired(body: String): Boolean = body.contains(PASSWORD_EXPIRED_MARK)

    /** 服务端给的文案里，有没有对凭据的否定（密码错误 / 账号不存在 …）。 */
    fun hasCredentialError(text: String): Boolean =
            text.isNotEmpty() && CREDENTIAL_MARKS.any { text.contains(it) }

    /**
     * 从服务端文案里解析「还剩几次可以试」；解析不到返回 null。
     *
     * 实测文案「密码错误。再输错3次，账号将被锁定。」→ 3；也认「还可尝试2次」「剩余1次」。
     */
    fun lockoutRemaining(text: String): Int? {
        if (text.isEmpty()) return null
        for (match in LOCKOUT_COUNT.findAll(text)) {
            val start = match.range.first
            val context = text.substring(maxOf(0, start - LOCKOUT_LOOKBACK), start)
            if (LOCKOUT_KEYWORDS.none { context.contains(it) }) continue
            match.groupValues[1].toIntOrNull()?.let { return it }
        }
        return null
    }

    /**
     * 剩余次数已经不能再赌了。
     *
     * **服务端累计失败次数，5 次锁号**，所以 ≤ 1 时必须硬性阻断一切重试路径
     * （见 `docs/CORE-SPEC.md` §6）。
     */
    fun isLockoutCritical(remaining: Int?): Boolean = remaining != null && remaining <= 1

    /** 认证页上「除了它本身是认证页之外」看到的东西。页面侧原样回报，不夹带任何判断。 */
    data class CasObservation(
            /** 正文里有「密码已过期」标记。 */
            val expired: Boolean,
            /** 账号密码表单在位。 */
            val hasForm: Boolean,
            /** 有滑块容器。 */
            val hasCaptcha: Boolean,
            /** 服务端提示文本（可能为空串）。 */
            val prompt: String,
    )

    /** 认证页该按哪一条处理。 */
    enum class CasKind {
        /** 「密码已过期」提示页：跳过它（等价于点「点击跳过」＝重载当前 URL）。 */
        EXPIRED,

        /** 服务端否定了凭据：立刻停手、不重试。 */
        REJECTED,

        /** 账号密码表单在位。 */
        FORM,

        /** 只有滑块、没有密码框（独立的滑动登录文档）。 */
        CAPTCHA,

        OTHER,
    }

    /**
     * 解析 `PageJs.CAS_STATE` 的回传值 `obs|<过期>|<表单>|<滑块>|<提示文本>`。
     *
     * 认不出的形状一律当成「什么都没看到」，不猜。
     */
    fun casObservation(raw: String?): CasObservation {
        val value = raw?.trim()?.trim('"').orEmpty()
        val parts = value.split('|', limit = 5)
        if (parts.size < 4 || parts[0] != "obs") return CasObservation(false, false, false, "")
        return CasObservation(
                expired = parts[1] == "1",
                hasForm = parts[2] == "1",
                hasCaptcha = parts[3] == "1",
                prompt = if (parts.size > 4) parts[4] else "")
    }

    /**
     * 按**优先级**决定怎么处理。顺序必须留在这里、而且必须能被单测——真机教过一次：
     *
     * 1. **过期优先**。过期提示的文案本身就写在 `#msg1` / `.form-error` 容器里，所以「先看有没有
     *    提示文本」会把它整个挡住：页面上明明写着密码已过期，应用却去装滑块监视器，于是既不跳过
     *    也不提示。这就是把优先级写进 JS 字面量的代价。
     * 2. 再看提示文本是不是在否定凭据。
     * 3. 最后才是表单 / 滑块。
     */
    fun casKind(observation: CasObservation): CasKind = when {
        observation.expired -> CasKind.EXPIRED
        hasCredentialError(observation.prompt) -> CasKind.REJECTED
        observation.hasForm -> CasKind.FORM
        observation.hasCaptcha -> CasKind.CAPTCHA
        else -> CasKind.OTHER
    }

    /** 前缀形状是否合法。 */
    fun isPrefix(value: String): Boolean = PREFIX.matches(value)

    /** 从门户给出的 `redirect`/`href` 推出网关前缀；推不出返回 null。 */
    fun prefixFrom(redirect: String?, pageUrl: String): String? {
        val href = redirect?.trim().orEmpty()
        if (href.isEmpty()) return null
        val abs = if (href.startsWith("http")) href else originOf(pageUrl) + href
        if (!abs.contains("/https/")) return null
        val prefix = abs.substringBefore("/student/")
        return if (isPrefix(prefix)) prefix else null
    }

    /**
     * 入口地址：记得前缀就直打教务系统的 SSO 支点；没记过（首次使用）回退门户首页，
     * 由门户那一跳把前缀读出来。WebVPN 入口就是门户首页。
     */
    fun entryUrl(prefix: String?, entry: Entry): String = when {
        entry == Entry.WEBVPN -> PORTAL
        prefix != null -> prefix + SSO_PATH
        else -> PORTAL
    }

    /**
     * 页面侧探测结果里那条入口地址。
     *
     * 探测返回 `portal|<href>`（见 `PageJs.PROBE`），其余形态一律 null。
     */
    fun probeHref(probe: String?): String? {
        val raw = probe?.trim()?.trim('"')?.replace("\\/", "/") ?: return null
        return if (raw.startsWith("portal|")) raw.substringAfter('|').ifEmpty { null } else null
    }

    /**
     * 解析页面脚本 `arrival.js` 的回传值：`arrival|<命中的标记>` / `arrival|none` / `arrival|err`。
     * 返回命中的标记名；**没确认到达时返回 null**（认不出的形状一律当没确认，不猜）。
     *
     * CORE-SPEC §2：「成功」的判据是**正文**含 `个人信息` / `注销` / `资源站点`，不能只看 URL 是不是
     * 落在门户主机——换票中转页、门户自己的错误页都满足那个条件，只说明「到过」。
     * 标记表写在 `shared/js/arrival.js` 里（只有页面侧看得到正文），这里只解析它的结论。
     */
    fun arrivalMark(raw: String?): String? {
        val value = raw?.trim()?.trim('"').orEmpty()
        val parts = value.split('|', limit = 2)
        if (parts.size != 2 || parts[0] != "arrival") return null
        return if (parts[1].isEmpty() || parts[1] == "none" || parts[1] == "err") null else parts[1]
    }

    /**
     * 「剩余次数」那半句话（APP-UX §5 的「剩余次数」行）：**追加**在否定文案后面，不是替换它。
     * 解析不到次数时返回 null（什么都不加）。
     *
     * 为什么值得单独一个函数：它曾经是实现里的一个 bug——文案写成三选一，
     * 「用已存凭据被否定」先命中，于是「再错一次就锁定了」对**最可能只剩一次**的那种场景
     * 永远不可达（每次冷启动都会自动消耗一次失败次数）。规则放在这里就能被单测钉住。
     */
    fun remainingClause(remaining: Int?): String? = when {
        remaining == null -> null
        isLockoutCritical(remaining) -> "；再错一次就锁定了，请先确认密码"
        else -> "；还可以试 $remaining 次"
    }

    /** 两串地址是不是同一页（只忽略末尾斜杠）。 */
    fun samePage(a: String?, b: String?): Boolean {
        if (a.isNullOrEmpty() || b.isNullOrEmpty()) return false
        return a.trimEnd('/') == b.trimEnd('/')
    }

    fun originOf(url: String): String =
            Regex("""^https?://[^/]+""").find(url)?.value.orEmpty()
}
