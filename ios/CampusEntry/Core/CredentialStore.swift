//
//  CredentialStore.swift
//  CampusEntry
//
//  由 `pc/src/CampusEntry/Core/CredentialStore.cs` 逐条移植（权威来源是 C#）；
//  Android 端 `CredentialStore.kt` 与 PC 端本来就逐字节同一套格式，这一份是第三份。
//
//  ══ 落盘格式：三端互通的硬约束，一个字节都不能改 ══════════════════════════════
//
//  落盘形态（一个 blob）：
//
//  ```
//  [0]      格式版本，目前是 1
//  [1..]    加解密后端产出的字节（自带 IV 与完整性标签）
//  ```
//
//  明文形态（交后端加密之前）：长度前缀的两段——
//
//  ```
//  [用户名长度 u16 大端][用户名 UTF-8][密码 UTF-8]
//  ```
//
//  用长度前缀而不是分隔符：用户名或密码里出现任何字符都不会把两段串起来。
//
//  **为什么这是硬约束**：三端要能读懂彼此留下的凭据——同一台设备上的迁移、排障时用另一端解出
//  同一份备份、以及「三端行为一致」这条产品承诺（`docs/CORE-SPEC.md` §6、`docs/APP-UX.md` §6.1）。
//  版本字节或明文分段方式一旦有差异，另一端就会把存下的凭据判成 `unreadable`，于是每次冷启动都
//  让用户重新登录一遍——这正是本工作区最想避免的失败模式。所以 **版本字节 1 + 长度前缀明文，
//  逐字节同一套**，任何一端都不得改动；要改只能整版本号一起改。
//
//  需要说清楚的一点：`[1..]` 那一段是**各端平台机制自己的地盘**——PC 是 DPAPI 的自有格式、
//  Android 是 `[IV 长度][IV][密文+标签]`、iOS 是 `nonce(12)||密文||标签(16)`。它由各端后端自己
//  决定，**不属于跨端契约**，上层只能当它是不透明字节。也就是说：三端「逐字节相同」的是版本字节
//  与明文分段，而不是这段密文本身（见 `KeychainCryptoBackend.swift`）。
//
//  ══ Swift 侧的命名与类型映射 ═════════════════════════════════════════════
//
//  命名按 Swift 惯例、与已完成的 `Sues.swift` / `EntryFlow.swift` / `EntryHost.swift` 对齐：
//  类型名 PascalCase，公开成员（属性、方法、静态常量）lowerCamelCase，**参数一律无标签 `_`**
//  （调用位次与 C#/Kotlin 逐位平行，也与 `Sues.entryUrl(_:_:)` 这类已有名一致）。「保持名称不变」
//  约束的是结构与语义，不是把 C# 的大小写习惯搬进 Swift。
//
//  | C#（权威）                     | Swift                                                        |
//  | ------------------------------ | ------------------------------------------------------------ |
//  | `sealed class Credential`      | `final class Credential`                                     |
//  | `char[]`                       | `[Character]`                                                |
//  | `byte[]` / `byte[]?`           | `[UInt8]` / `[UInt8]?`（本文件统一用 `[UInt8]`，不用 `Data`）   |
//  | `interface ICryptoBackend`     | `protocol CryptoBackend`（方法名逐条对应，只把首字母改小写）    |
//  | `Seal` / `Open`                | `seal(_:)` / `` `open`(_:) ``                                 |
//  | `SavedCredential` 记录族        | `enum SavedCredential`：`.absent` / `.loaded` / `.unreadable` |
//  | `ArgumentException`            | 本文件里的 `IllegalArgumentException`（Swift 无非受检异常）     |
//  | `CryptoException`              | `struct CryptoException: Error`                              |
//
//  `open` 在声明与调用两处都写反引号（`` backend.`open`(...) ``）：`open` 是访问级别修饰符
//  （`open class`），加上反引号在「它是关键字」与「它只是普通标识符」两种解析下都成立，
//  代价只有两个反引号。这不改变方法名与语义：它仍然对应 C# 的 `Open` / Kotlin 的 `open`。
//
//  ══ 明文擦除：诚实边界（不要假装做到了）══════════════════════════════════
//
//  PC 用 `Array.Clear`、Android 用 `fill(0)` 把明文就地清零，Swift 照做（`SecretWipe`）。但必须
//  对用户说清楚（`docs/APP-UX.md` §6.5 的同一段话）：
//
//  - `String` 一旦造出来就不可变，Swift 没有任何办法擦掉它的内容；
//  - `Array` / `Data` 是**值类型 + 写时复制**：我们只擦得掉自己这一份，任何一份副本都拿不到；
//  - 优化器有权把「写过就不再读」的写操作当死代码删掉；Swift 也没有 C 的 `memset_s` /
//    `explicit_bzero` 那种保证性擦除原语。
//
//  所以 `SecretWipe` 做的是**尽力而为**：用 `memset` 就地覆盖，把残留窗口压到最小，但**不宣称**
//  明文已被彻底擦除。此处没有「更多努力」可言，任何声称「彻底擦干净」的说法都是假的。
//

