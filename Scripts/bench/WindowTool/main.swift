// Independent window checks for Scripts/device-checks.sh, so results do not rely
// only on Dropy's own report. Needs Accessibility for `frame`, `move` and `axcheck`.
//
//   WindowTool axcheck <pid>                 exit 0 if the app's AX windows are real windows
//   WindowTool find <pid>                    prints the CGWindowID of the app's largest window
//   WindowTool frame <pid> <window-id>       prints "x y w h minimized appHidden"
//   WindowTool move <pid> <window-id> <x> <y>
//   WindowTool server <window-id>            prints "x y w h onscreen" from the window server
//   WindowTool snapshot <pid> [window-id]    prints one JSON line of AX and window-server state,
//                                            classifying why the window is missing (AXSnapshot.swift)
import AppKit
import ApplicationServices

typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let getWindow = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
    .map { unsafeBitCast($0, to: GetWindow.self) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func axWindows(_ pid: pid_t) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString,
                                        &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
}

/// The app's windows list covers only the active Space; main and focused windows are
/// reported on any Space. Every candidate must match the exact window ID.
func window(_ pid: pid_t, _ id: CGWindowID) -> AXUIElement {
    guard let getWindow else { fail("exact window lookup unavailable") }
    let application = AXUIElementCreateApplication(pid)
    var candidates = axWindows(pid)
    for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success, let value,
           CFGetTypeID(value) == AXUIElementGetTypeID() { candidates.append(value as! AXUIElement) }
    }
    for element in candidates {
        var found: CGWindowID = 0
        if getWindow(element, &found) == .success, found == id { return element }
    }
    let snapshot = Snapshot.take(pid: pid, focus: id, getWindow: getWindow)
    fail("window \(id) not found in the Accessibility tree: \(snapshot["classification"] ?? "?")")
}

func point(_ element: AXUIElement, _ name: String) -> CGPoint {
    var value: CFTypeRef?
    var result = CGPoint.zero
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
          CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgPoint, &result)
    else { fail("cannot read \(name)") }
    return result
}

