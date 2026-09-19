import Foundation
import XCTest
@testable import CampusEntry

// 由 `pc/tests/CampusEntry.Tests/SliderDragTests.cs` 逐条翻译而来（权威来源是 C#）。
// 用例数：C# 8 个 [Fact]（没有 [Theory]），这里同样是 8 个 func。

/// 拖动换算（docs/CORE-SPEC.md §5.3 / §7，与 Android 端 SliderDragTest 等价）。
final class SliderDragTests: XCTestCase {

    /// 真机上的几何：容器 440×0.75=330，手柄 60×0.75=45（加 1px+1px 边框后 47）。
    private func geometry(handleLeft: Double = 0, trackLeft: Double = 0) -> SliderDrag.Geometry {
        SliderDrag.Geometry(
            containerWidth: 330,
            backgroundWidth: 330,
            backgroundNaturalWidth: 440,
            sliderNaturalWidth: 80,
            handleOuterWidth: 47,
            handleBorderWidth: 2,
            handleLeft: handleLeft,
            trackLeft: trackLeft)
    }

    /// `SliderDrag.Probe` 是带关联值的枚举（`.ready(Geometry)` / `.failed(String)`），
    /// 没有声明 `Equatable`，所以用模式匹配判断分支——对应 C# 的 `Assert.IsType<Probe.Failed>(…)`。
    private func isFailed(_ probe: SliderDrag.Probe) -> Bool {
        if case .failed = probe { return true }
        return false
    }

    func test滑轨长度是二百八十五而不是值域乘缩放() {
        let g = geometry()
        XCTAssertEqual(360, g.cutScope)
        XCTAssertEqual(45.0, g.handleWidth, accuracy: 1e-5)
        XCTAssertEqual(285.0, g.slidingScope, accuracy: 1e-5)

        // 这两个数字就是当初的错：值域乘缩放得 270；含边框的手柄宽算出 283，都短于真值 285
        XCTAssertEqual(270.0, 360.0 * 0.75, accuracy: 1e-5)
        XCTAssertEqual(283.0, 330.0 - 47.0, accuracy: 1e-5)
        XCTAssertEqual(285.0, 330.0 * (440.0 - 60.0) / 440.0, accuracy: 1e-5)
    }

    func test偏移二百_光标一百五十九_提交二百() {
        guard let plan = SliderDrag.makePlan(200, geometry(handleLeft: 0, trackLeft: 0)) else {
            return XCTFail("偏移 200 应当能反解出拖动计划")
        }
        XCTAssertEqual(159, plan.cursor)
        XCTAssertEqual(200, plan.submitted)
    }

    func test偏移一百_量化误差不超过一() {
        guard let plan = SliderDrag.makePlan(100, geometry()) else {
            return XCTFail("偏移 100 应当能反解出拖动计划")
        }
        // C# 的 `Assert.InRange(plan.Submitted, 99, 101)`
        XCTAssertTrue((99...101).contains(plan.submitted), "提交值应当落在 99...101，实为 \(plan.submitted)")
    }

    func test全域最多差一像素() {
        let g = geometry()
        var exact = 0
        for x in 0...g.cutScope {
            guard let plan = SliderDrag.makePlan(x, g) else {
                XCTFail("x=\(x) 应当能反解出拖动计划")
                continue
            }
            let error = abs(plan.submitted - x)
            XCTAssertTrue(error <= 1, "x=\(x) 提交 \(plan.submitted)，误差 \(error) > 1")
            if error == 0 { exact += 1 }
        }
        XCTAssertTrue(exact >= 286, "可精确命中 \(exact) 个，应至少 286 个")
    }

    func test位移是相对当前光标的() {
        guard let plan = SliderDrag.makePlan(200, geometry(handleLeft: 40, trackLeft: 10)) else {
            return XCTFail("偏移 200 应当能反解出拖动计划")
        }
        XCTAssertEqual(129.0, plan.delta, accuracy: 1e-5)
    }

    func test几何回传值解析() {
        let probe = SliderDrag.parseProbe("\"geom|330|330|440|80|47|2|40|10\"")
        guard case .ready(let ready) = probe else {
            return XCTFail("合法的 geom 回传值应当解析成 Probe.ready")
        }
        XCTAssertEqual(330.0, ready.containerWidth, accuracy: 1e-5)
        XCTAssertEqual(440, ready.backgroundNaturalWidth)

        XCTAssertTrue(isFailed(SliderDrag.parseProbe("\"none\"")))
        XCTAssertTrue(isFailed(SliderDrag.parseProbe("\"missing\"")))
        XCTAssertTrue(isFailed(SliderDrag.parseProbe("\"error\"")))
        XCTAssertTrue(isFailed(SliderDrag.parseProbe("\"geom|330\"")))
    }

    func test注入脚本里的位移按两位小数写() throws {
        // 与 Android 端一样：这段检查直接读 shared/js/drag.js，保证占位符替换产物合法。
        // 格式化固定用 en_US_POSIX，免得在某些区域设置下写成 "129,00" 让 JS 解析成别的数
        //（对应 C# 的 `ToString("F2", CultureInfo.InvariantCulture)`）。
        guard let plan = SliderDrag.makePlan(200, geometry(handleLeft: 40, trackLeft: 10)) else {
            return XCTFail("偏移 200 应当能反解出拖动计划")
        }
        let js = try sharedJsText("drag.js")
        let filled = js.replacingOccurrences(
            of: "__DELTA__",
            with: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), plan.delta))
        XCTAssertTrue(
            filled.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(129.00)"),
            "位移应当以 (129.00) 结尾：\(filled)")
        XCTAssertFalse(filled.contains("__DELTA__"), "占位符应当已被全部替换：\(filled)")
    }

    func test共享脚本都装着各自的占位符() throws {
        XCTAssertTrue(try sharedJsText("cas-state.js").contains("__EXPIRED_MARK__"))
        XCTAssertTrue(try sharedJsText("fill-and-submit.js").contains("__USERNAME__"))
        XCTAssertTrue(try sharedJsText("fill-and-submit.js").contains("__PASSWORD__"))
        XCTAssertTrue(try sharedJsText("notice-dialog.js").contains("__HIDE__"))
    }
}

// MARK: - 直接读仓库根 shared/js（与被测应用内嵌的是同一批文件）

/// C# 的 `SharedJs.ReadAllTextAsync` 是从 `AppContext.BaseDirectory` 向上找 `shared/js`。
/// Swift 侧测试进程的当前目录是 Xcode 的 DerivedData（不在仓库里），按目录树向上找不可靠；
/// 而 `#filePath` 是编译期就定下的本文件绝对路径，从它向上找 `shared/js` 更稳，
/// 找到的仍然是仓库根那一批物理文件（`ios/project.yml` 里 App 也是直接引用它们）。
private func sharedJsDirectory() throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while true {
        let candidate = directory.appendingPathComponent("shared/js", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return candidate
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path {
            throw NSError(
                domain: "CampusEntryTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "从 \(#filePath) 向上找不到 shared/js"])
        }
        directory = parent
    }
}

private func sharedJsText(_ name: String) throws -> String {
    let url = try sharedJsDirectory().appendingPathComponent(name)
    return try String(contentsOf: url, encoding: .utf8)
}
