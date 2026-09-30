// Exact-window input harness driver (issue #8). Sends one scripted action at a time to
// window A of the input fixture (Scripts/bench/InputFixture) through each candidate input
// route, under each source condition and focus state, and judges the result from the
// fixture's own log: the action must take effect in A and nowhere else. An effect in
// window B is a wrong-window failure, whatever else happened.
//
//   InputProbe matrix <fixture-log.jsonl> <results.jsonl> [route,...]
//
// Routes (see docs/FEASIBILITY.md):
//   pid         CGEvent.postToPid to the app process (public)
//   pidWindow   postToPid with the event's window set to A: undocumented fields 51/91/92 and
//               the private CGEventSetWindowLocation SPI (window-relative location)
//   activate    activate the app, raise A, post through the HID tap, then hand focus back (public)
//   ax          Accessibility semantic actions on A's elements (public)
// Conditions: visible, covered (B exactly over A), parked (moved beyond the displays),
// otherSpace (A on another desktop), minimized. Focus: A key, B key, app inactive.
//
// Needs Accessibility for this process. The activate route moves the real pointer and
// changes the frontmost app; it is skipped when the target point is off every display,
// and the pointer and frontmost app are restored after each trial.
import AppKit
import ApplicationServices

typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let getWindow = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
    .map { unsafeBitCast($0, to: GetWindow.self) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

// MARK: Fixture channel

struct Fixture {
    let log: String
    let pid: pid_t
    let a: CGWindowID
    let b: CGWindowID
    let app: AXUIElement

    static func attach(log: String) -> Fixture {
        for _ in 0..<40 {
            if let ready = lines(log).last(where: { $0["kind"] as? String == "ready" }),
               let pid = ready["pid"] as? Int, let a = ready["A"] as? Int, let b = ready["B"] as? Int {
                return Fixture(log: log, pid: pid_t(pid), a: CGWindowID(a), b: CGWindowID(b),
                               app: AXUIElementCreateApplication(pid_t(pid)))
            }
            wait(0.25)
        }
        fail("fixture not ready in \(log)")
    }

    static func lines(_ path: String) -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func send(_ command: String) {
        sendCommand(command)
        wait(0.05)
    }

    /// The fixture's own report of both windows, plus the log length at that moment.
    func state() -> (state: [String: Any], mark: Int)? {
        let nonce = UUID().uuidString
        send("state:\(nonce)")
        for _ in 0..<60 {
            let all = Fixture.lines(log)
            if let index = all.lastIndex(where: { $0["nonce"] as? String == nonce }) { return (all[index], index) }
            wait(0.05)
        }
        return nil
    }

    func events(from start: Int, to end: Int) -> [[String: Any]] {
        let all = Fixture.lines(log)
        guard start < end, end <= all.count else { return [] }
        return Array(all[start..<end])
    }
}

/// Commands go to the AppKit fixture as distributed notifications, or, when
/// PROBE_COMMAND_FILE is set (the Electron fixture), as lines appended to that file.
let commandFile = ProcessInfo.processInfo.environment["PROBE_COMMAND_FILE"]

func sendCommand(_ command: String) {
    if let commandFile {
        guard let handle = FileHandle(forWritingAtPath: commandFile) else { fail("cannot write \(commandFile)") }
        handle.seekToEndOfFile()
        handle.write(Data((command + "\n").utf8))
        try? handle.close()
        return
    }
    DistributedNotificationCenter.default().postNotificationName(
        .init("org.dropy.inputfixture.command"), object: command, userInfo: nil, deliverImmediately: true)
}

/// Chromium builds its Accessibility tree only when an assistive client asks for it.
/// `AXManualAccessibility` is Electron's documented switch for that; the probe sets it
/// for Electron targets and records that it did, since Dropy would have to do the same.
let enablesManualAccessibility = ProcessInfo.processInfo.environment["PROBE_ELECTRON"] == "1"

func enableManualAccessibility(_ app: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
}

// MARK: Accessibility

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

/// Elements resolved while each window was reachable. An app omits a window on another
/// desktop from its windows list, but an element obtained earlier stays valid; it is
/// reused only while `_AXUIElementGetWindow` still maps it to the same window ID.
nonisolated(unsafe) var cachedWindows: [CGWindowID: AXUIElement] = [:]
nonisolated(unsafe) var lastLookupUsedCache = false

/// The exact window, from the windows list or the main/focused window, else the
/// verified cached element.
func window(_ fixture: Fixture, _ id: CGWindowID) -> AXUIElement? {
    guard let getWindow else { fail("exact window lookup unavailable") }
    var candidates = attribute(fixture.app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
        if let found = element(attribute(fixture.app, name)) { candidates.append(found) }
    }
    func matches(_ element: AXUIElement) -> Bool {
        var found: CGWindowID = 0
        return getWindow(element, &found) == .success && found == id
    }
    if let fresh = candidates.first(where: matches) {
        cachedWindows[id] = fresh
        lastLookupUsedCache = false
        return fresh
    }
    if let cached = cachedWindows[id], matches(cached) {
        lastLookupUsedCache = true
        return cached
    }
    return nil
}

/// AppKit exposes `accessibilityIdentifier` as AXIdentifier; Chromium exposes an HTML
/// `id` as AXDOMIdentifier, several levels deeper.
func descendant(_ root: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 30 else { return nil }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if attribute(child, kAXIdentifierAttribute) as? String == identifier
            || attribute(child, "AXDOMIdentifier") as? String == identifier { return child }
        if let found = descendant(child, identifier: identifier, depth: depth + 1) { return found }
    }
    return nil
}

func frame(_ element: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let position = attribute(element, kAXPositionAttribute), let extent = attribute(element, kAXSizeAttribute),
          AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(extent as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
}

@discardableResult
func setPosition(_ element: AXUIElement, _ point: CGPoint) -> AXError {
    var point = point
    return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
}

@discardableResult
func setBool(_ element: AXUIElement, _ name: String, _ value: Bool) -> AXError {
    AXUIElementSetAttributeValue(element, name as CFString, value as CFBoolean)
}

func displays() -> [CGRect] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.map(CGDisplayBounds)
}

func activeSpaces() -> String {
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    let handle = UnsafeMutableRawPointer(bitPattern: -2)
    guard let main = dlsym(handle, "CGSMainConnectionID"), let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces"),
          let list = unsafeBitCast(copy, to: CopyDisplaySpaces.self)(unsafeBitCast(main, to: MainConnection.self)())?
            .takeRetainedValue() as? [[String: Any]] else { return "unknown" }
    return list.compactMap { ($0["Current Space"] as? [String: Any])?["id64"] as? UInt64 }.map(String.init).joined(separator: ",")
}