func size(_ element: AXUIElement, _ name: String) -> CGSize {
    var value: CFTypeRef?
    var result = CGSize.zero
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
          CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgSize, &result)
    else { fail("cannot read \(name)") }
    return result
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: WindowTool axcheck|frame|move|server ...") }
switch command {
case "axcheck":
    // axcheck <pid> [window-id]: exit 0 when Accessibility is usable for the app, or for
    // that exact window. Failure output names the classification from AXSnapshot.
    guard AXIsProcessTrusted() else { fail("permission:notTrusted") }
    guard let pid = args.dropFirst().first.flatMap(pid_t.init) else { fail("usage: axcheck <pid> [window-id]") }
    if args.count > 2, let id = CGWindowID(args[2]) {
        _ = window(pid, id)
        print("ok window \(id)")
        break
    }
    let roles = axWindows(pid).map { element -> String in
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return role as? String ?? "?"
    }
    guard !roles.isEmpty, roles.allSatisfy({ $0 == kAXWindowRole as String }) else {
        fail("Accessibility returned non-window elements: \(roles)")
    }
    print("ok \(roles.count) windows")
case "find":
    guard let pid = args.dropFirst().first.flatMap(pid_t.init), let getWindow else { fail("usage: find <pid>") }
    let best = axWindows(pid).compactMap { element -> (CGWindowID, CGFloat)? in
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success else { return nil }
        let extent = size(element, kAXSizeAttribute)
        return (id, extent.width * extent.height)
    }.max { $0.1 < $1.1 }
    guard let best else { fail("no windows") }
    print(best.0)
case "frame":
    guard args.count == 3, let pid = pid_t(args[1]), let id = CGWindowID(args[2]) else { fail("usage: frame <pid> <id>") }
    let element = window(pid, id)
    let origin = point(element, kAXPositionAttribute)
    let extent = size(element, kAXSizeAttribute)
    var minimized: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
    guard let application = NSRunningApplication(processIdentifier: pid) else { fail("process gone") }
    print(origin.x, origin.y, extent.width, extent.height, (minimized as? Bool) == true ? 1 : 0, application.isHidden ? 1 : 0)
case "move":
    guard args.count == 5, let pid = pid_t(args[1]), let id = CGWindowID(args[2]),
          let x = Double(args[3]), let y = Double(args[4]) else { fail("usage: move <pid> <id> <x> <y>") }
    var point = CGPoint(x: x, y: y)
    guard AXUIElementSetAttributeValue(window(pid, id), kAXPositionAttribute as CFString,
                                       AXValueCreate(.cgPoint, &point)!) == .success else { fail("move failed") }
case "visibility":
    guard args.count == 3, let id = CGWindowID(args[1]), let dropyPID = pid_t(args[2]) else { fail("usage: visibility <id> <dropy-pid>") }
    let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    guard let source = all.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == id }),
          let bounds = (source[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else {
        print("notListed visible=0 uncovered=0")
        exit(0)
    }
    let onScreen = (source[kCGWindowIsOnscreen as String] as? Bool) == true
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let parts = ids.map(CGDisplayBounds).map { bounds.intersection($0) }.filter { !$0.isNull }
    func area(_ rect: CGRect) -> Double { rect.isNull ? 0 : Double(rect.width * rect.height) }
    let visible = onScreen ? parts.reduce(0.0) { $0 + area($1) } : 0
    let covers = all.compactMap { info -> CGRect? in
        guard (info[kCGWindowOwnerPID as String] as? Int32) == dropyPID,
              (info[kCGWindowName as String] as? String) == "Dropy parking:\(id)",
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              (info[kCGWindowAlpha as String] as? Double) == 1,
              (info[kCGWindowLayer as String] as? Int ?? 0) > (source[kCGWindowLayer as String] as? Int ?? 0)
        else { return nil }
        return (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }
    // Subtract each cover from the remaining rectangles, avoiding double counting.
    var remaining = onScreen ? parts : []
    for cover in covers {
        remaining = remaining.flatMap { part -> [CGRect] in
            let overlap = part.intersection(cover)
            guard !overlap.isNull else { return [part] }
            return [CGRect(x: part.minX, y: part.minY, width: part.width, height: overlap.minY - part.minY),
                    CGRect(x: part.minX, y: overlap.maxY, width: part.width, height: part.maxY - overlap.maxY),
                    CGRect(x: part.minX, y: overlap.minY, width: overlap.minX - part.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: part.maxX - overlap.maxX, height: overlap.height)]
                .filter { $0.width > 0 && $0.height > 0 }
        }
    }
    let total = max(area(bounds), 1)
    print(String(format: "onscreen=%d visible=%.6f uncovered=%.6f tabs=%d", onScreen ? 1 : 0, visible / total, remaining.reduce(0.0) { $0 + area($1) } / total, covers.count))
case "snapshot":
    // snapshot <pid> [window-id]: one JSON line describing the AX tree and window server.
    guard args.count >= 2, let pid = pid_t(args[1]) else { fail("usage: snapshot <pid> [window-id]") }
    let focus = args.count > 2 ? CGWindowID(args[2]) : nil
    let json = Snapshot.take(pid: pid, focus: focus, getWindow: getWindow)
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
case "watch":
    // watch <pid> <window-id> <seconds>: poll every 100 ms and print a JSON line whenever
    // the active Space, the frontmost app or the window's classification changes.
    guard args.count == 4, let pid = pid_t(args[1]), let id = CGWindowID(args[2]),
          let seconds = Double(args[3]) else { fail("usage: watch <pid> <window-id> <seconds>") }
    var last = ""
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        let snapshot = Snapshot.take(pid: pid, focus: id, getWindow: getWindow)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let key = "\(snapshot["activeSpaces"] ?? "")|\(front)|\(snapshot["classification"] ?? "")"
        if key != last {
            var line = snapshot
            line["frontmost"] = front
            let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
            last = key
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
case "fixture":
    // fixture <command>: send a command to the Dropy fixture app (Scripts/bench/Fixture).
    guard args.count == 2 else { fail("usage: fixture space:other|space:home|space:<id>|second|quit") }
    DistributedNotificationCenter.default().postNotificationName(
        .init("org.dropy.fixture.command"), object: args[1], userInfo: nil, deliverImmediately: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
case "spaces":
    // spaces: the current Space of each display and the frontmost app, to detect a
    // person switching desktops or apps while a check runs.
    let current = Snapshot.currentSpaces()?.map(String.init).joined(separator: ",") ?? "unknown"
    print("active=\(current) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
case "server":
    guard args.count == 2, let id = CGWindowID(args[1]),
          let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
          let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
    else { print("notListed"); exit(0) }
    print(Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height),
          (info[kCGWindowIsOnscreen as String] as? Bool) == true ? 1 : 0)
default:
    fail("unknown command \(command)")
}
