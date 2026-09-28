import CoreGraphics
import Foundation

/// Facts gathered when the exact source window cannot be found through Accessibility,
/// so the cause can be told apart instead of reported as one "missing window" error.
///
/// On macOS 27 an app's `AXWindows` list covers only windows on the active Space:
/// a window on another Space drops out of it (the list is often empty) while the
/// window server still lists it and the app still reports it as main or focused.
/// That, not a placement side effect, explained every lookup failure seen so far.
public struct WindowLookupFacts: Equatable, Sendable {
    /// `AXIsProcessTrusted()` for Dropy.
    public var trusted: Bool
    /// The exact process (PID, launch date and bundle ID) is still running.
    public var processRunning: Bool
    /// The raw `AXError` from reading the app's windows list, nil on success.
    public var windowsListError: Int32?
    /// Roles of the elements in the windows list.
    public var listedRoles: [String]
    /// Window IDs of every candidate (windows list, main and focused window);
    /// nil where `_AXUIElementGetWindow` failed for that element.
    public var candidateWindowIDs: [UInt32?]
    /// Candidates whose attributes could not be read because the element was invalid.
    public var staleCandidates: Int
    /// The window server still lists the window ID.
    public var windowServerListed: Bool
    /// The window server reports the window on screen (on the active Space and not minimized).
    public var windowServerOnScreen: Bool
    /// Spaces holding the window and the current Space of each display, when known.
    public var windowSpaces: [UInt64]?
    public var activeSpaces: [UInt64]?

    public init(trusted: Bool, processRunning: Bool, windowsListError: Int32? = nil,
                listedRoles: [String] = [], candidateWindowIDs: [UInt32?] = [], staleCandidates: Int = 0,
                windowServerListed: Bool, windowServerOnScreen: Bool,
                windowSpaces: [UInt64]? = nil, activeSpaces: [UInt64]? = nil) {
        self.trusted = trusted
        self.processRunning = processRunning
        self.windowsListError = windowsListError
        self.listedRoles = listedRoles
        self.candidateWindowIDs = candidateWindowIDs
        self.staleCandidates = staleCandidates
        self.windowServerListed = windowServerListed
        self.windowServerOnScreen = windowServerOnScreen
        self.windowSpaces = windowSpaces
        self.activeSpaces = activeSpaces
    }
}

/// Why the exact window was, or was not, reachable through Accessibility.
public enum WindowLookupDiagnosis: Equatable, Sendable, CustomStringConvertible {
    case found
    /// Dropy lacks Accessibility permission.
    case accessibilityNotTrusted
    /// Accessibility refused the request (`kAXErrorAPIDisabled`).
    case accessibilityDisabled
    /// The exact process exited.
    case processGone
    /// The exact window no longer exists.
    case windowClosed
    /// The app did not answer the windows-list request (e.g. `kAXErrorCannotComplete`).
    case appNotResponding(axError: Int32)
    /// The window is on a Space that is not active on any display.
    case onOtherSpace
    /// Space facts are unavailable and the window server reports it off screen.
    case notOnScreen
    /// The windows list held elements that are not windows.
    case nonWindowElements
    /// `_AXUIElementGetWindow` failed for a listed element.
    case lookupFailed
    /// A listed element had become invalid.
    case staleElements
    /// On screen on the active Space, yet Accessibility does not list it.
    case unlisted

    static let apiDisabled: Int32 = -25211

    public static func diagnose(_ facts: WindowLookupFacts, windowID: UInt32) -> WindowLookupDiagnosis {
        guard facts.trusted else { return .accessibilityNotTrusted }
        guard facts.processRunning else { return .processGone }
        if facts.candidateWindowIDs.contains(windowID) { return .found }
        if facts.windowsListError == apiDisabled { return .accessibilityDisabled }
        guard facts.windowServerListed else { return .windowClosed }
        if let error = facts.windowsListError { return .appNotResponding(axError: error) }
        if let spaces = facts.windowSpaces, let active = facts.activeSpaces, !spaces.isEmpty, !active.isEmpty {
            if Set(spaces).isDisjoint(with: active) { return .onOtherSpace }
        } else if !facts.windowServerOnScreen {
            return .notOnScreen
        }
        if facts.listedRoles.contains(where: { $0 != "AXWindow" }) { return .nonWindowElements }
        if facts.candidateWindowIDs.contains(nil) { return .lookupFailed }
        if facts.staleCandidates > 0 { return .staleElements }
        return .unlisted
    }

    /// True when the window may still exist and a later attempt can reach it.
    public var mayBecomeReachable: Bool {
        switch self {
        case .found, .processGone, .windowClosed: false
        default: true
        }
    }

