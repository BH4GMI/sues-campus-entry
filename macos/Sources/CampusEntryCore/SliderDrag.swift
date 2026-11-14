import Foundation

/// Slider drag coordinate conversion and inverse solver (`SliderDrag.cs` / `CORE-SPEC.md` §5.3).
public enum SliderDrag {
    public static let defaultSpan = 4

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// CSS-pixel geometry measured from the DOM alongside image natural widths.
    public struct Geometry: Equatable, Sendable {
        public let containerWidth: Double
        public let backgroundWidth: Double
        public let backgroundNaturalWidth: Int
        public let sliderNaturalWidth: Int
        public let handleOuterWidth: Double
        public let handleBorderWidth: Double
        public let handleLeft: Double
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

        /// Submission value range (`cutScope = bgNaturalWidth - slNaturalWidth`, e.g. 440 - 80 = 360).
        public var cutScope: Int { backgroundNaturalWidth - sliderNaturalWidth }

        /// Content width of the drag handle without left/right borders.
        public var handleWidth: Double { handleOuterWidth - handleBorderWidth }

        /// Available track travel in CSS pixels (`containerWidth - handleWidth`).
        public var slidingScope: Double { containerWidth - handleWidth }

        /// Current handle offset relative to the track's left edge.
        public var cursorNow: Double { handleLeft - trackLeft }

        public var containerMatchesImage: Bool { abs(containerWidth - backgroundWidth) < 1.0 }
    }

    public enum Probe: Equatable, Sendable {
        case ready(Geometry)
        case failed(String)
    }

    public struct Plan: Equatable, Sendable {
        public let cursor: Int
        public let submitted: Int
        public let delta: Double

        public init(cursor: Int, submitted: Int, delta: Double) {
            self.cursor = cursor
            self.submitted = submitted
            self.delta = delta
        }
    }

    /// Parses the string returned by `slider-geometry.js`.
    public static func parseProbe(_ raw: String?) -> Probe {
        let value = Sues.trimQuotes(raw)
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

        let parts = value.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 9, parts[0] == "geom" else {
            return .failed("几何回传值不认得：\(value)")
        }

        var numbers = [Double]()
        numbers.reserveCapacity(8)
        for i in 1...8 {
            guard let d = Double(String(parts[i])), d.isFinite else {
                return .failed("几何第 \(i) 个值不是数字：\(parts[i])")
            }
            numbers.append(d)
        }

        return .ready(Geometry(
            containerWidth: numbers[0],
            backgroundWidth: numbers[1],
            backgroundNaturalWidth: Int(numbers[2]),
            sliderNaturalWidth: Int(numbers[3]),
            handleOuterWidth: numbers[4],
            handleBorderWidth: numbers[5],
            handleLeft: numbers[6],
            trackLeft: numbers[7]
        ))
    }

    /// Computes the integer value submitted by the page: `parseInt(cursor / slidingScope * cutScope)`.
    public static func submitted(cursor: Int, cutScope: Int, slidingScope: Double) -> Int {
        Int(floor(Double(cursor) / slidingScope * Double(cutScope)))
    }

    /// Finds an integer cursor offset minimizing `|submitted - x|` within `±span` of the rounded estimate.
    public static func cursorFor(x: Int, cutScope: Int, slidingScope: Double, span: Int = defaultSpan) -> Int? {
        guard cutScope > 0, slidingScope > 0 else { return nil }
        guard x >= 0, x <= cutScope else { return nil }

        let base = Int((Double(x) / Double(cutScope) * slidingScope).rounded(.toNearestOrAwayFromZero))
        var best: Int?
        var bestError = Int.max

        for offset in -span...span {
            let cursor = base + offset
            if cursor < 0 { continue }
            let error = abs(submitted(cursor: cursor, cutScope: cutScope, slidingScope: slidingScope) - x)
            if error < bestError {
                bestError = error
                best = cursor
            }
            if error == 0 { break }
        }
        return best
    }

    /// Builds a drag plan for solved gap coordinate `x`, or `nil` when geometry or `x` is invalid.
    public static func makePlan(x: Int, geometry: Geometry, span: Int = defaultSpan) -> Plan? {
        guard let cursor = cursorFor(
            x: x,
            cutScope: geometry.cutScope,
            slidingScope: geometry.slidingScope,
            span: span
        ) else {
            return nil
        }
        let sub = submitted(cursor: cursor, cutScope: geometry.cutScope, slidingScope: geometry.slidingScope)
        return Plan(cursor: cursor, submitted: sub, delta: Double(cursor) - geometry.cursorNow)
    }

    /// Formats a drag delta with `%.2f` in the POSIX locale for JS injection.
    public static func formatDelta(_ delta: Double) -> String {
        String(format: "%.2f", locale: posixLocale, delta)
    }
}
