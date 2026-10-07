// Stage spike (Phase 0 of docs/design/2026-10-07-interaction-engine-plan.md).
// Throwaway: creates a Dropy-owned virtual display and runs a scenario file of
// commands against it, logging what macOS does. Not app code.
//
//   StageSpike <scenario-file>
//
// Scenario lines (# comments allowed):
//   create <w> <h> [hz]        HiDPI virtual display of w×h points
//   arrange <x> <y>            put the Stage's top-left at global (x, y)
//   arrange corner             just past the main display's bottom-right corner
//   info                       displays, scales and current desktops
//   baseline                   remember every on-screen window's frame
//   moved                      list windows whose frame changed since baseline
//   find <pid> <title-prefix>  choose the target window (Accessibility)
//   findid <pid> <window-id>   the same by exact window ID, also off the current desktop
//   move stage <dx> <dy>       target to Stage origin + (dx, dy), read back
//   move main <x> <y>          target to global (x, y) on the main display, read back
//   size <w> <h>               resize the target, read back
//   where                      target frame, its desktops, the Stage's desktop
//   activate                   bring the target's app forward (AX frontmost)
//   curtain on|off             opaque window over the whole Stage
//   warp <x> <y> | warp stage <dx> <dy>   move the pointer (no suppression)
//   pointer                    where the pointer is, and on which display
//   cursor                     the current system cursor's size and hot spot
//   popups                     the target app's non-normal-layer windows and where they are
//   shell <command…>           run a shell command, print its output
//   wait <seconds>
//   release                    release the Stage, time until it is gone
//   crash                      abort() with the Stage alive
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
let started = Date()
func log(_ text: String) {
    print(String(format: "[%7.3f] ", Date().timeIntervalSince(started)) + text)
}
func spin(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func r(_ rect: CGRect) -> String { "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))" }

// MARK: SkyLight desktop facts (as in Sources/Dropy/WindowPlacer.swift)

typealias MainConnection = @convention(c) () -> Int32
typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
func symbol<T>(_ name: String, as type: T.Type) -> T? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
}
func spaces(ofWindow id: UInt32) -> [UInt64] {
    guard let cid = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
          let copy = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindows.self),
          let list = copy(cid, 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
    return list.map(\.uint64Value)
}
/// Display UUID → (current desktop, all desktops with their type: 0 normal, 4 full screen).
func displaySpaces() -> [String: (current: UInt64, all: [(UInt64, Int)])] {
    guard let cid = symbol("CGSMainConnectionID", as: MainConnection.self)?(),
          let copy = symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self),
          let displays = copy(cid)?.takeRetainedValue() as? [[String: Any]] else { return [:] }
    var result: [String: (UInt64, [(UInt64, Int)])] = [:]
    for display in displays {
        let id = display["Display Identifier"] as? String ?? "?"
        let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64 ?? 0
        let all = (display["Spaces"] as? [[String: Any]] ?? []).map { ($0["id64"] as? UInt64 ?? 0, $0["type"] as? Int ?? -1) }
        result[id] = (current, all)
    }
    return result
}
func uuid(of display: CGDirectDisplayID) -> String {
    guard let id = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return "?" }
    return CFUUIDCreateString(nil, id) as String
}
func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids
}

// MARK: Accessibility

typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let getWindow = symbol("_AXUIElementGetWindow", as: GetWindow.self)
func axPoint(_ e: AXUIElement, _ attr: String) -> CGPoint? {
    var v: CFTypeRef?; var p = CGPoint.zero
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v,
          AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
    return p
}
func axSize(_ e: AXUIElement, _ attr: String) -> CGSize? {
    var v: CFTypeRef?; var s = CGSize.zero
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v,
          AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
    return s
}
func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axPoint(e, kAXPositionAttribute), let s = axSize(e, kAXSizeAttribute) else { return nil }
    return CGRect(origin: p, size: s)
}
@discardableResult func setPosition(_ e: AXUIElement, _ p: CGPoint) -> AXError {
    var p = p
    return AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
}
@discardableResult func setSize(_ e: AXUIElement, _ s: CGSize) -> AXError {
    var s = s
    return AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
}

