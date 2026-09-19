using System.Text.RegularExpressions;

namespace CampusEntry.Core;

/// <summary>
/// 打开校内两个系统所需的全部判断，<b>纯逻辑、不依赖 UI</b>。
/// 与 Android 端 <c>Sues.kt</c> 逐条一致（同一份 <c>docs/CORE-SPEC.md</c>）；改判据先改规范再两端同改。
/// 这里不碰任何凭据本身：只认地址形状、页面身份与服务端给的提示文本。
/// </summary>
public static class Sues
{
    /// <summary>WebVPN 门户首页。</summary>
    public const string Portal = "https://webvpn.sues.edu.cn";

    /// <summary>门户主机名。只有它下面才是网关自己的路径（如换票中转页），别的站点同名路径不算。</summary>
    public static string PortalHost => Portal.Replace("https://", "");

    /// <summary>教务系统免二次登录的入口路径；与网关前缀拼起来就是落点。</summary>
    public const string SsoPath = "/student/sso/login";

    /// <summary>教务系统在 WebVPN 下的地址形态：<c>/https/&lt;主机编码&gt;/student/…</c>。</summary>
    private static readonly Regex JxfwUrl = new(@"/https/[0-9a-f]+/student/", RegexOptions.Compiled);

    /// <summary>网关前缀只认形状：<c>http(s)://主机/https/&lt;十六进制编码&gt;</c>。编码不得写死。</summary>
    private static readonly Regex Prefix = new(@"^https?://[^/]+/https/[0-9a-fA-F]+$", RegexOptions.Compiled);

    /// <summary>换票链的中间落点；不代表登录失败，也不能当成「入口地址已失效」。</summary>
    private const string TransientPath = "/wengine-vpn/failed";

    /// <summary>「密码已过期」提示页的判据。只对部分账号弹出，不弹属正常路径。</summary>
    public const string PasswordExpiredMark = "密码已过期";

    /// <summary>服务端否定凭据时用的文案标记（实测自认证页的 #msg1 / .form-error 容器）。</summary>
    private static readonly string[] CredentialMarks =
    {
        "密码错误", "密码不正确", "用户名或密码", "账号或密码",
        "用户不存在", "账号不存在", "用户名不存在",
    };

    /// <summary>剩余次数文案里，数字前面出现这些词才认（服务端措辞不固定，不写死句式）。</summary>
    private static readonly string[] LockoutKeywords =
    {
        "再", "还", "剩余", "剩", "可再", "尝试", "输错", "错误",
    };

    private static readonly Regex LockoutCount = new(@"(\d+)\s*次", RegexOptions.Compiled);

    /// <summary>回看多少个字符，来确认这个「N次」确实是在说剩余次数。</summary>
    private const int LockoutLookback = 12;

    /// <summary>两个入口。默认教务系统，WebVPN 是次要入口。</summary>
    public enum Entry { Jxfw, Webvpn }

    /// <summary>统一身份认证页（会话过期时网关会把请求弹到这里）。</summary>
    public static bool IsCasPage(string url) => url.Contains("/cas/login");

    /// <summary>
    /// <b>允许填写 / 捕获凭据的页面</b>（CORE-SPEC §6.1）：主机必须是门户主机，且 URL 含
    /// <c>/cas/login</c>。第三条「文档同时存在 <c>#username</c> 与 <c>#password</c>」在页面脚本里判
    /// （它返回 <c>noform</c>，宿主据此作废这次填写）。
    /// </summary>
    /// <remarks>
    /// 为什么不能只看路径：网关会把第三方页面改写到自己主机下，教务系统自己也有 CAS 形态的登录页。
    /// 只看 <c>/cas/login</c> 就会把本机保存的学校凭据填进一个**不该填**的页面——而
    /// DESIGN.md 与两端界面文案都明写着「账号密码只在学校自己的统一身份认证页上输入」。
    /// </remarks>
    public static bool IsCredentialPage(string url) => IsCasPage(url) && HostOf(url) == PortalHost;

    /// <summary>已经在教务系统里。</summary>
    public static bool IsJxfwPage(string url) => JxfwUrl.IsMatch(url);

    /// <summary>教务系统自己的登录页（要求二次登录）。落点必须用 SSO 支点，不能用卡片地址。</summary>
    public static bool IsSecondLoginPage(string url) => IsJxfwPage(url) && url.Contains("/student/login");

