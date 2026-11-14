import Testing
@testable import CampusEntryCore

/// Equivalent navigation state machine tests from `EntryFlowTests.cs`.
@Suite("EntryFlow State Machine")
struct EntryFlowTests {
    private static let prefix =
        "https://webvpn.sues.edu.cn/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b"
    private static let ssoURL = prefix + "/student/sso/login"
    private static let jxfwHome = prefix + "/student/home"
    private static let casURL =
        "https://webvpn.sues.edu.cn/https/f3f652d234256d43300d8db9d6562d/cas/login?service=x"
    private static let secondLogin = prefix + "/student/login?refer=https://jxfw.sues.edu.cn/student/home"
    private static let transient = "https://webvpn.sues.edu.cn/wengine-vpn/failed"

    private static let expired = Sues.CasObservation(
        expired: true,
        hasForm: false,
        hasCaptcha: true,
        prompt: "根据密码安全策略，您的密码已过期，请及时更新！"
    )
    private static let rejected = Sues.CasObservation(
        expired: false,
        hasForm: true,
        hasCaptcha: false,
        prompt: "密码错误。再输错3次，账号将被锁定。"
    )
    private static let normalForm = Sues.CasObservation(
        expired: false,
        hasForm: true,
        hasCaptcha: true,
        prompt: ""
    )

    private func visit(_ flow: EntryFlow, _ url: String) -> EntryFlow.Action {
        flow.onDocumentStarted()
        return flow.onDocumentFinished(url)
    }

