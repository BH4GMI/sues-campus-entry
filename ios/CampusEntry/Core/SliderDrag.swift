import Foundation

//  SliderDrag.swift —— 从 pc/src/CampusEntry/Core/SliderDrag.cs 逐条移植
//  （docs/CORE-SPEC.md §5.3 拖动换算、§7 测试向量）。
//
//  滑块拖动换算：缺口在背景图里的像素偏移 → 手柄要拖到哪儿。
//  这段算术必须留在能被单测覆盖的地方，不要写回注入页面的 JS 字面量。
//
//  结构映射（C# → Swift）：
//  - `static class`              → `public enum`（无 case，只有静态成员）
//  - `sealed record Geometry`    → `public struct Geometry` + 显式 `public init`（字段顺序与 C# 一致）
//  - `abstract record Probe`     → `public enum Probe`（求和类型；用
//    `if case .ready(let geometry) = probe` / `if case .failed(let reason) = probe` 取出，
//    对应 C# 的 `case Probe.Ready ready:` / `case Probe.Failed failed:`）
//  - `sealed record Plan`        → `public struct Plan`
//  - 公开成员按本工程 iOS 侧落地的命名习惯用小驼峰（与 Core/Sues.swift、Core/EntryFlow.swift、
//    Core/EntryHost.swift 的调用点一致），参数一律无标签，保持与 C#/Kotlin 相同的位次。
//
//  两个数字上的坑（C# 与原注释逐字保留）：滑轨长度**不是** `值域 × zoom`（那是 270，不是 285）；
//  手柄宽**不能**用 `offsetWidth`（含 1px+1px 边框是 47，滑轨会算成 283，提交值整体偏 2px，
//  正好吃掉服务端的 ±2 容差）。

/// 滑块拖动换算：缺口在背景图里的像素偏移 → 手柄要拖到哪儿。
/// 与 Android 端 `SliderDrag.kt`、PC 端 `SliderDrag.cs` 逐条一致（docs/CORE-SPEC.md §5.3）。
public enum SliderDrag {

    /// 页面上量到的几何。全部是**渲染**尺寸（CSS 像素），不是自然尺寸。
    public struct Geometry {
        /// `.ap-container` 的渲染宽，也就是「440 × zoom」那个量。
        public let containerWidth: Double
        /// 背景图自身的渲染宽。正常情况下与 containerWidth 相等，不等就说明容器有内边距。
        public let backgroundWidth: Double
        public let backgroundNaturalWidth: Int
        public let sliderNaturalWidth: Int
        /// 手柄的渲染宽，**含边框**。
        public let handleOuterWidth: Double
        /// 手柄左右边框之和。
        public let handleBorderWidth: Double
        /// 手柄的视口左边缘。
        public let handleLeft: Double
        /// 轨道的视口左边缘。
        public let trackLeft: Double

        public init(
            containerWidth: Double,
            backgroundWidth: Double,
            backgroundNaturalWidth: Int,
            sliderNaturalWidth: Int,
            handleOuterWidth: Double,
            handleBorderWidth: Double,
            handleLeft: Double,
            trackLeft: Double
        ) {
            self.containerWidth = containerWidth
            self.backgroundWidth = backgroundWidth
            self.backgroundNaturalWidth = backgroundNaturalWidth
            self.sliderNaturalWidth = sliderNaturalWidth
            self.handleOuterWidth = handleOuterWidth
            self.handleBorderWidth = handleBorderWidth
            self.handleLeft = handleLeft
            self.trackLeft = trackLeft
        }

        /// 提交值的值域：两图自然宽之差（实测 440 − 80 = 360）。
        public var cutScope: Int { backgroundNaturalWidth - sliderNaturalWidth }

        /// 手柄的内容宽（去掉边框）。页面内部用的是这个：`60 × zoom`。
        public var handleWidth: Double { handleOuterWidth - handleBorderWidth }

        /// 手柄能走的显示层像素 = 容器渲染宽 − 手柄内容宽。
        ///
        /// 与实测契约里的 `containerWidth × (440 − 60) ÷ 440` **代数等价**：手柄内容宽正是
        /// `60 × zoom`，所以这里用测量值，少一个写死的常量，页面改了手柄尺寸也不会悄悄算错。
        public var slidingScope: Double { containerWidth - handleWidth }

        /// 手柄此刻的位置，也就是页面内部的 `start.cursor`。
        /// 位移是**相对量**（`pos = (clientX − start.x) + start.cursor`），所以拖动量要以它为基准：
        /// 万一上一张图失败后手柄没有回到最左边，按「从 0 开始拖」算就会整体偏。
        public var cursorNow: Double { handleLeft - trackLeft }

        /// 量到的容器宽与背景图渲染宽是否一致。不一致时上层的日志会带着它，便于发现容器有内边距。
        public var containerMatchesImage: Bool { abs(containerWidth - backgroundWidth) < 1.0 }
    }

    /// 量几何的结果。测不到时要说清是哪一种，不要静默跳过。
    public enum Probe {
        case ready(Geometry)
        case failed(String)
    }

    /// 一次拖动要做的事：光标该在哪、页面会提交什么、相对当前要移动多少。
    public struct Plan {
        public let cursor: Int
        public let submitted: Int
        public let delta: Double

        public init(cursor: Int, submitted: Int, delta: Double) {
            self.cursor = cursor
            self.submitted = submitted
            self.delta = delta
        }
    }

