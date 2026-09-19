import SwiftUI

/// `DESIGN.md` 的视觉 token 落到 SwiftUI。
///
/// **取值不是自己编的**：浅色与深色两套都取自 Android 端 `Theme.kt` 的 `LightColors` / `DarkColors`
/// （`DESIGN.md` 是唯一来源，Android 是它目前最完整的一次落地）。这样三端的视觉身份是同一套，
/// 不会出现"iOS 看起来是另一个应用"。
///
/// 只有一处例外，已在下面标注：Android 没有给深色模式单独定义 `primary-deep`（它只用作按下态），
/// 所以深色下的按下态取了一个从 `primary` 派生的值，而不是假装规范里有。
enum Theme {

    // ---------------------------------------------------------------- 颜色

    /// 交互蓝。全应用唯一的驱动色。
    static let primary = Color.adaptive(light: 0x2F6FB5, dark: 0x5B9BD5)

    /// 交互蓝的按下态。深色取值是从 primary 派生的（Android 未定义深色下的按下态）。
    static let primaryPressed = Color.adaptive(light: 0x24548A, dark: 0x4A87C2)

    /// 墨色：标题与正文。
    static let ink = Color.adaptive(light: 0x1A1C1E, dark: 0xE8EAED)

    /// 石板灰：未激活标签、辅助说明。
    static let secondary = Color.adaptive(light: 0x6C7278, dark: 0xA2A9B0)

    /// 页面底色。
    static let background = Color.adaptive(light: 0xF5F7FA, dark: 0x121417)

    /// 卡片、底栏、输入框底色。
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x1B1E22)

    /// 唯一的分隔线颜色。
    static let line = Color.adaptive(light: 0xE3E3E3, dark: 0x2C3136)

    /// 状态语义色：只在需要用户改变行为时出现。
    static let success = Color.adaptive(light: 0x2E7D5B, dark: 0x6FBF95)
    static let warning = Color.adaptive(light: 0x8F5500, dark: 0xE0A85C)
    static let error = Color.adaptive(light: 0xB3261E, dark: 0xF2B8B5)

    // ---------------------------------------------------------------- 圆角与间距（与 DESIGN.md 同值）

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32

        /// 触控目标下限。视觉尺寸可以更小，但可点区域必须补足。
        static let touch: CGFloat = 48
    }

    // ---------------------------------------------------------------- 字体（DESIGN.md typography）

    enum Font {
        static let headlineSmall = SwiftUI.Font.system(size: 24, weight: .semibold)
        static let titleMedium = SwiftUI.Font.system(size: 16, weight: .semibold)
        static let titleSmall = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let bodyLarge = SwiftUI.Font.system(size: 16)
        static let bodyMedium = SwiftUI.Font.system(size: 14)
        static let bodySmall = SwiftUI.Font.system(size: 12)
        static let labelLarge = SwiftUI.Font.system(size: 14, weight: .medium)
        static let labelMedium = SwiftUI.Font.system(size: 12, weight: .medium)
        static let labelSmall = SwiftUI.Font.system(size: 11, weight: .medium)
    }
}

extension Color {

    /// 用 `0xRRGGBB` 直接写颜色，避免到处出现 `Double` 分量。
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }

    /// 跟随系统浅色/深色切换的颜色。
    ///
    /// `DESIGN.md` 只给了浅色 token，深色取值来自 Android 端 `Theme.kt`；
    /// 这里不接受"只做浅色"——那会在深色系统下变成一片刺眼的白。
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
        })
    }
}
