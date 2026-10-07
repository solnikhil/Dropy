import AppKit
import DropyCore

/// Full App interaction: the chosen app's real window moves into the overlay and its
/// app comes to the front, so the person uses it exactly as usual. A snapshot covers
/// the window's place while it moves in and out, so the swap does not show. Nothing
/// streams while the window is in use. Closing puts the window back where it was.
@MainActor
final class NativeSession: NSObject {
    private unowned let host: OverlaySessionHost
    private let dock: WindowDock
    /// Where the docked window and the overlay's body are, in screen coordinates.
    private var dockLayout: DockLayout?
    private var monitors: [Any] = []

    init(host: OverlaySessionHost, journal: PlacementJournal) {
        self.host = host
        dock = WindowDock(journal: journal)
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

    private var minimumDockWidth: CGFloat {
        DockGeometry.minimumBodyWidth(notch: host.notchSize ?? CGSize(width: 180, height: 32))
    }

    private func isCurrent(_ request: UUID) -> Bool { request == host.generation && host.state.isDocking }

    /// Where the docked window should go for the current size preference.
    private func targetLayout(for docked: WindowDock.Docked, on screen: NSScreen) -> DockLayout {
        let clearance = DockGeometry.clearance(notch: host.notchSize,
                                               menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
        let preferences = host.preferences.value
        let size = DockGeometry.windowSize(preset: preferences.sizePreset,
                                           adaptsToWindow: preferences.automaticWindowSize,
                                           current: dock.originalSize ?? docked.frame.size,
                                           screen: screen.frame, clearance: clearance)
        return DockGeometry.layout(windowSize: size, screen: screen.frame, clearance: clearance,
                                   minimumBodyWidth: minimumDockWidth)
    }

    // MARK: Opening

    /// The person chose a window: bring the real one in.
    func start(_ selected: CapturableWindow, request: UUID) {
        removeWatchers()
        host.backdrop?.hole = nil
        host.panel?.ignoresMouseEvents = false
        host.workspace?.coversWindow = true
        setSnapshot(nil)
        host.setState(.docking(applicationName: selected.applicationName))
        Task {
            do {
                try await dock.adopt(selected.window, identity: selected.identity)
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
                                                                    mainDisplayHeight: mainDisplayHeight))
        } catch {
            guard isCurrent(request), let identity = host.selectedIdentity else { return }
            NSLog("Dropy dock: cannot place (%@); showing the preview", String(describing: error))
            host.showPreviewInstead(of: identity, request: request, note: "View only · Dropy could not move this window")
            return
        }
        // Closed meanwhile: the close puts the window back after this placement.
        guard isCurrent(request) else { return }
        let actual = PlacementGeometry.appKitRect(fromGlobal: placed, mainDisplayHeight: mainDisplayHeight)
        let layout = DockGeometry.layout(around: actual, screen: screen.frame, minimumBodyWidth: minimumDockWidth)
        if layout != target { host.applyLayout(body: layout.body, preview: layout.windowInBody, animated: false) }
        dockLayout = layout
        await dock.activate()
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
        Task {
            // Back where the person had it, then macOS switches to its desktop.
            await dock.release()
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
    /// window's place, the window goes back where it was (unless the person already
    /// took it), the outline collapses, and focus returns to the previous app only
    /// while the person is still in the docked app or in Dropy.
    /// - Returns: false when nothing was docked, so the overlay closes normally.
    func close(panel: OverlayPanel, backdrop: MorphBackdropView?, content: NSView?, workspace: OverlayWorkspaceView?,
               wasDocked: Bool, putsBack: Bool, returnsFocus: Bool, previous: NSRunningApplication?) -> Bool {
        guard dock.current != nil else { return false }
        panel.ignoresMouseEvents = true
        let dropyActive = NSApplication.shared.isActive
        Task { @MainActor [weak self] in
            guard let self else { return }
            let source = self.dock.current?.identity.processID
            if putsBack {
                if wasDocked { await self.dock.refreshSnapshot(timeout: .milliseconds(150)) }
                workspace?.snapshot.layer?.contents = self.dock.current?.snapshot
                workspace?.coversWindow = true
                workspace?.layoutSubtreeIfNeeded()
            }
            backdrop?.hole = nil
            if putsBack { await self.dock.release() }
            self.host.morphClosed(panel, backdrop: backdrop, content: content)
            guard returnsFocus else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard dropyActive || front == source || front == getpid() else { return }
            if let previous, !previous.isTerminated, previous.processIdentifier != source {
                WindowDock.activateApplication(previous.processIdentifier)
            }
        }
        return true
    }

    /// Puts a docked window back where the person had it, for quitting.
    func releaseNow() {
        dock.releaseNow()
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
            let layout = DockGeometry.layout(around: actual, screen: screen.frame, minimumBodyWidth: minimumDockWidth)
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
        Task { await dock.release() }
    }

    /// The placement journal was settled elsewhere (recovery restored the window).
    func journalChanged() {
        if dock.journalChanged(), host.state.isDocking { host.close(returnsFocus: false, putsBack: false) }
    }
}
