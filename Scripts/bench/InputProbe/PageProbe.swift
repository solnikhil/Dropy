// Text-semantics probe (M3): typing and clicks into a web page's fields in window A of a
// browser engine (the disposable Electron fixture or Safari) while window B shows the same
// page, judged entirely from each window's Accessibility tree. See Scripts/bench/text.html
// for the page contract and Scripts/text-probe.sh for the driver.
//
//   InputProbe page <pid> <windowA> <windowB> <results.jsonl> <electron|safari> [routes]
//
// A trial passes only when A's field holds exactly the expected text with the caret after
// the insertion, A's page saw an input event for that field, A's other fields and B's page
// are unchanged (B saw no key, mouse or input event), and nothing outside A changed: key
// window, frontmost app, desktop, pointer, held modifiers or buttons. Undo is measured after
// the trial and reported as a separate semantic, never folded into the pass.
import AppKit
import ApplicationServices

struct PageCase {
    let name: String
    let field: String
    let text: String
    let selection: (Int, Int)

    /// The field's text after typing replaces the selection.
    var expected: String {
        let units = Array(text.utf16)
        return String(decoding: units[..<selection.0], as: UTF16.self) + typedText
            + String(decoding: units[selection.1...], as: UTF16.self)
    }
    var expectedCaret: Int { selection.0 + typedText.utf16.count }
}

/// Mirrors `cases` in Scripts/bench/text.html.
let pageCases = [
    PageCase(name: "middle", field: "input", text: "alpha beta", selection: (5, 5)),
    PageCase(name: "select", field: "input", text: "alpha beta", selection: (6, 10)),
    PageCase(name: "multi", field: "area", text: "line one\nline two", selection: (14, 14)),
    PageCase(name: "edit", field: "edit", text: "hello world", selection: (5, 5)),
]

/// The page's own report, from its read-only status field.
func pageStatus(_ window: AXUIElement) -> [String: Any]? {
    guard let field = descendant(window, identifier: "t-status"),
          let text = attribute(field, kAXValueAttribute) as? String,
          let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
    return object
}

@discardableResult
func pressPage(_ window: AXUIElement, _ identifier: String) -> Bool {
    guard let button = descendant(window, identifier: identifier) else { return false }
    return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
}

func windowID(_ element: AXUIElement?) -> CGWindowID {
    var id: CGWindowID = 0
    if let element { _ = getWindow?(element, &id) }
    return id
}

/// Desktops holding a window, from the window server (independent of the app).
func spacesOf(_ window: CGWindowID) -> [UInt64] {
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    let handle = UnsafeMutableRawPointer(bitPattern: -2)
    guard let main = dlsym(handle, "CGSMainConnectionID"), let copy = dlsym(handle, "CGSCopySpacesForWindows") else { return [] }
    let connection = unsafeBitCast(main, to: MainConnection.self)()
    let list = unsafeBitCast(copy, to: CopySpaces.self)(connection, 0x7, [NSNumber(value: window)] as CFArray)?
        .takeRetainedValue() as? [NSNumber] ?? []
    return list.map(\.uint64Value)
}