// MARK: Trial model

enum Route: String, CaseIterable {
    case pid, pidWindow, activate, ax
    /// Text candidates for windows whose field ignores `AXSelectedText` (Chromium):
    /// splice into the exact element's `AXValue` at its selection, or focus the exact
    /// element first. Only `type` applies; other actions report notApplicable.
    case axValue, axFocus
    /// Routes run by default; the text candidates are opt-in by name.
    static let standard: [Route] = [.pid, .pidWindow, .activate, .ax]
}
enum Action: String, CaseIterable { case type, click, scroll, shortcut }
enum Condition: String, CaseIterable { case visible, covered, parked, otherSpace, minimized }
enum Focus: String, CaseIterable { case aKey, bKey, appInactive }

/// A's home frame and B's, captured once so every condition can be undone exactly.
struct Home { var a: CGRect; var b: CGRect }

let typedText = "dx7"

/// Makes an app frontmost through Accessibility. Since macOS 14 activation is cooperative:
/// a background app asking to activate itself, or another app asking for it, is often
/// refused, which the setup check showed as focus-state mismatches.
@discardableResult
func makeFrontmost(_ pid: pid_t) -> Bool {
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    wait(0.4)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
    // AX refuses an app whose only windows are minimized; a direct request still works then.
    NSRunningApplication(processIdentifier: pid)?.activate()
    wait(0.4)
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
}

/// A windowless-looking app to hand focus to for "app inactive": the placement fixture
/// with its only window minimized, so activating it switches neither desktop nor windows.
/// Activating Finder instead switched desktops in the first runs.
let focusSink: pid_t? = ProcessInfo.processInfo.environment["PROBE_FOCUS_SINK_PID"].flatMap(pid_t.init)

func prepareFocusSink() {
    guard let focusSink else { return }
    let app = AXUIElementCreateApplication(focusSink)
    for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }
    wait(0.8)
}

func makeOtherAppFrontmost() {
    if let focusSink {
        makeFrontmost(focusSink)
        prepareFocusSink() // keep its window out of the way if activation restored it
    }
    else { NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate(); wait(0.5) }
}

/// Parked the way Dropy parks: AppKit keeps a small strip on screen (Dropy covers it).
func isParked(_ extent: CGRect) -> Bool {
    let area = extent.width * extent.height
    guard area > 0 else { return false }
    let visible = displays().reduce(CGFloat(0)) { total, display in
        let overlap = extent.intersection(display)
        return overlap.isNull ? total : total + overlap.width * overlap.height
    }
    return visible / area < 0.05
}

/// Sets up a condition; returns nil when it cannot be reached (e.g. one desktop only).
func setUp(_ condition: Condition, _ focus: Focus, fixture: Fixture, home: Home) -> String? {
    guard let a = window(fixture, fixture.a), let b = window(fixture, fixture.b) else { return "windowNotFound" }
    makeFrontmost(fixture.pid)
    let key = focus == .aKey ? a : b
    setBool(key, kAXMainAttribute, true)
    AXUIElementPerformAction(key, kAXRaiseAction as CFString)
    fixture.send(focus == .aKey ? "key:A" : "key:B")
    wait(0.4)
    switch condition {
    case .visible: break
    case .covered:
        setPosition(b, home.a.origin)
        AXUIElementPerformAction(b, kAXRaiseAction as CFString)
    case .parked:
        let right = displays().map(\.maxX).max() ?? 0, bottom = displays().map(\.maxY).max() ?? 0
        setPosition(a, CGPoint(x: right + 200, y: bottom + 200))
    case .otherSpace:
        let before = Fixture.lines(fixture.log).count
        fixture.send("space:other")
        wait(0.8)
        let reply = Fixture.lines(fixture.log).dropFirst(before).last { $0["kind"] as? String == "space" }
        if let error = reply?["error"] as? String { return error }
    case .minimized:
        setBool(a, kAXMinimizedAttribute, true)
        wait(0.8)
    }
    if focus == .appInactive { makeOtherAppFrontmost() }
    wait(0.3)
    guard let state = fixture.state()?.state,
          let aState = state["A"] as? [String: Any], let bState = state["B"] as? [String: Any],
          let active = state["active"] as? Bool else { return "setupStateUnavailable" }
    switch focus {
    case .aKey:
        guard active, aState["key"] as? Bool == true else { return "setupFocusMismatch" }
    case .bKey:
        guard active, bState["key"] as? Bool == true else { return "setupFocusMismatch" }
    case .appInactive:
        guard !active else { return "setupFocusMismatch" }
    }
    switch condition {
    case .visible: break
    case .covered:
        guard let extent = frame(b), extent.origin == home.a.origin else { return "setupCoverFailed" }
    case .parked:
        guard let extent = frame(a), isParked(extent) else { return "setupParkingFailed" }
    case .minimized:
        guard aState["minimized"] as? Bool == true else { return "setupMinimizeFailed" }
    case .otherSpace:
        guard let reply = Fixture.lines(fixture.log).last(where: { $0["kind"] as? String == "space" }),
              let spaces = reply["A"] as? [UInt64], !spaces.isEmpty,
              activeSpaces() != "unknown",
              !spaces.contains(where: { activeSpaces().split(separator: ",").contains(Substring(String($0))) }) else {
            return "setupSpaceFailed"
        }
    }
    return nil
}

func tearDown(fixture: Fixture, home: Home) {
    fixture.send("space:home")
    wait(0.5)
    if let a = window(fixture, fixture.a) {
        if attribute(a, kAXMinimizedAttribute) as? Bool == true { setBool(a, kAXMinimizedAttribute, false); wait(0.8) }
        setPosition(a, home.a.origin)
    }
    if let b = window(fixture, fixture.b) { setPosition(b, home.b.origin) }
    fixture.send("reset")
    wait(0.3)
}

// MARK: Routes

// Every event gets explicit modifier flags. An event created without a source copies the
// current session flags, and a Command-flagged key posted to the HID tap without its own
// Command key-up left Command logically held for the whole session in an early run.

func keyEvents(_ text: String) -> [CGEvent] {
    text.flatMap { character -> [CGEvent] in
        var units = Array(String(character).utf16)
        return [true, false].compactMap { down in
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event?.flags = []
            return event
        }
    }
}

