import Foundation
import XCTest
@testable import CampusEntry

// 由 `pc/tests/CampusEntry.Tests/CredentialStoreTests.cs` 逐条翻译而来（权威来源是 C#）。
// 用例数：C# 7 个 [Fact]（没有 [Theory]），这里同样是 7 个 func。

/// 凭据落盘格式（与 Android 端 CredentialStoreTest 等价；后端用可控行为的假件）。
final class CredentialStoreTests: XCTestCase {

    /// 与 C# 的 `FakeBackend` **逐字节一致**的假后端：简单可逆变换（异或 0x5A）+ 长度前缀 +
    /// 异或校验和，足够检验「改一个比特就解不开」。
    ///
    /// 这里刻意**不用 Keychain**（也不用真 DPAPI）：真后端的密钥在设备钥匙串里，条目可能残留、
    /// 可能被别的测试或上一次运行影响，单测会因此依赖设备状态。被测的是 `CredentialStore`
    /// 自己的落盘格式与完整性处置，与平台密钥库无关——C# 侧用假件正是这个理由。
    private final class FakeBackend: CryptoBackend {

        func seal(_ plain: [UInt8]) throws -> [UInt8] {
            // C#：output[0] = (byte)plain.Length，中间逐字节 ^ 0x5A，最后一字节是校验和
            var output = [UInt8](repeating: 0, count: plain.count + 2)
            output[0] = UInt8(truncatingIfNeeded: plain.count)
            for index in 0..<plain.count {
                output[index + 1] = plain[index] ^ 0x5A
            }
            output[output.count - 1] = FakeBackend.checksum(plain)
            return output
        }

        func `open`(_ sealedBytes: [UInt8]) throws -> [UInt8] {
            // C#：if (sealedBytes.Length < 2 || sealedBytes[0] != sealedBytes.Length - 2)
            if sealedBytes.count < 2 || Int(sealedBytes[0]) != sealedBytes.count - 2 {
                throw CryptoException("密文形状不对")
            }
            var output = [UInt8](repeating: 0, count: sealedBytes.count - 2)
            for index in 0..<output.count {
                output[index] = sealedBytes[index + 1] ^ 0x5A
            }
            // C#：if (sealedBytes[^1] != Checksum(output))
            if sealedBytes[sealedBytes.count - 1] != FakeBackend.checksum(output) {
                throw CryptoException("完整性校验失败")
            }
            return output
        }

        /// iOS 的 `CryptoBackend` 比 C# 的 `ICryptoBackend` 多一个 `destroy()`（来自 Android 端：
        /// 清账号时要能真的丢掉密钥材料）。这个假件不持有任何密钥材料，所以是空操作——
        /// C# 的 `FakeBackend` 里本来也没有对应的方法，测试里没有一条用到它。
        func destroy() throws {}

        /// C#：`byte sum = 0; foreach (var b in data) sum ^= b; return sum;`
        private static func checksum(_ data: [UInt8]) -> UInt8 {
            var sum: UInt8 = 0
            for byte in data { sum ^= byte }
            return sum
        }
    }

    /// C# 的 `Convert.ToHexString`：大写、无分隔。
    private func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", Int($0)) }.joined()
    }

    /// `SavedCredential` 是带关联值的枚举，也没有声明 `Equatable`，`XCTAssertEqual` 用不了，
    /// 所以用模式匹配判断分支——对应 C# 的 `Assert.IsType<SavedCredential.Unreadable>(…)`。
    private func isUnreadable(_ result: SavedCredential) -> Bool {
        if case .unreadable = result { return true }
        return false
    }

    private func isAbsent(_ result: SavedCredential) -> Bool {
        if case .absent = result { return true }
        return false
    }

    func test落盘的是密文_账号和密码都看不见() throws {
        let store = CredentialStore(FakeBackend())
        let blob = try store.encode("20230001", Array("p@ss\"w\\ord\n"))
        let text = hexString(blob)
        XCTAssertFalse(text.contains("20230001"))
        XCTAssertEqual(UInt8(0x01), blob[0]) // 版本字节
    }

    func test存取一致() throws {
        let store = CredentialStore(FakeBackend())
        let blob = try store.encode("user名", Array("密 码1"))
        guard case .loaded(let loaded) = store.decode(blob) else {
            return XCTFail("应当解出已保存的凭据")
        }
        defer { loaded.clear() }
        XCTAssertEqual("user名", loaded.username)
        XCTAssertEqual("密 码1", String(loaded.password))
    }

    func test密文被改过一个比特_按解不开处理() throws {
        let store = CredentialStore(FakeBackend())
        var blob = try store.encode("user", Array("pass"))
        blob[blob.count - 1] ^= 1
        XCTAssertTrue(isUnreadable(store.decode(blob)), "密文被改过应当按「解不开」处置")
    }

    func test版本不认得_按解不开处理_不静默当成没存过() throws {
        let store = CredentialStore(FakeBackend())
        var blob = try store.encode("user", Array("pass"))
        blob[0] = 99
        XCTAssertTrue(isUnreadable(store.decode(blob)), "版本不认得应当按「解不开」处置")
    }

    func test没存过就是没存过() {
        let store = CredentialStore(FakeBackend())
        XCTAssertTrue(isAbsent(store.decode(nil)))
        XCTAssertTrue(isAbsent(store.decode([])))
        XCTAssertTrue(isAbsent(store.decode([1])))
    }

    func test空账号或空密码宁可炸也不存() {
        let store = CredentialStore(FakeBackend())
        XCTAssertThrowsError(try store.encode(" ", Array("pass"))) { error in
            XCTAssertTrue(
                error is IllegalArgumentException,
                "空账号应当是 IllegalArgumentException，实为 \(error)")
        }
        XCTAssertThrowsError(try store.encode("user", [])) { error in
            XCTAssertTrue(
                error is IllegalArgumentException,
                "空密码应当是 IllegalArgumentException，实为 \(error)")
        }
    }

    func test用户名或密码里的特殊字符不会把两段串起来() throws {
        // 长度前缀而不是分隔符：任何字符都合法。
        // C# 里用的是 NUL（`"a\u0000b"`），Swift 里同样是 NUL（`"a\u{0}b"`，UTF-8 编码也是 1 字节）。
        let store = CredentialStore(FakeBackend())
        let blob = try store.encode("a\u{0}b", Array("c\u{0}d"))
        guard case .loaded(let loaded) = store.decode(blob) else {
            return XCTFail("应当解出已保存的凭据")
        }
        defer { loaded.clear() }
        XCTAssertEqual("a\u{0}b", loaded.username)
        XCTAssertEqual("c\u{0}d", String(loaded.password))
    }
}
