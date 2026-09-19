using System.Drawing;
using System.IO;
using System.Text.Json;
using System.Windows.Threading;

namespace CampusEntry.Core;

/// <summary>底栏正上方那一行状态。</summary>
public sealed class NoticeState
{
    public enum ToneKind { Plain, Alert, Done }

    public string Text { get; init; } = "";
    public ToneKind Tone { get; init; } = ToneKind.Plain;

    /// <summary>需要用户出手时不再自动消失。</summary>
    public bool Sticky { get; init; }

    public NoticeKind Kind { get; init; } = NoticeKind.None;
}

/// <summary>
/// 状态行上的可点动作（APP-UX §5 的「是否可点」列），界面据此决定显示哪个按钮。
/// <para>
/// <see cref="UndoSave"/> 与 <see cref="ClearAccount"/> 的**效果相同**（清掉本机凭据 + 关掉自动登录），
/// 分开只是因为语境不同、按钮该写的字不同：刚保存成功是「撤销」，凭据被否定是「清除账号」。
/// </para>
/// </summary>
public enum NoticeKind { None, Retry, UndoSave, ClearAccount }

/// <summary>
/// WebView2 宿主：驱动导航状态机、维护界面要显示的状态。与 Android 端 <c>EntryHost.kt</c>
/// 逐条对应（同一份 <c>docs/CORE-SPEC.md</c>）；差别只在传输层——页面回调走
/// <c>chrome.webview.postMessage</c>（见 <see cref="ScriptBag.EntryShim"/>），单窗口无标签页。
/// </summary>
public sealed class EntryHost : IDisposable
{
    private const string Tag = "教务直达";

    /// <summary>探测的节奏。**发数上限在 <see cref="EntryFlow.ProbeMaxAttempts"/>**：那是判据，住在状态机里才测得到。</summary>
    private const int ProbeIntervalMs = 600;
    private const int CaptchaMaxAttempts = 3;

    /// <summary>每次流程里替用户提交凭据的硬上限（服务端累计失败次数，5 次锁号）。</summary>
    private const int AutoSubmitMax = 2;

    private const int ArmedTimeoutMs = 20_000;
    private const int TransientTimeoutMs = 15_000;
    private const int TransientMaxReloads = 1;
    private const int ExpiredMaxSkips = 1;
    private const int NoticeTimeoutMs = 2_000;
    private const int PendingTimeoutMs = 90_000;

    private readonly EntrySettings settings;
    private readonly CredentialRepository repository;
    private readonly Dispatcher dispatcher;

    public Microsoft.Web.WebView2.Wpf.WebView2 View { get; } = new();
    private Microsoft.Web.WebView2.Core.CoreWebView2 Core => View.CoreWebView2;

    public EntryFlow Flow { get; } = new();

    // ---------------------------------------------------------------- 界面镜像状态

    public NoticeState Notice { get; private set; } = new();
    public bool Home { get; private set; }
    public bool SaveAccount { get; private set; }
    public string? SavedUsername { get; private set; }
    public bool HideNotices { get; private set; }
    public Sues.Entry ActiveEntry { get; private set; } = Sues.Entry.Jxfw;

    /// <summary>界面状态有变（通知、开关、首页显隐），Compose/WPF 侧据此刷新。</summary>
    public event Action? Changed;

    /// <summary>WebView2 就绪（可以开始导航了）。</summary>
    public event Action? Ready;

    /// <summary>
    /// WebView2 初始化失败（运行时装了但起不来那一类）。界面据此给出「为什么 + 下一步」，
    /// 而不是让用户对着空白窗口猜。
    /// </summary>
    public event Action<string>? InitializationFailed;

    private void RaiseChanged() => Changed?.Invoke();

    // ---------------------------------------------------------------- 本次流程的运行时状态（对齐 Android 的 Tab 字段）

    private bool autoStopped;
    private string lastPrompt = "";
    private DispatcherTimer? probeTick;
    private DispatcherTimer? transientTick;
    private int transientReloads;
    private DispatcherTimer? armedTick;
    private int captchaAttempts;
    private string? captchaLastId;
    private bool captchaGaveUp;
    private int expiredSkips;
    private Credential? pending;
    private DispatcherTimer? pendingTick;
    private int filledDoc = -1;
    private int autoSubmits;
    private int tweakedDoc = -1;
    private DispatcherTimer? noticeTick;

    public EntryHost(EntrySettings entrySettings, CredentialRepository credentialRepository,
            Microsoft.Web.WebView2.Core.CoreWebView2Environment environment)
    {
        settings = entrySettings;
        repository = credentialRepository;
        dispatcher = Dispatcher.CurrentDispatcher;

        SaveAccount = settings.SaveAccount;
        HideNotices = settings.HideNotices;
        // 读已保存的账号要跑一次 DPAPI 解密：**放到线程池**，别占着界面线程
        //（构造发生在窗口已经显示之后）。读完 RaiseChanged 刷新界面；失败等价于「没存过」。
        SavedUsername = null;
        LoadSavedUsernameAsync();
        Home = !settings.SaveDecided;

        View.CoreWebView2InitializationCompleted += (_, e) =>
        {
            if (e.IsSuccess)
            {
                OnCoreReady();
            }
            else
            {
                // 不是「缺少运行时」（那是 WebView2RuntimeNotFoundException，启动时就能拦），
                // 而是运行时装上了却起不来。之前只写日志，用户看到的是一个空白窗口且没有任何出口。
                var reason = e.InitializationException?.Message ?? "未知原因";
                Log($"WebView2 初始化失败：{reason}");
                InitializationFailed?.Invoke(reason);
            }
        };
        _ = View.EnsureCoreWebView2Async(environment);
    }

