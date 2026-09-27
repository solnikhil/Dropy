import AppKit
import ApplicationServices
import DropyCore

/// M2 experiment: moves, minimizes or hides a source window and puts it back.
///
/// Every placement is written to the journal before the window is touched, so a
/// crash or quit can be undone at the next launch. Moving and minimizing another
/// app's window needs Accessibility permission; hiding an app does not.
///
/// The exact window is found by its CGWindowID through `_AXUIElementGetWindow`, a
/// private but long-standing HIServices function looked up at runtime. Without it
/// the placement is unsupported: matching by title or frame could move the wrong window.
@MainActor
enum WindowPlacer {
    enum PlacementError: Error, CustomStringConvertible {
        case accessibilityNotTrusted
        case exactWindowLookupUnavailable
        case windowNotFound
        case processGone
        case pendingPlacement
        case attribute(String, AXError)

        var description: String {
            switch self {
            case .accessibilityNotTrusted: "accessibilityNotTrusted"
            case .exactWindowLookupUnavailable: "exactWindowLookupUnavailable"
            case .windowNotFound: "windowNotInAccessibilityTree"
            case .processGone: "processGone"
            case .pendingPlacement: "pendingPlacement"
            case .attribute(let name, let error): "attribute(\(name),\(error.rawValue))"
            }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Connected display bounds in global top-left coordinates, main display first.
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        return ids.sorted { lhs, _ in lhs == main }.map(CGDisplayBounds)
    }

