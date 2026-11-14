using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using CampusEntry.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace CampusEntry;

/// <summary>
/// 主窗口：桌面形态——自绘标题栏 + 工具栏 + 标签栏 + 整页站点。启动直达教务系统（没有任何中间首页），
/// 首次运行只用一条可关闭的横幅说明凭据处理。自动登录逻辑在 <see cref="EntryHost"/>，
/// 与 Android 端同一份（shared/js + docs/CORE-SPEC.md）；「哪个标签是前台」由 <see cref="TabHost"/> 管。
///
/// 标题栏用 WPF 原生的 <see cref="System.Windows.Shell.WindowChrome"/> 自绘：拖动、双击最大化、
/// 贴边贴靠、Alt+Space 系统菜单都仍是系统行为，只有窗口按钮由我们自己画。
/// </summary>
public partial class MainWindow : Window
{
    private TabHost tabs = null!;
    private EntrySettings settings = null!;
    private bool bannerDismissed;

    /// <summary>上次画标签条时的「集合 + 标题 + 当前页签」签名，用来避免状态行更新时重建。</summary>
    private string tabSignature = "";

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

        // WebView2 的数据放 %LOCALAPPDATA%\CampusEntry\WebView2（可写目录、随「清除账号」一并可删）。
        // 所有标签共用**同一个** environment：于是它们共享一份 cookie/登录态，只有一个浏览器进程组。
        var environment = await CoreWebView2Environment.CreateAsync(
                userDataFolder: Path.Combine(EntrySettings.DirectoryPath, "WebView2"));

        tabs = new TabHost(settings, repository, environment);
        tabs.TabsChanged += SyncTabs;
        tabs.ActiveChanged += SyncTabs;
        tabs.ViewTitleChanged += title => Dispatcher.Invoke(() => ApplyPageTitle(title));
        tabs.InitializationFailed += reason => Dispatcher.Invoke(() => ReportFatal(
                "学校页面无法显示。\n\n"
                + "本应用用系统的 Microsoft Edge WebView2 组件显示网页，它这次没能启动。\n"
                + "可以试试：更新 Microsoft Edge、或按下面的地址装一次 Evergreen 运行时，然后重开本应用：\n"
                + "https://developer.microsoft.com/microsoft-edge/webview2/\n\n"
                + "技术细节：" + reason,
                null));

        // 桌面惯例：双击图标直达目的地；首次运行用横幅说明，不加一次点击
        var first = await tabs.StartAsync(Sues.Entry.Jxfw);
        if (first == null) return;   // 初始化失败已经经 InitializationFailed 报出去了

        // 到这一步 WebView2 才真的能导航，工具栏此时才允许点（见 XAML 里 IsEnabled 的说明）
        ToolbarHost.IsEnabled = true;
        SyncTabs();
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

    private void OnBack(object sender, RoutedEventArgs e) => tabs?.GoBack();

    private void OnForward(object sender, RoutedEventArgs e) => tabs?.GoForward();

    private void OnReload(object sender, RoutedEventArgs e) => tabs?.Reload();

    private void OnOpenJxfw(object sender, RoutedEventArgs e) => tabs?.OpenEntry(Sues.Entry.Jxfw);

    private void OnOpenWebvpn(object sender, RoutedEventArgs e) => tabs?.OpenEntry(Sues.Entry.Webvpn);

    /// <summary>
    /// 状态行上的动作按钮（「重试」/「撤销」）。动作由状态机给（<see cref="NoticeKind"/>），
    /// 界面只负责画出来——APP-UX §5 的「是否可点」列就是这条约定。
    /// </summary>
    private void OnNoticeAction(object sender, RoutedEventArgs e) => tabs?.OnNoticeAction();

    private void OnSettings(object sender, RoutedEventArgs e)
    {
        if (tabs == null) return;
        var dialog = new SettingsWindow(tabs, SyncTabs, this) { Owner = this };
        dialog.ShowDialog();
        SyncTabs();
    }