func modifierEvent(command down: Bool) -> CGEvent? {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: down)
    event?.type = .flagsChanged
    event?.flags = down ? .maskCommand : []
    return event
}

/// Command down, K down/up, Command up, as a keyboard produces them.
func shortcutEvents() -> [CGEvent] {
    let keys: [CGEvent] = [true, false].compactMap { down in
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 40, keyDown: down) // "k"
        event?.flags = .maskCommand
        return event
    }
    return [modifierEvent(command: true)].compactMap { $0 } + keys + [modifierEvent(command: false)].compactMap { $0 }
}

func clickEvents(at point: CGPoint) -> [CGEvent] {
    [CGEventType.leftMouseDown, .leftMouseUp].compactMap {
        let event = CGEvent(mouseEventSource: nil, mouseType: $0, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = []
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }
}

func scrollEvents(at point: CGPoint) -> [CGEvent] {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -240, wheel2: 0, wheel3: 0)
    else { return [] }
    event.location = point
    event.flags = []
    return [event]
}

let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

/// Releases any modifier the session believes is held. Returns true if one was.
@discardableResult
func releaseModifiers() -> Bool {
    guard !CGEventSource.flagsState(.hidSystemState).intersection(modifierMask).isEmpty ||
          !CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty else { return false }
    for key: CGKeyCode in [55, 54, 56, 60, 58, 61, 59, 62] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        event?.type = .flagsChanged
        event?.flags = []
        event?.post(tap: .cghidEventTap)
    }
    wait(0.1)
    return true
}

/// Mouse buttons the session believes are down. A trial must never leave one held.
func buttonsDown() -> [String] {
    [(CGMouseButton.left, "left"), (.right, "right"), (.center, "center")].compactMap {
        CGEventSource.buttonState(.combinedSessionState, button: $0.0) || CGEventSource.buttonState(.hidSystemState, button: $0.0)
            ? $0.1 : nil
    }
}

func pointerLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

/// Records pointer, button and modifier state after a trial. Returns true when the
/// trial left the session unsafe (a held modifier or button), which fails the trial.
@discardableResult
func recordSessionState(_ record: inout [String: Any], pointerBefore: CGPoint) -> Bool {
    let pointerAfter = pointerLocation()
    if hypot(pointerAfter.x - pointerBefore.x, pointerAfter.y - pointerBefore.y) > 0.5 {
        record["pointerMoved"] = "\(Int(pointerBefore.x)),\(Int(pointerBefore.y))→\(Int(pointerAfter.x)),\(Int(pointerAfter.y))"
    }
    var unsafe = false
    let held = buttonsDown()
    if !held.isEmpty {
        record["buttonsLeftHeld"] = held
        for button in held {
            let (type, mouse): (CGEventType, CGMouseButton) = button == "left" ? (.leftMouseUp, .left)
                : button == "right" ? (.rightMouseUp, .right) : (.otherMouseUp, .center)
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pointerAfter, mouseButton: mouse)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
        unsafe = true
    }
    if releaseModifiers() {
        record["modifiersLeftHeld"] = true
        unsafe = true
    }
    if unsafe, !(record["outcome"] as? String ?? "").hasPrefix("wrongWindow") { record["outcome"] = "unsafeSessionState" }
    return unsafe
}

/// Undocumented CGEvent fields naming the event's window (51, which AppKit turns into
/// `NSEvent.windowNumber`) and the window under the pointer (91, 92).
let eventWindow = CGEventField(rawValue: 51)!
let windowUnderPointer = CGEventField(rawValue: 91)!
let windowThatCanHandle = CGEventField(rawValue: 92)!
/// Private CoreGraphics SPI setting the window-relative location; without it AppKit
/// derives a wrong `locationInWindow` for a window-targeted event.
typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
let setWindowLocation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
    .map { unsafeBitCast($0, to: SetWindowLocation.self) }

/// Performs one action. Returns nil when sent, or why the route does not apply.
func perform(_ route: Route, _ action: Action, fixture: Fixture) -> String? {
    guard let a = window(fixture, fixture.a) else { return "windowNotFound" }
    let target: CGRect?
    switch action {
    case .type, .shortcut: target = descendant(a, identifier: "text").flatMap(frame)
    case .click: target = descendant(a, identifier: "button").flatMap(frame)
    case .scroll: target = descendant(a, identifier: "scroll").flatMap(frame)
    }
    guard let target else { return "elementNotFound" }
    let point = CGPoint(x: target.midX, y: target.midY)
    func events() -> [CGEvent] {
        switch action {
        case .type: keyEvents(typedText)
        case .shortcut: shortcutEvents()
        case .click: clickEvents(at: point)
        case .scroll: scrollEvents(at: point)
        }
    }
    switch route {
    case .pid, .pidWindow:
        let origin = frame(a)?.origin ?? .zero
        if route == .pidWindow, setWindowLocation == nil { return "notApplicable(noSetWindowLocation)" }
        for event in events() {
            if route == .pidWindow {
                event.setIntegerValueField(eventWindow, value: Int64(fixture.a))
                event.setIntegerValueField(windowUnderPointer, value: Int64(fixture.a))
                event.setIntegerValueField(windowThatCanHandle, value: Int64(fixture.a))
                setWindowLocation?(event, CGPoint(x: point.x - origin.x, y: point.y - origin.y))
            }
            event.postToPid(fixture.pid)
            wait(0.02)
        }
    case .activate:
        if action == .click || action == .scroll, !displays().contains(where: { $0.contains(point) }) {
            return "notApplicable(pointOffDisplay)"
        }
        if attribute(a, kAXMinimizedAttribute) as? Bool == true { return "notApplicable(minimized)" }
        let previous = NSWorkspace.shared.frontmostApplication
        let pointer = CGEvent(source: nil)?.location ?? .zero
        NSRunningApplication(processIdentifier: fixture.pid)?.activate()
        setBool(a, kAXMainAttribute, true)
        AXUIElementPerformAction(a, kAXRaiseAction as CFString)
        wait(0.4)
        if action == .type {
            // Put the caret in A's field first, as a person would: click it when it is on a
            // display, otherwise ask Accessibility to focus it.
            if displays().contains(where: { $0.contains(point) }) {
                for event in clickEvents(at: point) { event.post(tap: .cghidEventTap); wait(0.02) }
            } else if let field = descendant(a, identifier: "text") {
                setBool(field, kAXFocusedAttribute, true)
            }
            wait(0.2)
        }
        for event in events() { event.post(tap: .cghidEventTap); wait(0.02) }
        wait(0.3)
        CGWarpMouseCursorPosition(pointer)
        previous?.activate()
        wait(0.3)
    case .axValue, .axFocus:
        guard action == .type else { return "notApplicable(textRouteOnly)" }
        guard let field = descendant(a, identifier: "text") else { return "elementNotFound" }
        return route == .axValue ? spliceValue(field, typedText) : focusThenInsert(field, typedText)
    case .ax:
        switch action {
        case .type:
            // Insert without focusing first: Dropy's router does the same, and focusing an
            // element of a window on another desktop switched desktops in the first run.
            guard let field = descendant(a, identifier: "text") else { return "elementNotFound" }
            let result = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, typedText as CFString)
            if result != .success { return "axError(\(result.rawValue))" }
        case .click:
            guard let button = descendant(a, identifier: "button") else { return "elementNotFound" }
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result != .success { return "axError(\(result.rawValue))" }
        case .scroll:
            guard let scroll = descendant(a, identifier: "scroll"),
                  let bar = element(attribute(scroll, kAXVerticalScrollBarAttribute)) else { return "elementNotFound" }
            let result = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 0.5 as CFNumber)
            if result != .success { return "axError(\(result.rawValue))" }
        case .shortcut:
            // Menu commands are app-level: AX can press the item but cannot say which window
            // it acts on. It acts on the key window, which is exactly the ambiguity to record.
            guard let bar = element(attribute(fixture.app, kAXMenuBarAttribute)),
                  let item = findMenuItem(bar, title: "Count in key window") else { return "elementNotFound" }
            let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
            if result != .success { return "axError(\(result.rawValue))" }
        }
    }
    wait(0.5)
    return nil
}

