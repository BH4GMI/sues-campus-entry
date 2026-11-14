import Foundation

/// Pure-logic rules and parsers for SUES campus system entry (aligned 1:1 with `Sues.cs` and `CORE-SPEC.md`).
public enum Sues {
    /// WebVPN portal homepage.
    public static let portal = "https://webvpn.sues.edu.cn"

    /// Portal host name. Only paths under this host belong to the gateway itself.
    public static let portalHost = "webvpn.sues.edu.cn"

    /// SSO pivot path on the academic system that avoids a second login prompt.
    public static let ssoPath = "/student/sso/login"

    /// Marker text indicating the "password expired" notice page.
    public static let passwordExpiredMark = "密码已过期"

    private static let transientPath = "/wengine-vpn/failed"

    private static let credentialMarks = [
        "密码错误", "密码不正确", "用户名或密码", "账号或密码",
        "用户不存在", "账号不存在", "用户名不存在",
    ]

    private static let lockoutKeywords = [
        "再", "还", "剩余", "剩", "可再", "尝试", "输错", "错误",
    ]

    private static let lockoutLookback = 12

    private static let jxfwUrlRegex = try! NSRegularExpression(pattern: #"/https/[0-9a-f]+/student/"#)
    private static let prefixRegex = try! NSRegularExpression(pattern: #"^https?://[^/]+/https/[0-9a-fA-F]+$"#)
    private static let lockoutCountRegex = try! NSRegularExpression(pattern: #"(\d+)\s*次"#)
    private static let hostPatternRegex = try! NSRegularExpression(pattern: #"^[a-zA-Z]+://([^/?#]+)"#)
    private static let pathPatternRegex = try! NSRegularExpression(pattern: #"^[a-zA-Z]+://[^/?#]*(/[^?#]*)?"#)
    private static let originPatternRegex = try! NSRegularExpression(pattern: #"^https?://[^/]+"#)

    /// Supported entry targets.
    public enum Entry: String, Codable, Equatable, Sendable {
        case jxfw
        case webvpn
    }

    /// Observations reported from a CAS authentication page without judgement.
    public struct CasObservation: Equatable, Sendable {
        public let expired: Bool
        public let hasForm: Bool
        public let hasCaptcha: Bool
        public let prompt: String

        public static let empty = CasObservation(expired: false, hasForm: false, hasCaptcha: false, prompt: "")

        public init(expired: Bool, hasForm: Bool, hasCaptcha: Bool, prompt: String) {
            self.expired = expired
            self.hasForm = hasForm
            self.hasCaptcha = hasCaptcha
            self.prompt = prompt
        }
    }

    /// Classification of a CAS authentication page ordered by handling priority.
    public enum CasKind: Equatable, Sendable {
        case expired
        case rejected
        case form
        case captcha
        case other
    }

    /// Whether the URL is the unified CAS login page.
    public static func isCasPage(_ url: String) -> Bool {
        url.contains("/cas/login")
    }

    /// Whether the page is eligible for autofill or credential capture (`CORE-SPEC.md` §6.1).
    public static func isCredentialPage(_ url: String) -> Bool {
        isCasPage(url) && hostOf(url) == portalHost
    }

    /// Whether the URL is inside the new academic system under WebVPN.
    public static func isJxfwPage(_ url: String) -> Bool {
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        return jxfwUrlRegex.firstMatch(in: url, range: range) != nil
    }

    /// Whether the URL is the academic system's secondary login page (`/student/login`).
    public static func isSecondLoginPage(_ url: String) -> Bool {
        isJxfwPage(url) && url.contains("/student/login")
    }

    /// Host component (without port) of a URL, or empty string if absent.
    public static func hostOf(_ url: String) -> String {
        let nsRange = NSRange(url.startIndex..<url.endIndex, in: url)
        guard let match = hostPatternRegex.firstMatch(in: url, range: nsRange),
              match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: url)
        else {
            return ""
        }
        let hostPort = url[groupRange]
        if let colon = hostPort.firstIndex(of: ":") {
            return String(hostPort[..<colon])
        }
        return String(hostPort)
    }

    /// Path component (starting with `/`) of a URL, or empty string if absent.
    public static func pathOf(_ url: String) -> String {
        let nsRange = NSRange(url.startIndex..<url.endIndex, in: url)
        guard let match = pathPatternRegex.firstMatch(in: url, range: nsRange),
              match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: url)
        else {
            return ""
        }
        return String(url[groupRange])
    }

    /// Scheme + authority origin of an HTTP(S) URL, or empty string if absent.
    public static func originOf(_ url: String) -> String {
        let nsRange = NSRange(url.startIndex..<url.endIndex, in: url)
        guard let match = originPatternRegex.firstMatch(in: url, range: nsRange),
              let range = Range(match.range, in: url)
        else {
            return ""
        }
        return String(url[range])
    }

    /// Whether the URL is the gateway ticket-exchange transient page (`/wengine-vpn/failed` on portal host).
    public static func isTransientPage(_ url: String) -> Bool {
        hostOf(url) == portalHost && pathOf(url).hasPrefix(transientPath)
    }

    /// Whether the page body contains the password-expired marker.
    public static func isPasswordExpired(_ body: String) -> Bool {
        body.contains(passwordExpiredMark)
    }

    /// Whether the prompt text contains a credential-rejection message.
    public static func hasCredentialError(_ text: String) -> Bool {
        !text.isEmpty && credentialMarks.contains(where: { text.contains($0) })
    }

    /// Extracts remaining retry attempts from an error message, or `nil` if unavailable.
    public static func lockoutRemaining(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in lockoutCountRegex.matches(in: text, range: nsRange) {
            guard let fullRange = Range(match.range, in: text),
                  let numRange = Range(match.range(at: 1), in: text)
            else {
                continue
            }
            let from = text.index(
                fullRange.lowerBound,
                offsetBy: -lockoutLookback,
                limitedBy: text.startIndex
            ) ?? text.startIndex
            let context = text[from..<fullRange.lowerBound]
            if lockoutKeywords.allSatisfy({ !context.contains($0) }) {
                continue
            }
            if let value = Int(text[numRange]) {
                return value
            }
        }
        return nil
    }

    /// Whether remaining attempts are critically low (<= 1), requiring hard retry blocking.
    public static func isLockoutCritical(_ remaining: Int?) -> Bool {
        guard let remaining else { return false }
        return remaining <= 1
    }

    /// Appended clause describing remaining attempts, or `nil` when count is unknown.
    public static func remainingClause(_ remaining: Int?) -> String? {
        guard let remaining else { return nil }
        if isLockoutCritical(remaining) {
            return "；再错一次就锁定了，请先确认密码"
        }
        return "；还可以试 \(remaining) 次"
    }

    /// Parses `cas-state.js` output (`obs|<expired>|<form>|<captcha>|<prompt>`).
    public static func casObservationFrom(_ raw: String?) -> CasObservation {
        let value = trimQuotes(raw)
        let parts = value.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "obs" else {
            return .empty
        }
        return CasObservation(
            expired: parts[1] == "1",
            hasForm: parts[2] == "1",
            hasCaptcha: parts[3] == "1",
            prompt: parts.count > 4 ? String(parts[4]) : ""
        )
    }

    /// Priority order: expired > rejected > form > captcha > other.
    public static func casKindOf(_ observation: CasObservation) -> CasKind {
        if observation.expired { return .expired }
        if hasCredentialError(observation.prompt) { return .rejected }
        if observation.hasForm { return .form }
        if observation.hasCaptcha { return .captcha }
        return .other
    }

    /// Validates whether `value` matches `^https?://[^/]+/https/[0-9a-fA-F]+$`.
    public static func isPrefix(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return prefixRegex.firstMatch(in: value, range: range) != nil
    }

    /// Derives and validates a gateway prefix from a portal redirect/href and current page URL.
    public static func prefixFrom(_ redirect: String?, pageUrl: String) -> String? {
        let href = (redirect ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty else { return nil }
        let abs = href.hasPrefix("http") ? href : originOf(pageUrl) + href
        guard abs.contains("/https/") else { return nil }
        let prefix = abs.range(of: "/student/").map { String(abs[..<$0.lowerBound]) } ?? abs
        return isPrefix(prefix) ? prefix : nil
    }

    /// Computes initial URL for an entry mode given an optional cached gateway prefix.
    public static func entryUrl(prefix: String?, entry: Entry) -> String {
        switch entry {
        case .webvpn:
            return portal
        case .jxfw:
            if let prefix {
                return prefix + ssoPath
            }
            return portal
        }
    }

    /// Extracts target href from `probe.js` output (`portal|<href>`), unescaping `\/`.
    public static func probeHref(_ probe: String?) -> String? {
        guard let probe else { return nil }
        let raw = trimQuotes(probe).replacingOccurrences(of: "\\/", with: "/")
        guard raw.hasPrefix("portal|") else { return nil }
        let href = String(raw.dropFirst("portal|".count))
        return href.isEmpty ? nil : href
    }

    /// Extracts arrival mark from `arrival.js` output (`arrival|<mark>`), returning `nil` if unconfirmed.
    public static func arrivalMark(_ raw: String?) -> String? {
        let value = trimQuotes(raw)
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "arrival" else { return nil }
        let mark = String(parts[1])
        return (mark == "none" || mark == "err" || mark.isEmpty) ? nil : mark
    }

    /// Compares two URLs while ignoring trailing slashes only.
    public static func samePage(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return trimTrailingSlashes(a) == trimTrailingSlashes(b)
    }

    static func trimQuotes(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func trimTrailingSlashes(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
