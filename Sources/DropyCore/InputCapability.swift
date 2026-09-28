import Foundation

/// Input capability model (M3, issue #10). Input is independent of capture: this decides
/// whether an interaction may be sent to the exact source window, and by which route,
/// from verified evidence only. It never picks a route for an ambiguous target and never
/// falls back to an unverified one.

/// What a person does inside the preview.
public enum InputKind: String, Codable, CaseIterable, Sendable {
    case pointerClick
    case scroll
    /// Committed text into the focused text element.
    case text
    /// A key equivalent such as Command-K; menus act on the app's key window.
    case keyShortcut
    case drag
    case imeComposition
    case contextMenu
}

/// How an interaction can reach another app's window.
public enum InputRoute: String, Codable, CaseIterable, Sendable {
    /// An Accessibility action or attribute on an element of the exact window.
    case accessibility
    /// A process-targeted event naming the exact window (undocumented event fields and the
    /// private `CGEventSetWindowLocation`); never activates the app.
    case windowTargetedEvent
    /// A process-targeted event without a window (`CGEvent.postToPid`).
    case processEvent
    /// Activate the app, bring the window forward, post a system event, hand focus back.
    case activateAndPost

    /// Relies on undocumented or private interfaces that a macOS update may change.
    public var usesPrivateInterfaces: Bool { self == .windowTargetedEvent }
    /// Changes the frontmost app and key window, so focus must be handed back.
    public var changesFocus: Bool { self == .activateAndPost }
    /// Moves the person's pointer, so it needs the target point on a display.
    public var movesPointer: Bool { self == .activateAndPost }
}

/// Where the source window is while Dropy shows it.
public enum SourceCondition: String, Codable, CaseIterable, Sendable {
    case visible, covered, parked, otherSpace, minimized
}

/// Which window had focus in the source app when the input was sent.
public enum FocusState: String, Codable, CaseIterable, Sendable {
    /// The target window is the app's key window.
    case targetKey
    /// Another window of the same app is key: the wrong-window trap.
    case otherWindowKey
    /// Another app is frontmost.
    case appInactive
}

/// One harness trial, e.g. a line of `Scripts/input-probe.sh` results.
public struct InputTrial: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The effect happened in the target window only.
        case pass
        /// The effect, or the event itself, reached another window.
        case wrongWindow
        case noEffect
        /// The route cannot be used in this condition (e.g. the point is off every display).
        case notApplicable
    }

    public let route: InputRoute
    public let kind: InputKind
    public let condition: SourceCondition
    public let focus: FocusState
    public let outcome: Outcome

    public init(route: InputRoute, kind: InputKind, condition: SourceCondition, focus: FocusState, outcome: Outcome) {
        self.route = route
        self.kind = kind
        self.condition = condition
        self.focus = focus
        self.outcome = outcome
    }
}

/// The evidence for one route, kind and condition across every tested focus state.
public enum RouteVerdict: Equatable, Sendable {
    /// Passed in every focus state that the app can be in while Dropy shows it.
    case verified
    /// Reached the wrong window at least once: never use it for this kind and condition.
    case wrongWindowObserved
    /// No wrong window, but not every required focus state passed.
    case unreliable
    case notApplicable
    case untested
}

public struct InputCapabilities: Equatable, Sendable {
    private var trials: [InputTrial]

    public init(trials: [InputTrial]) {
        self.trials = trials
    }

    /// While Dropy shows a window the target is rarely key: a route is verified only if it
    /// passes with another window key and with the app inactive (and with the target key,
    /// where that state was tested).
    public static let requiredFocusStates: Set<FocusState> = [.otherWindowKey, .appInactive]

    public func verdict(_ route: InputRoute, _ kind: InputKind, _ condition: SourceCondition) -> RouteVerdict {
        let relevant = trials.filter { $0.route == route && $0.kind == kind && $0.condition == condition }
        guard !relevant.isEmpty else { return .untested }
        if relevant.contains(where: { $0.outcome == .wrongWindow }) { return .wrongWindowObserved }
        let tested = relevant.filter { $0.outcome != .notApplicable }
        if tested.isEmpty { return .notApplicable }
        let passed = Set(tested.filter { $0.outcome == .pass }.map(\.focus))
        let required = Self.requiredFocusStates.union(tested.map(\.focus))
        return required.isSubset(of: passed) ? .verified : .unreliable
    }