    /// <summary>
    /// 后台读一次「已保存的账号」再刷新界面。失败只记日志——读不出来等价于没存过，不影响下一步。
    /// </summary>
    private async void LoadSavedUsernameAsync()
    {
        try
        {
            var name = await Task.Run(() => repository.SavedUsername());
            SavedUsername = name;
            RaiseChanged();
        }
        catch (Exception e)
        {
            Log($"读取已保存的账号失败：{e.GetType().Name} {e.Message}");
        }
    }

    private void OnCoreReady()
    {
        Core.NavigationStarting += (_, e) =>
        {
            // 服务端重定向链不产生新文档（对齐 Android onPageStarted 的语义），不进账本
            if (!e.IsRedirected) Flow.OnDocumentStarted();
        };
        Core.NavigationCompleted += (_, e) =>
        {
            var url = Core.Source;
            try
            {
                if (!e.IsSuccess)
                {
                    // **加载失败不是一份文档**，绝不能交给状态机。
                    // 交给它会同时错两次（都不需要网络以外的前提）：
                    //   · Core.Source 还停在旧文档 → 走「用缓存前缀直打却落到不认识的页面」→ **删掉已存前缀**，
                    //     并告诉用户「入口地址已失效」——真正的故障是网络；
                    //   · 失败目标本身是 /https/<hex>/student/… 时，地址形状照样命中 → 谎报「已进入教务系统」。
                    // Android 的 onReceivedError 就拦在这一层，PC 之前漏了。
                    Log($"onNavigationCompleted 失败：{url}（{e.WebErrorStatus}）");
                    Alert("网络不通，请检查后重试", NoticeKind.Retry);
                    return;
                }
                var action = Flow.OnDocumentFinished(url);
                Log($"onNavigationCompleted {url} -> {action}");
                Run(action);
                ApplyPagePrefs(url);
            }
            catch (Exception ex)
            {
                // 导航完成是最外层入口（WebView2 的回调）：这里漏出去的异常会直接终止进程
                Log($"处理导航完成时出错：{ex.GetType().Name} {ex.Message}");
                Alert("页面处理出错，请刷新后重试", NoticeKind.Retry);
            }
        };
        Core.WebMessageReceived += (_, e) => OnWebMessage(e);
        Core.ServerCertificateErrorDetected += (_, e) =>
        {
            // 登录凭据不能经过证书无效的连接：**一律取消，且不提供绕过入口**。
            // Android 的 `onReceivedSslError`（handler.cancel()）是同一件事——
            // APP-UX §5 的「证书」行两端都要成立。
            Log($"证书校验失败，已取消：{e.RequestUri}（{e.ErrorStatus}）");
            e.Action = Microsoft.Web.WebView2.Core.CoreWebView2ServerCertificateErrorAction.Cancel;
            Alert("证书校验失败，已停止连接");
        };
        Core.NewWindowRequested += (_, e) =>
        {
            // 站点用 window.open / target=_blank 新开页面：在当前窗口里打开，保住返回栈。
            // PC 端按 pc/README 的清单就是单窗口；教务系统的新开页在当前页继续浏览。
            e.Handled = true;
            if (!string.IsNullOrEmpty(e.Uri)) Core.Navigate(e.Uri);
            Log($"站点新开窗口 → 当前窗口打开 {e.Uri}");
        };
        Core.DocumentTitleChanged += (_, _) =>
        {
            if (!string.IsNullOrWhiteSpace(Core.DocumentTitle)) ViewTitleChanged?.Invoke(Core.DocumentTitle);
        };
        Core.ProcessFailed += (_, e) =>
        {
            // 网页进程（渲染进程）被系统回收：整页变白，而且**不会**来 NavigationCompleted——
            // 状态机会以为还停在原来那份文档上（停手标志、文档序号全保持旧值），界面也没有任何出口。
            // Android 的 onRenderProcessGone 是同一件事。
            Log($"WebView2 进程失败：{e.ProcessFailedKind}（{e.Reason}）");
            try
            {
                switch (e.ProcessFailedKind)
                {
                    case Microsoft.Web.WebView2.Core.CoreWebView2ProcessFailedKind.RenderProcessExited:
                    case Microsoft.Web.WebView2.Core.CoreWebView2ProcessFailedKind.RenderProcessUnresponsive:
                        // 这两类 WebView2 会自己重建渲染进程，重载一次就回到可用状态
                        Alert("页面被系统回收了，正在重新加载", NoticeKind.Retry);
                        Core.Reload();
                        break;
                    default:
                        // 浏览器进程 / GPU / 工具进程退出：WebView2 自己会处置，记一条日志即可
                        break;
                }
            }
            catch (Exception ex)
            {
                Log($"处置进程失败时出错：{ex.GetType().Name} {ex.Message}");
                Alert("页面已失效，请点「重试」", NoticeKind.Retry);
            }
        };

        _ = Core.AddScriptToExecuteOnDocumentCreatedAsync(ScriptBag.EntryShim);
        Ready?.Invoke();
    }

