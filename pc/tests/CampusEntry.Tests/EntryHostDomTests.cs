using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using CampusEntry.Core;
using Microsoft.Web.WebView2.Core;
using Xunit;

namespace CampusEntry.Tests;

/// <summary>
/// PC 端**宿主层**测试（2026-09 审计的 A9：这一层原先三端零覆盖；Android 侧的对应物是
/// `EntryHostDomTest`，iOS 侧没有——本机没有 macOS）。
///
/// 测的不是判据对不对（那是 `SuesTests` / `EntryFlowTests` 的事），而是**判据有没有被接上**：
/// 导航回调 → 状态机 → 宿主效果（状态行、自动填写）。Android 侧就是靠这一层查出两个真实缺陷
/// （初始 `about:blank` 被当成一份文档、判据读控件的实时属性）。
///
/// 三个关键手法：
///   · **STA + Dispatcher + 离屏窗口**：WPF 的 `WebView2` 是 `HwndHost`，必须有真实 HWND 与消息泵；
///     全部 WebView2 调用都跑在同一个 UI 线程上，测试方法本身是 `async`（不在 UI 线程上阻塞等待）。
///   · **请求拦截**（`WebResourceRequested` + 过滤器）把真实学校 URL 的响应换成本地造的那一页：
///     于是 `Source` 是**真实的学校地址**（判据能正常判），而**一点网络流量都不产生**。
///     这是 WebView2 的一等公民 API，不是补丁。
///   · 临时目录 + 独立的 `EntrySettings.DataDirectory`：绝不碰用户真实的 `entry.json` / 凭据。
///     （宿主的诊断日志仍写真实目录的 `run.log`——那是应用自己的日志，与应用运行时无异。）
/// </summary>
[Collection("WPF-STA")]
public sealed class EntryHostDomTests : IDisposable
{
    private const string PortalHost = "https://webvpn.sues.edu.cn";
    private const string JxfwHost = "https://jxfw.sues.edu.cn";

    /// <summary>照实测形态写：`fill-and-submit.js` 找的是 `input.login_btn, button.login_btn`。</summary>
    private const string CasForm = """
        <html><body><form action="#">
          <input id="username" name="username">
          <input id="password" name="password" type="password">
          <input class="login_btn" type="button" value="登 录">
        </form></body></html>
        """;

    private readonly string dataDir =
            Path.Combine(Path.GetTempPath(), "campus-entry-host-tests", Guid.NewGuid().ToString("N"));

    private readonly ManualResetEventSlim ready = new();
    private readonly CredentialRepository repository;

    private Dispatcher dispatcher = null!;
    private Window window = null!;
    private EntryHost host = null!;
    private string? initializationFailure;

    /// <summary>下一次请求要回给页面的 HTML（拦截器照这个答复）。</summary>
    private string servedHtml = "<html><body>空</body></html>";