import Foundation

/// 一组账号密码。密码用 `[Character]` 承载，用完可以真的擦掉。
///
/// 对应 C# 的 `Credential : IDisposable`：`Dispose()` 在 Swift 里的等价物是 `deinit`，
/// 因此这里没有 `dispose()` 方法——对象一被释放，`deinit` 就自动走一遍 `clear()`，不需要调用方记得。
/// 想立刻擦掉就显式调 `clear()`，语义与 C# / Android 完全一致。
public final class Credential {

    public let username: String

    /// 对外只读（C# 的 `Password { get; }` 也是只读属性，只有数组内容可变）；擦除一律走 `clear()`。
    public private(set) var password: [Character]

    public init(_ username: String, _ password: [Character]) {
        self.username = username
        self.password = password
    }

    /// 擦掉密码。调用之后这个对象不可再用（尽力擦除，见文件头）。
    public func clear() {
        SecretWipe.characters(&password)
    }

    /// C# `Dispose()` 的等价物。Swift 没有 `IDisposable`，`deinit` 就是「用完自动收拾」的那一步。
    deinit {
        clear()
    }
}

/// 读取已保存凭据的结果。
///
/// C# 是一个抽象 record 加三个嵌套 sealed record（`SavedCredential.Absent` / `.Loaded` / `.Unreadable`）。
/// Swift 的原生对应物是枚举，三个 case 与三个 record 一一对应：
/// `.absent`（没保存过）/ `.loaded(Credential)`（解出来了）/ `.unreadable`（密文在但解不开）。
public enum SavedCredential {

    /// 没保存过，或者密文短得根本不成形。
    case absent

    /// 解出来了。**用完必须 `clear()`**。
    case loaded(Credential)

    /// 密文在，但解不开或格式不认（被改过、换过机器/用户、密钥被删过、版本比本应用新）。
    case unreadable
}

/// 密码学操作失败。
///
/// 只有一个用途：让上层能把「解不开」与「没保存过」归到同一条处置路径上（当作没有凭据，
/// 让用户重新登录一次），而不是崩溃或猜测。对应 C# 的 `CryptoException`、Android 的 `CryptoException`。
public struct CryptoException: Error, LocalizedError, CustomStringConvertible {

    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// 参数不合法（对应 C# 的 `ArgumentException`、Android 的 `IllegalArgumentException`）。
///
/// 语义与两端一致：**抛**，不是返回值、也不是断言崩溃——调用方要能区分「参数不合法，什么都没存」
/// 与「写盘失败」。Swift 没有非受检异常，所以它会出现在 `encode(_:_:) throws` 的签名里；
/// C#/Kotlin 里它一样会往上冒，只是不用写出来。
public struct IllegalArgumentException: Error, LocalizedError, CustomStringConvertible {

    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// 加解密后端。
///
/// Windows 端实现是 DPAPI（`DpapiCryptoBackend.cs`），iOS 端实现是 `KeychainCryptoBackend`
/// （Keychain 里的 AES-256 密钥 + CryptoKit 的 AES-GCM）。
///
/// 这一层是**唯一**与平台密码学打交道的地方，所以上面的 `CredentialStore` 完全不依赖任何平台机制，
/// 用一个假后端就能在任何 Swift 环境里单测（对应 PC 的 `CredentialStoreTests`）。
public protocol CryptoBackend {