    /// <summary>窗口标题跟页面走。</summary>
    public event Action<string>? ViewTitleChanged;

    // ---------------------------------------------------------------- 界面动作

    public void EnterFromHome(Sues.Entry entry)
    {
        settings.SaveDecided = true;
        settings.SaveAccount = SaveAccount;
        SaveSettings("同意保存账号");
        Home = false;
        OpenEntry(entry);
    }

    public void OpenHome()
    {
        Home = true;
        RaiseChanged();
    }

    public void OpenEntry(Sues.Entry entry)
    {
        ActiveEntry = entry;
        Flow.Start(entry, settings.Prefix != null);
        ResetRuntime();
        // APP-UX §5「打开」行：这一跳可能几百毫秒，先说一句正在打开哪个入口
        ShowNotice(new NoticeState
        {
            Text = entry == Sues.Entry.Webvpn ? "正在打开校园网关…" : "正在打开教务系统…",
        });
        var url = Sues.EntryUrl(settings.Prefix, entry);
        Log($"打开入口={entry} 落点={url}");
        Core.Navigate(url);
        RaiseChanged();
    }

    public void GoBack()
    {
        if (Core.CanGoBack) Core.GoBack();
    }

    /// <summary>前进（PC 工具栏 / Alt+→ / 鼠标侧键都用它）。</summary>
    public void GoForward()
    {
        if (Core.CanGoForward) Core.GoForward();
    }

    public void Reload() => Core.Reload();

    public void ChangeSaveAccount(bool on)
    {
        SaveAccount = on;
        // 只改意愿，不写「已决定」：首页是否出现取决于用户有没有真的进去过（见 EnterFromHome）
        settings.SaveAccount = on;
        SaveSettings("自动登录意愿");
        if (!on)
        {
            DropPending();
            ShowNotice(new NoticeState { Text = "已关闭自动登录；已保存的账号还在本机，可以随时清除" });
        }
        RaiseChanged();
    }

    public void ChangeHideNotices(bool on)
    {
        HideNotices = on;
        settings.HideNotices = on;
        settings.Save();
        tweakedDoc = -1;
        Guarded("收起/恢复公告弹窗", "通知公告没能" + (on ? "收起" : "恢复") + "，请刷新后重试", async () =>
        {
            var result = await Eval(ScriptBag.NoticeDialogJs(on));
            Log($"通知公告：{(on ? "收起" : "恢复")} -> {result}");
        });
        RaiseChanged();
    }

    public void ClearAccount()
    {
        repository.Clear();
        SavedUsername = null;
        ShowNotice(new NoticeState { Text = "已清除账号", Tone = NoticeState.ToneKind.Done });
        RaiseChanged();
    }

    /// <summary>清除缓存、退出登录：清 cookie（登录状态就是 cookie），保留已保存的账号密码。</summary>
    public void ClearSession() => Guarded("退出登录", "退出登录没能完成，请重试", async () =>
    {
        ResetRuntime();
        await ClearCookiesAsync();
        OpenEntry(ActiveEntry);
        ShowNotice(new NoticeState { Text = "已退出登录；保存的账号还在", Tone = NoticeState.ToneKind.Done });
        RaiseChanged();
    });

    /// <summary>改用其他账号：清掉会话和本机凭据，回首页重新走一遍。</summary>
    public void SwitchAccount() => Guarded("改用其他账号", "改用其他账号没能完成，请重试", async () =>
    {
        repository.Clear();
        SavedUsername = null;
        ResetRuntime();
        await ClearCookiesAsync();
        Flow.Start(ActiveEntry, hasCachedPrefix: false);
        Home = true;
        RaiseChanged();
    });

    /// <summary>
    /// 删光 cookie 并等到真的删完再继续：否则紧接着那次导航会带着旧 cookie 出去，
    /// 用户看到的就是「点了退出却还是登录状态」。DeleteAllCookies 不带完成回调，
    /// 用「再查一次清单」确认，有上界，不空转。
    /// </summary>
    private async Task ClearCookiesAsync()
    {
        Core.CookieManager.DeleteAllCookies();
        for (var i = 0; i < 20; i++)
        {
            if ((await Core.CookieManager.GetCookiesAsync(null)).Count == 0) return;
            await Task.Delay(50);
        }
        Log("cookie 清理 1 秒内没有确认完成，继续执行（WebView2 的删除在后台进行）");
    }

    public void OnNoticeAction()
    {
        switch (Notice.Kind)
        {
            case NoticeKind.Retry:
                Core.Reload();
                break;
            case NoticeKind.UndoSave:
                repository.Clear();
                SavedUsername = null;
                ChangeSaveAccount(false);
                ShowNotice(new NoticeState { Text = "已撤销保存", Tone = NoticeState.ToneKind.Done });
                break;
            case NoticeKind.ClearAccount:
                // 与「撤销保存」同一套动作：清掉本机凭据并关掉自动登录
                repository.Clear();
                SavedUsername = null;
                ChangeSaveAccount(false);
                ShowNotice(new NoticeState { Text = "已清除账号", Tone = NoticeState.ToneKind.Done });
                break;
        }
        RaiseChanged();
    }

