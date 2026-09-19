import SwiftUI

/// 应用入口。
///
/// 形态上刻意与 Android 端保持同一套页面语义（浏览页 + 底部栏 + 状态一句话 + 账号 sheet），
/// 与 PC 端的桌面形态不同——PC 端那套自绘标题栏/工具栏是桌面惯例，不是把手机界面放大。
///
/// 依赖只有系统框架：SwiftUI / WebKit / Security / CryptoKit。没有第三方包。
@main
struct CampusEntryApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
