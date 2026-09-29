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

    /// Side effects the route has by construction, whatever a trial observed.
    public var inherentSideEffects: Set<InputSideEffect> {
        self == .activateAndPost ? [.sourceKeyWindow, .frontmostApp, .pointer] : []
    }
}

/// A change outside the target window that sending input caused. Each is gated
/// separately: making the target key inside its own inactive app is harmless while
/// Dropy stays in front, but switching the person's app, desktop or pointer is not.
public enum InputSideEffect: String, Codable, CaseIterable, Sendable {
    /// The source app's key window changed (e.g. the target became key within its app).
    case sourceKeyWindow
    /// The frontmost app changed.
    case frontmostApp
    /// The active desktop (Space) changed.
    case desktop
    /// The person's pointer moved.
    case pointer
    /// A focus or desktop change from a record that did not say which.
    case unclassifiedFocusChange

    /// Effects that take focus away from Dropy, so it must be handed back afterwards.
    public var needsHandback: Bool { self == .frontmostApp || self == .unclassifiedFocusChange }
}

/// Where the source window is while Dropy shows it.
public enum SourceCondition: String, Codable, CaseIterable, Sendable {
    case visible, covered, parked, otherSpace, minimized, hidden
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
    /// Changes observed outside the target window during the action.
    public let sideEffects: Set<InputSideEffect>
    /// Includes key-window, frontmost-app or desktop changes observed during the action.
    public var changesFocus: Bool { !sideEffects.isEmpty }

    public init(route: InputRoute, kind: InputKind, condition: SourceCondition, focus: FocusState, outcome: Outcome,
                sideEffects: Set<InputSideEffect>) {
        self.route = route
        self.kind = kind
        self.condition = condition
        self.focus = focus
        self.outcome = outcome
        self.sideEffects = sideEffects
    }

    /// A trial that only says whether some focus change was observed.
    public init(route: InputRoute, kind: InputKind, condition: SourceCondition, focus: FocusState, outcome: Outcome,
                changesFocus: Bool = false) {
        self.init(route: route, kind: kind, condition: condition, focus: focus, outcome: outcome,
                  sideEffects: changesFocus ? [.unclassifiedFocusChange] : [])
    }

    private enum CodingKeys: String, CodingKey { case route, kind, condition, focus, outcome, sideEffects, changesFocus }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        route = try container.decode(InputRoute.self, forKey: .route)
        kind = try container.decode(InputKind.self, forKey: .kind)
        condition = try container.decode(SourceCondition.self, forKey: .condition)
        focus = try container.decode(FocusState.self, forKey: .focus)
        outcome = try container.decode(Outcome.self, forKey: .outcome)
        if let effects = try container.decodeIfPresent(Set<InputSideEffect>.self, forKey: .sideEffects) {
            sideEffects = effects
        } else {
            // Older records carried only a flag.
            sideEffects = try container.decodeIfPresent(Bool.self, forKey: .changesFocus) == true ? [.unclassifiedFocusChange] : []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(route, forKey: .route)
        try container.encode(kind, forKey: .kind)
        try container.encode(condition, forKey: .condition)
        try container.encode(focus, forKey: .focus)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(sideEffects.sorted { $0.rawValue < $1.rawValue }, forKey: .sideEffects)
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
        guard relevant.allSatisfy({ $0.outcome == .pass }) else { return .unreliable }
        let passed = Set(tested.filter { $0.outcome == .pass }.map(\.focus))
        let required = Self.requiredFocusStates.union(tested.map(\.focus))
        return required.isSubset(of: passed) ? .verified : .unreliable
    }

    /// Route side effects are evidence-dependent: even AX actions can change focus or Spaces.
    public func sideEffects(_ route: InputRoute, _ kind: InputKind, _ condition: SourceCondition) -> Set<InputSideEffect> {
        trials.filter { $0.route == route && $0.kind == kind && $0.condition == condition }
            .reduce(route.inherentSideEffects) { $0.union($1.sideEffects) }
    }

    public func requiresFocusChange(_ route: InputRoute, _ kind: InputKind, _ condition: SourceCondition) -> Bool {
        !sideEffects(route, kind, condition).isEmpty
    }

    /// Whether focus must be handed back to Dropy after sending.
    public func needsHandback(_ route: InputRoute, _ kind: InputKind, _ condition: SourceCondition) -> Bool {
        sideEffects(route, kind, condition).contains(where: \.needsHandback)
    }