    // ---------------------------------------------------------------- 状态机的动作

    private void Run(EntryFlow.Action action)
    {
        switch (action)
        {
            case EntryFlow.Action.Nothing:
                break;
            case EntryFlow.Action.InspectCas:
                InspectCas();
                break;
            case EntryFlow.Action.AssistCas:
                AssistCas();
                break;
            case EntryFlow.Action.SkipExpired:
                SkipExpired();
                break;
            case EntryFlow.Action.RejectCredentials:
                RejectCredentials();
                break;
            case EntryFlow.Action.Transient:
                OnTransient();
                break;
            case EntryFlow.Action.Settle:
                Settle();
                break;
            case EntryFlow.Action.ClearPrefix:
                ClearPrefix();
                break;
            case EntryFlow.Action.SecondLogin:
                Alert("这里还要再登录一次，请手动");
                break;
            case EntryFlow.Action.ProbePortal:
                Probe();
                break;
            case EntryFlow.Action.VerifyArrival:
                VerifyArrival();
                break;
        }
    }

    /// <summary>
    /// 停手前的最后一道判据：**正文**里有没有「确实登录进去了」的标记（CORE-SPEC §2）。
    /// URL 落在门户主机只说明「到过」——换票中转页、门户自己的错误页都满足它。
    /// 确认不了就**不宣布到达**（也不清待判决、不落盘凭据），只留一条状态。
    /// </summary>
    private void VerifyArrival() => Guarded("确认到达目的地", "页面没能确认，请手动继续", async () =>
    {
        var mark = Sues.ArrivalMark(await Eval(ScriptBag.Arrival));
        if (mark == null)
        {
            Log($"门户页正文没有登录成功的标记，暂不算到达：{Core.Source}");
            ShowNotice(new NoticeState { Text = "正在等待门户加载完成…" });
            return;
        }
        Log($"门户页正文确认到达（标记={mark}）");
        Run(Flow.ConfirmArrival());
    });

    private void InspectCas() => Guarded("读取认证页状态", "自动登录没能继续，请手动登录", async () =>
    {
        var url = Core.Source;
        var raw = await Eval(ScriptBag.CasState);
        if (!Sues.SamePage(url, Core.Source)) return;
        var seen = Sues.CasObservationFrom(raw);
        Log($"认证页：过期={seen.Expired} 表单={seen.HasForm} 滑块={seen.HasCaptcha} 提示={Truncate(seen.Prompt, 80)}");
        lastPrompt = seen.Prompt;
        Run(Flow.OnCasObserved(seen));
    });

    /// <summary>
    /// 认证页上该做的辅助：勾「记住我」、装监视器、（用户已同意且已存凭据时）填写并提交一次。
    /// 自动填写是唯一一处「替用户提交凭据」的地方，边界与 Android 端一致。
    /// </summary>
    private void AssistCas() => Guarded("自动填写并提交", "自动登录没能继续，请手动登录", async () =>
    {
        // §6.1 的第一道闸：只有**学校的**统一身份认证页才允许被辅助。
        // 网关把它改写的第三方页面、教务系统自己的 CAS 形态登录页，路径里同样有 /cas/login；
        // 主机判据在这里一次把关，后面所有「碰凭据」的动作就不必各判一遍。
        if (!Sues.IsCredentialPage(Core.Source))
        {
            Log($"这一页不是学校的统一身份认证页，不动它：{Core.Source}");
            return;
        }
        EvalQuietly("勾记住我", ScriptBag.TickNotice);
        EvalQuietly("装滑块监视器", ScriptBag.CaptchaWatch);
        if (SaveAccount) EvalQuietly("装凭据监视器", ScriptBag.CredentialWatch);

        var doc = Flow.DocumentOrdinal;
        if (filledDoc == doc) return;
        if (!SaveAccount)
        {
            ShowNotice(new NoticeState { Text = "本次登录不会保存账号", Sticky = true });
            return;
        }
        if (autoSubmits >= AutoSubmitMax)
        {
            // 不是重试，是硬上限：连续替用户提交只会消耗失败次数（5 次锁号）
            Log($"自动提交已达上限 {autoSubmits} 次，交回用户");
            ShowNotice(new NoticeState { Text = "自动登录没有成功，请手动登录", Sticky = true });
            return;
        }
        // 解密（DPAPI）不占界面线程：这是两端一致的规则（Android 用后台线程 + 回主线程）
        using var credential = await Task.Run(() => repository.Load());
        if (credential == null)
        {
            ShowNotice(new NoticeState { Text = "登录一次，之后自动登录", Sticky = true });
            return;
        }
        filledDoc = doc;
        autoSubmits++;
        // 判决标志先置上：提交的回应是另一份文档（docs/PROTOCOL.md §6）。页面上真没表单时再作废。
        Flow.OnAutoSubmitted();
        ShowNotice(new NoticeState { Text = "正在自动填写账号…" });
        var password = new string(credential.Password);
        var result = await Eval(ScriptBag.FillAndSubmitJs(credential.Username, password));
        Log($"自动填写并提交：{result}");
        if (result.Contains("noform") || result.Contains("nobutton"))
        {
            // 页面上没有可填的表单：撤销标记，交给用户
            filledDoc = -1;
            autoSubmits--;
            Flow.OnAutoSubmitAborted();
            ShowNotice(new NoticeState { Text = "这一页要你手动登录", Sticky = true });
        }
    });

