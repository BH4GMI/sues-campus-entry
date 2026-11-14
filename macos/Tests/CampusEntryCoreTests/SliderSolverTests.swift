import Testing
@testable import CampusEntryCore

/// Equivalent synthetic slider tests from `SliderSolverTests.cs` (`CORE-SPEC.md` §5.2/§7).
@Suite("SliderSolver")
struct SliderSolverTests {
    private struct DeterministicRNG {
        private var state: UInt64

        init(seed: Int) {
            self.state = UInt64(bitPattern: Int64(seed)) ^ 0x9E3779B97F4A7C15
        }

        mutating func nextByte() -> UInt32 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return UInt32(z & 0xFF)
        }
    }

    /// 220x60 seeded random background, 30x60 template cropped directly from `x0`.
    private static func makePair(x0: Int, seed: Int) -> (bg: [UInt32], slider: [UInt32]) {
        var rng = DeterministicRNG(seed: seed)
        let bgW = 220
        let bgH = 60
        let slW = 30
        let slH = 60

        var bg = [UInt32](repeating: 0, count: bgW * bgH)
        for i in bg.indices {
            let r = rng.nextByte()
            let g = rng.nextByte()
            let b = rng.nextByte()
            bg[i] = (0xFF << 24) | (r << 16) | (g << 8) | b
        }

        var slider = [UInt32](repeating: 0, count: slW * slH)
        for y in 0..<slH {
            for x in 0..<slW {
                slider[y * slW + x] = bg[y * bgW + x0 + x]
            }
        }
        return (bg, slider)
    }

    @Test("合成背景上定位精确", arguments: [0, 1, 37, 100, 190])
    func exactMatchOnSyntheticBackground(x0: Int) {
        let (bg, slider) = Self.makePair(x0: x0, seed: 42 + x0)
        #expect(SliderSolver.solve(bg: bg, bgW: 220, bgH: 60, sl: slider, slW: 30, slH: 60) == x0)
    }

    @Test("模板全黑_掩码为零_放弃")
    func allZeroTemplateAborts() {
        let (bg, _) = Self.makePair(x0: 100, seed: 7)
        let slider = [UInt32](repeating: 0, count: 30 * 60)
        #expect(SliderSolver.solve(bg: bg, bgW: 220, bgH: 60, sl: slider, slW: 30, slH: 60) == nil)
    }

    @Test("模板纯白_仍有能量_给出候选而非放弃")
    func allWhiteTemplateReturnsNonNilCandidate() {
        let bgW = 220
        let bgH = 60
        let slW = 30
        let slH = 60
        let brightX = 60

        var bg = [UInt32](repeating: 0xFF1E1E1E, count: bgW * bgH)
        for y in 0..<bgH {
            for x in brightX..<(brightX + slW) {
                bg[y * bgW + x] = 0xFFFAFAFA
            }
        }
        let slider = [UInt32](repeating: 0xFFFFFFFF, count: slW * slH)

        #expect(SliderSolver.solve(bg: bg, bgW: bgW, bgH: bgH, sl: slider, slW: slW, slH: slH) != nil)
    }

    @Test("尺寸不合法_放弃")
    func invalidDimensionsAbort() {
        let (bg, slider) = Self.makePair(x0: 10, seed: 3)
        #expect(SliderSolver.solve(bg: bg, bgW: 20, bgH: 60, sl: slider, slW: 30, slH: 60) == nil)
        #expect(SliderSolver.solve(bg: bg, bgW: 220, bgH: 60, sl: slider, slW: 31, slH: 60) == nil)
        #expect(SliderSolver.solve(bg: [], bgW: 220, bgH: 60, sl: slider, slW: 30, slH: 60) == nil)
        #expect(SliderSolver.solve(bg: bg, bgW: 0, bgH: 60, sl: slider, slW: 30, slH: 60) == nil)
        #expect(SliderSolver.solve(bg: bg, bgW: 220, bgH: 60, sl: slider, slW: 0, slH: 60) == nil)
    }
}
