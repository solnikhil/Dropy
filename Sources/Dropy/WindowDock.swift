import AppKit
import ApplicationServices
import DropyCore
import ScreenCaptureKit

/// Puts an app's real window inside the overlay, brings its app to the front, and
/// sends it home when the overlay closes. Nothing is forwarded: the person uses the
/// real window, so every key, shortcut, input method, menu and drag works as usual.
///
/// Every move is journaled first (`PlacementMode.docked`, with the window's original
/// frame), so a crash or quit puts the window back where the person had it.
/// Operations run one at a time in the order asked, so a close during an opening
/// sends the window home only after it has been placed.
@MainActor
final class WindowDock {
    enum DockError: Error, CustomStringConvertible {
        case accessibilityNotTrusted
        case nothingDocked
        case windowUnreachable(String)
        case journal(Error)

        var description: String {
            switch self {
            case .accessibilityNotTrusted: "accessibilityNotTrusted"
            case .nothingDocked: "nothingDocked"
            case .windowUnreachable(let reason): "windowUnreachable(\(reason))"
            case .journal(let error): "journal(\(error))"
            }
        }
    }

    /// Something the person did to the docked window or its app.
    enum Event {
        /// Resized in place; the overlay follows. Global top-left frame.
        case resized(CGRect)
        /// Dragged away or made full screen: theirs now.
        case detached
        case closed
        case minimized
        /// Hidden with Command-H: it waits hidden, as if sent home.
        case appHidden
    }

    struct Docked {
        let identity: WindowIdentity
        var window: SCWindow
        var element: AXUIElement
        /// Where the window is, global top-left, as last placed or followed.
        var frame: CGRect
        /// The window as it last looked, for the opening and closing animations.
        var snapshot: CGImage?
        var cornerRadius: CGFloat
        /// Where it waits while the overlay is closed; nil while it is shown.
        var home: DockPolicy.Home?
    }

    private let journal: PlacementJournal
    private let parkingTabs: ParkingTabs
    private(set) var current: Docked?
    var onEvent: ((Event) -> Void)?
    /// Called when a release could not finish yet, so recovery can retry it.
    var onDeferredRestore: ((WindowIdentity) -> Void)?
    private var observer: AXObserver?
    private var queue: Task<Void, Never>?

    init(journal: PlacementJournal, parkingTabs: ParkingTabs) {
        self.journal = journal
        self.parkingTabs = parkingTabs
    }

    /// Runs `body` after every operation asked for before it.
    private func serially<T: Sendable>(_ body: @escaping @Sendable @MainActor () async throws -> T) async throws -> T {
        let previous = queue
        let task = Task { @MainActor in
            _ = await previous?.value
            return try await body()
        }
        queue = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: Choosing a window

    /// Makes `window` the docked window. A different one docked before goes back to
    /// where the person had it. The window is not moved yet.
    func adopt(_ window: SCWindow, identity: WindowIdentity) async throws {
        try await serially { [self] in
            if var docked = current, docked.identity == identity {
                docked.window = window
                current = docked
                return
            }
            if current != nil { releaseNow() }
            guard WindowPlacer.isTrusted else { throw DockError.accessibilityNotTrusted }
            let application = NSRunningApplication(processIdentifier: identity.processID)
            // A window the person hid or minimized is shown so it can be placed.
            if application?.isHidden == true { application?.unhide() }
            let element = try await findElement(identity)
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized) == .success,
               minimized as? Bool == true {
                try? WindowPlacer.setMinimized(false, window: element)
                try? await Task.sleep(for: .milliseconds(350))
            }
            let state = try WindowPlacer.readState(element, identity: identity)
            current = Docked(identity: identity, window: window, element: element, frame: state.frame,
                             snapshot: nil, cornerRadius: DockGeometry.defaultCornerRadius, home: nil)
            if onActiveSpace { await refreshSnapshot() }
        }
    }

