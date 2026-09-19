using CampusEntry.Core;
using Xunit;

namespace CampusEntry.Tests;

/// <summary>滑块定位（docs/CORE-SPEC.md §5.2/§7 合成用例，与 Android 端 SliderSolverTest 等价）。</summary>
public class SliderSolverTests
{
    /// <summary>220×60 背景（随机但有种子），30×60 模板 = 背景在 x0 处的原样裁剪。</summary>
    private static (int[] bg, int[] slider) MakePair(int x0, int seed)
    {
        var rng = new Random(seed);
        const int bgW = 220, bgH = 60, slW = 30, slH = 60;
        var bg = new int[bgW * bgH];
        for (var i = 0; i < bg.Length; i++)
        {
            var r = rng.Next(256);
            var g = rng.Next(256);
            var b = rng.Next(256);
            bg[i] = (0xFF << 24) | (r << 16) | (g << 8) | b;
        }
        var slider = new int[slW * slH];
        for (var y = 0; y < slH; y++)
            for (var x = 0; x < slW; x++)
                slider[y * slW + x] = bg[y * bgW + x0 + x];
        return (bg, slider);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(37)]
    [InlineData(100)]
    [InlineData(190)]
    public void 合成背景上定位精确(int x0)
    {
        var (bg, slider) = MakePair(x0, seed: 42 + x0);
        Assert.Equal(x0, SliderSolver.Solve(bg, 220, 60, slider, 30, 60));
    }

    [Fact]
    public void 模板全黑_掩码为零_放弃()
    {
        var (bg, _) = MakePair(100, seed: 7);
        var slider = new int[30 * 60]; // 全 0：RGB 全 0，掩码内没有像素
        Assert.Null(SliderSolver.Solve(bg, 220, 60, slider, 30, 60));
    }

    /// <summary>
    /// 纯白模板（掩码内每个像素都是 255）：**给出候选，而不是放弃**。
    /// <para>
    /// 旧实现用的是逐通道减均值（等价 cv2 <c>TmCcoeffNormed</c>）：方差为 0 就无从归一化，
    /// 只能放弃。2026-09 换成不减均值的度量后，纯白模板有非零能量，因此会正常给出候选——
    /// 参考实现同样是这个行为（ccoeff 路径报「未得到任何有效位置」，ccorr 路径正常返回）。
    /// </para>
    /// <para>
    /// <b>为什么只断言非空、不断言具体列号</b>：纯白模板是**退化输入**。模板均匀时，
    /// 背景里任何一个"内部均匀"的窗口都恰好与模板成正比，相关度**精确等于 1.0**——
    /// 全暗的窗口和真正对齐亮块的窗口同分，度量在这里没有分辨力，谁赢只取决于扫描顺序
    /// 与浮点舍入。断言某个具体列号会得到一个靠不住的测试。真正有分辨力的用例是
    /// <see cref="合成背景上定位精确"/>（模板是背景的原样裁剪，有内部纹理）。
    /// </para>
    /// </summary>
    [Fact]
    public void 模板纯白_仍有能量_给出候选而非放弃()
    {
        const int bgW = 220, bgH = 60, slW = 30, slH = 60, brightX = 60;
        var bg = new int[bgW * bgH];
        Array.Fill(bg, unchecked((int)0xFF1E1E1E));
        for (var y = 0; y < bgH; y++)
            for (var x = brightX; x < brightX + slW; x++)
                bg[y * bgW + x] = unchecked((int)0xFFFAFAFA);
        var slider = new int[slW * slH];
        Array.Fill(slider, unchecked((int)0xFFFFFFFF));

        Assert.NotNull(SliderSolver.Solve(bg, bgW, bgH, slider, slW, slH));
    }

    [Fact]
    public void 尺寸不合法_放弃()
    {
        var (bg, slider) = MakePair(10, seed: 3);
        Assert.Null(SliderSolver.Solve(bg, 20, 60, slider, 30, 60)); // 模板比背景宽
        Assert.Null(SliderSolver.Solve(bg, 220, 60, slider, 31, 60));
        Assert.Null(SliderSolver.Solve(Array.Empty<int>(), 220, 60, slider, 30, 60));
    }
}


