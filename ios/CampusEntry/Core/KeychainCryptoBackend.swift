//
//  KeychainCryptoBackend.swift
//  CampusEntry
//
//  对应 PC 的 `pc/src/CampusEntry/Core/DpapiCryptoBackend.cs` 与 Android 的
//  `android/.../AndroidKeyStoreBackend.kt`：三端都是「密钥交给平台保管、上层的 `CredentialStore`
//  只当后端产出的字节是一段不透明数据」。
//
//  文件头「落盘格式」的硬约束在 `CredentialStore.swift` 里说清楚了：**版本字节 1 + 长度前缀明文**
//  是三端逐字节相同的部分。这个文件负责的是 `[1..]` 那一段——它是**各端平台机制自己的字节**：
//
//  | 端 | `[1..]` 的摆法 |
//  | -- | --------------- |
//  | PC | DPAPI 的自有格式（自带完整性，不透明） |
//  | Android | `[IV 长度][IV][密文+标签]` |
//  | iOS（这一份） | `nonce(12) || 密文 || 标签(16)` |
//
//  所以「三端逐字节同一套」指的是版本字节与明文分段，**不包括段落 `[1..]`**（见 `CredentialStore.swift`
//  文件头）。上层只把它当不透明字节，任何端都不得去解读别端的这一段。
//
//  ══ iOS 的平台机制：Keychain + CryptoKit ═════════════════════════════════
//
//  - **密钥**：Keychain 里一条 `kSecClassGenericPassword` 的 **256 位对称密钥**，材料由
//    `SecRandomCopyBytes` 现生成（不是从任何口令派生，因此没有 KDF、也没有可爆破的口令空间）。
//    可访问性固定 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，**不设任何可同步属性**
//    （不写 `kSecAttrSynchronizable`，Keychain 默认即不同步）：密钥既不进 iCloud Keychain，
//    也不随备份迁到新设备。
//    `AfterFirstUnlock` 是**全自动登录**的前提（对齐 Android 的 `setUserAuthenticationRequired(false)`）：
//    要求每次现场验指纹/验设备密码才能用密钥，就没法自动了。将来若要做「打开应用验一次生物识别」，
//    改的是这里的可访问性 + `LocalAuthentication`，而且必须是用户显式打开的开关，不是默认行为。
//  - **加解密**：**CryptoKit 的 `AES.GCM`**，不用 AAD（与另外两端的 GCM 语义一致）；
//    `AES.GCM.SealedBox.combined` 的字节序恰好就是 `nonce || 密文 || 标签`，与要求写定的摆法一致。
//
//  ══ 与 Android 的一个真实差异（诚实记录，别当成「等价实现」）══════════════
//
//  AndroidKeyStore 里的密钥**不可导出**：密钥材料在系统/TEE 里，应用进程只能请它代算。
//  iOS 这里做不到同样的事——CryptoKit 需要密钥材料本身，所以密钥必须从 Keychain **读出来**进内存。
//  于是「能在本应用进程里执行代码的攻击者」可以连密钥一起拿到，而 Android 上他拿不到密钥本身。
//  这不是「再努力加密」能解决的问题（`docs/APP-UX.md` §6.5 已经对用户讲清楚了：加密保护的是静态
//  数据，不保护运行中的进程），此处**不宣称**与 Android 等价。
//
//  为什么不用别的方案：
//  - 不用 Secure Enclave / `kSecAttrTokenIDSecureEnclave`：它管的是 P-256 非对称私钥，不提供
//    通用 AES 对称密钥（我们需要的正是「用户不在场也能加解密」的对称密钥）。
//  - 不引第三方（`RNCryptor` / `SwiftKeychainWrapper` / `CryptoSwift` 之类）：系统给了
//    Keychain + CryptoKit，够用，零新增依赖也是 `docs/APP-UX.md` §6.2 对 Android 端写下的同一条理由。
//

import Foundation
import Security
import CryptoKit

/// Keychain 里的命名空间常量。密钥条目与密文条目用**同一个服务名**、不同的账户名区分，
/// 常量只在这里定义一份（`CredentialRepository` 也引用它，免得两处各写一个字符串、哪天只改了一半）。
enum KeychainNamespace {

