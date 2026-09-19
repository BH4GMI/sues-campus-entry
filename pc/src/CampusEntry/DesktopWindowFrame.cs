using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace CampusEntry;

/// <summary>
/// 桌面窗口的边框行为。
///
/// <b>Win11 窗口圆角。</b>自绘边框后，我们自己画的 8px 圆角只是「看起来圆」——窗口矩形本身
/// 仍然是方的，四角会被 DWM 填上默认底色。真正把窗口裁成圆角要交给合成器：
/// DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND。Win10 没有这个属性，保持直角，
/// 与 Win10 自身的窗口惯例一致。
///
/// <b>为什么不在这里处理最大化尺寸（实测记录）。</b>自定义边框的最大化窗口，系统给出的是
/// 「工作区外扩一圈 ResizeBorderThickness」的矩形，而 WindowChrome 把非客户区清零、客户区等于
/// 整个窗口矩形，于是客户区比工作区大一圈：实测 200% 缩放下 2906x1730 对工作区 2880x1704，
/// 每边多 13px（≈6.5 DIP，正是 ResizeBorderThickness 6 DIP 的外扩）。
/// 标准做法是在 WM_GETMINMAXINFO 里把 MaxSize/MaxPosition 钉回工作区，但**这里做不到**：
/// WindowChrome 自己已经挂了 WM_GETMINMAXINFO 的钩子并返回 handled=true，会终止钩子链，
/// 后加的钩子实测完全不会被调用（2026-09-19 用 HwndSource.AddHook 验证，窗口矩形没有任何变化）。
/// 剩下的 13px 只影响视口高度（页面按 1730 排版、可见 1704），可见边缘仍严格止于任务栏，
/// 没有视觉断层；换来的是保留 WindowChrome 原生的拖动、贴靠、双击最大化与最小尺寸约束，
/// 这个取舍是划算的，因此不再自行接管窗口几何。
/// </summary>
internal static class DesktopWindowFrame
{
    private const int DwmWindowCornerPreference = 33;
    private const int DwmWindowCornerRound = 2;
    private const int Windows11Build = 22000;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>在窗口的 OnSourceInitialized 里调用（此时 HWND 才存在）。</summary>
    public static void Apply(Window window)
    {
        if (Environment.OSVersion.Version.Build < Windows11Build) return;

        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero) return;

        var preference = DwmWindowCornerRound;
        var result = DwmSetWindowAttribute(handle, DwmWindowCornerPreference, ref preference, sizeof(int));
        if (result != 0)
        {
            System.Diagnostics.Debug.WriteLine(
                    $"[CampusEntry] DwmSetWindowAttribute(圆角) 失败，HRESULT=0x{result:X8}");
        }
    }
}
