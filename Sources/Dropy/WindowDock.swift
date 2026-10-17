import AppKit
import ApplicationServices
import DropyCore

/// Puts an app's real window inside the overlay, brings its app to the front, and
/// puts it back where it was when the overlay closes. Nothing is forwarded: the
/// person uses the real window, so every key, shortcut, input method, menu and drag
/// works as usual.
///
/// Every move is journaled first (`PlacementMode.docked`, with the window's original
/// frame), so a crash or quit puts the window back where the person had it.
/// Operations run one at a time in the order asked, so a close during an opening
/// puts the window back only after it has been placed.
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
        /// Hidden with Command-H.
        case appHidden
    }

    struct Docked {
        let identity: WindowIdentity
        var element: AXUIElement
        /// Where the window is, global top-left, as last placed or followed.
        var frame: CGRect
        var cornerRadius: CGFloat
        /// Waiting on the Stage between openings (a pinned app's window).
        var isStaged = false
        /// The desktop the window was on before Dropy first moved it, so it can go back
        /// to that desktop and not only to that position.
        var homeSpace: UInt64?
    }

    /// Windows that went back to a desktop the person is not on: they wait on the
    /// Stage until the person switches to that desktop, then return to their exact
    /// place there. macOS offers no public way to move a window to a desktop that is
    /// not showing, but a move between displays lands on the destination's current
    /// desktop, so the move happens the moment the home desktop is current.
    private var returning: [Docked] = []

    private let journal: PlacementJournal
    private weak var stage: Stage?
    private(set) var current: Docked?
    var onEvent: ((Event) -> Void)?
    /// Called when a release could not finish yet, so recovery can retry it.
    var onDeferredRestore: ((WindowIdentity) -> Void)?
    private var observer: AXObserver?
    private let operations = WindowSessionQueue()

    init(journal: PlacementJournal, stage: Stage?) {
        self.journal = journal
        self.stage = stage
    }

    /// Whether the managed window is waiting on the Stage.
    var isStaged: Bool { current?.isStaged ?? false }
    /// A window is on the Stage, or waits there for its own desktop to come back.
    var holdsWindows: Bool { isStaged || !returning.isEmpty }

    // MARK: Choosing a window

    /// Makes the window with `identity` the docked window. A different one docked before goes back to
    /// where the person had it. The window is not moved yet.
    func adopt(_ identity: WindowIdentity, session: UUID) -> Task<Void, Error> {
        operations.adopt(session) { [self] in
            if current?.identity == identity { return }
            // Opened again while waiting to go home: it is on the Stage already.
            if let index = returning.firstIndex(where: { $0.identity == identity }) {
                let docked = returning.remove(at: index)
                if current != nil { await sendHomeNow() }
                current = docked
                startObserving(docked)
                return
            }
            if current != nil { await sendHomeNow() }
            guard WindowPlacer.isTrusted else { throw DockError.accessibilityNotTrusted }
            let application = NSRunningApplication(processIdentifier: identity.processID)
            // An earlier failed restore still owns this window's original state.
            // Resolve it before adopting again rather than overwriting its evidence.
            guard !journal.entries.contains(where: { $0.identity == identity }) else {
                throw DockError.windowUnreachable("pendingRecovery")
            }
            let element = try await findElement(identity)
            let original = try WindowPlacer.readState(element, identity: identity)
            let spaces = Spaces.of(identity.windowID) ?? []
            current = Docked(identity: identity, element: element, frame: original.frame,
                             cornerRadius: DockGeometry.defaultCornerRadius,
                             homeSpace: spaces.count == 1 ? spaces[0] : nil)
            // Unhiding and unminimizing are source mutations too. Save the original
            // state first, including those flags, before asking macOS to change it.
            var entry = PlacementEntry(identity: identity, mode: .docked, original: original,
                                       applied: WindowPlacementState(frame: original.frame, isMinimized: false, isAppHidden: false),
                                       createdAt: Date(), applicationConfirmed: false)
            do { try journal.upsert(entry) } catch { current = nil; throw DockError.journal(error) }
            if original.isAppHidden { application?.unhide() }
            if original.isMinimized {
                try WindowPlacer.setMinimized(false, window: element)
                try? await Task.sleep(for: .milliseconds(350))
            }
            entry.applied = try WindowPlacer.readState(element, identity: identity)
            entry.applicationConfirmed = true
            do { try journal.upsert(entry) } catch { throw DockError.journal(error) }
            // A window on another desktop is pulled over through the Stage: a move to
            // another display lands on that display's current desktop, and from the
            // Stage it lands on the person's (spike S2).
            if !onActiveSpace, let stage, await stage.start() {
                try await moveToStageNow()
                NSLog("Dropy dock: brought window=%u from another desktop through the Stage", identity.windowID)
            }
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
    func place(at frame: CGRect, session: UUID) async throws -> CGRect {
        try await operations.perform(session) { [self] in
            guard var docked = current else { throw DockError.nothingDocked }
            let identity = docked.identity
            let original = try existingEntry(identity)?.original
                ?? WindowPlacer.readState(docked.element, identity: identity)
            var entry = PlacementEntry(identity: identity, mode: .docked, original: original,
                                       applied: WindowPlacementState(frame: frame, isMinimized: false, isAppHidden: false),
                                       createdAt: existingEntry(identity)?.createdAt ?? Date(), applicationConfirmed: false)
            do { try journal.upsert(entry) } catch { throw DockError.journal(error) }
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
            docked.isStaged = false
            current = docked
            startObserving(docked)
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
    func activate(session: UUID) async -> Bool {
        (try? await operations.perform(session) { [self] in
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

    // MARK: Waiting on the Stage

    private func moveToStageNow() async throws {
        guard var docked = current else { throw DockError.nothingDocked }
        guard let stage, stage.isReady, let slot = stage.slot(for: docked.frame.size) else {
            throw DockError.windowUnreachable("noStage")
        }
        let identity = docked.identity
        let original = try existingEntry(identity)?.original ?? WindowPlacer.readState(docked.element, identity: identity)
        var entry = PlacementEntry(identity: identity, mode: .staged, original: original,
                                   applied: WindowPlacementState(frame: CGRect(origin: slot, size: docked.frame.size),
                                                                 isMinimized: false, isAppHidden: false),
                                   createdAt: existingEntry(identity)?.createdAt ?? Date(), applicationConfirmed: false)
        do { try journal.upsert(entry) } catch { throw DockError.journal(error) }
        // Marked first: the observer ignores Dropy's own moves of a staged window.
        docked.isStaged = true
        current = docked
        try WindowPlacer.setPosition(slot, of: docked.element)
        try? await Task.sleep(for: .milliseconds(30))
        let observed = try WindowPlacer.readState(docked.element, identity: identity)
        entry.applied = observed
        entry.applicationConfirmed = true
        do { try journal.upsert(entry) } catch { throw DockError.journal(error) }
        docked.frame = observed.frame
        current = docked
        if observer == nil { startObserving(docked) }
        stage.setCovered(true)
        NSLog("Dropy dock: staged window=%u at %.0f,%.0f", identity.windowID, observed.frame.minX, observed.frame.minY)
    }

    /// Live mode: the window goes to `frame` on the Stage (global top-left; the spot
    /// that mirrors where the person sees it) and the Stage is uncovered, so the window
    /// draws at full rate for streaming. Returns its frame there.
    func prepareLive(frame: CGRect, session: UUID) async throws -> CGRect {
        try await operations.perform(session) { [self] in
            if current?.isStaged != true { try await moveToStageNow() }
            guard var docked = current, let stage, stage.bounds?.contains(frame.origin) == true else {
                throw DockError.windowUnreachable("noStage")
            }
            guard var entry = existingEntry(docked.identity) else { throw DockError.nothingDocked }
            entry.applied.frame = frame
            entry.applicationConfirmed = false
            do { try journal.upsert(entry) } catch { throw DockError.journal(error) }
            setFrame(frame, of: docked.element)
            // Some apps apply a new size a moment later (a layout pass of their own).
            try? await Task.sleep(for: .milliseconds(40))
            var observed = try WindowPlacer.readState(docked.element, identity: docked.identity)
            if !observed.frame.origin.equalTo(frame.origin) {
                try? WindowPlacer.setPosition(frame.origin, of: docked.element)
                observed = try WindowPlacer.readState(docked.element, identity: docked.identity)
            }
            entry.applied = observed
            entry.applicationConfirmed = true
            do { try journal.upsert(entry) } catch { throw DockError.journal(error) }
            docked.frame = observed.frame
            current = docked
            stage.setCovered(false)
            NSLog("Dropy dock: live on the Stage window=%u %.0fx%.0f", docked.identity.windowID,
                  observed.frame.width, observed.frame.height)
            return observed.frame
        }
    }

    // MARK: Letting it go

    /// Puts the window back where the person had it, on its own desktop, and forgets
    /// it. This is what closing the overlay does. If its desktop is not the one showing,
    /// it waits on the Stage until it is (`returning`).
    func release() -> Task<Void, Never> {
        let restore = operations.enqueue { [self] in await sendHomeNow() }
        return Task { _ = try? await restore.value }
    }

    /// System transitions release every owned window after any in-flight adoption,
    /// placement and closing have settled. Returning windows must not be stranded on
    /// a Stage whose coordinate system has just changed.
    func releaseAll() {
        _ = operations.enqueue { [self] in
            releaseNow()
            returnAllNow()
        }
    }

    /// Covering and restoration are one queued operation belonging to the closing
    /// session. Reserving it before suspension also closes an in-flight adoption.
    /// `coverFade` is how long `willRestore`'s cover takes to hide the window.
    func finishSession(_ session: UUID, coverFade: TimeInterval = 0, putsBack: Bool = true,
                       keepsOnStage: @escaping @MainActor (WindowIdentity) -> Bool = { _ in false },
                       willRestore: @escaping @MainActor (Docked) -> Void = { _ in },
                       didRestore: @escaping @MainActor (pid_t?, Bool) -> Void = { _, _ in }) -> Task<Void, Never> {
        operations.finish(session, ifUnowned: { didRestore(nil, false) }) { [self] in
            guard let docked = current else { didRestore(nil, false); return }
            var stages = false
            if putsBack {
                if let latest = current { willRestore(latest) }
                if coverFade > 0 { try? await Task.sleep(for: .seconds(coverFade)) }
                // Pinning may change while the cover fades in.
                stages = stage?.isReady == true && keepsOnStage(docked.identity)
                if stages {
                    do { try await moveToStageNow() }
                    catch { await sendHomeNow() }
                } else {
                    await sendHomeNow()
                }
            }
            didRestore(docked.identity.processID, stages && current?.isStaged == true)
        }
    }

    private func sendHomeNow() async {
        guard let docked = current else { return }
        guard let home = docked.homeSpace, Self.isElsewhere(home), stage?.isReady == true else {
            releaseNow()
            return
        }
        do {
            try await moveToStageNow()
        } catch {
            releaseNow()
            return
        }
        guard let waiting = current else { return }
        stopObserving()
        current = nil
        returning.append(waiting)
        NSLog("Dropy dock: window=%u waits on the Stage for its desktop", waiting.identity.windowID)
    }

    /// Whether `space` still exists but is not showing on any display.
    private static func isElsewhere(_ space: UInt64) -> Bool {
        guard let showing = Spaces.current(), !showing.contains(space), let all = Spaces.all() else { return false }
        return all.contains(space)
    }

    /// The person switched desktops: windows whose desktop is now showing go back to
    /// their place there (and any whose desktop was removed go back here).
    func activeSpaceChanged() {
        for waiting in returning {
            guard let home = waiting.homeSpace, !Self.isElsewhere(home) else { continue }
            returnHome(waiting, reason: "desktop showing")
        }
    }

    /// The person brought an app forward (Command-Tab, the Dock): a window of it that is
    /// waiting on the Stage would be invisible, so it comes back now, on this desktop.
    func applicationActivated(pid: pid_t) {
        for waiting in returning where waiting.identity.processID == pid {
            returnHome(waiting, reason: "app brought forward")
        }
    }

    /// Every waiting window goes back now, wherever the person is (quitting).
    func returnAllNow() {
        for waiting in returning { returnHome(waiting, reason: "quitting") }
    }

    /// The Stage ended: macOS has moved its windows to a real display already.
    func forgetReturning() { returning = [] }

    private func returnHome(_ waiting: Docked, reason: String) {
        returning.removeAll { $0.identity == waiting.identity }
        guard let entry = existingEntry(waiting.identity) else { return }
        let outcome = WindowPlacer.restore(entry, journal: journal)
        NSLog("Dropy dock: window=%u went home (%@) outcome=%@", waiting.identity.windowID, reason,
              PlacementJournal.name(outcome))
        if outcome.retriesAutomatically { onDeferredRestore?(waiting.identity) }
    }

    /// The synchronous release, for quitting.
    func releaseNow() {
        guard let docked = current else { return }
        stopObserving()
        current = nil
        guard let entry = existingEntry(docked.identity) else { return }
        let outcome = WindowPlacer.restore(entry, journal: journal)
        NSLog("Dropy dock: released window=%u outcome=%@", docked.identity.windowID, PlacementJournal.name(outcome))
        if outcome.retriesAutomatically { onDeferredRestore?(docked.identity) }
    }

    /// The person took the window (moved it away, made it full screen), or it closed:
    /// stop tracking it and leave it where it is.
    func detach() {
        guard let docked = current else { return }
        stopObserving()
        current = nil
        try? journal.remove(docked.identity)
        NSLog("Dropy dock: detached window=%u", docked.identity.windowID)
    }

    /// The person minimized or hid the docked window: it goes back to its original
    /// frame and stays minimized or hidden, so it reappears where they had it.
    func putBackKeepingState() {
        guard let docked = current else { return }
        stopObserving()
        current = nil
        guard var entry = existingEntry(docked.identity) else { return }
        do {
            let current = try WindowPlacer.readState(docked.element, identity: docked.identity)
            var target = entry.original
            target.isMinimized = current.isMinimized
            target.isAppHidden = current.isAppHidden
            entry = PlacementEntry(identity: entry.identity, mode: entry.mode, original: target,
                                   applied: current, createdAt: entry.createdAt, applicationConfirmed: true)
            try journal.upsert(entry)
            let outcome = WindowPlacer.restore(entry, journal: journal)
            if outcome.retriesAutomatically { onDeferredRestore?(docked.identity) }
        } catch {
            onDeferredRestore?(docked.identity)
        }
        NSLog("Dropy dock: put back (minimized or hidden) window=%u", docked.identity.windowID)
    }

    /// Whether the docked window's journal entry was settled elsewhere (recovery
    /// restored it); the window is then no longer Dropy's.
    func journalChanged() -> Bool {
        guard let docked = current, existingEntry(docked.identity) == nil, observer != nil else { return false }
        stopObserving()
        current = nil
        return true
    }

    /// The docked window's size before Dropy first moved it.
    var originalSize: CGSize? {
        current.flatMap { existingEntry($0.identity)?.original.frame.size }
    }

    private func existingEntry(_ identity: WindowIdentity) -> PlacementEntry? {
        journal.entries.first { $0.identity == identity && ($0.mode == .docked || $0.mode == .staged) }
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
        // A staged window only moves when Dropy moves it.
        guard !docked.isStaged else { return }
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
