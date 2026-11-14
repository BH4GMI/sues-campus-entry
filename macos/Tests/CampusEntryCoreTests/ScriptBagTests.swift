import Foundation
import Testing
@testable import CampusEntryCore

/// Bundled JS script manifest & placeholder guards (equivalent to `ScriptBagTests.cs`).
@Suite("ScriptBag")
struct ScriptBagTests {
    @Test("每个页面脚本都真的取得到内容")
    func allThirteenScriptsNonEmpty() throws {
        let scripts: [(name: String, text: String)] = [
            ("probe.js", ScriptBag.probe),
            ("arrival.js", ScriptBag.arrival),
            ("tick-notice.js", ScriptBag.tickNotice),
            ("skip-expired.js", ScriptBag.skipExpired),
            ("captcha-watch.js", ScriptBag.captchaWatch),
            ("captcha-stop.js", ScriptBag.captchaStop),
            ("slider-geometry.js", ScriptBag.sliderGeometry),
            ("credential-watch.js", ScriptBag.credentialWatch),
            ("credential-stop.js", ScriptBag.credentialStop),
            ("cas-state.js", ScriptBag.casState()),
            ("drag.js", ScriptBag.drag(plan: SliderDrag.Plan(cursor: 200, submitted: 246, delta: 12.34))),
            ("fill-and-submit.js", ScriptBag.fillAndSubmit(username: "u", password: "p")),
            ("notice-dialog.js", ScriptBag.noticeDialog(hide: true)),
        ]

        // Ensure no bundled JS file in Resources/js was omitted from the 13 ScriptBag entries.
        let jsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CampusEntryCore/Resources/js", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: jsDir.path)
            .filter { $0.hasSuffix(".js") }
            .sorted()
        #expect(files.count == 13)
        #expect(Set(scripts.map(\.name)) == Set(files))

        for (name, text) in scripts {
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name) is empty")
        }
        #expect(!ScriptBag.entryShim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("带参数的脚本不留占位符")
    func parameterizedScriptsHaveNoLeftoverPlaceholders() throws {
        let placeholderRegex = try NSRegularExpression(pattern: #"__[A-Z][A-Z0-9_]*__"#)
        let scripts: [(name: String, text: String)] = [
            ("probe.js", ScriptBag.probe),
            ("arrival.js", ScriptBag.arrival),
            ("tick-notice.js", ScriptBag.tickNotice),
            ("skip-expired.js", ScriptBag.skipExpired),
            ("captcha-watch.js", ScriptBag.captchaWatch),
            ("captcha-stop.js", ScriptBag.captchaStop),
            ("slider-geometry.js", ScriptBag.sliderGeometry),
            ("credential-watch.js", ScriptBag.credentialWatch),
            ("credential-stop.js", ScriptBag.credentialStop),
            ("cas-state.js", ScriptBag.casState()),
            ("drag.js", ScriptBag.drag(plan: SliderDrag.Plan(cursor: 200, submitted: 246, delta: 12.34))),
            ("fill-and-submit.js", ScriptBag.fillAndSubmit(username: "u\"\\n", password: "p\"\\r")),
            ("notice-dialog.js(true)", ScriptBag.noticeDialog(hide: true)),
            ("notice-dialog.js(false)", ScriptBag.noticeDialog(hide: false)),
            ("entryShim", ScriptBag.entryShim),
        ]

        for (name, text) in scripts {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let match = placeholderRegex.firstMatch(in: text, range: range)
            #expect(match == nil, "\(name) still contains an unreplaced __UPPER__ placeholder")
        }
    }
}
