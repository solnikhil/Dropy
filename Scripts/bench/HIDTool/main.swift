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

/// Processes that draw macOS permission and security prompts. Synthetic pointer input
/// must never land on them: a click there could answer a privacy prompt.
let promptOwners: Set<String> = ["UserNotificationCenter", "SecurityAgent", "universalAccessAuthWarn",
                                 "CoreServicesUIAgent", "tccd", "coreautha"]

/// Reports a refused input on stderr and, when DROPY_HID_BLOCK_LOG names a file, appends
/// it there too, so a device report can count inputs a prompt kept from being posted.
func blocked(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    if let path = ProcessInfo.processInfo.environment["DROPY_HID_BLOCK_LOG"] {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data((message + "\n").utf8)) }
    }
    exit(3)
}

/// Exits (status 3) before posting when a system prompt covers the point.
func refuseIfPromptAt(_ point: CGPoint) {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows where promptOwners.contains(window[kCGWindowOwnerName as String] as? String ?? "") {
        guard let raw = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: raw), frame.contains(point) else { continue }
        blocked("blockedByPrompt owner=\(window[kCGWindowOwnerName as String] ?? "?") at=\(Int(point.x)),\(Int(point.y))")
    }
}

/// Exits (status 3) before posting keys when a system prompt could receive them: its
/// owner is frontmost, or it has a window on screen above normal windows. Keys follow the
/// key window, and Return or Space would answer a prompt that took it.
func refuseKeysIfPromptCouldReceive() {
    if let front = NSWorkspace.shared.frontmostApplication?.localizedName, promptOwners.contains(front) {
        blocked("blockedByPrompt keys frontmost=\(front)")
    }
}

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
    refuseKeysIfPromptCouldReceive()
    let names = args.count > 2 ? args[2].split(separator: ",").map(String.init) : []
    let held = modifierKeys.filter { names.contains($0.0) }
    var flags: CGEventFlags = []
    for (_, key, flag) in held { flags.insert(flag); modifier(key, down: true, flags: flags) }
    // Hardware arrow keys carry the numeric-pad and Fn flags. Mission Control's
    // Control-arrow desktop switch ignores an arrow event without them (2026-09-29).
    let keyFlags = (123...126).contains(code) ? flags.union([.maskNumericPad, .maskSecondaryFn]) : flags
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = keyFlags
        post(event)
    }
    for (_, key, flag) in held.reversed() { flags.remove(flag); modifier(key, down: false, flags: flags) }
    _ = release()
case "click":
    guard (3...4).contains(args.count), let x = Double(args[1]), let y = Double(args[2]) else { fail("usage: click <x> <y> [mods]") }
    let names = args.count == 4 ? args[3].split(separator: ",").map(String.init) : []
    let held = modifierKeys.filter { names.contains($0.0) }
    var flags: CGEventFlags = []
    for (_, key, flag) in held { flags.insert(flag); modifier(key, down: true, flags: flags) }
    let point = CGPoint(x: x, y: y)
    refuseIfPromptAt(point)
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = flags
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        post(event)
    }
    for (_, key, flag) in held.reversed() { flags.remove(flag); modifier(key, down: false, flags: flags) }
    _ = release()
case "rightclick":
    guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else { fail("usage: rightclick <x> <y>") }
    let point = CGPoint(x: x, y: y)
    refuseIfPromptAt(point)
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .right))
    for type in [CGEventType.rightMouseDown, .rightMouseUp] {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .right)
        event?.flags = []
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        post(event)
    }
case "doubleclick":
    guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else { fail("usage: doubleclick <x> <y>") }
    let point = CGPoint(x: x, y: y)
    refuseIfPromptAt(point)
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    for click in [1, 2] {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = []
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            post(event)
        }
    }
case "drag":
    // drag <x1> <y1> <x2> <y2>: left button down, 20 dragged steps, up.
    guard args.count == 5, let x1 = Double(args[1]), let y1 = Double(args[2]), let x2 = Double(args[3]), let y2 = Double(args[4])
    else { fail("usage: drag <x1> <y1> <x2> <y2>") }
    let start = CGPoint(x: x1, y: y1)
    refuseIfPromptAt(start)
    refuseIfPromptAt(CGPoint(x: x2, y: y2))
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left))
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
    down?.flags = []
    post(down)
    var point = start
    for step in 1...20 {
        let t = Double(step) / 20
        point = CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = []
        post(event)
    }
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    up?.flags = []
    post(up)
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
    guard (2...3).contains(args.count), let dy = Int32(args[1]) else { fail("usage: scroll <dy> [mods]") }
    let names = args.count == 3 ? args[2].split(separator: ",").map(String.init) : []
    let held = modifierKeys.filter { names.contains($0.0) }
    var flags: CGEventFlags = []
    for (_, key, flag) in held { flags.insert(flag); modifier(key, down: true, flags: flags) }
    defer {
        for (_, key, flag) in held.reversed() { flags.remove(flag); modifier(key, down: false, flags: flags) }
        _ = release()
    }
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
    event?.flags = flags
    // Wheel initializers do not promise the current cursor location. Set it explicitly
    // so a test never posts the scroll to the menu bar or another window by accident.
    let point = CGEvent(source: nil)?.location ?? .zero
    refuseIfPromptAt(point)
    event?.location = point
    let hit = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).first {
        bounds($0).contains(point) && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
    }
    print("wheel pointer=\(Int(point.x)),\(Int(point.y)) hitPID=\(hit?[kCGWindowOwnerPID as String] ?? -1) window=\(hit?[kCGWindowNumber as String] ?? -1)")
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