    private void SkipExpired()
    {
        EvalQuietly("停滑块监视器", ScriptBag.CaptchaStop);
        if (expiredSkips >= ExpiredMaxSkips)
        {
            Log($"密码已过期：跳过 {expiredSkips} 次后仍回到这一页，停手");
            Alert("密码已过期，请点页面上的「点击跳过」继续");
            return;
        }
        expiredSkips++;
        ShowNotice(new NoticeState { Text = "密码已过期，正在跳过…" });
        Guarded("跳过密码过期提示", "跳过密码过期提示没能完成，请点页面上的「点击跳过」", async () =>
        {
            var result = await Eval(ScriptBag.SkipExpired);
            Log($"跳过密码过期提示：{result}（第 {expiredSkips} 次）");
        });
    }

    /// <summary>
    /// 服务端否定了凭据：立刻停手，不重试。归因看待判决标志（提交的回应是另一份文档）。
    /// 归因给已存凭据时删凭据并关闭自动登录；用户手动输错时监视器重新装上，改对再登一次就应被捕获。
    /// </summary>
    private void RejectCredentials()
    {
        autoStopped = true;
        StopProbeTimer();
        CancelTransient();
        CancelArmed();
        EvalQuietly("停滑块监视器", ScriptBag.CaptchaStop);
        DropPending();

        var usedSaved = Flow.ConsumeAutoVerdict();
        if (usedSaved)
        {
            repository.Clear();
            SavedUsername = null;
            ChangeSaveAccount(false);
            Log("已存凭据被服务端否定，已删除并关闭自动登录");
        }
        if (SaveAccount)
        {
            // 用户手动输错：监视器继续留着，改对的那次提交照样捕获
            EvalQuietly("装凭据监视器", ScriptBag.CredentialWatch);
        }
        else
        {
            EvalQuietly("停凭据监视器", ScriptBag.CredentialStop);
        }
        var remaining = Sues.LockoutRemaining(lastPrompt);
        Log($"凭据被否定（来自已存凭据={usedSaved}，剩余={remaining?.ToString() ?? "未说明"}），停手");
        // 文案分两段：先说是哪种否定，再按 APP-UX §5「剩余次数」那行**追加**次数信息。
        // 措辞规则（含 N ≤ 1 的改口）在 Sues.RemainingClause 里，能被单测钉住。
        var head = usedSaved ? "保存的账号已失效，请手动登录" : "账号或密码不对，请手动登录";
        var tail = Sues.RemainingClause(remaining) ?? "";
        // 动作也照 APP-UX §5 的「是否可点」列：用已存凭据 →「清除账号」，手动输错 →「重试」
        Alert(head + tail, usedSaved ? NoticeKind.ClearAccount : NoticeKind.Retry);
    }

    private void Settle()
    {
        CancelTransient();
        var captured = pending;
        pending = null;
        CancelPending();
        if (captured == null)
        {
            Log($"已到目的地，停手：{Core.Source}");
            ShowNotice(new NoticeState { Text = "已进入教务系统", Tone = NoticeState.ToneKind.Done });
            return;
        }
        // 加解密 + 落盘挪到线程池：界面线程不做 IO（两端一致的规则）
        Guarded("保存账号", "账号没能保存，请重试", async () =>
        {
            bool saved;
            try
            {
                saved = await Task.Run(() => repository.Save(captured.Username, captured.Password));
            }
            finally
            {
                captured.Clear();
            }
            SavedUsername = saved ? captured.Username : null;
            Log($"登录成功，保存账号={Mask(captured.Username)} 落盘={saved}");
            ShowNotice(new NoticeState
            {
                Text = saved ? "已记住账号，下次自动登录" : "账号没能保存，请重试",
                Tone = saved ? NoticeState.ToneKind.Done : NoticeState.ToneKind.Alert,
                Sticky = !saved,
                Kind = saved ? NoticeKind.UndoSave : NoticeKind.None,
            });
        });
    }

    private void ClearPrefix()
    {
        settings.Prefix = null;
        var saved = settings.Save();
        Log(saved ? "前缀已清除并落盘" : "前缀已在内存里清除，但没能写盘（磁盘或权限问题）");
        // 措辞必须与事实一致：没写成功就不能说「已清除记录」（下次启动还会拿旧的）
        Alert(saved
                ? "入口地址已失效，已清除记录；请点「教务系统」重新进入"
                : "入口地址已失效；但清除记录没能写入本机（磁盘或权限问题），下次启动仍会用旧地址");
    }

    /// <summary>
    /// 偏好落盘，失败只记日志、不打扰用户：这些都是「下次启动更好」的偏好，
    /// 本次会话的内存状态照常有效。**但绝不静默**——run.log 里必须留得下痕迹。
    /// </summary>
    private void SaveSettings(string what)
    {
        if (!settings.Save()) Log($"{what}：偏好没能写盘（磁盘或权限问题），本次会话仍有效");
    }

    private void OnTransient()
    {
        ShowNotice(new NoticeState { Text = "正在跳转…" });
        if (transientTick != null || transientReloads >= TransientMaxReloads) return;
        transientTick = PostDelayed(TransientTimeoutMs, () =>
        {
            transientTick = null;
            if (Sues.IsTransientPage(Core.Source))
            {
                transientReloads++;
                Log("中转页停留超时，重载一次");
                Core.Reload();
            }
        });
    }