func runPage(pid: pid_t, a idA: CGWindowID, b idB: CGWindowID, results path: String, engine: String, routes: [Route]) {
    let fixture = Fixture(log: "/dev/null", pid: pid, a: idA, b: idB, app: AXUIElementCreateApplication(pid))
    if engine == "electron" {
        _ = enableManualAccessibility(fixture.app)
        wait(2.0) // Chromium builds its tree asynchronously
    }
    guard let a = window(fixture, idA), let b = window(fixture, idB), let homeA = frame(a), let homeB = frame(b) else {
        fail("windows not reachable")
    }
    for w in [a, b] { pressPage(w, "t-reset") }
    wait(0.5)
    guard pageStatus(a) != nil, pageStatus(b) != nil else { fail("page status not readable through Accessibility") }
    FileManager.default.createFile(atPath: path, contents: nil)
    let output = FileHandle(forWritingAtPath: path)!
    let frontmost = NSWorkspace.shared.frontmostApplication
    prepareFocusSink()
    var conditions: [(Condition, Focus)] = [(.visible, .aKey)]
    for condition in [Condition.visible, .covered, .parked, .otherSpace, .minimized] {
        for focus in [Focus.bKey, .appInactive] { conditions.append((condition, focus)) }
    }
    // Every text route for every case, then the click routes once per condition.
    var plan: [(Route, Action, PageCase?)] = []
    for route in routes where route != .activate {
        for pageCase in pageCases { plan.append((route, .type, pageCase)) }
    }
    for route in routes where [.ax, .pidWindow].contains(route) { plan.append((route, .click, nil)) }
    var tally: [String: Int] = [:]

    for (condition, focus) in conditions {
        for (route, action, pageCase) in plan {
            var record: [String: Any] = ["engine": engine, "condition": condition.rawValue, "focus": focus.rawValue,
                                         "route": route.rawValue, "action": action.rawValue,
                                         "sideEffectsRecorded": true, "probeVersion": 4]
            if let pageCase { record["case"] = pageCase.name }
            if engine == "electron" { record["axManualAccessibility"] = true }
            var pointerBefore = pointerLocation()
            let setup = setUpPage(condition, focus, pageCase: pageCase, fixture: fixture, a: a, b: b, home: (homeA, homeB),
                                  engine: engine)
            if let setup {
                record["outcome"] = "notRun(\(setup))"
            } else if let beforeA = pageStatus(a), let beforeB = pageStatus(b) {
                let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let keyBefore = windowID(element(attribute(fixture.app, kAXFocusedWindowAttribute)))
                let spaceBefore = activeSpaces()
                pointerBefore = pointerLocation()
                let error = performPage(route, action, pageCase: pageCase, window: a, fixture: fixture)
                if let error { record["actionError"] = error }
                wait(0.8)
                let afterA = pageStatus(a) ?? [:], afterB = pageStatus(b) ?? [:]
                record["outcome"] = judgePage(action, pageCase: pageCase, beforeA: beforeA, afterA: afterA,
                                              beforeB: beforeB, afterB: afterB, error: error, record: &record)
                if windowID(element(attribute(fixture.app, kAXFocusedWindowAttribute))) != keyBefore {
                    record["keyWindowChanged"] = true
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != frontBefore { record["frontmostChanged"] = true }
                if activeSpaces() != spaceBefore { record["desktopChanged"] = "\(spaceBefore)→\(activeSpaces())" }
                recordSessionState(&record, pointerBefore: pointerBefore)
                let sideEffects = ["keyWindowChanged", "frontmostChanged", "desktopChanged", "pointerMoved"].filter { record[$0] != nil }
                if !sideEffects.isEmpty, record["outcome"] as? String == "pass" {
                    record["outcome"] = "sideEffect(\(sideEffects.joined(separator: ",")))"
                }
                // Undo, measured after the trial: does the page's own undo take the edit back?
                if action == .type, let pageCase, (afterA[pageCase.field] as? String) != pageCase.text {
                    pressPage(a, "t-undo")
                    wait(0.5)
                    record["undo"] = pageStatus(a)?["undo"] ?? NSNull()
                }
            } else {
                record["outcome"] = "noState"
            }
            if releaseModifiers() {
                record["modifiersLeftHeld"] = true
                if !(record["outcome"] as? String ?? "").hasPrefix("wrongWindow") { record["outcome"] = "unsafeSessionState" }
            }
            // A hidden or other-desktop page may not publish Accessibility updates until it is
            // shown again. Read A once more after restoring it, before the reset, so a late
            // effect is recorded instead of being mistaken for none.
            if let late = tearDownPage(fixture: fixture, a: a, b: b, home: (homeA, homeB), engine: engine),
               [.minimized, .otherSpace].contains(condition) {
                record["afterRestoreA"] = ["presses": late["presses"] ?? 0,
                                           "value": pageCase.flatMap { late[$0.field] } ?? NSNull()]
            }
            let outcome = record["outcome"] as? String ?? "?"
            tally[outcome.components(separatedBy: "(").first ?? outcome, default: 0] += 1
            let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            output.write(data + Data("\n".utf8))
            print(condition.rawValue, focus.rawValue, route.rawValue, action.rawValue, pageCase?.name ?? "-", outcome)
            fflush(stdout)
        }
    }
    releaseModifiers()
    frontmost?.activate()
    print("tally", tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
}

/// Prepares both pages, then the focus state and the source condition; verifies both.
func setUpPage(_ condition: Condition, _ focus: Focus, pageCase: PageCase?, fixture: Fixture, a: AXUIElement, b: AXUIElement,
               home: (CGRect, CGRect), engine: String) -> String? {
    if let pageCase {
        guard pressPage(a, "case-\(pageCase.name)"), pressPage(b, "case-\(pageCase.name)") else { return "prepareFailed" }
        wait(0.3)
    }
    makeFrontmost(fixture.pid)
    let key = focus == .aKey ? a : b
    setBool(key, kAXMainAttribute, true)
    AXUIElementPerformAction(key, kAXRaiseAction as CFString)
    wait(0.5)
    if focus == .aKey, let pageCase, let field = descendant(a, identifier: "t-\(pageCase.field)") {
        // Control only: a person's caret in A's field while A is key.
        setBool(field, kAXFocusedAttribute, true)
        var range = CFRange(location: pageCase.selection.0, length: pageCase.selection.1 - pageCase.selection.0)
        AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &range)!)
        wait(0.3)
    }
    switch condition {
    case .visible: break
    case .covered:
        setPosition(b, home.0.origin)
        AXUIElementPerformAction(b, kAXRaiseAction as CFString)
    case .parked:
        let right = displays().map(\.maxX).max() ?? 0, bottom = displays().map(\.maxY).max() ?? 0
        setPosition(a, CGPoint(x: right + 200, y: bottom + 200))
    case .minimized:
        setBool(a, kAXMinimizedAttribute, true)
        wait(0.8)
    case .otherSpace:
        guard engine == "electron", commandFile != nil else { return "otherSpaceNeedsOwnWindowMove" }
        sendCommand("space:other")
        wait(1.0)
    }
    if focus == .appInactive { makeOtherAppFrontmost() }
    wait(0.4)
    // Verify rather than assume.
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let focused = windowID(element(attribute(fixture.app, kAXFocusedWindowAttribute)))
    switch focus {
    case .aKey: guard front == fixture.pid, focused == fixture.a else { return "setupFocusMismatch" }
    case .bKey: guard front == fixture.pid, focused == fixture.b else { return "setupFocusMismatch" }
    case .appInactive: guard front != fixture.pid else { return "setupFocusMismatch" }
    }
    switch condition {
    case .visible: break
    case .covered: guard frame(b)?.origin == home.0.origin else { return "setupCoverFailed" }
    case .parked: guard let extent = frame(a), isParked(extent) else { return "setupParkingFailed" }
    case .minimized: guard attribute(a, kAXMinimizedAttribute) as? Bool == true else { return "setupMinimizeFailed" }
    case .otherSpace:
        let active = Set(activeSpaces().split(separator: ",").compactMap { UInt64($0) })
        let source = Set(spacesOf(fixture.a))
        guard !active.isEmpty, !source.isEmpty, active.isDisjoint(with: source) else { return "setupSpaceFailed" }
    }
    if let pageCase {
        guard pageStatus(a)?["case"] as? String == pageCase.name, pageStatus(b)?["case"] as? String == pageCase.name else {
            return "prepareNotReflected"
        }
    }
    return nil
}

