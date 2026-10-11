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
    /// Where Live mode shows the app, global top-left (development drivers).
    var liveCast: CGRect? { live?.cast }
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
    /// The camera housing the overlay grows from; nil on a screen without one, and
    /// when the overlay opens from a side edge or a corner.
    private(set) var notchSize: CGSize?
    /// Where this opening sits on the screen; read from the preferences at each opening.
    private(set) var position: OverlayPosition = .notch
    /// What the controls band leaves room for: the housing at the notch (or a
    /// notch-wide space on a screen without one), only the controls elsewhere.
    private var bandNotch: CGSize { notchSize ?? CGSize(width: position == .notch ? 180 : 0, height: 32) }
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
    /// The opening was laid out ahead for this window (nil: any window of the target
    /// app); the window list then selects it without showing the picker first.
    private var awaitingAutoSelection = false
    private var predictedWindowID: UInt32?
    /// Timing for the benchmark (`bun run bench`): when this opening was asked for, and
    /// how many times the layout changed before the window was ready.
    private var openedAt: CFTimeInterval = 0
    private var openReadyLogged = true
    /// The notch display's desktop when this opening started; only a change of it
    /// closes a docked window (adding the Stage display also posts a desktop change).
    private var desktopAtOpen: UInt64?
    private var layoutChangesBeforeReady = 0
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
                guard let self else { return }
                self.native.activeSpaceChanged()
                guard self.state.isDocking, let screen = self.overlayScreen else { return }
                // Other displays changing desktops (or the Stage appearing) leave the
                // docked window where it is; only a switch on this display strands it.
                let now = Spaces.current(on: Self.displayID(of: screen))
                guard now == nil || now != self.desktopAtOpen else { return }
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
        position = preferences.value.position
        notchSize = position == .notch ? Self.notchSize(on: screen) : nil
        openedAt = CACurrentMediaTime()
        openReadyLogged = false
        desktopAtOpen = Spaces.current(on: Self.displayID(of: screen))
        layoutChangesBeforeReady = 0
        // Open straight to the size the chosen window will need when it is known, so
        // the outline grows once instead of opening at the preset's size and morphing
        // again when the window list arrives.
        let prediction = predictOpening(on: screen)
        let full = prediction?.body ?? pickerBody(on: screen)
        // The window is final from the start, with a transparent margin for the ears
        // and the opening overshoot; only the outline inside it moves. Resizing the
        // window itself each frame stuttered.
        let canvas = canvasFrame(around: full, on: screen)
        let panel = OverlayPanel.make(contentRect: canvas)
        buildContent(in: panel, body: full.offsetBy(dx: -canvas.minX, dy: -canvas.minY))
        if let prediction, let root = panel.contentView, let workspace {
            place(panel: panel, root: root, workspace: workspace, frame: canvas, body: full, preview: prediction.preview)
        }
        opensInProcess += 1
        let openedAt = self.openedAt
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
        // Key without activating Dropy: the panel is non-activating, so the window list
        // still gets the keyboard, but Dropy never becomes the active app and its menu
        // bar never flashes over the app the person was in (or the one being docked).
        panel.makeKeyAndOrderFront(nil)
        if let prediction {
            awaitingAutoSelection = true
            predictedWindowID = prediction.windowID
            setState(prediction.state)
            if case .docking = prediction.state { native.showCachedSnapshot() }
        } else {
            awaitingAutoSelection = false
            setState(.selecting)
        }
        onOpen?()
        refreshWindows()
    }

    private struct OpeningPrediction {
        let body: CGRect
        let preview: CGRect
        let windowID: UInt32?
        let state: CapturePhase
    }

    /// The final layout of an opening that goes straight to a known app's window.
    private func predictOpening(on screen: NSScreen) -> OpeningPrediction? {
        guard ProcessInfo.processInfo.environment["DROPY_DEBUG_WINDOW_ID"] == nil,
              let bundleID = preferences.value.openTargetBundleIdentifier,
              let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated }) else { return nil }
        let name = application.localizedName ?? ""
        switch SessionModePolicy.mode(for: sessionConditions) {
        case .native, .live:
            guard let predicted = native.predictedLayout(for: bundleID, on: screen) else { return nil }
            return OpeningPrediction(body: predicted.layout.body, preview: predicted.layout.windowInBody,
                                     windowID: predicted.windowID, state: .docking(applicationName: name))
        case .preview:
            // The app's frontmost window, from the window server (no permission needed).
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            guard let row = rows.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == application.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == 0 }),
                  let bounds = (row[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:)),
                  bounds.width > 60 else { return nil }
            let layout = previewLayout(for: bounds.size, on: screen)
            let body = placedBody(size: layout.size, on: screen)
            return OpeningPrediction(body: body, preview: layout.preview, windowID: row[kCGWindowNumber as String] as? UInt32,
                                     state: .starting(applicationName: name))
        }
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
            try? await Task.sleep(for: .seconds(OverlayMotion.wall(OverlayMotion.morph.close.duration)))
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

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// The camera housing's size, from the menu-bar areas either side of it.
    static func notchSize(on screen: NSScreen) -> CGSize? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX, screen.safeAreaInsets.top > 0 else { return nil }
        return CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }

    /// Where the outline starts and ends: the notch, or on a screen without one a
    /// menu-bar-high pill that fades as it grows. Away from the notch, a small nub on
    /// the screen edge (or in the corner) that also fades.
    private func closedShape(in canvas: CGSize, body: CGRect) -> NotchShape {
        guard position == .notch else { return .nub(for: body, at: position) }
        return NotchShape.notch(size: notchSize ?? CGSize(width: 180, height: NSStatusBar.system.thickness), in: canvas)
    }

    /// The window list's body at the size preset, at this opening's position.
    private func pickerBody(on screen: NSScreen) -> CGRect {
        placedBody(size: OverlayGeometry.frame(on: screen.frame, preferredSize: preferences.value.sizePreset.dimensions).size,
                   on: screen)
    }

    /// A body of `size` at this opening's position on `screen`.
    private func placedBody(size: CGSize, on screen: NSScreen) -> CGRect {
        position.body(size: size, screen: screen.frame, visible: screen.visibleFrame)
    }

    /// Grows the outline out of the notch with a spring, then brings the content in.
    private func morphOpen(_ panel: OverlayPanel) {
        guard let backdrop, let content else { return }
        let canvas = backdrop.bounds.size
        let open = NotchShape.open(body: content.frame, at: position)
        if OverlayMotion.reduced {
            backdrop.set(open)
            settlesAt = Date()
        } else {
            let duration = backdrop.morph(from: closedShape(in: canvas, body: content.frame), to: open,
                                          motion: OverlayMotion.morph.open, clipping: content)
            settlesAt = Date().addingTimeInterval(OverlayMotion.wall(duration))
        }
        OverlayMotion.revealContent(content, position: position)
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
        OverlayMotion.hideContent(content, position: position)
        // Start from where the outline is on screen, even mid-opening or mid-resize.
        let duration = backdrop.morph(from: backdrop.visibleShape ?? .open(body: content.frame, at: position),
                                      to: closedShape(in: canvas, body: content.frame),
                                      motion: OverlayMotion.morph.close, clipping: content)
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
        let shouldAutoSelect = state == .selecting || awaitingAutoSelection
        if !hasSelection { status?.stringValue = "Finding open windows…" }
        Task {
            do {
                let windows = try await WindowCatalog.availableWindows()
                guard request == generation, state != .closed else { return }
                available = windows
                rebuildWindowList()
                if awaitingAutoSelection {
                    awaitingAutoSelection = false
                    let target = preferences.value.openTargetBundleIdentifier
                    let exact = predictedWindowID.flatMap { id in windows.firstIndex { $0.window.windowID == id } }
                    if let index = exact ?? windows.firstIndex(where: { $0.bundleIdentifier == target }) {
                        selectWindow(at: index)
                        return
                    }
                    // The window went away since the opening was laid out: choose as usual.
                    resetToPickerLayout()
                } else {
                    guard !hasSelection else { return }
                }
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
                guard request == generation, state != .closed, !hasSelection || awaitingAutoSelection else { return }
                if awaitingAutoSelection {
                    awaitingAutoSelection = false
                    resetToPickerLayout()
                }
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

    /// Back to the window list's own size after a predicted opening could not be used.
    private func resetToPickerLayout() {
        guard let screen = overlayScreen else { return }
        let body = pickerBody(on: screen)
        applyLayout(body: body, preview: WorkspaceLayout.preview(in: body.size, notch: bandNotch))
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
        let showing: Bool = switch next {
        case .docked, .live, .viewing, .sourceVisibility, .paused: true
        default: false
        }
        if !openReadyLogged, showing {
            openReadyLogged = true
            // One line per opening, read by the benchmark: request to usable window, and
            // how often the outline had to change size on the way (0 is the goal).
            NSLog("Dropy timing: ready mode=%@ ms=%.1f layoutChanges=%ld predicted=%@", next.diagnosticName,
                  (CACurrentMediaTime() - openedAt) * 1000, layoutChangesBeforeReady,
                  predictedWindowID != nil || awaitingAutoSelection ? "yes" : "no")
        }
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

    /// `body` is in the panel's coordinates.
    private func buildContent(in panel: NSPanel, body: CGRect) {
        let size = body.size
        let root = PointerTrackingView(frame: CGRect(origin: .zero, size: panel.frame.size))
        root.wantsLayer = true
        root.layer?.speed = Float(1 / OverlayMotion.slowdown)
        panel.contentView = root
        let backdrop = MorphBackdropView(frame: root.bounds)
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)
        self.backdrop = backdrop
        let workspace = OverlayWorkspaceView(frame: body)
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
        workspace.previewRect = WorkspaceLayout.preview(in: size, notch: bandNotch)
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
        let layout = previewLayout(for: source, on: screen)
        guard workspace.frame.size != layout.size || workspace.previewRect != layout.preview else { return }
        applyLayout(body: placedBody(size: layout.size, on: screen), preview: layout.preview)
    }

    /// The preview's layout for a window of `source` size.
    private func previewLayout(for source: CGSize, on screen: NSScreen) -> WorkspaceLayout {
        let preset = preferences.value.sizePreset
        if preferences.value.automaticWindowSize || preset == .nativeSize || expandedPreview {
            return WorkspaceLayout.make(source: source, screen: screen.frame.size,
                notch: bandNotch, expanded: expandedPreview,
                maximumSize: preset.maximumSize)
        }
        let size = OverlayGeometry.frame(on: screen.frame, preferredSize: preset.dimensions).size
        return WorkspaceLayout(size: size, preview: WorkspaceLayout.preview(in: size, notch: bandNotch))
    }

    /// The panel's frame around `body`, with room for the outline's overshoot.
    private func canvasFrame(around body: CGRect, on screen: NSScreen) -> CGRect {
        let margin = NotchMorph.overshootMargin(for: body.size, reach: OverlayMotion.reach)
        return OverlayGeometry.pixelAligned(position.canvas(around: body, margin: margin, screen: screen.frame),
                                            scale: screen.backingScaleFactor)
    }

    /// Moves the overlay's body to `newBody` (screen coordinates) with the preview or
    /// docked window at `preview` inside it, springing the outline there when animated.
    func applyLayout(body newBody: CGRect, preview: CGRect, animated: Bool = true) {
        guard let screen = overlayScreen, let panel, let workspace, let root = panel.contentView else { return }
        let currentBody = workspace.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        guard currentBody != newBody || workspace.previewRect != preview else { return }
        if !openReadyLogged { layoutChangesBeforeReady += 1 }
        renderer?.prepareForLayoutChange()
        // Do not leave an old-size animation mask clipping the new viewport.
        workspace.layer?.mask = nil
        let generation = UUID()
        layoutGeneration = generation
        let sessionGeneration = self.generation
        let oldOrigin = panel.frame.origin
        let oldBody = (backdrop?.visibleShape?.body ?? workspace.frame).offsetBy(dx: oldOrigin.x, dy: oldOrigin.y)
        func canvas(around body: CGRect) -> CGRect { canvasFrame(around: body, on: screen) }
        let layout = (preview: preview, size: newBody.size)
        let animate = animated && !OverlayMotion.reduced && backdrop?.visibleShape != nil
        if animate, state == .live { live?.suspendInputForLayout() }
        let frame = animate ? canvas(around: oldBody).union(canvas(around: newBody)) : canvas(around: newBody)
        let startShape = backdrop?.visibleShape?.offsetBy(dx: oldOrigin.x - frame.minX, dy: oldOrigin.y - frame.minY)
        place(panel: panel, root: root, workspace: workspace, frame: frame, body: newBody, preview: layout.preview)
        let endShape = NotchShape.open(body: workspace.frame, at: position)
        if animate, let backdrop, let startShape {
            let duration = backdrop.morph(from: startShape, to: endShape, motion: OverlayMotion.morph.resize, clipping: workspace)
            OverlayMotion.relayoutContent(workspace)
            settlesAt = Date().addingTimeInterval(OverlayMotion.wall(duration))
            // Once settled, shrink the panel to fit; nothing moves on screen.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(OverlayMotion.wall(duration)))
                guard let self, self.layoutGeneration == generation, self.generation == sessionGeneration, let panel = self.panel,
                      let root = panel.contentView, let workspace = self.workspace else { return }
                self.place(panel: panel, root: root, workspace: workspace, frame: canvas(around: newBody),
                           body: newBody, preview: layout.preview)
                self.backdrop?.settle(.open(body: workspace.frame, at: self.position))
                if self.state == .live { self.live?.resumeInputAfterLayout() }
            }
        } else {
            backdrop?.settle(endShape)
            settlesAt = Date().addingTimeInterval(DismissBehavior.pointerLeaveGrace)
            if state == .live { live?.resumeInputAfterLayout() }
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
        if state == .live {
            live?.updateLayout(body: workspace.frame.offsetBy(dx: actual.minX, dy: actual.minY),
                               viewport: workspace.previewRect.offsetBy(dx: workspace.frame.minX + actual.minX,
                                                                       dy: workspace.frame.minY + actual.minY))
        }
    }

    @objc private func expandClicked() {
        expandedPreview.toggle()
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
        awaitingAutoSelection = false
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
        let note = SessionModePolicy.previewNote(for: conditions)
        showPreviewInstead(of: selected.identity, request: request, note: note ?? "")
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
        guard request == generation, let renderer else { return }
        native.end()
        live?.end()
        // Reserve restoration before suspension. Closing or choosing another window
        // while it runs cannot leave this window on the Stage or restore the new one.
        let restoration = native.restoreForPreview()
        setState(.starting(applicationName: selectedApplicationName))
        Task { [weak self] in
            await restoration.value
            guard let self, self.generation == request, self.state != .closed else { return }
            self.workspace?.previewShell.layer?.cornerRadius = 12
            self.preview.start(identity, request: request, renderer: renderer)
            if !note.isEmpty { self.showNote(note) }
        }
    }

    func relinquishSourceFocus(processID: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return }
        if let previousApplication, !previousApplication.isTerminated,
           previousApplication.processIdentifier != processID {
            WindowDock.activateApplication(previousApplication.processIdentifier)
        } else {
            NSApp.activate()
        }
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

    /// Whether the Stage is needed right now: the overlay is open, or a window is on the
    /// Stage or waiting there to go home.
    var needsStage: Bool { state != .closed || native.dock.holdsWindows }
}
