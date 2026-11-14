import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    // NSApplication.delegate 是 weak 引用：delegate 必须由这里的局部强引用兜住整个
    // run loop，否则 ARC 允许在 run() 之前就把它释放掉（表现是启动后无窗口、无菜单）。
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
