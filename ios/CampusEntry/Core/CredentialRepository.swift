//
//  CredentialRepository.swift
//  CampusEntry
//
//  由 `pc/src/CampusEntry/Core/CredentialRepository.cs` 逐条移植（权威来源是 C#），
//  存储介质按 iOS 的平台机制映射。
//
//  ══ 角色划分（三端同一套）════════════════════════════════════════════════
//
//  这里是**唯一**一处知道凭据存在哪儿的代码；编解码、版本与完整性处置全在上面的
//  `CredentialStore` 里（纯逻辑，可单测）。密钥永远不以任何形式出现在这个类里——它由
//  `KeychainCryptoBackend` 单独管，这个类只负责「把密文搬进搬出 + 把 keychain 条目的增删改查
//  包起来」。
//
//  ══ 存储映射 ═══════════════════════════════════════════════════════════
//
//  | 端 | 密文 | 密钥 |
//  | -- | ---- | ---- |
//  | PC | 文件 `<目录>/credentials.bin`（先写 `.tmp` 再 `Move`，避免半截文件）| DPAPI（CurrentUser 范围），非导出、随用户账户，应用管不着 |
//  | Android | `SharedPreferences` 里的一个 Base64 字符串（`commit()` 同步落盘）| `AndroidKeyStore` 条目不导出 |
//  | iOS（这一份）| **Keychain** 一条 `kSecClassGenericPassword`（`kSecAttrService` = `campus-entry`，`kSecAttrAccount` = `credentials.bin`）| 另一条 Keychain 条目，见 `KeychainCryptoBackend.swift` |
//
//  iOS 侧刻意**不走 UserDefaults**：UserDefaults 是一个明文 plist，既不加密、也会进 iTunes/iCloud
//  备份；凭据密文放进去等于把 PC 端「偏好 entry.json / 凭据 credentials.bin 两个文件分开」这条
//  分法作废（`EntrySettings.swift` 文件头也写明这一条）。
//
//  两条条目都用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：
//  - `AfterFirstUnlock`：开机解锁过一次之后就能读，这是**全自动登录**的前提（对齐 Android 的
//    `setUserAuthenticationRequired(false)`：要求每次现场验身份就没法自动了）。
//  - `ThisDeviceOnly`：不进 iCloud Keychain、也不随备份迁移到新设备。密文离机本来就解不开，
//    但它也不该外流——与 Android 的 `allowBackup="false"` 是同一条原则。
//  - **不设任何可同步属性**（不写 `kSecAttrSynchronizable`，Keychain 默认即不同步）。
//
//  **覆盖面差异（诚实记录）**：Android 的密钥不可导出，攻击者拿不到密钥材料；iOS 的密钥是
//  Keychain 里的一条 256 位密钥，应用**必须读出来**交给 CryptoKit，因此能在本应用进程里执行代码的
//  攻击者可以连密钥一起拿到。这不是「再努力加密」能解决的问题，`docs/APP-UX.md` §6.5 已经把这条
//  边界对用户讲清楚了（加密保护的是静态数据，不保护运行中的进程）。
//
//  ══ Swift 侧的命名与类型映射 ═════════════════════════════════════════════
//
//  与已完成的 `Sues.swift` / `EntryFlow.swift` 对齐：类型名 PascalCase，公开成员 lowerCamelCase，
//  参数一律无标签 `_`（调用位次与 C#/Kotlin 逐位平行）。`CredentialRepository` 的构造参数去掉了
//  PC 的第一个参数 `directory`——理由见 `init` 的注释（不保留比传一个被忽略的假值诚实）。
//

import Foundation
import Security

/// 凭据在本机的存放处：**密文**在 Keychain，**密钥**由 `KeychainCryptoBackend` 单独管。
/// 对齐 PC 端 `CredentialRepository.cs` 与 Android 端 `CredentialRepository.kt`：这里只做存储胶水，
/// 编解码在 `CredentialStore`。
public final class CredentialRepository {

    private static let tag = "教务直达"

    private let store: CredentialStore
    private let backend: CryptoBackend

    /// - Parameters:
    ///   - store: 编解码（纯逻辑）。
    ///   - backend: 加解密后端。**PC 的 `CredentialRepository` 不需要它**（DPAPI 的密钥删不掉也不必删），
    ///     Android 与 iOS 需要：`clear()` 要连密钥一起删（`docs/APP-UX.md` §6.1 的「清除」）。
    ///
    /// 这里**没有** PC 的 `directory` 参数：PC 要用它拼出 `<目录>/credentials.bin`，而 iOS 的落点是
    /// Keychain——一个扁平的、按应用隔离的命名空间，没有「路径」可言。要保留这个参数就只能传一个
    /// 被静默忽略的假路径，比去掉它更容易误导人。也**不能**把沙盒路径写进 Keychain 条目名：容器
    /// 路径里带 UUID，重装后会变，用它做条目名会让旧条目变成孤儿（而 Keychain 条目在卸载后仍然存在）。
    /// 因此条目名用固定常量，语义对齐 Android 端固定的别名 / SharedPreferences 键。
    public init(_ store: CredentialStore, _ backend: CryptoBackend) {
        self.store = store
        self.backend = backend
    }

