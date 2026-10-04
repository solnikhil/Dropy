import AppKit
import Carbon.HIToolbox
import DropyCore
import ScreenCaptureKit

@MainActor
final class OverlayController: NSObject, NSMenuDelegate {
    private let preferences: PreferenceStore
    private let inputRouter: InputRouter
    private let capture = CaptureController()
    /// Size in points of the window being previewed, for mapping preview input.
    private var selectedWindowSize: CGSize?
    private var interactionStatus: NSTextField?
    private var interactionMessage: DispatchWorkItem?
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
    /// Key composition state (a pending dead key); reset whenever the target window is.
    private var keyInput = PreviewKeyInput()
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

    init(preferences: PreferenceStore, inputRouter: InputRouter) {
        self.preferences = preferences
        self.inputRouter = inputRouter
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

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

    func close() {
        guard state != .closed else { return }
        generation = UUID()
        overlaySession = UUID()
        setState(.closed)
        if let selectedIdentity { inputRouter.forget(selectedIdentity) }
        keyInput = PreviewKeyInput()
        selectedIdentity = nil
        selectedWindowSize = nil
        identityTask?.cancel()
        identityTask = nil
        removeSessionWatchers()
        if let panel { morphClosed(panel) }
        onClose?()
        panel = nil
        backdrop = nil
        content = nil
        list = nil
        status = nil
        interactionStatus = nil
        interactionMessage?.cancel()
        interactionMessage = nil
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
        // Hand focus back to the app that was in front before the overlay opened.
        if NSApplication.shared.isActive, let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate()
        }
        previousApplication = nil
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
    private func morphClosed(_ panel: OverlayPanel) {
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
        if !state.isCapturing { status?.stringValue = "Finding open windows…" }
        Task {
            do {
                let windows = try await WindowCatalog.availableWindows()
                guard request == generation, state != .closed else { return }
                available = windows
                rebuildWindowList()
                guard !state.isCapturing else { return }
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
                guard request == generation, state != .closed, !state.isCapturing else { return }
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
            status?.isHidden = next == .viewing
        }
        workspace?.needsLayout = true
        if !next.isCapturing { configureInteraction() }
    }

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
        guard let source = selectedWindowSize, let screen = overlayScreen,
              let panel, let workspace, let root = panel.contentView else { return }
        let layout: WorkspaceLayout
        let preset = preferences.value.sizePreset
        if preferences.value.automaticWindowSize || preset == .trueSize || expandedPreview {
            layout = WorkspaceLayout.make(source: source, screen: screen.frame.size,
                notch: notchSize ?? CGSize(width: 180, height: 32), expanded: expandedPreview,
                maximumSize: preset.maximumSize)
        } else {
            let size = OverlayGeometry.frame(on: screen.frame, preferredSize: preferences.value.sizePreset.dimensions).size
            layout = WorkspaceLayout(size: size, preview: WorkspaceLayout.preview(in: size,
                notch: notchSize ?? CGSize(width: 180, height: 32)))
        }
        guard workspace.frame.size != layout.size || workspace.previewRect != layout.preview else { return }
        renderer?.prepareForLayoutChange()
        // Do not leave an old-size animation mask clipping the new viewport.
        workspace.layer?.mask = nil
        let generation = UUID()
        layoutGeneration = generation
        // Both bodies in screen coordinates, hanging from the top edge, centered.
        let oldOrigin = panel.frame.origin
        let oldBody = (backdrop?.visibleShape?.body ?? workspace.frame).offsetBy(dx: oldOrigin.x, dy: oldOrigin.y)
        let newBody = CGRect(x: screen.frame.midX - layout.size.width / 2, y: screen.frame.maxY - layout.size.height,
                             width: layout.size.width, height: layout.size.height)
        // Workspace sizes can be smaller than the general picker minimum.
        func canvas(around body: CGRect) -> CGRect {
            let margin = NotchMorph.overshootMargin(for: body.size)
            return OverlayGeometry.pixelAligned(CGRect(x: body.minX - margin, y: body.minY - margin,
                          width: body.width + 2 * margin, height: body.height + margin), scale: screen.backingScaleFactor)
        }
        let animate = !OverlayMotion.reduced && backdrop?.visibleShape != nil
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
    }

    @objc private func expandClicked() {
        expandedPreview.toggle()
        layoutSelectedWindow()
        // The live-window watcher updates capture resolution without restarting it.
        configureInteraction()
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
        let request = UUID()
        generation = request
        identityTask?.cancel()
        identityTask = nil
        if let previous = selectedIdentity { inputRouter.forget(previous) }
        keyInput = PreviewKeyInput()
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
        configureInteraction()
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
        if let selectedIdentity { inputRouter.forget(selectedIdentity) }
        keyInput = PreviewKeyInput()
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
                as? NSRunningApplication,
              let identity = selectedIdentity,
              application.processIdentifier == identity.processID,
              application.launchDate == identity.processLaunchDate,
              application.bundleIdentifier == identity.bundleIdentifier else { return }
        let request = generation
        Task { await fail(.targetQuit(applicationName: selectedApplicationName), request: request) }
    }

    // MARK: Interactive preview (M3 prototype)

    /// Connects or disconnects preview input for the current source, and labels what is
    /// verified. Runs on selection, visibility changes and every identity check, because
    /// the source's condition (parked, minimized, other desktop) can change.
    func configureInteraction() {
        guard let renderer else { return }
        if interactionMessage == nil {
            interactionStatus?.isHidden = true
            interactionStatus?.stringValue = ""
        }
        let enabled = preferences.value.interactivePreview
        let trusted = WindowPlacer.isTrusted
        guard enabled, trusted, state.isCapturing, let identity = selectedIdentity else {
            renderer.onClick = nil
            renderer.onScroll = nil
            renderer.onUnsupported = nil
            return
        }
        let support = inputRouter.support(for: identity)
        inputRouter.prepare(identity)
        if renderer.onClick == nil, let window = renderer.window {
            // Where the preview is, for device checks: global top-left points.
            let frame = window.convertToScreen(renderer.convert(renderer.bounds, to: nil))
            let top = (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY
            NSLog("Dropy input: preview=%.0f,%.0f,%.0f,%.0f support=%@", frame.minX, top, frame.width, frame.height,
                  InteractionLabel.text(for: support, enabled: true, trusted: true))
        }
        // Each event re-checks that the drawn frame is this selection's window at its
        // current size; the router then confirms that size against the live window.
        renderer.onClick = { [weak self] point in
            guard let self, let mapping = self.mapping(for: identity, kind: .pointerClick),
                  let target = mapping.windowPoint(for: point) else { return }
            self.report(self.inputRouter.click(identity, at: target, expectedWindowSize: mapping.windowSize), kind: .pointerClick)
        }
        renderer.onScroll = { [weak self] point, delta in
            guard let self, let mapping = self.mapping(for: identity, kind: .scroll),
                  let target = mapping.windowPoint(for: point) else { return }
            self.report(self.inputRouter.scroll(identity, at: target, delta: mapping.windowDelta(for: delta),
                                                expectedWindowSize: mapping.windowSize), kind: .scroll)
        }
        renderer.onUnsupported = { [weak self] kind in self?.flash(InteractionLabel.text(for: .notVerified, kind: kind)) }
    }

    /// The mapping through the frame actually drawn, or nil (with a visible reason)
    /// when that frame cannot be tied to this selection's window at its current size:
    /// after a switch, before the first frame, or while the source is being resized.
    private func mapping(for identity: WindowIdentity, kind: InputKind) -> PreviewPointMapping? {
        guard let renderer else { return nil }
        let frame = renderer.presentedFrame
        switch PreviewInputGate.check(handler: identity, selected: selectedIdentity, frame: frame,
                                      sourceWindowSize: selectedWindowSize) {
        case .failure(let refusal):
            NSLog("Dropy input: kind=%@ gate=%@", kind.rawValue, String(describing: refusal))
            flash(refusal == .sourceChanged || refusal == .frameFromOtherWindow
                  ? "Switching windows · input not sent" : "Preview updating · input not sent")
            return nil
        case .success(let windowSize):
            guard let pixels = frame?.pixelSize else { return nil }
            return PreviewPointMapping(viewSize: renderer.bounds.size,
                                       backingScale: renderer.window?.backingScaleFactor ?? 2,
                                       capturePixelSize: pixels, windowSize: windowSize,
                                       mode: preferences.value.contentMode)
        }
    }

    /// Typing in the preview: committed characters only. Shortcuts, editing keys and
    /// input methods are refused and labelled rather than approximated.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard preferences.value.interactivePreview, WindowPlacer.isTrusted, state.isCapturing,
              let identity = selectedIdentity else { return false }
        switch keyInput.classify(characters: event.characters,
                                 charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                 modifiers: PreviewModifiers(event.modifierFlags),
                                 inputMethodActive: Self.inputMethodIsActive()) {
        case .text(let characters): report(inputRouter.type(identity, text: characters), kind: .text)
        case .refuse(let kind): flash(InteractionLabel.text(for: .notVerified, kind: kind))
        case .unsupportedKey: flash("This key is not supported in the preview yet")
        }
        return true
    }

    /// True when the current keyboard input source composes text (e.g. Japanese, Chinese).
    private static func inputMethodIsActive() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return type != (kTISTypeKeyboardLayout as String)
    }

    private func report(_ outcome: InputRouter.Outcome, kind: InputKind) {
        switch outcome {
        case .sent:
            // The latency trace measures from here to the first frame showing the result.
            if FrameStamp.tracing { LatencyMarks.shared.markInput() }
        case .refused(let refusal): flash(InteractionLabel.text(for: refusal, kind: kind))
        case .notApplicable(let reason):
            flash(reason.contains("windowGeometryChanged") ? "Preview resizing · try again in a moment"
                  : reason.contains("noTextElementChosen") ? "Click a text field in the preview first"
                  : reason.contains("nothingPressable") ? "Nothing to click there" : "Not sent here")
        }
    }

    /// Shows a transient refusal over the preview, then removes it.
    private func flash(_ message: String) {
        // Logged so device checks can confirm every refusal is shown, not silent.
        NSLog("Dropy input: shown=\"%@\"", message)
        interactionMessage?.cancel()
        interactionStatus?.stringValue = message
        interactionStatus?.isHidden = false
        let work = DispatchWorkItem { [weak self] in
            self?.interactionMessage = nil
            self?.configureInteraction()
        }
        interactionMessage = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
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
}
