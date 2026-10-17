import AppKit
import ApplicationServices

nonisolated(unsafe) var inputInterrupted: Int32 = 0

func emit(_ value: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
}
func fail(_ reason: String) -> Never { emit(["error": reason]); exit(2) }
func checkPrompt() -> Bool {
    let owners: Set<String> = ["UserNotificationCenter", "SecurityAgent", "universalAccessAuthWarn", "CoreServicesUIAgent", "tccd", "coreautha"]
    return !(CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).contains {
        owners.contains($0[kCGWindowOwnerName as String] as? String ?? "")
    }
}
func focusedWindow(_ pid: pid_t) -> Int? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    typealias WindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    var id: CGWindowID = 0
    guard unsafeBitCast(symbol, to: WindowID.self)(value as! AXUIElement, &id) == .success else { return nil }
    return Int(id)
}
let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "process":
    guard args.count == 3 else { fail("process bundle-id executable-path") }
    emit(NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).filter {
        $0.executableURL?.standardizedFileURL.path == URL(fileURLWithPath: args[2]).standardizedFileURL.path
    }.map { Int($0.processIdentifier) })
case "environment":
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    emit(["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(),
          "sessionKnown": session != nil,
          "locked": session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
          "console": session?["kCGSSessionOnConsoleKey"] as? Bool ?? false,
          "promptsClear": checkPrompt(), "thermal": ProcessInfo.processInfo.thermalState.rawValue,
          "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
          "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
          "fixtureAlreadyRunning": ["org.dropy.benchmarkfixture", "org.dropy.benchmarkbackdrop"].contains {
              !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
          },
          "displays": NSScreen.screens.map { screen in
              ["id": screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber ?? 0,
               "width": screen.frame.width, "height": screen.frame.height, "x": screen.frame.minX, "y": screen.frame.minY,
               "scale": screen.backingScaleFactor, "hz": screen.maximumFramesPerSecond] as [String: Any]
          }])
case "command":
    guard args.count == 4 else { fail("command directory id action") }
    let name = URL(fileURLWithPath: args[1]).lastPathComponent
    DistributedNotificationCenter.default().postNotificationName(.init("org.dropy.benchmark.\(name)"),
        object: String(data: try! JSONSerialization.data(withJSONObject: ["id": args[2], "action": args[3]]), encoding: .utf8),
        userInfo: nil, deliverImmediately: true)
case "keys":
    // The only input destination allowed is this run's disposable target window.
    guard args.count == 6, let pid = pid_t(args[1]), let window = Int(args[2]),
          let count = Int(args[3]), (1...2000).contains(count), let rate = Double(args[4]), (1...240).contains(rate),
          ["typing", "repeat", "chord"].contains(args[5]) else { fail("keys pid window count rate typing|repeat|chord") }
    guard AXIsProcessTrusted(), checkPrompt(),
          NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "org.dropy.benchmarkfixture" else { fail("input preflight failed") }
    let mask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    guard CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty else { fail("held modifier") }
    // Terminal interrupts must still release keys posted by this tool.
    signal(SIGINT) { _ in inputInterrupted = 1 }
    signal(SIGTERM) { _ in inputInterrupted = 1 }
    let mode = args[5]
    var sent: [[String: Any]] = []
    var held: [CGKeyCode] = []
    func post(_ key: CGKeyCode, down: Bool, sequence: Int, repeated: Bool = false) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
        event.flags = mode == "chord" ? [.maskShift] : []
        event.setIntegerValueField(.eventSourceUserData, value: Int64(sequence))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.post(tap: .cghidEventTap)
        sent.append(["sequence": sequence, "kind": down ? "down" : "up", "keyCode": Int(key), "repeat": repeated, "shift": mode == "chord"])
    }
    var problem: String?
    let started = DispatchTime.now().uptimeNanoseconds
    let deadlineForRun = started + UInt64((Double(count) / rate + 5) * 1e9)
    for index in 0..<count {
        let deadline = started + UInt64(Double(index) / rate * 1e9)
        let now = DispatchTime.now().uptimeNanoseconds
        if deadline > now { Thread.sleep(forTimeInterval: Double(deadline - now) / 1e9) }
        guard inputInterrupted == 0, DispatchTime.now().uptimeNanoseconds < deadlineForRun else { problem = "interrupted or injection deadline exceeded"; break }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              focusedWindow(pid) == window, checkPrompt() else { problem = "focus changed or prompt appeared"; break }
        let key: CGKeyCode = mode == "repeat" ? 0 : [CGKeyCode(0), 1, 2][index % 3]
        if mode == "chord" {
            // Three keys overlap, then release in reverse order, all with Shift.
            let sequence = index * 6 + 1
            for (offset, k) in [CGKeyCode(0), 1, 2].enumerated() { held.append(k); post(k, down: true, sequence: sequence + offset) }
            for (offset, k) in held.reversed().enumerated() { post(k, down: false, sequence: sequence + 3 + offset) }
            held = []
        } else if mode == "repeat" {
            if index == 0 { held.append(key) }
            post(key, down: true, sequence: index + 1, repeated: index > 0)
        } else {
            held.append(key); post(key, down: true, sequence: index * 2 + 1)
            post(key, down: false, sequence: index * 2 + 2); held = []
        }
    }
    for key in held.reversed() { post(key, down: false, sequence: count + 1) }
    emit(["events": sent, "durationMs": Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6,
          "error": problem as Any? ?? NSNull()])
    if problem != nil { exit(2) }
case "shortcut":
    guard AXIsProcessTrusted(), checkPrompt() else { fail("shortcut preflight failed") }
    let flags: CGEventFlags = [.maskControl, .maskAlternate]
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 2, keyDown: down)!
        event.flags = flags; event.post(tap: .cghidEventTap)
    }
default: fail("environment|command|keys|shortcut")
}
