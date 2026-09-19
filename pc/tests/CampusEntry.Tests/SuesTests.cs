using CampusEntry.Core;
using Xunit;

namespace CampusEntry.Tests;

/// <summary>docs/CORE-SPEC.md §7 的等价测试向量（与 Android 端 SuesTest 一致）。</summary>
public class SuesTests
{
    private const string Prefix =
            "https://webvpn.sues.edu.cn/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b";
    private const string CasUrl =
            "https://webvpn.sues.edu.cn/https/f3f652d234256d43300d8db9d6562d/cas/login?service=x";

    // ------------------------------------------------ 落点（§7）

    [Fact]
    public void 无前缀的教务入口回退门户()
    {
        Assert.Equal("https://webvpn.sues.edu.cn", Sues.EntryUrl(null, Sues.Entry.Jxfw));
        Assert.Equal(Prefix + "/student/sso/login", Sues.EntryUrl(Prefix, Sues.Entry.Jxfw));
        Assert.Equal("https://webvpn.sues.edu.cn", Sues.EntryUrl(Prefix, Sues.Entry.Webvpn));
    }

    // ------------------------------------------------ 前缀形状（§7）

    [Fact]
    public void 前缀只认形状不认取值()
    {
        Assert.True(Sues.IsPrefix(Prefix));
        Assert.False(Sues.IsPrefix("https://webvpn.sues.edu.cn"));
        Assert.False(Sues.IsPrefix("https://webvpn.sues.edu.cn/https/"));
        Assert.False(Sues.IsPrefix("https://webvpn.sues.edu.cn/https/zzzz"));
        Assert.False(Sues.IsPrefix(Prefix + "/student/home"));
        Assert.False(Sues.IsPrefix("/https/abc123"));
    }

    [Fact]
    public void 从门户redirect推出前缀()
    {
        var page = "https://webvpn.sues.edu.cn/";
        Assert.Equal(Prefix, Sues.PrefixFrom("/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b/student/home", page));
        Assert.Null(Sues.PrefixFrom("/http/abc123/student/home", page));
        Assert.Null(Sues.PrefixFrom("", page));
        Assert.Null(Sues.PrefixFrom(null, page));
    }

    // ------------------------------------------------ 页面身份（§7）

    [Fact]
    public void 页面身份判据()
    {
        Assert.True(Sues.IsJxfwPage(Prefix + "/student/home"));
        Assert.False(Sues.IsSecondLoginPage(Prefix + "/student/home"));
        Assert.True(Sues.IsJxfwPage(Prefix + "/student/sso/login"));
        Assert.False(Sues.IsSecondLoginPage(Prefix + "/student/sso/login"));
        Assert.True(Sues.IsSecondLoginPage(Prefix + "/student/login?refer=https://jxfw.sues.edu.cn/student/home"));
        Assert.True(Sues.IsCasPage(CasUrl));
        Assert.False(Sues.IsJxfwPage(CasUrl));
        Assert.False(Sues.IsJxfwPage("https://webvpn.sues.edu.cn/http/abc123/eams/index.action"));
        Assert.False(Sues.IsJxfwPage("https://webvpn.sues.edu.cn/http/abc123/eams/index.action"));

        var transient = "https://webvpn.sues.edu.cn/wengine-vpn/failed";
        Assert.True(Sues.IsTransientPage(transient));
        Assert.False(Sues.IsJxfwPage(transient));
        Assert.False(Sues.IsCasPage(transient));
        // 别的站点上恰好同名的路径不算网关中转页
        Assert.False(Sues.IsTransientPage("https://other.example.com/wengine-vpn/failed"));
    }

    // ------------------------------------------------ 凭据页的主机判据（§6.1）

    /// <summary>
    /// 「认证页」是**页面身份**（只看路径），「凭据页」才是**允许碰凭据**的页面（还要主机对）。
    /// 两者分开：网关改写的第三方页面路径里同样有 /cas/login，只看路径会把学校凭据填进去。
    /// </summary>
    [Fact]
    public void 凭据页必须是门户主机()
    {
        Assert.True(Sues.IsCredentialPage(CasUrl));
        Assert.False(Sues.IsCredentialPage("https://jxfw.sues.edu.cn/cas/login?service=x"));
        Assert.False(Sues.IsCredentialPage("https://example.com/cas/login"));
        // 只是身份判据变了没变：路径对就算认证页，但不算凭据页
        Assert.True(Sues.IsCasPage("https://example.com/cas/login"));
        Assert.False(Sues.IsCredentialPage(Prefix + "/student/home"));
    }

    // ------------------------------------------------ 剩余次数的措辞（APP-UX §5）