    private func findElement(_ identity: WindowIdentity) async throws -> AXUIElement {
        for attempt in 0..<10 {
            switch try WindowPlacer.find(identity) {
            case .found(let element): return element
            case .missing(let diagnosis):
                if !diagnosis.mayBecomeReachable || attempt == 9 {
                    throw DockError.windowUnreachable(diagnosis.description)
                }
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw DockError.windowUnreachable("timeout")
    }

    /// Whether the docked window is on the desktop the person is looking at. A window
    /// on another desktop, or behind another app's full-screen space, cannot be
    /// brought here: macOS has no public way to move another app's window between desktops.
    var onActiveSpace: Bool {
        current.map { Self.isOnActiveSpace($0.identity.windowID) } ?? true
    }

    /// True when unknown: the desktop facts come from private calls that may be missing.
    static func isOnActiveSpace(_ windowID: UInt32) -> Bool {
        guard let spaces = Spaces.of(windowID), !spaces.isEmpty, let active = Spaces.current() else { return true }
        return !Set(spaces).isDisjoint(with: active)
    }

    // MARK: Showing it

    /// Shows the window at `frame` (global top-left) and returns where it really went:
    /// apps can refuse a size and macOS keeps windows below the menu bar.
    @discardableResult
    func place(at frame: CGRect) async throws -> CGRect {
        try await serially { [self] in
            guard var docked = current else { throw DockError.nothingDocked }
            let identity = docked.identity
            let wasHome = docked.home
            let original = try existingEntry(identity)?.original
                ?? WindowPlacer.readState(docked.element, identity: identity)
            var entry = PlacementEntry(identity: identity, mode: .docked, original: original,
                                       applied: WindowPlacementState(frame: frame, isMinimized: false, isAppHidden: false),
                                       createdAt: existingEntry(identity)?.createdAt ?? Date(), applicationConfirmed: false)
            do { try journal.upsert(entry) } catch { throw DockError.journal(error) }
            if wasHome == .hideApp, let application = NSRunningApplication(processIdentifier: identity.processID),
               application.isHidden {
                application.unhide()
                // A hidden app's window can leave Accessibility; wait for it to come back.
                docked.element = try await findElement(identity)
            }
            if wasHome == .park { parkingTabs.remove(identity) }
            setFrame(frame, of: docked.element)
            // Some apps apply a new size a moment later (a layout pass of their own).
            try? await Task.sleep(for: .milliseconds(40))
            var observed = try WindowPlacer.readState(docked.element, identity: identity)
            if !observed.frame.equalTo(frame) {
                setFrame(CGRect(origin: frame.origin, size: observed.frame.size), of: docked.element)
                observed = try WindowPlacer.readState(docked.element, identity: identity)
            }
            entry.applied = observed
            entry.applicationConfirmed = true
            do { try journal.upsert(entry) } catch { throw DockError.journal(error) }
            docked.frame = observed.frame
            docked.home = nil
            current = docked
            startObserving(docked)
            // The capture catalog's copy of the window still has its old size; refresh it
            // so the closing snapshot needs no lookup.
            Task { @MainActor [weak self] in
                guard case .available(let fresh)? = try? await WindowCatalog.resolve(identity),
                      var latest = self?.current, latest.identity == identity else { return }
                latest.window = fresh
                self?.current = latest
            }
            NSLog("Dropy dock: placed window=%u asked=%.0fx%.0f got=%.0fx%.0f at %.0f,%.0f", identity.windowID,
                  frame.width, frame.height, observed.frame.width, observed.frame.height,
                  observed.frame.minX, observed.frame.minY)
            return observed.frame
        }
    }

    /// Accessibility applies a size and a position separately, and each can be clamped
    /// against the other: position, size, then position again.
    private func setFrame(_ frame: CGRect, of element: AXUIElement) {
        try? WindowPlacer.setPosition(frame.origin, of: element)
        try? WindowPlacer.setFrame(frame, of: element, resize: true)
        try? WindowPlacer.setPosition(frame.origin, of: element)
    }

    /// Brings the docked window's app to the front with that window key. Returns
    /// whether the app is frontmost afterwards.
    @discardableResult
    func activate() async -> Bool {
        (try? await serially { [self] in
            guard let docked = current else { return false }
            let pid = docked.identity.processID
            raise(docked.element)
            // As an Accessibility client Dropy can set the app frontmost directly. macOS 14's
            // cooperative activation otherwise only honours a request the active app yields to.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString,
                                         kCFBooleanTrue)
            if await waitForFrontmost(pid) {
                raise(docked.element)
                return true
            }
            guard let application = NSRunningApplication(processIdentifier: pid) else { return false }
            NSApp.yieldActivation(to: application)
            application.activate()
            let front = await waitForFrontmost(pid)
            raise(docked.element)
            NSLog("Dropy dock: activation fallback frontmost=%@", front ? "yes" : "no")
            return front
        }) ?? false
    }

    private func raise(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    private func waitForFrontmost(_ pid: pid_t) async -> Bool {
        for _ in 0..<16 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Brings another app to the front, e.g. the one the person was in before.
    static func activateApplication(_ pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString,
                                     kCFBooleanTrue)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    // MARK: Snapshots

    /// Captures the window as it looks now (at most `timeout`), keeps it for the next
    /// animation and measures its corner radius. Keeps the previous snapshot on failure.
    func refreshSnapshot(timeout: Duration = .milliseconds(250)) async {
        guard let docked = current else { return }
        let identity = docked.identity
        var window = docked.window
        let known = abs(window.frame.width - docked.frame.width) < 2 && abs(window.frame.height - docked.frame.height) < 2
        if !known, case .available(let fresh)? = try? await WindowCatalog.resolve(identity) { window = fresh }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(docked.frame.width * scale))
        configuration.height = max(1, Int(docked.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = await Self.captureImage(filter: filter, configuration: configuration, timeout: timeout)
        guard let image, var latest = current, latest.identity == identity else { return }
        latest.window = window
        latest.snapshot = image
        if let radius = Self.cornerRadius(of: image, scale: scale) { latest.cornerRadius = radius }
        current = latest
    }

    /// One screenshot, or nil after `timeout` so a slow capture never holds up a close.
    private static func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration,
                                     timeout: Duration) async -> CGImage? {
        let once = OneShot<CGImage?>()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                once.resume(image)
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
        }
    }

    private static func cornerRadius(of image: CGImage, scale: CGFloat) -> CGFloat? {
        let side = min(image.width, image.height, Int(48 * scale))
        guard side > 2, let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        // The image's top-left corner at the context's top-left; a bitmap context's
        // first row in memory is its top row.
        context.draw(image, in: CGRect(x: 0, y: side - image.height, width: image.width, height: image.height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let diagonal = (0..<side).map { pixels[($0 * side + $0) * 4 + 3] }
        return DockGeometry.cornerRadius(diagonalAlpha: diagonal, scale: scale)
    }

    // MARK: Sending it home

    /// Hides the app, or parks the window when the app has other windows open, and
    /// returns which. The window keeps its docked size, so the next opening only has
    /// to show it.
    @discardableResult
    func sendHome() async -> DockPolicy.Home? {
        try? await serially { [self] in
            guard var docked = current, docked.home == nil, var entry = existingEntry(docked.identity) else {
                return nil
            }
            let identity = docked.identity
            let home = DockPolicy.home(otherVisibleWindows: Self.otherVisibleWindows(of: identity))
            // Set first: the observer ignores Dropy's own homing moves.
            docked.home = home
            current = docked
            switch home {
            case .hideApp:
                entry.applied.isAppHidden = true
                entry.applicationConfirmed = false
                try? journal.upsert(entry)
                NSRunningApplication(processIdentifier: identity.processID)?.hide()
                for _ in 0..<20 {
                    if NSRunningApplication(processIdentifier: identity.processID)?.isHidden == true { break }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                entry.applied.isAppHidden = NSRunningApplication(processIdentifier: identity.processID)?.isHidden ?? true
                entry.applicationConfirmed = true
                try? journal.upsert(entry)
            case .park:
                let parked = PlacementGeometry.offscreenFrame(for: docked.frame, displays: WindowPlacer.displayBounds())
                entry.applied.frame = parked
                entry.applicationConfirmed = false
                try? journal.upsert(entry)
                try? WindowPlacer.setPosition(parked.origin, of: docked.element)
                if let observed = try? WindowPlacer.readState(docked.element, identity: identity) {
                    entry.applied = observed
                }
                entry.applicationConfirmed = true
                try? journal.upsert(entry)
                parkingTabs.show(for: entry)
            }
            NSLog("Dropy dock: home=%@ window=%u", home.rawValue, identity.windowID)
            return home
        }
    }

    /// The person hid the app themselves: the window is home already.
    func markHiddenByPerson() {
        guard var docked = current, var entry = existingEntry(docked.identity) else { return }
        docked.home = .hideApp
        current = docked
        entry.applied.isAppHidden = true
        try? journal.upsert(entry)
    }

    private static func otherVisibleWindows(of identity: WindowIdentity) -> Int {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return rows.filter { row in
            guard (row[kCGWindowOwnerPID as String] as? Int32) == identity.processID,
                  (row[kCGWindowNumber as String] as? UInt32) != identity.windowID,
                  (row[kCGWindowLayer as String] as? Int) == 0,
                  ((row[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let bounds = (row[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:))
            else { return false }
            return bounds.width > 60 && bounds.height > 60
        }.count
    }

    // MARK: Letting it go

    /// Puts the window back where the person had it and forgets it.
    func release() async {
        _ = try? await serially { [self] in releaseNow() }
    }

    /// The synchronous release, for quitting.
    func releaseNow() {
        guard let docked = current else { return }
        stopObserving()
        current = nil
        parkingTabs.remove(docked.identity)
        guard let entry = existingEntry(docked.identity) else { return }
        let outcome = WindowPlacer.restore(entry, journal: journal)
        NSLog("Dropy dock: released window=%u outcome=%@", docked.identity.windowID, PlacementJournal.name(outcome))
        if outcome.retriesAutomatically { onDeferredRestore?(docked.identity) }
    }

    /// The person took the window (moved it away, made it full screen, minimized it),
    /// or it closed: stop tracking it and leave it where it is.
    func detach() {
        guard let docked = current else { return }
        stopObserving()
        current = nil
        parkingTabs.remove(docked.identity)
        try? journal.remove(docked.identity)
        NSLog("Dropy dock: detached window=%u", docked.identity.windowID)
    }

    /// The journal entry was settled elsewhere (recovery or a parking tab).
    func journalChanged() {
        guard let docked = current, existingEntry(docked.identity) == nil, docked.home != nil else { return }
        stopObserving()
        current = nil
    }

    /// The docked window's size before Dropy first moved it.
    var originalSize: CGSize? {
        current.flatMap { existingEntry($0.identity)?.original.frame.size }
    }

    private func existingEntry(_ identity: WindowIdentity) -> PlacementEntry? {
        journal.entries.first { $0.identity == identity && $0.mode == .docked }
    }

    // MARK: Watching the window

    private func startObserving(_ docked: Docked) {
        stopObserving()
        var created: AXObserver?
        guard AXObserverCreate(docked.identity.processID, dockObserverCallback, &created) == .success,
              let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                     kAXWindowMiniaturizedNotification] {
            AXObserverAddNotification(created, docked.element, name as CFString, refcon)
        }
        AXObserverAddNotification(created, AXUIElementCreateApplication(docked.identity.processID),
                                  kAXApplicationHiddenNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func stopObserving() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    fileprivate func handle(_ notification: String) {
        guard var docked = current else { return }
        if notification == kAXUIElementDestroyedNotification {
            onEvent?(.closed)
            return
        }
        // Moves while waiting at home are Dropy's own.
        guard docked.home == nil else { return }
        switch notification {
        case kAXWindowMiniaturizedNotification:
            onEvent?(.minimized)
        case kAXApplicationHiddenNotification:
            onEvent?(.appHidden)
        case kAXMovedNotification, kAXResizedNotification:
            guard let state = try? WindowPlacer.readState(docked.element, identity: docked.identity) else { return }
            var fullScreen: CFTypeRef?
            AXUIElementCopyAttributeValue(docked.element, "AXFullScreen" as CFString, &fullScreen)
            switch DockPolicy.change(expected: docked.frame, observed: state.frame,
                                     isFullScreen: fullScreen as? Bool == true) {
            case .unchanged:
                break
            case .resizedInPlace:
                docked.frame = state.frame
                current = docked
                if var entry = existingEntry(docked.identity) {
                    entry.applied = state
                    try? journal.upsert(entry)
                }
                onEvent?(.resized(state.frame))
            case .detached:
                onEvent?(.detached)
            }
        default:
            break
        }
    }
}

private func dockObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                  _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let name = notification as String
    let address = UInt(bitPattern: refcon)
    // Added to the main run loop, so this runs on the main thread.
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<WindowDock>.fromOpaque(pointer).takeUnretainedValue().handle(name)
    }
}

/// Resumes a continuation once, from whichever side finishes first.
private final class OneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Value, Never>?

    func resume(_ value: sending Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
