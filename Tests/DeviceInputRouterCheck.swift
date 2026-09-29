import AppKit
import ApplicationServices
import DropyCore

/// Native router regressions against the disposable two-window input fixture only.
/// Invoked by interactive-checks.sh; never used with personal app windows.
@main
struct DeviceInputRouterChecks {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
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
        let beforeA = attribute(fieldA, kAXValueAttribute) as? String ?? ""
        let beforeB = attribute(fieldB, kAXValueAttribute) as? String ?? ""
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = PlacementJournal(url: root.appendingPathComponent("journal.json"))
        let trials = [FocusState.otherWindowKey, .appInactive].flatMap { focus in
            [InputTrial(route: .windowTargetedEvent, kind: .pointerClick, condition: .visible, focus: focus,
                        outcome: .pass, sideEffects: [.sourceKeyWindow]),
             InputTrial(route: .accessibility, kind: .text, condition: .visible, focus: focus,
                        outcome: .pass, sideEffects: [])]
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let evidence = InputEvidence(macOS: String(version), macOSMajor: version, sources: [
            .init(bundleIdentifier: "org.dropy.inputfixture", appVersion: nil, report: "test-only", trials: trials)
        ])
        let router = InputRouter(journal: journal, evidence: evidence)
        let point = CGPoint(x: textFrame.midX - windowFrame.minX, y: textFrame.midY - windowFrame.minY)
        let wrongSize = CGSize(width: windowFrame.width + 1, height: windowFrame.height)
        precondition(router.click(identity, at: point, expectedWindowSize: wrongSize) == .notApplicable("windowGeometryChanged"))
        precondition(router.type(identity, text: "must-not-send") == .notApplicable("accessibility:noTextElementChosen"),
                     "a rejected click must not choose a typing target")
        precondition(attribute(fieldA, kAXValueAttribute) as? String == beforeA)
        let pointerBefore = CGEvent(source: nil)?.location
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let spacesBefore = Spaces.current()
        precondition(router.click(identity, at: point, expectedWindowSize: windowFrame.size) == .sent(.windowTargetedEvent))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        precondition(CGEvent(source: nil)?.location == pointerBefore, "private input moved the hardware pointer")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore, "private input changed the frontmost app")
        precondition(Spaces.current() == spacesBefore, "private input changed desktops")
        app.hide()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        defer { app.unhide() }
        precondition(app.isHidden && router.condition(of: identity) == .hidden)
        precondition(router.type(identity, text: "must-not-send") == .refused(.notVerified))
        precondition(attribute(fieldA, kAXValueAttribute) as? String == beforeA)
        precondition(attribute(fieldB, kAXValueAttribute) as? String == beforeB)
        print("Native router regressions passed: resized click creates no text target; hidden input refused; decoy, pointer, app and desktop unchanged")
    }

    @MainActor private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    @MainActor private static func textField(_ root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 12 else { return nil }
        if attribute(root, kAXIdentifierAttribute) as? String == "text" { return root }
        for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let field = textField(child, depth: depth + 1) { return field }
        }
        return nil
    }
    @MainActor private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
