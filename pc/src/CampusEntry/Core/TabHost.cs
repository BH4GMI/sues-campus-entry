using Microsoft.Web.WebView2.Core;

namespace CampusEntry.Core;

/// <summary>
/// 一个标签页：自己的一份 <see cref="EntryHost"/>（也就是自己的一份 WebView2 与导航状态机）。
///
/// <para>
/// 与 Android 的 <c>Tab</c> 逐条对应（同一个 <c>docs/CORE-SPEC.md</c>）：切换标签**只改可见性，
/// 绝不导航**——于是切回来时页面还是原来那一页，状态机也不会把「用户切页面」当成一次新文档记账。
/// </para>
/// </summary>
public sealed class EntryTab
{
    public required int Id { get; init; }

    public required EntryHost Host { get; init; }

    /// <summary>标签上显示的字：页面标题，取不到时用入口名。</summary>
    public string Title { get; set; } = "";

    /// <summary>
    /// 这一页是**站点自己开的**（<c>window.open</c> / <c>target="_blank"</c>），不是用户点的入口。
    /// 这类标签会先 <see cref="EntryFlow.Adopt"/> 再接管导航：只辅助认证页，不替用户判断落点。
    /// </summary>
    public bool SiteOpened { get; init; }
}

/// <summary>
/// 标签页宿主：管每个标签的 WebView2、驱动它们各自的导航状态机、决定「谁是前台」。
///
/// <para>
/// 界面层只读 <see cref="Tabs"/> / <see cref="Active"/>，并在 <see cref="TabsChanged"/> /
/// <see cref="ActiveChanged"/> 之后重画。**只有前台标签跑自动化**：切走即
/// <see cref="EntryHost.PauseAutomation"/>，切回再 <see cref="EntryHost.ResumeAutomation"/>。
/// </para>
/// <para>
/// 站点要新开页面时（<c>window.open</c>），这里开一个真标签页并把**整段导航**递过去
/// （<c>NewWindowRequested.NewWindow</c>），于是 POST 表单、referer 都原样保留——
/// 这是 WebView2 的一等公民机制，等价 Android 的 <c>WebViewTransport</c>。
/// </para>
/// </summary>
public sealed class TabHost : IDisposable
{
    /// <summary>
    /// 标签数上限。不是性能考虑，是**安全**考虑：每个标签都有一份独立的「替用户提交凭据」预算
    /// （<see cref="EntryHost"/> 的 <c>AutoSubmitMax</c>），标签无上限等于预算无上限。
    /// </summary>
    public const int MaxTabs = 8;

    private readonly EntrySettings settings;
    private readonly CredentialRepository repository;
    private readonly CoreWebView2Environment environment;

    private readonly List<EntryTab> tabs = new();
    private int nextId = 1;
    private int activeId = -1;
    private bool disposed;

    public TabHost(EntrySettings entrySettings, CredentialRepository credentialRepository,
            CoreWebView2Environment webViewEnvironment)
    {
        settings = entrySettings;
        repository = credentialRepository;
        environment = webViewEnvironment;
    }

    // ---------------------------------------------------------------- 界面可读的状态

    public IReadOnlyList<EntryTab> Tabs => tabs;

    public EntryTab? Active => tabs.FirstOrDefault(t => t.Id == activeId);

    public int ActiveId => activeId;

    public bool SaveAccount => Active?.Host.SaveAccount ?? false;

    public string? SavedUsername => Active?.Host.SavedUsername;

    public bool HideNotices => Active?.Host.HideNotices ?? false;

    /// <summary>标签列表或标题变了（新建、关闭、标题、高亮）。</summary>
    public event Action? TabsChanged;

    /// <summary>前台标签换了，或前台标签自己的界面状态变了。</summary>
    public event Action? ActiveChanged;

    /// <summary>窗口标题跟**前台标签**的页面走。</summary>
    public event Action<string>? ViewTitleChanged;

    public event Action<string>? InitializationFailed;

    // ---------------------------------------------------------------- 建与切

