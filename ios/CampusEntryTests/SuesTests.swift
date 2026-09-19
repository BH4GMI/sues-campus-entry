import XCTest
@testable import CampusEntry

// 由 `pc/tests/CampusEntry.Tests/SuesTests.cs` 逐条翻译而来（权威来源是 C#）。
// 用例数：C# 9 个 [Fact] + 3 个 [Theory]（4 + 2 + 2 条 InlineData）= 17 条向量，
// 这里同样是 9 个 func + 3 个循环，循环里的断言逐条覆盖 17 条向量。

// C# 里这两个是类内 `private const string`；Swift 的顶层文件私有常量等价
//（`private` 在文件作用域即 fileprivate，不会与其它测试文件重名）。
private let prefix =
    "https://webvpn.sues.edu.cn/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b"
private let casUrl =
    "https://webvpn.sues.edu.cn/https/f3f652d234256d43300d8db9d6562d/cas/login?service=x"

/// `Sues.CasKind` 在 iOS 实现里没有声明 `Equatable`，`XCTAssertEqual` 用不了，
/// 所以按分支映射成字符串再断言（对应 C# 的 `Assert.Equal(Sues.CasKind.Expired, …)`）。
/// `switch` 必须穷举全部 case，漏一个编译不过——这个映射不会悄悄放过新增的分支。
private func casKindLabel(_ kind: Sues.CasKind) -> String {
    switch kind {
    case .expired: return "expired"
    case .rejected: return "rejected"
    case .form: return "form"
    case .captcha: return "captcha"
    case .other: return "other"
    }
}

/// docs/CORE-SPEC.md §7 的等价测试向量（与 Android 端 SuesTest 一致）。
final class SuesTests: XCTestCase {

    // ------------------------------------------------ 落点（§7）

    func test无前缀的教务入口回退门户() {
        XCTAssertEqual("https://webvpn.sues.edu.cn", Sues.entryUrl(nil, .jxfw))
        XCTAssertEqual(prefix + "/student/sso/login", Sues.entryUrl(prefix, .jxfw))
        XCTAssertEqual("https://webvpn.sues.edu.cn", Sues.entryUrl(prefix, .webvpn))
    }

    // ------------------------------------------------ 前缀形状（§7）

    func test前缀只认形状不认取值() {
        XCTAssertTrue(Sues.isPrefix(prefix))
        XCTAssertFalse(Sues.isPrefix("https://webvpn.sues.edu.cn"))
        XCTAssertFalse(Sues.isPrefix("https://webvpn.sues.edu.cn/https/"))
        XCTAssertFalse(Sues.isPrefix("https://webvpn.sues.edu.cn/https/zzzz"))
        XCTAssertFalse(Sues.isPrefix(prefix + "/student/home"))
        XCTAssertFalse(Sues.isPrefix("/https/abc123"))
    }

    func test从门户redirect推出前缀() {
        let page = "https://webvpn.sues.edu.cn/"
        XCTAssertEqual(prefix, Sues.prefixFrom(
            "/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b/student/home", page))
        XCTAssertNil(Sues.prefixFrom("/http/abc123/student/home", page))
        XCTAssertNil(Sues.prefixFrom("", page))
        XCTAssertNil(Sues.prefixFrom(nil, page))
    }

    // ------------------------------------------------ 页面身份（§7）

    func test页面身份判据() {
        XCTAssertTrue(Sues.isJxfwPage(prefix + "/student/home"))
        XCTAssertFalse(Sues.isSecondLoginPage(prefix + "/student/home"))
        XCTAssertTrue(Sues.isJxfwPage(prefix + "/student/sso/login"))
        XCTAssertFalse(Sues.isSecondLoginPage(prefix + "/student/sso/login"))
        XCTAssertTrue(Sues.isSecondLoginPage(
            prefix + "/student/login?refer=https://jxfw.sues.edu.cn/student/home"))
        XCTAssertTrue(Sues.isCasPage(casUrl))
        XCTAssertFalse(Sues.isJxfwPage(casUrl))
        XCTAssertFalse(Sues.isJxfwPage("https://webvpn.sues.edu.cn/http/abc123/eams/index.action"))
        XCTAssertFalse(Sues.isJxfwPage("https://webvpn.sues.edu.cn/http/abc123/eams/index.action"))

        let transient = "https://webvpn.sues.edu.cn/wengine-vpn/failed"
        XCTAssertTrue(Sues.isTransientPage(transient))
        XCTAssertFalse(Sues.isJxfwPage(transient))
        XCTAssertFalse(Sues.isCasPage(transient))
        // 别的站点上恰好同名的路径不算网关中转页
        XCTAssertFalse(Sues.isTransientPage("https://other.example.com/wengine-vpn/failed"))
    }

    // ------------------------------------------------ 凭据页的主机判据（§6.1）

    /// 「认证页」是**页面身份**（只看路径），「凭据页」才是**允许碰凭据**的页面（还要主机对）。
    /// 两者分开：网关改写的第三方页面路径里同样有 /cas/login，只看路径会把学校凭据填进去。
    func test凭据页必须是门户主机() {
        XCTAssertTrue(Sues.isCredentialPage(casUrl))
        XCTAssertFalse(Sues.isCredentialPage("https://jxfw.sues.edu.cn/cas/login?service=x"))
        XCTAssertFalse(Sues.isCredentialPage("https://example.com/cas/login"))
        // 只是身份判据变了没变：路径对就算认证页，但不算凭据页
        XCTAssertTrue(Sues.isCasPage("https://example.com/cas/login"))
        XCTAssertFalse(Sues.isCredentialPage(prefix + "/student/home"))
    }

