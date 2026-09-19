import Foundation

/// 导航状态机，**纯逻辑、不依赖 UI**，与 Android 端 `EntryFlow.kt` 逐条一致
/// （同一份 `docs/CORE-SPEC.md` §4）。这个类只决定该做什么，动作由宿主执行。
public final class EntryFlow {

    /// 状态机让宿主去做的事。
    public enum Action: Sendable {
        /// 同一份文档的重复回调、已经停手、或站点自己开的页面：什么都不做。
        case nothing
        /// 认证页：去页面里观察它现在是什么状态。
        case inspectCas
        /// 认证页、状态正常：勾「记住我」、装监视器、（已授权时）自动填写并提交。
        case assistCas
        /// 「密码已过期」提示页：点掉「点击跳过」。
        case skipExpired
        /// 服务端否定了凭据：停手、不重试。
        case rejectCredentials
        /// 换票中转页：等它自己往下跳。
        case transient
        /// 到地方了：停手，页面交给用户。
        case settle
        /// 前缀失效：清掉缓存，下次回门户重读。
        case clearPrefix
        /// 教务系统自己的二次登录页：提示用户自行登录。
        case secondLogin
        /// 去门户读入口前缀。
        case probePortal
        /// 到了「可能已经是目的地」的页面：**先验正文**再决定要不要停手（CORE-SPEC §2）。
        /// 只用于门户入口那一跳——URL 落在门户主机只说明「到过」。
        case verifyArrival
    }

    /// 当前替哪个入口服务。
    public private(set) var entry: Sues.Entry = .jxfw

    /// 站点自己开的窗口：不替用户导航，但仍然辅助认证页。
    public private(set) var adopted: Bool = false

    /// 本次是不是用缓存前缀直打教务系统进来的。
    private var fromCachedPrefix: Bool = false

    /// 已经停手：不再替用户导航（认证页的帮忙仍然保留）。
    private var settled: Bool = false

    /// 本次流程里见过认证页：用来把「登录完落在门户」和「前缀已失效」分开。
    private var casSeen: Bool = false

    /// 应用替用户提交过凭据、**判决还没落地**。
    ///
    /// 登录提交是整页导航：服务端的回应（成功跳转链 / 错误文案页）是**下一份新文档**
    /// （docs/PROTOCOL.md §6）。所以「这次否定是不是冲着应用填的那组凭据来的」不能用
    /// 「文档序号相等」判断——那永远差一。正确的模型是标志：应用真的按下登录那一刻置位；
    /// 用户自己提交、登录成功、或重开流程时清掉。
    private var awaitingVerdict: Bool = false

    // 文档账本：同一份文档会重复回调，而换文档不等于换地址（认证页提交前后地址逐字节相同），
    // 所以身份只能来自「第几份文档」。
    private var docs: Int = 0
    private var handled: Int = -1

    /// 门户探测的自续重试账本（按 URL 分别记）。
    ///
    /// 这段账本**必须住在状态机里**：它唯一的改动点是 `onProbeMissed`，所以「上限是几发」能被单测钉住。
    /// 2026-09-20 修：早先它写在宿主里，重试路径顺手调了「取消探测」（那个函数同时负责停定时器与清计数），
    /// 于是计数每轮被清零、上限永远到不了、探测变成无限循环；而宿主层一条测试都没有，没人拦得住。
    private var probeUrl: String?
    private var probeMisses: Int = 0

    /// 门户探测的自续重试上限（CORE-SPEC §3：600ms 一发、最多 15 发后交回用户）。
    public static let probeMaxAttempts = 15

    /// C# 侧的隐式默认构造函数；显式声明以便跨模块构造。
    public init() {}

    /// 已经停手：不再替用户导航。
    public var isSettled: Bool { settled }

    /// 宿主拿它当「本文档身份」，例如记录「这份文档是我填的」。
    public var documentOrdinal: Int { docs }

    /// 用户点了某个入口：把状态全部复位，重新走一遍。
    public func start(_ entry: Sues.Entry, _ hasCachedPrefix: Bool) {
        self.entry = entry
        fromCachedPrefix = hasCachedPrefix
        adopted = false
        settled = false
        casSeen = false
        awaitingVerdict = false
        docs = 0
        handled = -1
        resetProbe()
    }

