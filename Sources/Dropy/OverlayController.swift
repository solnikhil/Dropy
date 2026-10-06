import AppKit
import DropyCore
import ScreenCaptureKit

@MainActor
final class OverlayController: NSObject, NSMenuDelegate {
    private let preferences: PreferenceStore
    private let capture = CaptureController()
    /// Moves the chosen app's real window into the overlay (Full App interaction).
    private let dock: WindowDock
    /// Where the docked window and the overlay's body are, in screen coordinates.
    private var dockLayout: DockLayout?
    private var dockMonitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    /// Size in points of the window being previewed.
    private var selectedWindowSize: CGSize?
    /// A short note over the preview, e.g. why it is view only.
    private var interactionStatus: NSTextField?
    private var panel: OverlayPanel?
    private var list: NSStackView?
    private var status: NSTextField?
    private var privacyButton: NSButton?
    private var workspace: OverlayWorkspaceView?
    private var overlayScreen: NSScreen?
    private var expandedPreview = false
    /// Changes with every layout change; a resize finishing later leaves a newer one alone.
    private var layoutGeneration = UUID()
    /// The black outline that morphs out of the notch, and the content it reveals.
    private var backdrop: MorphBackdropView?
    private var content: NSView?
    /// The camera housing the overlay grows from; nil on a screen without one.
    private var notchSize: CGSize?
    /// Called when opening so notch affordances release their input ownership.
    var onOpen: (() -> Void)?
    /// Called whenever the overlay closes, so the notch trigger can stay quiet.
    var onClose: (() -> Void)?
    /// When the opening morph finishes; pointer-leave does not close before then.
    private var settlesAt = Date.distantPast
    private var renderer: MetalFrameView?
    private var available: [CapturableWindow] = []
    private var selectedIdentity: WindowIdentity?
    /// The window-list row Return opens; the first row until the arrows move it.
    private var highlightedIdentity: WindowIdentity?
    private var selectedApplicationName = ""
    private var restartedAfterInterruption = false
    private var identityTask: Task<Void, Never>?
    private struct PendingStart {
        let identity: WindowIdentity
        let request: UUID
        let renderer: MetalFrameView
    }
    private var pendingStart: PendingStart?
    private var startInFlight = false
    private var overlaySession = UUID()
    private var opensInProcess = 0
    private var requestedScreenCaptureAccess = false
    /// Changes on open, close, every selection and every failure. Async work
    /// continues only while its captured generation is still current.
    private var generation = UUID()
    private(set) var state: CapturePhase = .closed
    private var sessionMonitors: [Any] = []
    private var trackingArea: NSTrackingArea?
    private var pointerHasEntered = false
    private var pendingPointerLeave: DispatchWorkItem?
    private var previousApplication: NSRunningApplication?

    /// The exact window being previewed, for development drivers.
    var currentSelection: WindowIdentity? { selectedIdentity }
    func captureCounts() -> CaptureCounts? { capture.currentCounts() }

