import Foundation

/// Slider gap locator matching `SliderSolver.cs` and `CORE-SPEC.md` §5.2.
/// Operates on non-premultiplied `0xAARRGGBB` pixel buffers using masked 3-channel `TM_CCORR_NORMED`.
public enum SliderSolver {
    public static let dimThreshold = 12000

    /// Solves the x-offset of the slider template `sl` inside background `bg`, or returns `nil` if invalid/aborted.
    public static func solve(
        bg: [UInt32],
        bgW: Int,
        bgH: Int,
        sl: [UInt32],
        slW: Int,
        slH: Int
    ) -> Int? {
        guard slW > 0, slH > 0, bgW > 0, bgH > 0 else { return nil }
        guard slW <= bgW, slH <= bgH else { return nil }
        let (slCount, slOverflow) = slW.multipliedReportingOverflow(by: slH)
        let (bgCount, bgOverflow) = bgW.multipliedReportingOverflow(by: bgH)
        guard !slOverflow, !bgOverflow, sl.count >= slCount, bg.count >= bgCount else { return nil }

        var mx = [Int]()
        var my = [Int]()
        var tr = [Double]()
        var tg = [Double]()
        var tb = [Double]()
        mx.reserveCapacity(slCount)
        my.reserveCapacity(slCount)
        tr.reserveCapacity(slCount)
        tg.reserveCapacity(slCount)
        tb.reserveCapacity(slCount)

        var energyT = 0.0
        for y in 0..<slH {
            let rowOffset = y * slW
            for x in 0..<slW {
                let p = sl[rowOffset + x]
                let r = Int((p >> 16) & 0xFF)
                let g = Int((p >> 8) & 0xFF)
                let b = Int(p & 0xFF)
                if 299 * r + 587 * g + 114 * b <= dimThreshold {
                    continue
                }
                let dr = Double(r)
                let dg = Double(g)
                let db = Double(b)
                mx.append(x)
                my.append(y)
                tr.append(dr)
                tg.append(dg)
                tb.append(db)
                energyT += dr * dr + dg * dg + db * db
            }
        }

        let maskCount = mx.count
        guard maskCount >= 64 else { return nil }

        let normT = energyT.squareRoot()
        guard normT > 0.0 else { return nil }

        var bestX = -1
        var bestScore = -Double.infinity
        let maxX = bgW - slW

        for ox in 0...maxX {
            var num = 0.0
            var den = 0.0
            for i in 0..<maskCount {
                let p = bg[my[i] * bgW + ox + mx[i]]
                let ir = Double((p >> 16) & 0xFF)
                let ig = Double((p >> 8) & 0xFF)
                let ib = Double(p & 0xFF)
                num += tr[i] * ir + tg[i] * ig + tb[i] * ib
                den += ir * ir + ig * ig + ib * ib
            }
            guard den > 0.0 else { continue }
            let score = num / (normT * den.squareRoot())
            // Strict greater-than preserves the smallest ox on ties.
            if score > bestScore {
                bestScore = score
                bestX = ox
            }
        }

        return bestX >= 0 ? bestX : nil
    }
}
