import AppKit
import CampusEntryCore

/// Application delegate managing lifecycle, main menu, and the single main browser window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var mainWindowController: MainWindowController?
    private let logger = RunLogger.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIconDrawer.applicationIcon()
        buildMainMenu()

        let settings = EntrySettings.load()
        let host = EntryHost(settings: settings, logger: logger)
        let controller = MainWindowController(host: host, settings: settings, logger: logger)
        self.mainWindowController = controller

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.open(.jxfw)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu Actions

    @objc private func openSettings(_ sender: Any?) {
        mainWindowController?.onSettings()
    }

    @objc private func navigateBack(_ sender: Any?) {
        mainWindowController?.onBack()
    }

    @objc private func navigateForward(_ sender: Any?) {
        mainWindowController?.onForward()
    }

    @objc private func reloadPage(_ sender: Any?) {
        mainWindowController?.onReload()
    }

    @objc private func openJxfw(_ sender: Any?) {
        mainWindowController?.onOpenJxfw()
    }

    @objc private func openWebvpn(_ sender: Any?) {
        mainWindowController?.onOpenWebvpn()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let host = mainWindowController?.host else { return false }
        if NSApp.modalWindow != nil { return false }

        switch menuItem.action {
        case #selector(openSettings(_:)):
            return host.ready
        case #selector(navigateBack(_:)):
            return host.ready && host.canGoBack
        case #selector(navigateForward(_:)):
            return host.ready && host.canGoForward
        case #selector(reloadPage(_:)):
            return host.ready
        case #selector(openJxfw(_:)):
            return host.ready
        case #selector(openWebvpn(_:)):
            return host.ready
        default:
            return true
        }
    }

    // MARK: - Menu Construction

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "教务直达")
        appMenu.addItem(withTitle: "关于 教务直达", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 教务直达", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 教务直达", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu (enables Cut/Copy/Paste/SelectAll inside WKWebView forms)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Navigation Menu
        let navMenuItem = NSMenuItem()
        let navMenu = NSMenu(title: "导航")

        let backItem = NSMenuItem(title: "后退", action: #selector(navigateBack(_:)), keyEquivalent: "[")
        backItem.target = self
        navMenu.addItem(backItem)

        let forwardItem = NSMenuItem(title: "前进", action: #selector(navigateForward(_:)), keyEquivalent: "]")
        forwardItem.target = self
        navMenu.addItem(forwardItem)

        let reloadItem = NSMenuItem(title: "刷新", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        reloadItem.target = self
        navMenu.addItem(reloadItem)

        navMenu.addItem(.separator())

        let jxfwItem = NSMenuItem(title: "教务系统", action: #selector(openJxfw(_:)), keyEquivalent: "1")
        jxfwItem.target = self
        navMenu.addItem(jxfwItem)

        let webvpnItem = NSMenuItem(title: "WebVPN", action: #selector(openWebvpn(_:)), keyEquivalent: "2")
        webvpnItem.target = self
        navMenu.addItem(webvpnItem)

        navMenuItem.submenu = navMenu
        mainMenu.addItem(navMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu
    }
}
