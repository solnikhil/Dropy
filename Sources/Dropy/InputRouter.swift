import AppKit
import ApplicationServices
import DropyCore

/// Sends one interaction from the preview to the exact source window (M3 beta).
///
/// Every send re-resolves the window by exact identity, asks `InputPlanner` for the
/// verified routes, and tries them in order. Nothing is sent when the window cannot be
/// tied to the selected window ID, and a route that cannot act at the pointed element
/// gives way to the next verified one; no route targets anything but the exact window.
///
/// Routes follow `Scripts/bench/InputProbe` exactly, because the shipped evidence was
/// measured with those sequences:
/// - window-targeted event: `postToPid` with event fields 51/91/92 set to the window and
///   the private `CGEventSetWindowLocation`; explicit empty modifier flags.
/// - Accessibility: `AXPress` on the pressable element under the point; the scroll
///   bar's value; `AXSelectedText` without changing focus on the text element last clicked in this window.
@MainActor
final class InputRouter {
    enum Outcome: Equatable {
        case sent(InputRoute)
        case refused(InputRefusal)
        /// Every verified route was tried and none could act here (e.g. nothing pressable,
        /// no text element chosen yet).
        case notApplicable(String)
    }

    private let journal: PlacementJournal
    let evidence: InputEvidence
    private let macOSMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    /// The text element last clicked in each window, so typing goes to that window only.
    private var textTargets: [WindowIdentity: AXUIElement] = [:]

    init(journal: PlacementJournal, evidence: InputEvidence = InputRouter.bundledEvidence()) {
        self.journal = journal
        self.evidence = evidence
    }

