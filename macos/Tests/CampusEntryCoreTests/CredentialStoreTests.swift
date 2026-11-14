import Foundation
import Testing
@testable import CampusEntryCore

/// Equivalent credential storage format tests from `CredentialStoreTests.cs`.
@Suite("CredentialStore")
struct CredentialStoreTests {
    private final class FakeBackend: CryptoBackend {
        func seal(_ plain: Data) throws -> Data {
            guard plain.count <= Int(UInt8.max) else {
                throw CryptoError.encryptionFailed("plaintext too long for FakeBackend")
            }
            var output = Data(capacity: plain.count + 2)
            output.append(UInt8(plain.count))
            for b in plain {
                output.append(b ^ 0x5A)
            }
            output.append(checksum(plain))
            return output
        }

        func open(_ sealed: Data) throws -> Data {
            guard sealed.count >= 2 else {
                throw CryptoError.decryptionFailed("密文形状不对")
            }
            let expectedLength = Int(sealed[sealed.startIndex])
            guard expectedLength == sealed.count - 2 else {
                throw CryptoError.decryptionFailed("密文形状不对")
            }
            var output = Data(capacity: expectedLength)
            let payloadStart = sealed.index(after: sealed.startIndex)
            let payloadEnd = sealed.index(before: sealed.endIndex)
            for b in sealed[payloadStart..<payloadEnd] {
                output.append(b ^ 0x5A)
            }
            guard sealed[sealed.index(before: sealed.endIndex)] == checksum(output) else {
                throw CryptoError.decryptionFailed("完整性校验失败")
            }
            return output
        }

        private func checksum(_ data: Data) -> UInt8 {
            var sum: UInt8 = 0
            for b in data {
                sum ^= b
            }
            return sum
        }
    }

    @Test("落盘的是密文_账号和密码都看不见")
    func persistedBlobIsCiphertext() throws {
        let store = CredentialStore(backend: FakeBackend())
        let blob = try store.encode(username: "20230001", password: "p@ss\"w\\ord\n")
        let hex = blob.map { String(format: "%02X", $0) }.joined()
        let userHex = Data("20230001".utf8).map { String(format: "%02X", $0) }.joined()
        #expect(!hex.contains("20230001"))
        #expect(!hex.contains(userHex))
        #expect(blob.first == 0x01)
    }

    @Test("存取一致")
    func roundTripUtf8AndSpaces() throws {
        let store = CredentialStore(backend: FakeBackend())
        let blob = try store.encode(username: "user名", password: "密 码1")
        let outcome = store.decode(blob)
        guard case let .loaded(loaded) = outcome else {
            Issue.record("Expected .loaded, got \(outcome.status)")
            return
        }
        defer { loaded.clear() }
        #expect(loaded.username == "user名")
        #expect(loaded.passwordString == "密 码1")
    }

    @Test("密文被改过一个比特_按解不开处理")
    func singleBitTamperIsUnreadable() throws {
        let store = CredentialStore(backend: FakeBackend())
        var blob = try store.encode(username: "user", password: "pass")
        blob[blob.count - 1] ^= 1
        #expect(store.decode(blob).status == .unreadable)
    }

    @Test("版本不认得_按解不开处理_不静默当成没存过")
    func unknownVersionIsUnreadable() throws {
        let store = CredentialStore(backend: FakeBackend())
        var blob = try store.encode(username: "user", password: "pass")
        blob[0] = 99
        #expect(store.decode(blob).status == .unreadable)
    }

    @Test("没存过就是没存过")
    func nilEmptyAndOneByteAreAbsent() {
        let store = CredentialStore(backend: FakeBackend())
        #expect(store.decode(nil).status == .absent)
        #expect(store.decode(Data()).status == .absent)
        #expect(store.decode(Data([1])).status == .absent)
    }

    @Test("空账号或空密码宁可炸也不存")
    func blankUsernameOrEmptyPasswordThrows() {
        let store = CredentialStore(backend: FakeBackend())
        #expect(throws: CryptoError.self) {
            _ = try store.encode(username: " ", password: "pass")
        }
        #expect(throws: CryptoError.self) {
            _ = try store.encode(username: "user", passwordBytes: [])
        }
        #expect(throws: CryptoError.self) {
            _ = try store.encode(username: "user", password: "")
        }
    }

    @Test("用户名或密码里的特殊字符不会把两段串起来")
    func embeddedNulRoundTripsCleanly() throws {
        let store = CredentialStore(backend: FakeBackend())
        let blob = try store.encode(username: "a\u{0000}b", password: "c\u{0000}d")
        let outcome = store.decode(blob)
        guard case let .loaded(loaded) = outcome else {
            Issue.record("Expected .loaded, got \(outcome.status)")
            return
        }
        defer { loaded.clear() }
        #expect(loaded.username == "a\u{0000}b")
        #expect(loaded.passwordString == "c\u{0000}d")
    }
}