    public func allows(_ route: InputRoute, _ kind: InputKind, _ condition: SourceCondition, policy: InputPolicy) -> Bool {
        policy.allows(route) && sideEffects(route, kind, condition).isSubset(of: policy.allowedSideEffects)
    }

    /// Kinds with at least one verified route for the condition under the policy.
    public func verifiedKinds(in condition: SourceCondition, policy: InputPolicy) -> Set<InputKind> {
        Set(InputKind.allCases.filter { kind in
            InputRoute.allCases.contains { allows($0, kind, condition, policy: policy) && verdict($0, kind, condition) == .verified }
        })
    }
}

/// What the person or build allows Dropy to use.
public struct InputPolicy: Equatable, Sendable {
    public var allowsPrivateInterfaces: Bool
    public var allowedSideEffects: Set<InputSideEffect>

    public init(allowsPrivateInterfaces: Bool = false, allowedSideEffects: Set<InputSideEffect>) {
        self.allowsPrivateInterfaces = allowsPrivateInterfaces
        self.allowedSideEffects = allowedSideEffects
    }

    /// All side effects, or none.
    public init(allowsPrivateInterfaces: Bool = false, allowsFocusChanges: Bool = false) {
        self.init(allowsPrivateInterfaces: allowsPrivateInterfaces,
                  allowedSideEffects: allowsFocusChanges ? Set(InputSideEffect.allCases) : [])
    }

    public var allowsFocusChanges: Bool { allowedSideEffects == Set(InputSideEffect.allCases) }

    /// Dropy's interactive preview: the private window-targeted route is allowed (the
    /// owner accepted that risk on 2026-09-29), and the source may make the target its
    /// own key window. Nothing may switch the person's app, desktop or pointer.
    public static let preview = InputPolicy(allowsPrivateInterfaces: true, allowedSideEffects: [.sourceKeyWindow])

    public func allows(_ route: InputRoute) -> Bool {
        (allowsPrivateInterfaces || !route.usesPrivateInterfaces) && route.inherentSideEffects.isSubset(of: allowedSideEffects)
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

public enum InputRefusal: Error, Equatable, Sendable {
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

    /// Route order for one kind. A pointer event through the exact window reproduces what
    /// the person did (caret placement, links, custom controls), so pointer kinds prefer
    /// it over an Accessibility press where both are verified and allowed. Keys always
    /// follow the source app's key window, so text uses Accessibility first.
    public static func routeOrder(for kind: InputKind) -> [InputRoute] {
        switch kind {
        case .pointerClick, .scroll, .drag, .contextMenu:
            [.windowTargetedEvent, .accessibility, .activateAndPost, .processEvent]
        case .text, .keyShortcut, .imeComposition:
            routeOrder
        }
    }

    /// Every verified, allowed route for the kind, best first. A route that cannot act on
    /// the element under the pointer (e.g. nothing pressable there) may give way to the
    /// next; every candidate targets the exact window.
    public static func candidates(_ kind: InputKind, selectedWindowID: UInt32, resolution: InputTargetResolution,
                                  condition: SourceCondition, capabilities: InputCapabilities,
                                  policy: InputPolicy) -> Result<[InputRoute], InputRefusal> {
        switch decide(kind, selectedWindowID: selectedWindowID, resolution: resolution, condition: condition,
                      capabilities: capabilities, policy: policy) {
        case .refuse(let refusal): return .failure(refusal)
        case .send:
            return .success(routeOrder(for: kind).filter {
                capabilities.allows($0, kind, condition, policy: policy) && capabilities.verdict($0, kind, condition) == .verified
            })
        }
    }

    public static func decide(_ kind: InputKind, selectedWindowID: UInt32, resolution: InputTargetResolution,
                              condition: SourceCondition, capabilities: InputCapabilities,
                              policy: InputPolicy) -> InputDecision {
        switch resolution {
        case .ambiguous: return .refuse(.ambiguousTarget)
        case .unreachable(let diagnosis): return .refuse(.targetUnreachable(diagnosis))
        case .exact(let windowID):
            guard windowID == selectedWindowID else { return .refuse(.targetChanged) }
        }
        let allowed = routeOrder(for: kind).filter { capabilities.allows($0, kind, condition, policy: policy) }
        if let route = allowed.first(where: { capabilities.verdict($0, kind, condition) == .verified }) {
            return .send(route, handBackFocus: capabilities.needsHandback(route, kind, condition))
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
