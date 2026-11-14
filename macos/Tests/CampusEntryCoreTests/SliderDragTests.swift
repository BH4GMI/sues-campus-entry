import Foundation
import Testing
@testable import CampusEntryCore

/// Equivalent drag conversion tests from `SliderDragTests.cs` (`CORE-SPEC.md` §5.3 / §7).
@Suite("SliderDrag")
struct SliderDragTests {
    /// Device geometry: container 440*0.75=330, handle 60*0.75=45 (47 with 1px+1px border).
    private static func geometry(handleLeft: Double = 0, trackLeft: Double = 0) -> SliderDrag.Geometry {
        SliderDrag.Geometry(
            containerWidth: 330,
            backgroundWidth: 330,
            backgroundNaturalWidth: 440,
            sliderNaturalWidth: 80,
            handleOuterWidth: 47,
            handleBorderWidth: 2,
            handleLeft: handleLeft,
            trackLeft: trackLeft
        )
    }

    @Test("滑轨长度是二百八十五而不是值域乘缩放")
    func slidingScopeIs285() {
        let g = Self.geometry()
        #expect(g.cutScope == 360)
        #expect(abs(g.handleWidth - 45.0) < 1e-5)
        #expect(abs(g.slidingScope - 285.0) < 1e-5)

        // Historical wrong formulas vs true value:
        let wrongScaledScope = 360.0 * 0.75
        let wrongOuterHandle = 330.0 - 47.0
        let trueSlidingScope = 330.0 * (440.0 - 60.0) / 440.0
        #expect(abs(wrongScaledScope - 270.0) < 1e-5)
        #expect(abs(wrongOuterHandle - 283.0) < 1e-5)
        #expect(abs(trueSlidingScope - 285.0) < 1e-5)
    }

    @Test("偏移二百_光标一百五十九_提交二百")
    func offset200Cursor159Submitted200() throws {
        let plan = try #require(SliderDrag.makePlan(x: 200, geometry: Self.geometry(handleLeft: 0, trackLeft: 0)))
        #expect(plan.cursor == 159)
        #expect(plan.submitted == 200)
    }

    @Test("偏移一百_量化误差不超过一")
    func offset100WithinOnePixel() throws {
        let plan = try #require(SliderDrag.makePlan(x: 100, geometry: Self.geometry()))
        #expect((99...101).contains(plan.submitted))
    }

    @Test("全域最多差一像素")
    func fullRangeSweepMaxErrorOneAndAtLeast286Exact() throws {
        let g = Self.geometry()
        var exact = 0
        for x in 0...g.cutScope {
            let plan = try #require(SliderDrag.makePlan(x: x, geometry: g))
            let error = abs(plan.submitted - x)
            #expect(error <= 1, "x=\(x) submitted \(plan.submitted), error \(error) > 1")
            if error == 0 {
                exact += 1
            }
        }
        #expect(exact >= 286, "exact hits \(exact) should be >= 286")
    }

    @Test("位移是相对当前光标的")
    func deltaRelativeToCurrentCursor() throws {
        let plan = try #require(SliderDrag.makePlan(x: 200, geometry: Self.geometry(handleLeft: 40, trackLeft: 10)))
        #expect(abs(plan.delta - 129.0) < 1e-5)
    }

    @Test("几何回传值解析")
    func parseProbeVectors() {
        let probe = SliderDrag.parseProbe("\"geom|330|330|440|80|47|2|40|10\"")
        guard case let .ready(geom) = probe else {
            Issue.record("Expected .ready probe, got \(probe)")
            return
        }
        #expect(abs(geom.containerWidth - 330.0) < 1e-5)
        #expect(geom.backgroundNaturalWidth == 440)

        if case .failed = SliderDrag.parseProbe("\"none\"") {} else {
            Issue.record("Expected .failed for none")
        }
        if case .failed = SliderDrag.parseProbe("\"missing\"") {} else {
            Issue.record("Expected .failed for missing")
        }
        if case .failed = SliderDrag.parseProbe("\"error\"") {} else {
            Issue.record("Expected .failed for error")
        }
        if case .failed = SliderDrag.parseProbe("\"geom|330\"") {} else {
            Issue.record("Expected .failed for truncated geom")
        }
    }

    @Test("注入脚本里的位移按两位小数写")
    func dragJsReplacesDeltaWithTwoDecimals() throws {
        let plan = try #require(SliderDrag.makePlan(x: 200, geometry: Self.geometry(handleLeft: 40, trackLeft: 10)))
        let filled = ScriptBag.drag(plan: plan)
        #expect(filled.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(129.00)"))
        #expect(!filled.contains("__DELTA__"))
    }

    @Test("共享脚本都装着各自的占位符")
    func rawScriptsContainExpectedPlaceholders() throws {
        let jsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CampusEntryCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .appendingPathComponent("Sources/CampusEntryCore/Resources/js", isDirectory: true)

        let dragRaw = try String(contentsOf: jsDir.appendingPathComponent("drag.js"), encoding: .utf8)
        let casStateRaw = try String(contentsOf: jsDir.appendingPathComponent("cas-state.js"), encoding: .utf8)
        let fillRaw = try String(contentsOf: jsDir.appendingPathComponent("fill-and-submit.js"), encoding: .utf8)
        let noticeRaw = try String(contentsOf: jsDir.appendingPathComponent("notice-dialog.js"), encoding: .utf8)

        #expect(dragRaw.contains("__DELTA__"))
        #expect(casStateRaw.contains("__EXPIRED_MARK__"))
        #expect(fillRaw.contains("__USERNAME__"))
        #expect(fillRaw.contains("__PASSWORD__"))
        #expect(noticeRaw.contains("__HIDE__"))
    }
}
