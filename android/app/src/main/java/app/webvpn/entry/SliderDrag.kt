package app.webvpn.entry

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * 滑块拖动换算：缺口在背景图里的像素偏移 → 手柄要拖到哪儿。
 *
 * **这段算术必须留在这里，不要写回注入页面的 JS 字面量。**
 * 它曾经只存在于那段字符串里，于是「把提交值域当成滑轨长度」这种 5% 的系统性偏差一路活到了
 * 真机上——三次拖动全部偏短，而电脑上一条测试都拦不住。
 *
 * 实测契约（`docs/PROTOCOL.md` §6、`docs/CORE-SPEC.md` §5.3）：
 *
 * ```
 * 值域     = 背景图自然宽 − 滑块图自然宽        （440 − 80 = 360）
 * 滑轨长度 = 容器渲染宽 − 手柄内容宽            （zoom=0.75 时 330 − 45 = 285）
 * 提交值   = parseInt(光标 / 滑轨长度 × 值域)    ← 页面自己的算法
 * 反解     = 光标 = x / 值域 × 滑轨长度
 * ```
 *
 * 两个必须记住的点：
 * 1. **滑轨长度不是 `值域 × zoom`**（那是 270，不是 285）。滑轨是手柄能走的显示层像素，
 *    值域是提交值的范围，两者是不同的量。
 * 2. **手柄宽不能用 `offsetWidth`**：它含 1px+1px 边框（47 而不是 45），滑轨会被算成 283，
 *    提交值整体偏 2px，正好吃掉服务端的 ±2 容差。
 */
object SliderDrag {

    /** 反解时在手柄位置附近枚举多少个整数，用来把量化误差压到最小。 */
    private const val SPAN = 4

    /** 页面上量到的几何。全部是**渲染**尺寸（CSS 像素），不是自然尺寸。 */
    data class Geometry(
            /** `.ap-container` 的渲染宽，也就是「440 × zoom」那个量。 */
            val containerWidth: Double,
            /** 背景图自身的渲染宽。正常情况下与 [containerWidth] 相等，不等就说明容器有内边距。 */
            val backgroundWidth: Double,
            val backgroundNaturalWidth: Int,
            val sliderNaturalWidth: Int,
            /** 手柄的渲染宽，**含边框**。 */
            val handleOuterWidth: Double,
            /** 手柄左右边框之和。 */
            val handleBorderWidth: Double,
            /** 手柄的视口左边缘。 */
            val handleLeft: Double,
            /** 轨道的视口左边缘。 */
            val trackLeft: Double,
    ) {
        /** 提交值的值域：两图自然宽之差（实测 440 − 80 = 360）。 */
        val cutScope: Int get() = backgroundNaturalWidth - sliderNaturalWidth

        /** 手柄的内容宽（去掉边框）。页面内部用的是这个：`60 × zoom`。 */
        val handleWidth: Double get() = handleOuterWidth - handleBorderWidth

        /**
         * 手柄能走的显示层像素。
         *
         * 与实测契约里的 `containerWidth × (440 − 60) ÷ 440` **代数等价**：手柄内容宽正是
         * `60 × zoom`，所以这里用测量值，少一个写死的常量，页面改了手柄尺寸也不会悄悄算错。
         */
        val slidingScope: Double get() = containerWidth - handleWidth

        /**
         * 手柄此刻的位置，也就是页面内部的 `start.cursor`。
         *
         * 位移是**相对量**（`pos = (clientX − start.x) + start.cursor`），所以拖动量要用它做基准：
         * 万一上一张图失败后手柄没有回到最左边，按「从 0 开始拖」算就会整体偏。
         */
        val cursorNow: Double get() = handleLeft - trackLeft

        /** 量到的容器宽与背景图渲染宽是否一致。不一致时上层的日志会带着它，便于发现容器有内边距。 */
        val containerMatchesImage: Boolean get() = abs(containerWidth - backgroundWidth) < 1.0
    }

    /** 量几何的结果。测不到时要说清是哪一种，不要静默跳过。 */
    sealed class Probe {
        class Ready(val geometry: Geometry) : Probe()
        class Failed(val reason: String) : Probe()
    }

    /** 一次拖动要做的事：光标该在哪、页面会提交什么、相对当前要移动多少。 */
    data class Plan(val cursor: Int, val submitted: Int, val delta: Double)

    /** 解析 [PageJs.SLIDER_GEOMETRY] 的回传值。 */
    fun probe(raw: String?): Probe {
        val value = raw?.trim()?.trim('"').orEmpty()
        return when (value) {
            "none" -> Probe.Failed("页面上没有滑块容器")
            "missing" -> Probe.Failed("滑块容器里缺少轨道、手柄或图片元素")
            "error" -> Probe.Failed("页面读取几何时抛错")
            else -> {
                val parts = value.split('|')
                if (parts.size != 9 || parts[0] != "geom") {
                    Probe.Failed("几何回传值不认得：$value")
                } else {
                    val numbers = ArrayList<Double>(8)
                    for (i in 1..8) {
                        numbers.add(parts[i].toDoubleOrNull() ?: return Probe.Failed("几何第 $i 个值不是数字：${parts[i]}"))
                    }
                    Probe.Ready(Geometry(
                            containerWidth = numbers[0],
                            backgroundWidth = numbers[1],
                            backgroundNaturalWidth = numbers[2].toInt(),
                            sliderNaturalWidth = numbers[3].toInt(),
                            handleOuterWidth = numbers[4],
                            handleBorderWidth = numbers[5],
                            handleLeft = numbers[6],
                            trackLeft = numbers[7]))
                }
            }
        }
    }

    /**
     * 页面会提交的值：`parseInt(光标 / 滑轨长度 × 值域)`。
     *
     * `parseInt` 对非负数就是向下取整，所以用 [floor]。
     */
    fun submitted(cursor: Int, cutScope: Int, slidingScope: Double): Int =
            floor(cursor / slidingScope * cutScope).toInt()

    /**
     * 反解光标位置。
     *
     * 基准是 `x / 值域 × 滑轨长度`；因为渲染像素比提交值域窄（360 → 285），量化会带来 0~1px 误差，
     * 所以在基准附近枚举整数，取「提交值最贴近 [x]」的那个。
     */
    fun cursorFor(x: Int, cutScope: Int, slidingScope: Double, span: Int = SPAN): Int? {
        if (cutScope <= 0 || !(slidingScope > 0)) return null
        if (x < 0 || x > cutScope) return null
        // 注意别写成整数除法：x 与 cutScope 都是 Int，x / cutScope 会先截成 0
        val base = (x.toDouble() / cutScope * slidingScope).roundToInt()
        var best: Int? = null
        var bestError = Int.MAX_VALUE
        for (offset in -span..span) {
            val cursor = base + offset
            if (cursor < 0) continue
            val error = abs(submitted(cursor, cutScope, slidingScope) - x)
            if (error < bestError) {
                bestError = error
                best = cursor
            }
            if (error == 0) break
        }
        return best
    }

    /** 把缺口偏移 [x] 变成一次拖动。量不到合法几何、或 x 越界时返回 null，绝不猜。 */
    fun plan(x: Int, geometry: Geometry, span: Int = SPAN): Plan? {
        val cursor = cursorFor(x, geometry.cutScope, geometry.slidingScope, span) ?: return null
        val submitted = submitted(cursor, geometry.cutScope, geometry.slidingScope)
        return Plan(cursor = cursor, submitted = submitted, delta = cursor - geometry.cursorNow)
    }
}
