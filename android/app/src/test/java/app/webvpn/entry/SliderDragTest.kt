package app.webvpn.entry

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 拖动换算。
 *
 * 这套用例的意义很直接：这段算术以前只写在注入页面的 JS 字面量里，于是「把提交值域当成滑轨长度」
 * 的错误一路活到了真机上——三次拖动全部偏短。现在它在这里，并且下面第一条用例就钉住了那个数字。
 */
class SliderDragTest {

    init {
        // JVM 单测没有 assets：从源码树读同一批文件（走目录树向上找到仓库根的 shared/js）
        var dir: java.io.File? = java.io.File(System.getProperty("user.dir") ?: ".")
        while (dir != null && !java.io.File(dir, "shared/js").isDirectory) dir = dir.parentFile
        val root = java.io.File(checkNotNull(dir) { "从 ${System.getProperty("user.dir")} 向上找不到 shared/js" }, "shared/js")
        PageJs.prepareSource { name -> java.io.File(root, name).readText() }
    }

    /** 真机上的几何：容器 440×0.75=330，手柄 60×0.75=45（加 1px+1px 边框后 47）。 */
    private fun geometry(handleLeft: Double = 0.0, trackLeft: Double = 0.0) = SliderDrag.Geometry(
            containerWidth = 330.0,
            backgroundWidth = 330.0,
            backgroundNaturalWidth = 440,
            sliderNaturalWidth = 80,
            handleOuterWidth = 47.0,
            handleBorderWidth = 2.0,
            handleLeft = handleLeft,
            trackLeft = trackLeft)

    @Test
    fun 滑轨长度是三百八十五而不是值域乘缩放() {
        val g = geometry()
        assertEquals("提交值域 = 两图自然宽之差", 360, g.cutScope)
        assertEquals("手柄内容宽要去掉边框", 45.0, g.handleWidth, 1e-9)
        assertEquals("滑轨长度 = 容器渲染宽 − 手柄内容宽", 285.0, g.slidingScope, 1e-9)

        // 这两个数字就是当初的错：值域 360 乘缩放 0.75 得 270，比真值短 15px；
        // 拿含边框的 offsetWidth(47) 去算则得 283，比真值短 2px，正好吃掉服务端的 ±2 容差。
        assertEquals(270.0, 360.0 * 0.75, 1e-9)
        assertEquals(283.0, 330.0 - 47.0, 1e-9)

        // 与实测契约里的写法代数等价：容器宽 × (440 − 60) ÷ 440
        assertEquals(285.0, 330.0 * (440.0 - 60.0) / 440.0, 1e-9)
        assertEquals(g.slidingScope, 330.0 * (440.0 - 60.0) / 440.0, 1e-9)
    }

    @Test
    fun 反解出能精确命中的光标() {
        val plan = SliderDrag.plan(200, geometry())
        assertTrue(plan != null)
        assertEquals("基准 round(200/360*285)=158，±4 里 159 能精确提交 200", 159, plan!!.cursor)
        assertEquals(200, plan.submitted)
    }

    @Test
    fun 压缩导致的固定差不超过一像素() {
        // 360 → 285 的压缩让少量偏移只能落在邻格；实测契约说 75/361 会固定差 1px
        val plan = SliderDrag.plan(100, geometry())
        assertTrue(plan != null)
        assertEquals(1, abs(plan!!.submitted - 100))
    }

    @Test
    fun 全域误差都不超过一像素且可精确命中的有二百八十六个() {
        val g = geometry()
        var exact = 0
        var maxError = 0
        for (x in 0..g.cutScope) {
            val plan = SliderDrag.plan(x, g)
            assertTrue("x=$x 应当能反解", plan != null)
            val error = abs(plan!!.submitted - x)
            if (error == 0) exact++
            if (error > maxError) maxError = error
            assertTrue("x=$x 的光标不能为负", plan.cursor >= 0)
            assertTrue("x=$x 的光标不能越出滑轨", plan.cursor <= g.slidingScope + 1)
        }
        assertEquals("实测契约：286/361 个偏移可精确命中", 286, exact)
        assertEquals("其余的最多差 1px，落在服务端 ±2 容差内", 1, maxError)
    }

