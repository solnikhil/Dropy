import AppKit
import DropyCore
import ScreenCaptureKit

/// The overlay that grows from the notch. It owns the panel, its outline and layout,
/// the window list and dismissal, and hands the chosen window to a session: the live
/// preview (`PreviewSession`) or the docked real window (`NativeSession`), as
/// `SessionModePolicy` decides.
@MainActor
final class OverlayController: NSObject, NSMenuDelegate, OverlaySessionHost {
    let preferences: PreferenceStore
    private let stage: Stage?
    private var preview: PreviewSession!
    private var native: NativeSession!
    /// Over a full-screen app: the window stays on the Stage and is streamed.
    private var live: LiveSession?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Size in points of the window being shown.
    var selectedWindowSize: CGSize?
    /// A short note over the preview, e.g. why it is view only.
    private var interactionStatus: NSTextField?
    private(set) var panel: OverlayPanel?
    private var list: NSStackView?
    private var status: NSTextField?
    private var privacyButton: NSButton?
    private(set) var workspace: OverlayWorkspaceView?
    private(set) var overlayScreen: NSScreen?
    private var expandedPreview = false
    /// Changes with every layout change; a resize finishing later leaves a newer one alone.
    private var layoutGeneration = UUID()
    /// The black outline that morphs out of the notch, and the content it reveals.
    private(set) var backdrop: MorphBackdropView?
    private var content: NSView?
    /// The camera housing the overlay grows from; nil on a screen without one.
    private(set) var notchSize: CGSize?
    /// Called when opening so notch affordances release their input ownership.
    var onOpen: (() -> Void)?
    /// Called whenever the overlay closes, so the notch trigger can stay quiet.
    var onClose: (() -> Void)?
    /// When the opening morph finishes; pointer-leave does not close before then.
    private(set) var settlesAt = Date.distantPast
    private(set) var renderer: MetalFrameView?
    private var available: [CapturableWindow] = []
    var selectedIdentity: WindowIdentity?
    /// The window-list row Return opens; the first row until the arrows move it.
    private var highlightedIdentity: WindowIdentity?
    private(set) var selectedApplicationName = ""
    private var overlaySession = UUID()
    private var opensInProcess = 0
    private var requestedScreenCaptureAccess = false
    /// Changes on open, close, every selection and every failure. Async work
    /// continues only while its captured generation is still current.
    var generation = UUID()
    private(set) var state: CapturePhase = .closed
    private var sessionMonitors: [Any] = []
    private var trackingArea: NSTrackingArea?
    private var pointerHasEntered = false
    private var pendingPointerLeave: DispatchWorkItem?
    private var previousApplication: NSRunningApplication?

    /// The exact window being previewed, for development drivers.
    var currentSelection: WindowIdentity? { selectedIdentity }
    func captureCounts() -> CaptureCounts? { preview.captureCounts() }

