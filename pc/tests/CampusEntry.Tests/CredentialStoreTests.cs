using CampusEntry.Core;
using Xunit;

namespace CampusEntry.Tests;

/// <summary>凭据落盘格式（与 Android 端 CredentialStoreTest 等价；后端用可控行为的假件）。</summary>
public class CredentialStoreTests
{
    private sealed class FakeBackend : ICryptoBackend
    {
        // 简单可逆变换 + 长度前缀 + 校验和，足够检验「改一个比特就解不开」
        public byte[] Seal(byte[] plain)
        {
            var output = new byte[plain.Length + 2];
            output[0] = (byte)plain.Length;
            for (var i = 0; i < plain.Length; i++) output[i + 1] = (byte)(plain[i] ^ 0x5A);
            output[^1] = Checksum(plain);
            return output;
        }

        public byte[] Open(byte[] sealedBytes)
        {
            if (sealedBytes.Length < 2 || sealedBytes[0] != sealedBytes.Length - 2)
                throw new CryptoException("密文形状不对");
            var output = new byte[sealedBytes.Length - 2];
            for (var i = 0; i < output.Length; i++) output[i] = (byte)(sealedBytes[i + 1] ^ 0x5A);
            if (sealedBytes[^1] != Checksum(output)) throw new CryptoException("完整性校验失败");
            return output;
        }

        private static byte Checksum(byte[] data)
        {
            byte sum = 0;
            foreach (var b in data) sum ^= b;
            return sum;
        }
    }

    [Fact]
    public void 落盘的是密文_账号和密码都看不见()
    {
        var store = new CredentialStore(new FakeBackend());
        var blob = store.Encode("20230001", "p@ss\"w\\ord\n".ToCharArray());
        var text = Convert.ToHexString(blob);
        Assert.DoesNotContain("20230001", text);
        Assert.Equal(0x01, blob[0]); // 版本字节
    }

    [Fact]
    public void 存取一致()
    {
        var store = new CredentialStore(new FakeBackend());
        var blob = store.Encode("user名", "密 码1".ToCharArray());
        var loaded = Assert.IsType<SavedCredential.Loaded>(store.Decode(blob)).Credential;
        try
        {
            Assert.Equal("user名", loaded.Username);
            Assert.Equal("密 码1", new string(loaded.Password));
        }
        finally
        {
            loaded.Clear();
        }
    }

    [Fact]
    public void 密文被改过一个比特_按解不开处理()
    {
        var store = new CredentialStore(new FakeBackend());
        var blob = store.Encode("user", "pass".ToCharArray());
        blob[^1] ^= 1;
        Assert.IsType<SavedCredential.Unreadable>(store.Decode(blob));
    }

    [Fact]
    public void 版本不认得_按解不开处理_不静默当成没存过()
    {
        var store = new CredentialStore(new FakeBackend());
        var blob = store.Encode("user", "pass".ToCharArray());
        blob[0] = 99;
        Assert.IsType<SavedCredential.Unreadable>(store.Decode(blob));
    }

    [Fact]
    public void 没存过就是没存过()
    {
        var store = new CredentialStore(new FakeBackend());
        Assert.IsType<SavedCredential.Absent>(store.Decode(null));
        Assert.IsType<SavedCredential.Absent>(store.Decode(Array.Empty<byte>()));
        Assert.IsType<SavedCredential.Absent>(store.Decode(new byte[] { 1 }));
    }

    [Fact]
    public void 空账号或空密码宁可炸也不存()
    {
        var store = new CredentialStore(new FakeBackend());
        Assert.Throws<ArgumentException>(() => store.Encode(" ", "pass".ToCharArray()));
        Assert.Throws<ArgumentException>(() => store.Encode("user", Array.Empty<char>()));
    }

    [Fact]
    public void 用户名或密码里的特殊字符不会把两段串起来()
    {
        // 长度前缀而不是分隔符：任何字符都合法
        var store = new CredentialStore(new FakeBackend());
        var blob = store.Encode("a\u0000b", "c\u0000d".ToCharArray());
        var loaded = Assert.IsType<SavedCredential.Loaded>(store.Decode(blob)).Credential;
        using (loaded)
        {
            Assert.Equal("a\u0000b", loaded.Username);
            Assert.Equal("c\u0000d", new string(loaded.Password));
        }
    }
}