    @Test
    fun 位移是相对当前光标位置的() {
        // 手柄没在最左边时，按「从 0 开始拖」算就会整体偏
        val atHome = SliderDrag.plan(200, geometry(handleLeft = 10.0, trackLeft = 10.0))
        assertEquals(0.0, geometry(handleLeft = 10.0, trackLeft = 10.0).cursorNow, 1e-9)
        assertEquals(159.0, atHome!!.delta, 1e-9)

        val moved = SliderDrag.plan(200, geometry(handleLeft = 40.0, trackLeft = 10.0))
        assertEquals(30.0, geometry(handleLeft = 40.0, trackLeft = 10.0).cursorNow, 1e-9)
        assertEquals("已经拖到 30 了，只需要再走 129", 129.0, moved!!.delta, 1e-9)
        assertEquals(159, moved.cursor)
    }

    @Test
    fun 几何不合法时不猜() {
        assertNull("值域为 0", SliderDrag.plan(10, geometry().copy(sliderNaturalWidth = 440)))
        assertNull("滑轨为 0", SliderDrag.plan(10, geometry().copy(containerWidth = 45.0,
                handleOuterWidth = 47.0, handleBorderWidth = 2.0)))
        assertNull("偏移越界", SliderDrag.plan(361, geometry()))
        assertNull("偏移为负", SliderDrag.plan(-1, geometry()))
    }

    @Test
    fun 容器宽与背景图渲染宽的关系会被报出来() {
        assertTrue(geometry().containerMatchesImage)
        assertFalse(geometry().copy(backgroundWidth = 325.0).containerMatchesImage)
    }

    @Test
    fun 解析页面量回来的几何() {
        val raw = "\"geom|330|330|440|80|47|2|10|10\""
        val ready = SliderDrag.probe(raw)
        assertTrue(ready is SliderDrag.Probe.Ready)
        val g = (ready as SliderDrag.Probe.Ready).geometry
        assertEquals(285.0, g.slidingScope, 1e-9)
        assertEquals(0.0, g.cursorNow, 1e-9)
    }

    @Test
    fun 量不到几何时要说清是哪一种() {
        assertEquals("页面上没有滑块容器", (SliderDrag.probe("none") as SliderDrag.Probe.Failed).reason)
        assertEquals("滑块容器里缺少轨道、手柄或图片元素", (SliderDrag.probe("missing") as SliderDrag.Probe.Failed).reason)
        assertEquals("页面读取几何时抛错", (SliderDrag.probe("error") as SliderDrag.Probe.Failed).reason)
        assertTrue(SliderDrag.probe(null) is SliderDrag.Probe.Failed)
        assertTrue(SliderDrag.probe("geom|1|2|3") is SliderDrag.Probe.Failed)
        assertTrue("数字坏了也要说清", SliderDrag.probe("geom|a|330|440|80|47|2|0|0") is SliderDrag.Probe.Failed)
    }

    @Test
    fun 真机那三次偏移的用例() {
        // 来自 2026-09-19 12:22 的真机日志：缺口在 63/141/269，旧实现反解出的光标是 47/106/202。
        // 页面按真实滑轨 285 算，实际只提交了 59/133/255 —— 全部偏短，且 x 越大偏得越多。
        val g = geometry()
        assertEquals("三次的实际提交值", listOf(59, 133, 255), listOf(47, 106, 202).map {
            SliderDrag.submitted(it, g.cutScope, g.slidingScope)
        })

        // 修好之后：同样的缺口，页面会精确收到那三个数
        val cases = listOf(Triple(63, 50, 63), Triple(141, 112, 141), Triple(269, 213, 269))
        for ((x, cursor, submitted) in cases) {
            val plan = SliderDrag.plan(x, g)
            assertTrue("x=$x 应当能反解", plan != null)
            assertEquals("x=$x 的光标", cursor, plan!!.cursor)
            assertEquals("x=$x 的提交值", submitted, plan.submitted)
        }
    }