    /// 站点自己开了这一页（window.open / target=_blank）：只辅助认证页，不替用户导航。
    public func adopt() {
        adopted = true
        settled = true
        casSeen = false
        awaitingVerdict = false
        docs = 0
        handled = -1
        resetProbe()
    }

    /// 新文档开始加载。
    public func onDocumentStarted() { docs += 1 }

    /// 门户探测又没读到前缀。**返回值就是「还要不要再探一发」**，宿主只管据此排下一次任务。
    ///
    /// 计数按 URL 分别记：换了页面就重新计（门户自己会跳几步，跳过去之后预算应当重置）。
    /// 返回 true 的次数恰好是 `EntryFlow.probeMaxAttempts`，第 N+1 次返回 false——宿主那时提示用户。
    /// 宿主**不得**自己清这个计数（见字段上的说明）。
    public func onProbeMissed(_ url: String) -> Bool {
        if probeUrl != url {
            probeUrl = url
            probeMisses = 0
        }
        probeMisses += 1
        return probeMisses <= EntryFlow.probeMaxAttempts
    }

    /// 清掉探测重试账本（重开流程 / 被站点接管的页面）。
    private func resetProbe() {
        probeUrl = nil
        probeMisses = 0
    }

    /// 一份新文档加载完成，返回该做什么。
    public func onDocumentFinished(_ url: String) -> Action {
        if handled == docs { return .nothing }
        handled = docs

        if Sues.isCasPage(url) {
            // 认证页在任何一跳都可能出现（会话过期、被踢下线），不受其它规则约束
            casSeen = true
            if !adopted { settled = false }
            return .inspectCas
        }
        // §4 的条目顺序：第 2 条「已经停手」**先于**第 3 条「换票中转页」。
        // 早先这里把中转页判定放在停手之前，于是已经交回用户的页面仍会被装上 15 秒重载定时器——
        // 一次用户没要求的导航，与「停手 = 不再替用户导航」直接冲突。
        if settled || adopted { return .nothing }
        if Sues.isTransientPage(url) { return .transient }

        if Sues.isSecondLoginPage(url) { return .secondLogin }
        if Sues.isJxfwPage(url) { return settle() }
        // 门户入口：**URL 落在门户主机不算到达**——换票中转页（上面已排除）与门户自己的
        // 错误页都满足它，那只说明「到过」。按 §2 先验正文，确认了再停手。
        // 教务系统那一支不用正文标记：那三个标记是**门户**的（教务系统首页没有它们），
        // `/https/<编码>/student/` 这个形状本身已经足够具体。
        if entry == .webvpn { return .verifyArrival }
        if fromCachedPrefix && !casSeen { return .clearPrefix }
        return .probePortal
    }

    /// 正文里确认了登录成功的标记：这才是真的到了目的地（CORE-SPEC §2）。
    /// 由宿主在 `.verifyArrival` 之后调用。
    public func confirmArrival() -> Action { settle() }

    /// 认证页上观察到的东西，返回该做什么。优先级由 `Sues.casKindOf` 说了算。
    public func onCasObserved(_ observation: Sues.CasObservation) -> Action {
        switch Sues.casKindOf(observation) {
        case .expired:
            return .skipExpired
        case .rejected:
            return .rejectCredentials
        default:
            return .assistCas
        }
    }

    /// 应用替用户按下了登录：置上待判决标志，不受「换了一份新文档」影响。
    public func onAutoSubmitted() { awaitingVerdict = true }

    /// 自动提交没能发生（页面上没有表单/登录按钮）：标志作废。
    public func onAutoSubmitAborted() { awaitingVerdict = false }

    /// 用户自己提交了凭据：待判决不再属于应用。
    public func onUserSubmitted() { awaitingVerdict = false }

    /// 凭据被否定时调用一次：读走并清掉待判决标志。读走即清，因此第二次否定
    /// （用户手动改过后还是错）不会再次归属给应用、不会重复触发删库。
    public func consumeAutoVerdict() -> Bool {
        let was = awaitingVerdict
        awaitingVerdict = false
        return was
    }

    private func settle() -> Action {
        settled = true
        // 登录到了目的地就是正面判决：待判决状态结束
        awaitingVerdict = false
        return .settle
    }
}
