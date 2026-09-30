import AppKit
import Carbon.HIToolbox
import DropyCore
import ScreenCaptureKit

@MainActor
final class OverlayController: NSObject {
    private let preferences: PreferenceStore
    private let inputRouter: InputRouter
    private let handOff: HandOffSession
    private let capture = CaptureController()
    /// Size in points of the window being previewed, for mapping preview input.
    private var selectedWindowSize: CGSize?
    private var interactionStatus: NSTextField?
    private var interactionMessage: DispatchWorkItem?
    private var panel: OverlayPanel?
    private var list: NSStackView?
    private var status: NSTextField?
    private var privacyButton: NSButton?
    private var handOffButton: NSButton?
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

    init(preferences: PreferenceStore, inputRouter: InputRouter, handOff: HandOffSession) {
        self.preferences = preferences
        self.inputRouter = inputRouter
        self.handOff = handOff
        super.init()
        handOff.onChange = { [weak self] in self?.configureInteraction() }
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
        // Coming back to the preview ends a hand-off, and it must be decided from the
        // state now, before Dropy activates itself over the source app.
        handOff.end(reason: "overlayReopened")
        generation = UUID()
        overlaySession = UUID()
        let full = OverlayGeometry.frame(on: screen.frame,
                                         preferredSize: preferences.value.sizePreset.dimensions)
        let compact = CGRect(x: screen.frame.midX - 104, y: screen.frame.maxY - 38,
                             width: 208, height: 38)
        let panel = OverlayPanel.make(contentRect: compact)
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
        installSessionWatchers(on: panel, finalFrame: full)
        panel.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(full, display: true)
        }
        setState(.selecting)
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
        panel?.orderOut(nil)
        panel = nil
        list = nil
        status = nil
        interactionStatus = nil
        interactionMessage?.cancel()
        interactionMessage = nil
        privacyButton = nil
        handOffButton = nil
        renderer?.clear()
        renderer = nil
        Task { await capture.stop(reason: "closed") }
        // A hand-off is not ended here: with "click outside" dismissal, clicking the
        // real window to type in it closes the overlay. Reopening it ends the hand-off.
        // Hand focus back to the app that was in front before the overlay opened.
        if NSApplication.shared.isActive, let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate()
        }
        previousApplication = nil
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
        DispatchQueue.main.asyncAfter(deadline: .now() + DismissBehavior.pointerLeaveGrace, execute: work)
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
                let preferredBundleID: String?
                switch preferences.value.openBehavior {
                case .direct: preferredBundleID = preferences.value.selectedBundleIdentifier
                case .lastUsed: preferredBundleID = preferences.value.lastUsedBundleIdentifier
                case .picker: preferredBundleID = nil
                }
                if shouldAutoSelect,
                   let requested = ProcessInfo.processInfo.environment["DROPY_DEBUG_WINDOW_ID"],
                   let windowID = UInt32(requested) {
                    if let index = windows.firstIndex(where: { $0.window.windowID == windowID && $0.bundleIdentifier == preferredBundleID }) {
                        selectWindow(at: index)
                    } else {
                        NSLog("Dropy device check: requested exact window unavailable")
                    }
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
                ? "No capturable windows. Open an app and refresh."
                : "Choose a window · live preview only"
        default:
            status?.stringValue = next.message ?? ""
        }
        privacyButton?.isHidden = next.failure?.opensPrivacySettings != true
        if !next.isCapturing { configureInteraction() }
    }

    private func buildContent(in panel: NSPanel, size: CGSize) {
        let root = PointerTrackingView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        // No rounded mask on the root: the panel is opaque, so the corners were never
        // visible, and masking a layer tree forces an offscreen pass on every composite.
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        panel.contentView = root

        let title = NSTextField(labelWithString: "DROPY")
        title.frame = CGRect(x: 26, y: size.height - 64, width: 220, height: 28)
        title.font = .boldSystemFont(ofSize: 21)
        title.textColor = .white
        root.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Your apps, near the notch")
        subtitle.frame = CGRect(x: 27, y: size.height - 85, width: 270, height: 18)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        root.addSubview(subtitle)

        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.frame = CGRect(x: size.width - 90, y: size.height - 65, width: 66, height: 28)
        root.addSubview(close)

        // Hand-off typing: the only way to start one. It carries no key equivalent, so no
        // key routed from the preview can reach it, and it is hidden unless the offer says
        // otherwise. Placed above the preview so it is never mistaken for preview content.
        let handOffControl = NSButton(title: HandOff.startTitle, target: self,
                                      action: #selector(handOffClicked))
        handOffControl.frame = CGRect(x: 288, y: size.height - 65, width: 200, height: 28)
        handOffControl.toolTip = "Put the source window back, bring its app to the front, and type in it directly. Dropy stops containing it until you come back."
        handOffControl.isHidden = true
        root.addSubview(handOffControl)
        handOffButton = handOffControl

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refresh.frame = CGRect(x: 22, y: size.height - 124, width: 90, height: 27)
        root.addSubview(refresh)

        let privacy = NSButton(title: "Open Privacy Settings", target: self,
                               action: #selector(privacyClicked))
        privacy.frame = CGRect(x: 118, y: size.height - 124, width: 160, height: 27)
        privacy.isHidden = true
        root.addSubview(privacy)
        privacyButton = privacy

        let scroll = NSScrollView(frame: CGRect(x: 18, y: 50,
                                                width: 252, height: size.height - 185))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView(frame: CGRect(x: 0, y: 0, width: 230, height: 1))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        scroll.documentView = stack
        root.addSubview(scroll)
        list = stack

        let previewFrame = CGRect(x: 288, y: 50,
                                  width: max(100, size.width - 312),
                                  height: max(100, size.height - 145))
        let previewShell = NSView(frame: previewFrame)
        previewShell.wantsLayer = true
        previewShell.layer?.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 1).cgColor
        previewShell.layer?.cornerRadius = 16
        root.addSubview(previewShell)
        do {
            let view = try MetalFrameView.make(frame: previewShell.bounds)
            view.autoresizingMask = [.width, .height]
            view.contentMode = preferences.value.contentMode
            // Clip the Metal layer itself: it has no sublayers, so rounding it does
            // not need an offscreen pass the way masking the shell's tree did.
            view.layer?.cornerRadius = 16
            view.layer?.masksToBounds = true
            previewShell.addSubview(view)
            renderer = view
        } catch {
            let failure = NSTextField(labelWithString: "Metal unavailable: \(error.localizedDescription)")
            failure.frame = CGRect(x: 15, y: 15, width: previewFrame.width - 30, height: 80)
            failure.textColor = .systemRed
            previewShell.addSubview(failure)
        }

        let rowWidth = max(100, size.width - 310)
        let status = NSTextField(labelWithString: "Finding open windows…")
        status.frame = CGRect(x: 288, y: 20, width: rowWidth * 0.55, height: 20)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        root.addSubview(status)
        self.status = status

        let interaction = NSTextField(labelWithString: "")
        interaction.frame = CGRect(x: 288 + rowWidth * 0.55, y: 20, width: rowWidth * 0.45, height: 20)
        interaction.font = .systemFont(ofSize: 11)
        interaction.textColor = .secondaryLabelColor
        interaction.alignment = .right
        interaction.lineBreakMode = .byTruncatingTail
        root.addSubview(interaction)
        interactionStatus = interaction
    }

    private func rebuildWindowList() {
        guard let list else { return }
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, window) in available.enumerated() {
            let button = NSButton(title: window.displayName, target: self,
                                  action: #selector(windowClicked(_:)))
            button.frame = CGRect(x: 0, y: 0, width: 226, height: 42)
            button.tag = index
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            list.addArrangedSubview(button)
        }
        list.frame.size.height = max(CGFloat(available.count) * 49, 1)
    }

    /// Development-only stress driver for rapid A/B switching without input automation:
    /// `DROPY_DEBUG_ALTERNATE=<bundle-id>[,<switches>[,<max-interval-ms>[,close]]]` alternates between
    /// that app's first two picker windows with random gaps up to the interval, then logs
    /// the window that should be showing; `close` then closes the overlay after three
    /// seconds to check that no stream survives. Logs window IDs only.
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
        // A hand-off belongs to the source being shown. Choosing another window ends it by
        // the same rules, rather than leaving a handed-over window nobody can take back.
        if handOff.active != nil, !handOff.isActive(for: selected.identity) {
            handOff.end(reason: "selectionChanged")
        }
        let request = UUID()
        generation = request
        identityTask?.cancel()
        identityTask = nil
        if let previous = selectedIdentity { inputRouter.forget(previous) }
        keyInput = PreviewKeyInput()
        selectedIdentity = selected.identity
        selectedWindowSize = selected.window.frame.size
        selectedApplicationName = selected.applicationName
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

    /// Minimized, hidden and other-Space windows stop producing frames; say so
    /// instead of presenting a frozen image as live.
    private func showVisibility(of window: SCWindow) {
        selectedWindowSize = window.frame.size
        setState(window.isOnScreen ? .viewing : .paused(applicationName: selectedApplicationName))
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
        let enabled = preferences.value.interactivePreview
        let trusted = WindowPlacer.isTrusted
        // A hand-off has the real window. The installed handlers stay, so anything aimed
        // at the preview is refused visibly through the gate rather than silently dropped.
        if handOff.isActive(for: selectedIdentity) {
            configureHandOff(typingVerified: false)
            if interactionMessage == nil { interactionStatus?.stringValue = HandOff.label }
            return
        }
        guard enabled, trusted, state.isCapturing, let identity = selectedIdentity else {
            renderer.onClick = nil
            renderer.onScroll = nil
            renderer.onUnsupported = nil
            if interactionMessage == nil {
                interactionStatus?.stringValue = state.isCapturing
                    ? InteractionLabel.text(for: .viewOnly, enabled: enabled, trusted: trusted) : ""
            }
            configureHandOff(typingVerified: false)
            return
        }
        let support = inputRouter.support(for: identity)
        inputRouter.prepare(identity)
        configureHandOff(typingVerified: support.verifies(.text))
        if renderer.onClick == nil, let window = renderer.window {
            // Where the preview is, for device checks: global top-left points.
            let frame = window.convertToScreen(renderer.convert(renderer.bounds, to: nil))
            let top = (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY
            NSLog("Dropy input: preview=%.0f,%.0f,%.0f,%.0f support=%@", frame.minX, top, frame.width, frame.height,
                  InteractionLabel.text(for: support, enabled: true, trusted: true))
        }
        if interactionMessage == nil {
            // An app that updated past its evidence says so instead of a generic "untested".
            let reason = support == .viewOnly ? InteractionLabel.viewOnlyReason(inputRouter.evidenceMatch(for: identity)) : nil
            interactionStatus?.stringValue = reason ?? InteractionLabel.text(for: support, enabled: true, trusted: true)
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

    /// Shows the hand-off button only where `HandOff.offer` allows it, and keeps its title
    /// in step. Called from every path that relabels the preview, so the button appears and
    /// disappears with the source's condition, not on a timer.
    private func configureHandOff(typingVerified: Bool) {
        guard let button = handOffButton else { return }
        switch HandOff.offer(interactivePreview: preferences.value.interactivePreview,
                             capturing: state.isCapturing && selectedIdentity != nil,
                             typingVerified: typingVerified, active: handOff.active != nil) {
        case .hidden:
            button.isHidden = true
        case .start(let title), .end(let title, _):
            button.title = title
            button.isHidden = false
        }
    }

    /// The mapping through the frame actually drawn, or nil (with a visible reason)
    /// when that frame cannot be tied to this selection's window at its current size:
    /// after a switch, before the first frame, or while the source is being resized.
    private func mapping(for identity: WindowIdentity, kind: InputKind) -> PreviewPointMapping? {
        guard let renderer else { return nil }
        let frame = renderer.presentedFrame
        switch PreviewInputGate.check(handler: identity, selected: selectedIdentity, frame: frame,
                                      sourceWindowSize: selectedWindowSize,
                                      handOffActive: handOff.isActive(for: identity)) {
        case .failure(let refusal):
            NSLog("Dropy input: kind=%@ gate=%@", kind.rawValue, String(describing: refusal))
            flash(Self.message(for: refusal))
            return nil
        case .success(let windowSize):
            guard let pixels = frame?.pixelSize else { return nil }
            return PreviewPointMapping(viewSize: renderer.bounds.size,
                                       backingScale: renderer.window?.backingScaleFactor ?? 2,
                                       capturePixelSize: pixels, windowSize: windowSize,
                                       mode: preferences.value.contentMode)
        }
    }

    private static func message(for refusal: PreviewInputGate.Refusal) -> String {
        switch refusal {
        case .handOffActive: HandOff.inputRefusedLabel
        case .sourceChanged, .frameFromOtherWindow: "Switching windows · input not sent"
        case .noFrame, .geometryChanging: "Preview updating · input not sent"
        }
    }

    /// Typing in the preview: committed characters only. Shortcuts, editing keys and
    /// input methods are refused and labelled rather than approximated.
    private func handleKey(_ event: NSEvent) -> Bool {
        // The real window has every key while a hand-off lasts. Consuming the key here
        // keeps the preview from sending a second copy, and keeps any key from reaching
        // a control: a hand-off starts and ends only from the button.
        if handOff.isActive(for: selectedIdentity) {
            flash(HandOff.inputRefusedLabel)
            return true
        }
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

    /// Shows a short message in place of the interaction label, then restores the label.
    private func flash(_ message: String) {
        // Logged so device checks can confirm every refusal is shown, not silent.
        NSLog("Dropy input: shown=\"%@\"", message)
        interactionMessage?.cancel()
        interactionStatus?.stringValue = message
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
    @objc private func refreshClicked() { refreshWindows() }
    @objc private func windowClicked(_ button: NSButton) { selectWindow(at: button.tag) }

    /// The person asked for, or asked to end, a hand-off. This is the only caller that may
    /// pass `.personRequest`.
    @objc private func handOffClicked() {
        if handOff.active != nil {
            handOff.end(reason: "buttonClicked")
            return
        }
        guard let identity = selectedIdentity else { return }
        Task { @MainActor in
            switch await handOff.start(identity, trigger: .personRequest) {
            case .started, .ignored: break
            case .refused(let refusal): flash(HandOff.message(for: refusal))
            case .failed: flash(HandOff.failedLabel)
            }
        }
    }
}