    // ------------------------------------------------ 剩余次数的措辞（APP-UX §5）

    /// 「剩余次数」是**追加**而不是替换：这条规则曾经被写成三选一，于是「再错一次就锁定了」
    /// 对「用已存凭据被否定」永远不可达——而那恰好是最可能只剩一次的场景。
    func test剩余次数是追加的一句且N不大于一时改口() {
        XCTAssertNil(Sues.remainingClause(nil))
        XCTAssertEqual("；还可以试 3 次", Sues.remainingClause(3))
        XCTAssertEqual("；还可以试 2 次", Sues.remainingClause(2))
        XCTAssertEqual("；再错一次就锁定了，请先确认密码", Sues.remainingClause(1))
        XCTAssertEqual("；再错一次就锁定了，请先确认密码", Sues.remainingClause(0))
    }

    // ------------------------------------------------ 到达判据（§2 的正文标记）

    /// §2：不能只看 URL 是否落在门户主机——换票中转页与门户自己的错误页都满足它，只说明「到过」。
    /// 权威判据是正文含 `个人信息` / `注销` / `资源站点`；标记表在 `shared/js/arrival.js` 里。
    func test到达判据只认正文里那三个标记() {
        XCTAssertEqual("个人信息", Sues.arrivalMark("\"arrival|个人信息\""))
        XCTAssertEqual("注销", Sues.arrivalMark("arrival|注销"))
        XCTAssertEqual("资源站点", Sues.arrivalMark("arrival|资源站点"))
        // 没命中 / 脚本出错 / 形状不认得：一律「没确认」，不猜
        XCTAssertNil(Sues.arrivalMark("arrival|none"))
        XCTAssertNil(Sues.arrivalMark("arrival|err"))
        XCTAssertNil(Sues.arrivalMark("arrival|"))
        XCTAssertNil(Sues.arrivalMark("null"))
        XCTAssertNil(Sues.arrivalMark(nil))
    }

    // ------------------------------------------------ 错误文本与剩余次数（§7）

    /// C# 的 `[Theory]` + 4 条 `[InlineData]`。XCTest 没有内建参数化，用循环逐条断言：
    /// 失败消息里带上输入，一条失败就能定位到具体向量，且每条向量都真的被断言过。
    func test剩余次数不写死句式() {
        let cases: [(text: String, expected: Int)] = [
            ("密码错误。再输错3次，账号将被锁定。", 3),
            ("密码错误，还可以试2次", 2),
            ("还可尝试2次", 2),
            ("剩余1次", 1),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(expected, Sues.lockoutRemaining(text), "用例: \(text)")
        }
    }

    /// C# 的 `[Theory]` + 2 条 `[InlineData]`。
    func test凭据否定的文案判据() {
        let cases = [
            "密码错误。再输错3次，账号将被锁定。",
            "密码错误，还可以试2次",
        ]
        for text in cases {
            XCTAssertTrue(Sues.hasCredentialError(text), "用例: \(text)")
        }
    }

    /// C# 的 `[Theory]` + 2 条 `[InlineData]`。
    func test没有次数信息时剩余为空() {
        let cases = [
            "密码错误，请重试。",
            "账号&密码错误",
        ]
        for text in cases {
            XCTAssertTrue(Sues.hasCredentialError(text), "用例: \(text)")
            XCTAssertNil(Sues.lockoutRemaining(text), "用例: \(text)")
        }
    }

    func test过期不得当成密码错误() {
        XCTAssertTrue(Sues.isPasswordExpired("根据密码安全策略，您的密码已过期，请及时更新！"))
        XCTAssertFalse(Sues.hasCredentialError("密码已过期"))
        XCTAssertTrue(Sues.isLockoutCritical(1))
        XCTAssertTrue(Sues.isLockoutCritical(0))
        XCTAssertFalse(Sues.isLockoutCritical(2))
        XCTAssertFalse(Sues.isLockoutCritical(nil))
    }

    func test认证页回传值的解析() {
        let obs = Sues.casObservationFrom("\"obs|1|1|1|根据密码安全策略，您的密码已过期！\"")
        XCTAssertTrue(obs.expired)
        XCTAssertTrue(obs.hasForm)
        XCTAssertTrue(obs.hasCaptcha)
        XCTAssertTrue(obs.prompt.contains("密码已过期"))

        // 认不出的形状一律当成「什么都没看到」，不猜
        let bad = Sues.casObservationFrom("null")
        XCTAssertFalse(bad.expired)
        XCTAssertFalse(bad.hasForm)
        XCTAssertEqual("", bad.prompt)

        XCTAssertEqual("expired", casKindLabel(Sues.casKindOf(obs)))
        XCTAssertEqual("rejected", casKindLabel(Sues.casKindOf(
            Sues.casObservationFrom("\"obs|0|1|0|密码错误。再输错3次，账号将被锁定。\""))))
        XCTAssertEqual("form", casKindLabel(Sues.casKindOf(Sues.casObservationFrom("\"obs|0|1|1|\""))))
    }

    // ------------------------------------------------ 探测结果解析（§7）

    func test探测回传值解析() {
        XCTAssertEqual("/https/abc/student/home", Sues.probeHref("\"portal|/https\\/abc/student/home\""))
        XCTAssertNil(Sues.probeHref("\"expired\""))
        XCTAssertNil(Sues.probeHref("\"cas\""))
        XCTAssertNil(Sues.probeHref("\"other\""))
        XCTAssertNil(Sues.probeHref("\"\""))
        XCTAssertNil(Sues.probeHref("portal|"))
    }
}
