import Foundation

/// Navigation state machine (pure logic, aligned 1:1 with `EntryFlow.cs` and `CORE-SPEC.md` §4).
public final class EntryFlow {
    /// Maximum number of self-rescheduling portal probe retries (600 ms interval).
    public static let probeMaxAttempts = 15

    public enum Action: Equatable, Sendable {
        case nothing
        case inspectCas
        case assistCas
        case skipExpired
        case rejectCredentials
        case transient
        case settle
        case clearPrefix
        case secondLogin
        case probePortal
        case verifyArrival
    }

    /// Entry point currently served by this flow.
    public private(set) var entry: Sues.Entry = .jxfw

    /// Whether the current page was opened by the site (`window.open` / `target=_blank`): assist CAS only.
    public private(set) var adopted: Bool = false

    private var fromCachedPrefix: Bool = false
    private var _settled: Bool = false
    private var casSeen: Bool = false
    private var awaitingVerdict: Bool = false

    private var docs: Int = 0
    private var handled: Int = -1

    private var probeUrl: String?
    private var probeMisses: Int = 0

    /// Whether navigation automation has stopped handing control back to the user.
    public var isSettled: Bool { _settled }

    /// Current document ordinal incremented on each document start.
    public var documentOrdinal: Int { docs }

    public init() {}

    /// Resets state for a new user-initiated entry run.
    public func start(entry: Sues.Entry, hasCachedPrefix: Bool) {
        self.entry = entry
        self.fromCachedPrefix = hasCachedPrefix
        self.adopted = false
        self._settled = false
        self.casSeen = false
        self.awaitingVerdict = false
        self.docs = 0
        self.handled = -1
        resetProbe()
    }

    /// Adopts a site-opened popup tab: assists CAS pages without navigating for the user.
    public func adopt() {
        adopted = true
        _settled = true
        casSeen = false
        awaitingVerdict = false
        docs = 0
        handled = -1
        resetProbe()
    }

    /// Records that a new document has started loading.
    public func onDocumentStarted() {
        docs += 1
    }

    /// Records a missed portal probe for `url` and returns whether another retry is permitted.
    public func onProbeMissed(_ url: String) -> Bool {
        if probeUrl != url {
            probeUrl = url
            probeMisses = 0
        }
        probeMisses += 1
        return probeMisses <= Self.probeMaxAttempts
    }

    private func resetProbe() {
        probeUrl = nil
        probeMisses = 0
    }

    /// Evaluates what action to take when a document finishes loading.
    public func onDocumentFinished(_ url: String) -> Action {
        if handled == docs { return .nothing }
        handled = docs

        if Sues.isCasPage(url) {
            casSeen = true
            if !adopted { _settled = false }
            return .inspectCas
        }
        if _settled || adopted { return .nothing }
        if Sues.isTransientPage(url) { return .transient }

        if Sues.isSecondLoginPage(url) { return .secondLogin }
        if Sues.isJxfwPage(url) { return settle() }
        if entry == .webvpn { return .verifyArrival }
        if fromCachedPrefix && !casSeen { return .clearPrefix }
        return .probePortal
    }

    /// Confirms arrival after body-content verification (`Action.verifyArrival`).
    @discardableResult
    public func confirmArrival() -> Action {
        settle()
    }

    /// Decides what action to take on a CAS page from its DOM observation.
    public func onCasObserved(_ observation: Sues.CasObservation) -> Action {
        switch Sues.casKindOf(observation) {
        case .expired:
            return .skipExpired
        case .rejected:
            return .rejectCredentials
        case .form, .captcha, .other:
            return .assistCas
        }
    }

    /// Marks that the app submitted stored credentials and awaits server verdict on a subsequent document.
    public func onAutoSubmitted() {
        awaitingVerdict = true
    }

    /// Clears the pending verdict when automatic submission could not occur.
    public func onAutoSubmitAborted() {
        awaitingVerdict = false
    }

    /// Clears the pending verdict when the user manually submitted credentials.
    public func onUserSubmitted() {
        awaitingVerdict = false
    }

    /// Reads and clears the pending auto-submission verdict flag once.
    public func consumeAutoVerdict() -> Bool {
        let was = awaitingVerdict
        awaitingVerdict = false
        return was
    }

    /// Transitions the flow into the settled state and clears any pending verdict.
    @discardableResult
    public func settle() -> Action {
        _settled = true
        awaitingVerdict = false
        return .settle
    }
}