    /// 本应用在 Keychain 里的服务名。
    ///
    /// 这是**持久化标识，不是显示名**：产品显示名是「教务直达」，但 Keychain 条目的服务名
    /// 一改，已保存的凭据就读不到了（表现是"突然要我重新登录"）。因此这里用 ASCII 技术标识，
    /// 与密钥别名 `campus-entry-cred-v1`、PC 的数据目录 `CampusEntry` 是同一套命名。
    ///
    /// 之所以现在就能对齐（PC 的数据目录反而不动）：iOS 端从未编译发布过，机器上不可能有旧条目；
    /// PC 端已经有用户在跑，数据目录名一旦改了就会把他们的账号弄丢。见 `EntrySettings.cs` 的说明。
    static let service = "campus-entry"

    /// 凭据密文的条目名。语义对应 PC 的 `credentials.bin`、Android 的 `credential_blob`：
    /// 名字本身只是标识，不代表真的存在这个文件。
    static let blobAccount = "credentials.bin"
}

/// iOS 端的加解密后端：Keychain 上的 AES-256 密钥 + CryptoKit 的 AES-GCM。
public final class KeychainCryptoBackend: CryptoBackend {

    /// 默认密钥条目名，对齐 Android 端 `AndroidKeyStoreBackend.DEFAULT_ALIAS`。
    public static let defaultAlias = "campus-entry-cred-v1"

    private static let tag = "教务直达"

    private static let keyBytes = 256 / 8
    private static let nonceBytes = 12
    private static let tagBytes = 16

    /// 密钥在 Keychain 里的条目名（PC 的 `DpapiCryptoBackend` 没有这个概念，因为 DPAPI 的密钥由系统管）。
    private let alias: String

    public init(_ alias: String = KeychainCryptoBackend.defaultAlias) {
        self.alias = alias
    }

    /// 加密。产出的字节固定是 `nonce(12) || 密文 || 标签(16)`。
    public func seal(_ plain: [UInt8]) throws -> [UInt8] {
        // CryptoKit 要的是 `DataProtocol`/`ContiguousBytes`，所以这里必然多一份 `Data` 副本；
        // 它和下层的 `[UInt8]` 一样只擦得掉自己这一份（见 `CredentialStore.swift` 文件头的诚实边界），
        // 但至少不留在这里被后续的分配复用。
        var payload = Data(plain)
        defer { payload.resetBytes(in: 0..<payload.count) }
        do {
            let symmetricKey = try key()
            let box = try AES.GCM.seal(payload, using: symmetricKey)
            // `combined` 的字节序是 nonce || 密文 || 标签（标准 12 字节 nonce）。逐项校验一次，
            // 免得哪天 CryptoKit 的默认 nonce 长度变了，落盘格式悄悄跟着变。
            guard let combined = box.combined,
                  combined.count == Self.nonceBytes + box.ciphertext.count + Self.tagBytes else {
                throw CryptoException("加密结果不是 nonce(12)||密文||标签(16) 的形态")
            }
            return [UInt8](combined)
        } catch let error as CryptoException {
            throw error
        } catch {
            // 平台异常统一成 CryptoException：上层只需要认一种失败（同 DPAPI / AndroidKeyStore 的实现）。
            throw CryptoException("加密失败：\(error)")
        }
    }

    /// 解密并校验完整性。密文被改过、密钥换过（例如用户清过账号）都在这里抛 `CryptoException`，
    /// **绝不返回猜测出来的明文**。
    public func `open`(_ sealedBytes: [UInt8]) throws -> [UInt8] {
        do {
            let symmetricKey = try key()
            let box = try AES.GCM.SealedBox(combined: Data(sealedBytes))
            var plain = try AES.GCM.open(box, using: symmetricKey)
            defer { plain.resetBytes(in: 0..<plain.count) }
            return [UInt8](plain)
        } catch let error as CryptoException {
            throw error
        } catch {
            // 标签校验失败（密文被改过 / 密钥已经不是当初那一把）、`combined` 形态不合法，都归到这里。
            throw CryptoException("解密失败：\(error)")
        }
    }