/// Inserts text at the element's selection by rewriting its whole value, then puts the
/// caret after the insertion. Nothing but this element is addressed.
func spliceValue(_ field: AXUIElement, _ text: String) -> String? {
    guard let value = attribute(field, kAXValueAttribute) as? String else { return "noValue" }
    var range = CFRange(location: value.utf16.count, length: 0)
    if let raw = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
        AXValueGetValue(raw as! AXValue, .cfRange, &range)
    }
    let units = Array(value.utf16)
    guard range.location >= 0, range.length >= 0, range.location + range.length <= units.count else { return "badRange" }
    let next = String(decoding: units[..<range.location], as: UTF16.self) + text
        + String(decoding: units[(range.location + range.length)...], as: UTF16.self)
    let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, next as CFString)
    guard result == .success else { return "axError(\(result.rawValue))" }
    var caret = CFRange(location: range.location + text.utf16.count, length: 0)
    AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &caret)!)
    return nil
}

/// Focuses the exact element, then inserts at its selection.
func focusThenInsert(_ field: AXUIElement, _ text: String) -> String? {
    let focus = setBool(field, kAXFocusedAttribute, true)
    guard focus == .success else { return "axError(focus \(focus.rawValue))" }
    wait(0.2)
    let result = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString)
    return result == .success ? nil : "axError(\(result.rawValue))"
}

func findMenuItem(_ root: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 5 else { return nil }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if attribute(child, kAXTitleAttribute) as? String == title { return child }
        if let found = findMenuItem(child, title: title, depth: depth + 1) { return found }
    }
    return nil
}

// MARK: Judging

/// What the action did to one window, from the fixture's before/after state.
func effect(_ action: Action, before: [String: Any], after: [String: Any]) -> Bool {
    switch action {
    case .type: (after["text"] as? String ?? "") != (before["text"] as? String ?? "")
    case .click: (after["presses"] as? Int ?? 0) > (before["presses"] as? Int ?? 0)
    case .scroll: (after["scroll"] as? Double ?? 0) != (before["scroll"] as? Double ?? 0)
    case .shortcut: (after["commands"] as? Int ?? 0) > (before["commands"] as? Int ?? 0)
    }
}

/// Failed actions may have already delivered input. Always judge both windows before
/// considering the API result; a wrong-window observation must never become "notSent".
func judge(inA: Bool, inB: Bool, receivedBy: [String: Int], actionError: String?) -> String {
    if inB { return "wrongWindow" }
    if receivedBy["B", default: 0] > 0 { return "wrongWindow(delivered)" }
    if let actionError {
        return actionError.hasPrefix("notApplicable") ? actionError : "notSent(\(actionError))"
    }
    return inA ? "pass" : "noEffect"
}

