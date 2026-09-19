package app.webvpn.entry

/**
 * 一个标签页里的导航状态机。**纯逻辑、不依赖 Android**，因此可以直接单测。
 *
 * 为什么要有这个类：这些状态（文档账本、是否已停手、是否见过认证页、是不是用缓存前缀进来的）
 * 说的都是「**这一页**走到哪儿了」。它们原先住在 Activity 上，只有一页时没问题；一旦有多个标签页，
 * 共用一份状态就会出现「A 页的动作作用到 B 页」——A 页见到认证页会把 B 页的「已停手」复位，
 * B 页的前缀失效判断会拿 A 页的账本算。所以状态的所有权必须降到**每页一份**。
 *
 * 这个类只**决定**该做什么，动作由宿主执行（见 `EntryHost`）。
 */
class EntryFlow {

    /** 状态机让宿主去做的事。 */
    enum class Action {
        /** 同一份文档的重复回调、已经停手、或站点自己开的页面：什么都不做。 */
        NOTHING,

        /** 认证页：去页面里观察它现在是什么状态。 */
        INSPECT_CAS,

        /** 认证页、状态正常：勾「记住我」、装监视器、（已授权时）自动填写并提交。 */
        ASSIST_CAS,

        /** 「密码已过期」提示页：点掉「点击跳过」。 */
        SKIP_EXPIRED,

        /** 服务端否定了凭据：停手、不重试。 */
        REJECT_CREDENTIALS,

        /** 换票中转页：等它自己往下跳。 */
        TRANSIENT,

        /** 到地方了：停手，页面交给用户。 */
        SETTLE,

        /** 前缀失效：清掉缓存，下次回门户重读。 */
        CLEAR_PREFIX,

        /** 教务系统自己的二次登录页：提示用户自行登录。 */
        SECOND_LOGIN,

        /** 去门户读入口前缀。 */
        PROBE_PORTAL,

        /**
         * 到了「可能已经是目的地」的页面：**先验正文**再决定要不要停手（`docs/CORE-SPEC.md` §2）。
         * 只用于门户入口那一跳——URL 落在门户主机只说明「到过」。
         */
        VERIFY_ARRIVAL,
    }

    /** 这一页当前是替哪个入口服务的。 */
    var entry: Sues.Entry = Sues.Entry.JXFW
        private set

    /** 站点自己开的标签页：**不替用户导航**，但仍然辅助认证页。 */
    var adopted: Boolean = false
        private set

    /** 本次是不是用缓存前缀直打教务系统进来的。 */
    private var fromCachedPrefix = false

    /** 已经停手：不再替用户导航（认证页的帮忙仍然保留）。 */
    private var settled = false

    /** 本次流程里见过认证页：用来把「登录完落在门户」和「前缀已失效」分开。 */
    private var casSeen = false

    /**
     * 应用替用户提交过凭据、**判决还没落地**。
     *
     * 登录提交是整页导航：服务端的回应（成功跳转链 / 错误文案页）是**下一份新文档**
     * （`docs/PROTOCOL.md` §6）。所以「这次否定是不是冲着应用填的那组凭据来的」不能用
     * 「文档序号相等」判断——那永远差一，已存凭据被否定时会漏删，留下「每次冷启动都
     * 自动消耗一次失败次数」直达锁号的隐患。
     *
     * 正确的模型是**标志**：应用真的按下登录那一刻置位；用户自己提交、登录成功、
     * 或重开流程时清掉。否定发生时标志在，才归属给应用。
     */
    private var awaitingVerdict = false

    // 文档账本：onPageFinished 对同一份文档会重复回调，而**换文档不等于换地址**
    // （认证页提交前后地址逐字节相同），所以身份只能来自「第几份文档」。
    private var docs = 0
    private var handled = -1

    // 门户探测的自续重试账本（按 URL 分别记）。
    //
    // 这段账本**必须住在状态机里**：它唯一的改动点是 onProbeMissed，所以「上限是几发」能被单测钉住。
    // 2026-09-20 修：早先它写在宿主里，重试路径顺手调了「取消探测」（那个函数同时负责停定时器与清计数），
    // 于是计数每轮被清零、上限永远到不了、探测变成无限循环；而宿主层一条测试都没有，没人拦得住。
    private var probeUrl: String? = null
    private var probeMisses = 0

    companion object {
        /** 门户探测的自续重试上限（`docs/CORE-SPEC.md` §3：600ms 一发、最多 15 发后交回用户）。 */
        const val PROBE_MAX_ATTEMPTS = 15
    }

    /** 已经有几份文档了。宿主拿它当「本页身份」，例如记录「这份文档是我填的」。 */
    val documentOrdinal: Int get() = docs

    /** 已经停手：不再替用户导航。 */
    val isSettled: Boolean get() = settled

    /** 用户点了某个入口：把这一页的状态全部复位，重新走一遍。 */
    fun start(entry: Sues.Entry, hasCachedPrefix: Boolean) {
        this.entry = entry
        fromCachedPrefix = hasCachedPrefix
        adopted = false
        settled = false
        casSeen = false
        awaitingVerdict = false
        docs = 0
        handled = -1
        resetProbe()
    }

