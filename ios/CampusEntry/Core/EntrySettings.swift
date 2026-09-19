//
//  EntrySettings.swift
//  CampusEntry
//
//  由 `pc/src/CampusEntry/Core/EntrySettings.cs` 逐条移植（权威来源是 C#）：网关前缀、保存意愿、
//  公告开关，以及桌面那套窗口几何（iOS 上保留字段只为与另两端对齐，见下）。
//
//  ══ 持久化映射：JSON 文件 → UserDefaults ═════════════════════════════════
//
//  PC 把这几个偏好写成一个 JSON 文件：`%LOCALAPPDATA%\CampusEntry\entry.json`
//  （`JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true })`，
//  字段名就是属性的原名，null 与 "" 是两回事）。iOS 改用 **`UserDefaults.standard`**：
//
//  | C# 属性（权威）    | UserDefaults 键名   | 默认值 | 说明                          |
//  | ----------------- | ------------------- | ------ | ----------------------------- |
//  | `Prefix`          | `"Prefix"`          | 无     | 网关前缀；`nil` 与 `""` 不同义  |
//  | `SaveAccount`     | `"SaveAccount"`     | true   | 是否保存账号（自动登录的前提）   |
//  | `SaveDecided`     | `"SaveDecided"`     | false  | 用户是否已经做过「首页/入口」的选择 |
//  | `HideNotices`     | `"HideNotices"`     | true   | 是否隐藏公告                   |
//  | `WindowLeft`      | `"WindowLeft"`      | 无     | 桌面窗口几何；iOS 用不到        |
//  | `WindowTop`       | `"WindowTop"`       | 无     | 同上                          |
//  | `WindowWidth`     | `"WindowWidth"`     | 无     | 同上                          |
//  | `WindowHeight`    | `"WindowHeight"`    | 无     | 同上                          |
//  | `WindowMaximized` | `"WindowMaximized"` | false  | 同上                          |
//
//  键名**逐字沿用 PC 的字段名**（而不是 Android 的 `jxfw_prefix` / `save_account`）：PC 是这一层
//  的权威，同一个字段在两端必须同名——读另一端的配置、写文档、排障时才不会出现「同一个东西两个
//  名字」。窗口那四个字段在 iOS 上没有使用者（手机上没有可拖动的窗口），保留它们是为了让两端的
//  字段集合完全一致：少一个字段，将来对照两端配置时会以为对方漏存了。
//
//  ══ 凭据绝不进 UserDefaults ═════════════════════════════════════════════
//
//  UserDefaults 是一个**明文 plist**，既不加密，也会进 iTunes/iCloud 备份。所以凭据密文单独放
//  `CredentialRepository` 里那个 Keychain 存取的封装（见 `CredentialRepository.swift`），
//  与 PC 端「偏好 `entry.json` / 凭据 `credentials.bin` 两个文件分开」是同一种分法：
//  分开才好做「清除账号」与备份排除。**任何情况下都不要把凭据写进这里。**
//
//  ══ 读取失败的处置（策略与 PC 一致）══════════════════════════════════════
//
//  C# 的 `Load()` 外面是 try/catch：**偏好读不动就当首次使用**——宁可重新走一遍门户，也不带着
//  可疑状态跑。iOS 侧没有可 catch 的东西：UserDefaults 自己就把「读不到 / 值类型不对」变成
//  「该键未设置」，效果与「当首次使用」完全相同（字段保持下面的初始值）。因此这里没有 try/catch，
//  但处置策略与原注释逐条一致。
//
//  ══ Swift 侧映射 ════════════════════════════════════════════════════════
//
//  `public sealed class` → `public final class`；公开成员 lowerCamelCase（`prefix` / `saveAccount`
//  / `load()` / `save()`），参数无标签；`string?` → `String?`、`bool` → `Bool`、`double?` → `Double?`。
//  命名与已完成的 `Sues.swift` / `EntryFlow.swift` / `EntryHost.swift` 对齐。
//

import Foundation

/// 本机的落盘偏好。凭据不在这里——单独放 Keychain（见文件头）。
public final class EntrySettings {

    /// UserDefaults 里的键名。**逐字沿用 PC `entry.json` 的字段名**（见文件头的对照表）。
    private enum Key {
        static let prefix = "Prefix"
        static let saveAccount = "SaveAccount"
        static let saveDecided = "SaveDecided"
        static let hideNotices = "HideNotices"
        static let windowLeft = "WindowLeft"
        static let windowTop = "WindowTop"
        static let windowWidth = "WindowWidth"
        static let windowHeight = "WindowHeight"
        static let windowMaximized = "WindowMaximized"
    }

