import AppKit
import DropyCore

/// Full App interaction: the chosen app's real window moves into the overlay and its
/// app comes to the front, so the person uses it exactly as usual. A snapshot covers
/// the window's place while it moves in and out, so the swap does not show. Nothing
/// streams while the window is in use. Closing puts a pinned app's window on the
/// Stage, ready for the next opening from any desktop, and any other window back
/// where it was.
@MainActor
final class NativeSession: NSObject {
    private unowned let host: OverlaySessionHost
    /// The window Dropy manages; Live mode shares it.
    let dock: WindowDock
    /// Where the docked window and the overlay's body are, in screen coordinates.
    private var dockLayout: DockLayout?
    private var monitors: [Any] = []
    private var session: UUID?

    init(host: OverlaySessionHost, journal: PlacementJournal, stage: Stage?) {
        self.host = host
        dock = WindowDock(journal: journal, stage: stage)
        super.init()
        dock.onEvent = { [weak self] event in self?.handleDockEvent(event) }
    }

    /// Called when a docked window's restore could not finish yet.
    var onDeferredRestore: ((WindowIdentity) -> Void)? {
        get { dock.onDeferredRestore }
        set { dock.onDeferredRestore = newValue }
    }

    /// The window Dropy is docking or has docked, if any.
    var dockedIdentity: WindowIdentity? { dock.current?.identity }

    private var mainDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    var minimumDockWidth: CGFloat {
        DockGeometry.minimumBodyWidth(notch: host.notchSize ?? (host.position == .notch ? CGSize(width: 180, height: 32) : nil))
    }

    /// The body around where the window really is, at this opening's position.
    func layout(around window: CGRect, on screen: NSScreen) -> DockLayout {
        DockGeometry.layout(around: window, screen: screen.frame, minimumBodyWidth: minimumDockWidth,
                            position: host.position, clearance: clearance(on: screen), visible: screen.visibleFrame)
    }

    /// A window of `size` placed at this opening's position.
    func layout(windowSize size: CGSize, on screen: NSScreen) -> DockLayout {
        DockGeometry.layout(windowSize: size, screen: screen.frame, clearance: clearance(on: screen),
                            minimumBodyWidth: minimumDockWidth, position: host.position, visible: screen.visibleFrame)
    }

    /// The space a window may take: the screen, minus the Dock away from the notch.
    private func room(on screen: NSScreen) -> CGRect {
        host.position.room(screen: screen.frame, visible: screen.visibleFrame)
    }

    private func clearance(on screen: NSScreen) -> CGFloat {
        DockGeometry.clearance(notch: host.notchSize, menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
                               position: host.position)
    }

    private func isCurrent(_ request: UUID) -> Bool { request == host.generation && host.state.isDocking }

    /// Where the docked window should go for the current size preference.
    func targetLayout(for docked: WindowDock.Docked, on screen: NSScreen) -> DockLayout {
        targetLayout(windowSize: dock.originalSize ?? docked.frame.size, on: screen)
    }

    /// The same, for a window of `current` size that Dropy has not moved yet.
    func targetLayout(windowSize current: CGSize, on screen: NSScreen) -> DockLayout {
        let preferences = host.preferences.value
        let size = DockGeometry.windowSize(preset: preferences.sizePreset,
                                           adaptsToWindow: preferences.automaticWindowSize,
                                           current: current, screen: room(on: screen), clearance: clearance(on: screen))
        return layout(windowSize: size, on: screen)
    }

