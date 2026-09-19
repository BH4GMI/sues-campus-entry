using System.Globalization;

namespace CampusEntry.Core;

/// <summary>
/// 滑块拖动换算：缺口在背景图里的像素偏移 → 手柄要拖到哪儿。
/// 与 Android 端 <c>SliderDrag.kt</c> 逐条一致（docs/CORE-SPEC.md §5.3）。
/// 这段算术必须留在能被单测覆盖的地方，不要写回注入页面的 JS 字面量。
/// </summary>
public static class SliderDrag
{
    private const int Span = 4;

    /// <summary>页面上量到的几何。全部是渲染尺寸（CSS 像素），不是自然尺寸。</summary>
    public sealed record Geometry(
        double ContainerWidth,
        double BackgroundWidth,
        int BackgroundNaturalWidth,
        int SliderNaturalWidth,
        double HandleOuterWidth,
        double HandleBorderWidth,
        double HandleLeft,
        double TrackLeft)
    {
        /// <summary>提交值的值域：两图自然宽之差（实测 440 − 80 = 360）。</summary>
        public int CutScope => BackgroundNaturalWidth - SliderNaturalWidth;

        /// <summary>手柄的内容宽（去掉边框）。页面内部用的是这个。</summary>
        public double HandleWidth => HandleOuterWidth - HandleBorderWidth;

        /// <summary>手柄能走的显示层像素 = 容器渲染宽 − 手柄内容宽。</summary>
        public double SlidingScope => ContainerWidth - HandleWidth;

        /// <summary>手柄此刻的位置。位移是相对量，拖动量要以它为基准。</summary>
        public double CursorNow => HandleLeft - TrackLeft;

        public bool ContainerMatchesImage => Math.Abs(ContainerWidth - BackgroundWidth) < 1.0;
    }

    public abstract record Probe
    {
        public sealed record Ready(Geometry Geometry) : Probe;

        public sealed record Failed(string Reason) : Probe;
    }

    public sealed record Plan(int Cursor, int Submitted, double Delta);

    /// <summary>解析 slider-geometry.js 的回传值。</summary>
    public static Probe ParseProbe(string? raw)
    {
        var value = (raw ?? "").Trim().Trim('"');
        switch (value)
        {
            case "none":
                return new Probe.Failed("页面上没有滑块容器");
            case "missing":
                return new Probe.Failed("滑块容器里缺少轨道、手柄或图片元素");
            case "error":
                return new Probe.Failed("页面读取几何时抛错");
        }
        var parts = value.Split('|');
        if (parts.Length != 9 || parts[0] != "geom")
            return new Probe.Failed($"几何回传值不认得：{value}");
        var numbers = new double[8];
        for (var i = 1; i <= 8; i++)
        {
            if (!double.TryParse(parts[i], NumberStyles.Float, CultureInfo.InvariantCulture, out var d))
                return new Probe.Failed($"几何第 {i} 个值不是数字：{parts[i]}");
            numbers[i - 1] = d;
        }
        return new Probe.Ready(new Geometry(
            ContainerWidth: numbers[0],
            BackgroundWidth: numbers[1],
            BackgroundNaturalWidth: (int)numbers[2],
            SliderNaturalWidth: (int)numbers[3],
            HandleOuterWidth: numbers[4],
            HandleBorderWidth: numbers[5],
            HandleLeft: numbers[6],
            TrackLeft: numbers[7]));
    }

    /// <summary>页面会提交的值：parseInt(光标 / 滑轨长度 × 值域)。对非负数就是向下取整。</summary>
    public static int Submitted(int cursor, int cutScope, double slidingScope) =>
        (int)Math.Floor(cursor / slidingScope * cutScope);

    /// <summary>反解光标位置；在基准附近枚举整数，把量化误差压到最小。</summary>
    public static int? CursorFor(int x, int cutScope, double slidingScope, int span = Span)
    {
        if (cutScope <= 0 || !(slidingScope > 0)) return null;
        if (x < 0 || x > cutScope) return null;
        var Base = (int)Math.Round(x / (double)cutScope * slidingScope, MidpointRounding.AwayFromZero);
        int? best = null;
        var bestError = int.MaxValue;
        for (var offset = -span; offset <= span; offset++)
        {
            var cursor = Base + offset;
            if (cursor < 0) continue;
            var error = Math.Abs(Submitted(cursor, cutScope, slidingScope) - x);
            if (error < bestError)
            {
                bestError = error;
                best = cursor;
            }
            if (error == 0) break;
        }
        return best;
    }

    /// <summary>把缺口偏移 x 变成一次拖动。量不到合法几何、或 x 越界时返回 null，绝不猜。</summary>
    public static Plan? MakePlan(int x, Geometry geometry, int span = Span)
    {
        var cursor = CursorFor(x, geometry.CutScope, geometry.SlidingScope, span);
        if (cursor == null) return null;
        var submitted = Submitted(cursor.Value, geometry.CutScope, geometry.SlidingScope);
        return new Plan(cursor.Value, submitted, cursor.Value - geometry.CursorNow);
    }
}