    /// <summary>
    /// 开第一个标签并等它真的能导航。返回值就是那个标签；初始化失败时返回 <c>null</c>
    /// （原因经 <see cref="InitializationFailed"/> 报出去）。
    /// </summary>
    public async Task<EntryTab?> StartAsync(Sues.Entry entry)
    {
        var tab = CreateTab(siteOpened: false, title: EntryName(entry));
        try
        {
            await tab.Host.CoreReady;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        tab.Host.EnterFromHome(entry);
        return tab;
    }

    public void SwitchTo(int id)
    {
        var tab = tabs.FirstOrDefault(t => t.Id == id);
        if (tab == null || id == activeId) return;

        var previous = Active;
        activeId = id;
        Log($"切到标签 [{id}]（共 {tabs.Count} 个）");

        // 先让旧标签停手，再让新标签接手：顺序反了会有一小段两个标签同时在跑自动化。
        previous?.Host.PauseAutomation();
        tab.Host.ResumeAutomation();

        ActiveChanged?.Invoke();
        TabsChanged?.Invoke();
    }

    public void CloseTab(int id)
    {
        var index = tabs.FindIndex(t => t.Id == id);
        if (index < 0) return;
        if (tabs.Count == 1)
        {
            Log("只剩一个标签页，不关");
            return;
        }

        var tab = tabs[index];
        var wasActive = id == activeId;
        tabs.RemoveAt(index);
        Log($"关闭标签 [{id}]，剩 {tabs.Count} 个");

        if (wasActive)
        {
            activeId = -1;
            SwitchTo(tabs[Math.Min(index, tabs.Count - 1)].Id);
        }
        TabsChanged?.Invoke();
        tab.Host.Dispose();
    }

    // ---------------------------------------------------------------- 前台标签的直通操作（工具栏用）

    public void OpenEntry(Sues.Entry entry)
    {
        var active = Active;
        if (active == null) return;
        active.Title = EntryName(entry);
        active.Host.OpenEntry(entry);
        TabsChanged?.Invoke();
    }

    public void GoBack() => Active?.Host.GoBack();

    public void GoForward() => Active?.Host.GoForward();

    public void Reload() => Active?.Host.Reload();

    public void OnNoticeAction() => Active?.Host.OnNoticeAction();

    /// <summary>
    /// 自动登录意愿：前台标签负责落盘与状态行，其余标签只同步内存——
    /// 否则每改一次设置，每个标签都会各写一次 entry.json。
    /// </summary>
    public void ChangeSaveAccount(bool on)
    {
        var active = Active;
        if (active == null) return;
        active.Host.ChangeSaveAccount(on);
        foreach (var tab in tabs.Where(t => t != active)) tab.Host.AdoptSettings(on, tab.Host.HideNotices);
    }

    public void ChangeHideNotices(bool on)
    {
        var active = Active;
        if (active == null) return;
        active.Host.ChangeHideNotices(on);
        foreach (var tab in tabs.Where(t => t != active)) tab.Host.AdoptSettings(tab.Host.SaveAccount, on);
    }

    /// <summary>清除本机凭据：所有标签都要忘掉，否则切过去还显示「已记住」。</summary>
    public void ClearAccount()
    {
        foreach (var tab in tabs) tab.Host.ClearAccount();
        TabsChanged?.Invoke();
    }

    /// <summary>
    /// 退出登录 / 改用其他账号：cookie 是**整个会话**的（所有标签共用一份 profile），
    /// 所以先把别的标签关掉再清——留着它们也只会变成未登录的空壳。
    /// </summary>
    public void ClearSession()
    {
        CloseOthers();
        Active?.Host.ClearSession();
    }

    public void SwitchAccount()
    {
        CloseOthers();
        Active?.Host.SwitchAccount();
    }

    // ---------------------------------------------------------------- 建标签

    private EntryTab CreateTab(bool siteOpened, string title)
    {
        var host = new EntryHost(settings, repository, environment);
        var tab = new EntryTab
        {
            Id = nextId++,
            Host = host,
            Title = title,
            SiteOpened = siteOpened,
        };

        host.NewWindowHandler = OnNewWindowRequested;
        host.Changed += () =>
        {
            // 只转发「前台标签的界面状态变了」：状态行每更新一次都重画整条标签栏会闪、会丢悬停。
            // 标签条只在**集合或标题**变化时重画（见 TabsChanged 的几处 Invoke）。
            if (tab.Id == activeId) ActiveChanged?.Invoke();
        };
        host.ViewTitleChanged += pageTitle =>
        {
            tab.Title = string.IsNullOrWhiteSpace(pageTitle) ? title : pageTitle;
            TabsChanged?.Invoke();
            if (tab.Id == activeId) ViewTitleChanged?.Invoke(tab.Title);
        };
        host.InitializationFailed += reason =>
        {
            Log($"[{tab.Id}] 标签初始化失败：{reason}");
            // 只剩一个标签时不关它：让用户看到报错对话框，比把窗口变成空白更清楚。
            if (tabs.Count > 1) CloseTab(tab.Id);
            InitializationFailed?.Invoke(reason);
        };

        tabs.Add(tab);
        Log($"[{tab.Id}] 新建标签页（站点自开={siteOpened}），共 {tabs.Count} 个");

        // 先切过去：WPF 的 WebView2 是 HwndHost，要在可见的视觉树里才建得出 HWND，
        // 否则 EnsureCoreWebView2Async 会一直等下去。
        SwitchTo(tab.Id);
        TabsChanged?.Invoke();
        return tab;
    }

    // ---------------------------------------------------------------- 站点新开页面

    private bool OnNewWindowRequested(CoreWebView2NewWindowRequestedEventArgs e)
    {
        if (disposed) return false;
        if (tabs.Count >= MaxTabs)
        {
            Log($"标签页已到上限 {MaxTabs}，这一页并进当前标签");
            return false;
        }

        // 接过来——但新标签的 WebView2 要先建好才能把导航递过去，那是个异步过程，
        // 所以在这里取一个 deferral，等建好了再 Complete（WebView2 会一直等着）。
        CoreWebView2Deferral? deferral = null;
        try
        {
            deferral = e.GetDeferral();
        }
        catch (Exception ex)
        {
            Log($"取新窗口 deferral 失败，走兜底：{ex.GetType().Name} {ex.Message}");
        }

        _ = HandOverAsync(e, deferral);
        return true;
    }

    /// <summary>
    /// 把站点的新窗口请求交接给一个新标签。成功时整段导航（含 POST body、referer、opener）
    /// 都归新标签，原标签一点没动；失败时退回「并进当前标签」，至少不让链接变成死键。
    /// </summary>
    private async Task HandOverAsync(CoreWebView2NewWindowRequestedEventArgs e,
            CoreWebView2Deferral? deferral)
    {
        EntryTab? tab = null;
        try
        {
            tab = CreateTab(siteOpened: true, title: "新标签页");
            // 站点自开的页由站点管：先声明「这是站点的页面」，状态机才不会把它当成落点判。
            tab.Host.Flow.Adopt();
            var core = await tab.Host.CoreReady;

            e.Handled = true;
            e.NewWindow = core;
            Log($"[{tab.Id}] 接管站点新窗口：{Truncate(e.Uri, 120)}");
        }
        catch (Exception ex)
        {
            Log($"新标签页没能接住站点请求：{ex.GetType().Name} {ex.Message}");
            if (tab != null) CloseTab(tab.Id);
            try
            {
                e.Handled = true;
                if (!string.IsNullOrEmpty(e.Uri)) Active?.Host.NavigateTo(e.Uri);
            }
            catch (Exception fatal)
            {
                // 事件参数此时可能已经被释放；到这里说明连兜底都做不了，只能记下来
                Log($"新窗口兜底也失败：{fatal.GetType().Name} {fatal.Message}");
            }
        }
        finally
        {
            try
            {
                deferral?.Complete();
            }
            catch (Exception ex)
            {
                Log($"完成新窗口 deferral 失败：{ex.GetType().Name} {ex.Message}");
            }
        }
    }

    // ---------------------------------------------------------------- 杂项

    private void CloseOthers()
    {
        foreach (var tab in tabs.Where(t => t.Id != activeId).ToList()) CloseTab(tab.Id);
    }

    private static string EntryName(Sues.Entry entry) =>
            entry == Sues.Entry.Jxfw ? "教务系统" : "WebVPN";

    private static string Truncate(string text, int max) =>
            string.IsNullOrEmpty(text) ? "(空)" : text.Length <= max ? text : text[..max] + "…";

    private static void Log(string message) => EntryHost.Log("标签 " + message);

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (var tab in tabs.ToList())
        {
            tabs.Remove(tab);
            tab.Host.Dispose();
        }
        activeId = -1;
        TabsChanged?.Invoke();
        ActiveChanged?.Invoke();
    }
}
