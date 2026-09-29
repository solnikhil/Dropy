// Real input for Scripts/dismissal-checks.sh: posts HID-level events, the way a keyboard
// and mouse would, and reports what the window server shows. Every key event carries
// explicit modifier flags and every modifier press has its release, and `release`
// clears any modifier the session believes is held.
//
//   HIDTool key <keycode> [cmd,opt,shift,ctrl]   press and release one key
//   HIDTool click <x> <y>                        left click at global top-left points
//   HIDTool move <x> <y>                         move the pointer in steps, with mouseMoved events
//   HIDTool scroll <dy>                          one pixel-unit wheel event at the pointer
//   HIDTool pointer                              prints "x y"
//   HIDTool frontmost                            prints the frontmost app's bundle ID
//   HIDTool panel <pid>                          prints "x y w h" of the process's largest on-screen window above normal level
//   HIDTool statusitem <pid>                     prints "x y w h" of the process's menu-bar item
//   HIDTool release                              releases held modifiers
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

let modifierKeys: [(String, CGKeyCode, CGEventFlags)] = [("cmd", 55, .maskCommand), ("opt", 58, .maskAlternate),
                                                          ("shift", 56, .maskShift), ("ctrl", 59, .maskControl)]

func post(_ event: CGEvent?) {
    event?.post(tap: .cghidEventTap)
    wait(0.03)
}

func modifier(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
    event?.type = .flagsChanged
    event?.flags = flags
    post(event)
}

func release() -> Bool {
    let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
    guard !CGEventSource.flagsState(.hidSystemState).intersection(mask).isEmpty ||
          !CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty else { return false }
    for (_, key, _) in modifierKeys { modifier(key, down: false, flags: []) }
    return true
}

func windows(_ pid: pid_t) -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
}

func bounds(_ info: [String: Any]) -> CGRect {
    (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .null
}

func printRect(_ rect: CGRect) { print(Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)) }

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "key":
    guard args.count >= 2, let code = CGKeyCode(args[1]) else { fail("usage: key <keycode> [mods]") }
    let names = args.count > 2 ? args[2].split(separator: ",").map(String.init) : []
    let held = modifierKeys.filter { names.contains($0.0) }
    var flags: CGEventFlags = []
    for (_, key, flag) in held { flags.insert(flag); modifier(key, down: true, flags: flags) }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        post(event)
    }
    for (_, key, flag) in held.reversed() { flags.remove(flag); modifier(key, down: false, flags: flags) }
    _ = release()
case "click":
    guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else { fail("usage: click <x> <y>") }
    let point = CGPoint(x: x, y: y)
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = []
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        post(event)
    }
case "move":
    guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else { fail("usage: move <x> <y>") }
    let start = CGEvent(source: nil)?.location ?? .zero
    for step in 1...20 {
        let t = Double(step) / 20
        let point = CGPoint(x: start.x + (x - start.x) * t, y: start.y + (y - start.y) * t)
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = []
        post(event)
    }
case "scroll":
    // scroll <dy>: one pixel-unit wheel event at the pointer (negative scrolls down).
    guard args.count == 2, let dy = Int32(args[1]) else { fail("usage: scroll <dy>") }
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
    event?.flags = []
    post(event)
case "pointer":
    let point = CGEvent(source: nil)?.location ?? .zero
    print(Int(point.x), Int(point.y))
case "frontmost":
    print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")
case "panel":
    guard args.count == 2, let pid = pid_t(args[1]) else { fail("usage: panel <pid>") }
    let candidates = windows(pid).filter { ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 && bounds($0).height > 100 }
    guard let panel = candidates.max(by: { bounds($0).width * bounds($0).height < bounds($1).width * bounds($1).height })
    else { print("none"); exit(0) }
    printRect(bounds(panel))
case "statusitem":
    // Menu-bar extras may be drawn by the system rather than in the app's own windows
    // (macOS 27 lists none for Dropy), so ask Accessibility for the app's extras menu bar.
    guard args.count == 2, let pid = pid_t(args[1]) else { fail("usage: statusitem <pid>") }
    var bar: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), "AXExtrasMenuBar" as CFString, &bar)
    var children: CFTypeRef?
    if let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() {
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
    }
    guard let item = (children as? [AXUIElement])?.first else { print("none"); exit(0) }
    var position: CFTypeRef?, size: CFTypeRef?
    AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position)
    AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size)
    var origin = CGPoint.zero, extent = CGSize.zero
    guard let position, let size, AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent), extent.width > 0 else { print("none"); exit(0) }
    printRect(CGRect(origin: origin, size: extent))
case "release":
    print(release() ? "released held modifiers" : "no modifiers held")
default:
    fail("usage: HIDTool key|click|move|pointer|frontmost|panel|statusitem|release")
}