func run(fixture: Fixture, results path: String, routes: [Route]) {
    prepareFocusSink()
    let manualAccessibility = enablesManualAccessibility && enableManualAccessibility(fixture.app)
    if enablesManualAccessibility { wait(1.0) } // Chromium builds its tree asynchronously
    FileManager.default.createFile(atPath: path, contents: nil)
    let output = FileHandle(forWritingAtPath: path)!
    guard let a = window(fixture, fixture.a), let b = window(fixture, fixture.b),
          let homeA = frame(a), let homeB = frame(b) else { fail("fixture windows not reachable") }
    let home = Home(a: homeA, b: homeB)
    let frontmost = NSWorkspace.shared.frontmostApplication
    var tally: [String: Int] = [:]
    for condition in Condition.allCases {
        for focus in Focus.allCases {
            // Making A key would bring it back on screen, onto the active desktop or in front of B.
            if focus == .aKey, [.covered, .otherSpace, .minimized].contains(condition) { continue }
            for route in routes {
                for action in Action.allCases {
                    var record: [String: Any] = ["condition": condition.rawValue, "focus": focus.rawValue,
                                                 "route": route.rawValue, "action": action.rawValue,
                                                 // Key-window, frontmost-app, desktop, pointer and button
                                                 // changes are recorded below; InputEvidence accepts only such records.
                                                 "sideEffectsRecorded": true, "probeVersion": 3]
                    if manualAccessibility { record["axManualAccessibility"] = true }
                    var pointerBefore = pointerLocation()
                    if let blocked = setUp(condition, focus, fixture: fixture, home: home) {
                        record["outcome"] = "notRun(\(blocked))"
                    } else if let before = fixture.state() {
                        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                        let spaceBefore = activeSpaces()
                        pointerBefore = pointerLocation()
                        let skipped = perform(route, action, fixture: fixture)
                        if lastLookupUsedCache { record["lookup"] = "cachedElement" }
                        if let skipped { record["actionError"] = skipped }
                        if let after = fixture.state() {
                            let inA = effect(action, before: before.state["A"] as? [String: Any] ?? [:],
                                             after: after.state["A"] as? [String: Any] ?? [:])
                            let inB = effect(action, before: before.state["B"] as? [String: Any] ?? [:],
                                             after: after.state["B"] as? [String: Any] ?? [:])
                            let received = fixture.events(from: before.mark, to: after.mark)
                                .filter { $0["kind"] as? String == "event" }
                            let receivedBy = Dictionary(grouping: received, by: { $0["w"] as? String ?? "?" })
                                .mapValues(\.count)
                            record["receivedBy"] = receivedBy
                            if action == .type {
                                // Exact result, not just "changed": the text must be the typed
                                // characters at the caret. A page-level input event must also have
                                // fired, or the app's own state would not know about the edit.
                                let textA = (after.state["A"] as? [String: Any])?["text"] as? String ?? ""
                                record["textA"] = textA
                                let pageEdits = fixture.events(from: before.mark, to: after.mark).filter { $0["kind"] as? String == "effect" && $0["effect"] as? String == "text" && $0["w"] as? String == "A" }
                                record["inputEventsA"] = pageEdits.count
                            }
                            // Delivery to B is a failure even without a visible effect: in a real
                            // app the same event would act on the other document.
                            record["outcome"] = judge(inA: inA, inB: inB, receivedBy: receivedBy, actionError: skipped)
                            if action == .type, record["outcome"] as? String == "pass" {
                                if record["textA"] as? String != typedText { record["outcome"] = "partialEffect(text)" }
                                else if record["inputEventsA"] as? Int == 0 { record["outcome"] = "partialEffect(noInputEvent)" }
                            }
                            let focusEvents = fixture.events(from: before.mark, to: after.mark).filter {
                                $0["kind"] as? String == "focus" &&
                                ["becameKey", "appActive", "appInactive"].contains($0["change"] as? String ?? "")
                            }
                            if !focusEvents.isEmpty {
                                record["focusChangedDuringTrial"] = true
                                // Which changes, so evidence can tell "A became key inside its
                                // app" from "the app was activated", even if it was handed back.
                                record["focusChanges"] = Array(Set(focusEvents.compactMap { $0["change"] as? String })).sorted()
                            }
                            if activeSpaces() != spaceBefore { record["desktopChanged"] = "\(spaceBefore)→\(activeSpaces())" }
                            let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                            if frontAfter != frontBefore { record["frontmostChanged"] = "\(frontBefore)→\(frontAfter)" }
                            let aKey = (after.state["A"] as? [String: Any])?["key"] as? Bool
                            let aKeyBefore = (before.state["A"] as? [String: Any])?["key"] as? Bool
                            if aKey != aKeyBefore { record["keyWindowChanged"] = true }
                        } else {
                            record["outcome"] = "noState"
                        }
                    } else {
                        record["outcome"] = "noState"
                    }
                    recordSessionState(&record, pointerBefore: pointerBefore)
                    tearDown(fixture: fixture, home: home)
                    let outcome = record["outcome"] as? String ?? "?"
                    tally[outcome.components(separatedBy: "(").first ?? outcome, default: 0] += 1
                    let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    output.write(data + Data("\n".utf8))
                    print(condition.rawValue, focus.rawValue, route.rawValue, action.rawValue, outcome)
                    fflush(stdout)
                }
            }
        }
    }
    releaseModifiers()
    frontmost?.activate()
    print("tally", tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
}

/// Markdown summary: one row per route × action, one column per condition/focus,
/// each cell the outcome. Wrong-window outcomes are bold.
func report(_ path: String) {
    let records = Fixture.lines(path)
    var columns: [String] = []
    for record in records {
        let column = "\(record["condition"] ?? "")/\(record["focus"] ?? "")"
        if !columns.contains(column) { columns.append(column) }
    }
    print("| Route | Action | " + columns.joined(separator: " | ") + " |")
    print("|---|---|" + columns.map { _ in "---" }.joined(separator: "|") + "|")
    for route in Route.allCases {
        for action in Action.allCases {
            let row = records.filter { $0["route"] as? String == route.rawValue && $0["action"] as? String == action.rawValue }
            guard !row.isEmpty else { continue }
            let cells = columns.map { column -> String in
                guard let record = row.first(where: { "\($0["condition"] ?? "")/\($0["focus"] ?? "")" == column }) else { return "-" }
                var cell = record["outcome"] as? String ?? "?"
                if cell.hasPrefix("wrongWindow") { cell = "**\(cell)**" }
                var notes: [String] = []
                if record["frontmostChanged"] != nil { notes.append("front") }
                if record["focusChangedDuringTrial"] != nil { notes.append("focus") }
                if record["keyWindowChanged"] != nil { notes.append("key") }
                if record["desktopChanged"] != nil { notes.append("desktop") }
                if record["lookup"] != nil { notes.append("cached") }
                if record["pointerMoved"] != nil { notes.append("pointer") }
                if record["modifiersLeftHeld"] != nil { notes.append("MODIFIER HELD") }
                if record["buttonsLeftHeld"] != nil { notes.append("BUTTON HELD") }
                return notes.isEmpty ? cell : "\(cell) (\(notes.joined(separator: ",")))"
            }
            print("| \(route.rawValue) | \(action.rawValue) | " + cells.joined(separator: " | ") + " |")
        }
    }
}

// MARK: Real apps

/// A real app with two windows, A (target) and B (decoy). Effects are read from each
/// window's own Accessibility state: the first text area's value and the first scroll
/// bar's position. Only typing and scrolling are judged; nothing else is sent.
/// Chromium apps nest content far deeper than AppKit ones.
let appSearchDepth = enablesManualAccessibility ? 40 : 14

func firstDescendant(_ root: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
    guard depth < appSearchDepth else { return nil }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if attribute(child, kAXRoleAttribute) as? String == role { return child }
        if let found = firstDescendant(child, role: role, depth: depth + 1) { return found }
    }
    return nil
}

func appState(_ window: AXUIElement) -> (text: String, scroll: Double) {
    let area = firstDescendant(window, role: kAXTextAreaRole as String)
    let text = area.flatMap { attribute($0, kAXValueAttribute) as? String } ?? ""
    let bar = firstDescendant(window, role: kAXScrollBarRole as String).flatMap { bar -> AXUIElement? in
        attribute(bar, kAXOrientationAttribute) as? String == kAXVerticalOrientationValue as String ? bar : nil
    } ?? firstDescendant(window, role: kAXScrollAreaRole as String).flatMap { element(attribute($0, kAXVerticalScrollBarAttribute)) }
    let scroll = bar.flatMap { attribute($0, kAXValueAttribute) as? Double } ?? -1
    return (text, scroll)
}