    public var prefix: String?
    public var saveAccount: Bool = true
    public var saveDecided: Bool = false
    public var hideNotices: Bool = true

    // 桌面惯例：记住上次窗口的大小与位置。nil = 未记录过（首次居中）。
    // iOS 上没有窗口可记，保留只为与 PC / Android 的字段集合对齐（见文件头）。
    public var windowLeft: Double?
    public var windowTop: Double?
    public var windowWidth: Double?
    public var windowHeight: Double?
    public var windowMaximized: Bool = false

    public init() {}

    /// 偏好所在的目录。PC 用它把偏好写成 `<目录>/entry.json`、把凭据写成
    /// `<目录>/credentials.bin`；iOS 两者都不落文件（偏好进 UserDefaults、密文进 Keychain），
    /// 所以这个属性只剩**与 PC 对照**的用途：返回 App 沙盒里 Application Support 下的
    /// `CampusEntry` 目录（将来若有非敏感文件要落盘，就用它）。名字与 PC 保持一致，好让两端
    /// 读代码时对得上。
    public static var directoryPath: String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return base.appendingPathComponent("CampusEntry", isDirectory: true).path
    }

    /// 读偏好。没存过的字段保持初始值——**偏好读不动就当首次使用**（理由见文件头）。
    public static func load() -> EntrySettings {
        let settings = EntrySettings()
        let defaults = UserDefaults.standard

        // 用 `object(forKey:)` 而不是 `string(forKey:)`：前者能区分「没存过」与「存过空串」，
        // 与 C# 里 `null` 和 `""` 是两回事这一点对齐。
        if let prefix = defaults.object(forKey: Key.prefix) as? String {
            settings.prefix = prefix
        }
        // 布尔与数字：键不存在时保持初始值（对应 C# 反序列化缺失字段时保留属性初始值）。
        if defaults.object(forKey: Key.saveAccount) != nil {
            settings.saveAccount = defaults.bool(forKey: Key.saveAccount)
        }
        if defaults.object(forKey: Key.saveDecided) != nil {
            settings.saveDecided = defaults.bool(forKey: Key.saveDecided)
        }
        if defaults.object(forKey: Key.hideNotices) != nil {
            settings.hideNotices = defaults.bool(forKey: Key.hideNotices)
        }
        settings.windowLeft = defaults.object(forKey: Key.windowLeft) as? Double
        settings.windowTop = defaults.object(forKey: Key.windowTop) as? Double
        settings.windowWidth = defaults.object(forKey: Key.windowWidth) as? Double
        settings.windowHeight = defaults.object(forKey: Key.windowHeight) as? Double
        if defaults.object(forKey: Key.windowMaximized) != nil {
            settings.windowMaximized = defaults.bool(forKey: Key.windowMaximized)
        }
        return settings
    }

    /// 写偏好。
    ///
    /// PC 那一步还会 `Directory.CreateDirectory(DirectoryPath)`——iOS 不需要建目录（UserDefaults
    /// 由系统管理），对应动作就是这里的 `set` / `removeObject`。也不调 `synchronize()`：它早已被
    /// 官方标为「不必要的」，系统会在合适的时机落盘，强行同步并不会给出更强的持久性承诺。
    public func save() {
        let defaults = UserDefaults.standard

        if let prefix = prefix {
            defaults.set(prefix, forKey: Key.prefix)
        } else {
            // `nil` 用 removeObject 表达：UserDefaults 存不了 nil，而「存过空串」与「没存过」
            // 在 C# 那边是两个不同的值，不能在这里合并成一个。
            defaults.removeObject(forKey: Key.prefix)
        }
        defaults.set(saveAccount, forKey: Key.saveAccount)
        defaults.set(saveDecided, forKey: Key.saveDecided)
        defaults.set(hideNotices, forKey: Key.hideNotices)

        EntrySettings.store(windowLeft, forKey: Key.windowLeft, in: defaults)
        EntrySettings.store(windowTop, forKey: Key.windowTop, in: defaults)
        EntrySettings.store(windowWidth, forKey: Key.windowWidth, in: defaults)
        EntrySettings.store(windowHeight, forKey: Key.windowHeight, in: defaults)
        defaults.set(windowMaximized, forKey: Key.windowMaximized)
    }

    private static func store(_ value: Double?, forKey key: String, in defaults: UserDefaults) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