    private static readonly Regex HostPattern = new(@"^[a-zA-Z]+://([^/?#]+)", RegexOptions.Compiled);
    private static readonly Regex PathPattern = new(@"^[a-zA-Z]+://[^/?#]*(/[^?#]*)?", RegexOptions.Compiled);

    /// <summary>地址里的主机名（去掉端口）；取不到返回空串。</summary>
    public static string HostOf(string url) =>
        HostPattern.Match(url) is { Success: true, Groups.Count: > 1 } m
            ? m.Groups[1].Value.Split(':')[0] : "";

    /// <summary>地址里的路径（含开头的 /）；没有路径返回空串。</summary>
    public static string PathOf(string url) =>
        PathPattern.Match(url) is { Success: true, Groups.Count: > 1 } m ? m.Groups[1].Value : "";

    /// <summary>换票中转页。判据必须带主机名——别的站点上恰好同名的路径不能被当成网关的中转页。</summary>
    public static bool IsTransientPage(string url) =>
        HostOf(url) == PortalHost && PathOf(url).StartsWith(TransientPath, StringComparison.Ordinal);

    /// <summary>正文是不是「密码已过期」提示页。这条路径不消耗失败次数，与密码错误本质不同。</summary>
    public static bool IsPasswordExpired(string body) => body.Contains(PasswordExpiredMark, StringComparison.Ordinal);

    /// <summary>服务端给的文案里，有没有对凭据的否定。</summary>
    public static bool HasCredentialError(string text) =>
        text.Length > 0 && CredentialMarks.Any(text.Contains);

    /// <summary>
    /// 从服务端文案里解析「还剩几次可以试」；解析不到返回 null。
    /// 实测文案「密码错误。再输错3次，账号将被锁定。」→ 3。
    /// </summary>
    public static int? LockoutRemaining(string text)
    {
        if (text.Length == 0) return null;
        foreach (Match match in LockoutCount.Matches(text))
        {
            var start = match.Index;
            var from = Math.Max(0, start - LockoutLookback);
            var context = text.Substring(from, start - from);
            if (LockoutKeywords.All(k => !context.Contains(k, StringComparison.Ordinal))) continue;
            if (int.TryParse(match.Groups[1].Value, out var n)) return n;
        }
        return null;
    }

    /// <summary>剩余次数已经不能再赌了。服务端累计失败次数，5 次锁号，所以 ≤1 时必须硬性阻断一切重试。</summary>
    public static bool IsLockoutCritical(int? remaining) => remaining is <= 1;

    /// <summary>
    /// 「剩余次数」那半句话（APP-UX §5 的「剩余次数」行）：**追加**在否定文案后面，不是替换它。
    /// 解析不到次数时返回 null（什么都不加）。
    /// </summary>
    /// <remarks>
    /// 为什么值得单独一个函数：它曾经是实现里的一个 bug——文案写成三选一，
    /// 「用已存凭据被否定」先命中，于是「再错一次就锁定了」对**最可能只剩一次**的那种场景
    /// 永远不可达（每次冷启动都会自动消耗一次失败次数）。规则放在这里就能被单测钉住。
    /// </remarks>
    public static string? RemainingClause(int? remaining) => remaining switch
    {
        null => null,
        var n when IsLockoutCritical(n) => "；再错一次就锁定了，请先确认密码",
        var n => $"；还可以试 {n} 次",
    };

    /// <summary>认证页上「除了它本身是认证页之外」看到的东西。页面侧原样回报，不夹带任何判断。</summary>
    public sealed record CasObservation(
        bool Expired,
        bool HasForm,
        bool HasCaptcha,
        string Prompt)
    {
        public static readonly CasObservation Empty = new(false, false, false, "");
    }

    /// <summary>认证页该按哪一条处理。</summary>
    public enum CasKind { Expired, Rejected, Form, Captcha, Other }

    /// <summary>
    /// 解析页面脚本 cas-state.js 的回传值 <c>obs|&lt;过期&gt;|&lt;表单&gt;|&lt;滑块&gt;|&lt;提示文本&gt;</c>。
    /// 认不出的形状一律当成「什么都没看到」，不猜。
    /// </summary>
    public static CasObservation CasObservationFrom(string? raw)
    {
        var value = (raw ?? "").Trim().Trim('"');
        var parts = value.Split('|', 5);
        if (parts.Length < 4 || parts[0] != "obs") return CasObservation.Empty;
        return new CasObservation(
            Expired: parts[1] == "1",
            HasForm: parts[2] == "1",
            HasCaptcha: parts[3] == "1",
            Prompt: parts.Length > 4 ? parts[4] : "");
    }