    /// 保存。返回是否真的落盘了——那句「已记住账号」不能撒谎。
    ///
    /// 返回值与 C#/Kotlin 一致：只有**真的写下去了**才是 `true`。写法上的差别：PC/Android 让
    /// `Encode` 的 `ArgumentException` 直接往上冒（非受检异常），而 iOS 的调用点
    /// （`EntryHost.settle()`）是 `do { saved = repository.save(...) }`，不接异常，所以这里必须自己
    /// 处置参数不合法：**明确记一条日志**再返回 `false`，绝不静默——否则上层只能说「账号没能保存，
    /// 请重试」，而日志里也看不出真正原因是「抓到的账号/密码是空的」。
    public func save(_ username: String, _ password: [Character]) -> Bool {
        var blob: [UInt8]
        do {
            blob = try store.encode(username, password)
        } catch {
            NSLog("[%@] %@", CredentialRepository.tag, "凭据参数不合法，未落盘：\(error)")
            return false
        }
        // C# 的 `finally { Array.Clear(blob, 0, blob.Length); }`：密文已经交出去了，临时字节立刻擦掉。
        defer { SecretWipe.bytes(&blob) }
        return writeBlob(blob)
    }

    /// 读出一组可用凭据；没有或解不开都返回 `nil`。**拿到就必须 `clear()`。**
    public func load() -> Credential? {
        switch store.decode(blob()) {
        case .loaded(let credential):
            return credential
        case .unreadable:
            // 不静默：处置一样（让用户重登），但排障时要分得清「没存过」与「解不开」
            NSLog("[%@] %@", CredentialRepository.tag, "已保存的凭据解不开（换设备/密钥被删过/密文被改），按未保存处理")
            return nil
        case .absent:
            return nil
        }
    }

    /// 已经保存的账号名（界面打码显示）。解出来拿到名字就立刻擦掉密码——
    /// 不为了画一行字，把密码留在内存里。
    public func savedUsername() -> String? {
        guard let credential = load() else { return nil }
        // C# 的 `using var credential = Load();`：作用域结束就 Dispose（擦掉密码）。
        defer { credential.clear() }
        return credential.username
    }

    /// 清除：删密文**并且删密钥**。只删密文的话密钥还在，剩下的只有运气。
    ///
    /// PC 的 `Clear` 只删文件（DPAPI 的密钥删不掉、也不必删）；iOS 跟 Android：密钥是 Keychain 里
    /// 我们自己写的一条条目，删掉它比只删密文彻底。失败一律记日志、不抛（PC 的 `Clear` 也是
    /// catch + `Debug.WriteLine`）：用户那边只有「重试」这一条可走，把异常冒到界面上没有可处置的路径，
    /// 但原因（OSStatus / 错误描述）不会静默丢掉。
    public func clear() {
        let status = SecItemDelete(CredentialRepository.blobQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            // 条目不在就是已经清干净了，不算失败（幂等，与 PC 的 `if (File.Exists) File.Delete` 等价）。
            NSLog("[%@] %@", CredentialRepository.tag, "凭据密文删除失败：OSStatus \(status)")
        }
        do {
            try backend.destroy()
        } catch {
            NSLog("[%@] %@", CredentialRepository.tag, "删除密钥失败：\(error)")
        }
    }

    // ---------------------------------------------------------------- Keychain 存取

    /// 写密文条目。返回是否真的写下去了。
    ///
    /// 先 `SecItemUpdate`、只在条目不存在时 `SecItemAdd`：Keychain 的这两个操作本身是原子的，
    /// 不会留下「写了一半」的中间态——PC 侧那套「先写 `.tmp` 再 `Move`」要达到的正是这个效果，
    /// 在 iOS 上由平台机制天然满足，不需要再自己写一遍。
    private func writeBlob(_ blob: [UInt8]) -> Bool {
        let query = CredentialRepository.blobQuery()
        let data = Data(blob)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            // 与 PC 的 catch 分支同一个语义：落盘没成功就返回 false（那句话不能撒谎）。
            NSLog("[%@] %@", CredentialRepository.tag, "凭据落盘失败：OSStatus \(updateStatus)")
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            NSLog("[%@] %@", CredentialRepository.tag, "凭据落盘失败：OSStatus \(addStatus)")
            return false
        }
        return true
    }

    /// 读密文条目。没有（`errSecItemNotFound`）返回 `nil`；读不动记一条日志返回 `nil`——
    /// 与 PC 的 `Blob()`（`File.Exists ? ReadAllBytes : null`，读不了就 `Debug.WriteLine` + null）等价。
    private func blob() -> [UInt8]? {
        var query = CredentialRepository.blobQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                NSLog("[%@] %@", CredentialRepository.tag, "凭据密文读不动：Keychain 返回的不是 Data")
                return nil
            }
            return [UInt8](data)
        case errSecItemNotFound:
            return nil
        default:
            NSLog("[%@] %@", CredentialRepository.tag, "凭据密文读不了：OSStatus \(status)")
            return nil
        }
    }

    /// 密文条目的身份：服务 + 账户。条目名常量定义在 `KeychainCryptoBackend.swift` 里
    /// （密钥条目用的是同一个服务名），免得两处各写一个字符串、哪天只改了一半。
    private static func blobQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainNamespace.service,
            kSecAttrAccount as String: KeychainNamespace.blobAccount,
        ]
    }
}
