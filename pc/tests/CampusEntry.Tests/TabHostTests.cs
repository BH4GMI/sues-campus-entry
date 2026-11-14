using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using CampusEntry.Core;
using Microsoft.Web.WebView2.Core;
using Xunit;

namespace CampusEntry.Tests;

/// <summary>
/// 标签页宿主的**接线**测试（不是判据测试——判据在 <c>EntryFlowTests</c>）：
/// 站点点开一个 <c>target="_blank"</c> 的链接之后，到底有没有变成一个可以来回切的真标签页。
///
/// <para>
/// 为什么值得单独测：<c>EntryFlow.Adopt()</c> 在 PC 上一直**没人调用**，单测却一直是绿的
/// （`EntryFlowTests.站点自己开的标签页不劫持用户` 只证明状态机自己是对的）。
/// 这里测的是「事件 → 建标签 → 交接导航」这条真实的接线，也就是上一类 bug 唯一抓得住的层。
/// </para>
/// <para>
/// 手法与 <see cref="EntryHostDomTests"/> 一致：STA + Dispatcher + 离屏窗口（WebView2 是 HwndHost，
/// 必须有真 HWND）、请求拦截（零网络流量）。唯一新增的是用 **CDP 的 Input.dispatchMouseEvent**
/// 点那个链接——Chromium 只把可信输入算作用户手势，脚本里直接 <c>window.open</c> 会被弹窗拦截器挡掉。
/// </para>
/// </summary>
[Collection("WPF-STA")]
public sealed class TabHostTests : IDisposable
{
    private const string HostPattern = "https://*.sues.edu.cn/*";

    private readonly string dataDir =
            Path.Combine(Path.GetTempPath(), "campus-entry-tab-tests", Guid.NewGuid().ToString("N"));

    private Dispatcher dispatcher = null!;
    private Window window = null!;
    private Grid content = null!;
    private TabHost tabs = null!;
    private CoreWebView2Environment environment = null!;
    private string? initializationFailure;

    /// <summary>下一次页面请求要回给页面的 HTML。</summary>
    private string servedHtml = "<html><body>空</body></html>";