/// Restores both windows and resets both pages; returns A's status just before the reset.
@discardableResult
func tearDownPage(fixture: Fixture, a: AXUIElement, b: AXUIElement, home: (CGRect, CGRect), engine: String) -> [String: Any]? {
    if engine == "electron", commandFile != nil { sendCommand("space:home"); wait(0.6) }
    if attribute(a, kAXMinimizedAttribute) as? Bool == true { setBool(a, kAXMinimizedAttribute, false); wait(0.8) }
    setPosition(a, home.0.origin)
    setPosition(b, home.1.origin)
    wait(0.4)
    let status = pageStatus(a)
    for w in [a, b] { pressPage(w, "t-reset") }
    wait(0.3)
    return status
}

func performPage(_ route: Route, _ action: Action, pageCase: PageCase?, window a: AXUIElement, fixture: Fixture) -> String? {
    if action == .click {
        guard let button = descendant(a, identifier: "t-button"), let target = frame(button), let origin = frame(a)?.origin else {
            return "elementNotFound"
        }
        switch route {
        case .ax:
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            return result == .success ? nil : "axError(\(result.rawValue))"
        case .pidWindow:
            let point = CGPoint(x: target.midX, y: target.midY)
            return postToWindow(clickEvents(at: point), fixture: fixture, local: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        default: return "notApplicable(route)"
        }
    }
    guard let pageCase, let field = descendant(a, identifier: "t-\(pageCase.field)") else { return "elementNotFound" }
    switch route {
    case .ax:
        let result = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, typedText as CFString)
        return result == .success ? nil : "axError(\(result.rawValue))"
    case .axValue: return spliceValue(field, typedText)
    case .axFocus: return focusThenInsert(field, typedText)
    case .pidWindow, .pid:
        let origin = frame(a)?.origin ?? .zero
        let centre = frame(field).map { CGPoint(x: $0.midX, y: $0.midY) } ?? origin
        if route == .pid { for event in keyEvents(typedText) { event.postToPid(fixture.pid); wait(0.03) }; return nil }
        return postToWindow(keyEvents(typedText), fixture: fixture, local: CGPoint(x: centre.x - origin.x, y: centre.y - origin.y))
    case .activate: return "notApplicable(route)"
    }
}