    /// <summary>
    /// 「剩余次数」是**追加**而不是替换：这条规则曾经被写成三选一，于是「再错一次就锁定了」
    /// 对「用已存凭据被否定」永远不可达——而那恰好是最可能只剩一次的场景。
    /// </summary>
    [Fact]
    public void 剩余次数是追加的一句且N不大于一时改口()
    {
        Assert.Null(Sues.RemainingClause(null));
        Assert.Equal("；还可以试 3 次", Sues.RemainingClause(3));
        Assert.Equal("；还可以试 2 次", Sues.RemainingClause(2));
        Assert.Equal("；再错一次就锁定了，请先确认密码", Sues.RemainingClause(1));
        Assert.Equal("；再错一次就锁定了，请先确认密码", Sues.RemainingClause(0));
    }

    // ------------------------------------------------ 到达判据（§2 的正文标记）

    /// <summary>
    /// §2：不能只看 URL 是否落在门户主机——换票中转页与门户自己的错误页都满足它，只说明「到过」。
    /// 权威判据是正文含 `个人信息` / `注销` / `资源站点`；标记表在 `shared/js/arrival.js` 里。
    /// </summary>
    [Fact]
    public void 到达判据只认正文里那三个标记()
    {
        Assert.Equal("个人信息", Sues.ArrivalMark("\"arrival|个人信息\""));
        Assert.Equal("注销", Sues.ArrivalMark("arrival|注销"));
        Assert.Equal("资源站点", Sues.ArrivalMark("arrival|资源站点"));
        // 没命中 / 脚本出错 / 形状不认得：一律「没确认」，不猜
        Assert.Null(Sues.ArrivalMark("arrival|none"));
        Assert.Null(Sues.ArrivalMark("arrival|err"));
        Assert.Null(Sues.ArrivalMark("arrival|"));
        Assert.Null(Sues.ArrivalMark("null"));
        Assert.Null(Sues.ArrivalMark(null));
    }

    // ------------------------------------------------ 错误文本与剩余次数（§7）

    [Theory]
    [InlineData("密码错误。再输错3次，账号将被锁定。", 3)]
    [InlineData("密码错误，还可以试2次", 2)]
    [InlineData("还可尝试2次", 2)]
    [InlineData("剩余1次", 1)]
    public void 剩余次数不写死句式(string text, int expected)
    {
        Assert.Equal(expected, Sues.LockoutRemaining(text));
    }

    [Theory]
    [InlineData("密码错误。再输错3次，账号将被锁定。")]
    [InlineData("密码错误，还可以试2次")]
    public void 凭据否定的文案判据(string text)
    {
        Assert.True(Sues.HasCredentialError(text));
    }

    [Theory]
    [InlineData("密码错误，请重试。")]
    [InlineData("账号&密码错误")]
    public void 没有次数信息时剩余为空(string text)
    {
        Assert.True(Sues.HasCredentialError(text));
        Assert.Null(Sues.LockoutRemaining(text));
    }

    [Fact]
    public void 过期不得当成密码错误()
    {
        Assert.True(Sues.IsPasswordExpired("根据密码安全策略，您的密码已过期，请及时更新！"));
        Assert.False(Sues.HasCredentialError("密码已过期"));
        Assert.True(Sues.IsLockoutCritical(1));
        Assert.True(Sues.IsLockoutCritical(0));
        Assert.False(Sues.IsLockoutCritical(2));
        Assert.False(Sues.IsLockoutCritical(null));
    }

    [Fact]
    public void 认证页回传值的解析()
    {
        var obs = Sues.CasObservationFrom("\"obs|1|1|1|根据密码安全策略，您的密码已过期！\"");
        Assert.True(obs.Expired);
        Assert.True(obs.HasForm);
        Assert.True(obs.HasCaptcha);
        Assert.Contains("密码已过期", obs.Prompt);

        // 认不出的形状一律当成「什么都没看到」，不猜
        var bad = Sues.CasObservationFrom("null");
        Assert.False(bad.Expired);
        Assert.False(bad.HasForm);
        Assert.Equal("", bad.Prompt);

        Assert.Equal(Sues.CasKind.Expired, Sues.CasKindOf(obs));
        Assert.Equal(Sues.CasKind.Rejected, Sues.CasKindOf(
                Sues.CasObservationFrom("\"obs|0|1|0|密码错误。再输错3次，账号将被锁定。\"")));
        Assert.Equal(Sues.CasKind.Form, Sues.CasKindOf(Sues.CasObservationFrom("\"obs|0|1|1|\"")));
    }

    // ------------------------------------------------ 探测结果解析（§7）

    [Fact]
    public void 探测回传值解析()
    {
        Assert.Equal("/https/abc/student/home", Sues.ProbeHref("\"portal|/https\\/abc/student/home\""));
        Assert.Null(Sues.ProbeHref("\"expired\""));
        Assert.Null(Sues.ProbeHref("\"cas\""));
        Assert.Null(Sues.ProbeHref("\"other\""));
        Assert.Null(Sues.ProbeHref("\"\""));
        Assert.Null(Sues.ProbeHref("portal|"));
    }
}

