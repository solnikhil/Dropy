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
        case windowNotFound(WindowLookupDiagnosis)
        case windowNotOnScreen
        case processGone
        case pendingPlacement
        case attribute(String, AXError)

        var description: String {
            switch self {
            case .accessibilityNotTrusted: "accessibilityNotTrusted"
            case .exactWindowLookupUnavailable: "exactWindowLookupUnavailable"
            case .windowNotFound(let diagnosis): "windowNotInAccessibilityTree(\(diagnosis))"
            case .windowNotOnScreen: "windowNotOnScreen"
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
    ///
    /// The window must be on screen: placing a window that is on another Space or
    /// already minimized hides nothing, and its restore would depend on a Space the
    /// person may never return to.
    static func apply(_ mode: PlacementMode, to identity: WindowIdentity,
                      journal: PlacementJournal) async throws -> PlacementEntry {
        guard !journal.entries.contains(where: { $0.identity == identity }) else {
            throw PlacementError.pendingPlacement
        }
        let needsAccessibility = mode != .hideApp
        if needsAccessibility, !isTrusted { throw PlacementError.accessibilityNotTrusted }
        guard WindowCatalog.isRunning(identity) else { throw PlacementError.processGone }
        guard windowServerInfo(identity.windowID)?.onScreen == true else { throw PlacementError.windowNotOnScreen }
        // An app can answer with a partial windows list for a moment; retry briefly,
        // and only for causes that can clear on their own. Hiding an app needs no
        // Accessibility, so without it the window server supplies the frame.
        var window: AXUIElement?
        if isTrusted {
            var lookup = try find(identity)
            for _ in 0..<5 {
                guard case .missing(let diagnosis) = lookup, diagnosis.mayBecomeReachable else { break }
                try await Task.sleep(for: .milliseconds(100))
                lookup = try find(identity)
            }
            switch lookup {
            case .found(let element): window = element
            case .missing(let diagnosis): throw PlacementError.windowNotFound(diagnosis)
            }
        }
        func observe() throws -> WindowPlacementState? {
            try window.map { try readState($0, identity: identity) } ?? state(of: identity)
        }
        guard let original = try observe() else { throw PlacementError.processGone }
        var expected = original
        switch mode {
        case .offscreen, .parked, .docked, .staged:
            expected.frame = PlacementGeometry.offscreenFrame(for: original.frame, displays: displayBounds())
        case .minimize: expected.isMinimized = true
        case .hideApp: expected.isAppHidden = true
        }
        var entry = PlacementEntry(identity: identity, mode: mode, original: original,
                                   applied: expected, createdAt: Date(), applicationConfirmed: false)
        try journal.upsert(entry)
        switch mode {
        case .offscreen, .parked, .docked, .staged:
            guard let window else { throw PlacementError.accessibilityNotTrusted }
            try setPosition(expected.frame.origin, of: window)
        case .minimize:
            guard let window else { throw PlacementError.accessibilityNotTrusted }
            try setMinimized(true, window: window)
        case .hideApp:
            NSRunningApplication(processIdentifier: identity.processID)?.hide()
        }
        switch mode {
        case .offscreen, .parked, .docked, .staged:
            // AppKit may clamp the position; record where the window really went so
            // a restore compares against reality rather than the request.
            if let observed = try? observe() {
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
                if let observed = try? observe(),
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
    /// entry is removed once the outcome is final. It stays, with the reason, when the
    /// window cannot be reached yet (no Accessibility, another Space, a busy app), so
    /// automatic recovery or a later launch can finish the job.
    @discardableResult
    static func restore(_ entry: PlacementEntry, journal: PlacementJournal) -> RestoreOutcome {
        if entry.mode != .hideApp, !isTrusted { return .deferred(.accessibilityNotTrusted) }
        var entry = entry
        // A docked window waiting with its app hidden can be missing from Accessibility
        // until the app is shown. Dropy hid it, so Dropy shows it, then judges the
        // window as if it had never been hidden: a move the person made still wins.
        if entry.mode == .docked, entry.applied.isAppHidden,
           let application = NSRunningApplication(processIdentifier: entry.identity.processID),
           application.isHidden, WindowCatalog.isRunning(entry.identity) {
            application.unhide()
            for _ in 0..<20 {
                if case .found = (try? find(entry.identity)) ?? .missing(.processGone) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            entry.applied.isAppHidden = false
        }
        let (read, window) = readForRestore(entry)
        let plan = RestorePlan.make(for: entry, read: read, displays: displayBounds())
        let decision: RestoreDecision
        switch plan {
        case .deferral(let reason):
            return .deferred(reason)
        case .settle(let settled):
            decision = settled
        case .restore(let planned, let unhide, let unminimize, let frame, let resize):
            decision = planned
            // A restore may partly succeed (unminimize/unhide) before the frame
            // write fails or the process crashes. Preserve that ambiguity rather
            // than classifying our partial restore as the user's later change.
            var restoring = entry
            restoring.applicationConfirmed = false
            do { try journal.upsert(restoring) }
            catch { return .deferred(.journalWriteFailed(String(describing: error))) }
            do {
                if unhide { NSRunningApplication(processIdentifier: entry.identity.processID)?.unhide() }
                if unminimize || frame != nil {
                    guard let window else { return .deferred(.applyFailed("windowElementUnavailable")) }
                    if unminimize { try setMinimized(false, window: window) }
                    if let frame { try setFrame(frame, of: window, resize: resize) }
                }
            } catch {
                return .deferred(.applyFailed(String(describing: error)))
            }
        }
        // An unconfirmed move stays for explicit recovery.
        if decision == .pending { return .decided(decision) }
        do { try journal.remove(entry.identity) }
        catch { return .deferred(.journalWriteFailed(String(describing: error))) }
        return .decided(decision)
    }

    /// Reads the source for a restore. A hidden app's windows can be unreachable while
    /// it stays hidden; for `hideApp` only the app's hidden state was changed, so the
    /// exact process is enough to decide and undo it.
    private static func readForRestore(_ entry: PlacementEntry) -> (SourceWindowRead, AXUIElement?) {
        let identity = entry.identity
        func appOnly() -> SourceWindowRead? {
            guard entry.mode == .hideApp, WindowCatalog.isRunning(identity),
                  let application = NSRunningApplication(processIdentifier: identity.processID) else { return nil }
            var state = entry.applied
            state.isAppHidden = application.isHidden
            return .state(state)
        }
        guard isTrusted else {
            return (appOnly() ?? .unreachable(.accessibilityNotTrusted), nil)
        }
        do {
            switch try find(identity) {
            case .found(let window):
                return (.state(try readState(window, identity: identity)), window)
            case .missing(let diagnosis):
                if diagnosis != .processGone, let state = appOnly() { return (state, nil) }
                return (.unreachable(diagnosis), nil)
            }
        } catch {
            return (.failed(String(describing: error)), nil)
        }
    }

    /// Current placement facts for the exact window, or nil when it is unreachable.
    static func state(of identity: WindowIdentity) throws -> WindowPlacementState? {
        guard isTrusted else {
            // Without Accessibility only the window server and the app's hidden state are observable.
            guard WindowCatalog.isRunning(identity),
                  let application = NSRunningApplication(processIdentifier: identity.processID),
                  let bounds = windowServerInfo(identity.windowID)?.bounds else { return nil }
            return WindowPlacementState(frame: bounds, isMinimized: false, isAppHidden: application.isHidden)
        }
        guard case .found(let window) = try find(identity) else { return nil }
        return try readState(window, identity: identity)
    }

    static func readState(_ window: AXUIElement, identity: WindowIdentity) throws -> WindowPlacementState {
        let position = try pointValue(window, kAXPositionAttribute)
        let size = try sizeValue(window, kAXSizeAttribute)
        var minimized: CFTypeRef?
        let minimizedResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        guard minimizedResult == .success, let isMinimized = minimized as? Bool else {
            throw PlacementError.attribute(kAXMinimizedAttribute, minimizedResult)
        }
        let hidden = NSRunningApplication(processIdentifier: identity.processID)?.isHidden ?? false
        return WindowPlacementState(frame: CGRect(origin: position, size: size),
                                    isMinimized: isMinimized, isAppHidden: hidden)
    }

    /// Window-server view of the window: its bounds and whether it is on screen.
    static func windowServerInfo(_ windowID: UInt32) -> (bounds: CGRect, onScreen: Bool)? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
                          as? [[String: Any]])?.first,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
        return (bounds, (info[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }

    // MARK: Exact window lookup

    enum Lookup {
        case found(AXUIElement)
        case missing(WindowLookupDiagnosis)
    }

    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindowFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    /// Finds the exact window by CGWindowID. The app's windows list covers only the
    /// active Space, so the main and focused windows, which the app reports on any
    /// Space, are candidates too; each must still match the exact window ID.
    /// On a miss, the facts are gathered once and diagnosed, and the result is logged.
    static func find(_ identity: WindowIdentity) throws -> Lookup {
        guard let getWindow else { throw PlacementError.exactWindowLookupUnavailable }
        guard isTrusted else { return .missing(.accessibilityNotTrusted) }
        guard WindowCatalog.isRunning(identity) else { return .missing(.processGone) }
        let application = AXUIElementCreateApplication(identity.processID)
        var listed: CFTypeRef?
        let listResult = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &listed)
        let list = (listed as? [AXUIElement]) ?? []
        var candidates = list
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                candidates.append(value as! AXUIElement)
            }
        }
        var ids: [UInt32?] = []
        for element in candidates {
            var windowID: CGWindowID = 0
            let found = getWindow(element, &windowID) == .success
            if found, windowID == identity.windowID { return .found(element) }
            ids.append(found ? windowID : nil)
        }
        let records = CGWindowListCopyWindowInfo([.optionIncludingWindow], identity.windowID) as? [[String: Any]]
        let serverRecord = records?.first { ($0[kCGWindowNumber as String] as? UInt32) == identity.windowID }
        let serverOnScreen = (serverRecord?[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let facts = WindowLookupFacts(
            trusted: true, processRunning: true,
            windowsListError: listResult == .success ? nil : listResult.rawValue,
            listedRoles: list.map { stringValue($0, kAXRoleAttribute) ?? "?" },
            candidateWindowIDs: ids,
            staleCandidates: candidates.filter { element in
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
            }.count,
            windowServerListed: serverRecord != nil, windowServerOnScreen: serverOnScreen,
            windowServerQuerySucceeded: records != nil,
            windowSpaces: Spaces.of(identity.windowID), activeSpaces: Spaces.current())
        let diagnosis = WindowLookupDiagnosis.diagnose(facts, windowID: identity.windowID)
        NSLog("Dropy placement lookup: wanted=%u diagnosis=%@ axWindows=%@ roles=[%@] candidates=[%@] server=%@ spaces=%@ active=%@",
              identity.windowID, diagnosis.description,
              listResult == .success ? "ok" : "err\(listResult.rawValue)",
              facts.listedRoles.joined(separator: ","),
              ids.map { $0.map(String.init) ?? "err" }.joined(separator: ","),
              records == nil ? "queryFailed" : (serverRecord == nil ? "notListed" : (serverOnScreen ? "onScreen" : "offScreen")),
              facts.windowSpaces.map { $0.map(String.init).joined(separator: ",") } ?? "unknown",
              facts.activeSpaces.map { $0.map(String.init).joined(separator: ",") } ?? "unknown")
        return .missing(diagnosis)
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }

    // MARK: Accessibility values

    static func pointValue(_ element: AXUIElement, _ attribute: String) throws -> CGPoint {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        var point = CGPoint.zero
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            throw PlacementError.attribute(attribute, result)
        }
        return point
    }

    static func sizeValue(_ element: AXUIElement, _ attribute: String) throws -> CGSize {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        var size = CGSize.zero
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            throw PlacementError.attribute(attribute, result)
        }
        return size
    }

    static func setPosition(_ point: CGPoint, of window: AXUIElement) throws {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        guard result == .success else { throw PlacementError.attribute(kAXPositionAttribute, result) }
    }

    static func setFrame(_ frame: CGRect, of window: AXUIElement, resize: Bool) throws {
        try setPosition(frame.origin, of: window)
        guard resize else { return }
        var size = frame.size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        guard result == .success else { throw PlacementError.attribute(kAXSizeAttribute, result) }
    }

    static func setMinimized(_ minimized: Bool, window: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                                  minimized as CFBoolean)
        guard result == .success else { throw PlacementError.attribute(kAXMinimizedAttribute, result) }
    }
}

/// Space facts for diagnostics only. These are private SkyLight calls looked up at
/// runtime; when they are unavailable the diagnosis falls back to on-screen state.
/// Nothing decides identity or ownership from them.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }

    /// Spaces holding the window; all Spaces for a window that joins every Space.
    static func of(_ windowID: UInt32) -> [UInt64]? {
        guard let connection = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
              let copy = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindows.self),
              let spaces = copy(connection, 0x7, [NSNumber(value: windowID)] as CFArray)?
                .takeRetainedValue() as? [NSNumber] else { return nil }
        return spaces.map(\.uint64Value)
    }

    /// Whether the display's current Space is another app's full screen, which an
    /// ordinary window cannot join. False when unknown.
    static func currentIsFullScreen(on display: CGDirectDisplayID) -> Bool {
        guard let connection = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
              let copy = symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return false }
        let uuid = CGDisplayCreateUUIDFromDisplayID(display)
            .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        let entry = displays.first { $0["Display Identifier"] as? String == uuid }
            ?? (CGDisplayIsMain(display) != 0 ? displays.first { $0["Display Identifier"] as? String == "Main" } : nil)
        // Space type 4 is a full-screen app (0 is an ordinary desktop).
        return (entry?["Current Space"] as? [String: Any])?["type"] as? Int == 4
    }

    /// Whether every display shares one set of desktops ("Displays have separate Spaces"
    /// off). The Stage then has no desktop of its own and cannot help.
    static var displaysShareSpaces: Bool {
        UserDefaults(suiteName: "com.apple.spaces")?.bool(forKey: "spans-displays") ?? false
    }

    /// Every Space of every display (desktops and full-screen spaces).
    static func all() -> [UInt64]? {
        guard let connection = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
              let copy = symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let spaces = displays.flatMap { ($0["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["id64"] as? UInt64 } }
        return spaces.isEmpty ? nil : spaces
    }

    /// The current Space of each display.
    static func current() -> [UInt64]? {
        guard let connection = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
              let copy = symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let spaces = displays.compactMap { ($0["Current Space"] as? [String: Any])?["id64"] as? UInt64 }
        return spaces.isEmpty ? nil : spaces
    }
}
