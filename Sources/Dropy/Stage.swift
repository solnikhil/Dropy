import AppKit
import DropyCore
import DropyStageShim

/// Dropy's Stage: a hidden virtual display where pinned apps' windows wait between
/// openings. A window on it is "on screen" for macOS (it keeps rendering, and its
/// menus and popovers open there), it can be reached from every desktop with public
/// Accessibility moves, and the person never sees it. Measured in
/// docs/design/2026-10-07-stage-spike-results.md.
///
/// - Created once, when Dropy needs it, and kept for the life of the process; it
///   disappears with the process, and macOS then moves its windows to a real display.
/// - Placed past the bottom-right corner of every real display, touching them at one
///   point, and guarded by an event tap so a stray pointer is put back.
/// - Covered by an opaque curtain while nothing on it is shown, so the apps there
///   count as hidden and slow down.
@MainActor
final class Stage {
    enum Failure: Error, CustomStringConvertible {
        case unsupported, refused, notReported, accessibilityNotTrusted, displaysShareSpaces
        var description: String {
            switch self {
            case .displaysShareSpaces: "displaysShareSpaces"
            case .unsupported: "unsupported"
            case .refused: "refused"
            case .notReported: "notReported"
            case .accessibilityNotTrusted: "accessibilityNotTrusted"
            }
        }
    }

    private var display: NSObject?
    private(set) var displayID: CGDirectDisplayID?
    private var curtain: NSPanel?
    private var barrier: CFMachPort?
    private var barrierSource: CFRunLoopSource?
    private var screenObserver: NSObjectProtocol?
    private var starting: Task<Bool, Never>?
    /// While true, the pointer may be on the Stage (Live mode's hand-off).
    var allowsPointer = false
    /// Called when WindowServer ends the Stage; its windows are then on a real display.
    var onLost: (() -> Void)?

    static var isSupported: Bool { DropyStageIsSupported() }

    var isReady: Bool { displayID != nil && screen != nil }

    /// The Stage in global top-left coordinates.
    var bounds: CGRect? { displayID.map(CGDisplayBounds) }

    var screen: NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    /// Height of the Stage's own menu bar, which windows cannot cover.
    var menuBarHeight: CGFloat {
        guard let screen else { return 37 }
        return max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// Real displays (not the Stage), global top-left.
    static func realDisplays(excluding stage: CGDirectDisplayID?) -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.filter { $0 != stage }.map(CGDisplayBounds)
    }

    /// Creates the Stage if needed. Returns whether it is ready.
    @discardableResult
    func start() async -> Bool {
        if isReady { return true }
        if let starting { return await starting.value }
        let task = Task { @MainActor in
            do {
                try await create()
                return true
            } catch {
                NSLog("Dropy stage: unavailable (%@)", String(describing: error))
                stop()
                return false
            }
        }
        starting = task
        let ready = await task.value
        starting = nil
        return ready
    }

    private func create() async throws {
        guard Self.isSupported else { throw Failure.unsupported }
        guard AXIsProcessTrusted() else { throw Failure.accessibilityNotTrusted }
        // With one set of desktops across displays, the Stage would switch desktops along
        // with the main display, and windows on it would come and go with them.
        guard !Spaces.displaysShareSpaces else { throw Failure.displaysShareSpaces }
        let notch = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        let size = StageGeometry.size(for: notch?.frame.size ?? CGSize(width: 1512, height: 982))
        let refresh = Double(notch?.maximumFramesPerSecond ?? 60)
        let started = Date()
        guard let object = DropyStageCreate("Dropy Stage", UInt32(size.width), UInt32(size.height), refresh, 1,
                                            DispatchQueue.main, { [weak self] in
            MainActor.assumeIsolated { self?.lost() }
        }) else { throw Failure.refused }
        display = object
        let id = DropyStageDisplayID(object)
        // macOS reports a new display asynchronously; once it took over 3 s (spike S1).
        // Wait for the report rather than assume.
        for _ in 0..<160 {
            if NSScreen.screens.contains(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        displayID = id
        guard screen != nil else { throw Failure.notReported }
        arrange()
        showCurtain()
        installBarrier()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.arrange() }
        }
        NSLog("Dropy stage: ready id=%u %.0fx%.0f@%.0fHz in %.0fms bounds=%@", id, size.width, size.height, refresh,
              Date().timeIntervalSince(started) * 1000, NSStringFromRect(bounds ?? .zero))
    }

