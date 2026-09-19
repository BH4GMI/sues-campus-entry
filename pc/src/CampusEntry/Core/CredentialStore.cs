using System.Text;

namespace CampusEntry.Core;

/// <summary>一组账号密码。密码用 char[] 承载，用完可以真的擦掉。</summary>
public sealed class Credential : IDisposable
{
    public string Username { get; }
    public char[] Password { get; }

    public Credential(string username, char[] password)
    {
        Username = username;
        Password = password;
    }

    /// <summary>擦掉密码。调用之后这个对象不可再用。</summary>
    public void Clear() => Array.Clear(Password, 0, Password.Length);

    public void Dispose() => Clear();
}

/// <summary>读取已保存凭据的结果。</summary>
public abstract record SavedCredential
{
    public sealed record Absent : SavedCredential;

    public sealed record Loaded(Credential Credential) : SavedCredential;

    /// <summary>密文在，但解不开或格式不认（被改过、换过机器/用户、版本比本应用新）。</summary>
    public sealed record Unreadable : SavedCredential;
}

public sealed class CryptoException : Exception
{
    public CryptoException(string message) : base(message) { }
}

/// <summary>加解密后端。Windows 端实现是 DPAPI（见 <see cref="DpapiCryptoBackend"/>）。</summary>
public interface ICryptoBackend
{
    /// <summary>加密。产出自带 IV 与完整性标签（后端自选格式）。</summary>
    byte[] Seal(byte[] plain);

    /// <summary>解密；密文被改过或换过保护范围时抛 <see cref="CryptoException"/>。</summary>
    byte[] Open(byte[] sealedBytes);
}

/// <summary>
/// 凭据的落盘编解码与完整性处置。<b>纯逻辑</b>，与 Android 端 <c>CredentialStore.kt</c> 逐字节同一套格式：
///
/// <code>
/// [0]      格式版本，目前是 1
/// [1..]    加解密后端产出的字节（自带 IV 与完整性标签）
/// </code>
///
/// 明文形态（交后端加密之前）：长度前缀的两段——
/// <code>[用户名长度 u16 大端][用户名 UTF-8][密码 UTF-8]</code>
/// 用长度前缀而不是分隔符：用户名或密码里出现任何字符都不会把两段串起来。
/// </summary>
public sealed class CredentialStore
{
    private const byte Version = 1;
    private const int Header = 2;

    private readonly ICryptoBackend _backend;

    public CredentialStore(ICryptoBackend backend) => _backend = backend;

    /// <summary>
    /// 编码。账号为空或密码为空会抛异常：宁可在这里炸，也不要存下一组永远登不进去的凭据。
    /// </summary>
    public byte[] Encode(string username, char[] password)
    {
        if (string.IsNullOrWhiteSpace(username)) throw new ArgumentException("账号不能为空");
        if (password.Length == 0) throw new ArgumentException("密码不能为空");
        var plain = Frame(username, password);
        try
        {
            var sealedBytes = _backend.Seal(plain);
            var outBytes = new byte[1 + sealedBytes.Length];
            outBytes[0] = Version;
            Buffer.BlockCopy(sealedBytes, 0, outBytes, 1, sealedBytes.Length);
            return outBytes;
        }
        finally
        {
            Array.Clear(plain, 0, plain.Length);
        }
    }

    /// <summary>解码。任何不正常的情况都返回 Absent 或 Unreadable，不抛。</summary>
    public SavedCredential Decode(byte[]? blob)
    {
        if (blob == null || blob.Length <= 1) return new SavedCredential.Absent();
        if (blob[0] != Version) return new SavedCredential.Unreadable();

        byte[] plain;
        try
        {
            var sealedBytes = new byte[blob.Length - 1];
            Buffer.BlockCopy(blob, 1, sealedBytes, 0, sealedBytes.Length);
            plain = _backend.Open(sealedBytes);
        }
        catch (Exception e)
        {
            // 契约是「任何不正常的情况都返回 Absent 或 Unreadable，不抛」（见类注释）。
            // 只捕 CryptoException 不够：DPAPI 在换用户、配置文件漫游、被策略禁用等情况下会抛
            // 别的异常，它们会一路穿过 CredentialRepository.Load() 冒到启动路径上——把
            // 「读不出凭据」变成「应用起不来」。（catch (Exception) 不会吞 OOM 之外的 Error。）
            System.Diagnostics.Debug.WriteLine($"[CampusEntry] 凭据解不开（{e.GetType().Name}）：{e.Message}");
            return new SavedCredential.Unreadable();
        }
        try
        {
            var credential = Unframe(plain);
            return credential == null
                    ? new SavedCredential.Unreadable()
                    : new SavedCredential.Loaded(credential);
        }
        finally
        {
            Array.Clear(plain, 0, plain.Length);
        }
    }

    private static byte[] Frame(string username, char[] password)
    {
        var user = Encoding.UTF8.GetBytes(username);
        var pass = Encoding.UTF8.GetBytes(password);
        try
        {
            var output = new byte[Header + user.Length + pass.Length];
            output[0] = (byte)(user.Length >> 8);
            output[1] = (byte)user.Length;
            Buffer.BlockCopy(user, 0, output, Header, user.Length);
            Buffer.BlockCopy(pass, 0, output, Header + user.Length, pass.Length);
            return output;
        }
        finally
        {
            Array.Clear(pass, 0, pass.Length);
        }
    }

    private static Credential? Unframe(byte[] plain)
    {
        if (plain.Length <= Header) return null;
        var length = ((plain[0] & 0xFF) << 8) | (plain[1] & 0xFF);
        if (length <= 0 || Header + length >= plain.Length) return null;
        var username = Encoding.UTF8.GetString(plain, Header, length);
        var password = Encoding.UTF8.GetString(plain, Header + length, plain.Length - Header - length);
        return new Credential(username, password.ToCharArray());
    }
}
