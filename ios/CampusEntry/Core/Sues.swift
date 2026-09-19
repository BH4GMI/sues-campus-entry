import Foundation

/// 打开校内两个系统所需的全部判断，**纯逻辑、不依赖 UI**。
///
/// 与 Android 端 `Sues.kt` 逐条一致（同一份 `docs/CORE-SPEC.md`）；改判据先改规范再三端同改。
/// 这里不碰任何凭据本身：只认地址形状、页面身份与服务端给的提示文本。
public enum Sues {

    /// WebVPN 门户首页。
    public static let portal = "https://webvpn.sues.edu.cn"

    /// 门户主机名。只有它下面才是网关自己的路径（如换票中转页），别的站点同名路径不算。
    public static var portalHost: String { portal.replacingOccurrences(of: "https://", with: "") }

    /// 教务系统免二次登录的入口路径；与网关前缀拼起来就是落点。
    public static let ssoPath = "/student/sso/login"

    /// 教务系统在 WebVPN 下的地址形态：`/https/<主机编码>/student/…`。
    private static let jxfwUrl = try? NSRegularExpression(
        pattern: "/https/[0-9a-f]+/student/")

    /// 网关前缀只认形状：`http(s)://主机/https/<十六进制编码>`。编码不得写死。
    private static let prefix = try? NSRegularExpression(
        pattern: "^https?://[^/]+/https/[0-9a-fA-F]+$")

    /// 换票链的中间落点；不代表登录失败，也不能当成「入口地址已失效」。
    private static let transientPath = "/wengine-vpn/failed"

    /// 「密码已过期」提示页的判据。只对部分账号弹出，不弹属正常路径。
    public static let passwordExpiredMark = "密码已过期"

    /// 服务端否定凭据时用的文案标记（实测自认证页的 #msg1 / .form-error 容器）。
    private static let credentialMarks: [String] = [
        "密码错误", "密码不正确", "用户名或密码", "账号或密码",
        "用户不存在", "账号不存在", "用户名不存在",
    ]

    /// 剩余次数文案里，数字前面出现这些词才认（服务端措辞不固定，不写死句式）。
    private static let lockoutKeywords: [String] = [
        "再", "还", "剩余", "剩", "可再", "尝试", "输错", "错误",
    ]

    private static let lockoutCount = try? NSRegularExpression(
        pattern: "(\\d+)\\s*次")

    /// 回看多少个字符，来确认这个「N次」确实是在说剩余次数。
    private static let lockoutLookback = 12

    /// 两个入口。默认教务系统，WebVPN 是次要入口。
    public enum Entry: String, CaseIterable, Sendable {
        case jxfw
        case webvpn
    }

    /// 统一身份认证页（会话过期时网关会把请求弹到这里）。
    public static func isCasPage(_ url: String) -> Bool { url.contains("/cas/login") }

    /// **允许填写 / 捕获凭据的页面**（CORE-SPEC §6.1）：主机必须是门户主机，且 URL 含 `/cas/login`。
    /// 第三条「文档同时存在 `#username` 与 `#password`」在页面脚本里判（它返回 `noform`，宿主据此作废）。
    ///
    /// 为什么不能只看路径：网关会把第三方页面改写到自己主机下，教务系统自己也有 CAS 形态的登录页。
    /// 只看 `/cas/login` 就会把本机保存的学校凭据填进一个**不该填**的页面——而 DESIGN.md 与
    /// 两端界面文案都明写着「账号密码只在学校自己的统一身份认证页上输入」。
    public static func isCredentialPage(_ url: String) -> Bool {
        isCasPage(url) && hostOf(url) == portalHost
    }

    /// 已经在教务系统里。
    public static func isJxfwPage(_ url: String) -> Bool { isMatch(jxfwUrl, url) }

    /// 教务系统自己的登录页（要求二次登录）。落点必须用 SSO 支点，不能用卡片地址。
    public static func isSecondLoginPage(_ url: String) -> Bool {
        isJxfwPage(url) && url.contains("/student/login")
    }

    private static let hostPattern = try? NSRegularExpression(
        pattern: "^[a-zA-Z]+://([^/?#]+)")
    private static let pathPattern = try? NSRegularExpression(
        pattern: "^[a-zA-Z]+://[^/?#]*(/[^?#]*)?")

