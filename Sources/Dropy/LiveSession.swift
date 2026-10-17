import AppKit
import DropyCore

/// Live mode, used over another app's full-screen space, where an ordinary window
/// cannot be brought. The app's window waits on the Stage at the spot that mirrors
/// where the person sees it, and the Stage is shown one to one over the display
/// (`LiveMirror`): the window lands in the overlay's cut-out exactly as a docked window
/// does, and its menus, popovers and sheets show wherever they open.
///
/// - While the pointer is over anything of the app's, the real pointer is on the Stage
///   at the same spot (`PointerHandoff`, a plain offset), so hover, clicks, scrolling,
///   menus and drags are the app's own; Dropy draws the app's cursor where the person sees it.
/// - Anywhere else the pointer is on the display, so the full-screen app underneath is
///   used as usual, and the overlay stays open: both apps are in use. Clicking either
///   app brings it to the front, so the keyboard goes to the one clicked; nothing is forwarded.
///
/// Measured in docs/design/2026-10-07-stage-spike-results.md (S3–S5).
@MainActor
final class LiveSession {
    private unowned let host: OverlaySessionHost
    private unowned let native: NativeSession
    private let stage: Stage
    private let caster = LiveCaster()
    func benchmarkSnapshot() -> [String: Any]? { caster.benchmarkSnapshot() }
    private var mirror: LiveMirror?
    private var cursor: SoftCursor?
    private var handoff: PointerHandoff?
    private var layoutInput = LiveLayoutReadiness()
    private var layoutRevision = UUID()
    /// The docked window on the Stage, global top-left, as last placed or followed.
    private var stagedWindow: CGRect?
    private var regionsCheckedAt: CFTimeInterval = 0
    private var following = false
    /// Where the person sees the app's window (the overlay's cut-out), global top-left.
    private(set) var cast: CGRect?

    init(host: OverlaySessionHost, native: NativeSession, stage: Stage) {
        self.host = host
        self.native = native
        self.stage = stage
    }

