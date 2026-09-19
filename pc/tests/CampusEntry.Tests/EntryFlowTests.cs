using CampusEntry.Core;
using Xunit;
using static CampusEntry.Core.Sues;
using Action = CampusEntry.Core.EntryFlow.Action;

namespace CampusEntry.Tests;

/// <summary>导航状态机（与 Android 端 EntryFlowTest 等价，含否定的归因用例）。</summary>
public class EntryFlowTests
{
    private const string Prefix =
            "https://webvpn.sues.edu.cn/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b";
    private const string SsoUrl = Prefix + "/student/sso/login";
    private const string JxfwHome = Prefix + "/student/home";
    private const string CasUrl =
            "https://webvpn.sues.edu.cn/https/f3f652d234256d43300d8db9d6562d/cas/login?service=x";
    private const string SecondLogin = Prefix + "/student/login?refer=https://jxfw.sues.edu.cn/student/home";
    private const string Transient = "https://webvpn.sues.edu.cn/wengine-vpn/failed";

    private static Action Visit(EntryFlow flow, string url)
    {
        flow.OnDocumentStarted();
        return flow.OnDocumentFinished(url);
    }

    private static readonly CasObservation Expired = new(true, false, true, "根据密码安全策略，您的密码已过期，请及时更新！");
    private static readonly CasObservation Rejected = new(false, true, false, "密码错误。再输错3次，账号将被锁定。");
    private static readonly CasObservation NormalForm = new(false, true, true, "");

