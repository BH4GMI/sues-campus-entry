using System.Text.Json;
using System.IO;

namespace CampusEntry.Core;

/// <summary>
/// PC 端的落盘偏好（%LOCALAPPDATA%\CampusEntry\entry.json）：网关前缀、保存意愿、公告开关。
/// 凭据不在这里——单独放 credentials.bin，便于「清除账号」与备份排除（对齐 Android 端两个文件的做法）。
/// </summary>
public sealed class EntrySettings
{
    public string? Prefix { get; set; }
    public bool SaveAccount { get; set; } = true;
    public bool SaveDecided { get; set; }
    public bool HideNotices { get; set; } = true;

    // 桌面惯例：记住上次窗口的大小与位置。null = 未记录过（首次居中）。
    public double? WindowLeft { get; set; }
    public double? WindowTop { get; set; }
    public double? WindowWidth { get; set; }
    public double? WindowHeight { get; set; }
    public bool WindowMaximized { get; set; }

    /// <summary>
    /// 本机数据目录。
    /// <para>
    /// <b>这是持久化键，不是显示名</b>：目录名里的 <c>CampusEntry</c> 与产品显示名「教务直达」无关，
    /// 改名时**绝不能**跟着改——一旦改了，用户机器上已保存的账号与偏好会全部读不到
    /// （表现是"突然要我重新登录"，看起来像登录坏了，实际是数据被另起炉灶）。
    /// 同一原则适用于 Android 的 SharedPreferences 文件名。
    /// </para>
    /// </summary>
    public static string DirectoryPath =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CampusEntry");

    /// <summary>
    /// 本实例的落盘目录；<c>null</c> = 用 <see cref="DirectoryPath"/>。
    /// <para>
    /// 存在的唯一理由：**宿主层测试**要能装配真宿主而不覆盖用户真实的 <c>entry.json</c>。
    /// <see cref="Save"/> 是宿主会主动调用的（清前缀、切换保存意愿），所以只靠"测试不去调 Save"是防不住的。
    /// 两端同一原则：Android 用测试独立的 SharedPreferences 名。
    /// </para>
    /// </summary>
    public string? DataDirectory { get; init; }

    private string ResolvedDirectory => DataDirectory ?? DirectoryPath;

    private string FilePath => Path.Combine(ResolvedDirectory, "entry.json");

    public static EntrySettings Load()
    {
        try
        {
            var path = Path.Combine(DirectoryPath, "entry.json");
            if (!File.Exists(path)) return new EntrySettings();
            return JsonSerializer.Deserialize<EntrySettings>(File.ReadAllText(path)) ?? new EntrySettings();
        }
        catch
        {
            // 偏好读不动就当首次使用：宁可重新走一遍门户，也不带着可疑状态跑
            return new EntrySettings();
        }
    }

    /// <summary>
    /// 落盘。<b>不抛</b>：这是与 <see cref="Load"/> 对称的契约——偏好读不动、写不动，都不能把主流程带走。
    /// 返回是否真的写成功：调用方据此决定口径（例如「已清除记录」就不能在没写成功时照说）。
    /// </summary>
    public bool Save()
    {
        try
        {
            Directory.CreateDirectory(ResolvedDirectory);
            File.WriteAllText(FilePath,
                    JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            return true;
        }
        catch (Exception e)
        {
            System.Diagnostics.Debug.WriteLine($"[CampusEntry] 偏好写盘失败：{e.Message}");
            return false;
        }
    }
}