    private var dock: WindowDock { native.dock }
    private var mainDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }
    private func isCurrent(_ request: UUID) -> Bool { request == host.generation && host.state.isDocking }
    private func global(_ rect: CGRect) -> CGRect { DockGeometry.globalRect(fromAppKit: rect, mainDisplayHeight: mainDisplayHeight) }
    private func appKit(_ rect: CGRect) -> CGRect { PlacementGeometry.appKitRect(fromGlobal: rect, mainDisplayHeight: mainDisplayHeight) }

    /// Where `cast` (global) waits on the Stage so the Stage mirrors the overlay's display.
    private func mirrored(_ cast: CGRect, on screen: NSScreen, stage bounds: CGRect) -> CGRect {
        StageGeometry.mirrored(cast, display: CGDisplayBounds(OverlayController.displayID(of: screen)), stage: bounds,
                               menuBarHeight: stage.menuBarHeight)
    }

    /// The person chose a window while a full-screen app is in front.
    func start(_ selected: CapturableWindow, request: UUID) {
        end()
        host.backdrop?.hole = nil
        // The app's icon covers its place while it moves in, as when docking.
        native.showCover(processID: selected.identity.processID)
        host.setState(.docking(applicationName: selected.applicationName))
        let adoption = native.adopt(selected.identity, request: request)
        Task { [self] in
            if !stage.isReady { await stage.start() }
            guard isCurrent(request) else { return }
            guard stage.isReady, let stageBounds = stage.bounds, let displayID = stage.displayID else {
                return host.showPreviewInstead(of: selected.identity, request: request,
                                               note: "View only · The hidden display Dropy needs is not available")
            }
            do {
                try await adoption.value
                guard isCurrent(request), let docked = dock.current, let screen = host.overlayScreen else { return }
                var layout = native.targetLayout(for: docked, on: screen)
                host.applyLayout(body: layout.body, preview: layout.windowInBody, animated: true)
                // Nothing on the Stage shows yet, so the window moves while the outline grows.
                var staged = try await dock.prepareLive(frame: mirrored(global(layout.window), on: screen, stage: stageBounds),
                                                        session: request)
                guard isCurrent(request) else { return }
                if staged.size != layout.window.size {
                    // The app refused the size: lay the overlay out around what it took.
                    layout = native.layout(windowSize: staged.size, on: screen)
                    host.applyLayout(body: layout.body, preview: layout.windowInBody, animated: true)
                    staged = try await dock.prepareLive(frame: mirrored(global(layout.window), on: screen, stage: stageBounds),
                                                        session: request)
                    guard isCurrent(request) else { return }
                }
                let cast = global(layout.window)
                let offset = CGVector(dx: staged.minX - cast.minX, dy: staged.minY - cast.minY)
                let mirrorFrame = appKit(stageBounds.offsetBy(dx: -offset.dx, dy: -offset.dy))
                guard let mirror = LiveMirror(frame: mirrorFrame) else { throw LiveFailure.noRenderer }
                self.mirror = mirror
                mirror.show()
                try await caster.start(stage: displayID, size: stageBounds.size, windowID: docked.identity.windowID,
                                       appProcess: docked.identity.processID, renderer: mirror.renderer,
                                       refreshRate: stage.screen?.maximumFramesPerSecond ?? 60,
                                       onUnexpectedStop: { [weak self] error in
                    self?.captureStopped(error, request: request)
                })
                guard isCurrent(request) else { return }
                await dock.activate(session: request)
                guard isCurrent(request) else { return }
                // Revealed once the mirror shows the window and the outline is at rest:
                // its cut-out does not show through a morph still playing.
                guard await Self.firstFrame(on: mirror.renderer) else { throw LiveFailure.firstFrameTimeout }
                let settle = host.backdrop?.morphRemaining ?? 0
                if settle > 0 { try? await Task.sleep(for: .seconds(settle)) }
                guard isCurrent(request) else { return }
                self.cast = cast
                stagedWindow = staged
                host.setState(.live)
                native.updateHole()
                native.uncover()
                beginHandoff(offset: offset)
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

    private enum LiveFailure: Error { case noRenderer, firstFrameTimeout }

    /// Waits for `renderer` to put its first frame on screen, at most a second.
    private static func firstFrame(on renderer: MetalFrameView) async -> Bool {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            renderer.onNextPresented = { _ in
                guard !once.done else { return }
                once.done = true
                renderer.onNextPresented = nil
                continuation.resume(returning: true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !once.done else { return }
                once.done = true
                renderer.onNextPresented = nil
                continuation.resume(returning: false)
            }
        }
    }

    private func captureStopped(_ error: Error, request: UUID) {
        guard isCurrent(request) else { return }
        let error = error as NSError
        let failure = CaptureFailure.stream(domain: error.domain, code: error.code)
        end()
        native.end()
        host.generation = UUID()
        let failedGeneration = host.generation
        let restoration = native.restoreForPreview()
        host.selectedIdentity = nil
        host.renderer?.clear()
        host.setState(.failed(failure))
        // A system stop is an explicit stop. Keep its reason visible and wait for
        // a new selection instead of starting another capture through the preview.
        Task { [weak self] in
            await restoration.value
            guard let self, self.host.generation == failedGeneration else { return }
            if !failure.opensPrivacySettings { self.host.reloadListKeepingState() }
        }
    }

    /// Stops the stream and gives the pointer back. Safe to call at any time.
    func end() {
        stage.onPointerEvent = nil
        if let handoff, handoff.onStage, let location = CGEvent(source: nil)?.location {
            // Back to where the person sees the pointer, never left on the Stage.
            warp(to: StageGeometry.nearestPoint(to: handoff.shownPoint(location),
                                                on: Stage.realDisplays(excluding: stage.displayID)))
        }
        stage.allowsPointer = false
        if let mirror {
            // Cover the cut-out before the picture goes, so the app underneath never
            // shows through it while the overlay closes or changes.
            if cast != nil, let processID = dock.current?.identity.processID { native.showCover(processID: processID) }
            mirror.close()
        }
        mirror = nil
        handoff = nil
        stagedWindow = nil
        cast = nil
        following = false
        layoutRevision = UUID()
        layoutInput.reset()
        cursor?.hide()
        caster.stop()
    }

    /// Do not hand input into content still clipped by a resize animation.
    func suspendInputForLayout() {
        layoutInput.suspendAnimation()
        if let handoff, handoff.onStage, let location = CGEvent(source: nil)?.location {
            warp(to: StageGeometry.nearestPoint(to: handoff.shownPoint(location),
                                                on: Stage.realDisplays(excluding: stage.displayID)))
        }
        handoff?.reset()
        stage.allowsPointer = false
        cursor?.hide()
    }

    func resumeInputAfterLayout() { layoutInput.resumeAnimation() }

    /// The overlay was laid out again (AppKit coordinates): the window follows its new
    /// place in the overlay, so the Stage keeps mirroring the display.
    func updateLayout(body: CGRect, viewport: CGRect) {
        guard let cast, let stagedWindow, let screen = host.overlayScreen, let stageBounds = stage.bounds else { return }
        let shown = global(viewport)
        guard DockPolicy.change(expected: cast, observed: shown, isFullScreen: false) != .unchanged else { return }
        self.cast = shown
        let target = mirrored(shown, on: screen, stage: stageBounds)
        guard !target.equalTo(stagedWindow) || layoutInput.isMoving else { return refreshRegions(force: true) }
        let session = host.generation
        let revision = UUID()
        layoutRevision = revision
        layoutInput.beginMove(revision)
        suspendInputForLayout()
        Task { [weak self] in
            guard let self else { return }
            do {
                let placed = try await self.dock.prepareLive(frame: target, session: session)
                guard self.host.generation == session, self.host.state == .live,
                      self.layoutRevision == revision else { return }
                self.placed(placed, shown: shown)
                self.layoutInput.finishMove(revision)
            } catch {
                guard self.host.generation == session, self.layoutRevision == revision else { return }
                self.host.close(returnsFocus: false, putsBack: true)
            }
        }
    }

    /// The window is at `staged` on the Stage and shows at `shown`: the mirror and the
    /// hand-off use the offset between them.
    private func placed(_ staged: CGRect, shown: CGRect) {
        guard let stageBounds = stage.bounds else { return }
        stagedWindow = staged
        cast = CGRect(origin: shown.origin, size: staged.size)
        let offset = CGVector(dx: staged.minX - shown.minX, dy: staged.minY - shown.minY)
        handoff?.offset = offset
        mirror?.move(to: appKit(stageBounds.offsetBy(dx: -offset.dx, dy: -offset.dy)))
        refreshRegions(force: true)
    }

    // MARK: Pointer hand-off

    private func beginHandoff(offset: CGVector) {
        // The overlay's own pointer-leave and click-outside watchers would read the hand-off
        // (the pointer moving to the Stage, clicks landing in the app there) as leaving.
        // Over a full-screen app the overlay stays open while either app is used.
        host.removeSessionWatchers()
        layoutInput.reset()
        handoff = PointerHandoff(offset: offset, regions: cast.map { [$0] } ?? [])
        refreshRegions(force: true)
        if cursor == nil { cursor = SoftCursor() }
        // A pointer already resting over the app is handed over at its first move.
        stage.onPointerEvent = { [weak self] _, event in self?.pointerMoved(event) }
    }

    /// What of the app shows, from the window server's list of windows on the Stage, at
    /// most every 50 ms (and at once when the pointer is about to leave, in case a menu
    /// it is moving into just opened). Also follows the person resizing the window.
    private func refreshRegions(force: Bool = false) {
        guard var handoff, let cast, let stageBounds = stage.bounds, let docked = dock.current else { return }
        let now = CACurrentMediaTime()
        guard force || now - regionsCheckedAt > 0.05 else { return }
        regionsCheckedAt = now
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var windows: [PointerHandoff.StageWindow] = []
        var window: CGRect?
        for row in rows {
            guard let bounds = (row[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:)),
                  bounds.intersects(stageBounds), let processID = row[kCGWindowOwnerPID as String] as? Int32 else { continue }
            if (row[kCGWindowNumber as String] as? UInt32) == docked.identity.windowID { window = bounds }
            windows.append(.init(bounds: bounds, layer: row[kCGWindowLayer as String] as? Int ?? 0, processID: processID))
        }
        handoff.regions = PointerHandoff.regions(of: windows, window: cast, stage: stageBounds, offset: handoff.offset,
                                                 appProcess: docked.identity.processID, ownProcess: getpid())
        self.handoff = handoff
        if let window { follow(window) }
    }

    /// The person resized the window on the Stage (its edges are theirs to drag): the
    /// overlay grows or shrinks around it. A drag by the title bar would take it away
    /// from where the person sees it, so it goes back.
    private func follow(_ window: CGRect) {
        guard let stagedWindow, let handoff, let screen = host.overlayScreen, !following else { return }
        switch DockPolicy.change(expected: stagedWindow, observed: window, isFullScreen: false) {
        case .unchanged:
            return
        case .resizedInPlace:
            self.stagedWindow = window
            let shown = window.offsetBy(dx: -handoff.offset.dx, dy: -handoff.offset.dy)
            cast = shown
            let layout = native.layout(around: appKit(shown), on: screen)
            host.applyLayout(body: layout.body, preview: layout.windowInBody, animated: false)
            native.updateHole()
        case .detached:
            following = true
            let session = host.generation
            Task { [weak self] in
                guard let self else { return }
                let placed = try? await self.dock.prepareLive(frame: stagedWindow, session: session)
                guard self.host.generation == session, self.host.state == .live else { return }
                self.following = false
                guard let placed, let cast = self.cast else {
                    self.host.close(returnsFocus: false, putsBack: true)
                    return
                }
                self.placed(placed, shown: cast)
            }
        }
    }

    private func pointerMoved(_ event: CGEvent) {
        guard WindowPlacer.isTrusted else {
            host.close(returnsFocus: false, putsBack: true)
            native.releaseForSystemChange()
            return
        }
        guard layoutInput.allowsInput, handoff != nil else { return }
        refreshRegions()
        let location = event.location
        if let handoff, handoff.onStage, !handoff.showsApp(at: handoff.shownPoint(location)) { refreshRegions(force: true) }
        guard var handoff else { return }
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
            // The same spot the person sees: no jump, the system cursor takes over.
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
}