    @Test
    fun 换任何缩放都比实测契约的写法一致() {
        // 契约写法是 容器渲染宽 × (440 − 60) ÷ 440。这里用一组差异很大的缩放来证明两者代数等价——
        // 也就是说服务器把 zoom 从 0.75 改成别的值，或者在别的手机上按别的比例渲染，换算都成立。
        for (zoom in listOf(0.4, 0.6, 0.75, 0.9, 1.0, 1.25, 2.0)) {
            val container = 440.0 * zoom
            val handle = 60.0 * zoom
            val g = SliderDrag.Geometry(
                    containerWidth = container,
                    backgroundWidth = container,
                    backgroundNaturalWidth = 440,
                    sliderNaturalWidth = 80,
                    handleOuterWidth = handle + 2.0,   // 含 1px+1px 边框
                    handleBorderWidth = 2.0,
                    handleLeft = 0.0,
                    trackLeft = 0.0)
            assertEquals("zoom=$zoom 的滑轨", container - handle, g.slidingScope, 1e-9)
            assertEquals("zoom=$zoom 与契约写法一致", container * (440.0 - 60.0) / 440.0,
                    g.slidingScope, 1e-9)
        }
    }

    @Test
    fun 换任何尺寸都只是按比例缩放() {
        // 尺寸、比例、分辨率都不该影响结论：式子里的量与设备无关，全是页面自己报的渲染尺寸。
        // 这里挑两个「别的手机」的形状：窄屏（容器更小）与高像素密度（出现小数 CSS 像素）。
        for (scale in listOf(0.5, 0.75, 1.0, 1.5, 2.0)) {
            for (fraction in listOf(0.0, 0.333, 0.5, 0.75)) {
                val container = 330.0 * scale + fraction
                val handle = 45.0 * scale
                val g = SliderDrag.Geometry(container, container, 440, 80,
                        handle + 2.0, 2.0, 0.0, 0.0)
                var maxError = 0
                for (x in 0..g.cutScope) {
                    val plan = SliderDrag.plan(x, g) ?: continue
                    val error = abs(plan.submitted - x)
                    if (error > maxError) maxError = error
                }
                // cutScope 不随容器缩放变化（它来自图片自然尺寸），所以滑轨越短压缩越厉害；
                // 但误差始终不超过 1，落在服务端 ±2 容差内。
                assertTrue("scale=$scale fraction=$fraction 的最大误差应 ≤1，实为 $maxError",
                        maxError <= 1)
            }
        }
    }

    @Test
    fun 偏移值域来自图片自然尺寸与设备无关() {
        // 值域是 440 − 80 = 360，来自服务端下发的两张图，跟手机屏幕没有关系
        val g = geometry()
        assertEquals(360, g.cutScope)
        assertEquals("换成另一台手机也只是渲染尺寸变了",
                g.cutScope, geometry().copy(containerWidth = 220.0, backgroundWidth = 220.0).cutScope)
    }

    @Test
    fun 滑轨再短也留有余量() {
        // 提交值域固定 360，而滑轨是渲染出来的像素。两者压缩比越大，量化误差越大，
        // 所以「滑轨被渲染得很小」是这套换算唯一的真实边界。这里把它量出来。
        fun maxError(travel: Int): Int {
            val g = SliderDrag.Geometry(
                    containerWidth = travel + 45.0,
                    backgroundWidth = travel + 45.0,
                    backgroundNaturalWidth = 440,
                    sliderNaturalWidth = 80,
                    handleOuterWidth = 47.0,
                    handleBorderWidth = 2.0,
                    handleLeft = 0.0,
                    trackLeft = 0.0)
            return (0..g.cutScope).mapNotNull { x ->
                SliderDrag.plan(x, g)?.let { abs(it.submitted - x) }
            }.max()
        }

        assertEquals("手机上实测的滑轨（285）", 1, maxError(285))
        assertTrue("滑轨短到 100px 仍落在服务端 ±2 容差内：余量约 3 倍", maxError(100) <= 2)
    }

    @Test
    fun 注入脚本里的位移按两位小数写() {
        // 用 Locale.US 格式化，免得在某些区域设置下写成 "129,00" 让 JS 解析成别的数
        val js = PageJs.dragJs(SliderDrag.plan(200, geometry(handleLeft = 40.0, trackLeft = 10.0))!!)
        assertTrue("位移应当以 129.00 结尾：$js", js.endsWith("(129.00)"))
    }
}
