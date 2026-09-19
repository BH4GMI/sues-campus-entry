import Foundation
import UIKit
import WebKit

// ============================================================================
// 本文件是 PC 端 `pc/src/CampusEntry/Core/EntryHost.cs`（WebView2 宿主）的
// **逐条忠实移植**，平台 API 换成 WKWebView；判断逻辑同时与 Android 端
// `android/app/src/main/java/app/webvpn/entry/EntryHost.kt` 一致（同一份
// `docs/CORE-SPEC.md` / `docs/PROTOCOL.md`）。命名沿用本工程 iOS 侧已落地的
// 风格（`Core/Sues.swift`、`Core/EntryFlow.swift`）：类型与属性小驼峰、
// 枚举成员小驼峰、C# 的 `event Action` → Swift 的 `var onXxx: (() -> Void)?`。
//
// 传输层差异（iOS 独有的三处，其余逐条对应）：
//   1. JS → 原生：`window.webkit.messageHandlers.entry.postMessage(payload)`，
//      通道名固定 `entry`。宿主实现 `WKScriptMessageHandler`。
//   2. 原生 → JS：`webView.evaluateJavaScript(_:)`。**WKWebView 直接回传原生对象**，
//      不像 WebView2 那样把返回值再 JSON 包一层引号，所以 iOS 侧**没有 Unquote**——
//      C# 的 `Unquote(json)` 在这里只保留「非字符串结果不当字符串用」这一层防御。
//   3. 导航事件见 `didStartProvisionalNavigation`（"新文档"判定）处的长注释。
// ============================================================================

/// 底栏正上方那一行状态。（对应 C# `NoticeState` / Kotlin `Notice`。）
public struct Notice: Equatable, Sendable {

    /// 这一行用什么语气显示。
    public enum ToneKind: Sendable {
        case plain
        case alert
        case done
    }

    /// 状态行文字；空串表示「没有状态」。
    public var text: String
    public var tone: ToneKind

    /// 需要用户出手时不再自动消失。
    public var sticky: Bool

    /// 可点的动作（「重试」/「撤销保存」）。
    public var kind: NoticeKind

    public init(
        text: String = "",
        tone: ToneKind = .plain,
        sticky: Bool = false,
        kind: NoticeKind = .none
    ) {
        self.text = text
        self.tone = tone
        self.sticky = sticky
        self.kind = kind
    }

    /// 空白状态（C# 里到处出现的 `new NoticeState()`）。
    public static let none = Notice()
}

/// 状态行上那个可点的动作。（对应 C# `NoticeKind` / Kotlin `Notice.Act`。）
///
/// `undoSave` 与 `clearAccount` 的**效果相同**（清掉本机凭据 + 关掉自动登录），分开只因语境不同、
/// 按钮该写的字不同：刚保存成功是「撤销」，凭据被否定是「清除账号」。
public enum NoticeKind: Sendable {
    case none
    case retry
    case undoSave
    case clearAccount
}

/// 类型名别名：任务书与 C# 那侧叫 `NoticeState` / `NoticeKind`，本工程 iOS 侧
/// 的实现类型是 `Notice` / `NoticeKind`（对齐 Android 的 `Notice`）。两个名字都能用，
/// 不产生第二份类型。
public typealias NoticeState = Notice

