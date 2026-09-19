package app.webvpn.entry

import kotlin.math.sqrt

/**
 * 滑块缺口定位：**整幅**滑块图作模板，在背景图上按列滑窗，取相关度最高的列。
 *
 * 参数全部取自验证工作区的技术报告与 80 例真值语料：
 * - 模板必须是整幅滑块图（裁剪会整体偏 +19px）；
 * - 亮度掩码 `299R+587G+114B > 12000`，只在掩码内计算；
 * - 掩码内**三通道展平、不减均值**的归一化互相关（参考实现里叫 `ccorr`，等价
 *   `cv2.TM_CCORR_NORMED`）；
 * - 只搜 1.0 档（不缩放）——这是「单次提交 |x−真值|≤2」判据下的最优配置。
 *
 * 服务端容差 ±2px，因此返回的列号可以直接交给页面提交。
 * 纯函数、不依赖 Android：位图解码由调用方负责，便于在 JVM 上直接单测。
 *
 * ## 度量为什么是「不减均值」这一版（2026-09 修正）
 *
 * 本文件此前的实现做的是**逐通道减均值再归一化**（`ccoeff`），而这份注释当时写的是
 * `ccorr` —— **注释与实现互相矛盾，缺陷就是这么藏住的**。真值语料一量就露了：
 *
 * | 度量 | 首选命中（80 例，只搜 1.0 档） |
 * | --- | --- |
 * | `ccorr`（不减均值，三通道展平） | **77/80（96.2%）** |
 * | `ccoeff`（逐通道减均值） | 64/80（80.0%） |
 *
 * 对照基准在 `D:\webvpn\lab\bench_campusentry_csharp`；PC 端换度量后与参考实现
 * **逐例一致 80/80**，本文件与 `SliderSolver.swift` 必须给出同一张答案表。
 *
 * 原因：服务端把缺口画成了拼图块的**逐通道仿射变换**（实测 `bg ≈ a·piece + b`），
 * 展平后的归一化互相关只能归一化倍数、归一化不了平移，减均值会把这条平移当噪声压掉，
 * 连真值处的优势一起压没。**合成图单测下两种度量给出同一答案，所以单测全绿也发现不了它**——
 * 改这个度量必须回到上面那个语料基准复跑。
 */
object SliderSolver {

    /** 亮度掩码阈值（加权和，不是平均值）。 */
    const val DIM_THRESHOLD = 12000

    /**
     * @return 缺口左边界在背景图上的列号；无法定位（尺寸不合法、掩码内无像素、或模板能量为 0）返回 null。
     */
    fun solve(bg: IntArray, bgW: Int, bgH: Int, slider: IntArray, slW: Int, slH: Int): Int? {
        if (slW <= 0 || slH <= 0 || bgW <= 0 || bgH <= 0) return null
        if (slW > bgW || slH > bgH) return null
        val n = slW * slH
        if (slider.size < n || bg.size < bgW * bgH) return null

        // 模板：只保留掩码内的像素（行主序，与参考实现的遍历顺序一致）
        val mx = IntArray(n)
        val my = IntArray(n)
        val tr = IntArray(n)
        val tg = IntArray(n)
        val tb = IntArray(n)
        var m = 0
        var energyT = 0.0            // Σ(r² + g² + b²)：展平后的模板能量，滑窗里是常量
        for (y in 0 until slH) {
            for (x in 0 until slW) {
                val p = slider[y * slW + x]
                val r = (p ushr 16) and 0xFF
                val g = (p ushr 8) and 0xFF
                val b = p and 0xFF
                if (299 * r + 587 * g + 114 * b <= DIM_THRESHOLD) continue
                mx[m] = x
                my[m] = y
                tr[m] = r
                tg[m] = g
                tb[m] = b
                energyT += r.toDouble() * r + g.toDouble() * g + b.toDouble() * b
                m++
            }
        }
        // 掩码内像素太少时统计量不可靠；这个下界在 80 例语料上没有触发过，保留它只是防御退化模板。
        if (m < 64) return null

        val normT = sqrt(energyT)
        if (normT <= 0.0) return null

        var bestX = -1
        var bestScore = Double.NEGATIVE_INFINITY
        val maxX = bgW - slW
        for (ox in 0..maxX) {
            var num = 0.0
            var den = 0.0
            for (i in 0 until m) {
                val p = bg[my[i] * bgW + ox + mx[i]]
                val ir = (p ushr 16) and 0xFF
                val ig = (p ushr 8) and 0xFF
                val ib = p and 0xFF
                num += tr[i].toDouble() * ir + tg[i].toDouble() * ig + tb[i].toDouble() * ib
                den += ir.toDouble() * ir + ig.toDouble() * ig + ib.toDouble() * ib
            }
            if (den <= 0.0) continue
            val score = num / (normT * sqrt(den))
            // 严格大于：并列时保留更小的 x，与参考实现「按分值降序稳定排序」的结果一致
            if (score > bestScore) {
                bestScore = score
                bestX = ox
            }
        }
        return if (bestX >= 0) bestX else null
    }
}