    init(preferences: PreferenceStore, journal: PlacementJournal, parkingTabs: ParkingTabs) {
        self.preferences = preferences
        dock = WindowDock(journal: journal, parkingTabs: parkingTabs)
        super.init()
        dock.onEvent = { [weak self] event in self?.handleDockEvent(event) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = application?.processIdentifier ?? 0
            let bundleID = application?.bundleIdentifier
            MainActor.assumeIsolated { self?.applicationActivated(pid: pid, bundleIdentifier: bundleID) }
        }
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    /// Called when a docked window's restore could not finish yet.
    var onDeferredRestore: ((WindowIdentity) -> Void)? {
        get { dock.onDeferredRestore }
        set { dock.onDeferredRestore = newValue }
    }

    func toggle() {
        state == .closed ? open() : close()
    }

    /// Closes the overlay if the dismiss preference treats `event` as an exit.
    func dismiss(_ event: DismissEvent) {
        guard state != .closed, preferences.value.dismissBehavior.closes(on: event) else { return }
        close()
    }

    /// Opens the overlay. With `resumingHome`, a docked window waiting at home comes
    /// back whatever the open behavior says (its app was brought to the front).
    func open(resumingHome: Bool = false) {
        guard state == .closed else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        if docksWindows, let docked = dock.current, docked.home != nil, dock.onActiveSpace,
           WindowCatalog.isRunning(docked.identity),
           resumingHome || preferences.value.openTargetBundleIdentifier == docked.identity.bundleIdentifier {
            openDockedHome(docked, on: screen)
            return
        }
        generation = UUID()
        overlaySession = UUID()
        overlayScreen = screen
        expandedPreview = false
        let full = OverlayGeometry.frame(on: screen.frame,
                                         preferredSize: preferences.value.sizePreset.dimensions)
        // The window is final from the start, with a transparent margin for the ears
        // and the opening overshoot; only the outline inside it moves. Resizing the
        // window itself each frame stuttered.
        let margin = NotchMorph.overshootMargin(for: full.size)
        let canvas = OverlayGeometry.pixelAligned(CGRect(x: full.minX - margin, y: full.minY - margin,
                            width: full.width + 2 * margin, height: full.height + margin), scale: screen.backingScaleFactor)
        let panel = OverlayPanel.make(contentRect: canvas)
        notchSize = Self.notchSize(on: screen)
        buildContent(in: panel, size: full.size)
        opensInProcess += 1
        let openedAt = CACurrentMediaTime()
        let openNumber = opensInProcess
        // Reveal: open request to the first captured frame on screen. "Warm" means
        // this process has opened the overlay before.
        renderer?.onNextPresented = { presentedTime in
            NSLog("Dropy reveal: firstFrame=%.1fms open=%ld warm=%@",
                  (presentedTime - openedAt) * 1_000, openNumber, openNumber > 1 ? "yes" : "no")
        }
        self.panel = panel
        panel.onEscape = { [weak self] in self?.dismiss(.escape) }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.processIdentifier == getpid() ? nil : frontmost
        installSessionWatchers(on: panel, finalFrame: canvas)
        morphOpen(panel)
        panel.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        setState(.selecting)
        onOpen?()
        refreshWindows()
    }

    /// Closes the overlay. A docked window goes home (its app hidden, or the window
    /// parked) unless `sendsHome` is false because the person already took it, hid it
    /// or closed it. Focus goes back to the previous app only while the person is
    /// still in the docked app or in Dropy.
    func close(returnsFocus: Bool = true, sendsHome: Bool = true) {
        guard state != .closed else { return }
        let wasDocked = state == .docked
        let wasDocking = state.isDocking
        generation = UUID()
        overlaySession = UUID()
        setState(.closed)
        selectedIdentity = nil
        highlightedIdentity = nil
        selectedWindowSize = nil
        identityTask?.cancel()
        identityTask = nil
        removeSessionWatchers()
        removeDockWatchers()
        dockLayout = nil
        let closingPanel = panel, closingBackdrop = backdrop, closingContent = content, closingWorkspace = workspace
        onClose?()
        panel = nil
        backdrop = nil
        content = nil
        list = nil
        status = nil
        interactionStatus = nil
        privacyButton = nil
        workspace = nil
        overlayScreen = nil
        // The last frame stays on screen while the content fades and the outline
        // collapses; clearing it at once blanked the preview mid-close.
        let closingRenderer = renderer
        renderer = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(OverlayMotion.wall(NotchMorph.close.duration)))
            closingRenderer?.clear()
        }
        Task { await capture.stop(reason: "closed") }
        let previous = previousApplication
        previousApplication = nil
        guard let closingPanel else { return }
        guard wasDocking, dock.current != nil else {
            morphClosed(closingPanel, backdrop: closingBackdrop, content: closingContent)
            // Hand focus back to the app that was in front before the overlay opened.
            if NSApplication.shared.isActive, let previous, !previous.isTerminated { previous.activate() }
            return
        }
        closingPanel.ignoresMouseEvents = true
        let dropyActive = NSApplication.shared.isActive
        Task { @MainActor [weak self] in
            guard let self else { return }
            let source = self.dock.current?.identity.processID
            if sendsHome {
                // A fresh picture of the window covers its place while it leaves.
                if wasDocked { await self.dock.refreshSnapshot(timeout: .milliseconds(150)) }
                closingWorkspace?.snapshot.layer?.contents = self.dock.current?.snapshot
                closingWorkspace?.coversWindow = true
                closingWorkspace?.layoutSubtreeIfNeeded()
            }
            closingBackdrop?.hole = nil
            if sendsHome { await self.dock.sendHome() }
            self.morphClosed(closingPanel, backdrop: closingBackdrop, content: closingContent)
            guard returnsFocus else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard dropyActive || front == source || front == getpid() else { return }
            if let previous, !previous.isTerminated, previous.processIdentifier != source {
                WindowDock.activateApplication(previous.processIdentifier)
            } else if self.dock.current?.home == .park,
                      let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                // A parked window's app would otherwise keep the keyboard with nothing on screen.
                WindowDock.activateApplication(finder.processIdentifier)
            }
        }
    }

    /// Puts a docked window back where the person had it, for quitting.
    func shutdown() {
        dock.releaseNow()
        close(returnsFocus: false, sendsHome: false)
    }

    // MARK: Morph

    /// The camera housing's size, from the menu-bar areas either side of it.
    private static func notchSize(on screen: NSScreen) -> CGSize? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX, screen.safeAreaInsets.top > 0 else { return nil }
        return CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }

    /// Where the outline starts and ends: the notch, or on a screen without one a
    /// menu-bar-high pill that fades as it grows.
    private func closedShape(in canvas: CGSize) -> NotchShape {
        NotchShape.notch(size: notchSize ?? CGSize(width: 180, height: NSStatusBar.system.thickness), in: canvas)
    }

    /// Grows the outline out of the notch with a spring, then brings the content in.
    private func morphOpen(_ panel: OverlayPanel) {
        guard let backdrop, let content else { return }
        let canvas = backdrop.bounds.size
        let open = NotchShape.open(body: content.frame)
        if OverlayMotion.reduced {
            backdrop.set(open)
            settlesAt = Date()
        } else {
            let duration = backdrop.morph(from: closedShape(in: canvas), to: open, motion: NotchMorph.open,
                                          clipping: content)
            settlesAt = Date().addingTimeInterval(OverlayMotion.wall(duration))
        }
        OverlayMotion.revealContent(content)
        // Without a notch to grow from, the whole overlay also fades in.
        if notchSize == nil || OverlayMotion.reduced {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = OverlayMotion.wall(OverlayMotion.reduced ? 0.2 : 0.25)
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Blurs the content away, collapses the outline into the notch (height first,
    /// then width) and melts it in over the last frames. The panel
    /// stops taking clicks at once and leaves the screen when the outline settles.
    /// A new opening during this builds its own panel.
    private func morphClosed(_ panel: OverlayPanel, backdrop: MorphBackdropView?, content: NSView?) {
        panel.ignoresMouseEvents = true
        guard let backdrop, let content, !OverlayMotion.reduced else {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15
                panel.animator().alphaValue = 0 }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.15))
                panel.orderOut(nil)
            }
            return
        }
        let canvas = backdrop.bounds.size
        OverlayMotion.hideContent(content)
        // Start from where the outline is on screen, even mid-opening or mid-resize.
        let duration = backdrop.morph(from: backdrop.visibleShape ?? .open(body: content.frame),
                                      to: closedShape(in: canvas), motion: NotchMorph.close, clipping: content)
        // The last stretch fades, so the outline melts into the notch; without a notch
        // there is nothing to merge with, so it fades throughout.
        let fadeStart = notchSize == nil ? 0 : duration * 0.55
        OverlayMotion.fadeOut(panel, after: fadeStart, over: duration - fadeStart)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(OverlayMotion.wall(duration)))
            panel.orderOut(nil)
        }
    }

    // MARK: Dismissal while open
    //
    // These watchers exist only while the overlay is open, so a closed overlay
    // still costs nothing.

    private func installSessionWatchers(on panel: OverlayPanel, finalFrame: CGRect) {
        removeSessionWatchers()
        // Global monitors see only other apps' events, so any click they report is
        // outside Dropy's panel.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                           handler: { [weak self] _ in
            self?.dismiss(.clickOutside)
        }) { sessionMonitors.append(monitor) }
        // Other Dropy windows (including the status menu) are invisible to the
        // global monitor. Keep those events flowing after checking the panel.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self, weak panel] event in
            if let panel, event.window !== panel { self?.dismiss(.clickOutside) }
            return event
        }) { sessionMonitors.append(monitor) }
        // Pointer-leave arms only once the pointer has been inside, so opening from
        // the menu or the shortcut with the pointer elsewhere does not close at once.
        pointerHasEntered = finalFrame.contains(NSEvent.mouseLocation)
        // The root view owns the tracking area and overrides the NSResponder methods.
        // With this controller as owner, Swift exported `mouseEntered(with:)` as
        // `mouseEnteredWith:`, AppKit never called it, and pointer-leave never closed.
        if let root = panel.contentView as? PointerTrackingView {
            root.onEntered = { [weak self] in self?.pointerEntered() }
            root.onExited = { [weak self] in self?.pointerExited() }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: root)
            root.addTrackingArea(area)
            trackingArea = area
        }
    }

    private func removeSessionWatchers() {
        sessionMonitors.forEach(NSEvent.removeMonitor)
        sessionMonitors = []
        if let trackingArea { panel?.contentView?.removeTrackingArea(trackingArea) }
        trackingArea = nil
        pendingPointerLeave?.cancel()
        pendingPointerLeave = nil
        pointerHasEntered = false
    }

    private func pointerEntered() {
        if !pointerHasEntered { NSLog("Dropy dismiss: pointer entered") }
        pointerHasEntered = true
        pendingPointerLeave?.cancel()
        pendingPointerLeave = nil
    }

    private func pointerExited() {
        NSLog("Dropy dismiss: pointer left (armed=%@)", pointerHasEntered ? "yes" : "no")
        guard pointerHasEntered, preferences.value.dismissBehavior.closes(on: .pointerLeft) else { return }
        pendingPointerLeave?.cancel()
        let session = overlaySession
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.overlaySession == session, let panel = self.panel,
                  !panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.dismiss(.pointerLeft)
        }
        pendingPointerLeave = work
        // Never mid-opening: an overlay that closes while it is still growing looks
        // broken. The check then runs on where the pointer is once it has settled.
        let wait = max(DismissBehavior.pointerLeaveGrace, settlesAt.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Person-initiated refresh: reload the list and leave any failure state.
    func refreshWindows() {
        guard state != .closed else { return }
        let request = generation
        let shouldAutoSelect = state == .selecting
        if !hasSelection { status?.stringValue = "Finding open windows…" }
        Task {
            do {
                let windows = try await WindowCatalog.availableWindows()
                guard request == generation, state != .closed else { return }
                available = windows
                rebuildWindowList()
                guard !hasSelection else { return }
                setState(.selecting)
                let preferredBundleID = preferences.value.openTargetBundleIdentifier
                if shouldAutoSelect,
                   let requested = ProcessInfo.processInfo.environment["DROPY_DEBUG_WINDOW_ID"],
                   let windowID = UInt32(requested) {
                    if let index = windows.firstIndex(where: { $0.window.windowID == windowID && $0.bundleIdentifier == preferredBundleID }) {
                        selectWindow(at: index)
                    } else {
                        NSLog("Dropy device check: requested exact window unavailable")
                    }
                } else if shouldAutoSelect, let pinned = preferences.value.pinnedBundleIdentifier {
                    showPinnedApp(pinned, request: request)
                } else if shouldAutoSelect, let bundleID = preferredBundleID,
                   let index = windows.firstIndex(where: { $0.bundleIdentifier == bundleID }) {
                    selectWindow(at: index)
                }
                if shouldAutoSelect { startDebugAlternationIfRequested() }
            } catch {
                guard request == generation, state != .closed, !hasSelection else { return }
                let failure = catalogFailure(for: error)
                setState(.failed(failure))
                // Ask once per launch so macOS lists Dropy under Screen Recording and
                // shows its own prompt; without a request the app never appears there.
                if failure == .permissionDenied, !requestedScreenCaptureAccess {
                    requestedScreenCaptureAccess = true
                    _ = CGRequestScreenCaptureAccess()
                }
            }
        }
    }

    /// Shows the pinned app's window, launching the app or asking it for a window
    /// first. Stops as soon as anything else happens: a selection, a close, a refresh.
    private func showPinnedApp(_ bundleID: String, request: UUID) {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? bundleID
        Task {
            var asked = false
            let started = Date()
            while request == generation, state == .selecting {
                let index = available.firstIndex { $0.bundleIdentifier == bundleID }
                switch PinnedAppPlan.next(installed: url != nil, hasWindow: index != nil, asked: asked,
                                          waited: Date().timeIntervalSince(started)) {
                case .select:
                    if let index { selectWindow(at: index) }
                    return
                case .open:
                    guard let url else { return }
                    asked = true
                    let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
                    status?.stringValue = running ? "Asking \(name) for a window…" : "Opening \(name)…"
                    NSLog("Dropy pinned app: %@ running=%@", running ? "reopen" : "launch", running ? "yes" : "no")
                    // Not activated: the overlay keeps focus. For a running app this is
                    // the Dock-icon request, which opens a window if it has none.
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                case .wait:
                    break
                case .giveUp(let problem):
                    NSLog("Dropy pinned app: gave up %@", String(describing: problem))
                    status?.stringValue = problem.message(appName: name)
                    return
                }
                try? await Task.sleep(for: .seconds(PinnedAppPlan.pollInterval))
                guard request == generation, state == .selecting,
                      let windows = try? await WindowCatalog.availableWindows(),
                      request == generation, state == .selecting else { return }
                available = windows
                rebuildWindowList()
            }
        }
    }

    /// Repopulate the list after a failure without replacing the failure message,
    /// so the person can make an explicit new choice.
    private func reloadListKeepingState() {
        let request = generation
        Task {
            guard let windows = try? await WindowCatalog.availableWindows(),
                  request == generation, state.failure != nil else { return }
            available = windows
            rebuildWindowList()
        }
    }

    private func setState(_ next: CapturePhase) {
        if next != state { NSLog("Dropy state: %@", next.diagnosticName) }
        state = next
        switch next {
        case .closed: break
        case .selecting:
            status?.stringValue = available.isEmpty
                ? "No open windows. Open an app, then use the window menu."
                : "Choose a window"
        default:
            status?.stringValue = next.message ?? ""
        }
        privacyButton?.isHidden = next.failure?.opensPrivacySettings != true
        // Closing keeps the layout it had: switching to the window list here flashed
        // the list inside the outline as it collapsed.
        if next != .closed {
            workspace?.showsPreview = next.isCapturing
            workspace?.docked = next.isDocking
            workspace?.elsewhere.isHidden = { if case .dockedElsewhere = next { false } else { true } }()
            renderer?.isHidden = next.isDocking
            status?.isHidden = next == .viewing || next == .docked || { if case .docking = next { true } else { false } }()
        }
        workspace?.needsLayout = true
    }

    /// A window is chosen: being previewed or docked.
    private var hasSelection: Bool { state.isCapturing || state.isDocking }

    private func buildContent(in panel: NSPanel, size: CGSize) {
        let root = PointerTrackingView(frame: CGRect(origin: .zero, size: panel.frame.size))
        root.wantsLayer = true
        root.layer?.speed = Float(1 / OverlayMotion.slowdown)
        panel.contentView = root
        let backdrop = MorphBackdropView(frame: root.bounds)
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)
        self.backdrop = backdrop
        let workspace = OverlayWorkspaceView(frame: CGRect(x: (root.bounds.width - size.width) / 2,
            y: root.bounds.height - size.height, width: size.width, height: size.height))
        root.addSubview(workspace)
        self.workspace = workspace
        content = workspace
        list = workspace.windowList
        status = workspace.status
        interactionStatus = workspace.interaction
        privacyButton = workspace.privacy
        workspace.privacy.target = self
        workspace.privacy.action = #selector(privacyClicked)
        workspace.expand.target = self
        workspace.expand.action = #selector(expandClicked)
        workspace.elsewhere.target = self
        workspace.elsewhere.action = #selector(goToDockedDesktop)
        workspace.previewRect = WorkspaceLayout.preview(in: size, notch: notchSize ?? CGSize(width: 180, height: 32))
        workspace.needsLayout = true
        workspace.layoutSubtreeIfNeeded()
        do {
            let view = try MetalFrameView.make(frame: workspace.previewShell.bounds)
            view.autoresizingMask = [.width, .height]
            view.contentMode = preferences.value.contentMode
            view.layer?.cornerRadius = 12
            view.layer?.masksToBounds = true
            workspace.previewShell.addSubview(view)
            // The docked window's snapshot draws above the (empty) live preview.
            workspace.previewShell.addSubview(workspace.snapshot)
            renderer = view
        } catch {
            workspace.status.stringValue = "Metal unavailable: \(error.localizedDescription)"
        }
        rebuildWindowList()
        workspace.needsLayout = true
        workspace.layoutSubtreeIfNeeded()
    }

    /// Morphs the overlay to the chosen window's size: the outline springs from where
    /// it is on screen to the new size, the new layout grows into view clipped to it,
    /// and the panel is resized only twice (to cover both sizes, then to fit), never
    /// every animation frame. The existing renderer survives, preserving capture
    /// ownership.
    private func layoutSelectedWindow() {
        guard let source = selectedWindowSize, let screen = overlayScreen, let workspace else { return }
        let layout: WorkspaceLayout
        let preset = preferences.value.sizePreset
        if preferences.value.automaticWindowSize || preset == .nativeSize || expandedPreview {
            layout = WorkspaceLayout.make(source: source, screen: screen.frame.size,
                notch: notchSize ?? CGSize(width: 180, height: 32), expanded: expandedPreview,
                maximumSize: preset.maximumSize)
        } else {
            let size = OverlayGeometry.frame(on: screen.frame, preferredSize: preferences.value.sizePreset.dimensions).size
            layout = WorkspaceLayout(size: size, preview: WorkspaceLayout.preview(in: size,
                notch: notchSize ?? CGSize(width: 180, height: 32)))
        }
        guard workspace.frame.size != layout.size || workspace.previewRect != layout.preview else { return }
        // Hanging from the top edge, centered.
        applyLayout(body: CGRect(x: screen.frame.midX - layout.size.width / 2, y: screen.frame.maxY - layout.size.height,
                                 width: layout.size.width, height: layout.size.height), preview: layout.preview)
    }

    /// The panel's frame around `body`, with room for the outline's overshoot.
    private func canvasFrame(around body: CGRect, on screen: NSScreen) -> CGRect {
        let margin = NotchMorph.overshootMargin(for: body.size)
        return OverlayGeometry.pixelAligned(CGRect(x: body.minX - margin, y: body.minY - margin,
                      width: body.width + 2 * margin, height: body.height + margin), scale: screen.backingScaleFactor)
    }

    /// Moves the overlay's body to `newBody` (screen coordinates) with the preview or
    /// docked window at `preview` inside it, springing the outline there when animated.
    private func applyLayout(body newBody: CGRect, preview: CGRect, animated: Bool = true) {
        guard let screen = overlayScreen, let panel, let workspace, let root = panel.contentView else { return }
        let currentBody = workspace.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        guard currentBody != newBody || workspace.previewRect != preview else { return }
        renderer?.prepareForLayoutChange()
        // Do not leave an old-size animation mask clipping the new viewport.
        workspace.layer?.mask = nil
        let generation = UUID()
        layoutGeneration = generation
        let oldOrigin = panel.frame.origin
        let oldBody = (backdrop?.visibleShape?.body ?? workspace.frame).offsetBy(dx: oldOrigin.x, dy: oldOrigin.y)
        func canvas(around body: CGRect) -> CGRect { canvasFrame(around: body, on: screen) }
        let layout = (preview: preview, size: newBody.size)
        let animate = animated && !OverlayMotion.reduced && backdrop?.visibleShape != nil
        let frame = animate ? canvas(around: oldBody).union(canvas(around: newBody)) : canvas(around: newBody)
        let startShape = backdrop?.visibleShape?.offsetBy(dx: oldOrigin.x - frame.minX, dy: oldOrigin.y - frame.minY)
        place(panel: panel, root: root, workspace: workspace, frame: frame, body: newBody, preview: layout.preview)
        let endShape = NotchShape.open(body: workspace.frame)
        if animate, let backdrop, let startShape {
            let duration = backdrop.morph(from: startShape, to: endShape, motion: NotchMorph.resize, clipping: workspace)
            OverlayMotion.relayoutContent(workspace)
            settlesAt = Date().addingTimeInterval(OverlayMotion.wall(duration))
            // Once settled, shrink the panel to fit; nothing moves on screen.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(OverlayMotion.wall(duration)))
                guard let self, self.layoutGeneration == generation, let panel = self.panel,
                      let root = panel.contentView, let workspace = self.workspace else { return }
                self.place(panel: panel, root: root, workspace: workspace, frame: canvas(around: newBody),
                           body: newBody, preview: layout.preview)
                self.backdrop?.settle(.open(body: workspace.frame))
            }
        } else {
            backdrop?.settle(endShape)
            settlesAt = Date().addingTimeInterval(DismissBehavior.pointerLeaveGrace)
        }
        // A docked window's menus and sheets reach outside the overlay; pointer-leave
        // does not apply to it.
        guard state != .docked else { return }
        pendingPointerLeave?.cancel()
        pendingPointerLeave = nil
        pointerHasEntered = pointerHasEntered || frame.contains(NSEvent.mouseLocation)
        if pointerHasEntered, !frame.contains(NSEvent.mouseLocation) { pointerExited() }
    }

    /// Puts the panel at `frame` (screen) with the workspace at `body` (screen).
    private func place(panel: NSPanel, root: NSView, workspace: OverlayWorkspaceView, frame: CGRect,
                       body: CGRect, preview: CGRect) {
        panel.setFrame(frame, display: false)
        let actual = panel.frame
        root.frame = CGRect(origin: .zero, size: actual.size)
        workspace.frame = body.offsetBy(dx: -actual.minX, dy: -actual.minY)
        workspace.previewRect = preview
        workspace.needsLayout = true
        workspace.layoutSubtreeIfNeeded()
        backdrop?.frame = root.bounds
        if state == .docked { updateHole() }
    }

    @objc private func expandClicked() {
        expandedPreview.toggle()
        // The live-window watcher updates capture resolution without restarting it.
        layoutSelectedWindow()
    }

    func menuWillOpen(_ menu: NSMenu) { refreshWindows() }

    @objc private func menuWindowClicked(_ item: NSMenuItem) {
        guard let identity = item.representedObject as? WindowIdentity,
              let index = available.firstIndex(where: { $0.identity == identity }) else { return }
        selectWindow(at: index)
    }

    private func rebuildWindowList() {
        guard let list, let workspace else { return }
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        let menu = workspace.apps.menu ?? NSMenu()
        menu.removeAllItems()
        menu.delegate = self
        let label = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        label.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Choose a window")
        if let selectedIdentity, let icon = NSRunningApplication(processIdentifier: selectedIdentity.processID)?.icon?.copy() as? NSImage {
            icon.size = CGSize(width: 16, height: 16)
            label.image = icon
        }
        menu.addItem(label)
        for window in available {
            let button = WindowChoiceButton(title: window.displayName, target: self, action: #selector(windowClicked))
            button.frame = CGRect(x: 0, y: 0, width: max(1, workspace.bounds.width - 32), height: 42)
            button.identity = window.identity
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            list.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 42).isActive = true
            let item = NSMenuItem(title: window.displayName, action: #selector(menuWindowClicked), keyEquivalent: "")
            item.target = self
            item.representedObject = window.identity
            item.state = selectedIdentity == window.identity ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Dropy", action: #selector(closeClicked), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)
        workspace.apps.menu = menu
        workspace.needsLayout = true
        applyHighlight()
    }

    /// Development-only exact-window switching driver; does not send input.
    private func startDebugAlternationIfRequested() {
        guard let spec = ProcessInfo.processInfo.environment["DROPY_DEBUG_ALTERNATE"] else { return }
        let parts = spec.split(separator: ",").map(String.init)
        let switches = parts.count > 1 ? max(Int(parts[1]) ?? 40, 1) : 40
        let maxInterval = parts.count > 2 ? max(Int(parts[2]) ?? 150, 0) : 150
        let pair = available.filter { $0.bundleIdentifier == parts.first }.prefix(2).map(\.window.windowID)
        guard pair.count == 2 else {
            NSLog("Dropy debug alternate: fewer than two windows")
            return
        }
        NSLog("Dropy debug alternate: windows=%u,%u switches=%ld", pair[0], pair[1], switches)
        let session = overlaySession
        Task {
            for step in 0..<switches {
                guard session == overlaySession, state != .closed,
                      let index = available.firstIndex(where: { $0.window.windowID == pair[step % 2] })
                else { return }
                selectWindow(at: index)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 0...maxInterval)))
            }
            NSLog("Dropy debug alternate done: expected=%u", pair[(switches - 1) % 2])
            guard parts.count > 3, parts[3] == "close" else { return }
            try? await Task.sleep(for: .seconds(3))
            guard session == overlaySession, state != .closed else { return }
            close()
        }
    }

    private func selectWindow(at index: Int) {
        guard available.indices.contains(index), let renderer else { return }
        let selected = available[index]
        // Choosing the window that is already in the overlay changes nothing.
        if state.isDocking, selected.identity == selectedIdentity, dock.current?.identity == selected.identity { return }
        let request = UUID()
        generation = request
        identityTask?.cancel()
        identityTask = nil
        hideNote()
        selectedIdentity = selected.identity
        selectedWindowSize = selected.window.frame.size
        selectedApplicationName = selected.applicationName
        rebuildWindowList()
        restartedAfterInterruption = false
        if let bundleID = selected.bundleIdentifier {
            preferences.update {
                $0.lastUsedBundleIdentifier = bundleID
                if $0.openBehavior == .direct { $0.selectedBundleIdentifier = bundleID }
            }
        }
        renderer.clear()
        if docksWindows {
            startDocking(selected, request: request)
            return
        }
        if preferences.value.interaction == .fullApp {
            showNote("View only · Allow Accessibility for Dropy in Settings to use apps here")
        }
        startCapture(selected.identity, request: request, renderer: renderer)
    }

    private func isCurrent(_ request: UUID, _ identity: WindowIdentity) -> Bool {
        request == generation && state.isCapturing && selectedIdentity == identity
    }

    /// Latest selection wins, and at most one resolve-and-start runs at a time.
    /// Starting every superseded selection queued dozens of window-list fetches
    /// during rapid switching and delayed the final preview by seconds.
    private func startCapture(_ identity: WindowIdentity, request: UUID, renderer: MetalFrameView) {
        setState(.starting(applicationName: selectedApplicationName))
        pendingStart = PendingStart(identity: identity, request: request, renderer: renderer)
        guard !startInFlight else { return }
        startInFlight = true
        Task {
            while let next = pendingStart {
                pendingStart = nil
                guard isCurrent(next.request, next.identity) else { continue }
                await performStart(next.identity, request: next.request, renderer: next.renderer)
            }
            startInFlight = false
        }
    }

    private func performStart(_ identity: WindowIdentity, request: UUID,
                              renderer: MetalFrameView) async {
        let onStop: @MainActor (Error) -> Void = { [weak self] error in
            self?.captureStopped(error, identity: identity, request: request, renderer: renderer)
        }
        let resolution: WindowResolution
        do {
            resolution = try await WindowCatalog.resolve(identity)
        } catch {
            guard isCurrent(request, identity) else { return }
            await fail(catalogFailure(for: error), request: request)
            return
        }
        guard isCurrent(request, identity) else { return }
        guard case .available(let window) = resolution else {
            await fail(unavailable(resolution), request: request)
            return
        }
        selectedWindowSize = WindowCatalog.presentationFacts(for: window).size
        layoutSelectedWindow()
        do {
            let started = try await capture.start(window: window, renderer: renderer,
                                                  onUnexpectedStop: onStop)
            guard started, isCurrent(request, identity) else { return }
            showVisibility(of: window)
            monitorWindow(identity, request: request, renderer: renderer)
        } catch {
            guard isCurrent(request, identity) else { return }
            let captureFailure = await startFailure(for: error, identity: identity)
            guard isCurrent(request, identity) else { return }
            await fail(captureFailure, request: request)
        }
    }

    /// A window on another display is still available. Report only confirmed
    /// visibility facts, independently of whether capture can deliver frames.
    private func showVisibility(of window: SCWindow) {
        let facts = WindowCatalog.presentationFacts(for: window)
        selectedWindowSize = facts.size
        layoutSelectedWindow()
        setState(facts.visibility == .available ? .viewing
            : .sourceVisibility(applicationName: selectedApplicationName, visibility: facts.visibility))
    }

    private func monitorWindow(_ identity: WindowIdentity, request: UUID,
                               renderer: MetalFrameView) {
        identityTask?.cancel()
        identityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.isCurrent(request, identity) else { return }
                do {
                    let resolution = try await WindowCatalog.resolve(identity)
                    guard !Task.isCancelled, self.isCurrent(request, identity) else { return }
                    guard case .available(let window) = resolution else {
                        await self.fail(self.unavailable(resolution), request: request)
                        return
                    }
                    self.selectedWindowSize = WindowCatalog.presentationFacts(for: window).size
                    self.layoutSelectedWindow()
                    try await self.capture.updateWindow(window, renderer: renderer)
                    guard !Task.isCancelled, self.isCurrent(request, identity) else { return }
                    self.showVisibility(of: window)
                } catch {
                    guard !Task.isCancelled, self.isCurrent(request, identity) else { return }
                    // A failed catalog read does not stop a healthy stream; the
                    // stream delegate reports real stops. Revoked permission does.
                    if case .permissionDenied = self.catalogFailure(for: error) {
                        await self.fail(.permissionDenied, request: request)
                        return
                    }
                    NSLog("Dropy window check failed: code=%ld", (error as NSError).code)
                }
            }
        }
    }

    /// The stream ended without Dropy asking. Re-resolve the exact window to
    /// explain why, and restart once if the same window is still available.
    private func captureStopped(_ error: Error, identity: WindowIdentity, request: UUID,
                                renderer: MetalFrameView) {
        guard isCurrent(request, identity) else { return }
        let nsError = error as NSError
        let kind = CaptureErrorKind.classify(domain: nsError.domain, code: nsError.code)
        Task {
            switch kind {
            case .permissionDenied:
                await fail(.permissionDenied, request: request)
            case .stoppedFromSystemControls:
                await fail(.stoppedFromSystemControls, request: request)
            case .windowListUnavailable:
                await fail(.windowListUnavailable(code: nsError.code), request: request)
            case .sourceMissing, .interrupted:
                let resolution: WindowResolution
                do {
                    resolution = try await WindowCatalog.resolve(identity)
                } catch {
                    guard isCurrent(request, identity) else { return }
                    await fail(catalogFailure(for: error), request: request)
                    return
                }
                guard isCurrent(request, identity) else { return }
                switch resolution {
                case .available:
                    guard !restartedAfterInterruption else {
                        await fail(.streamInterrupted(code: nsError.code), request: request)
                        return
                    }
                    restartedAfterInterruption = true
                    identityTask?.cancel()
                    identityTask = nil
                    startCapture(identity, request: request, renderer: renderer)
                case let gone:
                    await fail(unavailable(gone), request: request)
                }
            }
        }
    }

    private func unavailable(_ resolution: WindowResolution) -> CaptureFailure {
        switch resolution {
        case .processExited: .targetQuit(applicationName: selectedApplicationName)
        case .windowClosed, .available: .sourceWindowClosed(applicationName: selectedApplicationName)
        }
    }

    private func failure(for error: Error) -> CaptureFailure {
        let nsError = error as NSError
        switch CaptureErrorKind.classify(domain: nsError.domain, code: nsError.code) {
        case .permissionDenied: return .permissionDenied
        case .stoppedFromSystemControls: return .stoppedFromSystemControls
        case .windowListUnavailable: return .windowListUnavailable(code: nsError.code)
        case .sourceMissing, .interrupted: return .streamInterrupted(code: nsError.code)
        }
    }

    private func catalogFailure(for error: Error) -> CaptureFailure {
        let nsError = error as NSError
        if CaptureErrorKind.classify(domain: nsError.domain, code: nsError.code) == .permissionDenied {
            return .permissionDenied
        }
        return .windowListUnavailable(code: nsError.code)
    }

    private func startFailure(for error: Error, identity: WindowIdentity) async -> CaptureFailure {
        let nsError = error as NSError
        guard CaptureErrorKind.classify(domain: nsError.domain, code: nsError.code) == .sourceMissing else {
            return failure(for: error)
        }
        do {
            let resolution = try await WindowCatalog.resolve(identity)
            if case .available = resolution { return .streamInterrupted(code: nsError.code) }
            return unavailable(resolution)
        } catch {
            return catalogFailure(for: error)
        }
    }

    /// Every capture failure ends here: invalidate in-flight work, stop the stream,
    /// clear the preview and keep the reason visible. The source app is never
    /// moved or hidden, so it stays reachable through normal macOS controls.
    private func fail(_ failure: CaptureFailure, request: UUID) async {
        guard request == generation, state.isCapturing else { return }
        generation = UUID()
        let failedGeneration = generation
        selectedIdentity = nil
        identityTask?.cancel()
        identityTask = nil
        renderer?.clear()
        setState(.failed(failure))
        await capture.stop(reason: failure.diagnosticName)
        guard generation == failedGeneration else { return }
        renderer?.clear()
        if !failure.opensPrivacySettings { reloadListKeepingState() }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        // A docked app that quits takes its window with it; there is nothing to put back.
        if let docked = dock.current, docked.identity.processID == application.processIdentifier {
            dock.detach()
            if state.isDocking { close(returnsFocus: false, sendsHome: false) }
            return
        }
        guard let identity = selectedIdentity,
              application.processIdentifier == identity.processID,
              application.launchDate == identity.processLaunchDate,
              application.bundleIdentifier == identity.bundleIdentifier else { return }
        let request = generation
        Task { await fail(.targetQuit(applicationName: selectedApplicationName), request: request) }
    }

    /// Keys while the window list is showing.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard state == .selecting else { return false }
        return handlePickerKey(event)
    }

    /// The window list from the keyboard: arrows, Return, 1–9.
    private func handlePickerKey(_ event: NSEvent) -> Bool {
        guard !available.isEmpty,
              let key = PickerKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                  commandControlOrOption: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty)
        else { return false }
        let current = available.firstIndex { $0.identity == highlightedIdentity }
        switch key {
        case .move(let step):
            guard let next = PickerKey.highlight(current, moving: step, count: available.count) else { return true }
            highlightedIdentity = available[next].identity
            applyHighlight(scrolling: true)
        case .choose:
            selectWindow(at: current ?? 0)
        case .row(let index):
            guard available.indices.contains(index) else { return true }
            selectWindow(at: index)
        }
        return true
    }

    /// Tints the highlighted row (the first when none is) and keeps it in view.
    private func applyHighlight(scrolling: Bool = false) {
        guard let list else { return }
        let rows = list.arrangedSubviews.compactMap { $0 as? WindowChoiceButton }
        if !rows.contains(where: { $0.identity == highlightedIdentity }) { highlightedIdentity = rows.first?.identity }
        for row in rows {
            let highlighted = row.identity == highlightedIdentity
            row.bezelColor = highlighted ? .controlAccentColor : nil
            if highlighted, scrolling { row.scrollToVisible(row.bounds) }
        }
    }

    /// A note over the preview until the next selection.
    private func showNote(_ message: String) {
        interactionStatus?.stringValue = message
        interactionStatus?.isHidden = false
    }

    private func hideNote() {
        interactionStatus?.isHidden = true
        interactionStatus?.stringValue = ""
    }

    @objc private func privacyClicked() {
        // Asking through the system registers Dropy's current signature in the
        // Screen Recording list and shows macOS's own prompt. Adding the app by
        // hand with + did not produce a grant that matched on macOS 27.
        if CGRequestScreenCaptureAccess() { return }
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func closeClicked() { close() }

    @objc private func windowClicked(_ button: WindowChoiceButton) {
        guard let identity = button.identity,
              let index = available.firstIndex(where: { $0.identity == identity }) else { return }
        selectWindow(at: index)
    }

    // MARK: Docking the real window
    //
    // Full App interaction: the chosen app's real window moves into the overlay and its
    // app comes to the front, so the person uses it exactly as usual. A snapshot covers
    // the window's place while it moves in and out, so the swap does not show. Nothing
    // streams while the window is in use.

    /// Whether choosing a window docks it rather than previewing it.
    private var docksWindows: Bool {
        preferences.value.interaction == .fullApp && WindowPlacer.isTrusted
    }

    private var mainDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    private var minimumDockWidth: CGFloat {
        DockGeometry.minimumBodyWidth(notch: notchSize ?? CGSize(width: 180, height: 32))
    }

    /// Where the docked window should go for the current size preference.
    private func dockTargetLayout(for docked: WindowDock.Docked, on screen: NSScreen) -> DockLayout {
        let clearance = DockGeometry.clearance(notch: notchSize,
                                               menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
        let size = DockGeometry.windowSize(preset: preferences.value.sizePreset,
                                           adaptsToWindow: preferences.value.automaticWindowSize,
                                           current: dock.originalSize ?? docked.frame.size,
                                           screen: screen.frame, clearance: clearance)
        return DockGeometry.layout(windowSize: size, screen: screen.frame, clearance: clearance,
                                   minimumBodyWidth: minimumDockWidth)
    }

    /// The person chose a window: bring the real one in.
    private func startDocking(_ selected: CapturableWindow, request: UUID) {
        removeDockWatchers()
        backdrop?.hole = nil
        panel?.ignoresMouseEvents = false
        workspace?.coversWindow = true
        setSnapshot(nil)
        setState(.docking(applicationName: selected.applicationName))
        Task { await capture.stop(reason: "docking") }
        Task {
            do {
                try await dock.adopt(selected.window, identity: selected.identity)
            } catch {
                guard isCurrentDock(request) else { return }
                if !WindowDock.isOnActiveSpace(selected.identity.windowID) {
                    // Accessibility may not reach a window on another desktop at all.
                    setState(.dockedElsewhere(applicationName: selected.applicationName))
                    return
                }
                NSLog("Dropy dock: cannot dock (%@); showing the preview", String(describing: error))
                previewInstead(selected.identity, request: request,
                               note: "View only · Dropy could not move this window")
                return
            }
            guard isCurrentDock(request), let docked = dock.current, let screen = overlayScreen else { return }
            guard dock.onActiveSpace else {
                showElsewhere(docked)
                return
            }
            setSnapshot(docked.snapshot, radius: docked.cornerRadius)
            let target = dockTargetLayout(for: docked, on: screen)
            applyLayout(body: target.body, preview: target.windowInBody)
            await finishDocking(request: request, target: target, on: screen)
        }
    }

    /// The fast way back: the window waiting at home already has its size, so the
    /// overlay opens straight to it.
    private func openDockedHome(_ docked: WindowDock.Docked, on screen: NSScreen) {
        generation = UUID()
        overlaySession = UUID()
        overlayScreen = screen
        expandedPreview = false
        notchSize = Self.notchSize(on: screen)
        let target = dockTargetLayout(for: docked, on: screen)
        let canvas = canvasFrame(around: target.body, on: screen)
        let panel = OverlayPanel.make(contentRect: canvas)
        buildContent(in: panel, size: target.body.size)
        self.panel = panel
        if let root = panel.contentView, let workspace {
            place(panel: panel, root: root, workspace: workspace, frame: canvas, body: target.body,
                  preview: target.windowInBody)
        }
        panel.onEscape = { [weak self] in self?.dismiss(.escape) }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = [getpid(), docked.identity.processID].contains(frontmost?.processIdentifier ?? 0)
            ? nil : frontmost
        selectedIdentity = docked.identity
        selectedApplicationName = NSRunningApplication(processIdentifier: docked.identity.processID)?.localizedName
            ?? "The app"
        setState(.docking(applicationName: selectedApplicationName))
        setSnapshot(docked.snapshot, radius: docked.cornerRadius)
        installSessionWatchers(on: panel, finalFrame: canvas)
        morphOpen(panel)
        // Not activated and not key: the docked app takes the keyboard in a moment.
        panel.orderFrontRegardless()
        onOpen?()
        let request = generation
        Task { await finishDocking(request: request, target: target, on: screen) }
        // The switcher menu lists the other windows.
        Task {
            guard let windows = try? await WindowCatalog.availableWindows(), request == generation else { return }
            available = windows
            rebuildWindowList()
        }
    }

    private func isCurrentDock(_ request: UUID) -> Bool { request == generation && state.isDocking }

    /// Places the window once the outline covers its place, brings its app forward and
    /// reveals it.
    private func finishDocking(request: UUID, target: DockLayout, on screen: NSScreen) async {
        // The window moves in only once the outline has grown over its place, so no
        // part of it shows outside the overlay.
        let wait = settlesAt.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard isCurrentDock(request) else { return }
        let placed: CGRect
        do {
            placed = try await dock.place(at: DockGeometry.globalRect(fromAppKit: target.window,
                                                                    mainDisplayHeight: mainDisplayHeight))
        } catch {
            guard isCurrentDock(request), let identity = selectedIdentity else { return }
            NSLog("Dropy dock: cannot place (%@); showing the preview", String(describing: error))
            previewInstead(identity, request: request, note: "View only · Dropy could not move this window")
            return
        }
        // Closed meanwhile: the close sends the window home after this placement.
        guard isCurrentDock(request) else { return }
        let actual = PlacementGeometry.appKitRect(fromGlobal: placed, mainDisplayHeight: mainDisplayHeight)
        let layout = DockGeometry.layout(around: actual, screen: screen.frame, minimumBodyWidth: minimumDockWidth)
        if layout != target { applyLayout(body: layout.body, preview: layout.windowInBody, animated: false) }
        dockLayout = layout
        await dock.activate()
        // A frame for the window server to draw the window where it now is.
        try? await Task.sleep(for: .milliseconds(34))
        guard isCurrentDock(request) else { return }
        reveal()
    }

    /// Cuts the overlay open over the real window and hands it the pointer.
    private func reveal() {
        guard let workspace, let dockLayout else { return }
        setState(.docked)
        updateHole()
        installDockWatchers()
        // The snapshot fades over the identical real window.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = OverlayMotion.reduced ? 0 : 0.12
            workspace.previewShell.animator().alphaValue = 0
        }, completionHandler: { [weak workspace] in
            MainActor.assumeIsolated {
                workspace?.coversWindow = false
                workspace?.previewShell.alphaValue = 1
            }
        })
        NSLog("Dropy dock: live body=%.0fx%.0f", dockLayout.body.width, dockLayout.body.height)
    }

    /// The cut-out in the outline, exactly over the docked window.
    private func updateHole() {
        guard let workspace, let docked = dock.current else {
            backdrop?.hole = nil
            return
        }
        backdrop?.hole = (workspace.previewRect.offsetBy(dx: workspace.frame.minX, dy: workspace.frame.minY),
                          docked.cornerRadius)
    }

    private func setSnapshot(_ image: CGImage?, radius: CGFloat = DockGeometry.defaultCornerRadius) {
        guard let workspace else { return }
        workspace.snapshot.layer?.contents = image
        workspace.snapshot.layer?.contentsScale = overlayScreen?.backingScaleFactor ?? 2
        workspace.previewShell.layer?.cornerRadius = radius
    }

    /// Docking is not possible for this window; show the live preview instead.
    private func previewInstead(_ identity: WindowIdentity, request: UUID, note: String) {
        guard let renderer else { return }
        workspace?.previewShell.layer?.cornerRadius = 12
        startCapture(identity, request: request, renderer: renderer)
        showNote(note)
    }

    /// The window is on another desktop or behind a full-screen app: show what it
    /// last looked like and offer to go there.
    private func showElsewhere(_ docked: WindowDock.Docked) {
        setSnapshot(docked.snapshot, radius: docked.cornerRadius)
        setState(.dockedElsewhere(applicationName: selectedApplicationName))
        workspace?.coversWindow = docked.snapshot != nil
    }

    @objc private func goToDockedDesktop() {
        guard let pid = dock.current?.identity.processID ?? selectedIdentity?.processID else { return }
        close(returnsFocus: false, sendsHome: false)
        Task {
            // Back where the person had it, then macOS switches to its desktop.
            await dock.release()
            WindowDock.activateApplication(pid)
        }
    }

    // MARK: While docked

    private func installDockWatchers() {
        removeSessionWatchers()
        removeDockWatchers()
        panel?.ignoresMouseEvents = true
        // The overlay takes the pointer only over its own outline (the band with the
        // controls and the border); everywhere over the window it lets clicks through.
        for kinds: NSEvent.EventTypeMask in [[.mouseMoved, .leftMouseDragged, .rightMouseDragged]] {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
                self?.updateDockPointer()
            }) { dockMonitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
                self?.updateDockPointer()
                return event
            }) { dockMonitors.append(monitor) }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                           handler: { [weak self] _ in self?.dockedClick() }) {
            dockMonitors.append(monitor)
        }
        updateDockPointer()
    }

    private func removeDockWatchers() {
        dockMonitors.forEach(NSEvent.removeMonitor)
        dockMonitors = []
    }

    private func updateDockPointer() {
        guard state == .docked, let panel, let dockLayout else { return }
        let point = NSEvent.mouseLocation
        let overOutline = dockLayout.body.contains(point) && !dockLayout.window.contains(point)
        if panel.ignoresMouseEvents == overOutline { panel.ignoresMouseEvents = !overOutline }
    }

    /// A click somewhere other than Dropy. Inside the docked app (its window, menus,
    /// sheets, the menu bar, an open panel) it is the person using the app.
    private func dockedClick() {
        guard state == .docked, let dockLayout, let docked = dock.current,
              preferences.value.dismissBehavior != .manual else { return }
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x, y: mainDisplayHeight - location.y)
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows: [DockPolicy.WindowAtPoint] = rows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = (row[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap(CGRect.init(dictionaryRepresentation:)),
                  bounds.contains(point) else { return nil }
            return DockPolicy.WindowAtPoint(processID: pid, bounds: bounds,
                                            layer: row[kCGWindowLayer as String] as? Int ?? 0,
                                            bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        }
        let body = DockGeometry.globalRect(fromAppKit: dockLayout.body, mainDisplayHeight: mainDisplayHeight)
        guard !DockPolicy.clickIsInside(point: point, body: body, windows: windows, ownProcessID: getpid(),
                                        sourceProcessID: docked.identity.processID) else { return }
        NSLog("Dropy dismiss: click outside the docked app")
        close(returnsFocus: false)
    }

    /// Another app came to the front: its windows would rise over the docked one, so
    /// the overlay closes. With the overlay closed, the docked app coming to the front
    /// (Command-Tab, its Dock icon) opens the overlay around it.
    private func applicationActivated(pid: pid_t, bundleIdentifier: String?) {
        guard let docked = dock.current else { return }
        if state == .closed {
            if docked.home == .hideApp, pid == docked.identity.processID, docksWindows {
                NSLog("Dropy dock: app brought forward; opening around it")
                open(resumingHome: true)
            }
            return
        }
        guard state.isDocking, DockPolicy.activationCloses(processID: pid, bundleIdentifier: bundleIdentifier,
                                                           sourceProcessID: docked.identity.processID,
                                                           ownProcessID: getpid()) else { return }
        NSLog("Dropy dismiss: switched to another app")
        close(returnsFocus: false)
    }

    private func handleDockEvent(_ event: WindowDock.Event) {
        switch event {
        case .resized(let frame):
            guard state == .docked, let screen = overlayScreen else { return }
            let actual = PlacementGeometry.appKitRect(fromGlobal: frame, mainDisplayHeight: mainDisplayHeight)
            let layout = DockGeometry.layout(around: actual, screen: screen.frame, minimumBodyWidth: minimumDockWidth)
            dockLayout = layout
            applyLayout(body: layout.body, preview: layout.windowInBody, animated: false)
            updateHole()
        case .detached, .minimized, .closed:
            NSLog("Dropy dock: the person took the window (%@)", String(describing: event))
            dock.detach()
            if state.isDocking { close(returnsFocus: false, sendsHome: false) }
        case .appHidden:
            dock.markHiddenByPerson()
            if state.isDocking { close(returnsFocus: false, sendsHome: false) }
        }
    }

    /// Preferences changed in a way that affects a docked window.
    func dockingPreferencesChanged() {
        let target = preferences.value.openTargetBundleIdentifier
        guard let docked = dock.current else { return }
        if preferences.value.interaction == .previewOnly {
            if state.isDocking { close(returnsFocus: false) }
            Task { await dock.release() }
        } else if state == .closed, target != docked.identity.bundleIdentifier {
            Task { await dock.release() }
        }
    }

    /// The placement journal was settled elsewhere (recovery, a parking tab).
    func journalChanged() {
        dock.journalChanged()
    }
}
