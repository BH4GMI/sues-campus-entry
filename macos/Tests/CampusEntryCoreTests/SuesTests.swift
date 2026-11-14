import Testing
@testable import CampusEntryCore

/// Equivalent test vectors from `SuesTests.cs` and `CORE-SPEC.md` §7.
@Suite("Sues Rules and Parsers")
struct SuesTests {
    private static let prefix =
        "https://webvpn.sues.edu.cn/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b"
    private static let casURL =
        "https://webvpn.sues.edu.cn/https/f3f652d234256d43300d8db9d6562d/cas/login?service=x"

    // MARK: - Entry URL (§7)

    @Test("无前缀的教务入口回退门户")
    func entryUrlFallback() {
        #expect(Sues.entryUrl(prefix: nil, entry: .jxfw) == "https://webvpn.sues.edu.cn")
        #expect(Sues.entryUrl(prefix: Self.prefix, entry: .jxfw) == Self.prefix + "/student/sso/login")
        #expect(Sues.entryUrl(prefix: Self.prefix, entry: .webvpn) == "https://webvpn.sues.edu.cn")
    }

    // MARK: - Prefix Shape (§7)

    @Test("前缀只认形状不认取值")
    func prefixShapeOnly() {
        #expect(Sues.isPrefix(Self.prefix))
        #expect(!Sues.isPrefix("https://webvpn.sues.edu.cn"))
        #expect(!Sues.isPrefix("https://webvpn.sues.edu.cn/https/"))
        #expect(!Sues.isPrefix("https://webvpn.sues.edu.cn/https/zzzz"))
        #expect(!Sues.isPrefix(Self.prefix + "/student/home"))
        #expect(!Sues.isPrefix("/https/abc123"))
    }

