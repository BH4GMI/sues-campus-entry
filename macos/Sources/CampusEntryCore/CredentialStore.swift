import Foundation

/// Errors thrown by `CryptoBackend` and `CredentialStore`.
public enum CryptoError: Error, LocalizedError, Sendable {
    case emptyUsername
    case emptyPassword
    case usernameTooLong
    case keychainFailure(status: OSStatus, message: String)
    case invalidKeyLength(Int)
    case encryptionFailed(String)
    case decryptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyUsername:
            return "账号不能为空"
        case .emptyPassword:
            return "密码不能为空"
        case .usernameTooLong:
            return "账号长度超出限制"
        case let .keychainFailure(status, message):
            return "Keychain 访问失败 (\(status)): \(message)"
        case let .invalidKeyLength(length):
            return "Keychain 密钥长度无效: \(length)"
        case let .encryptionFailed(detail):
            return "加密失败: \(detail)"
        case let .decryptionFailed(detail):
            return "解密失败: \(detail)"
        }
    }
}

/// Platform cryptographic sealing/unsealing backend.
public protocol CryptoBackend {
    /// Encrypts plaintext into an authenticated ciphertext blob (nonce/IV + ciphertext + tag).
    func seal(_ plain: Data) throws -> Data

    /// Decrypts and authenticates a sealed blob, throwing `CryptoError` if tampered or inaccessible.
    func open(_ sealed: Data) throws -> Data
}

/// Username + clearable UTF-8 password bytes.
public final class Credential {
    public let username: String
    public private(set) var passwordBytes: [UInt8]
    private var cleared = false

    public init(username: String, passwordBytes: [UInt8]) {
        self.username = username
        self.passwordBytes = passwordBytes
    }

    public convenience init(username: String, password: String) {
        self.init(username: username, passwordBytes: Array(password.utf8))
    }

    /// Returns the password decoded as UTF-8, or empty string once cleared.
    public var passwordString: String {
        guard !cleared else { return "" }
        return String(decoding: passwordBytes, as: UTF8.self)
    }

    /// Zeroes out the in-memory password bytes.
    public func clear() {
        guard !cleared else { return }
        cleared = true
        for index in passwordBytes.indices {
            passwordBytes[index] = 0
        }
    }

    deinit {
        clear()
    }
}

/// Result status of reading persisted credentials without carrying secret material.
public enum LoadStatus: Equatable, Sendable {
    case loaded
    case absent
    case unreadable
}

/// Decoded credential load outcome matching `CredentialStore.cs`.
public enum SavedCredential {
    case absent
    case loaded(Credential)
    case unreadable

    public var status: LoadStatus {
        switch self {
        case .absent: return .absent
        case .loaded: return .loaded
        case .unreadable: return .unreadable
        }
    }
}

/// Binary credential codec (`[0x01][sealed]`, plaintext `[u16be userLen][user UTF-8][pass UTF-8]`).
public final class CredentialStore {
    private static let version: UInt8 = 1
    private static let headerSize = 2

    private let backend: CryptoBackend

    public init(backend: CryptoBackend) {
        self.backend = backend
    }

    /// Encodes and seals `username` + `passwordBytes`. Throws on empty inputs or backend failure.
    public func encode(username: String, passwordBytes: [UInt8]) throws -> Data {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CryptoError.emptyUsername
        }
        guard !passwordBytes.isEmpty else {
            throw CryptoError.emptyPassword
        }

        var plain = try frame(username: username, passwordBytes: passwordBytes)
        defer { plain.resetBytes(in: 0..<plain.count) }