    /// 解析 `slider-geometry.js` 的回传值。
    public static func parseProbe(_ raw: String?) -> Probe {
        let value = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        switch value {
        case "none":
            return .failed("页面上没有滑块容器")
        case "missing":
            return .failed("滑块容器里缺少轨道、手柄或图片元素")
        case "error":
            return .failed("页面读取几何时抛错")
        default:
            break
        }
        let parts = value.components(separatedBy: "|")
        if parts.count != 9 || parts[0] != "geom" {
            return .failed("几何回传值不认得：\(value)")
        }
        var numbers = [Double](repeating: 0, count: 8)
        for i in 1...8 {
            // C# 的 double.TryParse 会接受 "NaN"/"Infinity"（.NET Core 3.0+），随后 (int) 转换得到
            // 未定义值；Swift 的 Int(Double) 对非有限值直接陷入陷阱。这里把非有限值按「不是数字」
            // 拒掉，避免崩溃；正常路径（页面报真实几何）行为与 C# 完全一致。
            guard let d = Double(parts[i]), d.isFinite else {
                return .failed("几何第 \(i) 个值不是数字：\(parts[i])")
            }
            numbers[i - 1] = d
        }
        // C# 的 `(int)numbers[2]` 是向零截断；Swift 的 Int(Double) 在非有限或超范围时会陷阱，
        // 所以走 truncateToInt，失败时用与 C#「不是数字」同一个失败分支。
        guard let backgroundNaturalWidth = truncateToInt(numbers[2]) else {
            return .failed("几何第 3 个值不是数字：\(parts[3])")
        }
        guard let sliderNaturalWidth = truncateToInt(numbers[3]) else {
            return .failed("几何第 4 个值不是数字：\(parts[4])")
        }
        return .ready(Geometry(
            containerWidth: numbers[0],
            backgroundWidth: numbers[1],
            backgroundNaturalWidth: backgroundNaturalWidth,
            sliderNaturalWidth: sliderNaturalWidth,
            handleOuterWidth: numbers[4],
            handleBorderWidth: numbers[5],
            handleLeft: numbers[6],
            trackLeft: numbers[7]))
    }

    /// 页面会提交的值：`parseInt(光标 / 滑轨长度 × 值域)`。
    /// `parseInt` 对非负数就是向下取整，所以用向下取整（C# 是 `(int)Math.Floor(...)`）。
    public static func submitted(_ cursor: Int, _ cutScope: Int, _ slidingScope: Double) -> Int {
        // C# 先把 int 抬成 double 再乘除（`cursor / slidingScope * cutScope`），运算顺序不能变。
        let value = (Double(cursor) / slidingScope * Double(cutScope)).rounded(.down)
        // C# 的 `(int)` 强制转换对非有限/超范围的值是「未指定」，x64 上得到 int.MinValue；
        // Swift 的 Int(Double) 会直接陷阱，所以显式退回同一个值（32 位的 int.MinValue）。
        // 正常路径到不了这里：调用方都先经过 cursorFor 的 `slidingScope > 0` 校验。
        return truncateToInt(value) ?? Int(Int32.min)
    }

    /// 反解光标位置。
    ///
    /// 基准是 `x / 值域 × 滑轨长度`；因为渲染像素比提交值域窄（360 → 285），量化会带来 0~1px 误差，
    /// 所以在基准附近枚举整数，取「提交值最贴近 x」的那个。
    ///
    /// - Parameter span: 在基准附近枚举多少个整数（C# 的 `private const int Span`）。
    ///   C# 把默认值写成那个常量；Swift 的默认参数值在**调用方**求值，不能引用非 public 的声明，
    ///   所以这里直接写等值的字面量 `4`——与 C# 的 `Span` 严格一致，改动必须同步。
    public static func cursorFor(
        _ x: Int,
        _ cutScope: Int,
        _ slidingScope: Double,
        span: Int = 4
    ) -> Int? {
        if cutScope <= 0 || !(slidingScope > 0) { return nil }
        if x < 0 || x > cutScope { return nil }
        // 注意别写成整数除法：x 与 cutScope 都是 Int，x / cutScope 会先截成 0。
        // C# 的 MidpointRounding.AwayFromZero ↔ Swift 的 .toNearestOrAwayFromZero。
        guard let base = truncateToInt(
            (Double(x) / Double(cutScope) * slidingScope).rounded(.toNearestOrAwayFromZero)
        ) else { return nil }
        var best: Int? = nil
        var bestError = Int.max
        // C# 是 `for (offset = -span; offset <= span; offset++)`：span 为负时循环体一次都不执行。
        // stride 在 from > through 时给出空序列，语义相同且不会因为区间反向而陷阱。
        for offset in stride(from: -span, through: span, by: 1) {
            let cursor = base + offset
            if cursor < 0 { continue }
            let error = abs(submitted(cursor, cutScope, slidingScope) - x)
            if error < bestError {
                bestError = error
                best = cursor
            }
            if error == 0 { break }
        }
        return best
    }

    /// 把缺口偏移 x 变成一次拖动。量不到合法几何、或 x 越界时返回 nil，绝不猜。
    public static func makePlan(_ x: Int, _ geometry: Geometry, span: Int = 4) -> Plan? {
        guard let cursor = cursorFor(x, geometry.cutScope, geometry.slidingScope, span: span) else {
            return nil
        }
        let submittedValue = submitted(cursor, geometry.cutScope, geometry.slidingScope)
        return Plan(
            cursor: cursor,
            submitted: submittedValue,
            delta: Double(cursor) - geometry.cursorNow)
    }

    /// C# 里 `(int)` 那种 double → int 的向零截断。
    ///
    /// Swift 的 `Int(Double)` 对非有限值或超出 Int 范围的值会陷入陷阱（进程崩溃），
    /// `Int(exactly:)` 则是返回 nil。正常输入（页面几何、图像尺寸）永远落在范围内。
    private static func truncateToInt(_ value: Double) -> Int? {
        Int(exactly: value.rounded(.towardZero))
    }
}