/// WebView 宿主：驱动导航状态机、维护界面要显示的状态。与 Android 端 `EntryHost.kt`
/// 逐条对应（同一份 `docs/CORE-SPEC.md`）；差别只在传输层——页面回调走
/// `window.webkit.messageHandlers.entry.postMessage`（见 `ScriptBag.entryShim`），单窗口无标签页。
@MainActor
public final class EntryHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    // ---------------------------------------------------------------- 常量

    private static let tag = "教务直达"

    /// JS → 原生 的消息通道名。契约固定，不要改。
    private static let messageHandlerName = "entry"

    /// 探测的节奏。**发数上限在 `EntryFlow.probeMaxAttempts`**：那是判据，住在状态机里才测得到。
    private static let probeIntervalMs = 600
    private static let captchaMaxAttempts = 3

    /// 每次流程里替用户提交凭据的硬上限（服务端累计失败次数，5 次锁号）。
    private static let autoSubmitMax = 2

    private static let armedTimeoutMs = 20_000
    private static let transientTimeoutMs = 15_000
    private static let transientMaxReloads = 1
    private static let expiredMaxSkips = 1
    private static let noticeTimeoutMs = 2_000
    private static let pendingTimeoutMs = 90_000

    // ---------------------------------------------------------------- 依赖与视图

    private let settings: EntrySettings
    private let repository: CredentialRepository

    /// 页面的宿主视图。（对应 C# 的 `View` 属性，类型从 `WebView2` 换成 `WKWebView`。）
    public let webView: WKWebView

    /// 导航状态机（纯逻辑，见 `Core/EntryFlow.swift`）。
    public let flow = EntryFlow()

    // ---------------------------------------------------------------- 界面镜像状态

    public private(set) var notice: Notice = .none
    public private(set) var home: Bool
    public private(set) var saveAccount: Bool
    public private(set) var savedUsername: String?
    public private(set) var hideNotices: Bool

    /// 当前替哪个入口服务。
    public private(set) var activeEntry: Sues.Entry = .jxfw

    /// 正在加载（对应 Android `Tab.loading`）。
    public private(set) var isLoading: Bool = false

    /// 加载进度 0…100（对应 Android `Tab.progress`）。
    public private(set) var progress: Int = 0

    /// 界面状态有变（通知、开关、首页显隐、加载态），界面层据此刷新。
    /// 对应 C# 的 `event Action? Changed`。
    public var onChanged: (() -> Void)?

    /// WebView 就绪（可以开始导航了）。对应 C# 的 `event Action? Ready`。
    public var onReady: (() -> Void)?

    /// 窗口/导航栏标题跟页面走。对应 C# 的 `event Action<string>? ViewTitleChanged`。
    public var onViewTitleChanged: ((String) -> Void)?

    // ---------------------------------------------------------------- 本次流程的运行时状态（对齐 Android 的 Tab 字段）

    private var autoStopped = false
    private var lastPrompt = ""

    private var probeTick: Timer?

    private var transientTick: Timer?
    private var transientReloads = 0

    private var armedTick: Timer?
    private var captchaAttempts = 0
    private var captchaLastId: String?
    private var captchaGaveUp = false

    private var expiredSkips = 0

    private var pending: Credential?
    private var pendingTick: Timer?

    private var filledDoc = -1
    private var autoSubmits = 0

    private var tweakedDoc = -1

    private var noticeTick: Timer?

    /// 「这一串导航里已经算过一份新文档了」。
    ///
    /// C# 的 `NavigationStarting(!IsRedirected)` 只在**新文档**时进账本，同一串导航内的
    /// 服务端重定向不会再触发。WKWebView 在 iOS 上对同一串导航重复回调
    /// `didStartProvisionalNavigation` 是已知现象（表单重投、同 URL 重发、分片导航），
    /// 而**文档序号**是这个宿主最要紧的账本（`filledDoc` / `tweakedDoc` 都拿它当文档身份，
    /// 见 `docs/CORE-SPEC.md` §4：同一份文档会重复回调）。所以这里用「一串导航只记一次」
    /// 把等价关系写死在自己手里；`didReceiveServerRedirectForProvisionalNavigation` 不记账，
    /// 与 C# 「重定向链不产生新文档」完全对应。
    /// 一串导航只记一次**只是**防重复：真的连着来两份文档（上一份还没结束就开了新的）会少记一次，
    /// 代价是 `filledDoc` / `tweakedDoc` 少认一份文档（表现为「这一份可能再填一次 / 再收起一次」），
    /// 比多记一次导致「文档序号提前用掉、自动填写被跳过」要轻。这一条要在真机上按日志核对。
    private var documentCounted = false

    // ---------------------------------------------------------------- 生命周期

    /// - Parameters:
    ///   - entrySettings: 落盘偏好（对应 C# `EntrySettings`）。
    ///   - credentialRepository: 凭据仓库（对应 C# `CredentialRepository`）。
    ///   - configuration: WKWebView 配置。对应 C# 构造函数里的 `CoreWebView2Environment`——
    ///     同样是「平台环境由调用方给进来」，宿主只在它上面加自己的垫片与消息通道。
    public init(
        settings entrySettings: EntrySettings,
        repository credentialRepository: CredentialRepository,
        configuration: WKWebViewConfiguration
    ) {
        settings = entrySettings
        repository = credentialRepository

        saveAccount = settings.saveAccount
        hideNotices = settings.hideNotices
        // Keychain 解密读一次：**不占主 actor**（构造发生在 App 启动路径上）。
        // 读完刷新界面；读不出来等价于「没存过」，只记日志。
        savedUsername = nil
        loadSavedUsername()
        home = !settings.saveDecided

        let contentController = configuration.userContentController

        // 每份文档创建前注入垫片：把 shared/js 里的 `window.entry.*` 转发到
        // `window.webkit.messageHandlers.entry`。等价于 C# 的
        // `Core.AddScriptToExecuteOnDocumentCreatedAsync(ScriptBag.EntryShim)`。
        contentController.addUserScript(WKUserScript(
            source: ScriptBag.entryShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))

        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        contentController.add(self, name: Self.messageHandlerName)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        // 窗口/导航栏标题跟页面走：C# 用的是 `Core.DocumentTitleChanged`。
        // WKWebView 没有对应的代理回调，官方可观察属性就是 `title`（KVO 合规），
        // 所以用 KVO 顶上——页面标题在文档加载中途变化时也会来。
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.title), options: [.new], context: nil)

        // C# 是在 WebView2 初始化完成回调里挂事件、注入垫片、然后 RaiseReady 的。
        // WKWebView 的承载视图没有「初始化完成」这一步：配置在 init 里就绪。
        //
        // 但**不能在这里回调 `onReady`**：调用方只有拿到 init 的返回值之后才能给 `onReady` 赋值，
        // 在 init 内部触发等于把这个事件永久丢掉（C# 那侧是异步回调，所以事件一定晚于订阅）。
        // 改成由承载方接好回调后显式调 `start()`，语义与 C# 的 Ready 一致。
    }

    /// 承载方接好 `onChanged` / `onViewTitleChanged` / `onReady` 之后调用一次。
    /// 等价于 C# 的 `Ready` 事件：此时才可以安全地开始替用户导航。
    public func start() {
        onReady?()
    }

    // ---------------------------------------------------------------- 视图状态跟随

    /// 对应 C# 的 `Core.DocumentTitleChanged`。
    ///
    /// `observeValue` 是 NSObject 的 Objective-C 方法，这里只处理 `WKWebView.title`；
    /// 其它 keyPath（本项目没注册别的）原样交回父类。
    override public func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == #keyPath(WKWebView.title) else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        let title = (change?[.newKey] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // C# 那侧是 `if (!string.IsNullOrWhiteSpace(Core.DocumentTitle))`：空标题不外报。
        if !title.isEmpty { onViewTitleChanged?(title) }
    }

    /// 后台读一次「已保存的账号」再回主 actor 刷新界面。
    /// 读不出来等价于「没存过」：只记日志，不影响下一步（`.broken` 与「没存过」的处置本来就一样）。
    private func loadSavedUsername() {
        Task { [weak self] in
            guard let self else { return }
            let repository = self.repository
            let name = await Task.detached(priority: .utility) {
                repository.savedUsername()
            }.value
            self.savedUsername = name
            self.raiseChanged()
        }
    }

    // ---------------------------------------------------------------- 界面动作

    public func enterFromHome(_ entry: Sues.Entry) {
        settings.saveDecided = true
        settings.saveAccount = saveAccount
        settings.save()
        home = false
        openEntry(entry)
    }

    public func openHome() {
        home = true
        raiseChanged()
    }

    public func openEntry(_ entry: Sues.Entry) {
        activeEntry = entry
        flow.start(entry, settings.prefix != nil)
        resetRuntime()
        // APP-UX §5「打开」行：这一跳可能几百毫秒，先说一句正在打开哪个入口
        showNotice(Notice(text: entry == .webvpn ? "正在打开校园网关…" : "正在打开教务系统…"))
        let url = Sues.entryUrl(settings.prefix, entry)
        log("打开入口=\(entry) 落点=\(url)")
        load(url)
        raiseChanged()
    }

    public func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    /// 前进（对应 C# `GoForward`；iOS 上由界面的返回/前进控件调用）。
    public func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    public func reload() { webView.reload() }

    public func changeSaveAccount(_ on: Bool) {
        saveAccount = on
        // 只改意愿，不写「已决定」：首页是否出现取决于用户有没有真的进去过（见 enterFromHome）
        settings.saveAccount = on
        settings.save()
        if !on {
            dropPending()
            showNotice(Notice(text: "已关闭自动登录；已保存的账号还在本机，可以随时清除"))
        }
        raiseChanged()
    }

    public func changeHideNotices(_ on: Bool) {
        hideNotices = on
        settings.hideNotices = on
        settings.save()
        tweakedDoc = -1
        Task { [weak self] in
            guard let self else { return }
            let result = await self.eval(ScriptBag.noticeDialogJs(on))
            self.log("通知公告：\(on ? "收起" : "恢复") -> \(result)")
        }
        raiseChanged()
    }

    public func clearAccount() {
        repository.clear()
        savedUsername = nil
        showNotice(Notice(text: "已清除账号", tone: .done))
        raiseChanged()
    }

    /// 清除缓存、退出登录：清 cookie（登录状态就是 cookie），保留已保存的账号密码。
    public func clearSessionAsync() async {
        resetRuntime()
        await clearCookiesAsync()
        openEntry(activeEntry)
        showNotice(Notice(text: "已退出登录；保存的账号还在", tone: .done))
        raiseChanged()
    }

    /// 改用其他账号：清掉会话和本机凭据，回首页重新走一遍。
    public func switchAccountAsync() async {
        repository.clear()
        savedUsername = nil
        resetRuntime()
        await clearCookiesAsync()
        flow.start(activeEntry, false)
        home = true
        raiseChanged()
    }

    /// 删光 cookie 并等到真的删完再继续：否则紧接着那次导航会带着旧 cookie 出去，
    /// 用户看到的就是「点了退出却还是登录状态」。
    ///
    /// 两件事分开做，各自用**对得上的判据**：
    ///   · 删除：`removeData(ofTypes: allWebsiteDataTypes())` —— 退出登录要连缓存一起清（用户点的是「清除缓存」）；
    ///   · 轮询：`httpCookieStore` 的 cookie 数 —— 登录状态就是 cookie，这才是「删干净了没有」的量，
    ///     与 PC 的 `GetCookiesAsync` 逐条对应。
    ///
    /// 早先轮询的是 `fetchDataRecords(ofTypes:)` 的**记录条数**：那是「每个 origin×类型」的记录数，
    /// 与 cookie 条数不是一回事，可能永远降不到 0 —— 那样每次退出都会固定跑满 20 次、并留一条
    /// 误导人的「没有确认完成」。有上界、不空转的原则不变：确认不了就记一条日志继续。
    private func clearCookiesAsync() async {
        let store = webView.configuration.websiteDataStore
        let everything = WKWebsiteDataStore.allWebsiteDataTypes()
        let since = Date(timeIntervalSince1970: 0)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: everything, modifiedSince: since) {
                continuation.resume()
            }
        }

        for _ in 0..<20 {
            let remaining = await store.httpCookieStore.allCookies().count
            if remaining == 0 { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        log("cookie 清理 1 秒内没有确认完成，继续执行（WKWebView 的删除在后台进行）")
    }

    public func onNoticeAction() {
        switch notice.kind {
        case .retry:
            webView.reload()
        case .undoSave:
            repository.clear()
            savedUsername = nil
            changeSaveAccount(false)
            showNotice(Notice(text: "已撤销保存", tone: .done))
        case .clearAccount:
            // 与「撤销保存」同一套动作：清掉本机凭据并关掉自动登录
            repository.clear()
            savedUsername = nil
            changeSaveAccount(false)
            showNotice(Notice(text: "已清除账号", tone: .done))
        case .none:
            break
        }
        raiseChanged()
    }

    // ---------------------------------------------------------------- 生命周期（对应 Android 的 onPause / onResume）

    /// 退到后台：页面计时器不该在后台跑，停掉滑块监视器。
    public func onPause() {
        evalIgnoringResult(ScriptBag.captchaStop)
    }

    /// 回到前台：把滑块监视器装回去。
    ///
    /// 不重装的话自动拖滑块会**静默失效**了——页面还在认证页上等滑块，应用却不再管。
    /// 监视器自带幂等护栏（`__capWatch`），重复注入无害。
    public func onResume() {
        evalIgnoringResult(ScriptBag.captchaWatch)
    }

    // ---------------------------------------------------------------- 状态机的动作

    private func run(_ action: EntryFlow.Action) {
        switch action {
        case .nothing:
            break
        case .inspectCas:
            inspectCas()
        case .assistCas:
            assistCas()
        case .skipExpired:
            skipExpired()
        case .rejectCredentials:
            rejectCredentials()
        case .transient:
            onTransient()
        case .settle:
            settle()
        case .clearPrefix:
            clearPrefix()
        case .secondLogin:
            alert("这里还要再登录一次，请手动")
        case .probePortal:
            probe()
        case .verifyArrival:
            verifyArrival()
        }
    }

    /// 停手前的最后一道判据：**正文**里有没有「确实登录进去了」的标记（CORE-SPEC §2）。
    /// URL 落在门户主机只说明「到过」——换票中转页、门户自己的错误页都满足它。
    /// 确认不了就**不宣布到达**（也不清待判决、不落盘凭据），只留一条状态。
    private func verifyArrival() {
        Task { [weak self] in
            guard let self else { return }
            let mark = Sues.arrivalMark(await self.eval(ScriptBag.arrival))
            guard let mark else {
                self.log("门户页正文没有登录成功的标记，暂不算到达：\(self.webView.url?.absoluteString ?? "")")
                self.showNotice(Notice(text: "正在等待门户加载完成…"))
                return
            }
            self.log("门户页正文确认到达（标记=\(mark)）")
            self.run(self.flow.confirmArrival())
        }
    }

    private func inspectCas() {
        let url = webView.url?.absoluteString ?? ""
        Task { [weak self] in
            guard let self else { return }
            let raw = await self.eval(ScriptBag.casState)
            // 这份脚本是异步回来的，期间页面可能已经换了一份文档：换走了就不认这份观察。
            guard Sues.samePage(url, self.webView.url?.absoluteString) else { return }
            let seen = Sues.casObservationFrom(raw)
            self.log("认证页：过期=\(seen.expired) 表单=\(seen.hasForm) "
                + "滑块=\(seen.hasCaptcha) 提示=\(self.truncate(seen.prompt, 80))")
            self.lastPrompt = seen.prompt
            self.run(self.flow.onCasObserved(seen))
        }
    }

    /// 认证页上该做的辅助：勾「记住我」、装监视器、（用户已同意且已存凭据时）填写并提交一次。
    /// 自动填写是唯一一处「替用户提交凭据」的地方，边界与 Android 端一致。
    private func assistCas() {
        // §6.1 的第一道闸：只有**学校的**统一身份认证页才允许被辅助。
        // 网关把它改写的第三方页面、教务系统自己的 CAS 形态登录页，路径里同样有 /cas/login；
        // 主机判据在这里一次把关，后面所有「碰凭据」的动作就不必各判一遍。
        let current = webView.url?.absoluteString ?? ""
        guard Sues.isCredentialPage(current) else {
            log("这一页不是学校的统一身份认证页，不动它：\(current)")
            return
        }
        evalIgnoringResult(ScriptBag.tickNotice)
        evalIgnoringResult(ScriptBag.captchaWatch)
        if saveAccount { evalIgnoringResult(ScriptBag.credentialWatch) }

        let doc = flow.documentOrdinal
        if filledDoc == doc { return }
        if !saveAccount {
            showNotice(Notice(text: "本次登录不会保存账号", sticky: true))
            return
        }
        if autoSubmits >= Self.autoSubmitMax {
            // 不是重试，是硬上限：连续替用户提交只会消耗失败次数（5 次锁号）
            log("自动提交已达上限 \(autoSubmits) 次，交回用户")
            showNotice(Notice(text: "自动登录没有成功，请手动登录", sticky: true))
            return
        }

        // 解密（Keychain + AES-GCM）挪出主 actor 再回主 actor 继续：界面线程不做 IO / Keychain 调用。
        // `CredentialRepository` **不是** `@MainActor`，所以 detached 闭包里的调用确实跑在后台执行器上
        //（与 `onCaptcha` 里解码/求解那处同一套写法）；这一跳也顺手解决了「等 Keychain 时文档已经换了」
        // ——回到主 actor 后重新对一次文档身份（下面的 filledDoc 判断用的是当前序号，不是上面那个 doc）。
        Task { [weak self] in
            guard let self else { return }
            let repository = self.repository
            let loaded = await Task.detached(priority: .userInitiated) {
                repository.load()
            }.value

            guard let credential = loaded else {
                self.showNotice(Notice(text: "登录一次，之后自动登录", sticky: true))
                return
            }
            // C# 的 `using var credential`：不管走哪条分支，用完都把密码擦掉。
            defer { credential.clear() }

            if self.filledDoc == self.flow.documentOrdinal { return }  // 这一跳之间已经替这份文档填过了
            self.filledDoc = self.flow.documentOrdinal
            self.autoSubmits += 1
            // 判决标志先置上：提交的回应是另一份文档（docs/PROTOCOL.md §6）。页面上真没表单时再作废。
            self.flow.onAutoSubmitted()
            self.showNotice(Notice(text: "正在自动填写账号…"))

            let username = credential.username
            let password = String(credential.password)
            let result = await self.eval(ScriptBag.fillAndSubmitJs(username, password))
            self.log("自动填写并提交：\(result)")
            if result.contains("noform") || result.contains("nobutton") {
                // 页面上没有可填的表单：撤销标记，交给用户
                self.filledDoc = -1
                self.autoSubmits -= 1
                self.flow.onAutoSubmitAborted()
                self.showNotice(Notice(text: "这一页要你手动登录", sticky: true))
            }
        }
    }

    private func skipExpired() {
        evalIgnoringResult(ScriptBag.captchaStop)
        if expiredSkips >= Self.expiredMaxSkips {
            log("密码已过期：跳过 \(expiredSkips) 次后仍回到这一页，停手")
            alert("密码已过期，请点页面上的「点击跳过」继续")
            return
        }
        expiredSkips += 1
        showNotice(Notice(text: "密码已过期，正在跳过…"))
        Task { [weak self] in
            guard let self else { return }
            let result = await self.eval(ScriptBag.skipExpired)
            self.log("跳过密码过期提示：\(result)（第 \(self.expiredSkips) 次）")
        }
    }

    /// 服务端否定了凭据：立刻停手，不重试。归因看待判决标志（提交的回应是另一份文档）。
    /// 归因给已存凭据时删凭据并关闭自动登录；用户手动输错时监视器重新装上，改对再登一次就应被捕获。
    private func rejectCredentials() {
        autoStopped = true
        stopProbeTimer()
        cancelTransient()
        cancelArmed()
        evalIgnoringResult(ScriptBag.captchaStop)
        dropPending()

        let usedSaved = flow.consumeAutoVerdict()
        if usedSaved {
            repository.clear()
            savedUsername = nil
            changeSaveAccount(false)
            log("已存凭据被服务端否定，已删除并关闭自动登录")
        }
        if saveAccount {
            // 用户手动输错：监视器继续留着，改对的那次提交照样捕获
            evalIgnoringResult(ScriptBag.credentialWatch)
        } else {
            evalIgnoringResult(ScriptBag.credentialStop)
        }
        let remaining = Sues.lockoutRemaining(lastPrompt)
        log("凭据被否定（来自已存凭据=\(usedSaved)，剩余=\(remaining.map(String.init) ?? "未说明")），停手")
        // 文案分两段：先说是哪种否定，再按 APP-UX §5「剩余次数」那行**追加**次数信息。
        // 措辞规则（含 N ≤ 1 的改口）在 Sues.remainingClause 里，能被单测钉住。
        let head = usedSaved ? "保存的账号已失效，请手动登录" : "账号或密码不对，请手动登录"
        let tail = Sues.remainingClause(remaining) ?? ""
        // 动作也照 APP-UX §5 的「是否可点」列：用已存凭据 →「清除账号」，手动输错 →「重试」
        alert(head + tail, kind: usedSaved ? .clearAccount : .retry)
    }

    private func settle() {
        cancelTransient()
        let captured = pending
        pending = nil
        cancelPending()
        if let captured {
            // 加密 + 落盘挪出主 actor：界面线程不做 Keychain 调用
            //（PC 用 Task.Run、Android 用后台线程 + 回主线程）。
            // 先把要用的两个字段取出来再进 detached 闭包：String / [Character] 是值类型，跨执行器不共享可变状态。
            let username = captured.username
            let password = captured.password
            Task { [weak self] in
                guard let self else { return }
                let repository = self.repository
                let saved = await Task.detached(priority: .userInitiated) {
                    repository.save(username, password)
                }.value
                // C# 的 `finally { captured.Clear(); }`：落盘成功与否都要擦掉内存里的密码。
                captured.clear()
                self.savedUsername = saved ? username : nil
                self.log("登录成功，保存账号=\(self.mask(username)) 落盘=\(saved)")
                self.showNotice(Notice(
                    text: saved ? "已记住账号，下次自动登录" : "账号没能保存，请重试",
                    tone: saved ? .done : .alert,
                    sticky: !saved,
                    kind: saved ? .undoSave : .none))
            }
        } else {
            log("已到目的地，停手：\(webView.url?.absoluteString ?? "")")
            showNotice(Notice(text: "已进入教务系统", tone: .done))
        }
    }

    private func clearPrefix() {
        settings.prefix = nil
        settings.save()
        alert("入口地址已失效，已清除记录；请点「教务系统」重新进入")
    }

    private func onTransient() {
        showNotice(Notice(text: "正在跳转…"))
        if transientTick != nil || transientReloads >= Self.transientMaxReloads { return }
        transientTick = postDelayed(Self.transientTimeoutMs) { [weak self] in
            guard let self else { return }
            self.transientTick = nil
            if Sues.isTransientPage(self.webView.url?.absoluteString ?? "") {
                self.transientReloads += 1
                self.log("中转页停留超时，重载一次")
                self.webView.reload()
            }
        }
    }

    // ---------------------------------------------------------------- 探索门户

    private func probe() {
        let url = webView.url?.absoluteString ?? ""
        Task { [weak self] in
            guard let self else { return }
            let raw = await self.eval(ScriptBag.probe)
            guard Sues.samePage(url, self.webView.url?.absoluteString) else { return }
            let prefix = Sues.prefixFrom(Sues.probeHref(raw), url)
            guard let prefix else {
                // 「还要不要再探一发」由状态机说了算，宿主只排任务。
                // 上限的账本与判据在同一层（EntryFlow），所以它能被单测钉住。
                if self.flow.onProbeMissed(url) {
                    self.stopProbeTimer()
                    self.postProbe()
                } else {
                    self.log("门户探测已达上限 \(EntryFlow.probeMaxAttempts) 发，交回用户")
                    self.alert("没在门户里找到教务系统入口，请自行点击")
                }
                return
            }
            self.settings.prefix = prefix
            self.settings.save()
            self.log("读到教务系统前缀=\(prefix)")
            self.load(prefix + Sues.ssoPath)
        }
    }

    private func postProbe() {
        probeTick = postDelayed(Self.probeIntervalMs) { [weak self] in
            guard let self else { return }
            self.probeTick = nil
            self.probe()
        }
    }

    // ---------------------------------------------------------------- 滑块

    private func onArmed(_ armed: Bool, expectsSlide: Bool) {
        if autoStopped { return }
        if armed {
            // armed=true 的含义就是「这一页的滑块归应用管」，两种文档形态都会到这里：
            //   · 「独立滑动文档」（没有 #password）一渲染出 .ap-container 就 armed；
            //   · 「表单与滑块同页」在**真实 submit** 之后 armed（页面脚本监听 submit，不轮询）。
            // 早先这里额外要求 expectsSlide——而它表示「这份文档没有密码框」，于是同页那一形态
            // 提交后两个分支都不命中：不拖、不提示、不超时，captchaAttempts 永不增长。
            // 判据只有一个：armed。expectsSlide 留下来只做诊断（日志一眼看出当前是哪种形态）。
            if captchaAttempts >= Self.captchaMaxAttempts {
                // 预算已经用尽：不要再宣称「正在自动完成安全验证…」——那是句谎话
                if !captchaGaveUp {
                    captchaGaveUp = true
                    alert("自动验证已达上限，请手动拖动")
                }
                return
            }
            log("接管滑块（同页表单=\(!expectsSlide)，已拖 \(captchaAttempts) 次）")
            showNotice(Notice(text: "正在自动完成安全验证…", sticky: true))
            cancelArmed()
            armedTick = postDelayed(Self.armedTimeoutMs) { [weak self] in
                guard let self else { return }
                self.armedTick = nil
                self.alert("验证没能自动完成，请手动拖动")
            }
        } else {
            // 只撤超时定时器，不清状态行：监视器第一次上报必然是 armed=false
            //（页面有密码框、还没提交），把它当成「收起提示」会把「登录一次，之后
            // 自动登录」这类本该留下的提示在 400ms 内擦掉。提示由后续的判决来替换，
            // 滑块监视器不拥有状态行。
            cancelArmed()
        }
    }

    private func onCaptcha(_ background: String, _ slider: String) {
        let id = background + "|" + slider
        if id == captchaLastId { return }
        captchaLastId = id
        if captchaAttempts >= Self.captchaMaxAttempts {
            // 用尽后换新图也不能装作没事：明确交回用户一次（只说一次）
            if !captchaGaveUp {
                captchaGaveUp = true
                alert("自动验证已达上限，请手动拖动")
            }
            return
        }
        // C# 是 `Task.Run(() => { 解码 → Solve → BeginInvoke })`：解码与求解都在后台线程，
        // 只有界面动作回主线程。iOS 这边同样把重活挪出主线程（主线程还要渲染页面）。
        Task { [weak self] in
            let x = await Task.detached(priority: .userInitiated) { [background, slider] () -> Int? in
                guard let bg = EntryHost.decodeDataUrl(background),
                      let sl = EntryHost.decodeDataUrl(slider) else { return nil }
                return SliderSolver.solve(
                    bg.pixels, bg.width, bg.height,
                    sl.pixels, sl.width, sl.height)
            }.value
            guard let self else { return }
            guard let x else {
                self.alert("验证没能自动完成，请手动拖动")
                return
            }
            if !self.autoStopped { self.dragTo(x) }
        }
    }

    private func dragTo(_ x: Int) {
        Task { [weak self] in
            guard let self else { return }
            let raw = await self.eval(ScriptBag.sliderGeometry)
            switch SliderDrag.parseProbe(raw) {
            case .failed(let reason):
                self.log("量不到滑块几何：\(reason)")
                self.alert("验证没能自动完成，请手动拖动")
            case .ready(let geometry):
                guard let plan = SliderDrag.makePlan(x, geometry) else {
                    self.log("换算不出光标位置：缺口=\(x) 几何=\(geometry)")
                    self.alert("验证没能自动完成，请手动拖动")
                    return
                }
                self.captchaAttempts += 1
                self.cancelArmed()
                self.log("缺口=\(x) 光标=\(plan.cursor)（当前 \(geometry.cursorNow)）预计提交=\(plan.submitted)"
                    + " 位移=\(plan.delta) 滑轨=\(geometry.slidingScope) 值域=\(geometry.cutScope)"
                    + " 容器宽=\(geometry.containerWidth) 图宽=\(geometry.backgroundWidth)"
                    + " 一致=\(geometry.containerMatchesImage)")
                let result = await self.eval(ScriptBag.dragJs(plan))
                self.log("拖动结果=\(result)（第 \(self.captchaAttempts) 次）")
            }
        }
    }

    // ---------------------------------------------------------------- 凭据捕获

    /// 用户在官方页面上按下登录，页面把值交了过来。是否接受由这里决定（双重校验）。
    private func onCredentialCaptured(_ username: String, _ password: String) {
        // 第二重校验（第一重是同意与否）：**当前文档必须真的是学校的统一身份认证页**。
        // 页面侧的监视器只装在那种页面上，但这一条不能只靠页面侧——页面脚本可以主动伪造一次提交。
        let current = webView.url?.absoluteString ?? ""
        guard Sues.isCredentialPage(current) else {
            log("当前文档不是学校的统一身份认证页，丢弃抓到的凭据：\(current)")
            return
        }
        if !saveAccount {
            log("用户未同意保存账号，丢弃抓到的凭据")
            return
        }
        if filledDoc == flow.documentOrdinal {
            log("这次提交是应用自己填的，不必重复保存")
            return
        }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty { return }

        // 用户本人的提交：此后服务端的判决不再属于应用那次自动提交
        flow.onUserSubmitted()
        dropPending()
        pending = Credential(username, Array(password))
        cancelPending()
        pendingTick = postDelayed(Self.pendingTimeoutMs) { [weak self] in
            guard let self else { return }
            self.pendingTick = nil
            self.log("抓到的凭据 \(Self.pendingTimeoutMs / 1000) 秒内没有定局，丢弃")
            self.dropPending()
        }
        log("抓到账号=\(mask(username))，等登录结果再决定是否保存")
    }

    private func dropPending() {
        cancelPending()
        pending?.clear()
        pending = nil
    }

    /// 日志与界面上的账号一律打码。
    private func mask(_ username: String) -> String {
        username.count <= 4 ? "****" : String(username.prefix(4)) + "****"
    }

    // ---------------------------------------------------------------- 页面显示偏好

    /// 只在教务系统里生效：认证页、门户页上一律不动（登录流程里不多添变量）。
    private func applyPagePrefs(_ url: String) {
        if !hideNotices || !Sues.isJxfwPage(url) { return }
        if tweakedDoc == flow.documentOrdinal { return }
        tweakedDoc = flow.documentOrdinal
        Task { [weak self] in
            guard let self else { return }
            let result = await self.eval(ScriptBag.noticeDialogJs(true))
            self.log("收起公告弹窗：\(result)")
        }
    }

    // ---------------------------------------------------------------- 导航回调（对应 C# 的 Core.* 事件）

    /// 一份新文档开始加载。
    ///
    /// **等价关系（这一段是本文件最要紧的注释）**：
    /// C# 那侧是 `NavigationStarting += (_, e) => { if (!e.IsRedirected) Flow.OnDocumentStarted(); }`
    /// ——「服务端重定向链不产生新文档」。WKWebView 对应的语义是：
    ///
    /// - `didStartProvisionalNavigation`：**每次新文档加载都会来**，与 C# 的 `NavigationStarting` 同义；
    /// - `didReceiveServerRedirectForProvisionalNavigation`：服务端重定向**不**走上面那个回调
    ///   （iOS 明确把它单独回调出来），因此重定向链天然不重复记账——与 `IsRedirected` 等价；
    /// - `didCommit` / `didFinish`：文档已经落在 WebView 里，重复回调**不能**记账。
    ///
    /// 另外 iOS 上 `didStartProvisionalNavigation` 对同一串导航**可能重复回调**（表单重投、
    /// 同 URL 重发、分片导航），而 C# 那边 `NavigationStarting` 只在文档真的要换时来一次。
    /// 文档序号是 `filledDoc` / `tweakedDoc` 的文档身份，多记一次会让「这份文档我已经填过」
    /// 失效，所以这里用 `documentCounted` 把「一串导航只记一次」钉死，
    /// 由 `didFinish` / `didFail*` 复位。
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !documentCounted {
            documentCounted = true
            flow.onDocumentStarted()
        }
        isLoading = true
        progress = 0
        onChanged?()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        documentCounted = false
        isLoading = false
        progress = 100
        let url = webView.url?.absoluteString ?? ""
        let action = flow.onDocumentFinished(url)
        log("onNavigationCompleted \(url) -> \(action)")
        run(action)
        applyPagePrefs(url)
        onChanged?()
    }

    /// 对应 Android `WebViewClient.onReceivedError`（只对主框架报错提示）。
    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        documentCounted = false
        isLoading = false
        onChanged?()
        alert("网络不通，请检查后重试", kind: .retry)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        documentCounted = false
        isLoading = false
        onChanged?()
        alert("网络不通，请检查后重试", kind: .retry)
    }

    /// 站点用 `window.open` / `target=_blank` 新开页面：在当前窗口里打开，保住返回栈。
    /// PC 端按 `pc/README` 的清单就是单窗口；教务系统的新开页在当前页继续浏览。
    /// （对应 C# `Core.NewWindowRequested` 里的 `e.Handled = true` + `Core.Navigate(e.Uri)`。）
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // WKWebView 用 `targetFrame == nil` 表示「这次导航的目标窗口不存在」，
        // 也就是 `window.open` / `target=_blank`（`navigationAction.targetFrame` 在 iOS 上
        // 拿不到 WebView2 的 `IsNewWindow` 那种标志位，这是平台提供的等价判据）。
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url?.absoluteString,
           !url.isEmpty {
            decisionHandler(.cancel)
            log("站点新开窗口 → 当前窗口打开 \(url)")
            load(url)
            return
        }
        decisionHandler(.allow)
    }

    /// 网页内容进程被系统回收（内存压力下很常见）。
    ///
    /// 整页会变白，而且**不会**回调 `didFail*`——状态机会以为还停在原来那份文档上
    /// （停手标志、文档序号、拖动次数全保持旧值），界面上也没有任何出口。
    /// 平台契约：这个回调之后 `reload()` 会让 WebKit 重建内容进程。
    /// PC 的 `ProcessFailed`、Android 的 `onRenderProcessGone` 是同一件事。
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("网页内容进程被系统回收，重新加载")
        alert("页面被系统回收了，正在重新加载", kind: .retry)
        webView.reload()
    }

    /// 证书校验失败：登录凭据不能经过证书无效的连接，一律取消，不提供绕过入口。
    ///
    /// WebView2 那边是 `Core.ServerCertificateErrorDetected` 之类的失败回调 / Android 是
    /// `onReceivedSslError` + `handler.cancel()`；WKWebView 的对应位置是认证挑战：
    /// `NSURLAuthenticationMethodServerTrust` 上**不**调用 `.performDefaultHandling` 就等于取消。
    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            log("证书校验失败，已停止连接（\(challenge.protectionSpace.host)）")
            completionHandler(.cancelAuthenticationChallenge, nil)
            alert("证书校验失败，已停止连接")
            return
        }
        // 非证书类挑战（HTTP Basic 等）本站用不到；不擅自替用户提供凭据：
        // 有默认处置就走默认，没有就取消——对应 Android 的 `handler.cancel()`。
        if challenge.previousFailureCount == 0,
           let sender = challenge.sender,
           challenge.proposedCredential == nil {
            sender.performDefaultHandling?(challenge)
        } else {
            challenge.sender?.cancel(challenge)
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // ---------------------------------------------------------------- 消息与脚本

    /// 页面侧通过 `window.webkit.messageHandlers.entry` 回调进来。
    ///
    /// 消息体是**原生对象**（垫片 `post({cmd:'armed',…})`），所以这里按形状分派，
    /// 等价于 C# 的 `OnWebMessage` 里那段 `JsonDocument.Parse` + `cmd` switch，
    /// 只是不需要再解析 JSON 文本。
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String else {
            log("页面消息解析失败：认不出的消息体 \(message.body)")
            return
        }
        switch cmd {
        case "armed":
            onArmed(boolValue(body["armed"]), expectsSlide: boolValue(body["expectsSlide"]))
        case "captcha":
            onCaptcha(stringValue(body["bg"]), stringValue(body["sl"]))
        case "credential":
            onCredentialCaptured(stringValue(body["username"]), stringValue(body["password"]))
        case "log":
            log(stringValue(body["message"]))
        default:
            break
        }
    }

    /// 执行脚本并取回字符串结果。
    ///
    /// **与 C# 的差异**：WebView2 的 `ExecuteScriptAsync` 把结果 JSON 编码成字符串
    /// （所以 C# 要 `Unquote`），WKWebView 直接回传原生对象（`String` / `NSNumber` / …），
    /// 因此 iOS 侧**不做 Unquote**，只把非字符串结果转成它的字符串形式；
    /// 认不出的类型返回空串并记一条日志，不猜。
    private func eval(_ script: String) async -> String {
        do {
            let value = try await webView.evaluateJavaScript(script)
            return coerceToString(value)
        } catch {
            log("脚本执行失败：\(error.localizedDescription)")
            return ""
        }
    }

    /// 只为了「执行」的脚本（装监视器、停监视器、点跳过之类），不需要回传值。
    private func evalIgnoringResult(_ script: String) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.eval(script)
        }
    }

    private func coerceToString(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if value is NSNull { return "" }
        log("脚本回传值不是字符串：\(type(of: value))")
        return ""
    }

    private func load(_ url: String) {
        guard let target = URL(string: url) else {
            log("落点不是合法 URL，跳过：\(url)")
            return
        }
        webView.load(URLRequest(url: target))
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private func stringValue(_ value: Any?) -> String {
        value as? String ?? ""
    }

    // ---------------------------------------------------------------- 计时器与通知

    private func resetRuntime() {
        stopProbeTimer()
        cancelTransient()
        cancelArmed()
        captchaAttempts = 0
        captchaLastId = nil
        captchaGaveUp = false
        transientReloads = 0
        expiredSkips = 0
        autoStopped = false
        autoSubmits = 0
        lastPrompt = ""
        filledDoc = -1
        tweakedDoc = -1
        documentCounted = false
    }

    /// 一次性延时任务。对应 C# 的 `PostDelayed`（`DispatcherTimer` + `Tick` 里 Stop）。
    /// 用 `.common` 运行模式：拖动/滚动的跟踪循环里也能按时触发，不会被界面卡住。
    private func postDelayed(_ ms: Int, _ action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: Double(ms) / 1000.0, repeats: false) { _ in
            action()
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// 只停探测定时器，**不碰重试计数**——计数在 `EntryFlow` 里，由状态机按 URL 自己管。
    ///
    /// 2026-09-20 修：早先这里把「停定时器」与「清计数」合成一个 `cancelProbe()`，重试路径顺手调了它，
    /// 于是 `probeAttempts += 1` 紧接着被抹回 0、15 发的上限永远到不了，「没在门户里找到入口」的提示
    /// 成了死代码（表现为无限轮询）。根因是职责混装 + 宿主层没有测试；现在账本住在可单测的状态机里。
    private func stopProbeTimer() {
        probeTick?.invalidate()
        probeTick = nil
    }

    private func cancelTransient() {
        transientTick?.invalidate()
        transientTick = nil
    }

    private func cancelArmed() {
        armedTick?.invalidate()
        armedTick = nil
    }

    private func cancelPending() {
        pendingTick?.invalidate()
        pendingTick = nil
    }

    private func alert(_ text: String, kind: NoticeKind = .none) {
        showNotice(Notice(text: text, tone: .alert, sticky: true, kind: kind))
    }

    private func showNotice(_ value: Notice) {
        noticeTick?.invalidate()
        noticeTick = nil
        notice = value
        if !value.text.isEmpty && !value.sticky {
            noticeTick = postDelayed(Self.noticeTimeoutMs) { [weak self] in
                guard let self else { return }
                self.noticeTick = nil
                self.notice = Notice()
                self.raiseChanged()
            }
        }
        raiseChanged()
    }

    private func raiseChanged() {
        onChanged?()
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n))
    }

    // ---------------------------------------------------------------- 图片解码（仅宿主 glue；求解在 SliderSolver 里）

    /// 解码后的一幅图：`pixels` 是 `0xAARRGGBB` 的打包像素（与 Android `Bitmap.getPixels`
    /// / C# `PixelFormat.Format32bppArgb` 同一套布局），尺寸是自然尺寸。
    ///
    /// 标 `Sendable`：这一对值要在后台线程里造出来、再回到主线程交给页面（见 `onCaptcha`）。
    private struct SliderImage: Sendable {
        let pixels: [Int32]
        let width: Int
        let height: Int
    }

    /// `data:image/png;base64,…` → 一张图；不是 data-URL 时按纯 base64 处理，与 C# 一致。
    ///
    /// 标 `nonisolated`：`EntryHost` 是 `@MainActor`，静态成员会**继承主 actor 隔离**，
    /// 于是 `onCaptcha` 里那个 `Task.detached` 闭包调用它就变成「跨 actor 同步调用」——
    /// 能不能编过取决于语言模式的并发检查，而且即便编过也说不清到底跑在哪个执行器上。
    /// 显式 `nonisolated` 把这件事定死：它们是纯函数，**确实**跑在调用者的执行器（后台）上。
    private nonisolated static func decodeDataUrl(_ dataUrl: String) -> SliderImage? {
        let payload: String
        if dataUrl.hasPrefix("data:") {
            guard let comma = dataUrl.firstIndex(of: ",") else { return nil }
            payload = String(dataUrl[dataUrl.index(after: comma)...])
        } else {
            payload = dataUrl
        }
        if payload.isEmpty { return nil }
        guard let data = Data(base64Encoded: payload) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return pixels(of: cgImage)
    }

    /// `CGImage` → 打包像素。
    ///
    /// 与 Android `BitmapFactory.Options.inPremultiplied = false` 对齐：**不做 alpha 合成**。
    /// 预乘会把滑块 PNG 半透明边缘的 RGB 改成 `R×A/255`，亮度掩码与相关度都会跟着偏，
    /// 候选表就与参考实现不一致了（`docs/CORE-SPEC.md` §5.2）。
    ///
    /// 麻烦在于 **Core Graphics 的位图上下文不支持非预乘 alpha**（`kCGImageAlphaLast` 不能作为
    /// 上下文格式），所以「画进上下文再读」这条路拿到的必然是预乘数据。因此这里在读完缓冲后
    /// **自己反预乘**——等价于 Accelerate 的 `vImageUnpremultiplyData_RGBA8888`，不引入依赖。
    ///
    /// 已知残余差异（**需要真机拿真实滑块图确认**）：`A == 0` 的像素在预乘阶段 RGB 已经被乘成 0，
    /// 信息不可逆，只能保持 0；而 Android 的非预乘位图在同一位置仍保有原始 RGB。
    /// 对滑块图的实际影响预期为零（完全透明的区域 PNG 编码器一般写 RGB=0，而亮度掩码本来就要求
    /// 足够亮才入选），但这是与参考实现的一处**真实差别**，不当成"已经一样"。
    ///
    /// 同样标 `nonisolated`：理由是上面 `decodeDataUrl` 那一段。
    private nonisolated static func pixels(of image: CGImage) -> SliderImage? {
        let width = image.width
        let height = image.height
        if width <= 0 || height <= 0 { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        if !ok { return nil }

        var result = [Int32](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let base = i * bytesPerPixel
            let a = Int(buffer[base + 3])
            var r = Int(buffer[base])
            var g = Int(buffer[base + 1])
            var b = Int(buffer[base + 2])

            // 反预乘：把已经被乘进去的 alpha 除回来。加 a/2 是四舍五入，
            // 让结果与原值最多差 1（Android 走非预乘是精确值，这是 1 个色阶的残差）。
            if a > 0 && a < 255 {
                r = min(255, (r * 255 + a / 2) / a)
                g = min(255, (g * 255 + a / 2) / a)
                b = min(255, (b * 255 + a / 2) / a)
            }

            result[i] = (Int32(a) << 24) | (Int32(r) << 16) | (Int32(g) << 8) | Int32(b)
        }
        return SliderImage(pixels: result, width: width, height: height)
    }

    // ---------------------------------------------------------------- 日志

    /// 日志同时进系统日志与 `run.log`（用户报障时把这一个文件发过来就够）。
    ///
    /// C# 写在 `%LOCALAPPDATA%\CampusEntry\run.log`；iOS 写在应用沙箱的 Documents 下，
    /// 这样开「文件共享」就能取出来。写不动也不影响主流程。
    private func log(_ message: String) {
        let line = "[\(Self.tag)] \(message)"
        #if DEBUG
        NSLog("%@", line)
        #endif
        do {
            let directory = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CampusEntry", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("run.log")
            let stamp = Self.stampFormatter.string(from: Date())
            let text = "\(stamp) \(line)\n"
            if FileManager.default.fileExists(atPath: file.path),
               let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = text.data(using: .utf8) { try handle.write(contentsOf: data) }
            } else {
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            // 日志写不动（磁盘满/权限）不影响主流程
        }
    }

    /// `yyyy-MM-dd HH:mm:ss`，与 C# 那侧的时间戳格式一致，便于两端日志对读。
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    // ---------------------------------------------------------------- 收尾

    /// 对应 C# 的 `Dispose`：丢弃未定局的凭据、清运行时状态、停掉状态行定时器、
    /// 撤掉消息通道与垫片（否则 `WKUserContentController` 会强引用宿主，WebView 也撤不掉）。
    ///
    /// **现在没有任何调用者，这是有意的、也是已知的**（审计 2026-09 结论）：
    /// 本端只有一个窗口，宿主与 App 同生共死——`ContentView` 用 `@State` 持有它、`start()` 里
    /// `guard host == nil` 只建一次，而 `WKUserContentController.add(self,…)` 会强引用宿主，
    /// 所以宿主**不会**被释放，也就没有「销毁」这个时刻。
    ///
    /// 之所以留着它而不是删掉：它描述的是一条**真实的解绑契约**（消息通道 + KVO 观察者 +
    /// 定时器 + 未定局凭据），一旦将来有多窗口 / 多 Scene，或者宿主改成可按需重建，
    /// 调用点就在「宿主的持有者消失」那一处——那时必须调它，否则留下的是悬挂的观察者与消息通道。
    /// 在那之前，把它接到 `onDisappear` 之类的钩子反而危险：那些钩子会在会话中途触发，
    /// 一次误触就会把还活着的 WebView 与登录会话一起拆掉。
    public func dispose() {
        dropPending()
        resetRuntime()
        noticeTick?.invalidate()
        noticeTick = nil
        probeTick?.invalidate()
        probeTick = nil
        transientTick?.invalidate()
        transientTick = nil
        armedTick?.invalidate()
        armedTick = nil
        pendingTick?.invalidate()
        pendingTick = nil
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.title))
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView.navigationDelegate = nil
        webView.stopLoading()
        onChanged = nil
        onReady = nil
        onViewTitleChanged = nil
    }
}