    @Test("从门户 redirect 推出前缀")
    func prefixFromPortalRedirect() {
        let page = "https://webvpn.sues.edu.cn/"
        #expect(
            Sues.prefixFrom(
                "/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b/student/home",
                pageUrl: page
            ) == Self.prefix
        )
        #expect(Sues.prefixFrom("/http/abc123/student/home", pageUrl: page) == nil)
        #expect(Sues.prefixFrom("", pageUrl: page) == nil)
        #expect(Sues.prefixFrom(nil, pageUrl: page) == nil)
    }

    // MARK: - Page Identity (§7)

    @Test("页面身份判据")
    func pageIdentity() {
        #expect(Sues.isJxfwPage(Self.prefix + "/student/home"))
        #expect(!Sues.isSecondLoginPage(Self.prefix + "/student/home"))
        #expect(Sues.isJxfwPage(Self.prefix + "/student/sso/login"))
        #expect(!Sues.isSecondLoginPage(Self.prefix + "/student/sso/login"))
        #expect(Sues.isSecondLoginPage(Self.prefix + "/student/login?refer=https://jxfw.sues.edu.cn/student/home"))
        #expect(Sues.isCasPage(Self.casURL))
        #expect(!Sues.isJxfwPage(Self.casURL))
        #expect(!Sues.isJxfwPage("https://webvpn.sues.edu.cn/http/abc123/eams/index.action"))

        let transient = "https://webvpn.sues.edu.cn/wengine-vpn/failed"
        #expect(Sues.isTransientPage(transient))
        #expect(!Sues.isJxfwPage(transient))
        #expect(!Sues.isCasPage(transient))
        #expect(!Sues.isTransientPage("https://other.example.com/wengine-vpn/failed"))
    }

    // MARK: - Credential Page Host Check (§6.1)

    @Test("凭据页必须是门户主机")
    func credentialPageRequiresPortalHost() {
        #expect(Sues.isCredentialPage(Self.casURL))
        #expect(!Sues.isCredentialPage("https://jxfw.sues.edu.cn/cas/login?service=x"))
        #expect(!Sues.isCredentialPage("https://example.com/cas/login"))
        #expect(Sues.isCasPage("https://example.com/cas/login"))
        #expect(!Sues.isCredentialPage(Self.prefix + "/student/home"))
    }

    // MARK: - Remaining Clause (APP-UX §5)

    @Test("剩余次数是追加的一句且 N 不大于一时改口")
    func remainingClauseFormatting() {
        #expect(Sues.remainingClause(nil) == nil)
        #expect(Sues.remainingClause(3) == "；还可以试 3 次")
        #expect(Sues.remainingClause(2) == "；还可以试 2 次")
        #expect(Sues.remainingClause(1) == "；再错一次就锁定了，请先确认密码")
        #expect(Sues.remainingClause(0) == "；再错一次就锁定了，请先确认密码")
    }

    // MARK: - Arrival Mark (§2)

    @Test("到达判据只认正文里那三个标记")
    func arrivalMarks() {
        #expect(Sues.arrivalMark("\"arrival|个人信息\"") == "个人信息")
        #expect(Sues.arrivalMark("arrival|注销") == "注销")
        #expect(Sues.arrivalMark("arrival|资源站点") == "资源站点")

        #expect(Sues.arrivalMark("arrival|none") == nil)
        #expect(Sues.arrivalMark("arrival|err") == nil)
        #expect(Sues.arrivalMark("arrival|") == nil)
        #expect(Sues.arrivalMark("null") == nil)
        #expect(Sues.arrivalMark(nil) == nil)
    }

    // MARK: - Error Text & Lockout Remaining (§7)

    @Test(
        "剩余次数不写死句式",
        arguments: [
            ("密码错误。再输错3次，账号将被锁定。", 3),
            ("密码错误，还可以试2次", 2),
            ("还可尝试2次", 2),
            ("剩余1次", 1),
        ]
    )
    func lockoutRemainingFlexiblePhrasing(text: String, expected: Int) {
        #expect(Sues.lockoutRemaining(text) == expected)
    }

    @Test(
        "凭据否定的文案判据",
        arguments: [
            "密码错误。再输错3次，账号将被锁定。",
            "密码错误，还可以试2次",
        ]
    )
    func credentialErrorMessages(text: String) {
        #expect(Sues.hasCredentialError(text))
    }

    @Test(
        "没有次数信息时剩余为空",
        arguments: [
            "密码错误，请重试。",
            "账号&密码错误",
        ]
    )
    func missingRemainingCountReturnsNil(text: String) {
        #expect(Sues.hasCredentialError(text))
        #expect(Sues.lockoutRemaining(text) == nil)
    }

    @Test("过期不得当成密码错误")
    func expiredIsNotCredentialError() {
        #expect(Sues.isPasswordExpired("根据密码安全策略，您的密码已过期，请及时更新！"))
        #expect(!Sues.hasCredentialError("密码已过期"))
        #expect(Sues.isLockoutCritical(1))
        #expect(Sues.isLockoutCritical(0))
        #expect(!Sues.isLockoutCritical(2))
        #expect(!Sues.isLockoutCritical(nil))
    }

    @Test("认证页回传值的解析")
    func casObservationParsing() {
        let obs = Sues.casObservationFrom("\"obs|1|1|1|根据密码安全策略，您的密码已过期！\"")
        #expect(obs.expired)
        #expect(obs.hasForm)
        #expect(obs.hasCaptcha)
        #expect(obs.prompt.contains("密码已过期"))

        let bad = Sues.casObservationFrom("null")
        #expect(!bad.expired)
        #expect(!bad.hasForm)
        #expect(bad.prompt == "")

        #expect(Sues.casKindOf(obs) == .expired)
        #expect(
            Sues.casKindOf(
                Sues.casObservationFrom("\"obs|0|1|0|密码错误。再输错3次，账号将被锁定。\"")
            ) == .rejected
        )
        #expect(Sues.casKindOf(Sues.casObservationFrom("\"obs|0|1|1|\"")) == .form)
    }

    // MARK: - Probe Result (§7)

    @Test("探测回传值解析")
    func probeHrefParsing() {
        #expect(Sues.probeHref("\"portal|/https\\/abc/student/home\"") == "/https/abc/student/home")
        #expect(Sues.probeHref("\"expired\"") == nil)
        #expect(Sues.probeHref("\"cas\"") == nil)
        #expect(Sues.probeHref("\"other\"") == nil)
        #expect(Sues.probeHref("\"\"") == nil)
        #expect(Sues.probeHref("portal|") == nil)
    }
}
