// Accessibility and window-server snapshot for one process, used to classify why an
// exact window is missing from the Accessibility tree. Compiled into WindowTool.
//
// Each snapshot separates the causes that look identical from Dropy's side:
//   - permission:   AXIsProcessTrusted is false, or AX calls return kAXErrorAPIDisabled
//   - app:          the process is gone, hung (cannotComplete) or exposes no AX tree
//   - roles:        the windows list holds non-window elements
//   - stale:        an element is listed but reads fail with invalidUIElement
//   - lookup:       _AXUIElementGetWindow fails for a listed element
//   - space:        the window server lists the window on a Space that is not active
//   - placement:    the window is listed, on the active Space, but AX omits it
import AppKit
import ApplicationServices

enum Snapshot {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }

    private static let connection: Int32? = symbol("CGSMainConnectionID", as: MainConnection.self).map { $0() }

    /// The current Space of every display. Private SkyLight calls; nil when unavailable.
    static func currentSpaces() -> [UInt64]? {
        guard let connection, let copy = symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return displays.compactMap { ($0["Current Space"] as? [String: Any])?["id64"] as? UInt64 }
    }

    /// Spaces that hold the window (all Spaces for sticky windows).
    static func spaces(of windowID: CGWindowID) -> [UInt64]? {
        guard let connection, let copy = symbol("CGSCopySpacesForWindows", as: CopySpaces.self),
              let spaces = copy(connection, 0x7, [NSNumber(value: windowID)] as CFArray)?
                .takeRetainedValue() as? [NSNumber] else { return nil }
        return spaces.map(\.uint64Value)
    }

    static func errorName(_ error: AXError) -> String {
        switch error {
        case .success: "ok"
        case .apiDisabled: "apiDisabled"
        case .invalidUIElement: "invalidUIElement"
        case .cannotComplete: "cannotComplete"
        case .attributeUnsupported: "attributeUnsupported"
        case .noValue: "noValue"
        case .notImplemented: "notImplemented"
        case .failure: "failure"
        case .illegalArgument: "illegalArgument"
        default: "ax\(error.rawValue)"
        }
    }

    private static func copy(_ element: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (value, result)
    }

    private static func describe(_ element: AXUIElement, getWindow: GetWindow?) -> [String: Any] {
        var out: [String: Any] = [:]
        let (role, roleError) = copy(element, kAXRoleAttribute)
        out["role"] = (role as? String) ?? "err:\(errorName(roleError))"
        if let subrole = copy(element, kAXSubroleAttribute).0 as? String { out["subrole"] = subrole }
        if let getWindow {
            var id: CGWindowID = 0
            let result = getWindow(element, &id)
            out["windowID"] = result == .success ? Int(id) : "err:\(errorName(result))" as Any
        }
        let (position, positionError) = copy(element, kAXPositionAttribute)
        var point = CGPoint.zero
        if let position, CFGetTypeID(position) == AXValueGetTypeID(),
           AXValueGetValue(position as! AXValue, .cgPoint, &point) {
            out["position"] = [point.x, point.y]
        } else {
            out["position"] = "err:\(errorName(positionError))"
        }
        let (minimized, minimizedError) = copy(element, kAXMinimizedAttribute)
        out["minimized"] = (minimized as? Bool).map { $0 as Any } ?? "err:\(errorName(minimizedError))"
        return out
    }

    /// A JSON object describing the process's Accessibility tree and window-server windows.
    static func take(pid: pid_t, focus windowID: CGWindowID?, getWindow: GetWindow?) -> [String: Any] {
        var out: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "pid": Int(pid),
                                  "trusted": AXIsProcessTrusted()]
        out["activeSpaces"] = currentSpaces() ?? "unavailable"
        if let application = NSRunningApplication(processIdentifier: pid) {
            out["app"] = ["bundle": application.bundleIdentifier ?? "?", "hidden": application.isHidden,
                          "active": application.isActive, "terminated": application.isTerminated]
        } else {
            out["app"] = "gone"
        }
        let app = AXUIElementCreateApplication(pid)
        let (windows, windowsError) = copy(app, kAXWindowsAttribute)
        out["axWindowsResult"] = errorName(windowsError)
        out["axWindows"] = (windows as? [AXUIElement] ?? []).map { describe($0, getWindow: getWindow) }
        let (children, childrenError) = copy(app, kAXChildrenAttribute)
        out["axChildren"] = (children as? [AXUIElement])?.map { copy($0, kAXRoleAttribute).0 as? String ?? "?" }
            ?? "err:\(errorName(childrenError))" as Any
        for (key, attribute) in [("axMain", kAXMainWindowAttribute), ("axFocused", kAXFocusedWindowAttribute)] {
            let (value, error) = copy(app, attribute)
            if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                out[key] = describe(value as! AXUIElement, getWindow: getWindow)
            } else {
                out[key] = "err:\(errorName(error))"
            }
        }
        let server = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        out["serverWindows"] = server.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
            .compactMap { info -> [String: Any]? in
                guard let id = info[kCGWindowNumber as String] as? UInt32 else { return nil }
                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .null
                // Only normal-layer windows and the focus window matter; skip menus and helpers.
                guard layer == 0 || id == windowID else { return nil }
                return ["id": Int(id), "layer": layer, "onscreen": (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                        "bounds": [bounds.minX, bounds.minY, bounds.width, bounds.height],
                        "spaces": spaces(of: id) ?? []]
            }
        if let windowID { out["classification"] = classify(out, windowID: windowID) }
        return out
    }

    /// The most specific explanation for a missing window, from one snapshot.
    static func classify(_ snapshot: [String: Any], windowID: CGWindowID) -> String {
        if snapshot["trusted"] as? Bool != true { return "permission:notTrusted" }
        guard snapshot["app"] is [String: Any] else { return "app:processGone" }
        let result = snapshot["axWindowsResult"] as? String ?? "?"
        if result == "apiDisabled" { return "permission:apiDisabled" }
        if result != "ok" { return "app:axWindows=\(result)" }
        let windows = snapshot["axWindows"] as? [[String: Any]] ?? []
        if windows.contains(where: { ($0["windowID"] as? Int) == Int(windowID) }) { return "found" }
        let reason = listMiss(snapshot, windows: windows, windowID: windowID)
        // The windows list covers only the active Space; main and focused cover every Space.
        let viaMain = ["axMain", "axFocused"].contains { key in
            ((snapshot[key] as? [String: Any])?["windowID"] as? Int) == Int(windowID)
        }
        return viaMain ? "mainOrFocusedOnly:\(reason)" : reason
    }

    private static func listMiss(_ snapshot: [String: Any], windows: [[String: Any]], windowID: CGWindowID) -> String {
        let server = (snapshot["serverWindows"] as? [[String: Any]] ?? []).first { ($0["id"] as? Int) == Int(windowID) }
        guard let server else { return "windowServer:notListed" }
        let active = Set(snapshot["activeSpaces"] as? [UInt64] ?? [])
        let spaces = Set(server["spaces"] as? [UInt64] ?? [])
        if !spaces.isEmpty, !active.isEmpty, spaces.isDisjoint(with: active) { return "space:otherSpace" }
        if windows.contains(where: { ($0["role"] as? String) != (kAXWindowRole as String) }) { return "roles:nonWindowElement" }
        if windows.contains(where: { ($0["windowID"] as? String)?.hasPrefix("err:") == true }) { return "lookup:getWindowFailed" }
        if windows.contains(where: { ($0["position"] as? String) == "err:invalidUIElement" }) { return "stale:invalidElement" }
        return "missing:listedOnActiveSpaceButNotInAX"
    }
}