    init(preferences: PreferenceStore, journal: PlacementJournal, stage: Stage?) {
        self.preferences = preferences
        self.stage = stage
        super.init()
        preview = PreviewSession(host: self)
        native = NativeSession(host: self, journal: journal, stage: stage)
        if let stage { live = LiveSession(host: self, native: native, stage: stage) }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = application?.processIdentifier ?? 0
            let bundleID = application?.bundleIdentifier
            MainActor.assumeIsolated { self?.native.applicationActivated(pid: pid, bundleIdentifier: bundleID) }
        })
        // The overlay shows on every desktop, but a docked window stays on the one it
        // was docked on: switching desktops would leave an empty frame. Close instead.
        // Only while docking: opening Dropy itself can switch desktops (its Settings
        // window may be on another one), and the window list or preview is fine there.
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isDocking else { return }
                NSLog("Dropy dismiss: switched desktops")
                self.close(returnsFocus: false)
            }
        })
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    /// Called when a docked window's restore could not finish yet.
    var onDeferredRestore: ((WindowIdentity) -> Void)? {
        get { native.onDeferredRestore }
        set { native.onDeferredRestore = newValue }
    }

    func toggle() {
        state == .closed ? open() : close()
    }

    /// Closes the overlay if the dismiss preference treats `event` as an exit.
    func dismiss(_ event: DismissEvent) {
        guard state != .closed, preferences.value.dismissBehavior.closes(on: event) else { return }
        close()
    }

    func open() {
        guard state == .closed else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
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

    /// Closes the overlay. A docked window goes back where the person had it, unless
    /// `putsBack` is false because they already took it, hid it or closed it. Focus
    /// goes back to the previous app only while the person is still in the docked app
    /// or in Dropy.
    func close(returnsFocus: Bool = true, putsBack: Bool = true) {
        guard state != .closed else { return }
        let wasDocked = state == .docked
        let wasDocking = state.isDocking
        generation = UUID()
        overlaySession = UUID()
        setState(.closed)
        selectedIdentity = nil
        highlightedIdentity = nil
        selectedWindowSize = nil
        preview.cancelMonitoring()
        removeSessionWatchers()
        native.end()
        live?.end()
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
        preview.stop(reason: "closed")
        let previous = previousApplication
        previousApplication = nil
        guard let closingPanel else { return }
        if wasDocking, native.close(panel: closingPanel, backdrop: closingBackdrop, content: closingContent,
                                    workspace: closingWorkspace, wasDocked: wasDocked, putsBack: putsBack,
                                    returnsFocus: returnsFocus, previous: previous) {
            return
        }
        morphClosed(closingPanel, backdrop: closingBackdrop, content: closingContent)
        // Hand focus back to the app that was in front before the overlay opened.
        if NSApplication.shared.isActive, let previous, !previous.isTerminated { previous.activate() }
    }

    /// Puts a docked window back where the person had it, for quitting.
    func shutdown() {
        native.releaseNow()
        close(returnsFocus: false, putsBack: false)
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
    func morphClosed(_ panel: OverlayPanel, backdrop: MorphBackdropView?, content: NSView?) {
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

    func removeSessionWatchers() {
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
                let failure = PreviewSession.catalogFailure(for: error)
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
    func reloadListKeepingState() {
        let request = generation
        Task {
            guard let windows = try? await WindowCatalog.availableWindows(),
                  request == generation, state.failure != nil else { return }
            available = windows
            rebuildWindowList()
        }
    }

    func setState(_ next: CapturePhase) {
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
            // Live streams into the preview area; the other docking states show the real window.
            workspace?.showsPreview = next.isCapturing || next == .live
            workspace?.docked = next.isDocking && next != .live
            workspace?.elsewhere.isHidden = { if case .dockedElsewhere = next { false } else { true } }()
            renderer?.isHidden = next.isDocking && next != .live
            status?.isHidden = next == .viewing || next == .docked || next == .live
                || { if case .docking = next { true } else { false } }()
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
        workspace.elsewhere.target = native
        workspace.elsewhere.action = #selector(NativeSession.goToDockedDesktop)
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
    func layoutSelectedWindow() {
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
    func applyLayout(body newBody: CGRect, preview: CGRect, animated: Bool = true) {
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
        if state == .docked { native.updateHole() }
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
        if state.isDocking, selected.identity == selectedIdentity, native.dockedIdentity == selected.identity { return }
        let request = UUID()
        generation = request
        preview.reset()
        hideNote()
        selectedIdentity = selected.identity
        selectedWindowSize = selected.window.frame.size
        selectedApplicationName = selected.applicationName
        rebuildWindowList()
        if let bundleID = selected.bundleIdentifier {
            preferences.update {
                $0.lastUsedBundleIdentifier = bundleID
                if $0.openBehavior == .direct { $0.selectedBundleIdentifier = bundleID }
            }
        }
        renderer.clear()
        let conditions = sessionConditions
        switch SessionModePolicy.mode(for: conditions) {
        case .native:
            preview.stop(reason: "docking")
            live?.end()
            native.start(selected, request: request)
        case .live:
            preview.stop(reason: "live")
            native.end()
            if let live { live.start(selected, request: request) } else { fallThroughToPreview(selected, request, conditions) }
        case .preview:
            fallThroughToPreview(selected, request, conditions)
        }
    }

    private func fallThroughToPreview(_ selected: CapturableWindow, _ request: UUID, _ conditions: SessionConditions) {
        guard let renderer else { return }
        native.end()
        live?.end()
        if let note = SessionModePolicy.previewNote(for: conditions) { showNote(note) }
        preview.start(selected.identity, request: request, renderer: renderer)
    }

    /// What decides how a chosen window is shown: Live over another app's full-screen
    /// space (with the Stage), the real window otherwise.
    private var sessionConditions: SessionConditions {
        let display = (overlayScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
        return SessionConditions(interaction: preferences.value.interaction, accessibilityTrusted: WindowPlacer.isTrusted,
                                 fullScreenInFront: Spaces.currentIsFullScreen(on: display),
                                 stageAvailable: stage != nil && !Spaces.displaysShareSpaces)
    }

    /// Docking is not possible for this window; show the live preview instead.
    func showPreviewInstead(of identity: WindowIdentity, request: UUID, note: String) {
        guard let renderer else { return }
        native.end()
        live?.end()
        workspace?.previewShell.layer?.cornerRadius = 12
        preview.start(identity, request: request, renderer: renderer)
        showNote(note)
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        // A docked app that quits takes its window with it; there is nothing to put back.
        if native.applicationTerminated(pid: application.processIdentifier) { return }
        guard let identity = selectedIdentity,
              application.processIdentifier == identity.processID,
              application.launchDate == identity.processLaunchDate,
              application.bundleIdentifier == identity.bundleIdentifier else { return }
        preview.targetQuit()
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
    func showNote(_ message: String) {
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

    /// Switching to Preview only puts a docked window back.
    func dockingPreferencesChanged() { native.preferencesChanged() }

    /// The placement journal was settled elsewhere (recovery restored the window).
    func journalChanged() { native.journalChanged() }

    /// The pinned app changed.
    func pinnedAppChanged() { native.pinnedAppChanged() }

    /// The Stage ended unexpectedly.
    func stageLost() { native.stageLost() }
}