    /// 丢弃密钥材料。之后**旧的密文再也解不开**——这正是「清除账号」要的效果：删掉密钥比删密文更彻底。
    ///
    /// 与 Android 的 `destroy()` 一样把失败如实抛给调用方（删不掉时它必须知道）；
    /// 谁去记日志由上层决定——`CredentialRepository.clear()` 采用 PC 的做法：记日志、继续往下走。
    public func destroy() throws {
        let status = SecItemDelete(KeychainCryptoBackend.query(alias) as CFDictionary)
        // 条目本来就不在＝已经清干净了，不算失败（幂等）。
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptoException("删除密钥失败：OSStatus \(status)")
        }
    }

    // ---------------------------------------------------------------- 密钥

    /// 取密钥；没有就现生成一把。
    ///
    /// 「没有」包括用户刚清过账号的情况——那时会生成一把**新**密钥，于是旧密文再也解不开，
    /// 这正是我们想要的语义，不需要额外分支（同 `AndroidKeyStoreBackend.key()`）。
    private func key() throws -> SymmetricKey {
        if var raw = try loadKey() {
            defer { raw.resetBytes(in: 0..<raw.count) }
            if raw.count == Self.keyBytes {
                return SymmetricKey(data: raw)
            }
            // 长度不是 32 字节，说明这一条不是我们写的密钥。**不能**默默把它当 AES-128 用（那是降级）：
            // 按「没有密钥」处理，现生成一把并覆盖它。旧密文因此解不开，而「解不开」在这套设计里
            // 本来就等价于「没保存过」（用户重登一次即可），不会带来新的失败模式。
            NSLog("[%@] %@", KeychainCryptoBackend.tag, "Keychain 里的密钥长度是 \(raw.count) 字节，不是 32；按无密钥处理并重新生成")
        }
        return try createKey()
    }

    /// 现生成一把 AES-256 密钥并存进 Keychain。
    private func createKey() throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: Self.keyBytes)
        defer { SecretWipe.bytes(&bytes) }

        let status = bytes.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, raw.count, base)
        }
        guard status == errSecSuccess else {
            throw CryptoException("生成随机密钥失败：OSStatus \(status)")
        }

        var raw = Data(bytes)
        defer { raw.resetBytes(in: 0..<raw.count) }
        let symmetricKey = SymmetricKey(data: raw)
        try storeKey(raw)
        return symmetricKey
    }

    /// 读密钥条目。条目不存在返回 `nil`（由 `key()` 现生成一把）；读不动就抛——读不动与「没存过」
    /// 是两回事，不能混。
    private func loadKey() throws -> Data? {
        var query = KeychainCryptoBackend.query(alias)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw CryptoException("Keychain 里的密钥不是 Data")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CryptoException("读取密钥失败：OSStatus \(status)")
        }
    }

    /// 写密钥条目：先 `SecItemUpdate`，只在条目不存在时 `SecItemAdd`（两步都是原子操作）。
    private func storeKey(_ raw: Data) throws {
        let query = KeychainCryptoBackend.query(alias)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: raw] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CryptoException("写入密钥失败：OSStatus \(updateStatus)")
        }

        var addQuery = query
        addQuery[kSecValueData as String] = raw
        // 只在这里设可访问性：`AfterFirstUnlock` 才能全自动登录；`ThisDeviceOnly` 保证不进
        // iCloud Keychain、也不随备份迁到新设备。刻意不设 `kSecAttrSynchronizable`（默认即不同步）。
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CryptoException("写入密钥失败：OSStatus \(addStatus)")
        }
    }

    /// 密钥条目的身份：服务 + 账户。字段按 Keychain 的要求写全（`kSecClass` / `kSecAttrService` /
    /// `kSecAttrAccount`），查询时再按需加 `kSecReturnData` / `kSecMatchLimit`。
    private static func query(_ alias: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainNamespace.service,
            kSecAttrAccount as String: alias,
        ]
    }
}
