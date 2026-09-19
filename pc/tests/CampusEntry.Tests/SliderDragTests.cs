using System.IO;
using CampusEntry.Core;
using Xunit;
using static CampusEntry.Core.SliderDrag;

namespace CampusEntry.Tests;

/// <summary>拖动换算（docs/CORE-SPEC.md §5.3 / §7，与 Android 端 SliderDragTest 等价）。</summary>
public class SliderDragTests
{
    /// <summary>真机上的几何：容器 440×0.75=330，手柄 60×0.75=45（加 1px+1px 边框后 47）。</summary>
    private static Geometry Geometry(double handleLeft = 0, double trackLeft = 0) => new(
            ContainerWidth: 330, BackgroundWidth: 330,
            BackgroundNaturalWidth: 440, SliderNaturalWidth: 80,
            HandleOuterWidth: 47, HandleBorderWidth: 2,
            HandleLeft: handleLeft, TrackLeft: trackLeft);

    [Fact]
    public void 滑轨长度是二百八十五而不是值域乘缩放()
    {
        var g = Geometry();
        Assert.Equal(360, g.CutScope);
        Assert.Equal(45.0, g.HandleWidth, 5);
        Assert.Equal(285.0, g.SlidingScope, 5);

        // 这两个数字就是当初的错：值域乘缩放得 270；含边框的手柄宽算出 283，都短于真值 285
        Assert.Equal(270.0, 360.0 * 0.75, 5);
        Assert.Equal(283.0, 330.0 - 47.0, 5);
        Assert.Equal(285.0, 330.0 * (440.0 - 60.0) / 440.0, 5);
    }

    [Fact]
    public void 偏移二百_光标一百五十九_提交二百()
    {
        var plan = MakePlan(200, Geometry(handleLeft: 0, trackLeft: 0))!;
        Assert.Equal(159, plan.Cursor);
        Assert.Equal(200, plan.Submitted);
    }

    [Fact]
    public void 偏移一百_量化误差不超过一()
    {
        var plan = MakePlan(100, Geometry())!;
        Assert.InRange(plan.Submitted, 99, 101);
    }

    [Fact]
    public void 全域最多差一像素()
    {
        var g = Geometry();
        var exact = 0;
        for (var x = 0; x <= g.CutScope; x++)
        {
            var plan = MakePlan(x, g);
            Assert.NotNull(plan);
            var error = Math.Abs(plan!.Submitted - x);
            Assert.True(error <= 1, $"x={x} 提交 {plan.Submitted}，误差 {error} > 1");
            if (error == 0) exact++;
        }
        Assert.True(exact >= 286, $"可精确命中 {exact} 个，应至少 286 个");
    }

    [Fact]
    public void 位移是相对当前光标的()
    {
        var plan = MakePlan(200, Geometry(handleLeft: 40, trackLeft: 10))!;
        Assert.Equal(129.0, plan.Delta, 5);
    }

    [Fact]
    public void 几何回传值解析()
    {
        var probe = ParseProbe("\"geom|330|330|440|80|47|2|40|10\"");
        var ready = Assert.IsType<Probe.Ready>(probe);
        Assert.Equal(330.0, ready.Geometry.ContainerWidth, 5);
        Assert.Equal(440, ready.Geometry.BackgroundNaturalWidth);

        Assert.IsType<Probe.Failed>(ParseProbe("\"none\""));
        Assert.IsType<Probe.Failed>(ParseProbe("\"missing\""));
        Assert.IsType<Probe.Failed>(ParseProbe("\"error\""));
        Assert.IsType<Probe.Failed>(ParseProbe("\"geom|330\""));
    }

    [Fact]
    public async Task 注入脚本里的位移按两位小数写()
    {
        // 与 Android 端一样：这段检查直接读 shared/js/drag.js，保证占位符替换产物合法
        var plan = MakePlan(200, Geometry(handleLeft: 40, trackLeft: 10))!;
        var js = await SharedJs.ReadAllTextAsync("drag.js");
        var filled = js.Replace("__DELTA__", plan.Delta.ToString("F2",
                System.Globalization.CultureInfo.InvariantCulture));
        Assert.EndsWith("(129.00)", filled.TrimEnd());
        Assert.DoesNotContain("__DELTA__", filled);
    }

    [Fact]
    public async Task 共享脚本都装着各自的占位符()
    {
        Assert.Contains("__EXPIRED_MARK__", await SharedJs.ReadAllTextAsync("cas-state.js"));
        Assert.Contains("__USERNAME__", await SharedJs.ReadAllTextAsync("fill-and-submit.js"));
        Assert.Contains("__PASSWORD__", await SharedJs.ReadAllTextAsync("fill-and-submit.js"));
        Assert.Contains("__HIDE__", await SharedJs.ReadAllTextAsync("notice-dialog.js"));
    }
}

/// <summary>测试直接读仓库根 shared/js（与被测应用内嵌的是同一批文件）。</summary>
file static class SharedJs
{
    public static async Task<string> ReadAllTextAsync(string name)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "shared/js")))
            dir = dir.Parent;
        Assert.True(dir != null, $"从 {AppContext.BaseDirectory} 向上找不到 shared/js");
        return await File.ReadAllTextAsync(Path.Combine(dir.FullName, "shared/js", name));
    }
}