// MARK: State

var stage: CGVirtualDisplay?
var stageID: CGDirectDisplayID = 0
var baseline: [UInt32: (CGRect, String)] = [:]
var target: (pid: pid_t, element: AXUIElement, windowID: UInt32)?
var curtain: NSWindow?

func stageBounds() -> CGRect { stageID == 0 ? .null : CGDisplayBounds(stageID) }
func screen(for display: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }
}
func inventory() -> [UInt32: (CGRect, String)] {
    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var result: [UInt32: (CGRect, String)] = [:]
    for row in rows where (row[kCGWindowLayer as String] as? Int) == 0 {
        guard let id = row[kCGWindowNumber as String] as? UInt32,
              let b = (row[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:))
        else { continue }
        result[id] = (b, row[kCGWindowOwnerName as String] as? String ?? "?")
    }
    return result
}
func displayName(containing point: CGPoint) -> String {
    for id in activeDisplays() where CGDisplayBounds(id).contains(point) { return id == stageID ? "stage" : "display\(id)" }
    return "none"
}

// MARK: Commands

func run(_ words: [String]) {
    switch words.first {
    case "create":
        let w = UInt32(words[1])!, h = UInt32(words[2])!, hz = words.count > 3 ? Double(words[3])! : 60
        let t0 = Date()
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "Dropy Stage"
        descriptor.maxPixelsWide = w * 2
        descriptor.maxPixelsHigh = h * 2
        descriptor.sizeInMillimeters = CGSize(width: Double(w) * 0.2, height: Double(h) * 0.2)
        descriptor.vendorID = 0xD70E
        descriptor.productID = 0x5747
        descriptor.serialNum = 1
        descriptor.terminationHandler = { _, _ in log("stage: terminated by WindowServer") }
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return log("create: initWithDescriptor returned nil") }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: w, height: h, refreshRate: hz)]
        let applied = display.apply(settings)
        stage = display
        stageID = display.displayID
        var appeared = false
        for _ in 0..<60 {
            if screen(for: stageID) != nil { appeared = true; break }
            spin(0.05)
        }
        let mode = CGDisplayCopyDisplayMode(stageID)
        log("create: applied=\(applied) id=\(stageID) appeared=\(appeared) after=\(Int(Date().timeIntervalSince(t0) * 1000))ms bounds=\(r(stageBounds())) mode=\(mode?.width ?? 0)x\(mode?.height ?? 0)pt \(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0)px \(mode?.refreshRate ?? 0)Hz scale=\(screen(for: stageID)?.backingScaleFactor ?? 0)")
    case "arrange":
        guard stageID != 0 else { return log("arrange: no stage") }
        let main = CGDisplayBounds(CGMainDisplayID())
        let origin = words[1] == "corner" ? CGPoint(x: main.maxX, y: main.maxY)
            : CGPoint(x: Double(words[1])!, y: Double(words[2])!)
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayOrigin(config, stageID, Int32(origin.x), Int32(origin.y))
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        spin(0.5)
        log("arrange: asked=\(Int(origin.x)),\(Int(origin.y)) result=\(result.rawValue) bounds=\(r(stageBounds())) main=\(r(main))")
    case "info":
        let spaces = displaySpaces()
        for id in activeDisplays() {
            let s = spaces[uuid(of: id)]
            log("info: \(id == stageID ? "stage" : "display") id=\(id) bounds=\(r(CGDisplayBounds(id))) scale=\(screen(for: id)?.backingScaleFactor ?? 0) current=\(s?.current ?? 0) desktops=\(s?.all.map { "\($0.0)\($0.1 == 4 ? "(fullscreen)" : "")" }.joined(separator: ",") ?? "?")")
        }
        log("info: frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
    case "baseline":
        baseline = inventory()
        log("baseline: \(baseline.count) windows")
    case "moved":
        let now = inventory()
        var changes: [String] = []
        for (id, (frame, owner)) in baseline {
            guard let current = now[id]?.0 else { changes.append("\(owner)#\(id) gone(off screen)"); continue }
            if current != frame { changes.append("\(owner)#\(id) \(r(frame)) -> \(r(current))") }
        }
        log("moved: \(changes.isEmpty ? "none" : changes.joined(separator: "; "))")
    case "find":
        let pid = pid_t(words[1])!, prefix = words.dropFirst(2).joined(separator: " ")
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        for element in (value as? [AXUIElement]) ?? [] {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            guard (title as? String)?.hasPrefix(prefix) == true else { continue }
            var id: CGWindowID = 0
            _ = getWindow?(element, &id)
            target = (pid, element, id)
            return log("find: window=\(id) frame=\(r(axFrame(element) ?? .null))")
        }
        log("find: no window titled \(prefix)…")
    case "findid":
        // Exact window ID among the app's windows and its main and focused window:
        // the windows list covers only the current desktop.
        let pid = pid_t(words[1])!, wanted = UInt32(words[2])!
        let app = AXUIElementCreateApplication(pid)
        var candidates: [AXUIElement] = []
        for attribute in [kAXWindowsAttribute, kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success, let value else { continue }
            if let list = value as? [AXUIElement] { candidates += list }
            else if CFGetTypeID(value) == AXUIElementGetTypeID() { candidates.append(value as! AXUIElement) }
        }
        for element in candidates {
            var id: CGWindowID = 0
            guard getWindow?(element, &id) == .success, id == wanted else { continue }
            target = (pid, element, id)
            return log("findid: window=\(id) frame=\(r(axFrame(element) ?? .null)) (of \(candidates.count) candidates)")
        }
        log("findid: window \(wanted) not reachable (\(candidates.count) candidates)")
    case "move":
        guard let target else { return log("move: no target") }
        let p: CGPoint = words[1] == "stage"
            ? CGPoint(x: stageBounds().minX + Double(words[2])!, y: stageBounds().minY + Double(words[3])!)
            : CGPoint(x: Double(words[2])!, y: Double(words[3])!)
        let t0 = Date()
        let error = setPosition(target.element, p)
        let after = axFrame(target.element) ?? .null
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        spin(0.3)
        let settled = axFrame(target.element) ?? .null
        log("move: to=\(Int(p.x)),\(Int(p.y)) err=\(error.rawValue) readback=\(r(after)) in \(ms)ms settled=\(r(settled)) on=\(displayName(containing: CGPoint(x: settled.midX, y: settled.minY + 5)))")
    case "size":
        guard let target else { return log("size: no target") }
        let error = setSize(target.element, CGSize(width: Double(words[1])!, height: Double(words[2])!))
        spin(0.2)
        log("size: err=\(error.rawValue) frame=\(r(axFrame(target.element) ?? .null))")
    case "where":
        guard let target else { return log("where: no target") }
        let frame = axFrame(target.element) ?? .null
        let mine = spaces(ofWindow: target.windowID)
        let all = displaySpaces()
        let stageCurrent = all[uuid(of: stageID)]?.current ?? 0
        let mainCurrent = all[uuid(of: CGMainDisplayID())]?.current ?? 0
        let server = (CGWindowListCopyWindowInfo(.optionIncludingWindow, target.windowID) as? [[String: Any]])?.first
        log("where: frame=\(r(frame)) on=\(displayName(containing: CGPoint(x: frame.midX, y: frame.minY + 5))) windowDesktops=\(mine) stageCurrent=\(stageCurrent) mainCurrent=\(mainCurrent) onScreen=\(server?[kCGWindowIsOnscreen as String] as? Bool ?? false)")
    case "activate":
        guard let target else { return log("activate: no target") }
        let before = displaySpaces()[uuid(of: CGMainDisplayID())]?.current ?? 0
        let t0 = Date()
        AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(target.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var front = false
        for _ in 0..<40 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { front = true; break }
            spin(0.025)
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        spin(1.0)
        let after = displaySpaces()[uuid(of: CGMainDisplayID())]?.current ?? 0
        log("activate: frontmost=\(front) in \(ms)ms mainDesktop \(before) -> \(after)\(before == after ? " (unchanged)" : " (SWITCHED)")")
    case "curtain":
        if words[1] == "on", let s = screen(for: stageID) {
            let w = NSPanel(contentRect: s.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.backgroundColor = .black
            w.isOpaque = true
            w.level = .floating
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.setFrame(s.frame, display: true)
            w.orderFrontRegardless()
            curtain = w
            spin(0.3)
            log("curtain: on frame=\(r(w.frame))")
        } else {
            curtain?.orderOut(nil)
            curtain = nil
            log("curtain: off")
        }
    case "warp":
        let p: CGPoint = words[1] == "stage"
            ? CGPoint(x: stageBounds().minX + Double(words[2])!, y: stageBounds().minY + Double(words[3])!)
            : CGPoint(x: Double(words[1])!, y: Double(words[2])!)
        let error = CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
        spin(0.05)
        let now = CGEvent(source: nil)?.location ?? .zero
        log("warp: to=\(Int(p.x)),\(Int(p.y)) err=\(error.rawValue) now=\(Int(now.x)),\(Int(now.y)) on=\(displayName(containing: now))")
    case "pointer":
        let now = CGEvent(source: nil)?.location ?? .zero
        log("pointer: \(Int(now.x)),\(Int(now.y)) on=\(displayName(containing: now))")
    case "cursor":
        let cursor = NSCursor.currentSystem
        let size = cursor?.image.size ?? .zero
        let bytes = cursor?.image.tiffRepresentation?.count ?? 0
        let kind = bytes == NSCursor.iBeam.image.tiffRepresentation?.count ? "iBeam"
            : bytes == NSCursor.arrow.image.tiffRepresentation?.count ? "arrow" : "other"
        log("cursor: available=\(cursor != nil) size=\(Int(size.width))x\(Int(size.height)) hotSpot=\(Int(cursor?.hotSpot.x ?? 0)),\(Int(cursor?.hotSpot.y ?? 0)) bytes=\(bytes) looksLike=\(kind)")
    case "popups":
        guard let target else { return log("popups: no target") }
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = rows.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == target.pid && ($0[kCGWindowLayer as String] as? Int ?? 0) != 0 }
        let text = mine.compactMap { row -> String? in
            guard let b = (row[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:)) else { return nil }
            return "layer\(row[kCGWindowLayer as String] as? Int ?? 0) \(r(b)) on=\(displayName(containing: CGPoint(x: b.midX, y: b.midY)))"
        }
        log("popups: \(text.isEmpty ? "none" : text.joined(separator: "; "))")
    case "shell":
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", words.dropFirst().joined(separator: " ")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        log("shell: \(words.dropFirst().joined(separator: " ")) -> \(out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))")
    case "wait":
        spin(Double(words[1])!)
    case "release":
        let t0 = Date()
        stage = nil
        var gone = false
        for _ in 0..<80 {
            spin(0.05)
            if !activeDisplays().contains(stageID) { gone = true; break }
        }
        log("release: gone=\(gone) after=\(Int(Date().timeIntervalSince(t0) * 1000))ms")
        stageID = 0
    case "crash":
        log("crash: aborting with the stage alive")
        abort()
    default:
        log("unknown command: \(words.joined(separator: " "))")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard CommandLine.arguments.count > 1, let scenario = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
    print("usage: StageSpike <scenario-file>")
    exit(2)
}
log("spike: AX trusted=\(AXIsProcessTrusted()) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
DispatchQueue.main.async {
    for line in scenario.split(separator: "\n") {
        let words = line.split(separator: " ").map(String.init)
        guard let first = words.first, !first.hasPrefix("#") else { continue }
        run(words)
    }
    log("spike: done")
    exit(0)
}
app.run()