    /// 加密。产出自带 IV 与完整性标签（后端自选格式）的字节。
    func seal(_ plain: [UInt8]) throws -> [UInt8]

    /// 解密；密文被改过或换过保护范围时抛 `CryptoException`，**绝不返回猜测出来的明文**。
    ///
    /// 方法名就是 PC 的 `Open` / Kotlin 的 `open`（只把首字母改小写）；反引号只是写法，
    /// 调用处写 `` backend.`open`(sealedBytes) ``，理由见文件头。
    func `open`(_ sealedBytes: [UInt8]) throws -> [UInt8]

    /// 丢弃密钥材料。之后**旧的密文再也解不开**——这正是「清除账号」要的效果：删掉密钥比只删密文彻底。
    ///
    /// 这个方法来自 Android 端 `CryptoBackend.destroy()`；PC 端的后端没有它——DPAPI 的密钥由系统按
    /// 用户账户保管，应用既删不掉也不必删。iOS 的密钥是 Keychain 里我们自己写的一条，**必须能删**
    /// （`docs/APP-UX.md` §6.1 的「清除」：删密文 + 删密钥库条目）。
    func destroy() throws
}

/// 凭据的落盘编解码与完整性处置。**纯逻辑**，与 Android 端 `CredentialStore.kt`、PC 端
/// `CredentialStore.cs` 逐字节同一套格式（见文件头）。
public final class CredentialStore {

    private static let tag = "教务直达"

    private static let version: UInt8 = 1
    private static let header = 2

    /// 判「账号是不是空的」用的空白集合。C# 用的是 `string.IsNullOrWhiteSpace`（`char.IsWhiteSpace`），
    /// 它比 `CharacterSet.whitespacesAndNewlines` 多算了 U+001C…U+001F 与 U+0085（NEL）。
    /// 不加这几个，一个「只由 NEL 组成」的账号会被 Swift 放过去存下来——那正是这条守卫要拦的
    /// 「永远登不进去的凭据」。以 C# 为准，把差集补上（Android 的 `isBlank` 用的是 Java 的
    /// `Character.isWhitespace`，本来就与 C# 略有出入；这里是 C# 的超集）。
    private static let blankCharacters: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{001C}\u{001D}\u{001E}\u{001F}\u{0085}")
        return set
    }()

    private let backend: CryptoBackend

    public init(_ backend: CryptoBackend) {
        self.backend = backend
    }

    /// 编码。账号为空或密码为空会抛 `IllegalArgumentException`（C# 是 `ArgumentException`）：
    /// **宁可在这里炸，也不要存下一组永远登不进去的凭据**——那会让应用每次启动都自动替用户消耗
    /// 一次失败次数，直达 5 次锁号。
    public func encode(_ username: String, _ password: [Character]) throws -> [UInt8] {
        // C# 的 `string.IsNullOrWhiteSpace`：全空白也算空（空白集合见 blankCharacters）。
        if username.trimmingCharacters(in: CredentialStore.blankCharacters).isEmpty {
            throw IllegalArgumentException("账号不能为空")
        }
        if password.isEmpty {
            throw IllegalArgumentException("密码不能为空")
        }
        var plain = CredentialStore.frame(username, password)
        defer { SecretWipe.bytes(&plain) }
        // 与 C#/Android 一样：版本字节在前，后端产出的字节跟在后面。
        return [CredentialStore.version] + (try backend.seal(plain))
    }

