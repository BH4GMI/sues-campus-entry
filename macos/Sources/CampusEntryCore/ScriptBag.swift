import Foundation

/// Loads the shared page-contract JavaScript snippets from `Bundle.module` (`Resources/js`).
public enum ScriptBag {
    private static let lock = NSLock()
    private static var cache = [String: String]()

    /// Loads and caches a JS file from `Resources/js` in `Bundle.module`.
    private static func raw(_ name: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[name] {
            return cached
        }

        let base = name.hasSuffix(".js") ? String(name.dropLast(3)) : name
        guard let url = Bundle.module.url(forResource: base, withExtension: "js", subdirectory: "js") else {
            fatalError("Missing bundled resource: Resources/js/\(base).js")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Failed to read bundled resource: Resources/js/\(base).js")
        }

        var trimmed = text
        while let last = trimmed.last, last.isWhitespace || last.isNewline {
            trimmed.removeLast()
        }
        precondition(!trimmed.isEmpty, "Resources/js/\(base).js is empty")

        cache[name] = trimmed
        return trimmed
    }

    public static var probe: String { raw("probe.js") }
    public static var arrival: String { raw("arrival.js") }
    public static var tickNotice: String { raw("tick-notice.js") }
    public static var skipExpired: String { raw("skip-expired.js") }
    public static var captchaWatch: String { raw("captcha-watch.js") }
    public static var captchaStop: String { raw("captcha-stop.js") }
    public static var sliderGeometry: String { raw("slider-geometry.js") }
    public static var credentialWatch: String { raw("credential-watch.js") }
    public static var credentialStop: String { raw("credential-stop.js") }

    public static func casState(expiredMark: String = Sues.passwordExpiredMark) -> String {
        raw("cas-state.js").replacingOccurrences(of: "__EXPIRED_MARK__", with: expiredMark)
    }

    public static func drag(delta: Double) -> String {
        raw("drag.js").replacingOccurrences(of: "__DELTA__", with: SliderDrag.formatDelta(delta))
    }

    public static func drag(plan: SliderDrag.Plan) -> String {
        drag(delta: plan.delta)
    }

    public static func fillAndSubmit(username: String, password: String) -> String {
        raw("fill-and-submit.js")
            .replacingOccurrences(of: "__USERNAME__", with: jsLiteral(username))
            .replacingOccurrences(of: "__PASSWORD__", with: jsLiteral(password))
    }

    public static func noticeDialog(hide: Bool) -> String {
        raw("notice-dialog.js").replacingOccurrences(of: "__HIDE__", with: hide ? "true" : "false")
    }

    /// WKWebView message-bridge shim injected at document start, forwarding `window.entry.*`
    /// calls to `window.webkit.messageHandlers.entry.postMessage(...)`.
    public static let entryShim = """
(function(){
 if(window.entry)return;
 function post(m){try{window.webkit.messageHandlers.entry.postMessage(m);}catch(e){}}
 window.entry={
  armed:function(a,e){post({cmd:'armed',armed:!!a,expectsSlide:!!e});},
  captcha:function(b,s){post({cmd:'captcha',bg:b,sl:s});},
  credential:function(u,p){post({cmd:'credential',username:u,password:p});},
  log:function(m){post({cmd:'log',message:String(m)});}
 };
})();
"""

    /// Escapes a Swift string into a safe double-quoted JavaScript string literal.
    public static func jsLiteral(_ text: String) -> String {
        var result = "\""
        result.reserveCapacity(text.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x5C: result.append("\\\\")
            case 0x22: result.append("\\\"")
            case 0x0A: result.append("\\n")
            case 0x0D: result.append("\\r")
            case 0x2028: result.append("\\u2028")
            case 0x2029: result.append("\\u2029")
            case 0..<0x20:
                result.append(String(format: "\\u%04x", scalar.value))
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result.append("\"")
        return result
    }
}