    /// <summary>
    /// 按优先级决定怎么处理：过期 &gt; 凭据被否定 &gt; 表单 &gt; 滑块。
    /// 顺序必须能被单测——真机教过一次：优先级写错会把过期页整个挡住（docs/PROTOCOL.md §6）。
    /// </summary>
    public static CasKind CasKindOf(CasObservation o) =>
        o.Expired ? CasKind.Expired
        : HasCredentialError(o.Prompt) ? CasKind.Rejected
        : o.HasForm ? CasKind.Form
        : o.HasCaptcha ? CasKind.Captcha
        : CasKind.Other;

    /// <summary>前缀形状是否合法。</summary>
    public static bool IsPrefix(string value) => Prefix.IsMatch(value);

    /// <summary>从门户给出的 redirect/href 推出网关前缀；推不出返回 null。</summary>
    public static string? PrefixFrom(string? redirect, string pageUrl)
    {
        var href = (redirect ?? "").Trim();
        if (href.Length == 0) return null;
        var abs = href.StartsWith("http", StringComparison.Ordinal) ? href : OriginOf(pageUrl) + href;
        if (!abs.Contains("/https/")) return null;
        var prefix = abs.SubstringBefore("/student/");
        return IsPrefix(prefix) ? prefix : null;
    }

    /// <summary>
    /// 入口地址：记得前缀就直打教务系统的 SSO 支点；没记过（首次使用）回退门户首页，
    /// 由门户那一跳把前缀读出来。WebVPN 入口就是门户首页。
    /// </summary>
    public static string EntryUrl(string? prefix, Entry entry) =>
        entry == Entry.Webvpn ? Portal
        : prefix != null ? prefix + SsoPath
        : Portal;

    /// <summary>页面侧探测结果里那条入口地址（<c>portal|&lt;href&gt;</c>）；其余形态一律 null。</summary>
    public static string? ProbeHref(string? probe)
    {
        if (probe == null) return null;
        var raw = probe.Trim().Trim('"').Replace("\\/", "/");
        if (!raw.StartsWith("portal|")) return null;
        var href = raw["portal|".Length..];
        return href.Length > 0 ? href : null;
    }

    /// <summary>
    /// 解析页面脚本 <c>arrival.js</c> 的回传值：<c>arrival|&lt;命中的标记&gt;</c> / <c>arrival|none</c> /
    /// <c>arrival|err</c>。返回命中的标记名；**没确认到达时返回 null**（认不出的形状一律当没确认，不猜）。
    /// </summary>
    /// <remarks>
    /// CORE-SPEC §2：「成功」的判据是**正文**含 <c>个人信息</c> / <c>注销</c> / <c>资源站点</c>，
    /// 不能只看 URL 是不是落在门户主机——换票中转页、门户自己的错误页都满足那个条件，只说明「到过」。
    /// 标记表写在 `shared/js/arrival.js` 里（只有页面侧看得到正文），这里只解析它的结论。
    /// </remarks>
    public static string? ArrivalMark(string? raw)
    {
        var value = (raw ?? "").Trim().Trim('"');
        var parts = value.Split('|', 2);
        if (parts.Length != 2 || parts[0] != "arrival") return null;
        return parts[1] is "none" or "err" or "" ? null : parts[1];
    }

    /// <summary>两串地址是不是同一页（只忽略末尾斜杠）。</summary>
    public static bool SamePage(string? a, string? b)
    {
        if (string.IsNullOrEmpty(a) || string.IsNullOrEmpty(b)) return false;
        return a.TrimEnd('/').Equals(b.TrimEnd('/'), StringComparison.Ordinal);
    }

    public static string OriginOf(string url) =>
        new Regex(@"^https?://[^/]+").Match(url) is { Success: true } m ? m.Value : "";
}

file static class StringExt
{
    public static string SubstringBefore(this string s, string marker)
    {
        var i = s.IndexOf(marker, StringComparison.Ordinal);
        return i < 0 ? s : s[..i];
    }
}

