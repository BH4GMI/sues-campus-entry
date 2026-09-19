namespace CampusEntry.Core;

/// <summary>
/// 导航状态机，<b>纯逻辑、不依赖 UI</b>，与 Android 端 <c>EntryFlow.kt</c> 逐条一致
/// （同一份 <c>docs/CORE-SPEC.md</c> §4）。这个类只决定该做什么，动作由宿主执行。
/// </summary>
public sealed class EntryFlow
{
    /// <summary>门户探测的自续重试上限（CORE-SPEC §3：600ms 一发、最多 15 发后交回用户）。</summary>
    public const int ProbeMaxAttempts = 15;

    public enum Action
    {
        Nothing,
        InspectCas,
        AssistCas,
        SkipExpired,
        RejectCredentials,
        Transient,
        Settle,
        ClearPrefix,
        SecondLogin,
        ProbePortal,

        /// <summary>
        /// 到了「可能已经是目的地」的页面：**先验正文**再决定要不要停手（CORE-SPEC §2）。
        /// 只用于门户入口那一跳——URL 落在门户主机只说明「到过」，中转页与门户自己的错误页都满足它。
        /// </summary>
        VerifyArrival,
    }

    /// <summary>当前替哪个入口服务。</summary>
    public Sues.Entry Entry { get; private set; } = Sues.Entry.Jxfw;

    /// <summary>站点自己开的窗口：不替用户导航，但仍然辅助认证页。</summary>
    public bool Adopted { get; private set; }

    /// <summary>本次是不是用缓存前缀直打教务系统进来的。</summary>
    private bool _fromCachedPrefix;

    /// <summary>已经停手：不再替用户导航（认证页的帮忙仍然保留）。</summary>
    private bool _settled;

    /// <summary>本次流程里见过认证页：用来把「登录完落在门户」和「前缀已失效」分开。</summary>
    private bool _casSeen;

    /// <summary>
    /// 应用替用户提交过凭据、<b>判决还没落地</b>。
    ///
    /// 登录提交是整页导航：服务端的回应（成功跳转链 / 错误文案页）是<b>下一份新文档</b>
    /// （docs/PROTOCOL.md §6）。所以「这次否定是不是冲着应用填的那组凭据来的」不能用
    /// 「文档序号相等」判断——那永远差一。正确的模型是标志：应用真的按下登录那一刻置位；
    /// 用户自己提交、登录成功、或重开流程时清掉。
    /// </summary>
    private bool _awaitingVerdict;

    // 文档账本：同一份文档会重复回调，而换文档不等于换地址（认证页提交前后地址逐字节相同），
    // 所以身份只能来自「第几份文档」。
    private int _docs;
    private int _handled = -1;

    // 门户探测的自续重试账本（按 URL 分别记）。
    //
    // 这段账本**必须住在状态机里**，不能放宿主：它的唯一改动点就是 OnProbeMissed，因此
    // 「上限到底是几发」能被单测钉住。2026-09-20 修：早先它写在宿主里，重试路径顺手调了
    // 「取消探测」（那个函数同时负责停定时器与清计数），于是计数每轮清零、上限永远到不了，
    // 探测变成无限循环，而两端宿主层一条测试都没有——没有任何东西能拦住它。
    private string? _probeUrl;
    private int _probeMisses;

    /// <summary>已经停手：不再替用户导航。</summary>
    public bool IsSettled => _settled;

    /// <summary>宿主拿它当「本文档身份」，例如记录「这份文档是我填的」。</summary>
    public int DocumentOrdinal => _docs;

    /// <summary>用户点了某个入口：把状态全部复位，重新走一遍。</summary>
    public void Start(Sues.Entry entry, bool hasCachedPrefix)
    {
        Entry = entry;
        _fromCachedPrefix = hasCachedPrefix;
        Adopted = false;
        _settled = false;
        _casSeen = false;
        _awaitingVerdict = false;
        _docs = 0;
        _handled = -1;
        ResetProbe();
    }

    /// <summary>站点自己开了这一页（window.open / target=_blank）：只辅助认证页，不替用户导航。</summary>
    public void Adopt()
    {
        Adopted = true;
        _settled = true;
        _casSeen = false;
        _awaitingVerdict = false;
        _docs = 0;
        _handled = -1;
        ResetProbe();
    }

    /// <summary>新文档开始加载。</summary>
    public void OnDocumentStarted() => _docs++;

