import SwiftUI
import WebKit

/// 根视图：拥有 `EntryHost`，把宿主的状态镜像成 SwiftUI 状态，并在入口页与浏览页之间路由。
///
/// 与 Android 端的分工一致：**业务规则全在 `EntryHost` 里**，这里只做两件事——把宿主的状态画出来、
/// 把用户意图转成宿主的方法调用（`DESIGN.md`/`APP-UX.md` 的分层要求：界面层不放业务规则）。
///
/// 整个视图标 `@MainActor`：它要构造 `EntryHost`（宿主本身是 `@MainActor`），
/// 并且从 `onChanged` 回调里回写 `@State`。显式标注比依赖 SDK 对 `View` 的隔离推断更稳。
@MainActor
struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase

    @State private var host: EntryHost?
    @State private var ready = false

    // 宿主持有真状态，这里只是镜像；每次 `onChanged` 全量刷新，不做局部推断。
    @State private var notice = Notice.none
    @State private var home = false
    @State private var saveAccount = false
    @State private var savedUsername: String?
    @State private var hideNotices = false
    @State private var activeEntry: Sues.Entry = .jxfw
    @State private var pageTitle = ""

    @State private var showAccount = false

    var body: some View {
        Group {
            if let host, ready {
                if home {
                    HomeView(onPick: { host.enterFromHome($0) })
                } else {
                    BrowserView(
                        webView: host.webView,
                        title: pageTitle,
                        notice: notice,
                        activeEntry: activeEntry,
                        onSelect: { host.openEntry($0) },
                        onNoticeAction: { host.onNoticeAction() },
                        onOpenAccount: { showAccount = true })
                }
            } else {
                // 还没有宿主：只可能出现在构建的那一帧
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: start)
        .sheet(isPresented: $showAccount) {
            if let host {
                AccountSheet(
                    savedUsername: savedUsername,
                    saveAccount: saveAccount,
                    hideNotices: hideNotices,
                    onChangeSaveAccount: { host.changeSaveAccount($0) },
                    onChangeHideNotices: { host.changeHideNotices($0) },
                    onOpenHome: { host.openHome(); showAccount = false },
                    onClearSession: {
                        showAccount = false
                        Task { await host.clearSessionAsync() }
                    },
                    onClearAccount: { host.clearAccount() },
                    onSwitchAccount: {
                        showAccount = false
                        Task { await host.switchAccountAsync() }
                    },
                    onClose: { showAccount = false })
            }
        }
        // 退到后台要停掉页面监视器、回前台要重装（`docs/CORE-SPEC.md` §5.1）：
        // 不重装的话，后台回来之后自动滑块会静默失效——这是实测踩过的坑。
        .onChange(of: scenePhase) { _, phase in
            guard let host else { return }
            switch phase {
            case .active: host.onResume()
            case .background, .inactive: host.onPause()
            @unknown default: break
            }
        }
    }

    // ---------------------------------------------------------------- 组装与状态镜像

    private func start() {
        guard host == nil else { return }

        let settings = EntrySettings.load()

        // 一个 backend 同时交给 store 与 repository：两边操作的是同一条 Keychain 密钥，
        // 建两个实例虽然指向同一条目，但「清除账号」时要删的那把钥匙应当只有一处持有者。
        let backend = KeychainCryptoBackend()
        let repository = CredentialRepository(CredentialStore(backend), backend)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        // UA：把默认 UA 里的应用名部分换成桌面 Safari 的标记。
        //
        // 目的与 Android `EntryHost.kt` 里那句 `userAgentString.replace("Mobile", "eliboM")
        // .replace("Android", "diordnA")` 相同——**尽量让站点给出「独立的滑动登录文档」那一形态**，
        // 而不是手机版的同页滑块。
        //
        // 用 `applicationNameForUserAgent` 而不是 `customUserAgent`：前者是官方提供的
        // 「替换 UA 里的应用名部分」的 API（默认值就是 `Mobile/15E148`），不用手工拼整条 UA，
        // 也不必去 KVC 读私有的 `WKWebView.userAgent`。
        //
        // 残余差异（**未在真机验证**）：UA 里仍然含 "iPhone" 标记，站点若按它判手机，
        // 就会走到「与表单同页」的那一形态。
        //
        // 这个差异**不再影响正确性**（2026-09 审计后修正的判断）：那一形态原先会静默失效——
        // `shared/js/captcha-watch.js` 的上报门禁要求「这份文档没有密码框」，于是同页形态提交后
        // 图片永不上报，宿主两个分支也都不命中。**那个缺陷已经修掉**（门禁只认 `armed`，
        // `EntryHost.onArmed` 也只认 `armed`），所以两种形态现在都能自动拖；差别只剩页面观感。
        // 因此这里**故意不**改成整条桌面 UA：那等于对站点谎报平台，而收益已经不存在了。
        // 真机上若发现观感确实不对，再单独评估。
        configuration.applicationNameForUserAgent = "Safari/605.1.15"

        let created = EntryHost(settings: settings, repository: repository, configuration: configuration)

        created.onChanged = { [weak created] in
            guard let created else { return }
            mirror(created)
        }
        created.onViewTitleChanged = { [weak created] in
            guard created != nil else { return }
            pageTitle = $0
        }
        // 等价于 C# 的 `Ready`：接好回调之后才开始替用户导航。
        // 首次使用先进入口页（把「会记住账号」交代清楚），之后直达教务系统。
        created.onReady = { [weak created] in
            guard let created else { return }
            if !created.home { created.openEntry(.jxfw) }
        }

        host = created
        mirror(created)
        ready = true
        created.start()
    }

    private func mirror(_ host: EntryHost) {
        notice = host.notice
        home = host.home
        saveAccount = host.saveAccount
        savedUsername = host.savedUsername
        hideNotices = host.hideNotices
        activeEntry = host.activeEntry
    }
}