    /// Kinds with at least one verified route for the condition under the policy.
    public func verifiedKinds(in condition: SourceCondition, policy: InputPolicy) -> Set<InputKind> {
        Set(InputKind.allCases.filter { kind in
            InputRoute.allCases.contains { policy.allows($0) && verdict($0, kind, condition) == .verified }
        })
    }
}

/// What the person or build allows Dropy to use.
public struct InputPolicy: Equatable, Sendable {
    public var allowsPrivateInterfaces: Bool
    public var allowsFocusChanges: Bool

    public init(allowsPrivateInterfaces: Bool = false, allowsFocusChanges: Bool = false) {
        self.allowsPrivateInterfaces = allowsPrivateInterfaces
        self.allowsFocusChanges = allowsFocusChanges
    }

    public func allows(_ route: InputRoute) -> Bool {
        (allowsPrivateInterfaces || !route.usesPrivateInterfaces) && (allowsFocusChanges || !route.changesFocus)
    }
}

/// How the input target was resolved just before sending.
public enum InputTargetResolution: Equatable, Sendable {
    /// The exact window, re-resolved by identity and window ID.
    case exact(windowID: UInt32)
    /// More than one candidate, or a candidate that could not be tied to the window ID.
    case ambiguous
    case unreachable(WindowLookupDiagnosis)
}

public enum InputDecision: Equatable, Sendable {
    case send(InputRoute, handBackFocus: Bool)
    case refuse(InputRefusal)
}

public enum InputRefusal: Equatable, Sendable {
    /// The target could not be tied to exactly the selected window; nothing is sent.
    case ambiguousTarget
    case targetUnreachable(WindowLookupDiagnosis)
    /// The window resolved to a different ID than the one being shown.
    case targetChanged
    /// Every allowed route that was tried reached the wrong window.
    case wrongWindowRisk
    /// No allowed route has been verified for this kind in this condition.
    case notVerified
}

public enum InputPlanner {
    /// Preference order: exact-element actions first, then exact-window events, then routes
    /// that change focus. A process-wide event is only used where it was verified.
    public static let routeOrder: [InputRoute] = [.accessibility, .windowTargetedEvent, .activateAndPost, .processEvent]

    public static func decide(_ kind: InputKind, selectedWindowID: UInt32, resolution: InputTargetResolution,
                              condition: SourceCondition, capabilities: InputCapabilities,
                              policy: InputPolicy) -> InputDecision {
        switch resolution {
        case .ambiguous: return .refuse(.ambiguousTarget)
        case .unreachable(let diagnosis): return .refuse(.targetUnreachable(diagnosis))
        case .exact(let windowID):
            guard windowID == selectedWindowID else { return .refuse(.targetChanged) }
        }
        let allowed = routeOrder.filter(policy.allows)
        if let route = allowed.first(where: { capabilities.verdict($0, kind, condition) == .verified }) {
            return .send(route, handBackFocus: route.changesFocus)
        }
        // Report the risk when every allowed route that was actually tried hit the wrong window.
        let tried = allowed.map { capabilities.verdict($0, kind, condition) }
            .filter { $0 != .untested && $0 != .notApplicable }
        if !tried.isEmpty, tried.allSatisfy({ $0 == .wrongWindowObserved }) { return .refuse(.wrongWindowRisk) }
        return .refuse(.notVerified)
    }

    /// The label Dropy shows for a source: view-only, or interactive for named kinds.
    public static func support(in condition: SourceCondition, capabilities: InputCapabilities,
                               policy: InputPolicy) -> InteractionSupport {
        let kinds = capabilities.verifiedKinds(in: condition, policy: policy)
        return kinds.isEmpty ? .viewOnly : .interactive(kinds)
    }
}

public enum InteractionSupport: Equatable, Sendable {
    case viewOnly
    case interactive(Set<InputKind>)
}