    public EntryHostDomTests()
    {
        var started = new ManualResetEventSlim();

        var uiThread = new Thread(() =>
        {
            dispatcher = Dispatcher.CurrentDispatcher;
            // 离屏：位置在屏幕外，不进任务栏、不抢焦点。窗口必须真的 Show 过，WebView2 才有 HWND。
            window = new Window
            {
                Left = -4000,
                Top = -4000,
                Width = 900,
                Height = 650,
                ShowInTaskbar = false,
                ShowActivated = false,
                WindowStyle = WindowStyle.None,
            };
            window.Show();
            started.Set();
            Dispatcher.Run();
        })
        { IsBackground = true };
        uiThread.SetApartmentState(ApartmentState.STA);
        uiThread.Start();
        Assert.True(started.Wait(TimeSpan.FromSeconds(15)), "STA/Dispatcher 线程没起来");

        Directory.CreateDirectory(dataDir);
        PurgeStaleDataDirectories(dataDir);
        var settings = new EntrySettings { DataDirectory = dataDir };
        repository = new CredentialRepository(dataDir, new CredentialStore(new DpapiCryptoBackend()));

        // WebView2 要求 **STA**（xunit 的测试线程是 MTA，直接在这里 CreateAsync 会得到
        // RPC_E_CHANGED_MODE "无法在设置线程模式后对其加以更改"），所以环境与宿主**都在 STA 线程上建**：
        // 测试线程只负责阻塞等待，STA 线程自己的消息泵照常转。
        //
        // 拦截器**必须等初始化成功之后再装**：`View.CoreWebView2` 在初始化完成前是 null，
        // 早先在这里直接订阅就得到一个 NullReferenceException（四个用例齐刷刷在构造函数里失败）。
        var interceptorsReady = new ManualResetEventSlim();
        dispatcher.InvokeAsync(async () =>
        {
            var environment = await CoreWebView2Environment
                    .CreateAsync(userDataFolder: Path.Combine(dataDir, "WebView2"));

            host = new EntryHost(settings, repository, environment);
            host.Ready += () => ready.Set();
            host.InitializationFailed += reason => initializationFailure = reason;
            host.View.CoreWebView2InitializationCompleted += (_, e) =>
            {
                if (!e.IsSuccess)
                {
                    initializationFailure = e.InitializationException?.Message ?? "未知";
                    return;
                }
                var core = host.View.CoreWebView2;
                core.WebResourceRequested += OnWebResourceRequested;
                core.AddWebResourceRequestedFilter(PortalHost + "/*", CoreWebView2WebResourceContext.All);
                core.AddWebResourceRequestedFilter(JxfwHost + "/*", CoreWebView2WebResourceContext.All);
                interceptorsReady.Set();
            };
            window.Content = host.View;
        }).Task.Unwrap().GetAwaiter().GetResult();

        Assert.True(interceptorsReady.Wait(TimeSpan.FromSeconds(30)),
                $"WebView2 30 秒内没就绪：{initializationFailure ?? "（没有报错信息）"}");
    }

    public void Dispose()
    {
        try
        {
            dispatcher.Invoke(() =>
            {
                window.Content = null;
                host.Dispose();
                window.Close();
            });
        }
        catch
        {
            // 关窗失败不影响用例结论
        }
        dispatcher.InvokeShutdown();
        // 只试一次：WebView2 的用户数据目录往往要等它的浏览器进程真正退出才删得掉，
        // **真正的回收发生在下一个用例的 PurgeStaleDataDirectories**（那时进程早退了）。
        // 不要在这里 sleep 重试——那是拿等待掩盖资源生命周期，而且会把测试拖慢。
        try { Directory.Delete(dataDir, recursive: true); } catch { /* 留给下一轮清 */ }
    }

    /// <summary>
    /// 清掉**上一次运行**留下的临时目录。
    ///
    /// 必要性：WebView2 的用户数据目录在它的浏览器进程退出前删不掉，`Dispose` 只能尽力而为——
    /// 实测连跑之后会在 <c>%TEMP%</c> 下攒出几十个目录（40 个 ≈ 15 MB）。这里在下一轮开工前回收，
    /// 于是稳态最多只剩「当前这一轮」的几个。
    /// </summary>
    private static void PurgeStaleDataDirectories(string keep)
    {
        var root = Path.Combine(Path.GetTempPath(), "campus-entry-host-tests");
        if (!Directory.Exists(root)) return;
        foreach (var dir in Directory.GetDirectories(root))
        {
            if (string.Equals(dir, keep, StringComparison.OrdinalIgnoreCase)) continue;
            try { Directory.Delete(dir, recursive: true); } catch { /* 还被占用就留给下一轮 */ }
        }
    }

    // ------------------------------------------------ A3：停手前先验正文（CORE-SPEC §2）

    [Fact]
    public async Task 门户入口落到没有登录标记的页面时不宣布到达()
    {
        await RunOnUi(async () =>
        {
            StartGatewayFlow();
            Serve("<html><body><div>请选择要访问的资源</div></body></html>");
            Navigate(PortalHost + "/portal");

            await AwaitTrue("状态行应当变成「正在等待门户加载完成…」",
                    () => Task.FromResult(host.Notice.Text == "正在等待门户加载完成…"));
            Assert.False(host.Flow.IsSettled, "没验到正文就不该算到达");
        });
    }