    /** 站点自己开了这一页（`window.open` / `target=_blank`）：只辅助认证页，不替用户导航。 */
    fun adopt() {
        adopted = true
        settled = true
        casSeen = false
        awaitingVerdict = false
        docs = 0
        handled = -1
        resetProbe()
    }

    /** 新文档开始加载（`onPageStarted`）。 */
    fun onDocumentStarted() {
        docs++
    }

    /**
     * 门户探测又没读到前缀。**返回值就是「还要不要再探一发」**，宿主只管据此排下一次任务。
     *
     * 计数按 URL 分别记：换了页面就重新计（门户自己会跳几步，跳过去之后预算应当重置）。
     * 返回 true 的次数恰好是 [PROBE_MAX_ATTEMPTS]，第 N+1 次返回 false——宿主那时提示用户。
     * 宿主**不得**自己清这个计数（见字段上的说明）。
     */
    fun onProbeMissed(url: String): Boolean {
        if (probeUrl != url) {
            probeUrl = url
            probeMisses = 0
        }
        probeMisses++
        return probeMisses <= PROBE_MAX_ATTEMPTS
    }

    /** 清掉探测重试账本（重开流程 / 被站点接管的页面）。 */
    private fun resetProbe() {
        probeUrl = null
        probeMisses = 0
    }

    /** 一份新文档加载完成，返回该做什么。 */
    fun onDocumentFinished(url: String): Action {
        if (handled == docs) return Action.NOTHING
        handled = docs

        if (Sues.isCasPage(url)) {
            // 认证页在任何一跳都可能出现（会话过期、被踢下线），**不受其它规则约束**
            casSeen = true
            if (!adopted) settled = false
            return Action.INSPECT_CAS
        }
        // §4 的条目顺序：第 2 条「已经停手」**先于**第 3 条「换票中转页」。
        // 早先这里把中转页判定放在停手之前，于是已经交回用户的页面仍会被装上 15 秒重载定时器——
        // 一次用户没要求的导航，与「停手 = 不再替用户导航」直接冲突。
        if (settled || adopted) return Action.NOTHING
        if (Sues.isTransientPage(url)) return Action.TRANSIENT

        return when {
            Sues.isSecondLoginPage(url) -> Action.SECOND_LOGIN
            Sues.isJxfwPage(url) -> settle()
            // 门户入口：**URL 落在门户主机不算到达**——换票中转页（上面已排除）与门户自己的
            // 错误页都满足它，那只说明「到过」。按 §2 先验正文，确认了再停手。
            // 教务系统那一支不用正文标记：那三个标记是**门户**的（教务系统首页没有它们），
            // `/https/<编码>/student/` 这个形状本身已经足够具体。
            entry == Sues.Entry.WEBVPN -> Action.VERIFY_ARRIVAL
            fromCachedPrefix && !casSeen -> Action.CLEAR_PREFIX
            else -> Action.PROBE_PORTAL
        }
    }

    /**
     * 正文里确认了登录成功的标记：这才是真的到了目的地（`docs/CORE-SPEC.md` §2）。
     * 由宿主在 [Action.VERIFY_ARRIVAL] 之后调用。
     */
    fun confirmArrival(): Action = settle()

    /** 认证页上观察到的东西，返回该做什么。优先级由 [Sues.casKind] 说了算。 */
    fun onCasObserved(observation: Sues.CasObservation): Action = when (Sues.casKind(observation)) {
        Sues.CasKind.EXPIRED -> Action.SKIP_EXPIRED
        Sues.CasKind.REJECTED -> Action.REJECT_CREDENTIALS
        else -> Action.ASSIST_CAS
    }

    /**
     * 应用替用户按下了登录。置上待判决标志；判决（成功 / 被否定）落地前它一直有效，
     * 不受「换了一份新文档」影响——回应本来就是另一份文档。
     */
    fun onAutoSubmitted() {
        awaitingVerdict = true
    }

    /** 自动提交没能发生（页面上没有表单 / 没有登录按钮）：标志作废。 */
    fun onAutoSubmitAborted() {
        awaitingVerdict = false
    }

    /**
     * 用户自己提交了凭据（页面侧抓到的提交不是应用填的那次）：待判决不再属于应用。
     */
    fun onUserSubmitted() {
        awaitingVerdict = false
    }

    /**
     * 凭据被否定时调用一次：读走并清掉待判决标志。
     *
     * 返回「这次否定是不是冲着应用填的那组凭据来的」。读走即清，因此**第二次**否定
     * （用户手动改过后还是错）不会再次归属给应用、不会重复触发删库。
     */
    fun consumeAutoVerdict(): Boolean {
        val was = awaitingVerdict
        awaitingVerdict = false
        return was
    }

    private fun settle(): Action {
        settled = true
        // 登录到了目的地就是正面判决：待判决状态结束
        awaitingVerdict = false
        return Action.SETTLE
    }
}
