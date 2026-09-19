package app.webvpn.entry

import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 滑块求解的合成用例：把背景图的一段原样当成滑块图，正确答案就是那一段的左边界列号。
 *
 * 真实语料上的精度见验证工作区（`D:\webvpn`）的技术报告；这里只钉住「同一段能找回来、
 * 不合法输入不崩也不瞎给答案」这两件事——真机上还有一次端到端验证。
 */
class SliderSolverTest {

    private val bgW = 220
    private val bgH = 60
    private val slW = 30
    private val slH = 60

    /** 非重复图案：随机但有种子，保证用例可复现。 */
    private fun background(seed: Int): IntArray {
        val rnd = Random(seed)
        return IntArray(bgW * bgH) {
            // 亮度要明显高于掩码阈值（12000），否则整幅模板会被判成"几乎全透明"
            val r = 60 + rnd.nextInt(180)
            val g = 60 + rnd.nextInt(180)
            val b = 60 + rnd.nextInt(180)
            (0xFF shl 24) or (r shl 16) or (g shl 8) or b
        }
    }

    private fun crop(bg: IntArray, x0: Int): IntArray {
        val out = IntArray(slW * slH)
        for (y in 0 until slH) {
            for (x in 0 until slW) out[y * slW + x] = bg[y * bgW + x0 + x]
        }
        return out
    }

    @Test
    fun 能把同一段图案找回来() {
        for (x0 in listOf(0, 1, 37, 100, bgW - slW)) {
            val bg = background(seed = 20260919 + x0)
            val sl = crop(bg, x0)
            assertEquals("x0=$x0", x0,
                    SliderSolver.solve(bg, bgW, bgH, sl, slW, slH))
        }
    }

    @Test
    fun 尺寸不合法时返回空() {
        val bg = background(1)
        val sl = crop(bg, 0)
        assertNull("滑块比背景还宽", SliderSolver.solve(bg, bgW, bgH, sl, bgW + 1, slH))
        assertNull(SliderSolver.solve(bg, bgW, bgH, sl, 0, slH))
        assertNull(SliderSolver.solve(IntArray(0), 0, 0, sl, slW, slH))
    }

    @Test
    fun 模板几乎全透明时返回空() {
        val bg = background(2)
        // 全黑：加权亮度 0，掩码内一个像素都没有
        val dark = IntArray(slW * slH) { (0xFF shl 24) }
        assertNull(SliderSolver.solve(bg, bgW, bgH, dark, slW, slH))
    }

    /**
     * 纯白模板（掩码内每个像素都是 255）：**给出候选，而不是放弃**。
     *
     * 旧实现做的是逐通道减均值（ccoeff）：方差为 0 就无从归一化，只能放弃。
     * 2026-09 换成不减均值的度量（ccorr）后，纯白模板有非零能量，因此会正常给出候选——
     * 参考实现同样是这个行为。语料依据见 `D:\webvpn\lab\bench_campusentry_csharp`。
     *
     * **为什么只断言非空、不断言具体列号**：纯白模板是退化输入。模板均匀时，背景里任何一个
     * "内部均匀"的窗口都恰好与模板成正比、相关度精确等于 1.0，度量在这里没有分辨力，
     * 谁赢只取决于扫描顺序与浮点舍入。有分辨力的用例是「合成背景上定位精确」。
     */
    @Test
    fun 纯白模板仍有能量时给出候选而不是放弃() {
        val bg = background(3)
        val white = IntArray(slW * slH) { 0xFFFFFFFF.toInt() }
        assertNotNull(SliderSolver.solve(bg, bgW, bgH, white, slW, slH))
    }

    @Test
    fun 掩码阈值是加权和而不是平均值() {
        // 文档里的判据：299R+587G+114B > 12000。这里把三个通道各取一点点，验证它确实过阈值。
        assertTrue(299 * 20 + 587 * 20 + 114 * 20 > SliderSolver.DIM_THRESHOLD)
        assertTrue(299 * 1 + 587 * 1 + 114 * 1 < SliderSolver.DIM_THRESHOLD)
    }
}
