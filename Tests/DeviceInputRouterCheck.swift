import AppKit
import ApplicationServices
import DropyCore

/// Native router regressions against the disposable two-window input fixture only.
/// Invoked by interactive-checks.sh; never used with personal app windows.
///
///   DeviceInputRouterChecks <pid> <windowA> <windowB>
///       geometry, stale text target, source switching and hidden-source checks; prints
///       `old-identity <pid> <launch-epoch> <windowA>` for the relaunch check
///   DeviceInputRouterChecks relaunched <old-pid> <old-launch-epoch> <old-windowA> <new-pid>
///       after the fixture quit and relaunched: the old identity must be refused and
///       the new instance left untouched
///
/// Every check sends through `InputRouter` exactly as the preview does and judges the
/// result from both windows' Accessibility state, plus the pointer, frontmost app and
/// desktop, which must never change.
@main
struct DeviceInputRouterChecks {
    nonisolated(unsafe) static var failures: [String] = []

    @MainActor static func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition { print("PASS \(name)") } else {
            let message = "FAIL \(name) \(detail())"
            print(message)
            failures.append(message)
        }
    }

    @MainActor static func main() throws {
        let args = CommandLine.arguments
        if args.count == 6, args[1] == "relaunched" { try relaunched(args); return }
        guard args.count == 4, let pid = Int32(args[1]), let aID = UInt32(args[2]), let bID = UInt32(args[3]),
              let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "org.dropy.inputfixture",
              let launchDate = app.launchDate else { fatalError("disposable input fixture required") }
        let identity = WindowIdentity(processID: pid, processLaunchDate: launchDate, windowID: aID,
                                      bundleIdentifier: app.bundleIdentifier)
        let decoy = WindowIdentity(processID: pid, processLaunchDate: launchDate, windowID: bID,
                                   bundleIdentifier: app.bundleIdentifier)
        guard case .found(let a) = try WindowPlacer.find(identity),
              case .found(let b) = try WindowPlacer.find(decoy), let fieldA = textField(a), let fieldB = textField(b),
              let windowFrame = frame(a), let textFrame = frame(fieldA) else { fatalError("fixture controls missing") }
        let beforeA = value(fieldA)
        let beforeB = value(fieldB)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = InputRouter(journal: PlacementJournal(url: root.appendingPathComponent("journal.json")),
                                 evidence: testEvidence())
        let point = CGPoint(x: textFrame.midX - windowFrame.minX, y: textFrame.midY - windowFrame.minY)
        let pointerBefore = CGEvent(source: nil)?.location
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let spacesBefore = Spaces.current()

        // 1. Geometry: a click mapped for another window size is refused and chooses no text target.
        let wrongSize = CGSize(width: windowFrame.width + 1.5, height: windowFrame.height)
        check(router.click(identity, at: point, expectedWindowSize: wrongSize) == .notApplicable("windowGeometryChanged"),
              "click mapped for a stale size is refused")
        check(router.type(identity, text: "must-not-send") == .notApplicable("accessibility:noTextElementChosen"),
              "a refused click chooses no typing target")

        // 2. A real resize of the source between mapping and sending.
        setSize(a, CGSize(width: windowFrame.width + 40, height: windowFrame.height))
        settle(0.4)
        let resized = frame(a)?.size
        check(resized?.width == windowFrame.width + 40, "source resized for the check", "size=\(String(describing: resized))")
        check(router.click(identity, at: point, expectedWindowSize: windowFrame.size) == .notApplicable("windowGeometryChanged"),
              "click during a source resize is refused")
        check(router.scroll(identity, at: point, delta: CGSize(width: 0, height: -40), expectedWindowSize: windowFrame.size)
              == .notApplicable("windowGeometryChanged"), "scroll during a source resize is refused")
        setSize(a, windowFrame.size)
        settle(0.4)
        check(frame(a)?.size == windowFrame.size, "source size restored")

        // 3. A current click chooses A's field; typing lands in A only.
        check(router.click(identity, at: point, expectedWindowSize: windowFrame.size) == .sent(.windowTargetedEvent),
              "click at the current size is sent")
        settle(0.3)
        check(router.type(identity, text: "q") == .sent(.accessibility), "typing after the click is sent")
        settle(0.3)
        check(value(fieldA) == beforeA + "q" && value(fieldB) == beforeB, "typing reached A only",
              "A=\(value(fieldA)) B=\(value(fieldB))")

        // 4. Switching sources: B has no typing target of its own, and forgetting A (what
        //    the overlay does on every switch) drops A's.
        check(router.type(decoy, text: "must-not-send") == .notApplicable("accessibility:noTextElementChosen"),
              "switching to B does not reuse A's typing target")
        for _ in 0..<25 {
            router.forget(identity)
            _ = router.type(decoy, text: "x")
        }
        check(router.type(identity, text: "must-not-send") == .notApplicable("accessibility:noTextElementChosen"),
              "rapid switching leaves no typing target behind")
        check(value(fieldA) == beforeA + "q" && value(fieldB) == beforeB, "rapid switching sent nothing")

        // 5. A stale text target: the field A's typing target points at is replaced.
        _ = router.click(identity, at: point, expectedWindowSize: windowFrame.size)
        settle(0.3)
        DistributedNotificationCenter.default().postNotificationName(
            .init("org.dropy.inputfixture.command"), object: "rebuild:A", userInfo: nil, deliverImmediately: true)
        settle(0.6)
        let staleOutcome = router.type(identity, text: "must-not-send")
        check(staleOutcome == .notApplicable("accessibility:textElementGone") ||
              { if case .notApplicable(let reason) = staleOutcome { return reason.contains("axError") } else { return false } }(),
              "typing into a replaced field is refused", "\(staleOutcome)")
        let rebuiltA = textField(a)
        check(rebuiltA.map(value) == beforeA + "q" && value(fieldB) == beforeB, "stale target sent nothing",
              "A=\(rebuiltA.map(value) ?? "?") B=\(value(fieldB))")
        check(router.type(identity, text: "must-not-send") == .notApplicable("accessibility:noTextElementChosen"),
              "a stale target is dropped, not retried")

        // Sending never moved the pointer, switched the frontmost app or changed desktops.
        check(CGEvent(source: nil)?.location == pointerBefore, "pointer never moved")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore, "frontmost app unchanged")
        check(Spaces.current() == spacesBefore, "desktop unchanged")

        // 6. Hidden source: not verified, refused. (Hiding is the check's own action.)
        let front = NSWorkspace.shared.frontmostApplication
        app.hide()
        settle(0.4)
        check(app.isHidden && router.condition(of: identity) == .hidden, "source hidden for the check")
        check(router.type(identity, text: "must-not-send") == .refused(.notVerified), "input to a hidden source is refused")
        app.unhide()
        front?.activate()
        settle(0.4)
        // Undo the one character the check typed.
        if let field = textField(a) { AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, beforeA as CFString) }
        print("old-identity \(pid) \(launchDate.timeIntervalSince1970) \(aID)")
        finish()
    }

    /// After quit and relaunch, the old identity (same window ID) must not reach the new process.
    @MainActor static func relaunched(_ args: [String]) throws {
        guard let oldPID = Int32(args[2]), let epoch = Double(args[3]), let oldA = UInt32(args[4]),
              let newPID = Int32(args[5]), let app = NSRunningApplication(processIdentifier: newPID),
              app.bundleIdentifier == "org.dropy.inputfixture", let newLaunch = app.launchDate else {
            fatalError("disposable input fixture required")
        }
        let old = WindowIdentity(processID: oldPID, processLaunchDate: Date(timeIntervalSince1970: epoch), windowID: oldA,
                                 bundleIdentifier: "org.dropy.inputfixture")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = InputRouter(journal: PlacementJournal(url: root.appendingPathComponent("journal.json")),
                                 evidence: testEvidence())
        let newWindows = (attribute(AXUIElementCreateApplication(newPID), kAXWindowsAttribute) as? [AXUIElement] ?? [])
        let before = newWindows.compactMap(textField).map(value)
        for outcome in [router.click(old, at: CGPoint(x: 40, y: 40)), router.scroll(old, at: CGPoint(x: 40, y: 200),
                                                                                     delta: CGSize(width: 0, height: -40)),
                        router.type(old, text: "must-not-send")] {
            guard case .refused(.targetUnreachable) = outcome else {
                check(false, "old identity refused after relaunch", "\(outcome)")
                continue
            }
            check(true, "old identity refused after relaunch")
        }
        // The same window number under the new process is a different identity, and it
        // has no typing target inherited from the old one.
        let reused = WindowIdentity(processID: newPID, processLaunchDate: newLaunch, windowID: oldA,
                                    bundleIdentifier: "org.dropy.inputfixture")
        let outcome = router.type(reused, text: "must-not-send")
        check(outcome != .sent(.accessibility), "no typing target survives a relaunch", "\(outcome)")
        settle(0.3)
        check(newWindows.compactMap(textField).map(value) == before, "relaunched instance untouched")
        finish()
    }

    @MainActor static func finish() {
        guard failures.isEmpty else {
            print("Native router regressions FAILED: \(failures.count)")
            exit(1)
        }
        print("Native router regressions passed")
    }

    /// Evidence as the shipped fixture evidence says: window-targeted clicks and scrolls,
    /// Accessibility text, visible only.
    @MainActor static func testEvidence() -> InputEvidence {
        let trials = [FocusState.otherWindowKey, .appInactive].flatMap { focus in
            [InputTrial(route: .windowTargetedEvent, kind: .pointerClick, condition: .visible, focus: focus,
                        outcome: .pass, sideEffects: [.sourceKeyWindow]),
             InputTrial(route: .windowTargetedEvent, kind: .scroll, condition: .visible, focus: focus,
                        outcome: .pass, sideEffects: []),
             InputTrial(route: .accessibility, kind: .text, condition: .visible, focus: focus,
                        outcome: .pass, sideEffects: [])]
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return InputEvidence(macOS: String(version), macOSMajor: version, sources: [
            .init(bundleIdentifier: "org.dropy.inputfixture", appVersion: nil, report: "test-only", trials: trials)
        ])
    }

    @MainActor static func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    @MainActor private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    @MainActor private static func value(_ element: AXUIElement) -> String { attribute(element, kAXValueAttribute) as? String ?? "" }
    @MainActor private static func textField(_ root: AXUIElement) -> AXUIElement? { textField(root, depth: 0) }
    @MainActor private static func textField(_ root: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }
        if attribute(root, kAXIdentifierAttribute) as? String == "text" { return root }
        for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let field = textField(child, depth: depth + 1) { return field }
        }
        return nil
    }
    @MainActor private static func setSize(_ element: AXUIElement, _ size: CGSize) {
        var size = size
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    }
    @MainActor private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