    /// The layout an opening of `bundleID` will end at, worked out before the window
    /// list loads, so the overlay can open straight to its final size instead of
    /// opening at the preset's size and morphing again (the late jump people saw on a
    /// first opening). Uses the window Dropy already manages for that app, or the app's
    /// main window. Nil when the app has no window to measure.
    func predictedLayout(for bundleID: String, on screen: NSScreen) -> (layout: DockLayout, windowID: UInt32?)? {
        if let docked = dock.current, docked.identity.bundleIdentifier == bundleID {
            return (targetLayout(for: docked, on: screen), docked.identity.windowID)
        }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated }),
              let window = WindowPlacer.mainWindow(of: application.processIdentifier),
              let size = try? WindowPlacer.sizeValue(window, kAXSizeAttribute), size.width > 0 else { return nil }
        return (targetLayout(windowSize: size, on: screen), WindowPlacer.windowID(of: window))
    }

    /// Covers the window's place with the last picture of the window Dropy manages,
    /// for an opening laid out before the window list arrives.
    func showCachedSnapshot() {
        guard let docked = dock.current else { return }
        host.workspace?.coversWindow = true
        setSnapshot(docked.snapshot, radius: docked.cornerRadius)
    }

    // MARK: Opening

    /// Native and Live share one ownership token and the same operation queue.
    func adopt(_ selected: CapturableWindow, request: UUID) -> Task<Void, Error> {
        session = request
        return dock.adopt(selected.window, identity: selected.identity, session: request)
    }

    /// Stops owning the source before preview begins. Cleanup is reserved now, not
    /// when the task awaiting it eventually runs.
    func restoreForPreview() -> Task<Void, Never> {
        guard let session else { return Task {} }
        self.session = nil
        let generation = host.generation
        return dock.finishSession(session, didRestore: { [weak self] source, _ in
            guard let self, self.host.generation == generation, let source else { return }
            self.host.relinquishSourceFocus(processID: source)
        })
    }

    /// The person chose a window: bring the real one in.
    func start(_ selected: CapturableWindow, request: UUID) {
        removeWatchers()
        host.backdrop?.hole = nil
        host.panel?.ignoresMouseEvents = false
        host.workspace?.coversWindow = true
        setSnapshot(nil)
        host.setState(.docking(applicationName: selected.applicationName))
        let adoption = adopt(selected, request: request)
        Task {
            // The Stage is not awaited here: only a window on another desktop needs it,
            // and `adopt` waits for it then. Waiting for it on every first opening held
            // the overlay up while the Stage was still starting after launch.
            do {
                try await adoption.value
            } catch {
                guard isCurrent(request) else { return }
                if !WindowDock.isOnActiveSpace(selected.identity.windowID) {
                    // Accessibility may not reach a window on another desktop at all.
                    host.setState(.dockedElsewhere(applicationName: selected.applicationName))
                    return
                }
                NSLog("Dropy dock: cannot dock (%@); showing the preview", String(describing: error))
                host.showPreviewInstead(of: selected.identity, request: request,
                                        note: "View only · Dropy could not move this window")
                return
            }
            guard isCurrent(request), let docked = dock.current, let screen = host.overlayScreen else { return }
            guard dock.onActiveSpace else {
                showElsewhere(docked)
                return
            }
            setSnapshot(docked.snapshot, radius: docked.cornerRadius)
            let target = targetLayout(for: docked, on: screen)
            host.applyLayout(body: target.body, preview: target.windowInBody, animated: true)
            await finish(request: request, target: target, on: screen)
        }
    }

    /// Places the window once the outline covers its place, brings its app forward and
    /// reveals it.
    private func finish(request: UUID, target: DockLayout, on screen: NSScreen) async {
        // The window moves in only once the outline has grown over its place, so no
        // part of it shows outside the overlay.
        let wait = host.settlesAt.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard isCurrent(request) else { return }
        let placed: CGRect
        do {
            placed = try await dock.place(at: DockGeometry.globalRect(fromAppKit: target.window,
                                                                    mainDisplayHeight: mainDisplayHeight), session: request)
        } catch {
            guard isCurrent(request), let identity = host.selectedIdentity else { return }
            NSLog("Dropy dock: cannot place (%@); showing the preview", String(describing: error))
            host.showPreviewInstead(of: identity, request: request, note: "View only · Dropy could not move this window")
            return
        }
        // Closed meanwhile: the close puts the window back after this placement.
        guard isCurrent(request) else { return }
        let actual = PlacementGeometry.appKitRect(fromGlobal: placed, mainDisplayHeight: mainDisplayHeight)
        let layout = layout(around: actual, on: screen)
        if layout != target { host.applyLayout(body: layout.body, preview: layout.windowInBody, animated: false) }
        dockLayout = layout
        await dock.activate(session: request)
        // A frame for the window server to draw the window where it now is.
        try? await Task.sleep(for: .milliseconds(34))
        guard isCurrent(request) else { return }
        reveal()
    }

    /// Cuts the overlay open over the real window and hands it the pointer.
    private func reveal() {
        guard let workspace = host.workspace, let dockLayout else { return }
        host.setState(.docked)
        updateHole()
        installWatchers()
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
    func updateHole() {
        guard let workspace = host.workspace, let docked = dock.current else {
            host.backdrop?.hole = nil
            return
        }
        host.backdrop?.hole = (workspace.previewRect.offsetBy(dx: workspace.frame.minX, dy: workspace.frame.minY),
                               docked.cornerRadius)
    }

    private func setSnapshot(_ image: CGImage?, radius: CGFloat = DockGeometry.defaultCornerRadius) {
        guard let workspace = host.workspace else { return }
        workspace.snapshot.layer?.contents = image
        workspace.snapshot.layer?.contentsScale = host.overlayScreen?.backingScaleFactor ?? 2
        workspace.previewShell.layer?.cornerRadius = radius
    }

    /// The window is on another desktop or behind a full-screen app: show what it
    /// last looked like and offer to go there.
    private func showElsewhere(_ docked: WindowDock.Docked) {
        setSnapshot(docked.snapshot, radius: docked.cornerRadius)
        host.setState(.dockedElsewhere(applicationName: host.selectedApplicationName))
        host.workspace?.coversWindow = docked.snapshot != nil
    }

    @objc func goToDockedDesktop() {
        guard let pid = dock.current?.identity.processID ?? host.selectedIdentity?.processID else { return }
        host.close(returnsFocus: false, putsBack: false)
        let restoration = dock.release()
        Task {
            // Back where the person had it, then macOS switches to its desktop.
            await restoration.value
            WindowDock.activateApplication(pid)
        }
    }

    // MARK: Closing

    /// The overlay closed or switched away from docking: stop watching the pointer.
    func end() {
        removeWatchers()
        dockLayout = nil
    }

    /// Finishes closing an overlay that was docking: a fresh picture covers the
    /// window's place, the window goes to the Stage (a pinned app) or back where it was
    /// (unless the person already took it), the outline collapses, and focus returns to
    /// the previous app only while the person is still in the docked app or in Dropy.
    /// - Returns: false when no adoption belongs to this session.
    func close(panel: OverlayPanel, backdrop: MorphBackdropView?, content: NSView?, workspace: OverlayWorkspaceView?,
               wasDocked: Bool, putsBack: Bool, returnsFocus: Bool, previous: NSRunningApplication?) -> Bool {
        guard let session else { return false }
        self.session = nil
        panel.ignoresMouseEvents = true
        let dropyActive = NSApplication.shared.isActive
        let preferences = host.preferences
        let closeStarted = CACurrentMediaTime()
        let closingGeneration = host.generation
        _ = dock.finishSession(session, snapshot: wasDocked, putsBack: putsBack, keepsOnStage: { identity in
            let value = preferences.value
            guard value.interaction == .fullApp, value.keepsPinnedAppReady,
                  let pinned = value.pinnedBundleIdentifier else { return false }
            return pinned == identity.bundleIdentifier
        }, willRestore: { docked in
            workspace?.snapshot.layer?.contents = docked.snapshot
            workspace?.coversWindow = true
            workspace?.layoutSubtreeIfNeeded()
        }, didRestore: { [weak self] source, stages in
            guard let self else { return }
            backdrop?.hole = nil
            if putsBack {
                NSLog("Dropy timing: closed home=%.1fms staged=%@", (CACurrentMediaTime() - closeStarted) * 1000,
                      stages ? "yes" : "no")
            }
            self.host.morphClosed(panel, backdrop: backdrop, content: content)
            // A reopened overlay owns focus now, even if its source is the same app.
            guard self.host.generation == closingGeneration else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard returnsFocus || (stages && front == source) else { return }
            guard dropyActive || front == source || front == getpid() else { return }
            if let previous, !previous.isTerminated, previous.processIdentifier != source {
                WindowDock.activateApplication(previous.processIdentifier)
            } else if stages, let finder = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.finder").first {
                WindowDock.activateApplication(finder.processIdentifier)
            }
        })
        return true
    }

    /// Puts a docked or staged window back where the person had it, for quitting.
    func releaseNow() {
        dock.releaseNow()
        dock.returnAllNow()
    }

    /// The person switched desktops: windows waiting for that desktop go back to it.
    func activeSpaceChanged() {
        dock.activeSpaceChanged()
    }

    /// The pinned app or the keep-ready choice changed: a staged window that should no
    /// longer wait goes back where it was.
    func pinnedAppChanged() {
        let preferences = host.preferences.value
        guard dock.isStaged, !host.state.isDocking,
              !preferences.keepsPinnedAppReady || dock.current?.identity.bundleIdentifier != preferences.pinnedBundleIdentifier
        else { return }
        _ = dock.release()
    }

    /// The Stage ended (the window server stopped it): macOS has moved its windows to a
    /// real display already, so a staged window is no longer Dropy's to move.
    func stageLost() {
        dock.forgetReturning()
        guard dock.isStaged else { return }
        dock.detach()
        if host.state.isDocking { host.close(returnsFocus: false, putsBack: false) }
    }

    // MARK: While docked

    private func installWatchers() {
        host.removeSessionWatchers()
        removeWatchers()
        host.panel?.ignoresMouseEvents = true
        // The overlay takes the pointer only over its own outline (the band with the
        // controls and the border); everywhere over the window it lets clicks through.
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
            self?.updatePointer()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            self?.updatePointer()
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                           handler: { [weak self] _ in self?.clickedElsewhere() }) {
            monitors.append(monitor)
        }
        updatePointer()
    }

    private func removeWatchers() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func updatePointer() {
        guard host.state == .docked, let panel = host.panel, let dockLayout else { return }
        let point = NSEvent.mouseLocation
        let overOutline = dockLayout.body.contains(point) && !dockLayout.window.contains(point)
        if panel.ignoresMouseEvents == overOutline { panel.ignoresMouseEvents = !overOutline }
    }

    /// A click somewhere other than Dropy. Inside the docked app (its window, menus,
    /// sheets, the menu bar, an open panel) it is the person using the app.
    private func clickedElsewhere() {
        guard host.state == .docked, let dockLayout, let docked = dock.current,
              host.preferences.value.dismissBehavior != .manual else { return }
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
        host.close(returnsFocus: false, putsBack: true)
    }

    /// Another app came to the front: its windows would rise over the docked one, so
    /// the overlay closes and the window goes back.
    func applicationActivated(pid: pid_t, bundleIdentifier: String?) {
        if host.state == .closed { dock.applicationActivated(pid: pid) }
        guard let docked = dock.current, host.state.isDocking,
              DockPolicy.activationCloses(processID: pid, bundleIdentifier: bundleIdentifier,
                                          sourceProcessID: docked.identity.processID,
                                          ownProcessID: getpid()) else { return }
        NSLog("Dropy dismiss: switched to another app")
        host.close(returnsFocus: false, putsBack: true)
    }

    /// An app quit. Returns true when it was the docked one: its window went with it,
    /// so there is nothing to put back.
    func applicationTerminated(pid: pid_t) -> Bool {
        guard let docked = dock.current, docked.identity.processID == pid else { return false }
        dock.detach()
        if host.state.isDocking { host.close(returnsFocus: false, putsBack: false) }
        return true
    }

    private func handleDockEvent(_ event: WindowDock.Event) {
        switch event {
        case .resized(let frame):
            guard host.state == .docked, let screen = host.overlayScreen else { return }
            let actual = PlacementGeometry.appKitRect(fromGlobal: frame, mainDisplayHeight: mainDisplayHeight)
            let layout = layout(around: actual, on: screen)
            dockLayout = layout
            host.applyLayout(body: layout.body, preview: layout.windowInBody, animated: false)
            updateHole()
        case .detached, .closed:
            NSLog("Dropy dock: the person took the window (%@)", String(describing: event))
            dock.detach()
            if host.state.isDocking { host.close(returnsFocus: false, putsBack: false) }
        case .minimized, .appHidden:
            // It returns where the person had it when they bring it back.
            dock.putBackKeepingState()
            if host.state.isDocking { host.close(returnsFocus: false, putsBack: false) }
        }
    }

    /// Switching to Preview only puts a docked window back.
    func preferencesChanged() {
        guard dock.current != nil, host.preferences.value.interaction == .previewOnly else { return }
        if host.state.isDocking { host.close(returnsFocus: false, putsBack: true) }
        _ = dock.release()
    }

    /// The placement journal was settled elsewhere (recovery restored the window).
    func journalChanged() {
        if dock.journalChanged(), host.state.isDocking { host.close(returnsFocus: false, putsBack: false) }
    }
}