    /// Moves, minimizes or hides the window, journaling first. Returns the entry,
    /// whose `applied` state is what was observed after placing.
    static func apply(_ mode: PlacementMode, to identity: WindowIdentity,
                      journal: PlacementJournal) async throws -> PlacementEntry {
        guard !journal.entries.contains(where: { $0.identity == identity }) else {
            throw PlacementError.pendingPlacement
        }
        let needsAccessibility = mode != .hideApp
        if needsAccessibility, !isTrusted { throw PlacementError.accessibilityNotTrusted }
        guard WindowCatalog.isRunning(identity) else { throw PlacementError.processGone }
        // The Accessibility window list is occasionally empty or partial for a moment;
        // retry briefly before calling the exact window missing.
        var found = try state(of: identity)
        for _ in 0..<5 where found == nil {
            try await Task.sleep(for: .milliseconds(100))
            found = try state(of: identity)
        }
        guard let original = found else { throw PlacementError.windowNotFound }
        var expected = original
        switch mode {
        case .offscreen, .parked:
            expected.frame = PlacementGeometry.offscreenFrame(for: original.frame, displays: displayBounds())
        case .minimize: expected.isMinimized = true
        case .hideApp: expected.isAppHidden = true
        }
        var entry = PlacementEntry(identity: identity, mode: mode, original: original,
                                   applied: expected, createdAt: Date(), applicationConfirmed: false)
        try journal.upsert(entry)
        switch mode {
        case .offscreen, .parked:
            try setPosition(expected.frame.origin, of: requireWindow(identity))
        case .minimize:
            try setMinimized(true, window: requireWindow(identity))
        case .hideApp:
            NSRunningApplication(processIdentifier: identity.processID)?.hide()
        }
        switch mode {
        case .offscreen, .parked:
            // AppKit may clamp the position; record where the window really went so
            // a restore compares against reality rather than the request.
            if let observed = try state(of: identity) {
                entry.applied = observed
                entry.applicationConfirmed = true
                try journal.upsert(entry)
            }
        case .minimize, .hideApp:
            // Minimizing and hiding animate. Reading the state immediately returned the
            // old value, the journal recorded "not minimized", and the restore then
            // treated the minimized window as a user change and left it minimized.
            // Keep the expected state and wait for the system to reach it.
            for _ in 0..<20 {
                if let observed = try state(of: identity),
                   observed.isMinimized == expected.isMinimized,
                   observed.isAppHidden == expected.isAppHidden {
                    entry.applied = observed
                    entry.applicationConfirmed = true
                    try journal.upsert(entry)
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        return entry
    }

    /// Undoes a placement if the window is still where Dropy left it. The journal
    /// entry is removed once the outcome is final; it stays when Accessibility is
    /// unavailable so a later launch can finish the job.
    @discardableResult
    static func restore(_ entry: PlacementEntry, journal: PlacementJournal) -> RestoreDecision? {
        if entry.mode != .hideApp, !isTrusted { return nil }
        let current: WindowPlacementState?
        do {
            if entry.mode == .hideApp, !isTrusted, WindowCatalog.isRunning(entry.identity),
               let application = NSRunningApplication(processIdentifier: entry.identity.processID) {
                var appState = entry.applied
                appState.isAppHidden = application.isHidden
                current = appState
            } else {
                current = try state(of: entry.identity)
            }
            if current == nil, WindowCatalog.isRunning(entry.identity),
               windowServerInfo(entry.identity.windowID) != nil { return nil }
        }
        catch {
            // A transient AX failure is not proof that the source disappeared.
            NSLog("Dropy placement recovery deferred: %@", String(describing: error))
            return nil
        }
        let decision = PlacementRestorer.decide(entry, current: current, displays: displayBounds())
        switch decision {
        case .restore(let target), .restoreOnFallbackDisplay(let target):
            do {
                if current?.isAppHidden == true, !target.isAppHidden {
                    NSRunningApplication(processIdentifier: entry.identity.processID)?.unhide()
                }
                if entry.mode != .hideApp {
                    let window = try requireWindow(entry.identity)
                    if current?.isMinimized == true, !target.isMinimized {
                        try setMinimized(false, window: window)
                    }
                    try setFrame(target.frame, of: window,
                                 resize: decision != .restore(target))
                }
            } catch {
                NSLog("Dropy placement restore failed: mode=%@ error=%@", entry.mode.rawValue,
                      String(describing: error))
                return nil
            }
        case .pending: return decision
        case .keepUserChange, .sourceGone:
            break
        }
        do { try journal.remove(entry.identity) }
        catch {
            NSLog("Dropy placement journal removal failed: %@", String(describing: error))
            return nil
        }
        return decision
    }

    /// Current placement facts for the exact window, or nil when it is gone.
    static func state(of identity: WindowIdentity, assumeHidden: Bool? = nil) throws -> WindowPlacementState? {
        guard WindowCatalog.isRunning(identity),
              let application = NSRunningApplication(processIdentifier: identity.processID) else { return nil }
        let hidden = assumeHidden ?? application.isHidden
        if !isTrusted {
            // Without Accessibility only the app's hidden state is observable.
            guard let bounds = windowServerBounds(identity.windowID) else { return nil }
            return WindowPlacementState(frame: bounds, isMinimized: false, isAppHidden: hidden)
        }
        guard let window = try axWindow(for: identity) else { return nil }
        let position = try pointValue(window, kAXPositionAttribute)
        let size = try sizeValue(window, kAXSizeAttribute)
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        return WindowPlacementState(frame: CGRect(origin: position, size: size),
                                    isMinimized: (minimized as? Bool) ?? false, isAppHidden: hidden)
    }

    /// Window-server view of the window: its bounds and whether it is on screen.
    static func windowServerInfo(_ windowID: UInt32) -> (bounds: CGRect, onScreen: Bool)? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
                          as? [[String: Any]])?.first,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
        return (bounds, (info[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }

    private static func windowServerBounds(_ windowID: UInt32) -> CGRect? {
        windowServerInfo(windowID)?.bounds
    }

    // MARK: Accessibility

    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindowFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    private static func requireWindow(_ identity: WindowIdentity) throws -> AXUIElement {
        guard let window = try axWindow(for: identity) else { throw PlacementError.windowNotFound }
        return window
    }

    private static func axWindow(for identity: WindowIdentity) throws -> AXUIElement? {
        guard let getWindow else { throw PlacementError.exactWindowLookupUnavailable }
        let application = AXUIElementCreateApplication(identity.processID)
        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
        guard result == .success, let list = windows as? [AXUIElement] else {
            throw PlacementError.attribute(kAXWindowsAttribute, result)
        }
        let match = list.first { element in
            var windowID: CGWindowID = 0
            return getWindow(element, &windowID) == .success && windowID == identity.windowID
        }
        if match == nil {
            let ids = list.map { element -> String in
                var windowID: CGWindowID = 0
                let result = getWindow(element, &windowID)
                return result == .success ? String(windowID) : "err\(result.rawValue)"
            }
            NSLog("Dropy placement lookup: wanted=%u axWindows=[%@]", identity.windowID,
                  ids.joined(separator: ","))
        }
        return match
    }

    private static func pointValue(_ element: AXUIElement, _ attribute: String) throws -> CGPoint {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        var point = CGPoint.zero
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            throw PlacementError.attribute(attribute, result)
        }
        return point
    }

    private static func sizeValue(_ element: AXUIElement, _ attribute: String) throws -> CGSize {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        var size = CGSize.zero
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            throw PlacementError.attribute(attribute, result)
        }
        return size
    }

    private static func setPosition(_ point: CGPoint, of window: AXUIElement) throws {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        guard result == .success else { throw PlacementError.attribute(kAXPositionAttribute, result) }
    }

    private static func setFrame(_ frame: CGRect, of window: AXUIElement, resize: Bool) throws {
        try setPosition(frame.origin, of: window)
        guard resize else { return }
        var size = frame.size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        guard result == .success else { throw PlacementError.attribute(kAXSizeAttribute, result) }
    }

    private static func setMinimized(_ minimized: Bool, window: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                                  minimized as CFBoolean)
        guard result == .success else { throw PlacementError.attribute(kAXMinimizedAttribute, result) }
    }
}