    @Test("没有缓存前缀时先回门户读前缀")
    func probePortalWithoutCachedPrefix() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: false)
        #expect(visit(flow, Sues.portal) == .probePortal)
    }

    @Test("用缓存前缀直打教务系统就停手")
    func directHitWithCachedPrefixSettles() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        #expect(visit(flow, Self.ssoURL) == .settle)
        #expect(flow.isSettled)
        #expect(visit(flow, Self.jxfwHome) == .nothing)
    }

    @Test("缓存前缀已失效才清前缀")
    func clearsInvalidatedCachedPrefix() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        #expect(visit(flow, Self.prefix + "/something-else") == .clearPrefix)
    }

    @Test("经过认证页之后落在门户不算前缀失效")
    func landingOnPortalAfterCasDoesNotClearPrefix() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        #expect(visit(flow, Self.casURL) == .inspectCas)
        #expect(visit(flow, Self.prefix + "/") == .probePortal)
    }

    @Test("停手之后落到换票中转页也不重载")
    func settledIgnoresTransientPage() {
        let flow = EntryFlow()
        flow.start(entry: .webvpn, hasCachedPrefix: true)
        #expect(visit(flow, Sues.portal) == .verifyArrival)
        #expect(flow.confirmArrival() == .settle)
        #expect(visit(flow, Self.transient) == .nothing)
    }

    @Test("换票中转页不清前缀等待它自己跳")
    func transientPageWaitsWithoutClearingPrefix() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        #expect(visit(flow, Self.transient) == .transient)
        #expect(!flow.isSettled)
        #expect(visit(flow, Self.jxfwHome) == .settle)
    }

    @Test("认证页的三种状态各走各的")
    func casObservationActions() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        #expect(visit(flow, Self.casURL) == .inspectCas)
        #expect(flow.onCasObserved(Self.expired) == .skipExpired)
        #expect(flow.onCasObserved(Self.rejected) == .rejectCredentials)
        #expect(flow.onCasObserved(Self.normalForm) == .assistCas)
    }

    @Test("见过认证页会把停手复位")
    func casPageResetsSettledState() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        #expect(visit(flow, Self.jxfwHome) == .settle)
        #expect(visit(flow, Self.casURL) == .inspectCas)
        #expect(!flow.isSettled)
    }

    @Test("停手之后不再替用户导航")
    func settledStopsNavigating() {
        let flow = EntryFlow()
        flow.start(entry: .webvpn, hasCachedPrefix: true)
        #expect(visit(flow, Sues.portal) == .verifyArrival)
        #expect(flow.confirmArrival() == .settle)
        #expect(visit(flow, Self.prefix + "/other/page") == .nothing)
        #expect(visit(flow, Self.secondLogin) == .nothing)
    }

    @Test("门户入口要先验正文才停手")
    func webvpnEntryRequiresConfirmArrival() {
        let flow = EntryFlow()
        flow.start(entry: .webvpn, hasCachedPrefix: true)
        #expect(visit(flow, Sues.portal) == .verifyArrival)
        #expect(!flow.isSettled)
        #expect(flow.confirmArrival() == .settle)
        #expect(flow.isSettled)
        #expect(visit(flow, Sues.portal + "/other") == .nothing)
    }

    @Test("教务系统入口按地址形状到达不看门户标记")
    func jxfwEntrySettlesByUrlShape() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        #expect(visit(flow, Self.jxfwHome) == .settle)
        #expect(flow.isSettled)
    }

    @Test("二次登录页只提示不自动填")
    func secondLoginReportsWithoutAutofill() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: false)
        #expect(visit(flow, Self.secondLogin) == .secondLogin)
    }

    @Test("同一份文档重复回调只处理一次")
    func duplicateDocumentFinishedHandledOnce() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        #expect(visit(flow, Self.jxfwHome) == .settle)
        #expect(flow.onDocumentFinished(Self.jxfwHome) == .nothing)
        #expect(flow.onDocumentFinished(Self.jxfwHome) == .nothing)
    }

    @Test("站点自己开的标签页不劫持用户")
    func adoptedTabAssistsCasOnly() {
        let flow = EntryFlow()
        flow.adopt()
        #expect(visit(flow, Sues.portal) == .nothing)
        #expect(visit(flow, Self.jxfwHome) == .nothing)
        #expect(visit(flow, Self.transient) == .nothing)
        #expect(visit(flow, Self.casURL) == .inspectCas)
        #expect(flow.onCasObserved(Self.normalForm) == .assistCas)
        #expect(visit(flow, Sues.portal) == .nothing)
    }

    @Test("重新点入口会把状态清干净")
    func restartResetsState() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        _ = visit(flow, Self.jxfwHome)
        flow.start(entry: .webvpn, hasCachedPrefix: true)
        #expect(!flow.isSettled)
        #expect(flow.entry == .webvpn)
        #expect(visit(flow, Sues.portal) == .verifyArrival)
    }

    // MARK: - Portal Probe Retry Limit (S1 Regression)

    @Test("门户探测最多自续十五发然后交回用户")
    func portalProbeMaxAttempts() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: false)
        #expect(visit(flow, Sues.portal) == .probePortal)

        var retries = 0
        while flow.onProbeMissed(Sues.portal) && retries < 100 {
            retries += 1
        }
        #expect(retries == EntryFlow.probeMaxAttempts)
    }

    @Test("换一页会重新计探测次数")
    func probeRetriesResetOnNewUrl() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: false)
        for _ in 0..<EntryFlow.probeMaxAttempts {
            #expect(flow.onProbeMissed(Sues.portal))
        }
        #expect(!flow.onProbeMissed(Sues.portal))
        #expect(flow.onProbeMissed(Sues.portal + "/login"))
    }

    @Test("重新点入口会把探测次数清零")
    func probeRetriesResetOnStart() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: false)
        var i = 0
        while i < 100 && flow.onProbeMissed(Sues.portal) {
            i += 1
        }
        #expect(!flow.onProbeMissed(Sues.portal))
        flow.start(entry: .jxfw, hasCachedPrefix: false)
        #expect(flow.onProbeMissed(Sues.portal))
    }

    // MARK: - Rejection Verdict Attribution

    @Test("自动提交后的否定落在下一份文档上也归因给应用")
    func autoSubmissionVerdictSurvivesNextDocument() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        _ = visit(flow, Self.casURL)
        _ = flow.onCasObserved(Self.normalForm)
        flow.onAutoSubmitted()
        flow.onDocumentStarted()
        #expect(flow.onDocumentFinished(Self.casURL) == .inspectCas)
        #expect(flow.onCasObserved(Self.rejected) == .rejectCredentials)
        #expect(flow.consumeAutoVerdict())
    }

    @Test("用户自己提交后的否定不归因给应用")
    func userSubmissionClearsAutoVerdict() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        _ = visit(flow, Self.casURL)
        flow.onAutoSubmitted()
        flow.onUserSubmitted()
        flow.onDocumentStarted()
        _ = flow.onDocumentFinished(Self.casURL)
        _ = flow.onCasObserved(Self.rejected)
        #expect(!flow.consumeAutoVerdict())
    }

    @Test("判决读走即清_第二次否定不会再次归因给应用")
    func verdictConsumedOnce() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        _ = visit(flow, Self.casURL)
        flow.onAutoSubmitted()
        flow.onDocumentStarted()
        _ = flow.onDocumentFinished(Self.casURL)
        _ = flow.onCasObserved(Self.rejected)
        #expect(flow.consumeAutoVerdict())
        flow.onDocumentStarted()
        _ = flow.onDocumentFinished(Self.casURL)
        _ = flow.onCasObserved(Self.rejected)
        #expect(!flow.consumeAutoVerdict())
    }

    @Test("登录成功与重开流程都会清掉待判决")
    func settleAndRestartClearAutoVerdict() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        _ = visit(flow, Self.casURL)
        flow.onAutoSubmitted()
        flow.onDocumentStarted()
        #expect(flow.onDocumentFinished(Self.jxfwHome) == .settle)
        #expect(!flow.consumeAutoVerdict())

        flow.onAutoSubmitted()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        #expect(!flow.consumeAutoVerdict())
    }

    @Test("页面没填成就把待判决作废")
    func abortedAutoSubmitClearsVerdict() {
        let flow = EntryFlow()
        flow.start(entry: .jxfw, hasCachedPrefix: true)
        _ = visit(flow, Self.casURL)
        flow.onAutoSubmitted()
        flow.onAutoSubmitAborted()
        #expect(!flow.consumeAutoVerdict())
    }
}