    // ---------------------------------------------------------------- 探索门户

    private void Probe() => Guarded("探测门户入口", "没能读到入口地址，请自行点击", async () =>
    {
        var url = Core.Source;
        var raw = await Eval(ScriptBag.Probe);
        if (!Sues.SamePage(url, Core.Source)) return;
        var prefix = Sues.PrefixFrom(Sues.ProbeHref(raw), url);
        if (prefix == null)
        {
            // 「还要不要再探一发」由状态机说了算，宿主只排定时器。
            // 上限的账本与判据在同一层（EntryFlow），所以它能被单测钉住。
            if (Flow.OnProbeMissed(url))
            {
                StopProbeTimer();
                probeTick = PostDelayed(ProbeIntervalMs, () => { probeTick = null; Probe(); });
            }
            else
            {
                Log($"门户探测已达上限 {EntryFlow.ProbeMaxAttempts} 发，交回用户");
                Alert("没在门户里找到教务系统入口，请自行点击");
            }
            return;
        }
        settings.Prefix = prefix;
        SaveSettings("网关前缀");
        Log($"读到教务系统前缀={prefix}");
        Core.Navigate(prefix + Sues.SsoPath);
    });

    // ---------------------------------------------------------------- 滑块

    private void OnArmed(bool armed, bool expectsSlide)
    {
        if (autoStopped) return;
        if (armed)
        {
            // armed=true 的含义就是「这一页的滑块归应用管」，两种文档形态都会到这里：
            //   · 「独立滑动文档」（没有 #password）一渲染出 .ap-container 就 armed；
            //   · 「表单与滑块同页」在**真实 submit** 之后 armed（页面脚本监听 submit，不轮询）。
            // 早先这里额外要求 expectsSlide——而它表示「这份文档没有密码框」，于是同页那一形态
            // 提交后两个分支都不命中：不拖、不提示、不超时，`captchaAttempts` 永不增长。
            // 判据只有一个：armed。expectsSlide 留下来只做诊断（日志一眼看出当前是哪种形态）。
            if (captchaAttempts >= CaptchaMaxAttempts)
            {
                // 预算已经用尽：不要再宣称「正在自动完成安全验证…」——那是句谎话
                if (!captchaGaveUp)
                {
                    captchaGaveUp = true;
                    Alert("自动验证已达上限，请手动拖动");
                }
                return;
            }
            Log($"接管滑块（同页表单={!expectsSlide}，已拖 {captchaAttempts} 次）");
            ShowNotice(new NoticeState { Text = "正在自动完成安全验证…", Sticky = true });
            CancelArmed();
            armedTick = PostDelayed(ArmedTimeoutMs, () =>
            {
                armedTick = null;
                Alert("验证没能自动完成，请手动拖动");
            });
        }
        else
        {
            // 只撤超时定时器，不清状态行：监视器第一次上报必然是 armed=false
            //（页面有密码框、还没提交），把它当成「收起提示」会把「登录一次，之后
            // 自动登录」这类本该留下的提示在 400ms 内擦掉。提示由后续的判决来替换，
            // 滑块监视器不拥有状态行。
            CancelArmed();
        }
    }

    private void OnCaptcha(string background, string slider)
    {
        var id = background + "|" + slider;
        if (id == captchaLastId) return;
        captchaLastId = id;
        if (captchaAttempts >= CaptchaMaxAttempts)
        {
            // 用尽后换新图也不能装作没事：明确交回用户一次（只说一次）
            if (!captchaGaveUp)
            {
                captchaGaveUp = true;
                dispatcher.BeginInvoke(() => Alert("自动验证已达上限，请手动拖动"));
            }
            return;
        }
        _ = Task.Run(() =>
        {
            var bg = DecodeDataUrl(background);
            var sl = DecodeDataUrl(slider);
            try
            {
                if (bg == null || sl == null) return;
                var x = SliderSolver.Solve(Pixels(bg), bg.Width, bg.Height, Pixels(sl), sl.Width, sl.Height);
                if (x == null)
                {
                    dispatcher.BeginInvoke(() => Alert("验证没能自动完成，请手动拖动"));
                    return;
                }
                dispatcher.BeginInvoke(() => { if (!autoStopped) DragTo(x.Value); });
            }
            finally
            {
                bg?.Dispose();
                sl?.Dispose();
            }
        });
    }

    private void DragTo(int x) => Guarded("自动拖动滑块", "验证没能自动完成，请手动拖动", async () =>
    {
        var raw = await Eval(ScriptBag.SliderGeometry);
        switch (SliderDrag.ParseProbe(raw))
        {
            case SliderDrag.Probe.Failed failed:
                Log($"量不到滑块几何：{failed.Reason}");
                Alert("验证没能自动完成，请手动拖动");
                break;
            case SliderDrag.Probe.Ready ready:
                var geometry = ready.Geometry;
                var plan = SliderDrag.MakePlan(x, geometry);
                if (plan == null)
                {
                    Log($"换算不出光标位置：缺口={x} 几何={geometry}");
                    Alert("验证没能自动完成，请手动拖动");
                    return;
                }
                captchaAttempts++;
                CancelArmed();
                Log($"缺口={x} 光标={plan.Cursor}（当前 {geometry.CursorNow}）预计提交={plan.Submitted}" +
                    $" 位移={plan.Delta} 滑轨={geometry.SlidingScope} 值域={geometry.CutScope}" +
                    $" 容器宽={geometry.ContainerWidth} 图宽={geometry.BackgroundWidth}" +
                    $" 一致={geometry.ContainerMatchesImage}");
                var result = await Eval(ScriptBag.DragJs(plan));
                Log($"拖动结果={result}（第 {captchaAttempts} 次）");
                break;
        }
    });

