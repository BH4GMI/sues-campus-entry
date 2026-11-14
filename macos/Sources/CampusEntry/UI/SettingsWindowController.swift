import AppKit
import CampusEntryCore

/// Modal settings dialog (460px wide, non-resizable, centered over the main window).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let host: EntryHost
    private let onSwitchRequested: () -> Void
    private let onChanged: () -> Void
    private weak var parentWindow: NSWindow?

    private let savedLine = NSTextField(labelWithString: "已保存：未保存")
    private let saveAccountBox = StyledCheckbox(
        title: "自动登录",
        subtitle: "登录后记住账号（加密保存在本机），下次自动填写"
    )
    private let hideNoticesBox = StyledCheckbox(
        title: "收起教务系统首页的公告弹窗",
        subtitle: "那个弹窗没有关闭按钮；收起后仍可从页面右侧「通知公告」进入"
    )
    private let clearSessionButton = DialogActionButton(
        title: "清除缓存 · 退出登录",
        style: .ghost,
        minWidth: 150,
        accessibilityLabel: "清除缓存并退出登录"
    )
    private let clearAccountButton = DialogActionButton(
        title: "清除账号",
        style: .danger,
        minWidth: 150,
        accessibilityLabel: "清除账号"
    )
    private let switchAccountButton = DialogActionButton(
        title: "改用其他账号",
        style: .ghost,
        minWidth: 150,
        accessibilityLabel: "改用其他账号"
    )
    private let closeButton = DialogActionButton(
        title: "关闭",
        style: .ghost,
        minWidth: 92,
        accessibilityLabel: "关闭"
    )

    private final class ModalDialogWindow: NSWindow {
        var onDismissKey: (() -> Void)?

        override func cancelOperation(_ sender: Any?) {
            onDismissKey?()
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
                onDismissKey?()
                return
            }
            super.keyDown(with: event)
        }
    }

    init(
        host: EntryHost,
        parentWindow: NSWindow,
        onSwitchRequested: @escaping () -> Void,
        onChanged: @escaping () -> Void
    ) {
        self.host = host
        self.parentWindow = parentWindow
        self.onSwitchRequested = onSwitchRequested
        self.onChanged = onChanged

        let dialogWindow = ModalDialogWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        dialogWindow.title = "设置"
        dialogWindow.isReleasedWhenClosed = false
        dialogWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        dialogWindow.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: dialogWindow)
        dialogWindow.delegate = self
        dialogWindow.onDismissKey = { [weak self] in
            self?.closeDialog()
        }

        buildUI(in: dialogWindow)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func runModal() {
        guard let window else { return }
        window.layoutIfNeeded()
        centerOverParent()
        NSApp.runModal(for: window)
    }

    private func centerOverParent() {
        guard let window else { return }
        guard let parentFrame = parentWindow?.frame else {
            window.center()
            return
        }
        let size = window.frame.size
        let x = parentFrame.origin.x + (parentFrame.width - size.width) / 2.0
        let y = parentFrame.origin.y + (parentFrame.height - size.height) / 2.0
        window.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    private func buildUI(in window: NSWindow) {
        let root = SurfaceView(fillColor: Theme.Colors.surface)
        window.contentView = root

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)

        // Section: 账号
        let accountHeading = NSTextField(labelWithString: "账号")
        accountHeading.font = Theme.Typography.sectionTitle
        accountHeading.textColor = Theme.Colors.ink
        contentStack.addArrangedSubview(accountHeading)
        contentStack.setCustomSpacing(5, after: accountHeading)

        savedLine.font = Theme.Typography.caption
        savedLine.textColor = Theme.Colors.secondary
        contentStack.addArrangedSubview(savedLine)
        contentStack.setCustomSpacing(14, after: savedLine)

        saveAccountBox.target = self
        saveAccountBox.action = #selector(onSaveAccountToggled)
        contentStack.addArrangedSubview(saveAccountBox)
        saveAccountBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.setCustomSpacing(16, after: saveAccountBox)

        hideNoticesBox.target = self
        hideNoticesBox.action = #selector(onHideNoticesToggled)
        contentStack.addArrangedSubview(hideNoticesBox)
        hideNoticesBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.setCustomSpacing(18, after: hideNoticesBox)

        let middleDivider = DividerView(axis: .horizontal)
        contentStack.addArrangedSubview(middleDivider)
        middleDivider.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.setCustomSpacing(16, after: middleDivider)

        // Section: 本机数据
        let dataHeading = NSTextField(labelWithString: "本机数据")
        dataHeading.font = Theme.Typography.sectionTitle
        dataHeading.textColor = Theme.Colors.ink
        contentStack.addArrangedSubview(dataHeading)
        contentStack.setCustomSpacing(10, after: dataHeading)

        clearSessionButton.target = self
        clearSessionButton.action = #selector(onClearSession)
        contentStack.addArrangedSubview(clearSessionButton)
        contentStack.setCustomSpacing(5, after: clearSessionButton)

        let clearSessionHint = NSTextField(wrappingLabelWithString: "取消登录状态（删除 cookie），不删除保存的密码")
        clearSessionHint.font = Theme.Typography.caption
        clearSessionHint.textColor = Theme.Colors.secondary
        contentStack.addArrangedSubview(clearSessionHint)
        contentStack.setCustomSpacing(14, after: clearSessionHint)

        clearAccountButton.target = self
        clearAccountButton.action = #selector(onClearAccount)
        contentStack.addArrangedSubview(clearAccountButton)
        contentStack.setCustomSpacing(5, after: clearAccountButton)

        let clearAccountHint = NSTextField(wrappingLabelWithString: "删除加密保存在本机的账号密码；下次要重新手动登录")
        clearAccountHint.font = Theme.Typography.caption
        clearAccountHint.textColor = Theme.Colors.secondary
        contentStack.addArrangedSubview(clearAccountHint)
        contentStack.setCustomSpacing(14, after: clearAccountHint)

        switchAccountButton.target = self
        switchAccountButton.action = #selector(onSwitchAccount)
        contentStack.addArrangedSubview(switchAccountButton)

        // Footer
        let footerTopDivider = DividerView(axis: .horizontal)
        root.addSubview(footerTopDivider)

        let footerBar = NSView()
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerBar)

        closeButton.target = self
        closeButton.action = #selector(onClose)
        closeButton.setKeyEquivalent("\r")
        footerBar.addSubview(closeButton)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 460),

            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            footerTopDivider.topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: 20),
            footerTopDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerTopDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footerBar.topAnchor.constraint(equalTo: footerTopDivider.bottomAnchor),
            footerBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footerBar.heightAnchor.constraint(equalToConstant: 58),

            closeButton.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -20),
            closeButton.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor),
        ])
    }

    func refresh() {
        if let username = host.savedUsername {
            savedLine.stringValue = "已保存：\(Self.maskUsername(username))"
        } else {
            savedLine.stringValue = "已保存：未保存"
        }
        saveAccountBox.isChecked = host.saveAccount
        hideNoticesBox.isChecked = host.hideNotices
        clearAccountButton.isEnabled = host.savedUsername != nil
    }

    static func maskUsername(_ username: String) -> String {
        if username.count <= 4 {
            return "****"
        }
        return String(username.prefix(4)) + "****"
    }

    @objc private func onSaveAccountToggled() {
        host.setSaveAccount(saveAccountBox.isChecked)
        onChanged()
        refresh()
    }

    @objc private func onHideNoticesToggled() {
        host.setHideNotices(hideNoticesBox.isChecked)
        onChanged()
    }

    @objc private func onClearSession() {
        host.clearSession()
        onChanged()
        closeDialog()
    }

    @objc private func onClearAccount() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清除账号"
        alert.informativeText = "删除加密保存在本机的账号密码？删除后下次要重新手动登录。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        host.clearAccount()
        onChanged()
        refresh()
    }

    @objc private func onSwitchAccount() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "改用其他账号"
        alert.informativeText = "清掉登录状态与本机账号，重新走一遍首次登录？"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        onSwitchRequested()
        host.switchAccount()
        onChanged()
        closeDialog()
    }

    @objc private func onClose() {
        closeDialog()
    }

    private func closeDialog() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}
