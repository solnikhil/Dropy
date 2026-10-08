import AppKit
import DropyCore

/// Live mode, used over another app's full-screen space, where an ordinary window
/// cannot be brought: the app's window stays on the Stage and is streamed into the
/// overlay. Dropy's own interaction system makes it feel native:
///
/// - the pointer is handed over to the Stage while it is over the cast
///   (`PointerHandoff`), so hover, clicks, scrolling, menus and drags are the app's own;
///   Dropy draws the app's cursor where the person sees the cast;
/// - the app is brought to the front, so the keyboard, shortcuts and input methods go
///   to it directly; nothing is forwarded.
///
/// Measured in docs/design/2026-10-07-stage-spike-results.md (S3–S5).
@MainActor
final class LiveSession {
    private unowned let host: OverlaySessionHost
    private unowned let native: NativeSession
    private let stage: Stage
    private let caster = LiveCaster()
    private var cursor: SoftCursor?
    private var handoff: PointerHandoff?
    private var monitors: [Any] = []
    /// The overlay's body in global coordinates, for telling clicks outside apart.
    private var body: CGRect?
    /// Where the person sees the app, global top-left.
    private(set) var cast: CGRect?

    init(host: OverlaySessionHost, native: NativeSession, stage: Stage) {
        self.host = host
        self.native = native
        self.stage = stage
    }

    private var dock: WindowDock { native.dock }
    private var mainDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }
    private func isCurrent(_ request: UUID) -> Bool { request == host.generation && host.state.isDocking }

    /// The person chose a window while a full-screen app is in front.
    func start(_ selected: CapturableWindow, request: UUID) {
        end()
        host.backdrop?.hole = nil
        host.workspace?.coversWindow = false
        host.setState(.docking(applicationName: selected.applicationName))
        Task {
            if !stage.isReady { await stage.start() }
            guard isCurrent(request) else { return }
            guard stage.isReady else {
                return host.showPreviewInstead(of: selected.identity, request: request,
                                               note: "View only · The hidden display Dropy needs is not available")
            }
            do {
                try await dock.adopt(selected.window, identity: selected.identity)
                guard isCurrent(request), let docked = dock.current, let screen = host.overlayScreen else { return }
                let target = native.targetLayout(for: docked, on: screen)
                host.applyLayout(body: target.body, preview: target.windowInBody, animated: true)
                let wait = host.settlesAt.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard isCurrent(request) else { return }
                let staged = try await dock.prepareLive(size: target.window.size)
                guard isCurrent(request), let stageBounds = stage.bounds, let displayID = stage.displayID,
                      let renderer = host.renderer else { return }
                // The app may have refused the size: lay the overlay out around what it took.
                let layout = DockGeometry.layout(windowSize: staged.size, screen: screen.frame,
                                                 clearance: target.band.height, minimumBodyWidth: native.minimumDockWidth)
                if layout != target { host.applyLayout(body: layout.body, preview: layout.windowInBody, animated: false) }
                try await caster.start(stage: displayID, region: staged.offsetBy(dx: -stageBounds.minX, dy: -stageBounds.minY),
                                       windowID: docked.identity.windowID, renderer: renderer,
                                       refreshRate: stage.screen?.maximumFramesPerSecond ?? 60)
                guard isCurrent(request) else { return await caster.stop(reason: "superseded") }
                await dock.activate()
                guard isCurrent(request) else { return }
                let cast = DockGeometry.globalRect(fromAppKit: layout.window, mainDisplayHeight: mainDisplayHeight)
                body = DockGeometry.globalRect(fromAppKit: layout.body, mainDisplayHeight: mainDisplayHeight)
                host.setState(.live)
                beginHandoff(cast: cast, staged: staged)
                NSLog("Dropy live: ready cast=%@ staged=%@", NSStringFromRect(cast), NSStringFromRect(staged))
            } catch {
                guard isCurrent(request) else { return }
                NSLog("Dropy live: cannot start (%@); showing the preview", String(describing: error))
                end()
                host.showPreviewInstead(of: selected.identity, request: request,
                                        note: "View only · Dropy could not stream this window")
            }
        }
    }

    /// Stops the stream and gives the pointer back. Safe to call at any time.
    func end() {
        stage.onPointerEvent = nil
        if handoff?.onStage == true, let body {
            // Back to the middle of where the cast was, never left on the Stage.
            warp(to: StageGeometry.nearestPoint(to: CGPoint(x: body.midX, y: body.midY),
                                                on: Stage.realDisplays(excluding: stage.displayID)))
        }
        stage.allowsPointer = false
        handoff = nil
        body = nil
        cast = nil
        cursor?.hide()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        Task { await caster.stop() }
    }

    // MARK: Pointer hand-off

    private func beginHandoff(cast: CGRect, staged: CGRect) {
        // The overlay's own pointer-leave and click-outside watchers would read the hand-off
        // (the pointer moving to the Stage, clicks landing in the app there) as leaving:
        // the app is the one in use, as when docked. clickedElsewhere decides instead.
        host.removeSessionWatchers()
        self.cast = cast
        handoff = PointerHandoff(cast: cast, staged: staged)
        if cursor == nil { cursor = SoftCursor() }
        stage.onPointerEvent = { [weak self] _, event in self?.pointerMoved(event) }
        // A pointer already resting over the cast is handed over at its first move.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                           handler: { [weak self] _ in self?.clickedElsewhere() }) {
            monitors.append(monitor)
        }
    }

    private func pointerMoved(_ event: CGEvent) {
        guard var handoff else { return }
        let location = event.location
        switch handoff.pointer(at: location) {
        case .none:
            // A stray pointer that reached the Stage some other way goes back.
            if let bounds = stage.bounds, bounds.contains(location) {
                let back = StageGeometry.nearestPoint(to: location, on: Stage.realDisplays(excluding: stage.displayID))
                warp(to: back)
                event.location = back
            }
        case .enter(let point, let shown):
            stage.allowsPointer = true
            warp(to: point)
            event.location = point
            cursor?.show(at: shown)
        case .follow(let shown):
            cursor?.move(to: shown)
        case .leave(let point):
            stage.allowsPointer = false
            let back = StageGeometry.nearestPoint(to: point, on: Stage.realDisplays(excluding: stage.displayID))
            warp(to: back)
            event.location = back
            cursor?.hide()
        }
        self.handoff = handoff
    }

    private func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Re-associate at once, or macOS ignores hardware motion for 0.25 s after a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// A click somewhere other than the cast or the app (whose clicks happen on the
    /// Stage while the pointer is handed over).
    private func clickedElsewhere() {
        guard host.state == .live, handoff?.onStage != true, let body, let docked = dock.current,
              host.preferences.value.dismissBehavior != .manual else { return }
        let point = CGEvent(source: nil)?.location ?? .zero
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
        guard !DockPolicy.clickIsInside(point: point, body: body, windows: windows, ownProcessID: getpid(),
                                        sourceProcessID: docked.identity.processID) else { return }
        NSLog("Dropy dismiss: click outside the live app")
        host.close(returnsFocus: false, putsBack: true)
    }
}