    /// 解码。任何不正常的情况都返回 `.absent` 或 `.unreadable`，**不抛**。
    public func decode(_ blob: [UInt8]?) -> SavedCredential {
        guard let blob = blob, blob.count > 1 else { return .absent }
        if blob[0] != CredentialStore.version { return .unreadable }

        var plain: [UInt8]
        do {
            plain = try backend.`open`(Array(blob[1...]))
        } catch is CryptoException {
            // 密文被改过 / 换过保护范围：按「解不开」处置，不崩溃、不猜测。
            return .unreadable
        } catch {
            // 后端契约要求只抛 CryptoException。C# 端这里没有 catch 其它异常（会一路往上冒），
            // 但 Swift 的 Decode 不允许抛，所以按「解不开」处置并**明确记一条日志**——
            // 静默会把后端的 bug 伪装成「用户没存过凭据」，这是排障时最费时间的一类问题。
            // 日志里只有错误描述：两个后端都不会把凭据本身放进错误里（`docs/APP-UX.md` §6.4 第 3 条）。
            NSLog("[%@] %@", CredentialStore.tag, "加解密后端抛出了非 CryptoException：\(error)")
            return .unreadable
        }
        defer { SecretWipe.bytes(&plain) }

        guard let credential = CredentialStore.unframe(plain) else { return .unreadable }
        return .loaded(credential)
    }

    private static func frame(_ username: String, _ password: [Character]) -> [UInt8] {
        let user = Array(username.utf8)
        // [Character] → UTF-8 字节必须先经过一个 String，而 String 擦不掉。
        // 这与 Android 端 `String(password).toByteArray()` 的残留窗口是同一个事实：只能缩短，不能根除。
        var text = ""
        for character in password {
            text.append(character)
        }
        var pass = Array(text.utf8)
        defer { SecretWipe.bytes(&pass) }

        var output = [UInt8](repeating: 0, count: header + user.count + pass.count)
        // 与 C# `(byte)(user.Length >> 8)` / `(byte)user.Length` 等价：取低 8 位（长到截断时，
        // 解出来会是不合法的长度，于是归为 unreadable——三端行为一致）。
        output[0] = UInt8(truncatingIfNeeded: user.count >> 8)
        output[1] = UInt8(truncatingIfNeeded: user.count)
        for index in 0..<user.count {
            output[header + index] = user[index]
        }
        for index in 0..<pass.count {
            output[header + user.count + index] = pass[index]
        }
        return output
    }

    private static func unframe(_ plain: [UInt8]) -> Credential? {
        if plain.count <= header { return nil }
        let length = (Int(plain[0] & 0xFF) << 8) | Int(plain[1] & 0xFF)
        if length <= 0 || header + length >= plain.count { return nil }
        let username = CredentialStore.utf8(plain, header, length)
        let password = CredentialStore.utf8(plain, header + length, plain.count - header - length)
        // 与 C# 的 `password.ToCharArray()`、Android 的 `password.toCharArray()` 一样，
        // 这里又出现一个擦不掉的 String 副本（见文件头「明文擦除」一段）。
        return Credential(username, Array(password))
    }

    /// 解码 UTF-8。与 `Encoding.UTF8.GetString` / `String(bytes, UTF_8)` 一致：
    /// 非法字节序列替换成 U+FFFD，不抛异常。
    private static func utf8(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> String {
        String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
    }
}

/// 尽最大努力擦除敏感缓冲。**模块内部共用一份**（`CredentialStore`、`CredentialRepository`、
/// `KeychainCryptoBackend` 都要擦），免得三处各写一遍、哪天只改了一处。
///
/// 不对外公开：这是实现细节，不是调用方该依赖的 API。
///
/// 能力边界见文件头「明文擦除：诚实边界」——这里只缩小残留窗口，**不保证**擦干净。
enum SecretWipe {

    /// 擦掉一段字节缓冲（对应 C# `Array.Clear` / Kotlin `fill(0)`）。
    static func bytes(_ buffer: inout [UInt8]) {
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = memset(base, 0, raw.count)
        }
    }

    /// 擦掉一段字符缓冲。`Character` 不是单字节类型，只能逐个赋值（`memset` 在这儿没有意义）。
    static func characters(_ buffer: inout [Character]) {
        buffer.withUnsafeMutableBufferPointer { raw in
            for index in raw.indices {
                raw[index] = "\0"
            }
        }
    }
}