    public TabHostTests()
    {
        var started = new ManualResetEventSlim();
        var uiThread = new Thread(() =>
        {
            dispatcher = Dispatcher.CurrentDispatcher;
            content = new Grid();
            window = new Window
            {
                Left = -4000,
                Top = -4000,
                Width = 900,
                Height = 650,
                ShowInTaskbar = false,
                ShowActivated = false,
                WindowStyle = WindowStyle.None,
                Content = content,
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
        OnUi(async () =>
        {
            var settings = new EntrySettings { DataDirectory = dataDir };
            var repository = new CredentialRepository(dataDir, new CredentialStore(new DpapiCryptoBackend()));
            environment = await CoreWebView2Environment
                    .CreateAsync(userDataFolder: Path.Combine(dataDir, "WebView2"));

            tabs = new TabHost(settings, repository, environment);
            tabs.TabsChanged += SyncViews;
            tabs.ActiveChanged += SyncViews;
            tabs.InitializationFailed += reason => initializationFailure = reason;
            await tabs.StartAsync(Sues.Entry.Jxfw);
        });

        Assert.True(WaitFor(() => tabs.Active != null, 30_000),
                $"第一个标签页 30 秒内没就绪：{initializationFailure ?? "（没有报错信息）"}");
    }

    // ---------------------------------------------------------------- 用例

    [Fact]
    public void 启动之后只有一个标签而且是前台()
    {
        var tab = Active();
        Assert.NotNull(tab);
        Assert.Single(tabs.Tabs);
        Assert.Equal(tab!.Id, tabs.ActiveId);
        Assert.False(tab.SiteOpened);
    }

    [Fact]
    public void 最后一个标签关不掉()
    {
        var id = Active()!.Id;
        OnUi(() => tabs.CloseTab(id));
        Assert.Single(tabs.Tabs);
    }

    /// <summary>
    /// 站点里点一个 <c>target="_blank"</c> 的链接：应当开出一个**新标签页**并切过去，
    /// 而原标签页一动不动（这是「看完资源再切回门户」那个场景的最小模型）。
    /// </summary>
    [Fact]
    public void 站点点开的链接会变成可以切回去的新标签页()
    {
        var first = Active()!;

        servedHtml = """
            <html><body style="margin:0">
              <a id="pop" href="https://jxfw.sues.edu.cn/popup" target="_blank"
                 style="display:block;width:200px;height:60px">开新页</a>
            </body></html>
            """;

        // 让第一个标签载入带链接的那一页（测试页拦在本地，不发真实请求）
        const string testUrl = "https://webvpn.sues.edu.cn/https/x/popup-test";
        OnUi(() => first.Host.NavigateTo(testUrl));
        Assert.True(WaitFor(() => (first.Host.CoreOrNull?.Source ?? "").Contains("popup-test"), 15_000),
                "第一个标签页没有导航到测试页");

        // 原标签页停在这一页：点开新页之后它不应该被动过
        var firstUrl = dispatcher.Invoke(() => first.Host.CoreOrNull!.Source);

        ClickLink(first);

        Assert.True(WaitFor(() => tabs.Tabs.Count == 2, 20_000),
                $"点开 target=_blank 链接之后没有出现第二个标签页（现有 {tabs.Tabs.Count} 个）");

        var opened = tabs.Tabs.First(t => t.Id != first.Id);
        Assert.True(opened.SiteOpened, "新标签页应当被标成「站点自开」");
        Assert.True(opened.Host.Flow.Adopted, "站点自开的页必须先 Adopt，否则状态机会把它当落点判");
        Assert.Equal(opened.Id, tabs.ActiveId);
        Assert.Equal(first.Id, tabs.Tabs[0].Id);

        // 切回去：原标签还在，而且是同一个对象（没有重新加载）
        OnUi(() => tabs.SwitchTo(first.Id));
        Assert.Equal(first.Id, tabs.ActiveId);
        Assert.Equal(2, tabs.Tabs.Count);
        Assert.Equal(firstUrl, dispatcher.Invoke(() => first.Host.CoreOrNull!.Source));
    }

    // ---------------------------------------------------------------- 界面同步（照 MainWindow 的做法）

    private void SyncViews()
    {
        var active = tabs.Active;
        foreach (var tab in tabs.Tabs)
        {
            if (!content.Children.Contains(tab.Host.View))
            {
                content.Children.Add(tab.Host.View);
                // 新标签的拦截器只能在它的 CoreWebView2 就绪之后装
                tab.Host.View.CoreWebView2InitializationCompleted += (_, e) =>
                {
                    if (!e.IsSuccess) return;
                    var core = tab.Host.View.CoreWebView2;
                    core.WebResourceRequested += OnWebResourceRequested;
                    core.AddWebResourceRequestedFilter(HostPattern, CoreWebView2WebResourceContext.All);
                };
            }
            tab.Host.View.Visibility = tab.Id == active?.Id ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private void OnWebResourceRequested(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        var response = environment.CreateWebResourceResponse(
                new MemoryStream(System.Text.Encoding.UTF8.GetBytes(servedHtml)),
                200, "OK", "Content-Type: text/html; charset=utf-8");
        e.Response = response;
    }

    /// <summary>用 CDP 发一次**可信**点击（Chromium 只认可信输入为「用户手势」，否则弹窗被拦）。</summary>
    private void ClickLink(EntryTab tab)
    {
        var deadline = Environment.TickCount64 + 20_000;
        while (Environment.TickCount64 < deadline)
        {
            var clicked = false;
            OnUi(async () => clicked = await TryClickAsync(tab));
            if (clicked) return;
            Thread.Sleep(100);
        }
        Assert.Fail("测试页里点不到那个链接");
    }

    private async System.Threading.Tasks.Task<bool> TryClickAsync(EntryTab tab)
    {
        var core = tab.Host.CoreOrNull;
        if (core == null) return false;

        var js = "JSON.stringify((()=>{const a=document.getElementById('pop');"
                + "if(!a)return null;const r=a.getBoundingClientRect();"
                + "return {x:r.left+r.width/2,y:r.top+r.height/2};})())";
        var result = await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate",
                System.Text.Json.JsonSerializer.Serialize(new { expression = js }));
        var inner = System.Text.Json.JsonDocument.Parse(result).RootElement
                .GetProperty("result").GetProperty("value").GetString();
        if (string.IsNullOrEmpty(inner) || inner == "null") return false;

        var point = System.Text.Json.JsonDocument.Parse(inner).RootElement;
        var x = point.GetProperty("x").GetDouble();
        var y = point.GetProperty("y").GetDouble();

        foreach (var type in new[] { "mousePressed", "mouseReleased" })
        {
            await core.CallDevToolsProtocolMethodAsync("Input.dispatchMouseEvent",
                    $"{{\"type\":\"{type}\",\"x\":{x},\"y\":{y},\"button\":\"left\",\"clickCount\":1}}");
        }
        return true;
    }

    // ---------------------------------------------------------------- 基础设施

    private EntryTab? Active() => dispatcher.Invoke(() => tabs.Active);

    private bool WaitFor(Func<bool> condition, int timeoutMs)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        while (Environment.TickCount64 < deadline)
        {
            if (dispatcher.Invoke(condition)) return true;
            Thread.Sleep(50);
        }
        return dispatcher.Invoke(condition);
    }

    private void OnUi(Func<System.Threading.Tasks.Task> action) =>
            dispatcher.InvokeAsync(action).Task.Unwrap().GetAwaiter().GetResult();

    private void OnUi(Action action) => dispatcher.Invoke(action);

    public void Dispose()
    {
        try
        {
            dispatcher.Invoke(() =>
            {
                window.Content = null;
                tabs?.Dispose();
                window.Close();
            });
        }
        catch
        {
            // 关窗失败不影响用例结论
        }
        dispatcher.InvokeShutdown();
        try { Directory.Delete(dataDir, recursive: true); } catch { /* WebView2 进程退出前删不掉 */ }
    }
}
