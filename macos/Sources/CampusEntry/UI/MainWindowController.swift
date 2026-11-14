import AppKit
import CampusEntryCore
import WebKit

/// Primary desktop window: top toolbar + dismissible first-run banner + full-bleed WKWebView.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let host: EntryHost
    private let settings: EntrySettings
    private let logger: RunLogger

    private var bannerDismissed = false
    private var awaitingSwitchReload = false
    private var lastNormalFrame: NSRect?
    private var shouldZoomOnShow = false
    private var eventMonitor: Any?
    private var isShowingFatalAlert = false

    // Top bar controls
    private let toolbarContainer = SurfaceView(fillColor: Theme.Colors.surface)
    private let backButton = ToolbarIconButton(
        symbolName: "chevron.left",
        accessibilityLabel: "后退",
        toolTip: "后退 (⌘[)"
    )
    private let forwardButton = ToolbarIconButton(
        symbolName: "chevron.right",
        accessibilityLabel: "前进",
        toolTip: "前进 (⌘])"
    )
    private let reloadButton = ToolbarIconButton(
        symbolName: "arrow.clockwise",
        accessibilityLabel: "刷新",
        toolTip: "刷新 (⌘R)"
    )
    private let tabJxfw = ToolbarTabButton(
        title: "教务系统",
        accessibilityLabel: "打开教务系统",
        toolTip: "教务系统 (⌘1)"
    )
    private let tabWebvpn = ToolbarTabButton(
        title: "WebVPN",
        accessibilityLabel: "打开 WebVPN",
        toolTip: "WebVPN (⌘2)"
    )
    private let noticeLabel = NSTextField(labelWithString: "")
    private let noticeActionButton = ToolbarTextButton(title: "", accessibilityLabel: "状态动作")
    private let settingsButton = ToolbarTextButton(
        title: "设置",
        symbolName: "gearshape",
        accessibilityLabel: "设置"
    )

    // First-run banner
    private let bannerContainer = SurfaceView(fillColor: Theme.Colors.neutral)
    private let bannerCloseButton = ToolbarIconButton(
        symbolName: "xmark",
        pointSize: 12,
        size: 28,
        cornerRadius: 6,
        accessibilityLabel: "关闭提示"
    )

    // WebView host
    private let webContainer = SurfaceView(fillColor: Theme.Colors.surface)

    init(host: EntryHost, settings: EntrySettings, logger: RunLogger) {
        self.host = host
        self.settings = settings
        self.logger = logger

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "教务直达"
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        restoreWindowBounds(window)
        buildUI(in: window)
        bindHost()
        installEventMonitor()
        refreshUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if shouldZoomOnShow, let window, !window.isZoomed {
            shouldZoomOnShow = false
            window.zoom(nil)
        }
    }

    private func buildUI(in window: NSWindow) {
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
        rootStack.detachesHiddenViews = true
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = rootStack

        buildToolbar()
        buildBanner()
        buildWebHost()

        rootStack.addArrangedSubview(toolbarContainer)
        rootStack.addArrangedSubview(bannerContainer)
        rootStack.addArrangedSubview(webContainer)

        NSLayoutConstraint.activate([
            toolbarContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            bannerContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            webContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
        ])
    }

    private func buildToolbar() {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubview(row)

        let divider = DividerView(axis: .horizontal)
        toolbarContainer.addSubview(divider)

        // Left group: Icon + Back/Forward/Reload + 1x20 separator + Entry tabs
        let iconView = AppIconView(size: 20)

        backButton.target = self
        backButton.action = #selector(onBack)

        forwardButton.target = self
        forwardButton.action = #selector(onForward)

        reloadButton.target = self
        reloadButton.action = #selector(onReload)

        let sep = DividerView(axis: .vertical, thickness: 1, length: 20)

        tabJxfw.target = self
        tabJxfw.action = #selector(onOpenJxfw)

        tabWebvpn.target = self
        tabWebvpn.action = #selector(onOpenWebvpn)

        let leftStack = NSStackView(views: [
            iconView,
            backButton,
            forwardButton,
            reloadButton,
            sep,
            tabJxfw,
            tabWebvpn,
        ])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 2
        leftStack.setCustomSpacing(10, after: iconView)
        leftStack.setCustomSpacing(10, after: reloadButton)
        leftStack.setCustomSpacing(10, after: sep)
        leftStack.setCustomSpacing(0, after: tabJxfw)
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(leftStack)

        // Right group: Notice text + NoticeAction + Settings
        noticeLabel.font = Theme.Typography.body
        noticeLabel.textColor = Theme.Colors.secondary
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.maximumNumberOfLines = 1
        noticeLabel.usesSingleLineMode = true
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeLabel.setAccessibilityLabel("状态")

        noticeActionButton.target = self
        noticeActionButton.action = #selector(onNoticeAction)
        noticeActionButton.isHidden = true

        settingsButton.target = self
        settingsButton.action = #selector(onSettings)
        settingsButton.toolTip = "设置 (⌘,)"

        let rightStack = NSStackView(views: [noticeLabel, noticeActionButton, settingsButton])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 16
        rightStack.detachesHiddenViews = true
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(rightStack)

        NSLayoutConstraint.activate([
            toolbarContainer.heightAnchor.constraint(equalToConstant: Theme.Layout.toolbarHeight + 1),

            row.topAnchor.constraint(equalTo: toolbarContainer.topAnchor),
            row.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: Theme.Layout.toolbarHeight),

            divider.topAnchor.constraint(equalTo: row.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),

            leftStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            leftStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            rightStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 16),

            noticeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.Layout.noticeMaxWidth),
        ])
    }

    private func buildBanner() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        bannerContainer.addSubview(content)

        let line1 = NSTextField(labelWithString: "非官方：这是个人做的教务系统快捷入口，与学校无关。")
        line1.font = Theme.Typography.body
        line1.textColor = Theme.Colors.ink
        line1.lineBreakMode = .byTruncatingTail
        line1.maximumNumberOfLines = 1

        let line2 = NSTextField(labelWithString: "首次登录后记住账号（加密保存在本机），以后双击图标直接进教务系统。")
        line2.font = Theme.Typography.body
        line2.textColor = Theme.Colors.secondary
        line2.lineBreakMode = .byTruncatingTail
        line2.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [line1, line2])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(textStack)

        bannerCloseButton.target = self
        bannerCloseButton.action = #selector(onCloseBanner)
        content.addSubview(bannerCloseButton)

        let bottomDivider = DividerView(axis: .horizontal)
        bannerContainer.addSubview(bottomDivider)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: bannerContainer.topAnchor, constant: Theme.Layout.bannerVerticalPadding),
            content.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -Theme.Layout.bannerVerticalPadding),
            content.leadingAnchor.constraint(equalTo: bannerContainer.leadingAnchor, constant: Theme.Layout.bannerHorizontalPadding),
            content.trailingAnchor.constraint(equalTo: bannerContainer.trailingAnchor, constant: -Theme.Layout.bannerHorizontalPadding),

            textStack.topAnchor.constraint(equalTo: content.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            textStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: bannerCloseButton.leadingAnchor, constant: -12),

            bannerCloseButton.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bannerCloseButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            bottomDivider.leadingAnchor.constraint(equalTo: bannerContainer.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: bannerContainer.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: bannerContainer.bottomAnchor),
        ])
    }

    private func buildWebHost() {
        let webView = host.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
    }

    private func bindHost() {
        host.onChanged = { [weak self] in
            guard let self else { return }
            if self.awaitingSwitchReload {
                self.awaitingSwitchReload = false
                self.host.open(self.host.activeEntry)
                return
            }
            self.refreshUI()
        }
        host.onFatalError = { [weak self] message in
            self?.handleFatalError(message: message)
        }
    }

    func refreshUI() {
        let docTitle = host.docTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.title = docTitle.isEmpty ? "教务直达" : "\(docTitle) — 教务直达"

        let ready = host.ready
        backButton.isEnabled = ready && host.canGoBack
        forwardButton.isEnabled = ready && host.canGoForward
        reloadButton.isEnabled = ready
        tabJxfw.isEnabled = ready
        tabWebvpn.isEnabled = ready
        settingsButton.isEnabled = ready
        noticeActionButton.isEnabled = ready

        tabJxfw.isSelectedTab = host.activeEntry == .jxfw
        tabWebvpn.isSelectedTab = host.activeEntry == .webvpn

        noticeLabel.stringValue = host.notice.text
        switch host.notice.kind {
        case .alert:
            noticeLabel.textColor = Theme.Colors.warning
        case .done:
            noticeLabel.textColor = Theme.Colors.success
        case .info, .none:
            noticeLabel.textColor = Theme.Colors.secondary
        }

        if let actionLabel = host.notice.actionLabel {
            noticeActionButton.titleText = actionLabel
            noticeActionButton.setAccessibilityLabel(actionLabel)
            noticeActionButton.isHidden = false
        } else {
            noticeActionButton.isHidden = true
        }

        let showBanner = host.savedUsername == nil && !bannerDismissed
        bannerContainer.isHidden = !showBanner
    }

    // MARK: - Actions

    @objc func onBack() {
        guard host.ready else { return }
        host.goBack()
    }

    @objc func onForward() {
        guard host.ready else { return }
        host.goForward()
    }

    @objc func onReload() {
        guard host.ready else { return }
        host.reload()
    }

    @objc func onOpenJxfw() {
        guard host.ready else { return }
        host.open(.jxfw)
    }

    @objc func onOpenWebvpn() {
        guard host.ready else { return }
        host.open(.webvpn)
    }

    @objc func onNoticeAction() {
        guard host.ready else { return }
        host.runNoticeAction()
    }

    @objc func onSettings() {
        guard host.ready, let window else { return }
        let dialog = SettingsWindowController(
            host: host,
            parentWindow: window,
            onSwitchRequested: { [weak self] in
                self?.awaitingSwitchReload = true
            },
            onChanged: { [weak self] in
                self?.refreshUI()
            }
        )
        dialog.runModal()
        refreshUI()
    }

    @objc private func onCloseBanner() {
        bannerDismissed = true
        refreshUI()
    }

    // MARK: - Shortcuts & Mouse Back/Forward

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            guard NSApp.modalWindow == nil, event.window === window else { return event }
            guard self.host.ready else { return event }

            if event.type == .otherMouseDown {
                if event.buttonNumber == 3 {
                    self.host.goBack()
                    return nil
                }
                if event.buttonNumber == 4 {
                    self.host.goForward()
                    return nil
                }
                return event
            }

            if event.type == .keyDown {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                // F5 -> Reload
                if event.keyCode == 96, flags.isEmpty {
                    self.host.reload()
                    return nil
                }
                // Cmd+Left -> Back, Cmd+Right -> Forward
                if flags == .command {
                    if event.keyCode == 123 {
                        self.host.goBack()
                        return nil
                    }
                    if event.keyCode == 124 {
                        self.host.goForward()
                        return nil
                    }
                }
            }

            return event
        }
    }

    // MARK: - Fatal Error

    private func handleFatalError(message: String) {
        guard !isShowingFatalAlert else { return }
        isShowingFatalAlert = true

        logger.log("启动失败：\(message)")

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "教务直达 — 无法启动"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Window Bounds Persistence

    private func restoreWindowBounds(_ window: NSWindow) {
        let defaultSize = NSSize(width: 1080, height: 720)
        var targetSize = defaultSize

        if let w = settings.width, let h = settings.height, w > 0, h > 0 {
            targetSize = NSSize(width: max(w, 760), height: max(h, 520))
        }

        if let x = settings.left, let y = settings.top {
            let candidate = NSRect(origin: NSPoint(x: x, y: y), size: targetSize)
            let isVisibleOnAnyScreen = NSScreen.screens.contains { screen in
                let overlap = screen.visibleFrame.intersection(candidate)
                return !overlap.isNull && overlap.width >= 80 && overlap.height >= 80
            }
            if isVisibleOnAnyScreen {
                window.setFrame(candidate, display: false)
                lastNormalFrame = candidate
            } else {
                window.setContentSize(targetSize)
                window.center()
                lastNormalFrame = window.frame
            }
        } else {
            window.setContentSize(targetSize)
            window.center()
            lastNormalFrame = window.frame
        }

        shouldZoomOnShow = settings.maximized
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, !window.isZoomed else { return }
        lastNormalFrame = window.frame
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, !window.isZoomed else { return }
        lastNormalFrame = window.frame
    }

    func windowWillClose(_ notification: Notification) {
        if let window {
            let normalFrame = window.isZoomed ? (lastNormalFrame ?? window.frame) : window.frame
            settings.left = Double(normalFrame.origin.x)
            settings.top = Double(normalFrame.origin.y)
            settings.width = Double(normalFrame.size.width)
            settings.height = Double(normalFrame.size.height)
            settings.maximized = window.isZoomed
            settings.save()
        }
        host.dispose()
    }
}
