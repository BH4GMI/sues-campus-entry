using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using CampusEntry.Core;
using Microsoft.Web.WebView2.Core;

namespace CampusEntry;

/// <summary>
/// 主窗口：桌面形态——自绘标题栏 + 工具栏 + 整页站点。启动直达教务系统（没有任何中间首页），
/// 首次运行只用一条可关闭的横幅说明凭据处理。自动登录逻辑在 <see cref="EntryHost"/>，
/// 与 Android 端同一份（shared/js + docs/CORE-SPEC.md）。
///
/// 标题栏用 WPF 原生的 <see cref="System.Windows.Shell.WindowChrome"/> 自绘：拖动、双击最大化、
/// 贴边贴靠、Alt+Space 系统菜单都仍是系统行为，只有窗口按钮由我们自己画。
/// </summary>
public partial class MainWindow : Window
{
    private EntryHost host = null!;
    private EntrySettings settings = null!;
    private bool bannerDismissed;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += async (_, _) => await StartAsync();
        StateChanged += OnWindowStateChanged;
        PreviewKeyDown += OnPreviewKeyDown;
        PreviewMouseDown += OnPreviewMouseDown;
    }

    private async System.Threading.Tasks.Task StartAsync()
    {
        try
        {
            await StartCoreAsync();
        }
        catch (WebView2RuntimeNotFoundException ex)
        {
            // WebView2 Runtime 是本应用**唯一**无法随包携带的外部依赖：它是系统级组件，
            // 由 Edge 提供（固定版本方案要另外分发近 200MB 且需自行跟进更新）。
            // 便携版换一台机器时可能没有它——这时必须给出「出了问题 / 为什么 / 下一步做什么」，
            // 而不是让进程崩掉。
            ReportFatal(
                    "缺少 WebView2 运行时，无法显示学校页面。\n\n"
                    + "本应用用系统的 Microsoft Edge WebView2 组件显示网页，它不随应用一起打包。\n"
                    + "请安装「Microsoft Edge WebView2 Runtime」（Evergreen 版）后重新打开本应用：\n"
                    + "https://developer.microsoft.com/microsoft-edge/webview2/\n\n"
                    + "技术细节：" + ex.Message,
                    ex);
        }
        catch (Exception ex)
        {
            ReportFatal("启动失败。\n\n" + ex.Message, ex);
        }
    }

    /// <summary>把启动失败说清楚：写进 run.log，弹一个带下一步的对话框，然后干净退出。</summary>
    private void ReportFatal(string message, Exception? ex)
    {
        try
        {
            Directory.CreateDirectory(EntrySettings.DirectoryPath);
            File.AppendAllText(
                    Path.Combine(EntrySettings.DirectoryPath, "run.log"),
                    $"[{DateTime.Now:O}] 启动失败：{ex?.ToString() ?? message}{Environment.NewLine}");
        }
        catch (Exception logFailure)
        {
            // 日志写不进去不能掩盖真正的问题，但也不该在报错路径上再抛一次
            System.Diagnostics.Debug.WriteLine($"[CampusEntry] run.log 写入失败：{logFailure.Message}");
        }

        MessageBox.Show(this, message, "教务直达 — 无法启动",
                MessageBoxButton.OK, MessageBoxImage.Error);
        Application.Current?.Shutdown();
    }

    private async System.Threading.Tasks.Task StartCoreAsync()
    {
        settings = EntrySettings.Load();
        RestoreWindowBounds();
        var repository = new CredentialRepository(EntrySettings.DirectoryPath,
                new CredentialStore(new DpapiCryptoBackend()));

        // WebView2 的数据放 %LOCALAPPDATA%\CampusEntry\WebView2（可写目录、随「清除账号」一并可删）
        var environment = await CoreWebView2Environment.CreateAsync(
                userDataFolder: Path.Combine(EntrySettings.DirectoryPath, "WebView2"));

        host = new EntryHost(settings, repository, environment);
        host.Changed += RefreshUi;
        host.ViewTitleChanged += title => Dispatcher.Invoke(() => ApplyPageTitle(title));
        WebHost.Content = host.View;

        // 桌面惯例：双击图标直达目的地；首次运行用横幅说明，不加一次点击
        host.Ready += () =>
        {
            // 到这一步 WebView2 才真的能导航，工具栏此时才允许点（见 XAML 里 IsEnabled 的说明）
            ToolbarHost.IsEnabled = true;
            host.OpenEntry(Sues.Entry.Jxfw);
            RefreshUi();
        };
        host.InitializationFailed += reason => Dispatcher.Invoke(() => ReportFatal(
                "学校页面无法显示。\n\n"
                + "本应用用系统的 Microsoft Edge WebView2 组件显示网页，它这次没能启动。\n"
                + "可以试试：更新 Microsoft Edge、或按下面的地址装一次 Evergreen 运行时，然后重开本应用：\n"
                + "https://developer.microsoft.com/microsoft-edge/webview2/\n\n"
                + "技术细节：" + reason,
                null));
        RefreshUi();
    }

    // ---------------------------------------------------------------- 自绘标题栏

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        DesktopWindowFrame.Apply(this);
    }

    private void OnMinimizeWindow(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    private void OnToggleMaximize(object sender, RoutedEventArgs e) =>
            WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    private void OnCloseWindow(object sender, RoutedEventArgs e) => Close();

    /// <summary>最大化/还原时换图标：□ ↔ ❐（与系统窗口按钮同一套字形）。</summary>
    private void OnWindowStateChanged(object? sender, EventArgs e)
    {
        if (MaximizeButton == null) return;
        MaximizeButton.Content = WindowState == WindowState.Maximized ? "\uE923" : "\uE922";
    }

    /// <summary>
    /// 任务栏与 Alt+Tab 用完整标题；自绘标题栏里分开显示「应用名 + 当前页面」。
    /// </summary>
    private void ApplyPageTitle(string title)
    {
        var page = string.IsNullOrWhiteSpace(title) ? "" : title;
        Title = page.Length == 0 ? "教务直达" : $"{page} — 教务直达";
        if (DocTitle != null) DocTitle.Text = page;
    }

    // ---------------------------------------------------------------- 工具栏

    private void OnBack(object sender, RoutedEventArgs e) => host?.GoBack();

    private void OnForward(object sender, RoutedEventArgs e) => host?.GoForward();

    private void OnReload(object sender, RoutedEventArgs e) => host?.Reload();

    private void OnOpenJxfw(object sender, RoutedEventArgs e) => host?.OpenEntry(Sues.Entry.Jxfw);

    private void OnOpenWebvpn(object sender, RoutedEventArgs e) => host?.OpenEntry(Sues.Entry.Webvpn);

    /// <summary>
    /// 状态行上的动作按钮（「重试」/「撤销」）。动作由状态机给（<see cref="NoticeKind"/>），
    /// 界面只负责画出来——APP-UX §5 的「是否可点」列就是这条约定。
    /// </summary>
    private void OnNoticeAction(object sender, RoutedEventArgs e) => host?.OnNoticeAction();

    private void OnSettings(object sender, RoutedEventArgs e)
    {
        if (host == null) return;
        var dialog = new SettingsWindow(host, RefreshUi, this) { Owner = this };
        dialog.ShowDialog();
        RefreshUi();
    }

    // ---------------------------------------------------------------- 快捷键与鼠标侧键

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt))
        {
            if (e.Key == Key.Left)
            {
                host?.GoBack();
                e.Handled = true;
            }
            else if (e.Key == Key.Right)
            {
                host?.GoForward();
                e.Handled = true;
            }
            return;
        }
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            if (e.Key == Key.D1)
            {
                host?.OpenEntry(Sues.Entry.Jxfw);
                e.Handled = true;
            }
            else if (e.Key == Key.D2)
            {
                host?.OpenEntry(Sues.Entry.Webvpn);
                e.Handled = true;
            }
            return;
        }
        if (e.Key == Key.F5)
        {
            host?.Reload();
            e.Handled = true;
        }
    }

    /// <summary>鼠标后退/前进侧键（桌面浏览器的基本操作）。</summary>
    private void OnPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.XButton1)
        {
            host?.GoBack();
            e.Handled = true;
        }
        else if (e.ChangedButton == MouseButton.XButton2)
        {
            host?.GoForward();
            e.Handled = true;
        }
    }

    // ---------------------------------------------------------------- 首次运行横幅

    private void OnCloseBanner(object sender, RoutedEventArgs e)
    {
        bannerDismissed = true;
        RefreshUi();
    }

    // ---------------------------------------------------------------- 状态刷新

    private void RefreshUi()
    {
        if (host == null) return;

        // 状态一句话在工具栏右侧（桌面惯例），颜色按语义
        NoticeText.Text = host.Notice.Text;
        NoticeText.Foreground = host.Notice.Tone switch
        {
            NoticeState.ToneKind.Alert => (SolidColorBrush)FindResource("Brush.Warning"),
            NoticeState.ToneKind.Done => (SolidColorBrush)FindResource("Brush.Success"),
            _ => (SolidColorBrush)FindResource("Brush.Secondary"),
        };

        // 状态行上的动作按钮：状态机给了动作才出现，否则整块塌陷（不占位、不可点）
        NoticeActionButton.Content = host.Notice.Kind switch
        {
            NoticeKind.Retry => "重试",
            NoticeKind.UndoSave => "撤销",
            NoticeKind.ClearAccount => "清除账号",
            _ => "",
        };
        NoticeActionButton.Visibility = host.Notice.Kind == NoticeKind.None
                ? Visibility.Collapsed
                : Visibility.Visible;

        // 「当前入口」是互斥状态，交给 RadioButton 的 IsChecked 表达，不再手工换前景色
        TabJxfw.IsChecked = host.ActiveEntry == Sues.Entry.Jxfw;
        TabWebvpn.IsChecked = host.ActiveEntry == Sues.Entry.Webvpn;

        var saved = host.SavedUsername != null;
        FirstRunBanner.Visibility = !saved && !bannerDismissed ? Visibility.Visible : Visibility.Collapsed;
        BannerSaved.Text = saved ? "✓ 已记住" : "";
    }

    // ---------------------------------------------------------------- 窗口几何（桌面惯例：记住大小与位置）

    private void RestoreWindowBounds()
    {
        if (settings.WindowWidth is > 0 && settings.WindowHeight is > 0)
        {
            Width = settings.WindowWidth.Value;
            Height = settings.WindowHeight.Value;
            if (settings.WindowLeft is >= -8 && settings.WindowTop is >= -8)
            {
                WindowStartupLocation = WindowStartupLocation.Manual;
                Left = settings.WindowLeft.Value;
                Top = settings.WindowTop.Value;
            }
        }
        if (settings.WindowMaximized) WindowState = WindowState.Maximized;
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (settings != null)
        {
            var bounds = WindowState == WindowState.Maximized ? RestoreBounds : new Rect(Left, Top, Width, Height);
            settings.WindowLeft = bounds.Left;
            settings.WindowTop = bounds.Top;
            settings.WindowWidth = bounds.Width;
            settings.WindowHeight = bounds.Height;
            settings.WindowMaximized = WindowState == WindowState.Maximized;
            settings.Save();
        }
        base.OnClosing(e);
    }

    protected override void OnClosed(EventArgs e)
    {
        host?.Dispose();
        base.OnClosed(e);
    }
}
