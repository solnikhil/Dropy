// Independent window checks for Scripts/device-checks.sh, so results do not rely
// only on Dropy's own report. Needs Accessibility for `frame`, `move` and `axcheck`.
//
//   WindowTool axcheck <pid>                 exit 0 if the app's AX windows are real windows
//   WindowTool find <pid>                    prints the CGWindowID of the app's largest window
//   WindowTool frame <pid> <window-id>       prints "x y w h minimized"
//   WindowTool move <pid> <window-id> <x> <y>
//   WindowTool server <window-id>            prints "x y w h onscreen" from the window server
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

func window(_ pid: pid_t, _ id: CGWindowID) -> AXUIElement {
    guard let getWindow else { fail("exact window lookup unavailable") }
    for element in axWindows(pid) {
        var found: CGWindowID = 0
        if getWindow(element, &found) == .success, found == id { return element }
    }
    fail("window \(id) not found in the Accessibility tree")
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
    guard AXIsProcessTrusted() else { fail("Accessibility not granted to this terminal") }
    guard let pid = args.dropFirst().first.flatMap(pid_t.init) else { fail("usage: axcheck <pid>") }
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
    print(Int(origin.x), Int(origin.y), Int(extent.width), Int(extent.height), (minimized as? Bool) == true ? 1 : 0)
case "move":
    guard args.count == 5, let pid = pid_t(args[1]), let id = CGWindowID(args[2]),
          let x = Double(args[3]), let y = Double(args[4]) else { fail("usage: move <pid> <id> <x> <y>") }
    var point = CGPoint(x: x, y: y)
    guard AXUIElementSetAttributeValue(window(pid, id), kAXPositionAttribute as CFString,
                                       AXValueCreate(.cgPoint, &point)!) == .success else { fail("move failed") }
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
