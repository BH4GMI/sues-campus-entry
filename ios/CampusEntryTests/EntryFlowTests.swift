import XCTest
@testable import CampusEntry

// 由 `pc/tests/CampusEntry.Tests/EntryFlowTests.cs` 逐条翻译而来（权威来源是 C#）。
// 用例数：C# 23 个 [Fact]（没有 [Theory]），这里同样是 23 个 func。

// C# 里这些是类内 `private const string` / `private static readonly`；
// Swift 的顶层文件私有常量等价（`private` 在文件作用域即 fileprivate，不会与其它测试文件重名）。
private let prefix =
    "https://webvpn.sues.edu.cn/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b"
private let ssoUrl = prefix + "/student/sso/login"
private let jxfwHome = prefix + "/student/home"
private let casUrl =
    "https://webvpn.sues.edu.cn/https/f3f652d234256d43300d8db9d6562d/cas/login?service=x"
private let secondLogin = prefix + "/student/login?refer=https://jxfw.sues.edu.cn/student/home"
private let transient = "https://webvpn.sues.edu.cn/wengine-vpn/failed"

private let expired = Sues.CasObservation(
    expired: true, hasForm: false, hasCaptcha: true,
    prompt: "根据密码安全策略，您的密码已过期，请及时更新！")
private let rejected = Sues.CasObservation(
    expired: false, hasForm: true, hasCaptcha: false,
    prompt: "密码错误。再输错3次，账号将被锁定。")
private let normalForm = Sues.CasObservation(
    expired: false, hasForm: true, hasCaptcha: true, prompt: "")

/// `EntryFlow.Action` 在 iOS 实现里没有声明 `Equatable`，`XCTAssertEqual` 用不了，
/// 所以按分支映射成字符串再断言（对应 C# 的 `Assert.Equal(Action.Settle, …)`）。
/// `switch` 必须穷举全部 case，漏一个编译不过——这个映射不会悄悄放过新增的分支。
private func actionLabel(_ action: EntryFlow.Action) -> String {
    switch action {
    case .nothing: return "nothing"
    case .inspectCas: return "inspectCas"
    case .assistCas: return "assistCas"
    case .skipExpired: return "skipExpired"
    case .rejectCredentials: return "rejectCredentials"
    case .transient: return "transient"
    case .settle: return "settle"
    case .clearPrefix: return "clearPrefix"
    case .secondLogin: return "secondLogin"
    case .probePortal: return "probePortal"
    case .verifyArrival: return "verifyArrival"
    }
}

/// 导航状态机（与 Android 端 EntryFlowTest 等价，含否定的归因用例）。
final class EntryFlowTests: XCTestCase {

    /// C# 的 `Visit`：新文档开始 + 加载完成。返回动作供断言，丢弃返回值也合法
    ///（C# 里那几处只调用不断言的地方就是丢掉返回值）。
    @discardableResult
    private func visit(_ flow: EntryFlow, _ url: String) -> EntryFlow.Action {
        flow.onDocumentStarted()
        return flow.onDocumentFinished(url)
    }

    func test没有缓存前缀时先回门户读前缀() {
        let flow = EntryFlow()
        flow.start(.jxfw, false)
        XCTAssertEqual("probePortal", actionLabel(visit(flow, Sues.portal)))
    }