func postToWindow(_ events: [CGEvent], fixture: Fixture, local: CGPoint) -> String? {
    guard let setWindowLocation else { return "notApplicable(noSetWindowLocation)" }
    for event in events {
        event.setIntegerValueField(eventWindow, value: Int64(fixture.a))
        event.setIntegerValueField(windowUnderPointer, value: Int64(fixture.a))
        event.setIntegerValueField(windowThatCanHandle, value: Int64(fixture.a))
        setWindowLocation(event, local)
        event.postToPid(fixture.pid)
        wait(0.03)
    }
    return nil
}

/// Counts of input-carrying events in a page status (keys, mouse, field edits).
func inputEventCount(_ status: [String: Any]) -> Int {
    (status["events"] as? [String: Int] ?? [:]).filter { key, _ in
        key == "keydown" || key == "mousedown" || key.hasSuffix(".input") || key.hasSuffix(".beforeinput")
    }.values.reduce(0, +)
}

func judgePage(_ action: Action, pageCase: PageCase?, beforeA: [String: Any], afterA: [String: Any],
               beforeB: [String: Any], afterB: [String: Any], error: String?, record: inout [String: Any]) -> String {
    let fieldsChangedB = ["input", "area", "edit"].filter { (beforeB[$0] as? String) != (afterB[$0] as? String) }
    let pressesB = (afterB["presses"] as? Int ?? 0) - (beforeB["presses"] as? Int ?? 0)
    record["decoyEvents"] = inputEventCount(afterB) - inputEventCount(beforeB)
    if !fieldsChangedB.isEmpty || pressesB > 0 { return "wrongWindow" }
    if inputEventCount(afterB) > inputEventCount(beforeB) { return "wrongWindow(delivered)" }
    if action == .click {
        let presses = (afterA["presses"] as? Int ?? 0) - (beforeA["presses"] as? Int ?? 0)
        if let error { return error.hasPrefix("notApplicable") ? error : "notSent(\(error))" }
        return presses == 1 ? "pass" : presses == 0 ? "noEffect" : "partialEffect(presses=\(presses))"
    }
    guard let pageCase else { return "noState" }
    let value = afterA[pageCase.field] as? String ?? ""
    record["valueA"] = value
    record["selA"] = afterA["sel"] ?? NSNull()
    let events = afterA["events"] as? [String: Int] ?? [:]
    record["eventsA"] = events
    let others = ["input", "area", "edit"].filter { $0 != pageCase.field && (beforeA[$0] as? String) != (afterA[$0] as? String) }
    if !others.isEmpty { return "partialEffect(otherField)" }
    if value == pageCase.text {
        if let error { return error.hasPrefix("notApplicable") ? error : "notSent(\(error))" }
        return "noEffect"
    }
    guard value == pageCase.expected else { return "partialEffect(value)" }
    let selection = (afterA["sel"] as? [Int]) ?? []
    guard selection == [pageCase.expectedCaret, pageCase.expectedCaret] else { return "partialEffect(caret)" }
    guard (events["\(pageCase.field).input"] ?? 0) > 0 else { return "partialEffect(noInputEvent)" }
    return "pass"
}

/// Markdown table: one row per route × action × case, one column per condition/focus.
func pageReport(_ path: String) {
    let records = Fixture.lines(path)
    var columns: [String] = []
    var rows: [String] = []
    for record in records {
        let column = "\(record["condition"] ?? "")/\(record["focus"] ?? "")"
        if !columns.contains(column) { columns.append(column) }
        let row = "\(record["route"] ?? "") | \(record["action"] ?? "") | \(record["case"] ?? "-")"
        if !rows.contains(row) { rows.append(row) }
    }
    print("| Route | Action | Case | " + columns.joined(separator: " | ") + " |")
    print("|---|---|---|" + columns.map { _ in "---" }.joined(separator: "|") + "|")
    for row in rows {
        let cells = columns.map { column -> String in
            guard let record = records.first(where: {
                "\($0["route"] ?? "") | \($0["action"] ?? "") | \($0["case"] ?? "-")" == row
                    && "\($0["condition"] ?? "")/\($0["focus"] ?? "")" == column }) else { return "-" }
            var cell = record["outcome"] as? String ?? "?"
            if cell.hasPrefix("wrongWindow") { cell = "**\(cell)**" }
            if let undo = record["undo"] as? [String: Any] {
                cell += (undo["restored"] as? Bool == true) ? " (undo ok)" : " (undo fails)"
            }
            if record["modifiersLeftHeld"] != nil || record["buttonsLeftHeld"] != nil { cell += " (HELD)" }
            if let late = record["afterRestoreA"] as? [String: Any], (late["presses"] as? Int ?? 0) > 0,
               record["action"] as? String == "click", cell == "noEffect" {
                cell += " (pressed; seen after restore)"
            }
            return cell
        }
        print("| \(row) | " + cells.joined(separator: " | ") + " |")
    }
}