        let sealedBytes = try backend.seal(plain)
        var out = Data(capacity: 1 + sealedBytes.count)
        out.append(Self.version)
        out.append(sealedBytes)
        return out
    }

    /// Convenience overload accepting a `String` password.
    public func encode(username: String, password: String) throws -> Data {
        var bytes = Array(password.utf8)
        defer {
            for i in bytes.indices { bytes[i] = 0 }
        }
        return try encode(username: username, passwordBytes: bytes)
    }

    /// Decodes a persisted blob. Never throws; invalid/corrupted/unopenable inputs yield `.absent` or `.unreadable`.
    public func decode(_ blob: Data?) -> SavedCredential {
        guard let blob, blob.count > 1 else { return .absent }
        guard blob[blob.startIndex] == Self.version else { return .unreadable }

        let sealedBytes = Data(blob.dropFirst())
        var plain: Data
        do {
            plain = try backend.open(sealedBytes)
        } catch {
            return .unreadable
        }
        defer { plain.resetBytes(in: 0..<plain.count) }

        guard let credential = unframe(plain) else {
            return .unreadable
        }
        return .loaded(credential)
    }

    private func frame(username: String, passwordBytes: [UInt8]) throws -> Data {
        let userBytes = Array(username.utf8)
        guard userBytes.count <= Int(UInt16.max) else {
            throw CryptoError.usernameTooLong
        }
        var output = Data(capacity: Self.headerSize + userBytes.count + passwordBytes.count)
        output.append(UInt8((userBytes.count >> 8) & 0xFF))
        output.append(UInt8(userBytes.count & 0xFF))
        output.append(contentsOf: userBytes)
        output.append(contentsOf: passwordBytes)
        return output
    }

    private func unframe(_ plain: Data) -> Credential? {
        guard plain.count > Self.headerSize else { return nil }
        let start = plain.startIndex
        let length = (Int(plain[start]) << 8) | Int(plain[plain.index(after: start)])
        guard length > 0, Self.headerSize + length < plain.count else { return nil }

        let userStart = plain.index(start, offsetBy: Self.headerSize)
        let passStart = plain.index(userStart, offsetBy: length)
        let userSlice = plain[userStart..<passStart]
        let passSlice = plain[passStart...]

        guard let username = String(bytes: userSlice, encoding: .utf8),
              String(bytes: passSlice, encoding: .utf8) != nil
        else {
            return nil
        }
        return Credential(username: username, passwordBytes: Array(passSlice))
    }
}

/// File-backed credential storage in `~/Library/Application Support/CampusEntry/credentials.bin`.
public final class CredentialRepository {
    public static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("CampusEntry", isDirectory: true)
    }

    public let fileURL: URL
    private let store: CredentialStore

    public init(directory: URL = CredentialRepository.defaultDirectory, store: CredentialStore) {
        self.fileURL = directory.appendingPathComponent("credentials.bin", isDirectory: false)
        self.store = store
    }

    /// Atomically writes sealed credentials via `credentials.bin.tmp` + `rename`.
    @discardableResult
    public func save(username: String, passwordBytes: [UInt8]) -> Bool {
        var blob: Data
        do {
            blob = try store.encode(username: username, passwordBytes: passwordBytes)
        } catch {
            return false
        }
        defer { blob.resetBytes(in: 0..<blob.count) }

        do {
            let fm = FileManager.default
            let dir = fileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let tmpURL = dir.appendingPathComponent("credentials.bin.tmp", isDirectory: false)
            if fm.fileExists(atPath: tmpURL.path) {
                try? fm.removeItem(at: tmpURL)
            }
            try blob.write(to: tmpURL)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)

            if Darwin.rename(tmpURL.path, fileURL.path) != 0 {
                let err = POSIXErrorCode(rawValue: errno) ?? .EIO
                try? fm.removeItem(at: tmpURL)
                throw POSIXError(err)
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func save(username: String, password: String) -> Bool {
        var bytes = Array(password.utf8)
        defer {
            for i in bytes.indices { bytes[i] = 0 }
        }
        return save(username: username, passwordBytes: bytes)
    }

    /// Loads saved credentials with explicit `SavedCredential` status (`.loaded`, `.absent`, `.unreadable`).
    public func loadSaved() -> SavedCredential {
        store.decode(readBlob())
    }

    /// Loads saved credentials, returning `nil` when absent or unreadable. Caller must `clear()` when done.
    public func load() -> Credential? {
        switch loadSaved() {
        case let .loaded(credential):
            return credential
        case .absent, .unreadable:
            return nil
        }
    }

    /// Returns only the saved username (for masked display) and immediately zeroes the password.
    public func savedUsername() -> String? {
        guard let credential = load() else { return nil }
        defer { credential.clear() }
        return credential.username
    }

    /// Deletes the persisted credential file if present.
    public func clear() {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
        }
    }

    private func readBlob() -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
    }
}