    /// Keeps the Stage past the corner of the real displays, also after they change.
    private func arrange() {
        guard let displayID, let bounds else { return }
        let origin = StageGeometry.origin(displays: Self.realDisplays(excluding: displayID))
        guard bounds.origin != origin else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(origin.x), Int32(origin.y))
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        NSLog("Dropy stage: arranged at %.0f,%.0f result=%d", origin.x, origin.y, result.rawValue)
        if let screen, let curtain { curtain.setFrame(screen.frame, display: false) }
    }

    /// Waits (at most `timeout`) until no other app's window is on the Stage, so the
    /// windows Dropy just moved off it have landed before the Stage goes away. Removing
    /// it while a move is still in flight let macOS "rescue" the window onto desktop 1.
    func waitUntilEmpty(timeout: TimeInterval = 1) {
        guard let bounds else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            let occupied = rows.contains { row in
                guard (row[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                      (row[kCGWindowLayer as String] as? Int) == 0,
                      let frame = (row[kCGWindowBounds as String] as? NSDictionary)
                          .flatMap(CGRect.init(dictionaryRepresentation:)) else { return false }
                return frame.intersects(bounds)
            }
            if !occupied { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        NSLog("Dropy stage: a window was still on the Stage when it was removed")
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        removeBarrier()
        curtain?.orderOut(nil)
        curtain = nil
        display = nil
        displayID = nil
    }

    private func lost() {
        NSLog("Dropy stage: ended by the window server")
        stop()
        onLost?()
    }

    // MARK: Curtain

    /// Covers the whole Stage (true) so its windows idle, or uncovers it (false) while
    /// a window on it is streamed.
    func setCovered(_ covered: Bool) {
        guard let curtain else { return }
        if covered { curtain.orderFrontRegardless() } else { curtain.orderOut(nil) }
    }

    private func showCurtain() {
        guard let screen else { return }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.title = "Dropy Stage curtain"
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        curtain = panel
    }

    // MARK: Barrier

    /// A stray pointer that reaches the Stage (only possible diagonally through one
    /// corner) is put back on the nearest real display, unless Live mode handed it over.
    private func installBarrier() {
        let mask = (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<Stage>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.filter(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            NSLog("Dropy stage: barrier unavailable")
            return
        }
        barrier = tap
        barrierSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeBarrier() {
        if let barrier { CGEvent.tapEnable(tap: barrier, enable: false); CFMachPortInvalidate(barrier) }
        if let barrierSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), barrierSource, .commonModes) }
        barrier = nil
        barrierSource = nil
    }

    /// Hooks that see pointer events first while the pointer is handed over (Live mode).
    var onPointerEvent: ((CGEventType, CGEvent) -> Void)?

    private func filter(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns a slow tap off; turn it back on rather than leave the Stage open.
            if let barrier { CGEvent.tapEnable(tap: barrier, enable: true) }
            return
        }
        if let onPointerEvent {
            onPointerEvent(type, event)
            return
        }
        guard !allowsPointer, let bounds, bounds.contains(event.location) else { return }
        let back = StageGeometry.nearestPoint(to: event.location, on: Self.realDisplays(excluding: displayID))
        CGWarpMouseCursorPosition(back)
        CGAssociateMouseAndMouseCursorPosition(1)
        event.location = back
    }

    // MARK: Windows

    /// Where a window of `size` waits on the Stage, global top-left.
    func slot(for size: CGSize) -> CGPoint? {
        guard let bounds else { return nil }
        return StageGeometry.slot(for: size, stage: bounds, menuBarHeight: menuBarHeight)
    }
}