/// Caret location in the window's first text area; a click there moves it.
func caret(_ window: AXUIElement) -> Int {
    guard let area = firstDescendant(window, role: kAXTextAreaRole as String),
          let range = attribute(area, kAXSelectedTextRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() else { return -1 }
    var value = CFRange()
    return AXValueGetValue(range as! AXValue, .cfRange, &value) ? value.location : -1
}

func runApp(pid: pid_t, a idA: CGWindowID, b idB: CGWindowID, results path: String, actions: [Action], routes: [Route]) {
    let fixture = Fixture(log: "/dev/null", pid: pid, a: idA, b: idB, app: AXUIElementCreateApplication(pid))
    guard let a = window(fixture, idA), let b = window(fixture, idB), let homeA = frame(a) else { fail("windows not reachable") }
    FileManager.default.createFile(atPath: path, contents: nil)
    let output = FileHandle(forWritingAtPath: path)!
    let frontmost = NSWorkspace.shared.frontmostApplication
    prepareFocusSink()
    // PROBE_APP_CONDITIONS widens the matrix (e.g. "visible,covered,parked,minimized").
    // A foreign app's window cannot be moved to another desktop from outside it.
    let conditions = (ProcessInfo.processInfo.environment["PROBE_APP_CONDITIONS"] ?? "visible,parked")
        .split(separator: ",").compactMap { Condition(rawValue: String($0)) }.filter { $0 != .otherSpace }
    let homeB = frame(b)
    if enablesManualAccessibility { _ = enableManualAccessibility(fixture.app); wait(2.0) }
    for condition in conditions {
        for focus in [Focus.bKey, .appInactive] {
            for route in routes {
                for action in actions {
                    makeFrontmost(pid)
                    setBool(b, kAXMainAttribute, true)
                    AXUIElementPerformAction(b, kAXRaiseAction as CFString)
                    wait(0.4)
                    if condition == .parked {
                        let right = displays().map(\.maxX).max() ?? 0, bottom = displays().map(\.maxY).max() ?? 0
                        setPosition(a, CGPoint(x: right + 200, y: bottom + 200))
                    }
                    if condition == .covered { setPosition(b, homeA.origin); AXUIElementPerformAction(b, kAXRaiseAction as CFString) }
                    if condition == .minimized { setBool(a, kAXMinimizedAttribute, true); wait(0.8) }
                    if focus == .appInactive { makeOtherAppFrontmost() }
                    let beforeA = appState(a), beforeB = appState(b)
                    let caretBeforeA = caret(a), caretBeforeB = caret(b)
                    let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let spaceBefore = activeSpaces()
                    let pointerBefore = pointerLocation()
                    let focusedBefore = element(attribute(fixture.app, kAXFocusedWindowAttribute))
                    var focusedIDBefore: CGWindowID = 0
                    if let focusedBefore { _ = getWindow?(focusedBefore, &focusedIDBefore) }
                    var record: [String: Any] = ["condition": condition.rawValue, "focus": focus.rawValue,
                                                 "route": route.rawValue, "action": action.rawValue,
                                                 // Key-window, frontmost-app and desktop changes are recorded
                                                 // below; InputEvidence accepts only such records.
                                                 "sideEffectsRecorded": true, "probeVersion": 3]
                    let skipped: String?
                    if focus == .bKey && (frontBefore != pid || focusedIDBefore != idB) {
                        skipped = "setupFocusMismatch"
                    } else if focus == .appInactive && frontBefore == pid {
                        skipped = "setupFocusMismatch"
                    } else if condition == .parked && frame(a).map(isParked) != true {
                        skipped = "setupParkingFailed"
                    } else if condition == .covered && frame(b)?.origin != homeA.origin {
                        skipped = "setupCoverFailed"
                    } else if condition == .minimized && attribute(a, kAXMinimizedAttribute) as? Bool != true {
                        skipped = "setupMinimizeFailed"
                    } else {
                        skipped = performOnApp(route, action, window: a, fixture: fixture)
                    }
                    if let skipped { record["actionError"] = skipped }
                    do {
                        wait(0.6)
                        let afterA = appState(a), afterB = appState(b)
                        let changed: ((text: String, scroll: Double), (text: String, scroll: Double)) -> Bool = { old, new in
                            action == .type ? old.text != new.text : old.scroll != new.scroll
                        }
                        var inA = changed(beforeA, afterA), inB = changed(beforeB, afterB)
                        if action == .click { inA = caret(a) != caretBeforeA; inB = caret(b) != caretBeforeB }
                        record["outcome"] = judge(inA: inA, inB: inB, receivedBy: [:], actionError: skipped)
                        // A change is not typing unless the typed characters appear; only
                        // lengths are recorded, never the documents' text.
                        if action == .type, record["outcome"] as? String == "pass" {
                            record["lengthA"] = [beforeA.text.count, afterA.text.count]
                            if !afterA.text.contains(typedText) || afterA.text.count != beforeA.text.count + typedText.count {
                                record["outcome"] = "partialEffect(text)"
                            }
                        }
                        var focusedIDAfter: CGWindowID = 0
                        if let focused = element(attribute(fixture.app, kAXFocusedWindowAttribute)) {
                            _ = getWindow?(focused, &focusedIDAfter)
                        }
                        if focusedIDAfter != focusedIDBefore { record["keyWindowChanged"] = true }
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier != frontBefore {
                            record["frontmostChanged"] = true
                        }
                        if activeSpaces() != spaceBefore { record["desktopChanged"] = "\(spaceBefore)→\(activeSpaces())" }
                        // Undo typed text in whichever window received it.
                        for (window, before, after) in [(a, beforeA, afterA), (b, beforeB, afterB)] where before.text != after.text {
                            if let area = firstDescendant(window, role: kAXTextAreaRole as String) {
                                AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, before.text as CFString)
                            }
                        }
                    }
                    recordSessionState(&record, pointerBefore: pointerBefore)
                    if attribute(a, kAXMinimizedAttribute) as? Bool == true { setBool(a, kAXMinimizedAttribute, false); wait(0.8) }
                    setPosition(a, homeA.origin)
                    if let homeB { setPosition(b, homeB.origin) }
                    wait(0.3)
                    let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    output.write(data + Data("\n".utf8))
                    print(condition.rawValue, focus.rawValue, route.rawValue, action.rawValue, record["outcome"] ?? "?")
                    fflush(stdout)
                }
            }
        }
    }
    frontmost?.activate()
}

