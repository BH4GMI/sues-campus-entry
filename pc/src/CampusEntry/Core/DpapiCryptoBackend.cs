using System.Security.Cryptography;
using System.Text;

namespace CampusEntry.Core;

/// <summary>
/// Windows 端的加解密后端：DPAPI（<c>ProtectedData</c>，CurrentUser 范围）。
///
/// 这是 Windows 上「凭据只属于当前用户」的一等公民机制，地位对齐 Android 端的系统密钥库：
/// 密钥由操作系统按用户账户派生并保管，应用读不到、导不出；密文离开这个用户账户（或被改动
/// 一个比特）就解不开。额外的 <see cref="Entropy"/> 不是密钥，只是把密文与本应用绑定，
/// 防止同一用户下其它 DPAPI 使用者拿明文。
/// </summary>
public sealed class DpapiCryptoBackend : ICryptoBackend
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("campus-entry-cred-v1");

    public byte[] Seal(byte[] plain) =>
            ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);

    public byte[] Open(byte[] sealedBytes)
    {
        try
        {
            return ProtectedData.Unprotect(sealedBytes, Entropy, DataProtectionScope.CurrentUser);
        }
        catch (CryptographicException e)
        {
            // 换机器/换用户/密文被改，DPAPI 一律抛 CryptographicException
            throw new CryptoException($"DPAPI 解不开：{e.Message}");
        }
    }
}