    /// <summary>
    /// 门户探测又没读到前缀。<b>返回值就是「还要不要再探一发」</b>，宿主只管据此排下一次定时器。
    /// </summary>
    /// <remarks>
    /// 计数按 URL 分别记：换了页面就重新计（门户会自己跳几步，跳过去之后预算应当重置）。
    /// 返回 true 的次数恰好是 <see cref="ProbeMaxAttempts"/>，第 N+1 次返回 false——宿主那时提示用户。
    /// 宿主<b>不得</b>自己清这个计数：清了就等于没有上限（见字段上的说明）。
    /// </remarks>
    public bool OnProbeMissed(string url)
    {
        if (_probeUrl != url)
        {
            _probeUrl = url;
            _probeMisses = 0;
        }
        _probeMisses++;
        return _probeMisses <= ProbeMaxAttempts;
    }

    /// <summary>清掉探测重试账本（重开流程 / 被站点接管的页面）。</summary>
    private void ResetProbe()
    {
        _probeUrl = null;
        _probeMisses = 0;
    }

    /// <summary>一份新文档加载完成，返回该做什么。</summary>
    public Action OnDocumentFinished(string url)
    {
        if (_handled == _docs) return Action.Nothing;
        _handled = _docs;

        if (Sues.IsCasPage(url))
        {
            // 认证页在任何一跳都可能出现（会话过期、被踢下线），不受其它规则约束
            _casSeen = true;
            if (!Adopted) _settled = false;
            return Action.InspectCas;
        }
        // §4 的条目顺序：第 2 条「已经停手」**先于**第 3 条「换票中转页」。
        // 早先这里把中转页判定放在停手之前，于是已经交回用户的页面仍会被装上 15 秒重载定时器——
        // 一次用户没要求的导航，与「停手 = 不再替用户导航」直接冲突。
        if (_settled || Adopted) return Action.Nothing;
        if (Sues.IsTransientPage(url)) return Action.Transient;

        if (Sues.IsSecondLoginPage(url)) return Action.SecondLogin;
        if (Sues.IsJxfwPage(url)) return Settle();
        // 门户入口：**URL 落在门户主机不算到达**——换票中转页（上面已排除）与门户自己的错误页
        // 都满足它，那只说明「到过」。按 §2 先验正文，确认了再停手。
        // 教务系统那一支不用正文标记：那三个标记是**门户**的（教务系统首页没有它们），
        // `/https/<编码>/student/` 这个形状本身已经足够具体。
        if (Entry == Sues.Entry.Webvpn) return Action.VerifyArrival;
        if (_fromCachedPrefix && !_casSeen) return Action.ClearPrefix;
        return Action.ProbePortal;
    }

    /// <summary>
    /// 正文里确认了登录成功的标记：这才是真的到了目的地（CORE-SPEC §2）。
    /// 由宿主在 <see cref="Action.VerifyArrival"/> 之后调用。
    /// </summary>
    public Action ConfirmArrival() => Settle();

    /// <summary>认证页上观察到的东西，返回该做什么。优先级由 <see cref="Sues.CasKindOf"/> 说了算。</summary>
    public Action OnCasObserved(Sues.CasObservation observation) =>
        Sues.CasKindOf(observation) switch
        {
            Sues.CasKind.Expired => Action.SkipExpired,
            Sues.CasKind.Rejected => Action.RejectCredentials,
            _ => Action.AssistCas,
        };

    /// <summary>应用替用户按下了登录：置上待判决标志，不受「换了一份新文档」影响。</summary>
    public void OnAutoSubmitted() => _awaitingVerdict = true;

    /// <summary>自动提交没能发生（页面上没有表单/登录按钮）：标志作废。</summary>
    public void OnAutoSubmitAborted() => _awaitingVerdict = false;

    /// <summary>用户自己提交了凭据：待判决不再属于应用。</summary>
    public void OnUserSubmitted() => _awaitingVerdict = false;

    /// <summary>
    /// 凭据被否定时调用一次：读走并清掉待判决标志。读走即清，因此第二次否定
    /// （用户手动改过后还是错）不会再次归属给应用、不会重复触发删库。
    /// </summary>
    public bool ConsumeAutoVerdict()
    {
        var was = _awaitingVerdict;
        _awaitingVerdict = false;
        return was;
    }

    private Action Settle()
    {
        _settled = true;
        // 登录到了目的地就是正面判决：待判决状态结束
        _awaitingVerdict = false;
        return Action.Settle;
    }
}