func performOnApp(_ route: Route, _ action: Action, window a: AXUIElement, fixture: Fixture) -> String? {
    let targetElement = action == .type || action == .click ? firstDescendant(a, role: kAXTextAreaRole as String)
        : firstDescendant(a, role: kAXScrollAreaRole as String) ?? firstDescendant(a, role: kAXTextAreaRole as String)
    guard let targetElement, let target = frame(targetElement) else { return "notSent(elementNotFound)" }
    let point = CGPoint(x: target.midX, y: min(target.midY, target.minY + 200))
    switch route {
    case .axValue, .axFocus:
        guard action == .type else { return "notApplicable(textRouteOnly)" }
        return (route == .axValue ? spliceValue(targetElement, typedText) : focusThenInsert(targetElement, typedText))
            .map { "notSent(\($0))" }
    case .ax:
        if action == .type {
            let result = AXUIElementSetAttributeValue(targetElement, kAXSelectedTextAttribute as CFString, typedText as CFString)
            return result == .success ? nil : "notSent(axError(\(result.rawValue)))"
        }
        if action == .click {
            // In text, a click places the caret; Dropy's router asks the element for the
            // character at the point and selects an empty range there, as done here.
            var position = point
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(targetElement, kAXRangeForPositionParameterizedAttribute as CFString,
                                                             AXValueCreate(.cgPoint, &position)!, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID() else { return "notSent(noRangeAtPoint)" }
            var range = CFRange()
            AXValueGetValue(value as! AXValue, .cfRange, &range)
            var caretRange = CFRange(location: range.location, length: 0)
            let result = AXUIElementSetAttributeValue(targetElement, kAXSelectedTextRangeAttribute as CFString,
                                                      AXValueCreate(.cfRange, &caretRange)!)
            return result == .success ? nil : "notSent(axError(\(result.rawValue)))"
        }
        guard let bar = element(attribute(targetElement, kAXVerticalScrollBarAttribute))
                ?? firstDescendant(a, role: kAXScrollBarRole as String) else { return "notSent(noScrollBar)" }
        let result = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 0.5 as CFNumber)
        return result == .success ? nil : "notSent(axError(\(result.rawValue)))"
    case .pid, .pidWindow:
        let origin = frame(a)?.origin ?? .zero
        if route == .pidWindow, setWindowLocation == nil { return "notApplicable(noSetWindowLocation)" }
        let events = switch action {
        case .type: keyEvents(typedText)
        case .click: clickEvents(at: point)
        default: scrollEvents(at: point)
        }
        for event in events {
            if route == .pidWindow {
                event.setIntegerValueField(eventWindow, value: Int64(fixture.a))
                event.setIntegerValueField(windowUnderPointer, value: Int64(fixture.a))
                event.setIntegerValueField(windowThatCanHandle, value: Int64(fixture.a))
                setWindowLocation?(event, CGPoint(x: point.x - origin.x, y: point.y - origin.y))
            }
            event.postToPid(fixture.pid)
            wait(0.03)
        }
        return nil
    case .activate:
        return "notApplicable(notRunOnRealApps)"
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "self-test" {
    let cases: [(Bool, Bool, [String: Int], String?, String)] = [
        (true, false, [:], nil, "pass"),
        (false, false, [:], nil, "noEffect"),
        (true, true, [:], "axError", "wrongWindow"),
        (false, false, ["B": 1], "notApplicable(minimized)", "wrongWindow(delivered)"),
        (true, false, [:], "axError", "notSent(axError)")
    ]
    for (a, b, received, error, expected) in cases {
        guard judge(inA: a, inB: b, receivedBy: received, actionError: error) == expected else { fail("judging regression") }
    }
    // Page-probe expectations: typing replaces the selection and leaves the caret after it.
    guard pageCases.map(\.expected) == ["alphadx7 beta", "alpha dx7", "line one\nline dx7two", "hellodx7 world"],
          pageCases.map(\.expectedCaret) == [8, 9, 17, 8] else { fail("page case regression") }
    var record: [String: Any] = [:]
    let middle = pageCases[0]
    let base: [String: Any] = ["input": middle.text, "area": "", "edit": "", "events": [String: Int]()]
    func after(_ value: String, sel: [Int], input: Int) -> [String: Any] {
        base.merging(["input": value, "sel": sel, "events": ["input.input": input]]) { $1 }
    }
    let pageChecks: [([String: Any], [String: Any], String)] = [
        (after("alphadx7 beta", sel: [8, 8], input: 1), base, "pass"),
        (after("alphadx7 beta", sel: [13, 13], input: 1), base, "partialEffect(caret)"),
        (after("alphadx7 beta", sel: [8, 8], input: 0), base, "partialEffect(noInputEvent)"),
        (after("alpha betadx7", sel: [13, 13], input: 1), base, "partialEffect(value)"),
        (base, base.merging(["input": "x"]) { $1 }, "wrongWindow"),
        (base, base.merging(["events": ["keydown": 3]]) { $1 }, "wrongWindow(delivered)"),
    ]
    for (afterA, afterB, expected) in pageChecks {
        let got = judgePage(.type, pageCase: middle, beforeA: base, afterA: afterA, beforeB: base, afterB: afterB,
                            error: nil, record: &record)
        guard got == expected else { fail("page judging regression: \(got) != \(expected)") }
    }
    print("InputProbe judging checks passed")
    exit(0)
}
if args.first == "check-modifiers" {
    guard CGEventSource.flagsState(.hidSystemState).intersection(modifierMask).isEmpty,
          CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty else {
        fail("Modifier key held; release it before running the probe")
    }
    print("no modifiers held")
    exit(0)
}
if args.first == "report", args.count == 2 { report(args[1]); exit(0) }
if args.first == "page-report", args.count == 2 { pageReport(args[1]); exit(0) }
if args.first == "release" { print(releaseModifiers() ? "released held modifiers" : "no modifiers held"); exit(0) }
if args.first == "send", args.count == 2 {
    sendCommand(args[1])
    wait(0.2)
    exit(0)
}
guard AXIsProcessTrusted() else { fail("Accessibility not granted to this process") }
switch args.first {
case "matrix":
    guard args.count >= 3 else { fail("usage: InputProbe matrix <fixture-log> <results.jsonl> [routes]") }
    let routes = args.count > 3 ? args[3].split(separator: ",").compactMap { Route(rawValue: String($0)) } : Route.standard
    run(fixture: Fixture.attach(log: args[1]), results: args[2], routes: routes)
case "page":
    // page <pid> <windowA> <windowB> <results.jsonl> <electron|safari> [routes]
    guard args.count >= 6, let pid = pid_t(args[1]), let a = CGWindowID(args[2]), let b = CGWindowID(args[3]) else {
        fail("usage: InputProbe page <pid> <windowA> <windowB> <results.jsonl> <electron|safari> [routes]")
    }
    let routes = args.count > 6 ? args[6].split(separator: ",").compactMap { Route(rawValue: String($0)) } : [.ax, .axValue, .pidWindow]
    runPage(pid: pid, a: a, b: b, results: args[4], engine: args[5], routes: routes)
case "app":
    // app <pid> <windowA> <windowB> <results.jsonl> <type,scroll> [routes]
    guard args.count >= 6, let pid = pid_t(args[1]), let a = CGWindowID(args[2]), let b = CGWindowID(args[3]) else {
        fail("usage: InputProbe app <pid> <windowA> <windowB> <results.jsonl> <type,scroll> [routes]")
    }
    let actions = args[5].split(separator: ",").compactMap { Action(rawValue: String($0)) }
    let routes = args.count > 6 ? args[6].split(separator: ",").compactMap { Route(rawValue: String($0)) } : [.pid, .pidWindow, .ax]
    runApp(pid: pid, a: a, b: b, results: args[4], actions: actions, routes: routes)
case "elements":
    // elements <fixture-log>: A's and B's control centres in window-relative points, and window sizes.
    guard args.count == 2 else { fail("usage: elements <fixture-log>") }
    let fixture = Fixture.attach(log: args[1])
    for (name, id) in [("A", fixture.a), ("B", fixture.b)] {
        guard let w = window(fixture, id), let wf = frame(w) else { fail("window \(name) not reachable") }
        var parts = ["\(name) window=\(id) size=\(Int(wf.width))x\(Int(wf.height))"]
        for identifier in ["text", "button", "scroll"] {
            guard let f = descendant(w, identifier: identifier).flatMap(frame) else { continue }
            parts.append("\(identifier)=\(Int(f.midX - wf.minX)),\(Int(f.midY - wf.minY))")
        }
        print(parts.joined(separator: " "))
    }
case "workbench":
    // workbench <pid> <windowA> <windowB> <results.jsonl>: VS Code pressable click and editor scroll.
    guard args.count == 5, let pid = pid_t(args[1]), let a = CGWindowID(args[2]), let b = CGWindowID(args[3]) else {
        fail("usage: InputProbe workbench <pid> <windowA> <windowB> <results.jsonl>")
    }
    runWorkbench(pid: pid, a: a, b: b, results: args[4])
case "workbench-discover":
    guard args.count == 3, let pid = pid_t(args[1]), let id = CGWindowID(args[2]) else { fail("usage: workbench-discover <pid> <window>") }
    discoverWorkbench(pid: pid, window: id)
case "pagestatus":
    // pagestatus <pid> <window>: the text page's status JSON (Scripts/bench/text.html).
    guard args.count == 3, let pid = pid_t(args[1]), let id = CGWindowID(args[2]) else { fail("usage: pagestatus <pid> <window>") }
    let fixture = Fixture(log: "/dev/null", pid: pid, a: id, b: id, app: AXUIElementCreateApplication(pid))
    guard let w = window(fixture, id), let status = pageStatus(w),
          let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) else { fail("no page status") }
    print(String(decoding: data, as: UTF8.self))
case "element":
    // element <pid> <window> <identifier>: "size=WxH at=x,y", the element's centre in
    // window-relative points (AXIdentifier or AXDOMIdentifier).
    guard args.count == 4, let pid = pid_t(args[1]), let id = CGWindowID(args[2]) else { fail("usage: element <pid> <window> <id>") }
    let app = AXUIElementCreateApplication(pid)
    if ProcessInfo.processInfo.environment["PROBE_ELECTRON"] == "1" { _ = enableManualAccessibility(app); wait(2) }
    let fixture = Fixture(log: "/dev/null", pid: pid, a: id, b: id, app: app)
    // Chromium publishes its tree some time after it is switched on; retry briefly.
    var found: (CGRect, CGRect)?
    for _ in 0..<10 {
        if let w = window(fixture, id), let wf = frame(w), let e = descendant(w, identifier: args[3]).flatMap(frame) {
            found = (wf, e); break
        }
        wait(1)
    }
    guard let (wf, e) = found else { fail("element \(args[3]) not found") }
    print("size=\(Int(wf.width))x\(Int(wf.height)) at=\(Int(e.midX - wf.minX)),\(Int(e.midY - wf.minY))")
case "textstate":
    // textstate <pid> <window>: "length caret" of the window's first text area, and "size=WxH text=x,y"
    // with the text area's centre in window-relative points.
    guard args.count == 3, let pid = pid_t(args[1]), let id = CGWindowID(args[2]) else { fail("usage: textstate <pid> <window>") }
    let fixture = Fixture(log: "/dev/null", pid: pid, a: id, b: id, app: AXUIElementCreateApplication(pid))
    guard let w = window(fixture, id), let wf = frame(w),
          let area = firstDescendant(w, role: kAXTextAreaRole as String), let af = frame(area) else { fail("no text area") }
    let text = attribute(area, kAXValueAttribute) as? String ?? ""
    let visibleTop = max(af.minY, wf.minY)
    print(text.count, caret(w), "size=\(Int(wf.width))x\(Int(wf.height)) text=\(Int(af.midX - wf.minX)),\(Int(min(visibleTop + 120, af.maxY) - wf.minY))")
case "windows":
    // windows <pid>: exact IDs of the app's windows on the active desktop, largest first.
    guard args.count == 2, let pid = pid_t(args[1]), let getWindow else { fail("usage: windows <pid>") }
    let list = attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    let ids = list.compactMap { element -> (CGWindowID, CGFloat)? in
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success, let extent = frame(element) else { return nil }
        return (id, extent.width * extent.height)
    }.sorted { $0.1 > $1.1 }.map { String($0.0) }
    print(ids.joined(separator: " "))
default:
    fail("usage: InputProbe matrix <fixture-log> <results.jsonl> [route,...]")
}
