import CryptoKit
import Foundation
import Security

/// macOS Keychain + AES-256-GCM encryption backend for `CredentialStore`.
public final class KeychainCryptoBackend: CryptoBackend {
    public static let defaultService = "cn.edu.sues.campus-entry"
    public static let defaultAccount = "cred-v1-key"

    private let service: String
    private let account: String
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    public init(service: String = defaultService, account: String = defaultAccount) {
        self.service = service
        self.account = account
    }

    public func seal(_ plain: Data) throws -> Data {
        let key = try loadOrCreateKey()
        do {
            let sealedBox = try AES.GCM.seal(plain, using: key)
            guard let combined = sealedBox.combined else {
                throw CryptoError.encryptionFailed("AES-GCM combined payload unavailable")
            }
            return combined
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.encryptionFailed(error.localizedDescription)
        }
    }

    public func open(_ sealed: Data) throws -> Data {
        let key = try loadOrCreateKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(sealedBox, using: key)
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.decryptionFailed(error.localizedDescription)
        }
    }

    /// Deletes the stored Keychain key item (mainly for diagnostics or full reset).
    public func deleteStoredKey() throws {
        lock.lock()
        defer { lock.unlock() }
        cachedKey = nil

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw keychainError(status)
        }
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }

        if let cachedKey {
            return cachedKey
        }

        if let existing = try copyExistingKey() {
            cachedKey = existing
            return existing
        }

        let fresh = SymmetricKey(size: .bits256)
        var raw = fresh.withUnsafeBytes { Data($0) }
        defer { raw.resetBytes(in: 0..<raw.count) }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: raw,
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            cachedKey = fresh
            return fresh
        }
        if addStatus == errSecDuplicateItem, let existing = try copyExistingKey() {
            cachedKey = existing
            return existing
        }
        throw keychainError(addStatus)
    }

    private func copyExistingKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
        guard var data = item as? Data else {
            throw CryptoError.invalidKeyLength(0)
        }
        defer { data.resetBytes(in: 0..<data.count) }
        guard data.count == 32 else {
            throw CryptoError.invalidKeyLength(data.count)
        }
        return SymmetricKey(data: data)
    }

    private func keychainError(_ status: OSStatus) -> CryptoError {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return CryptoError.keychainFailure(status: status, message: message)
    }
}