    [Fact]
    public async Task 门户入口正文里有登录标记时才停手()
    {
        await RunOnUi(async () =>
        {
            StartGatewayFlow();
            Serve("""<html><body><div class="card">资源站点</div></body></html>""");
            Navigate(PortalHost + "/portal");

            await AwaitTrue("正文有标记就该停手", () => Task.FromResult(host.Flow.IsSettled));
        });
    }

    // ------------------------------------------------ A2：只在门户主机的认证页上碰凭据（§6.1）

    [Fact]
    public async Task 别的主机上的认证页不会被自动填写()
    {
        await RunOnUi(async () =>
        {
            Assert.True(repository.Save("20250001", "Test-Password-1".ToCharArray()), "测试凭据要能落盘");
            StartGatewayFlow();
            Serve(CasForm);
            Navigate(JxfwHost + "/cas/login");

            // 反例没有「正向信号」可等，只能给足时间（后台解密 + 回 UI 线程）再断言没发生
            await Task.Delay(TimeSpan.FromSeconds(2.5));
            Assert.Equal("", await TypedUsername());
        });
    }

    [Fact]
    public async Task 门户主机上的认证页会被自动填写()
    {
        await RunOnUi(async () =>
        {
            Assert.True(repository.Save("20250001", "Test-Password-1".ToCharArray()), "测试凭据要能落盘");
            Assert.NotNull(repository.Load());   // 前提：凭据读得回来，否则「没填」说明不了闸的问题
            StartGatewayFlow();
            Serve(CasForm);
            Navigate(PortalHost + "/cas/login");

            await AwaitTrue("账号应当被自动填进页面", async () => await TypedUsername() == "20250001");

            // 再等一拍：填不进的那种失败会走「作废」分支，别把中间那一瞬当成成功
            await Task.Delay(TimeSpan.FromSeconds(1.5));
            Assert.Equal("20250001", await TypedUsername());
        });
    }

    // ------------------------------------------------ 骨架

    /// <summary>真机上「从首页点了校园网关」在状态机里的前置（导航本身由测试自己发）。</summary>
    private void StartGatewayFlow() => host.Flow.Start(Sues.Entry.Webvpn, hasCachedPrefix: false);

    private void Serve(string html) => servedHtml = html;

    private void Navigate(string url) => host.View.CoreWebView2.Navigate(url);

    /// <summary>直接问页面一句：账号框里现在是什么。比断言宿主内部计数更贴近「用户看到什么」。</summary>
    private async Task<string> TypedUsername()
    {
        var raw = await host.View.CoreWebView2.ExecuteScriptAsync(
                "(function(){var e=document.getElementById('username');return e?e.value:'(没有输入框)';})()");
        return raw.Trim().Trim('"');
    }

    /// <summary>有上界地等一个条件成立（在 UI 线程上，`await` 期间消息泵照常转）。</summary>
    private static async Task AwaitTrue(string what, Func<Task<bool>> condition, int timeoutMs = 15_000)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        while (Environment.TickCount64 < deadline)
        {
            if (await condition()) return;
            await Task.Delay(50);
        }
        Assert.Fail($"{what}（等了 {timeoutMs}ms 仍未成立）");
    }

    /// <summary>把一段异步工作丢到 UI 线程上做，并等它做完（WebView2 只能在那个线程上碰）。</summary>
    private Task RunOnUi(Func<Task> work) => dispatcher.InvokeAsync(work).Task.Unwrap();

    private void OnWebResourceRequested(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        // 真实学校 URL 的响应换成本地造的那一页：Source 是真实地址（判据照常判），但**不发任何请求**
        var bytes = System.Text.Encoding.UTF8.GetBytes(servedHtml);
        e.Response = host.View.CoreWebView2.Environment.CreateWebResourceResponse(
                new MemoryStream(bytes), 200, "OK", "Content-Type: text/html; charset=utf-8");
    }
}

/// <summary>
/// WPF + WebView2 的用例必须**串行**：一个进程里多个消息泵/多个 WebView2 用户数据目录会互相打架。
/// </summary>
[CollectionDefinition("WPF-STA", DisableParallelization = true)]
public sealed class WpfStaCollection
{
}