    public var description: String {
        switch self {
        case .found: "found"
        case .accessibilityNotTrusted: "accessibilityNotTrusted"
        case .accessibilityDisabled: "accessibilityDisabled"
        case .processGone: "processGone"
        case .windowClosed: "windowClosed"
        case .appNotResponding(let error): "appNotResponding(\(error))"
        case .onOtherSpace: "onOtherSpace"
        case .notOnScreen: "notOnScreen"
        case .nonWindowElements: "nonWindowElements"
        case .lookupFailed: "lookupFailed"
        case .staleElements: "staleElements"
        case .unlisted: "unlisted"
        }
    }
}

/// What reading the source window produced when a restore was attempted.
public enum SourceWindowRead: Equatable, Sendable {
    case state(WindowPlacementState)
    /// The exact window could not be read; the diagnosis says whether it still exists.
    case unreachable(WindowLookupDiagnosis)
    /// An Accessibility call failed while reading a reachable window.
    case failed(String)
}

/// Why a restore could not be decided or carried out yet. The journal entry stays,
/// and recovery tries again.
public enum RestoreDeferral: Equatable, Sendable, CustomStringConvertible {
    case accessibilityNotTrusted
    case windowUnreachable(WindowLookupDiagnosis)
    case readFailed(String)
    case applyFailed(String)
    case journalWriteFailed(String)

    public var description: String {
        switch self {
        case .accessibilityNotTrusted: "accessibilityNotTrusted"
        case .windowUnreachable(let diagnosis): "windowUnreachable(\(diagnosis))"
        case .readFailed(let error): "readFailed(\(error))"
        case .applyFailed(let error): "applyFailed(\(error))"
        case .journalWriteFailed(let error): "journalWriteFailed(\(error))"
        }
    }

    /// Advice for the person when recovery cannot finish on its own.
    public var advice: String {
        switch self {
        case .accessibilityNotTrusted, .windowUnreachable(.accessibilityNotTrusted),
             .windowUnreachable(.accessibilityDisabled):
            "Allow Dropy in System Settings > Privacy & Security > Accessibility."
        case .windowUnreachable(.onOtherSpace), .windowUnreachable(.notOnScreen):
            "The window is on another desktop (Space). Switch to that desktop; Dropy restores it there."
        case .windowUnreachable(.appNotResponding):
            "The app is not responding. Dropy retries when it answers again."
        default:
            "Dropy retries automatically; the window stays recorded until it is restored."
        }
    }
}

/// The result of one restore attempt for one journal entry.
public enum RestoreOutcome: Equatable, Sendable {
    /// Final or explicit-recovery decision; `.pending` keeps the entry for the person.
    case decided(RestoreDecision)
    case deferred(RestoreDeferral)

    /// Deferred outcomes are retried automatically. A `.pending` decision needs an
    /// explicit choice, because restoring it might undo a move the person made.
    public var retriesAutomatically: Bool {
        if case .deferred = self { return true }
        return false
    }
}

/// What to do for one entry, decided from the entry and a fresh read of its window.
public enum RestorePlan: Equatable, Sendable {
    case deferral(RestoreDeferral)
    /// Nothing to change on the window; drop the entry unless the decision is `.pending`.
    case settle(RestoreDecision)
    /// Change the source, then drop the entry. `frame` is nil when only the app's hidden
    /// state was changed (`hideApp`), so the window itself is left alone.
    case restore(RestoreDecision, unhide: Bool, unminimize: Bool, frame: CGRect?, resize: Bool)

    public static func make(for entry: PlacementEntry, read: SourceWindowRead,
                            displays: [CGRect]) -> RestorePlan {
        let current: WindowPlacementState
        switch read {
        case .state(let state): current = state
        case .failed(let error): return .deferral(.readFailed(error))
        case .unreachable(let diagnosis):
            if diagnosis == .accessibilityNotTrusted { return .deferral(.accessibilityNotTrusted) }
            // A window that may come back (another Space, a busy app, a stale tree) is not
            // proof that it is gone; only a closed window or exited process settles the entry.
            if diagnosis.mayBecomeReachable { return .deferral(.windowUnreachable(diagnosis)) }
            return .settle(PlacementRestorer.decide(entry, current: nil, displays: displays))
        }
        let decision = PlacementRestorer.decide(entry, current: current, displays: displays)
        switch decision {
        case .restore(let target), .restoreOnFallbackDisplay(let target):
            let movesWindow = entry.mode != .hideApp
            return .restore(decision,
                            unhide: current.isAppHidden && !target.isAppHidden,
                            unminimize: movesWindow && current.isMinimized && !target.isMinimized,
                            frame: movesWindow ? target.frame : nil,
                            resize: decision != .restore(target))
        case .keepUserChange, .sourceGone, .pending:
            return .settle(decision)
        }
    }
}

/// Automatic recovery retry spacing: 1, 2, 4, 8, 16 then every 30 seconds. Space
/// changes, app activation and wake retry immediately and restart the sequence.
public enum RecoveryBackoff {
    public static let maximumDelay: TimeInterval = 30

    public static func delay(afterAttempt attempt: Int) -> TimeInterval {
        min(pow(2, Double(min(max(attempt, 0), 16))), maximumDelay)
    }
}