    [Fact]
    public void 没有缓存前缀时先回门户读前缀()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: false);
        Assert.Equal(Action.ProbePortal, Visit(flow, Portal));
    }

    [Fact]
    public void 用缓存前缀直打教务系统就停手()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Assert.Equal(Action.Settle, Visit(flow, SsoUrl));
        Assert.True(flow.IsSettled);
        Assert.Equal(Action.Nothing, Visit(flow, JxfwHome));
    }

    [Fact]
    public void 缓存前缀已失效才清前缀()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Assert.Equal(Action.ClearPrefix, Visit(flow, Prefix + "/something-else"));
    }

    [Fact]
    public void 经过认证页之后落在门户不算前缀失效()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Assert.Equal(Action.InspectCas, Visit(flow, CasUrl));
        Assert.Equal(Action.ProbePortal, Visit(flow, Prefix + "/"));
    }

    [Fact]
    public void 停手之后落到换票中转页也不重载()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Webvpn, hasCachedPrefix: true);
        Assert.Equal(Action.VerifyArrival, Visit(flow, Portal));
        Assert.Equal(Action.Settle, flow.ConfirmArrival());
        // §4 第 2 条先于第 3 条：停手了就不再有「等它自己跳 + 超时重载」这回事
        Assert.Equal(Action.Nothing, Visit(flow, Transient));
    }

    [Fact]
    public void 换票中转页不清前缀等待它自己跳()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Assert.Equal(Action.Transient, Visit(flow, Transient));
        Assert.False(flow.IsSettled);
        Assert.Equal(Action.Settle, Visit(flow, JxfwHome));
    }

    [Fact]
    public void 认证页的三种状态各走各的()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Assert.Equal(Action.InspectCas, Visit(flow, CasUrl));
        // 过期优先，先跳过它
        Assert.Equal(Action.SkipExpired, flow.OnCasObserved(Expired));
        // 服务端否定凭据：停手不重试
        Assert.Equal(Action.RejectCredentials, flow.OnCasObserved(Rejected));
        // 正常表单：勾记住我 + 装监视器
        Assert.Equal(Action.AssistCas, flow.OnCasObserved(NormalForm));
    }

    [Fact]
    public void 见过认证页会把停手复位()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Assert.Equal(Action.Settle, Visit(flow, JxfwHome));
        Assert.Equal(Action.InspectCas, Visit(flow, CasUrl));
        Assert.False(flow.IsSettled);
    }

    [Fact]
    public void 停手之后不再替用户导航()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Webvpn, hasCachedPrefix: true);
        Assert.Equal(Action.VerifyArrival, Visit(flow, Portal));
        Assert.Equal(Action.Settle, flow.ConfirmArrival());
        Assert.Equal(Action.Nothing, Visit(flow, Prefix + "/other/page"));
        Assert.Equal(Action.Nothing, Visit(flow, SecondLogin));
    }

    [Fact]
    public void 门户入口要先验正文才停手()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Webvpn, hasCachedPrefix: true);
        Assert.Equal(Action.VerifyArrival, Visit(flow, Portal));
        // §2：URL 落在门户主机只说明「到过」，没验正文之前不算到达
        Assert.False(flow.IsSettled);
        Assert.Equal(Action.Settle, flow.ConfirmArrival());
        Assert.True(flow.IsSettled);
        Assert.Equal(Action.Nothing, Visit(flow, Portal + "/other"));
    }

    [Fact]
    public void 教务系统入口按地址形状到达不看门户标记()
    {
        // 那三个标记是**门户**的（教务系统首页没有它们），所以 /https/<编码>/student/ 那一支
        // 不能被要求验正文——否则主路径永不落定。
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Assert.Equal(Action.Settle, Visit(flow, JxfwHome));
        Assert.True(flow.IsSettled);
    }

    [Fact]
    public void 二次登录页只提示不自动填()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: false);
        Assert.Equal(Action.SecondLogin, Visit(flow, SecondLogin));
    }

    [Fact]
    public void 同一份文档重复回调只处理一次()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Assert.Equal(Action.Settle, Visit(flow, JxfwHome));
        Assert.Equal(Action.Nothing, flow.OnDocumentFinished(JxfwHome));
        Assert.Equal(Action.Nothing, flow.OnDocumentFinished(JxfwHome));
    }

    [Fact]
    public void 站点自己开的标签页不劫持用户()
    {
        var flow = new EntryFlow();
        flow.Adopt();
        Assert.Equal(Action.Nothing, Visit(flow, Portal));
        Assert.Equal(Action.Nothing, Visit(flow, JxfwHome));
        Assert.Equal(Action.Nothing, Visit(flow, Transient));
        Assert.Equal(Action.InspectCas, Visit(flow, CasUrl));
        Assert.Equal(Action.AssistCas, flow.OnCasObserved(NormalForm));
        Assert.Equal(Action.Nothing, Visit(flow, Portal));
    }

    [Fact]
    public void 重新点入口会把状态清干净()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Visit(flow, JxfwHome);
        flow.Start(Entry.Webvpn, hasCachedPrefix: true);
        Assert.False(flow.IsSettled);
        Assert.Equal(Entry.Webvpn, flow.Entry);
        Assert.Equal(Action.VerifyArrival, Visit(flow, Portal));
    }

    // ------------------------------------------------ 门户探测的自续重试（S1 回归）

    /// <summary>
    /// 上限的账本住在状态机里，所以这条用例能钉住它。
    /// 回归的缺陷：宿主在重试路径上顺手把计数清零 → 上限永远到不了 → 探测无限循环，
    /// "没在门户里找到教务系统入口" 的提示成了死代码。
    /// </summary>
    [Fact]
    public void 门户探测最多自续十五发然后交回用户()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: false);
        Assert.Equal(Action.ProbePortal, Visit(flow, Portal));

        // 循环必须有界：真回归时（上限失效）要"失败"，不能把测试跑成挂死
        var retries = 0;
        while (flow.OnProbeMissed(Portal) && retries < 100) retries++;
        Assert.Equal(EntryFlow.ProbeMaxAttempts, retries);
    }

    [Fact]
    public void 换一页会重新计探测次数()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: false);
        for (var i = 0; i < EntryFlow.ProbeMaxAttempts; i++) Assert.True(flow.OnProbeMissed(Portal));
        Assert.False(flow.OnProbeMissed(Portal));
        // 门户自己跳一步就到新页面：预算应当重来
        Assert.True(flow.OnProbeMissed(Portal + "/login"));
    }

    [Fact]
    public void 重新点入口会把探测次数清零()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: false);
        for (var i = 0; i < 100 && flow.OnProbeMissed(Portal); i++) { }
        Assert.False(flow.OnProbeMissed(Portal));
        flow.Start(Entry.Jxfw, hasCachedPrefix: false);
        Assert.True(flow.OnProbeMissed(Portal));
    }

    // ------------------------------------------------ 否定的归因：待判决标志，不是文档序号

    /// <summary>
    /// 登录提交是整页导航，服务端的否定落在下一份新文档上（PROTOCOL §6）。
    /// 用「文档序号相等」归因永远差一——已存凭据被否定时不会删。
    /// </summary>
    [Fact]
    public void 自动提交后的否定落在下一份文档上也归因给应用()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Visit(flow, CasUrl);                    // 认证页（文档 N）
        flow.OnCasObserved(NormalForm);
        flow.OnAutoSubmitted();                 // 按下登录的那一刻
        flow.OnDocumentStarted();               // 服务端回应是一份新文档（N+1）
        Assert.Equal(Action.InspectCas, flow.OnDocumentFinished(CasUrl));
        Assert.Equal(Action.RejectCredentials, flow.OnCasObserved(Rejected));
        // 否定必须归因给应用那次提交
        Assert.True(flow.ConsumeAutoVerdict());
    }

    [Fact]
    public void 用户自己提交后的否定不归因给应用()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Visit(flow, CasUrl);
        flow.OnAutoSubmitted();
        flow.OnUserSubmitted();
        flow.OnDocumentStarted();
        flow.OnDocumentFinished(CasUrl);
        flow.OnCasObserved(Rejected);
        Assert.False(flow.ConsumeAutoVerdict());
    }

    [Fact]
    public void 判决读走即清_第二次否定不会再次归因给应用()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Visit(flow, CasUrl);
        flow.OnAutoSubmitted();
        flow.OnDocumentStarted();
        flow.OnDocumentFinished(CasUrl);
        flow.OnCasObserved(Rejected);
        Assert.True(flow.ConsumeAutoVerdict());
        flow.OnDocumentStarted();
        flow.OnDocumentFinished(CasUrl);
        flow.OnCasObserved(Rejected);
        Assert.False(flow.ConsumeAutoVerdict());
    }

    [Fact]
    public void 登录成功与重开流程都会清掉待判决()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Visit(flow, CasUrl);
        flow.OnAutoSubmitted();
        flow.OnDocumentStarted();
        Assert.Equal(Action.Settle, flow.OnDocumentFinished(JxfwHome));
        Assert.False(flow.ConsumeAutoVerdict());

        flow.OnAutoSubmitted();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Assert.False(flow.ConsumeAutoVerdict());
    }

    [Fact]
    public void 页面没填成就把待判决作废()
    {
        var flow = new EntryFlow();
        flow.Start(Entry.Jxfw, hasCachedPrefix: true);
        Visit(flow, CasUrl);
        flow.OnAutoSubmitted();
        flow.OnAutoSubmitAborted();
        Assert.False(flow.ConsumeAutoVerdict());
    }
}

file static class AssertEx
{
    public static bool True(string reason, bool condition)
    {
        Assert.True(condition, reason);
        return condition;
    }
}