    /// 地址里的主机名（去掉端口）；取不到返回空串。
    public static func hostOf(_ url: String) -> String {
        guard let m = firstMatch(hostPattern, url), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: url) else { return "" }
        return String(url[r]).substringBefore(":")
    }

    /// 地址里的路径（含开头的 /）；没有路径返回空串。
    public static func pathOf(_ url: String) -> String {
        guard let m = firstMatch(pathPattern, url), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: url) else { return "" }
        return String(url[r])
    }

    /// 换票中转页。判据必须带主机名——别的站点上恰好同名的路径不能被当成网关的中转页。
    public static func isTransientPage(_ url: String) -> Bool {
        hostOf(url) == portalHost && pathOf(url).hasPrefix(transientPath)
    }

    /// 正文是不是「密码已过期」提示页。这条路径不消耗失败次数，与密码错误本质不同。
    public static func isPasswordExpired(_ body: String) -> Bool { body.contains(passwordExpiredMark) }

    /// 服务端给的文案里，有没有对凭据的否定。
    public static func hasCredentialError(_ text: String) -> Bool {
        !text.isEmpty && credentialMarks.contains { text.contains($0) }
    }

    /// 从服务端文案里解析「还剩几次可以试」；解析不到返回 nil。
    /// 实测文案「密码错误。再输错3次，账号将被锁定。」→ 3。
    public static func lockoutRemaining(_ text: String) -> Int? {
        if text.isEmpty { return nil }
        guard let count = lockoutCount else { return nil }
        let matches = count.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            let start = match.range.location
            let from = max(0, start - lockoutLookback)
            guard from <= start, let contextRange = Range(NSRange(location: from, length: start - from), in: text)
            else { continue }
            let context = String(text[contextRange])
            if lockoutKeywords.allSatisfy({ !context.contains($0) }) { continue }
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text),
                  let n = Int(text[r]) else { continue }
            return n
        }
        return nil
    }

    /// 剩余次数已经不能再赌了。服务端累计失败次数，5 次锁号，所以 ≤1 时必须硬性阻断一切重试。
    public static func isLockoutCritical(_ remaining: Int?) -> Bool {
        guard let remaining else { return false }
        return remaining <= 1
    }

    /// 认证页上「除了它本身是认证页之外」看到的东西。页面侧原样回报，不夹带任何判断。
    public struct CasObservation: Equatable, Sendable {
        /// 正文里有「密码已过期」标记。
        public let expired: Bool
        /// 账号密码表单在位。
        public let hasForm: Bool
        /// 有滑块容器。
        public let hasCaptcha: Bool
        /// 服务端提示文本（可能为空串）。
        public let prompt: String

        public init(expired: Bool, hasForm: Bool, hasCaptcha: Bool, prompt: String) {
            self.expired = expired
            self.hasForm = hasForm
            self.hasCaptcha = hasCaptcha
            self.prompt = prompt
        }

        public static let empty = CasObservation(expired: false, hasForm: false, hasCaptcha: false, prompt: "")
    }

    /// 认证页该按哪一条处理。
    public enum CasKind: Sendable {
        /// 「密码已过期」提示页：跳过它（等价于点「点击跳过」＝重载当前 URL）。
        case expired
        /// 服务端否定了凭据：立刻停手、不重试。
        case rejected
        /// 账号密码表单在位。
        case form
        /// 只有滑块、没有密码框（独立的滑动登录文档）。
        case captcha
        case other
    }

    /// 解析页面脚本 cas-state.js 的回传值 `obs|<过期>|<表单>|<滑块>|<提示文本>`。
    /// 认不出的形状一律当成「什么都没看到」，不猜。
    public static func casObservationFrom(_ raw: String?) -> CasObservation {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let parts = value.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        if parts.count < 4 || parts[0] != "obs" { return CasObservation.empty }
        return CasObservation(
            expired: parts[1] == "1",
            hasForm: parts[2] == "1",
            hasCaptcha: parts[3] == "1",
            prompt: parts.count > 4 ? parts[4] : "")
    }

    /// 按优先级决定怎么处理：过期 > 凭据被否定 > 表单 > 滑块。
    /// 顺序必须能被单测——真机教过一次：优先级写错会把过期页整个挡住（docs/PROTOCOL.md §6）。
    public static func casKindOf(_ o: CasObservation) -> CasKind {
        if o.expired { return .expired }
        if hasCredentialError(o.prompt) { return .rejected }
        if o.hasForm { return .form }
        if o.hasCaptcha { return .captcha }
        return .other
    }

    /// 前缀形状是否合法。
    public static func isPrefix(_ value: String) -> Bool { isMatch(prefix, value) }

    /// 从门户给出的 redirect/href 推出网关前缀；推不出返回 nil。
    public static func prefixFrom(_ redirect: String?, _ pageUrl: String) -> String? {
        let href = (redirect ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if href.isEmpty { return nil }
        let abs = href.hasPrefix("http") ? href : originOf(pageUrl) + href
        if !abs.contains("/https/") { return nil }
        let prefix = abs.substringBefore("/student/")
        return isPrefix(prefix) ? prefix : nil
    }

    /// 入口地址：记得前缀就直打教务系统的 SSO 支点；没记过（首次使用）回退门户首页，
    /// 由门户那一跳把前缀读出来。WebVPN 入口就是门户首页。
    public static func entryUrl(_ prefix: String?, _ entry: Entry) -> String {
        if entry == .webvpn { return portal }
        if let prefix { return prefix + ssoPath }
        return portal
    }

    /// 页面侧探测结果里那条入口地址（`portal|<href>`）；其余形态一律 nil。
    public static func probeHref(_ probe: String?) -> String? {
        guard let probe else { return nil }
        let raw = probe.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .replacingOccurrences(of: "\\/", with: "/")
        if !raw.hasPrefix("portal|") { return nil }
        let href = String(raw.dropFirst("portal|".count))
        return href.isEmpty ? nil : href
    }

    /// 解析页面脚本 `arrival.js` 的回传值：`arrival|<命中的标记>` / `arrival|none` / `arrival|err`。
    /// 返回命中的标记名；**没确认到达时返回 nil**（认不出的形状一律当没确认，不猜）。
    ///
    /// CORE-SPEC §2：「成功」的判据是**正文**含 `个人信息` / `注销` / `资源站点`，不能只看 URL 是不是
    /// 落在门户主机——换票中转页、门户自己的错误页都满足那个条件，只说明「到过」。
    /// 标记表写在 `shared/js/arrival.js` 里（只有页面侧看得到正文），这里只解析它的结论。
    public static func arrivalMark(_ raw: String?) -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "arrival" else { return nil }
        let mark = String(parts[1])
        return (mark.isEmpty || mark == "none" || mark == "err") ? nil : mark
    }

    /// 「剩余次数」那半句话（APP-UX §5 的「剩余次数」行）：**追加**在否定文案后面，不是替换它。
    /// 解析不到次数时返回 nil（什么都不加）。
    ///
    /// 为什么值得单独一个函数：它曾经是实现里的一个 bug——文案写成三选一，
    /// 「用已存凭据被否定」先命中，于是「再错一次就锁定了」对**最可能只剩一次**的那种场景
    /// 永远不可达（每次冷启动都会自动消耗一次失败次数）。规则放在这里就能被单测钉住。
    public static func remainingClause(_ remaining: Int?) -> String? {
        guard let remaining else { return nil }
        return isLockoutCritical(remaining)
            ? "；再错一次就锁定了，请先确认密码"
            : "；还可以试 \(remaining) 次"
    }

    /// 两串地址是不是同一页（只忽略末尾斜杠）。
    public static func samePage(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return trimTrailingSlashes(a) == trimTrailingSlashes(b)
    }

    public static func originOf(_ url: String) -> String {
        guard let m = firstMatch(originPattern, url), let r = Range(m.range, in: url) else { return "" }
        return String(url[r])
    }

    private static let originPattern = try? NSRegularExpression(pattern: "^https?://[^/]+")
}

/// 去掉字符串末尾的全部 `/`（对应 C# 的 `TrimEnd('/')`）。
private func trimTrailingSlashes(_ s: String) -> String {
    var end = s.endIndex
    while end > s.startIndex {
        let prev = s.index(before: end)
        if s[prev] == "/" { end = prev } else { break }
    }
    return String(s[s.startIndex..<end])
}

/// 取第一个匹配；表达式编译失败时返回 nil。
private func firstMatch(_ regex: NSRegularExpression?, _ text: String) -> NSTextCheckingResult? {
    guard let regex else { return nil }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
}

/// 是不是「有匹配」（对应 C# 的 `Regex.IsMatch` / Kotlin 的 `matches`）。
private func isMatch(_ regex: NSRegularExpression?, _ text: String) -> Bool {
    firstMatch(regex, text) != nil
}

private extension String {
    /// C# 的 StringExt.SubstringBefore：取标记之前的部分；找不到标记时返回原串。
    func substringBefore(_ marker: String) -> String {
        guard let range = range(of: marker) else { return self }
        return String(self[self.startIndex..<range.lowerBound])
    }
}