    // ---------------------------------------------------------------- 快捷键与鼠标侧键

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt))
        {
            if (e.Key == Key.Left)
            {
                tabs?.GoBack();
                e.Handled = true;
            }
            else if (e.Key == Key.Right)
            {
                tabs?.GoForward();
                e.Handled = true;
            }
            return;
        }
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            if (e.Key == Key.Tab)
            {
                CycleTab(Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? -1 : 1);
                e.Handled = true;
            }
            else if (e.Key == Key.W)
            {
                if (tabs?.Active != null) tabs.CloseTab(tabs.ActiveId);
                e.Handled = true;
            }
            else if (e.Key == Key.D1)
            {
                tabs?.OpenEntry(Sues.Entry.Jxfw);
                e.Handled = true;
            }
            else if (e.Key == Key.D2)
            {
                tabs?.OpenEntry(Sues.Entry.Webvpn);
                e.Handled = true;
            }
            return;
        }
        if (e.Key == Key.F5)
        {
            tabs?.Reload();
            e.Handled = true;
        }
    }

    /// <summary>鼠标后退/前进侧键（桌面浏览器的基本操作）。</summary>
    private void OnPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.XButton1)
        {
            tabs?.GoBack();
            e.Handled = true;
        }
        else if (e.ChangedButton == MouseButton.XButton2)
        {
            tabs?.GoForward();
            e.Handled = true;
        }
    }

    /// <summary>Ctrl+Tab / Ctrl+Shift+Tab 在标签之间循环。</summary>
    private void CycleTab(int delta)
    {
        if (tabs == null || tabs.Tabs.Count < 2) return;
        var list = tabs.Tabs;
        var index = -1;
        for (var i = 0; i < list.Count; i++)
        {
            if (list[i].Id == tabs.ActiveId) index = i;
        }
        if (index < 0) return;
        var next = ((index + delta) % list.Count + list.Count) % list.Count;
        tabs.SwitchTo(list[next].Id);
    }

    // ---------------------------------------------------------------- 首次运行横幅

    private void OnCloseBanner(object sender, RoutedEventArgs e)
    {
        bannerDismissed = true;
        RefreshUi();
    }

    // ---------------------------------------------------------------- 标签栏

    /// <summary>
    /// 把界面同步到 <see cref="TabHost"/> 的当前状态：内容区放每个标签的 WebView2、
    /// 只显示前台那个、重画标签条。**切换标签只改可见性**——不导航、不重载，
    /// 所以页面状态与状态机的文档序号都不会因为「切页面」而变化。
    /// </summary>
    private void SyncTabs()
    {
        if (tabs == null) return;

        var active = tabs.Active;

        // 先摘掉已经关闭的标签的控件，再补齐新的（顺序反了会短暂出现两个控件抢同一个位置）
        var alive = new HashSet<WebView2>(tabs.Tabs.Select(t => t.Host.View));
        for (var i = WebHost.Children.Count - 1; i >= 0; i--)
        {
            if (WebHost.Children[i] is WebView2 view && !alive.Contains(view)) WebHost.Children.RemoveAt(i);
        }
        foreach (var tab in tabs.Tabs)
        {
            if (!WebHost.Children.Contains(tab.Host.View)) WebHost.Children.Add(tab.Host.View);
            tab.Host.View.Visibility = tab.Id == active?.Id ? Visibility.Visible : Visibility.Collapsed;
        }

        TabStripHost.Visibility = tabs.Tabs.Count > 1 ? Visibility.Visible : Visibility.Collapsed;

        // 标签条只在「集合 / 标题 / 当前页签」变化时重画：状态行更新很频繁，
        // 每次都重建一遍页签会闪，也会把鼠标悬停状态丢掉。
        var signature = tabs.ActiveId + "|"
                + string.Join("|", tabs.Tabs.Select(t => t.Id + ":" + t.Title));
        if (signature != tabSignature)
        {
            tabSignature = signature;
            TabStrip.Children.Clear();
            foreach (var tab in tabs.Tabs) TabStrip.Children.Add(BuildTabHeader(tab));
        }

        ApplyPageTitle(active?.Title ?? "");
        RefreshUi();
    }

    /// <summary>
    /// 一个标签条上的「页签」：上沿 2 DIP 主色表示前台（DESIGN.md 的 8 点网格：
    /// 34 高 = 4×8 + 2 上沿，左右 12 内边距）。非前台的页签悬停时换成 Hover 底色。
    /// </summary>
    private FrameworkElement BuildTabHeader(EntryTab tab)
    {
        var isActive = tab.Id == tabs.ActiveId;
        var surface = (Brush)FindResource("Brush.Surface");
        var hover = (Brush)FindResource("Brush.Hover");
        var line = (Brush)FindResource("Brush.Line");

        var chip = new Border
        {
            Height = 34,
            Padding = new Thickness(12, 0, 6, 0),
            Background = isActive ? surface : Brushes.Transparent,
            BorderBrush = isActive ? (Brush)FindResource("Brush.Primary") : line,
            BorderThickness = isActive ? new Thickness(0, 2, 1, 0) : new Thickness(0, 0, 1, 0),
            Cursor = Cursors.Hand,
        };
        chip.MouseLeftButtonUp += (_, _) => tabs.SwitchTo(tab.Id);
        if (!isActive)
        {
            chip.MouseEnter += (_, _) => chip.Background = hover;
            chip.MouseLeave += (_, _) => chip.Background = Brushes.Transparent;
        }

        var title = new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(tab.Title) ? "新标签页" : tab.Title,
            FontSize = (double)FindResource("Type.Body"),
            FontWeight = isActive ? FontWeights.SemiBold : FontWeights.Normal,
            Foreground = (Brush)FindResource(isActive ? "Brush.Ink" : "Brush.Secondary"),
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 200,
            TextTrimming = TextTrimming.CharacterEllipsis,
            ToolTip = tab.Title,
        };

        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(title);

        // 只剩一个标签时不给关闭按钮：窗口总要留一页，留个点不动的叉更让人困惑
        if (tabs.Tabs.Count > 1)
        {
            var close = new Button
            {
                Style = (Style)FindResource("IconButton"),
                Content = "\uE8BB",
                FontSize = 10,
                Width = 22,
                Height = 22,
                Margin = new Thickness(6, 0, 0, 0),
                ToolTip = "关闭标签页 (Ctrl+W)",
            };
            close.Click += (_, args) =>
            {
                args.Handled = true;
                tabs.CloseTab(tab.Id);
            };
            row.Children.Add(close);
        }

        chip.Child = row;
        return chip;
    }

    // ---------------------------------------------------------------- 状态刷新

    private void RefreshUi()
    {
        var host = tabs?.Active?.Host;
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
        tabs?.Dispose();
        base.OnClosed(e);
    }
}
