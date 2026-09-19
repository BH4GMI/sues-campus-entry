namespace CampusEntry.Core;

/// <summary>
/// 滑块缺口定位：<b>整幅</b>滑块图作模板，在背景图上按列滑窗，取相关度最高的列。
/// 与 Android 端 <c>SliderSolver.kt</c> 逐条一致（docs/CORE-SPEC.md §5.2）：
/// 亮度掩码 299R+587G+114B&gt;12000、掩码内<b>三通道展平且不减均值</b>的归一化互相关、只搜 1.0 档。
/// 服务端容差 ±2px，返回的列号可以直接交给页面提交。
/// </summary>
/// <remarks>
/// <b>度量为什么是「不减均值」这一版（2026-09 修正）</b>
/// <para>
/// 旧实现做的是<b>逐通道减均值再归一化</b>（等价 cv2 的 <c>TM_CCOEFF_NORMED</c>，参考实现里叫
/// <c>ccoeff</c>）。换到真值语料上一量才发现它明显更差：
/// <c>D:\webvpn\lab\bench_campusentry_csharp</c> 用 80 例真值语料对照，旧实现的输出与
/// 参考实现的 <c>ccoeff</c> 路径<b>逐例完全相同（80/80）</b>——也就是说移植本身是忠实的，
/// 差的只是度量这一个选择：同一个口径下 <c>ccoeff</c> 首选命中 64/80（80.0%），
/// 而本文件现在用的「不减均值」版是 77/80（96.2%）。
/// </para>
/// <para>
/// 原因是服务端把缺口画成了拼图块的<b>逐通道仿射变换</b>（实测 <c>bg ≈ a·piece + b</c>，
/// a 在 B/G/R 上约 0.16/0.47/0.68，b 约 138/119/84，整体呈"掺白 + 去饱和"）。
/// 展平后的归一化互相关只能归一化倍数、归一化不了平移，于是真值处的峰被这个平移压低，
/// 某些亮区的假峰反而更高。**减均值会把这条平移当噪声压掉，恰好把真值处的优势一起压没了。**
/// </para>
/// <para>
/// 为什么 55 项单测当时全绿还是漏了它：单测用的是<b>合成图</b>，合成图里没有服务端那套仿射变换，
/// 两种度量在合成图上下同样的结论。**单测证明的是"数学没错"，证明不了"真图上识别得准"**——
/// 后者要靠真值语料，就是上面那个基准。改这个度量时也必须回去复跑它。
/// </para>
/// </remarks>
public static class SliderSolver
{
    public const int DimThreshold = 12000;

    /// <summary>像素布局与 Android Bitmap 一致：0xAARRGGBB。</summary>
    public static int? Solve(int[] bg, int bgW, int bgH, int[] slider, int slW, int slH)
    {
        if (slW <= 0 || slH <= 0 || bgW <= 0 || bgH <= 0) return null;
        if (slW > bgW || slH > bgH) return null;
        var n = slW * slH;
        if (slider.Length < n || bg.Length < bgW * bgH) return null;

        // 模板：只保留掩码内的像素（行主序，与参考实现的遍历顺序一致）
        var mx = new int[n];
        var my = new int[n];
        var tr = new int[n];
        var tg = new int[n];
        var tb = new int[n];
        var m = 0;
        double energyT = 0;                 // Σ(r² + g² + b²)：展平后的模板能量，滑窗里是常量
        for (var y = 0; y < slH; y++)
        {
            for (var x = 0; x < slW; x++)
            {
                var p = slider[y * slW + x];
                var r = (p >> 16) & 0xFF;
                var g = (p >> 8) & 0xFF;
                var b = p & 0xFF;
                if (299 * r + 587 * g + 114 * b <= DimThreshold) continue;
                mx[m] = x;
                my[m] = y;
                tr[m] = r;
                tg[m] = g;
                tb[m] = b;
                energyT += (double)r * r + (double)g * g + (double)b * b;
                m++;
            }
        }
        // 掩码内像素太少时统计量不可靠；这个下界在 80 例语料上没有触发过（旧实现在同一批上
        // 与参考逐例一致，说明它同样没触发），保留它只是防御空/退化模板。
        if (m < 64) return null;

        var normT = Math.Sqrt(energyT);
        if (normT <= 0.0) return null;

        var bestX = -1;
        var bestScore = double.NegativeInfinity;
        var maxX = bgW - slW;
        for (var ox = 0; ox <= maxX; ox++)
        {
            double num = 0, den = 0;
            for (var i = 0; i < m; i++)
            {
                var p = bg[my[i] * bgW + ox + mx[i]];
                var ir = (p >> 16) & 0xFF;
                var ig = (p >> 8) & 0xFF;
                var ib = p & 0xFF;
                num += (double)tr[i] * ir + (double)tg[i] * ig + (double)tb[i] * ib;
                den += (double)ir * ir + (double)ig * ig + (double)ib * ib;
            }
            if (den <= 0.0) continue;
            var score = num / (normT * Math.Sqrt(den));
            // 严格大于：并列时保留更小的 x，与参考实现「按分值降序稳定排序」的结果一致
            if (score > bestScore)
            {
                bestScore = score;
                bestX = ox;
            }
        }
        return bestX >= 0 ? bestX : null;
    }
}
