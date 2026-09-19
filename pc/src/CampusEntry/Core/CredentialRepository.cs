using System.IO;
using System.Text;

namespace CampusEntry.Core;

/// <summary>
/// 凭据在本机的存放处：<b>密文</b>放 credentials.bin，<b>密钥</b>由 DPAPI（Windows 用户范围）保管。
/// 对齐 Android 端 <c>CredentialRepository.kt</c>：这里只做存储胶水，编解码在 <see cref="CredentialStore"/>。
/// </summary>
public sealed class CredentialRepository
{
    private const string Tag = "教务直达";

    private readonly string _path;
    private readonly CredentialStore _store;

    public CredentialRepository(string directory, CredentialStore store)
    {
        _path = Path.Combine(directory, "credentials.bin");
        _store = store;
    }

    /// <summary>保存。返回是否真的落盘了——那句「已记住账号」不能撒谎。</summary>
    public bool Save(string username, char[] password)
    {
        var blob = _store.Encode(username, password);
        try
        {
            var tmp = _path + ".tmp";
            File.WriteAllBytes(tmp, blob);
            File.Move(tmp, _path, overwrite: true);
            return true;
        }
        catch (Exception e)
        {
            System.Diagnostics.Debug.WriteLine($"[{Tag}] 凭据写盘失败：{e.Message}");
            return false;
        }
        finally
        {
            Array.Clear(blob, 0, blob.Length);
        }
    }

    /// <summary>读出一组可用凭据；没有或解不开都返回 null。<b>拿到就必须 Clear/Dispose。</b></summary>
    public Credential? Load()
    {
        switch (_store.Decode(Blob()))
        {
            case SavedCredential.Loaded loaded:
                return loaded.Credential;
            case SavedCredential.Unreadable:
                // 不静默：处置一样（让用户重登），但排障时要分得清「没存过」与「解不开」
                System.Diagnostics.Debug.WriteLine($"[{Tag}] 已保存的凭据解不开（换用户/换机器/密文被改），按未保存处理");
                return null;
            default:
                return null;
        }
    }

    /// <summary>已经保存的账号名（界面打码显示）。解出来拿到名字就立刻擦掉密码。</summary>
    public string? SavedUsername()
    {
        using var credential = Load();
        return credential?.Username;
    }

    /// <summary>清除：删密文文件。密钥在 DPAPI 那一侧，本就导不出、也无需单独销毁。</summary>
    public void Clear()
    {
        try
        {
            if (File.Exists(_path)) File.Delete(_path);
        }
        catch (Exception e)
        {
            System.Diagnostics.Debug.WriteLine($"[{Tag}] 凭据文件删除失败：{e.Message}");
        }
    }

    private byte[]? Blob()
    {
        try
        {
            return File.Exists(_path) ? File.ReadAllBytes(_path) : null;
        }
        catch (Exception e)
        {
            System.Diagnostics.Debug.WriteLine($"[{Tag}] 凭据文件读不了：{e.Message}");
            return null;
        }
    }
}