    /// `InputEvidence.json` from the app bundle; empty (everything view-only) when missing.
    static func bundledEvidence() -> InputEvidence {
        guard let url = Bundle.main.url(forResource: "InputEvidence", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let evidence = try? JSONDecoder().decode(InputEvidence.self, from: data) else {
            NSLog("Dropy input: no bundled evidence; every source is view-only")
            return InputEvidence(macOS: "none", macOSMajor: 0, sources: [])
        }
        return evidence
    }

    func capabilities(for identity: WindowIdentity) -> InputCapabilities {
        evidence.capabilities(for: identity.bundleIdentifier, macOSMajor: macOSMajor)
    }

    func support(for identity: WindowIdentity) -> InteractionSupport {
        InputPlanner.support(in: condition(of: identity), capabilities: capabilities(for: identity), policy: .preview)
    }

    func forget(_ identity: WindowIdentity) { textTargets[identity] = nil }

    /// Processes whose Accessibility tree Dropy switched on.
    private var manualAccessibility: [Int32: Date] = [:]

    /// Prepares a source for interaction. For apps whose evidence was recorded with
    /// `AXManualAccessibility` on (Electron), switches it on once per process, ahead of
    /// the first click, because Chromium builds its tree asynchronously. Nothing is
    /// changed for any other app.
    func prepare(_ identity: WindowIdentity) {
        guard evidence.requiresManualAccessibility(for: identity.bundleIdentifier, macOSMajor: macOSMajor),
              manualAccessibility[identity.processID] != identity.processLaunchDate,
              let app = NSRunningApplication(processIdentifier: identity.processID),
              app.launchDate == identity.processLaunchDate, app.bundleIdentifier == identity.bundleIdentifier else { return }
        let result = AXUIElementSetAttributeValue(AXUIElementCreateApplication(identity.processID),
                                                  "AXManualAccessibility" as CFString, kCFBooleanTrue)
        NSLog("Dropy input: manualAccessibility pid=%d result=%d", identity.processID, result.rawValue)
        if result == .success { manualAccessibility[identity.processID] = identity.processLaunchDate }
    }

    /// Where the source is now: parked by Dropy, minimized, on another desktop, or visible.
    func condition(of identity: WindowIdentity) -> SourceCondition {
        if NSRunningApplication(processIdentifier: identity.processID)?.isHidden == true { return .hidden }
        if case .found(let window) = try? WindowPlacer.find(identity),
           (attribute(window, kAXMinimizedAttribute) as? Bool) == true { return .minimized }
        if let spaces = Spaces.of(identity.windowID), let active = Spaces.current(),
           !spaces.isEmpty, Set(spaces).isDisjoint(with: active) { return .otherSpace }
        if let entry = journal.entries.first(where: { $0.identity == identity }), entry.mode.movesWindow { return .parked }
        // Moved beyond every display by someone else: the same situation as parked.
        if let server = WindowPlacer.windowServerInfo(identity.windowID),
           PlacementGeometry.visibleFraction(of: server.bounds, on: WindowPlacer.displayBounds()) < 0.5 { return .parked }
        return .visible
    }

    // MARK: Sending

    /// Only a successfully sent click selects a typing target. Rejected geometry or
    /// a failed caret action must never silently redirect later typing to another field.
    func click(_ identity: WindowIdentity, at point: CGPoint, expectedWindowSize: CGSize? = nil) -> Outcome {
        send(.pointerClick, identity, expectedWindowSize: expectedWindowSize) { route, window, origin in
            let global = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
            let hit = Self.hitTest(window, global)
            let result: String?
            switch route {
            case .windowTargetedEvent:
                result = Self.postWindowTargeted(Self.clickEvents(at: global), identity: identity, local: point)
            case .accessibility:
                guard let hit else { return "nothingPressable" }
                if Self.isTextElement(hit) {
                    result = Self.placeCaret(hit, at: global)
                } else {
                    guard let pressable = Self.pressable(from: hit) else { return "nothingPressable" }
                    let error = AXUIElementPerformAction(pressable, kAXPressAction as CFString)
                    result = error == .success ? nil : "axError(\(error.rawValue))"
                }
            default:
                return "routeNotImplemented"
            }
            if result == nil {
                self.textTargets[identity] = hit.flatMap { Self.isTextElement($0) ? $0 : nil }
            }
            return result
        }
    }

    /// Puts the caret of a text element at a global point (`AXRangeForPosition`).
    static func placeCaret(_ element: AXUIElement, at point: CGPoint) -> String? {
        var point = point
        var value: CFTypeRef?
        guard let parameter = AXValueCreate(.cgPoint, &point),
              AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString,
                                                         parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return "noRangeAtPoint" }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return "noRangeAtPoint" }
        var caret = CFRange(location: range.location, length: 0)
        guard let caretValue = AXValueCreate(.cfRange, &caret) else { return "noRangeAtPoint" }
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretValue)
        return result == .success ? nil : "axError(\(result.rawValue))"
    }

    func scroll(_ identity: WindowIdentity, at point: CGPoint, delta: CGSize, expectedWindowSize: CGSize? = nil) -> Outcome {
        send(.scroll, identity, expectedWindowSize: expectedWindowSize) { route, window, origin in
            let global = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
            switch route {
            case .windowTargetedEvent:
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                          wheel1: Int32(delta.height.rounded()), wheel2: Int32(delta.width.rounded()),
                                          wheel3: 0) else { return "eventUnavailable" }
                event.location = global
                event.flags = []
                return Self.postWindowTargeted([event], identity: identity, local: point)
            case .accessibility:
                return Self.scrollByAccessibility(window, at: global, deltaY: delta.height)
            default:
                return "routeNotImplemented"
            }
        }
    }

    func type(_ identity: WindowIdentity, text: String) -> Outcome {
        send(.text, identity) { route, _, _ in
            guard route == .accessibility else { return "routeNotImplemented" }
            guard let target = self.textTargets[identity] else { return "noTextElementChosen" }
            // The element must still belong to the exact window.
            guard let owner = Self.windowID(of: target), owner == identity.windowID else {
                self.textTargets[identity] = nil
                return "textElementGone"
            }
            let result = AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFString)
            return result == .success ? nil : "axError(\(result.rawValue))"
        }
    }

    /// Resolves the exact window, plans, and tries each verified route until one applies.
    private func send(_ kind: InputKind, _ identity: WindowIdentity, expectedWindowSize: CGSize? = nil,
                      _ perform: (InputRoute, AXUIElement, CGPoint) -> String?) -> Outcome {
        let resolution: InputTargetResolution
        var window: AXUIElement?
        do {
            switch try WindowPlacer.find(identity) {
            case .found(let element):
                // `find` matched by exact window ID; confirm once more before sending.
                guard Self.windowID(of: element) == identity.windowID else { return .refused(.ambiguousTarget) }
                resolution = .exact(windowID: identity.windowID)
                window = element
            case .missing(let diagnosis):
                resolution = .unreachable(diagnosis)
            }
        } catch {
            resolution = .ambiguous
        }
        let condition = condition(of: identity)
        let planned = InputPlanner.candidates(kind, selectedWindowID: identity.windowID, resolution: resolution,
                                              condition: condition, capabilities: capabilities(for: identity),
                                              policy: .preview)
        let routes: [InputRoute]
        switch planned {
        case .failure(let refusal):
            NSLog("Dropy input: kind=%@ condition=%@ refused=%@", kind.rawValue, condition.rawValue, String(describing: refusal))
            return .refused(refusal)
        case .success(let list): routes = list
        }
        guard let window, let frame = Self.frame(of: window) else { return .refused(.ambiguousTarget) }
        if let expectedWindowSize, !PreviewInputGate.sizesMatch(frame.size, expectedWindowSize) {
            return .notApplicable("windowGeometryChanged")
        }
        let origin = frame.origin
        var reasons: [String] = []
        for route in routes {
            if let reason = perform(route, window, origin) {
                reasons.append("\(route.rawValue):\(reason)")
                continue
            }
            NSLog("Dropy input: kind=%@ condition=%@ route=%@", kind.rawValue, condition.rawValue, route.rawValue)
            return .sent(route)
        }
        NSLog("Dropy input: kind=%@ condition=%@ notApplicable=%@", kind.rawValue, condition.rawValue,
              reasons.joined(separator: ","))
        return .notApplicable(reasons.joined(separator: ","))
    }

    // MARK: Window-targeted events (private)

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                                      "CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: SetWindowLocation.self) }
    private static let eventWindowFields = [51, 91, 92].compactMap { CGEventField(rawValue: $0) }

    private static func clickEvents(at point: CGPoint) -> [CGEvent] {
        let events = [CGEventType.leftMouseDown, .leftMouseUp].compactMap {
            let event = CGEvent(mouseEventSource: nil, mouseType: $0, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = []
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            return event
        }
        return events.count == 2 ? events : []
    }

    private static func postWindowTargeted(_ events: [CGEvent], identity: WindowIdentity, local: CGPoint) -> String? {
        guard let setWindowLocation, eventWindowFields.count == 3 else { return "windowTargetingUnavailable" }
        guard !events.isEmpty else { return "eventUnavailable" }
        for event in events {
            for field in eventWindowFields { event.setIntegerValueField(field, value: Int64(identity.windowID)) }
            setWindowLocation(event, local)
            event.postToPid(identity.processID)
        }
        return nil
    }

    // MARK: Accessibility

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindow.self) }

    private static func windowID(of element: AXUIElement) -> UInt32? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        if getWindow(element, &id) == .success, id != 0 { return id }
        guard let owner = attribute(element, kAXWindowAttribute), CFGetTypeID(owner) == AXUIElementGetTypeID() else { return nil }
        return getWindow(owner as! AXUIElement, &id) == .success ? id : nil
    }

    private static func origin(of window: AXUIElement) -> CGPoint? { frame(of: window)?.origin }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let position = attribute(element, kAXPositionAttribute), let extent = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(extent as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// The deepest element of this window whose frame contains the point. Walking the
    /// window's own tree, instead of asking the system what is under the point, keeps the
    /// hit test inside the exact window even when it is covered or off every display.
    ///
    /// Later children are drawn above earlier ones and are tried first. A branch that
    /// contains the point but holds nothing actionable there is backtracked: Chromium
    /// stacks empty full-size groups beside the web content, so the topmost group at a
    /// point is often not the one holding the button under it. Without an actionable
    /// element anywhere, the deepest element on the topmost branch is returned.
    static func hitTest(_ window: AXUIElement, _ point: CGPoint) -> AXUIElement? {
        var budget = 4000
        var fallback: AXUIElement?
        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 40, budget > 0 else { return nil }
            var containing: [AXUIElement] = []
            for child in children(element).reversed() {
                guard budget > 0 else { break }
                budget -= 1
                if frame(of: child)?.contains(point) == true { containing.append(child) }
            }
            if containing.isEmpty {
                if fallback == nil, !CFEqual(element, window) { fallback = element }
                return nil
            }
            for child in containing {
                if let found = search(child, depth: depth + 1) { return found }
                if isActionable(child) { return child }
            }
            return nil
        }
        return search(window, depth: 0) ?? fallback
    }

    /// Something a click can act on: a pressable element or a text element.
    private static func isActionable(_ element: AXUIElement) -> Bool {
        actions(element).contains(kAXPressAction as String) || isTextElement(element)
    }

    private static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// The element itself or its nearest ancestor that supports `AXPress`, below the window.
    private static func pressable(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { return nil }
            let role = attribute(candidate, kAXRoleAttribute) as? String
            if role == kAXWindowRole as String || role == kAXApplicationRole as String { return nil }
            if actions(candidate).contains(kAXPressAction as String) { return candidate }
            current = attribute(candidate, kAXParentAttribute).flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
            }
        }
        return nil
    }

    static func isTextElement(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].map({ $0 as String }).contains(role ?? "") else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    /// Moves the vertical scroll bar of the scroll area under the point by the delta,
    /// relative to the scrollable height.
    private static func scrollByAccessibility(_ window: AXUIElement, at point: CGPoint, deltaY: CGFloat) -> String? {
        var current = hitTest(window, point)
        var area: AXUIElement?
        for _ in 0..<12 {
            guard let candidate = current else { break }
            if attribute(candidate, kAXRoleAttribute) as? String == kAXScrollAreaRole as String { area = candidate; break }
            current = attribute(candidate, kAXParentAttribute).flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
            }
        }
        guard let area, let visible = frame(of: area),
              let barValue = attribute(area, kAXVerticalScrollBarAttribute),
              CFGetTypeID(barValue) == AXUIElementGetTypeID() else { return "noScrollArea" }
        let bar = barValue as! AXUIElement
        let content = children(area).compactMap(frame(of:)).map(\.height).max() ?? 0
        let scrollable = content - visible.height
        guard scrollable > 1, let value = attribute(bar, kAXValueAttribute) as? Double else { return "nothingToScroll" }
        // Positive wheel deltas scroll content down (toward the top of the document).
        let next = min(max(value - Double(deltaY / scrollable), 0), 1)
        let result = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, next as CFNumber)
        return result == .success ? nil : "axError(\(result.rawValue))"
    }
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
