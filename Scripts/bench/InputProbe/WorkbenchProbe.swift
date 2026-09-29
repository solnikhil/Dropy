// VS Code workbench probe (M3): a pressable control and editor scrolling in window A of a
// scratch VS Code while window B is open on another scratch file, judged from each
// window's own Accessibility state. Complements `InputProbe app` (caret clicks, typing).
//
//   InputProbe workbench <pid> <windowA> <windowB> <results.jsonl>
//   InputProbe workbench-discover <pid> <window>     prints what the probe would judge
//
// Click target: the activity-bar "Explorer" item, whose selected state toggles (the
// side bar opens or closes); judged from that item's state in A and in B, and pressed
// again afterwards to restore it. Scroll target: the editor; judged from the first line
// number visible in the editor's gutter (AXStaticText elements holding only digits).
import AppKit
import ApplicationServices

/// The Explorer activity item: a pressable element described or titled "Explorer…".
func explorerItem(_ window: AXUIElement) -> AXUIElement? {
    var found: AXUIElement?
    var budget = 6000
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard found == nil, depth < 45, budget > 0 else { return }
        budget -= 1
        let label = (attribute(element, kAXDescriptionAttribute) as? String ?? "") + " "
            + (attribute(element, kAXTitleAttribute) as? String ?? "")
        if label.trimmingCharacters(in: .whitespaces).hasPrefix("Explorer") {
            var names: CFArray?
            AXUIElementCopyActionNames(element, &names)
            if (names as? [String] ?? []).contains(kAXPressAction as String) { found = element; return }
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(window, 0)
    return found
}

/// A toggle's state as the app reports it: selected, value or expanded, whichever exists.
func toggleState(_ element: AXUIElement) -> String {
    for name in [kAXSelectedAttribute as String, kAXValueAttribute as String, kAXExpandedAttribute as String] {
        if let value = attribute(element, name) { return "\(name)=\(value)" }
    }
    return "none"
}

/// The smallest line number shown in the editor gutter of this window, or nil.
func firstVisibleLine(_ window: AXUIElement) -> Int? {
    guard let area = firstDescendant(window, role: kAXTextAreaRole as String), let editor = frame(area) else { return nil }
    var numbers: [Int] = []
    var budget = 8000
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard depth < 45, budget > 0 else { return }
        budget -= 1
        if attribute(element, kAXRoleAttribute) as? String == kAXStaticTextRole as String,
           let text = attribute(element, kAXValueAttribute) as? String, let number = Int(text),
           let extent = frame(element), extent.minY >= editor.minY - 400, extent.maxY <= editor.maxY + 400 {
            numbers.append(number)
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(window, 0)
    return numbers.min()
}

func runWorkbench(pid: pid_t, a idA: CGWindowID, b idB: CGWindowID, results path: String) {
    let fixture = Fixture(log: "/dev/null", pid: pid, a: idA, b: idB, app: AXUIElementCreateApplication(pid))
    _ = enableManualAccessibility(fixture.app)
    wait(3.0)
    guard let a = window(fixture, idA), let b = window(fixture, idB), let homeA = frame(a), let homeB = frame(b) else {
        fail("windows not reachable")
    }
    FileManager.default.createFile(atPath: path, contents: nil)
    let output = FileHandle(forWritingAtPath: path)!
    let frontmost = NSWorkspace.shared.frontmostApplication
    prepareFocusSink()
    for condition in [Condition.visible, .covered, .parked, .minimized] {
        for focus in [Focus.bKey, .appInactive] {
            for (route, action) in [(Route.ax, Action.click), (.pidWindow, .click), (.pidWindow, .scroll)] {
                var record: [String: Any] = ["condition": condition.rawValue, "focus": focus.rawValue, "route": route.rawValue,
                                             "action": action.rawValue, "target": action == .click ? "pressable" : "other",
                                             "sideEffectsRecorded": true, "probeVersion": 4, "axManualAccessibility": true]
                makeFrontmost(pid)
                setBool(b, kAXMainAttribute, true)
                AXUIElementPerformAction(b, kAXRaiseAction as CFString)
                wait(0.5)
                switch condition {
                case .parked:
                    let right = displays().map(\.maxX).max() ?? 0, bottom = displays().map(\.maxY).max() ?? 0
                    setPosition(a, CGPoint(x: right + 200, y: bottom + 200))
                case .covered: setPosition(b, homeA.origin); AXUIElementPerformAction(b, kAXRaiseAction as CFString)
                case .minimized: setBool(a, kAXMinimizedAttribute, true); wait(0.8)
                default: break
                }
                if focus == .appInactive { makeOtherAppFrontmost() }
                wait(0.4)
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let focused = windowID(element(attribute(fixture.app, kAXFocusedWindowAttribute)))
                var setup: String?
                if focus == .bKey, front != pid || focused != idB { setup = "setupFocusMismatch" }
                if focus == .appInactive, front == pid { setup = "setupFocusMismatch" }
                if condition == .parked, frame(a).map(isParked) != true { setup = "setupParkingFailed" }
                if condition == .minimized, attribute(a, kAXMinimizedAttribute) as? Bool != true { setup = "setupMinimizeFailed" }
                if condition == .covered, frame(b)?.origin != homeA.origin { setup = "setupCoverFailed" }
                let itemA = explorerItem(a), itemB = explorerItem(b)
                let pointerBefore = pointerLocation()
                let spaceBefore = activeSpaces()
                if let setup {
                    record["outcome"] = "notRun(\(setup))"
                } else if action == .click, let itemA, let itemB {
                    let beforeA = toggleState(itemA), beforeB = toggleState(itemB)
                    var error: String?
                    if route == .ax {
                        let result = AXUIElementPerformAction(itemA, kAXPressAction as CFString)
                        if result != .success { error = "axError(\(result.rawValue))" }
                    } else if let target = frame(itemA), let origin = frame(a)?.origin {
                        let point = CGPoint(x: target.midX, y: target.midY)
                        error = postToWindow(clickEvents(at: point), fixture: fixture,
                                             local: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
                    }
                    wait(0.8)
                    let afterA = toggleState(itemA), afterB = toggleState(itemB)
                    record["stateA"] = [beforeA, afterA]
                    record["stateB"] = [beforeB, afterB]
                    record["outcome"] = judge(inA: afterA != beforeA, inB: afterB != beforeB, receivedBy: [:], actionError: error)
                    if afterA != beforeA { AXUIElementPerformAction(itemA, kAXPressAction as CFString); wait(0.5) }
                    if afterB != beforeB { AXUIElementPerformAction(itemB, kAXPressAction as CFString); wait(0.5) }
                } else if action == .scroll, let area = firstDescendant(a, role: kAXTextAreaRole as String), let target = frame(area),
                          let origin = frame(a)?.origin {
                    let beforeA = firstVisibleLine(a), beforeB = firstVisibleLine(b)
                    let point = CGPoint(x: target.midX, y: target.minY + min(200, target.height / 2))
                    let error = postToWindow(scrollEvents(at: point), fixture: fixture,
                                             local: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
                    wait(0.8)
                    let afterA = firstVisibleLine(a), afterB = firstVisibleLine(b)
                    record["lineA"] = [beforeA ?? -1, afterA ?? -1]
                    record["lineB"] = [beforeB ?? -1, afterB ?? -1]
                    if beforeA == nil || beforeB == nil {
                        record["outcome"] = "notRun(noGutterLines)"
                    } else {
                        record["outcome"] = judge(inA: afterA != beforeA, inB: afterB != beforeB, receivedBy: [:], actionError: error)
                    }
                } else {
                    record["outcome"] = "notRun(elementNotFound)"
                }
                if windowID(element(attribute(fixture.app, kAXFocusedWindowAttribute))) != focused { record["keyWindowChanged"] = true }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != front { record["frontmostChanged"] = true }
                if activeSpaces() != spaceBefore { record["desktopChanged"] = "\(spaceBefore)→\(activeSpaces())" }
                recordSessionState(&record, pointerBefore: pointerBefore)
                if attribute(a, kAXMinimizedAttribute) as? Bool == true { setBool(a, kAXMinimizedAttribute, false); wait(0.8) }
                setPosition(a, homeA.origin)
                setPosition(b, homeB.origin)
                wait(0.3)
                let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                output.write(data + Data("\n".utf8))
                print(condition.rawValue, focus.rawValue, route.rawValue, action.rawValue, record["outcome"] ?? "?")
                fflush(stdout)
            }
        }
    }
    releaseModifiers()
    frontmost?.activate()
}

func discoverWorkbench(pid: pid_t, window id: CGWindowID) {
    let fixture = Fixture(log: "/dev/null", pid: pid, a: id, b: id, app: AXUIElementCreateApplication(pid))
    _ = enableManualAccessibility(fixture.app)
    wait(3.0)
    guard let w = window(fixture, id) else { fail("window not reachable") }
    print("explorer:", explorerItem(w).map { toggleState($0) } ?? "not found")
    print("firstVisibleLine:", firstVisibleLine(w).map(String.init) ?? "not found")
}