    // ---------------------------------------------------------------- 凭据捕获

    /// <summary>用户在官方页面上按下登录，页面把值交了过来。是否接受由这里决定（双重校验）。</summary>
    private void OnCredentialCaptured(string username, string password)
    {
        // 第二重校验（第一重是同意与否）：**当前文档必须真的是学校的统一身份认证页**。
        // 页面侧的监视器只装在那种页面上，但这一条不能只靠页面侧——页面脚本可以主动伪造一次提交。
        if (!Sues.IsCredentialPage(Core.Source))
        {
            Log($"当前文档不是学校的统一身份认证页，丢弃抓到的凭据：{Core.Source}");
            return;
        }
        if (!SaveAccount)
        {
            Log("用户未同意保存账号，丢弃抓到的凭据");
            return;
        }
        if (filledDoc == Flow.DocumentOrdinal)
        {
            Log("这次提交是应用自己填的，不必重复保存");
            return;
        }
        if (string.IsNullOrWhiteSpace(username) || password.Length == 0) return;

        // 用户本人的提交：此后服务端的判决不再属于应用那次自动提交
        Flow.OnUserSubmitted();
        DropPending();
        pending = new Credential(username, password.ToCharArray());
        CancelPending();
        pendingTick = PostDelayed(PendingTimeoutMs, () =>
        {
            pendingTick = null;
            Log($"抓到的凭据 {PendingTimeoutMs / 1000} 秒内没有定局，丢弃");
            DropPending();
        });
        Log($"抓到账号={Mask(username)}，等登录结果再决定是否保存");
    }

    private void DropPending()
    {
        CancelPending();
        pending?.Clear();
        pending = null;
    }

    /// <summary>日志与界面上的账号一律打码。</summary>
    private static string Mask(string username) =>
            username.Length <= 4 ? "****" : username[..4] + "****";

    // ---------------------------------------------------------------- 页面显示偏好

    /// <summary>只在教务系统里生效：认证页、门户页上一律不动（登录流程里不多添变量）。</summary>
    private void ApplyPagePrefs(string url)
    {
        if (!HideNotices || !Sues.IsJxfwPage(url)) return;
        if (tweakedDoc == Flow.DocumentOrdinal) return;
        tweakedDoc = Flow.DocumentOrdinal;
        EvalQuietly("收起公告弹窗", ScriptBag.NoticeDialogJs(true), r => Log($"收起公告弹窗：{r}"));
    }

    // ---------------------------------------------------------------- 消息与脚本

