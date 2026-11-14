import AppKit
import CampusEntryCore
import Combine
import Foundation
import Security
import WebKit

/// Bottom-bar notice state mirrored by SwiftUI views (`APP-UX.md` §5).
public struct NoticeState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case none
        case info
        case done
        case alert
    }

    public enum Action: Equatable, Sendable {
        case none
        case retry
        case undoSave
        case clearAccount
    }

    public var text: String
    public var kind: Kind
    public var sticky: Bool
    public var action: Action

    public var actionLabel: String? {
        switch action {
        case .none:
            return nil
        case .retry:
            return "重试"
        case .undoSave:
            return "撤销"
        case .clearAccount:
            return "清除账号"
        }
    }

    public static let empty = NoticeState(text: "", kind: .none, sticky: false, action: .none)

    public init(
        text: String = "",
        kind: Kind = .none,
        sticky: Bool = false,
        action: Action = .none
    ) {
        self.text = text
        self.kind = kind
        self.sticky = sticky
        self.action = action
    }
}

/// Weak proxy so `WKUserContentController.add(_:name:)` never retains `EntryHost`.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// macOS `WKWebView` host controller driving `EntryFlow` (`CORE-SPEC.md` / `APP-UX.md`).
@MainActor
public final class EntryHost: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private static let probeIntervalMs = 600
    private static let captchaMaxAttempts = 3
    private static let autoSubmitMax = 2
    private static let armedTimeoutMs = 20_000
    private static let transientTimeoutMs = 15_000
    private static let transientMaxReloads = 1
    private static let expiredMaxSkips = 1
    private static let noticeTimeoutMs = 2_000
    private static let pendingTimeoutMs = 90_000
    private static let maxConsecutiveProcessTerminations = 3

    private let settings: EntrySettings
    private let repository: CredentialRepository
    private let logger: RunLogger

    public let webView: WKWebView
    public let flow = EntryFlow()

    // MARK: - Observable UI State

    @Published public private(set) var ready = false
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var activeEntry: Sues.Entry = .jxfw
    @Published public private(set) var docTitle = ""
    @Published public private(set) var savedUsername: String?
    @Published public private(set) var notice: NoticeState = .empty

    @Published public private(set) var home: Bool
    @Published public private(set) var saveAccount: Bool
    @Published public private(set) var hideNotices: Bool
    @Published public private(set) var isLoading = false
    @Published public private(set) var estimatedProgress = 0.0
    @Published public private(set) var currentURL = ""

    public var onFatalError: ((String) -> Void)?
    public var onChanged: (() -> Void)?
    public var onReady: (() -> Void)?

    // MARK: - Runtime Flow State

    /// URL of the document last committed/finished by `WKWebView` (never live-polled from unrelated states).
    private var currentDocURL = ""
    private var certFailedInCurrentNavigation = false
    private var consecutiveProcessTerminations = 0

    private var autoStopped = false
    private var lastPrompt = ""
    private var probeTimer: Timer?
    private var transientTimer: Timer?
    private var transientReloads = 0
    private var armedTimer: Timer?
    private var captchaAttempts = 0
    private var captchaLastId: String?
    private var captchaGaveUp = false
    private var expiredSkips = 0
    private var pending: Credential?
    private var pendingTimer: Timer?
    private var filledDoc = -1
    private var autoSubmits = 0
    private var tweakedDoc = -1
    private var noticeTimer: Timer?

    private var kvoObservations = [NSKeyValueObservation]()
    private var appObservers = [NSObjectProtocol]()
    private var isDisposed = false

    public init(
        settings: EntrySettings = EntrySettings.load(),
        repository: CredentialRepository = CredentialRepository(
            store: CredentialStore(backend: KeychainCryptoBackend())
        ),
        logger: RunLogger = .shared,
        configuration: WKWebViewConfiguration? = nil
    ) {
        self.settings = settings
        self.repository = repository
        self.logger = logger

        self.saveAccount = settings.saveAccount
        self.hideNotices = settings.hideNotices
        self.home = !settings.saveDecided

        let config = configuration ?? WKWebViewConfiguration()
        let contentController = config.userContentController
        let shim = WKUserScript(
            source: ScriptBag.entryShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(shim)

        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        contentController.add(WeakScriptMessageHandler(self), name: "entry")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        setupObservers()
        loadSavedUsernameAsync()

        ready = true
        onReady?()
        raiseChanged()
    }

    deinit {
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        kvoObservations.removeAll()
    }

    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true

        dropPending()
        resetRuntime()
        noticeTimer?.invalidate()
        noticeTimer = nil

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "entry")

        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        appObservers.removeAll()
        kvoObservations.removeAll()
    }

    private func setupObservers() {
        kvoObservations = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    self?.canGoBack = view.canGoBack
                    self?.raiseChanged()
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    self?.canGoForward = view.canGoForward
                    self?.raiseChanged()
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    let title = (view.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        self?.docTitle = title
                        self?.raiseChanged()
                    }
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    self?.isLoading = view.isLoading
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    self?.estimatedProgress = view.estimatedProgress
                }
            },
        ]

        let center = NotificationCenter.default
        appObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onBackground()
                }
            }
        )
        appObservers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onForeground()
                }
            }
        )
    }

    private func loadSavedUsernameAsync() {
        Task.detached(priority: .userInitiated) { [repository] in
            let name = repository.savedUsername()
            await MainActor.run { [weak self] in
                guard let self, !self.isDisposed else { return }
                self.savedUsername = name
                self.raiseChanged()
            }
        }
    }

    // MARK: - Host Operations

    public func enterFromHome(_ entry: Sues.Entry) {
        settings.saveDecided = true
        settings.saveAccount = saveAccount
        saveSettings("同意保存账号")
        home = false
        open(entry)
    }

    public func openHome() {
        home = true
        raiseChanged()
    }

    public func open(_ entry: Sues.Entry) {
        activeEntry = entry
        flow.start(entry: entry, hasCachedPrefix: settings.prefix != nil)
        resetRuntime()
        certFailedInCurrentNavigation = false

        showNotice(NoticeState(
            text: entry == .webvpn ? "正在打开校园网关…" : "正在打开教务系统…",
            kind: .info
        ))

        let targetString = Sues.entryUrl(prefix: settings.prefix, entry: entry)
        logger.log("打开入口=\(entry.rawValue) 落点=\(targetString)")
        if let url = URL(string: targetString) {
            webView.load(URLRequest(url: url))
        } else {
            alert("入口地址无效，请重试", action: .retry)
        }
        raiseChanged()
    }

    public func goBack() {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    public func goForward() {
        if webView.canGoForward {
            webView.goForward()
        }
    }

    public func reload() {
        webView.reload()
    }

    public func setSaveAccount(_ on: Bool) {
        saveAccount = on
        settings.saveAccount = on
        saveSettings("自动登录意愿")
        if !on {
            dropPending()
            showNotice(NoticeState(
                text: "已关闭自动登录；已保存的账号还在本机，可以随时清除",
                kind: .info
            ))
        }
        raiseChanged()
    }

    public func setHideNotices(_ on: Bool) {
        hideNotices = on
        settings.hideNotices = on
        saveSettings("收起公告弹窗")
        tweakedDoc = -1

        guard Sues.isJxfwPage(currentDocURL) else {
            raiseChanged()
            return
        }

        guarded("收起/恢复公告弹窗", fallbackText: "通知公告没能\(on ? "收起" : "恢复")，请刷新后重试") {
            let result = try await self.eval(ScriptBag.noticeDialog(hide: on))
            self.logger.log("通知公告：\(on ? "收起" : "恢复") -> \(result)")
        }
        raiseChanged()
    }

    public func clearAccount() {
        repository.clear()
        savedUsername = nil
        showNotice(NoticeState(text: "已清除账号", kind: .done))
        raiseChanged()
    }

    public func clearSession() {
        guarded("退出登录", fallbackText: "退出登录没能完成，请重试") {
            self.resetRuntime()
            await self.clearCookiesAsync()
            self.open(self.activeEntry)
            self.showNotice(NoticeState(text: "已退出登录；保存的账号还在", kind: .done))
            self.raiseChanged()
        }
    }

    public func switchAccount() {
        guarded("改用其他账号", fallbackText: "改用其他账号没能完成，请重试") {
            self.repository.clear()
            self.savedUsername = nil
            self.resetRuntime()
            await self.clearCookiesAsync()
            self.flow.start(entry: self.activeEntry, hasCachedPrefix: false)
            self.home = true
            self.raiseChanged()
        }
    }

    public func undoSave() {
        repository.clear()
        savedUsername = nil
        setSaveAccount(false)
        showNotice(NoticeState(text: "已撤销保存", kind: .done))
        raiseChanged()
    }

    public func runNoticeAction() {
        switch notice.action {
        case .none:
            break
        case .retry:
            reload()
        case .undoSave:
            undoSave()
            return
        case .clearAccount:
            repository.clear()
            savedUsername = nil
            setSaveAccount(false)
            showNotice(NoticeState(text: "已清除账号", kind: .done))
        }
        raiseChanged()
    }

    // MARK: - App Lifecycle Watchers

    private func onBackground() {
        guard Sues.isCredentialPage(currentDocURL) else { return }
        evalQuietly("退后台停滑块监视器", ScriptBag.captchaStop)
        evalQuietly("退后台停凭据监视器", ScriptBag.credentialStop)
    }

    private func onForeground() {
        guard !autoStopped, Sues.isCredentialPage(currentDocURL) else { return }
        evalQuietly("回前台重装滑块监视器", ScriptBag.captchaWatch)
        if saveAccount {
            evalQuietly("回前台重装凭据监视器", ScriptBag.credentialWatch)
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        certFailedInCurrentNavigation = false
        let url = webView.url?.absoluteString ?? ""
        guard !Self.isIgnoredURL(url) else { return }
        flow.onDocumentStarted()
    }

    public func webView(
        _ webView: WKWebView,
        didCommit navigation: WKNavigation!
    ) {
        let url = webView.url?.absoluteString ?? ""
        guard !Self.isIgnoredURL(url) else { return }
        currentDocURL = url
        currentURL = url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        raiseChanged()
    }

    public func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        consecutiveProcessTerminations = 0
        let url = webView.url?.absoluteString ?? currentDocURL
        guard !Self.isIgnoredURL(url) else { return }

        currentDocURL = url
        currentURL = url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward

        let title = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            docTitle = title
        }

        let action = flow.onDocumentFinished(url)
        logger.log("didFinish \(url) -> \(action)")
        run(action)
        applyPagePrefs(url)
        raiseChanged()
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(url: webView.url?.absoluteString ?? currentDocURL, error: error, phase: "didFail")
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(
            url: webView.url?.absoluteString ?? currentDocURL,
            error: error,
            phase: "didFailProvisionalNavigation"
        )
    }

    private func handleNavigationFailure(url: String, error: Error, phase: String) {
        let nsError = error as NSError
        if certFailedInCurrentNavigation {
            certFailedInCurrentNavigation = false
            logger.log("\(phase) 证书已拦截：\(url)（\(nsError.localizedDescription)）")
            return
        }
        if Self.isCancellationError(nsError) {
            logger.log("\(phase) 导航取消：\(url)（\(nsError.domain):\(nsError.code)）")
            return
        }
        if Self.isCertificateError(nsError) {
            logger.log("\(phase) 证书校验失败：\(url)（\(nsError.localizedDescription)）")
            alert("证书校验失败，已停止连接")
            return
        }

        logger.log("\(phase) 失败：\(url)（\(nsError.domain):\(nsError.code) \(nsError.localizedDescription)）")
        alert("网络不通，请检查后重试", action: .retry)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        consecutiveProcessTerminations += 1
        logger.log("WebView 内容进程终止（连续第 \(consecutiveProcessTerminations) 次）")

        if consecutiveProcessTerminations >= Self.maxConsecutiveProcessTerminations {
            let reason = "页面渲染进程连续异常终止，请尝试重新打开或重启应用"
            alert("页面已失效，请点「重试」", action: .retry)
            onFatalError?(reason)
            return
        }

        alert("页面被系统回收了，正在重新加载", action: .retry)
        webView.reload()
    }

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            certFailedInCurrentNavigation = true
            logger.log("证书校验失败，缺少 serverTrust，已取消：\(host)")
            alert("证书校验失败，已停止连接")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var trustError: CFError?
        if SecTrustEvaluateWithError(serverTrust, &trustError) {
            completionHandler(.performDefaultHandling, nil)
        } else {
            certFailedInCurrentNavigation = true
            let detail = (trustError as Error?)?.localizedDescription ?? "未知证书错误"
            logger.log("证书校验失败，已取消：\(host)（\(detail)）")
            alert("证书校验失败，已停止连接")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - WKUIDelegate

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil || !(navigationAction.targetFrame?.isMainFrame ?? true) {
            let url = navigationAction.request.url?.absoluteString ?? ""
            if !Self.isIgnoredURL(url) {
                logger.log("站点新开窗口 → 当前窗口打开 \(url)")
                webView.load(navigationAction.request)
            }
        }
        return nil
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "entry" else { return }
        guard let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String
        else {
            logger.log("页面消息解析失败：格式不是预期字典")
            return
        }

        switch cmd {
        case "armed":
            let armed = Self.boolValue(body["armed"])
            let expectsSlide = Self.boolValue(body["expectsSlide"])
            onArmed(armed: armed, expectsSlide: expectsSlide)
        case "captcha":
            let bg = (body["bg"] as? String) ?? ""
            let sl = (body["sl"] as? String) ?? ""
            onCaptcha(background: bg, slider: sl)
        case "credential":
            let username = (body["username"] as? String) ?? ""
            let password = (body["password"] as? String) ?? ""
            onCredentialCaptured(username: username, password: password)
        case "log":
            let msg = (body["message"] as? String) ?? ""
            logger.log(msg)
        default:
            logger.log("忽略未知页面消息 cmd=\(cmd)")
        }
    }

    // MARK: - State Machine Actions

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

    private func verifyArrival() {
        guarded("确认到达目的地", fallbackText: "页面没能确认，请手动继续") {
            let raw = try await self.eval(ScriptBag.arrival)
            guard let mark = Sues.arrivalMark(raw) else {
                self.logger.log("门户页正文没有登录成功的标记，暂不算到达：\(self.currentDocURL)")
                self.showNotice(NoticeState(text: "正在等待门户加载完成…", kind: .info))
                return
            }
            self.logger.log("门户页正文确认到达（标记=\(mark)）")
            self.run(self.flow.confirmArrival())
        }
    }

    private func inspectCas() {
        guarded("读取认证页状态", fallbackText: "自动登录没能继续，请手动登录") {
            let url = self.currentDocURL
            let raw = try await self.eval(ScriptBag.casState())
            guard Sues.samePage(url, self.currentDocURL) else { return }

            let seen = Sues.casObservationFrom(raw)
            self.logger.log(
                "认证页：过期=\(seen.expired) 表单=\(seen.hasForm) 滑块=\(seen.hasCaptcha) 提示=\(Self.truncate(seen.prompt, 80))"
            )
            self.lastPrompt = seen.prompt
            self.run(self.flow.onCasObserved(seen))
        }
    }

    private func assistCas() {
        guarded("自动填写并提交", fallbackText: "自动登录没能继续，请手动登录") {
            guard Sues.isCredentialPage(self.currentDocURL) else {
                self.logger.log("这一页不是学校的统一身份认证页，不动它：\(self.currentDocURL)")
                return
            }

            self.evalQuietly("勾记住我", ScriptBag.tickNotice)
            self.evalQuietly("装滑块监视器", ScriptBag.captchaWatch)
            if self.saveAccount {
                self.evalQuietly("装凭据监视器", ScriptBag.credentialWatch)
            }

            let doc = self.flow.documentOrdinal
            if self.filledDoc == doc { return }

            if !self.saveAccount {
                self.showNotice(NoticeState(text: "本次登录不会保存账号", kind: .info, sticky: true))
                return
            }

            if self.autoSubmits >= Self.autoSubmitMax {
                self.logger.log("自动提交已达上限 \(self.autoSubmits) 次，交回用户")
                self.showNotice(NoticeState(text: "自动登录没有成功，请手动登录", kind: .info, sticky: true))
                return
            }

            let credential = await Task.detached(priority: .userInitiated) { [repository = self.repository] in
                repository.load()
            }.value

            guard let credential else {
                self.showNotice(NoticeState(text: "登录一次，之后自动登录", kind: .info, sticky: true))
                return
            }
            defer { credential.clear() }

            self.filledDoc = doc
            self.autoSubmits += 1
            self.flow.onAutoSubmitted()
            self.showNotice(NoticeState(text: "正在自动填写账号…", kind: .info))

            let password = credential.passwordString
            let result = try await self.eval(
                ScriptBag.fillAndSubmit(username: credential.username, password: password)
            )
            self.logger.log("自动填写并提交：\(result)")

            if result.contains("noform") || result.contains("nobutton") {
                self.filledDoc = -1
                self.autoSubmits -= 1
                self.flow.onAutoSubmitAborted()
                self.showNotice(NoticeState(text: "这一页要你手动登录", kind: .info, sticky: true))
            }
        }
    }

    private func skipExpired() {
        evalQuietly("停滑块监视器", ScriptBag.captchaStop)
        if expiredSkips >= Self.expiredMaxSkips {
            logger.log("密码已过期：跳过 \(expiredSkips) 次后仍回到这一页，停手")
            alert("密码已过期，请点页面上的「点击跳过」继续")
            return
        }

        expiredSkips += 1
        showNotice(NoticeState(text: "密码已过期，正在跳过…", kind: .info))
        guarded("跳过密码过期提示", fallbackText: "跳过密码过期提示没能完成，请点页面上的「点击跳过」") {
            let result = try await self.eval(ScriptBag.skipExpired)
            self.logger.log("跳过密码过期提示：\(result)（第 \(self.expiredSkips) 次）")
        }
    }

    private func rejectCredentials() {
        autoStopped = true
        stopProbeTimer()
        cancelTransient()
        cancelArmed()
        evalQuietly("停滑块监视器", ScriptBag.captchaStop)
        dropPending()

        let usedSaved = flow.consumeAutoVerdict()
        if usedSaved {
            repository.clear()
            savedUsername = nil
            setSaveAccount(false)
            logger.log("已存凭据被服务端否定，已删除并关闭自动登录")
        }

        if saveAccount {
            evalQuietly("装凭据监视器", ScriptBag.credentialWatch)
        } else {
            evalQuietly("停凭据监视器", ScriptBag.credentialStop)
        }

        let remaining = Sues.lockoutRemaining(lastPrompt)
        logger.log(
            "凭据被否定（来自已存凭据=\(usedSaved)，剩余=\(remaining.map(String.init) ?? "未说明")），停手"
        )
        let head = usedSaved ? "保存的账号已失效，请手动登录" : "账号或密码不对，请手动登录"
        let tail = Sues.remainingClause(remaining) ?? ""
        alert(head + tail, action: usedSaved ? .clearAccount : .retry)
    }

    private func settle() {
        cancelTransient()
        let captured = pending
        pending = nil
        cancelPending()

        guard let captured else {
            logger.log("已到目的地，停手：\(currentDocURL)")
            showNotice(NoticeState(text: "已进入教务系统", kind: .done))
            return
        }

        let username = captured.username
        guarded("保存账号", fallbackText: "账号没能保存，请重试") {
            let saved = await Task.detached(priority: .userInitiated) { [repository = self.repository] in
                defer { captured.clear() }
                return repository.save(username: captured.username, passwordBytes: captured.passwordBytes)
            }.value

            self.savedUsername = saved ? username : nil
            self.logger.log("登录成功，保存账号=\(Self.mask(username)) 落盘=\(saved)")
            self.showNotice(NoticeState(
                text: saved ? "已记住账号，下次自动登录" : "账号没能保存，请重试",
                kind: saved ? .done : .alert,
                sticky: !saved,
                action: saved ? .undoSave : .none
            ))
            self.raiseChanged()
        }
    }

    private func clearPrefix() {
        settings.prefix = nil
        let saved = settings.save()
        logger.log(saved ? "前缀已清除并落盘" : "前缀已在内存里清除，但没能写盘（磁盘或权限问题）")
        alert(
            saved
                ? "入口地址已失效，已清除记录；请点「教务系统」重新进入"
                : "入口地址已失效；但清除记录没能写入本机（磁盘或权限问题），下次启动仍会用旧地址"
        )
    }

    private func onTransient() {
        showNotice(NoticeState(text: "正在跳转…", kind: .info))
        if transientTimer != nil || transientReloads >= Self.transientMaxReloads {
            return
        }
        transientTimer = postDelayed(ms: Self.transientTimeoutMs) { [weak self] in
            guard let self else { return }
            self.transientTimer = nil
            if Sues.isTransientPage(self.currentDocURL) {
                self.transientReloads += 1
                self.logger.log("中转页停留超时，重载一次")
                self.webView.reload()
            }
        }
    }

    // MARK: - Portal Probe

    private func probe() {
        guarded("探测门户入口", fallbackText: "没能读到入口地址，请自行点击") { [weak self] in
            guard let self else { return }
            let url = self.currentDocURL
            let raw = try await self.eval(ScriptBag.probe)
            guard Sues.samePage(url, self.currentDocURL) else { return }

            guard let prefix = Sues.prefixFrom(Sues.probeHref(raw), pageUrl: url) else {
                if self.flow.onProbeMissed(url) {
                    self.stopProbeTimer()
                    self.probeTimer = self.postDelayed(ms: Self.probeIntervalMs) { [weak self] in
                        self?.probeTimer = nil
                        self?.probe()
                    }
                } else {
                    self.logger.log("门户探测已达上限 \(EntryFlow.probeMaxAttempts) 发，交回用户")
                    self.alert("没在门户里找到教务系统入口，请自行点击")
                }
                return
            }

            self.settings.prefix = prefix
            self.saveSettings("网关前缀")
            self.logger.log("读到教务系统前缀=\(prefix)")
            if let target = URL(string: prefix + Sues.ssoPath) {
                self.webView.load(URLRequest(url: target))
            }
        }
    }

    // MARK: - Captcha Slider

    private func onArmed(armed: Bool, expectsSlide: Bool) {
        if autoStopped { return }
        if armed {
            if captchaAttempts >= Self.captchaMaxAttempts {
                if !captchaGaveUp {
                    captchaGaveUp = true
                    alert("自动验证已达上限，请手动拖动")
                }
                return
            }
            logger.log("接管滑块（同页表单=\(!expectsSlide)，已拖 \(captchaAttempts) 次）")
            showNotice(NoticeState(text: "正在自动完成安全验证…", kind: .info, sticky: true))
            cancelArmed()
            armedTimer = postDelayed(ms: Self.armedTimeoutMs) { [weak self] in
                guard let self else { return }
                self.armedTimer = nil
                self.alert("验证没能自动完成，请手动拖动")
            }
        } else {
            cancelArmed()
        }
    }

    private func onCaptcha(background: String, slider: String) {
        let id = background + "|" + slider
        if id == captchaLastId { return }
        captchaLastId = id

        if captchaAttempts >= Self.captchaMaxAttempts {
            if !captchaGaveUp {
                captchaGaveUp = true
                alert("自动验证已达上限，请手动拖动")
            }
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let bg = ImageDecoder.decodeDataURL(background),
                  let sl = ImageDecoder.decodeDataURL(slider)
            else {
                await MainActor.run { [weak self] in
                    self?.logger.log("验证码图片解码失败")
                }
                return
            }

            let solvedX = SliderSolver.solve(
                bg: bg.pixels,
                bgW: bg.width,
                bgH: bg.height,
                sl: sl.pixels,
                slW: sl.width,
                slH: sl.height
            )

            await MainActor.run { [weak self] in
                guard let self, !self.isDisposed, !self.autoStopped else { return }
                guard let x = solvedX else {
                    self.alert("验证没能自动完成，请手动拖动")
                    return
                }
                self.dragTo(x)
            }
        }
    }

    private func dragTo(_ x: Int) {
        guarded("自动拖动滑块", fallbackText: "验证没能自动完成，请手动拖动") {
            let raw = try await self.eval(ScriptBag.sliderGeometry)
            switch SliderDrag.parseProbe(raw) {
            case let .failed(reason):
                self.logger.log("量不到滑块几何：\(reason)")
                self.alert("验证没能自动完成，请手动拖动")
            case let .ready(geometry):
                guard let plan = SliderDrag.makePlan(x: x, geometry: geometry) else {
                    self.logger.log("换算不出光标位置：缺口=\(x) 几何=\(geometry)")
                    self.alert("验证没能自动完成，请手动拖动")
                    return
                }
                self.captchaAttempts += 1
                self.cancelArmed()
                self.logger.log(
                    "缺口=\(x) 光标=\(plan.cursor)（当前 \(geometry.cursorNow)）预计提交=\(plan.submitted)" +
                    " 位移=\(plan.delta) 滑轨=\(geometry.slidingScope) 值域=\(geometry.cutScope)" +
                    " 容器宽=\(geometry.containerWidth) 图宽=\(geometry.backgroundWidth)" +
                    " 一致=\(geometry.containerMatchesImage)"
                )
                let result = try await self.eval(ScriptBag.drag(plan: plan))
                self.logger.log("拖动结果=\(result)（第 \(self.captchaAttempts) 次）")
            }
        }
    }

    // MARK: - Credential Capture

    private func onCredentialCaptured(username: String, password: String) {
        guard Sues.isCredentialPage(currentDocURL) else {
            logger.log("当前文档不是学校的统一身份认证页，丢弃抓到的凭据：\(currentDocURL)")
            return
        }
        guard saveAccount else {
            logger.log("用户未同意保存账号，丢弃抓到的凭据")
            return
        }
        guard filledDoc != flow.documentOrdinal else {
            logger.log("这次提交是应用自己填的，不必重复保存")
            return
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            return
        }

        flow.onUserSubmitted()
        dropPending()
        pending = Credential(username: username, password: password)
        cancelPending()
        pendingTimer = postDelayed(ms: Self.pendingTimeoutMs) { [weak self] in
            guard let self else { return }
            self.pendingTimer = nil
            self.logger.log("抓到的凭据 \(Self.pendingTimeoutMs / 1000) 秒内没有定局，丢弃")
            self.dropPending()
        }
        logger.log("抓到账号=\(Self.mask(username))，等登录结果再决定是否保存")
    }

    private func dropPending() {
        cancelPending()
        pending?.clear()
        pending = nil
    }

    // MARK: - Page Display Preferences

    private func applyPagePrefs(_ url: String) {
        guard hideNotices, Sues.isJxfwPage(url) else { return }
        guard tweakedDoc != flow.documentOrdinal else { return }
        tweakedDoc = flow.documentOrdinal
        evalQuietly("收起公告弹窗", ScriptBag.noticeDialog(hide: true)) { [weak self] result in
            self?.logger.log("收起公告弹窗：\(result)")
        }
    }

    // MARK: - JS Execution & Cookie Clearing

    private func guarded(
        _ what: String,
        fallbackText: String,
        action: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            do {
                try await action()
            } catch {
                self.logger.log("\(what)失败：\(type(of: error)) \(error.localizedDescription)")
                self.alert(fallbackText)
            }
        }
    }

    private func evalQuietly(
        _ what: String,
        _ script: String,
        onComplete: (@MainActor (String) -> Void)? = nil
    ) {
        Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            do {
                let value = try await self.eval(script)
                onComplete?(value)
            } catch {
                self.logger.log("\(what)失败：\(type(of: error)) \(error.localizedDescription)")
            }
        }
    }

    private func eval(_ script: String) async throws -> String {
        let value = try await webView.evaluateJavaScript(script)
        if let str = value as? String {
            return str
        }
        if value == nil || value is NSNull {
            return ""
        }
        return String(describing: value!)
    }

    private func clearCookiesAsync() async {
        let dataStore = webView.configuration.websiteDataStore
        let cookieStore = dataStore.httpCookieStore
        let cookies = await cookieStore.allCookies()
        for cookie in cookies {
            await cookieStore.deleteCookie(cookie)
        }
        let types: Set<String> = [WKWebsiteDataTypeCookies, WKWebsiteDataTypeSessionStorage]
        let records = await dataStore.dataRecords(ofTypes: types)
        if !records.isEmpty {
            await dataStore.removeData(ofTypes: types, for: records)
        }
    }

    // MARK: - Timers, Notices & Helpers

    private func saveSettings(_ what: String) {
        if !settings.save() {
            logger.log("\(what)：偏好没能写盘（磁盘或权限问题），本次会话仍有效")
        }
    }

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
    }

    private func postDelayed(ms: Int, action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: TimeInterval(ms) / 1000.0, repeats: false) { firedTimer in
            Task { @MainActor in
                guard firedTimer.isValid else { return }
                action()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func stopProbeTimer() {
        probeTimer?.invalidate()
        probeTimer = nil
    }

    private func cancelTransient() {
        transientTimer?.invalidate()
        transientTimer = nil
    }

    private func cancelArmed() {
        armedTimer?.invalidate()
        armedTimer = nil
    }

    private func cancelPending() {
        pendingTimer?.invalidate()
        pendingTimer = nil
    }

    private func alert(_ text: String, action: NoticeState.Action = .none) {
        showNotice(NoticeState(text: text, kind: .alert, sticky: true, action: action))
    }

    private func showNotice(_ value: NoticeState) {
        noticeTimer?.invalidate()
        noticeTimer = nil
        notice = value
        if !value.text.isEmpty && !value.sticky {
            noticeTimer = postDelayed(ms: Self.noticeTimeoutMs) { [weak self] in
                guard let self else { return }
                self.noticeTimer = nil
                self.notice = .empty
                self.raiseChanged()
            }
        }
        raiseChanged()
    }

    private func raiseChanged() {
        onChanged?()
    }

    private static func isIgnoredURL(_ url: String?) -> Bool {
        guard let url else { return true }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.lowercased().hasPrefix("about:blank")
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }

    private static func isCancellationError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            return true
        }
        if error.domain == "WebKitErrorDomain" && error.code == 102 {
            return true
        }
        return false
    }

    private static func isCertificateError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return true
        default:
            return false
        }
    }

    private static func mask(_ username: String) -> String {
        if username.count <= 4 { return "****" }
        return String(username.prefix(4)) + "****"
    }

    private static func truncate(_ value: String, _ maxLength: Int) -> String {
        if value.count <= maxLength { return value }
        return String(value.prefix(maxLength))
    }
}