    func test用缓存前缀直打教务系统就停手() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        XCTAssertEqual("settle", actionLabel(visit(flow, ssoUrl)))
        XCTAssertTrue(flow.isSettled)
        XCTAssertEqual("nothing", actionLabel(visit(flow, jxfwHome)))
    }

    func test缓存前缀已失效才清前缀() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        XCTAssertEqual("clearPrefix", actionLabel(visit(flow, prefix + "/something-else")))
    }

    func test经过认证页之后落在门户不算前缀失效() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        XCTAssertEqual("inspectCas", actionLabel(visit(flow, casUrl)))
        XCTAssertEqual("probePortal", actionLabel(visit(flow, prefix + "/")))
    }

    func test停手之后落到换票中转页也不重载() {
        let flow = EntryFlow()
        flow.start(.webvpn, true)
        XCTAssertEqual("verifyArrival", actionLabel(visit(flow, Sues.portal)))
        XCTAssertEqual("settle", actionLabel(flow.confirmArrival()))
        // §4 第 2 条先于第 3 条：停手了就不再有「等它自己跳 + 超时重载」这回事
        XCTAssertEqual("nothing", actionLabel(visit(flow, transient)))
    }

    func test换票中转页不清前缀等待它自己跳() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        XCTAssertEqual("transient", actionLabel(visit(flow, transient)))
        XCTAssertFalse(flow.isSettled)
        XCTAssertEqual("settle", actionLabel(visit(flow, jxfwHome)))
    }

    func test认证页的三种状态各走各的() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        XCTAssertEqual("inspectCas", actionLabel(visit(flow, casUrl)))
        // 过期优先，先跳过它
        XCTAssertEqual("skipExpired", actionLabel(flow.onCasObserved(expired)))
        // 服务端否定凭据：停手不重试
        XCTAssertEqual("rejectCredentials", actionLabel(flow.onCasObserved(rejected)))
        // 正常表单：勾记住我 + 装监视器
        XCTAssertEqual("assistCas", actionLabel(flow.onCasObserved(normalForm)))
    }

    func test见过认证页会把停手复位() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        XCTAssertEqual("settle", actionLabel(visit(flow, jxfwHome)))
        XCTAssertEqual("inspectCas", actionLabel(visit(flow, casUrl)))
        XCTAssertFalse(flow.isSettled)
    }

    func test停手之后不再替用户导航() {
        let flow = EntryFlow()
        flow.start(.webvpn, true)
        XCTAssertEqual("verifyArrival", actionLabel(visit(flow, Sues.portal)))
        XCTAssertEqual("settle", actionLabel(flow.confirmArrival()))
        XCTAssertEqual("nothing", actionLabel(visit(flow, prefix + "/other/page")))
        XCTAssertEqual("nothing", actionLabel(visit(flow, secondLogin)))
    }

    func test门户入口要先验正文才停手() {
        let flow = EntryFlow()
        flow.start(.webvpn, true)
        XCTAssertEqual("verifyArrival", actionLabel(visit(flow, Sues.portal)))
        // §2：URL 落在门户主机只说明「到过」，没验正文之前不算到达
        XCTAssertFalse(flow.isSettled)
        XCTAssertEqual("settle", actionLabel(flow.confirmArrival()))
        XCTAssertTrue(flow.isSettled)
        XCTAssertEqual("nothing", actionLabel(visit(flow, Sues.portal + "/other")))
    }

    func test教务系统入口按地址形状到达不看门户标记() {
        // 那三个标记是**门户**的（教务系统首页没有它们），所以 /https/<编码>/student/ 那一支
        // 不能被要求验正文——否则主路径永不落定。
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        XCTAssertEqual("settle", actionLabel(visit(flow, jxfwHome)))
        XCTAssertTrue(flow.isSettled)
    }

    func test二次登录页只提示不自动填() {
        let flow = EntryFlow()
        flow.start(.jxfw, false)
        XCTAssertEqual("secondLogin", actionLabel(visit(flow, secondLogin)))
    }

    func test同一份文档重复回调只处理一次() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        XCTAssertEqual("settle", actionLabel(visit(flow, jxfwHome)))
        XCTAssertEqual("nothing", actionLabel(flow.onDocumentFinished(jxfwHome)))
        XCTAssertEqual("nothing", actionLabel(flow.onDocumentFinished(jxfwHome)))
    }

    func test站点自己开的标签页不劫持用户() {
        let flow = EntryFlow()
        flow.adopt()
        XCTAssertEqual("nothing", actionLabel(visit(flow, Sues.portal)))
        XCTAssertEqual("nothing", actionLabel(visit(flow, jxfwHome)))
        XCTAssertEqual("nothing", actionLabel(visit(flow, transient)))
        XCTAssertEqual("inspectCas", actionLabel(visit(flow, casUrl)))
        XCTAssertEqual("assistCas", actionLabel(flow.onCasObserved(normalForm)))
        XCTAssertEqual("nothing", actionLabel(visit(flow, Sues.portal)))
    }

    func test重新点入口会把状态清干净() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        visit(flow, jxfwHome)
        flow.start(.webvpn, true)
        XCTAssertFalse(flow.isSettled)
        XCTAssertEqual(Sues.Entry.webvpn, flow.entry)
        XCTAssertEqual("verifyArrival", actionLabel(visit(flow, Sues.portal)))
    }

    // ------------------------------------------------ 门户探测的自续重试（S1 回归）

    /// 上限的账本住在状态机里，所以这条用例能钉住它。
    /// 回归的缺陷：宿主在重试路径上顺手把计数清零 → 上限永远到不了 → 无限轮询，
    /// 「没在门户里找到教务系统入口」的提示成了死代码。
    /// 循环必须有界：真回归时要"失败"，不能把测试跑成挂死。
    func test门户探测最多自续十五发然后交回用户() {
        let flow = EntryFlow()
        flow.start(.jxfw, false)
        XCTAssertEqual("probePortal", actionLabel(visit(flow, Sues.portal)))

        var retries = 0
        while flow.onProbeMissed(Sues.portal) && retries < 100 { retries += 1 }
        XCTAssertEqual(EntryFlow.probeMaxAttempts, retries)
    }

    func test换一页会重新计探测次数() {
        let flow = EntryFlow()
        flow.start(.jxfw, false)
        for _ in 0..<EntryFlow.probeMaxAttempts {
            XCTAssertTrue(flow.onProbeMissed(Sues.portal))
        }
        XCTAssertFalse(flow.onProbeMissed(Sues.portal))
        // 门户自己跳一步就到新页面：预算应当重来
        XCTAssertTrue(flow.onProbeMissed(Sues.portal + "/login"))
    }

    func test重新点入口会把探测次数清零() {
        let flow = EntryFlow()
        flow.start(.jxfw, false)
        // 有界：把预算跑干（真回归时下面那句会失败，不会挂死）
        for _ in 0..<100 {
            if !flow.onProbeMissed(Sues.portal) { break }
        }
        XCTAssertFalse(flow.onProbeMissed(Sues.portal))
        flow.start(.jxfw, false)
        XCTAssertTrue(flow.onProbeMissed(Sues.portal))
    }

    // ------------------------------------------------ 否定的归因：待判决标志，不是文档序号

    /// 登录提交是整页导航，服务端的否定落在下一份新文档上（PROTOCOL §6）。
    /// 用「文档序号相等」归因永远差一——已存凭据被否定时不会删。
    func test自动提交后的否定落在下一份文档上也归因给应用() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        visit(flow, casUrl)                     // 认证页（文档 N）
        _ = flow.onCasObserved(normalForm)
        flow.onAutoSubmitted()                  // 按下登录的那一刻
        flow.onDocumentStarted()                // 服务端回应是一份新文档（N+1）
        XCTAssertEqual("inspectCas", actionLabel(flow.onDocumentFinished(casUrl)))
        XCTAssertEqual("rejectCredentials", actionLabel(flow.onCasObserved(rejected)))
        // 否定必须归因给应用那次提交
        XCTAssertTrue(flow.consumeAutoVerdict())
    }

    func test用户自己提交后的否定不归因给应用() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        visit(flow, casUrl)
        flow.onAutoSubmitted()
        flow.onUserSubmitted()
        flow.onDocumentStarted()
        _ = flow.onDocumentFinished(casUrl)
        _ = flow.onCasObserved(rejected)
        XCTAssertFalse(flow.consumeAutoVerdict())
    }

    func test判决读走即清_第二次否定不会再次归因给应用() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        visit(flow, casUrl)
        flow.onAutoSubmitted()
        flow.onDocumentStarted()
        _ = flow.onDocumentFinished(casUrl)
        _ = flow.onCasObserved(rejected)
        XCTAssertTrue(flow.consumeAutoVerdict())
        flow.onDocumentStarted()
        _ = flow.onDocumentFinished(casUrl)
        _ = flow.onCasObserved(rejected)
        XCTAssertFalse(flow.consumeAutoVerdict())
    }

    func test登录成功与重开流程都会清掉待判决() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        visit(flow, casUrl)
        flow.onAutoSubmitted()
        flow.onDocumentStarted()
        XCTAssertEqual("settle", actionLabel(flow.onDocumentFinished(jxfwHome)))
        XCTAssertFalse(flow.consumeAutoVerdict())

        flow.onAutoSubmitted()
        flow.start(.jxfw, true)
        XCTAssertFalse(flow.consumeAutoVerdict())
    }

    func test页面没填成就把待判决作废() {
        let flow = EntryFlow()
        flow.start(.jxfw, true)
        visit(flow, casUrl)
        flow.onAutoSubmitted()
        flow.onAutoSubmitAborted()
        XCTAssertFalse(flow.consumeAutoVerdict())
    }
}