    private void OnWebMessage(Microsoft.Web.WebView2.Core.CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            var root = doc.RootElement;
            var cmd = root.TryGetProperty("cmd", out var c) ? c.GetString() : null;
            switch (cmd)
            {
                case "armed":
                    OnArmed(root.GetProperty("armed").GetBoolean(),
                            root.GetProperty("expectsSlide").GetBoolean());
                    break;
                case "captcha":
                    OnCaptcha(root.GetProperty("bg").GetString() ?? "",
                            root.GetProperty("sl").GetString() ?? "");
                    break;
                case "credential":
                    OnCredentialCaptured(root.GetProperty("username").GetString() ?? "",
                            root.GetProperty("password").GetString() ?? "");
                    break;
                case "log":
                    Log(root.GetProperty("message").GetString() ?? "");
                    break;
            }
        }
        catch (Exception ex)
        {
            Log($"页面消息解析失败：{ex.Message}");
        }
    }

    /// <summary>
    /// 跑一段异步动作，把异常变成「一条日志 + 一条用户提示」，而不是让进程崩掉。
    /// </summary>
    /// <remarks>
    /// 为什么必须有它：这些动作全部由 WebView2 的回调直接触发（导航完成、页面消息），而回调是
    /// <c>async void</c>——里面的异常会直接冒到 Dispatcher 的未处理异常上，**一次网络抖动或
    /// WebView2 被销毁就能终止整个进程**。Android 各回调里的 try/catch 是同一件事；
    /// 这里是 PC 侧的对应物，只是集中在一处，不在每个入口重复写。
    /// </remarks>
    private async void Guarded(string what, string userText, Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (Exception e)
        {
            Log($"{what}失败：{e.GetType().Name} {e.Message}");
            Alert(userText);
        }
    }

    /// <summary>
    /// 执行一段「装了就好、失败不改变用户下一步」的脚本（勾记住我、装/停监视器、收起公告弹窗）。
    /// 用户看不到差别，但日志里必须留痕——不静默吞掉，也不拿它去打扰用户。
    /// </summary>
    private async void EvalQuietly(string what, string script, Action<string>? with = null)
    {
        try
        {
            var value = await Eval(script);
            with?.Invoke(value);
        }
        catch (Exception e)
        {
            Log($"{what}失败：{e.GetType().Name} {e.Message}");
        }
    }

    /// <summary>执行脚本并把 JSON 编码的回传值解回字符串。</summary>
    private async Task<string> Eval(string script)
    {
        var json = await Core.ExecuteScriptAsync(script);
        return Unquote(json) ?? "";
    }

    private static string? Unquote(string? json)
    {
        if (string.IsNullOrEmpty(json)) return json;
        var t = json.Trim();
        if (!t.StartsWith('"')) return t;
        try
        {
            return JsonDocument.Parse(t).RootElement.GetString();
        }
        catch (JsonException)
        {
            return t.Trim('"');
        }
    }

    private static Bitmap? DecodeDataUrl(string dataUrl)
    {
        try
        {
            var b64 = dataUrl.StartsWith("data:", StringComparison.Ordinal)
                    ? (dataUrl.Contains(',') ? dataUrl[(dataUrl.IndexOf(',') + 1)..] : "")
                    : dataUrl;
            if (b64.Length == 0) return null;
            var bytes = Convert.FromBase64String(b64);
            using var ms = new MemoryStream(bytes);
            // GDI+ 的 PNG 解码是直通 alpha（不预乘），与 Android inPremultiplied=false 对齐
            return new Bitmap(ms);
        }
        catch (Exception e)
        {
            Log($"验证码图片解码失败：{e.Message}");
            return null;
        }
    }

    private static int[] Pixels(Bitmap bitmap)
    {
        var rect = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, System.Drawing.Imaging.ImageLockMode.ReadOnly,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        try
        {
            var pixels = new int[bitmap.Width * bitmap.Height];
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
            return pixels;
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }

    // ---------------------------------------------------------------- 计时器与通知

    private void ResetRuntime()
    {
        StopProbeTimer();
        CancelTransient();
        CancelArmed();
        captchaAttempts = 0;
        captchaLastId = null;
        captchaGaveUp = false;
        transientReloads = 0;
        expiredSkips = 0;
        autoStopped = false;
        autoSubmits = 0;
        lastPrompt = "";
        filledDoc = -1;
        tweakedDoc = -1;
    }

    private DispatcherTimer PostDelayed(int ms, Action action)
    {
        var timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(ms),
        };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            action();
        };
        timer.Start();
        return timer;
    }

    /// <summary>
    /// 只停探测定时器，<b>不碰重试计数</b>——计数在 <see cref="EntryFlow"/> 里，由状态机按 URL 自己管。
    /// </summary>
    /// <remarks>
    /// 2026-09-20 修：早先这里把「停定时器」与「清计数」合成一个 <c>CancelProbe()</c>，重试路径顺手
    /// 调用了它，于是计数每轮被清零、15 发的上限永远到不了，探测变成无限循环且"没找到入口"的提示
    /// 成了死代码。根因是职责混装 + 宿主层没有测试；现在两件事分开，账本住在可单测的状态机里。
    /// </remarks>
    private void StopProbeTimer()
    {
        probeTick?.Stop();
        probeTick = null;
    }

    private void CancelTransient()
    {
        transientTick?.Stop();
        transientTick = null;
    }

    private void CancelArmed()
    {
        armedTick?.Stop();
        armedTick = null;
    }

    private void CancelPending()
    {
        pendingTick?.Stop();
        pendingTick = null;
    }

    private void Alert(string text) => ShowNotice(new NoticeState
    {
        Text = text,
        Tone = NoticeState.ToneKind.Alert,
        Sticky = true,
    });

    /// <summary>
    /// 带一个可点动作的告警。APP-UX §5 的状态文案表里「是否可点」那一列就是它：
    /// 断网 → 「重试」，密码错（用已存凭据）→ 「清除账号」。
    /// </summary>
    private void Alert(string text, NoticeKind kind) => ShowNotice(new NoticeState
    {
        Text = text,
        Tone = NoticeState.ToneKind.Alert,
        Sticky = true,
        Kind = kind,
    });

    private void ShowNotice(NoticeState value)
    {
        noticeTick?.Stop();
        noticeTick = null;
        Notice = value;
        if (value.Text.Length > 0 && !value.Sticky)
        {
            noticeTick = PostDelayed(NoticeTimeoutMs, () =>
            {
                noticeTick = null;
                Notice = new NoticeState();
                RaiseChanged();
            });
        }
        RaiseChanged();
    }

    private static string Truncate(string s, int n) => s.Length <= n ? s : s[..n];

    /// <summary>日志同时进调试输出与 run.log（用户报障时把这一个文件发过来就够）。</summary>
    private static void Log(string message)
    {
        var line = $"[{Tag}] {message}";
        System.Diagnostics.Debug.WriteLine(line);
        try
        {
            lock (Tag)
            {
                Directory.CreateDirectory(EntrySettings.DirectoryPath);
                File.AppendAllText(Path.Combine(EntrySettings.DirectoryPath, "run.log"),
                        $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}");
            }
        }
        catch
        {
            // 日志写不动（磁盘满/权限）不影响主流程
        }
    }

    public void Dispose()
    {
        DropPending();
        ResetRuntime();
        noticeTick?.Stop();
        View.Dispose();
    }
}





