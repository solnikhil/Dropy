import AppKit
import DropyCore
import ScreenCaptureKit

final class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class OverlayController: NSObject {
    private let preferences: PreferenceStore
    private let capture = CaptureController()
    private var panel: OverlayPanel?
    private var list: NSStackView?
    private var status: NSTextField?
    private var privacyButton: NSButton?
    private var renderer: MetalFrameView?
    private var available: [CapturableWindow] = []
    private var selectedIdentity: WindowIdentity?
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

    init(preferences: PreferenceStore) {
        self.preferences = preferences
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
        let full = OverlayGeometry.frame(on: screen.frame,
                                         preferredSize: preferences.value.sizePreset.dimensions)
        let compact = CGRect(x: screen.frame.midX - 104, y: screen.frame.maxY - 38,
                             width: 208, height: 38)
        let panel = OverlayPanel(contentRect: compact, styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        panel.isOpaque = true
        // An active window's shadow was re-rendered on every composite while content
        // behind it changed, adding about 25 points of GPU utilization with nothing
        // captured. A hairline border separates the panel instead.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
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
        selectedIdentity = nil
        identityTask?.cancel()
        identityTask = nil
        removeSessionWatchers()
        panel?.orderOut(nil)
        panel = nil
        list = nil
        status = nil
        privacyButton = nil
        renderer?.clear()
        renderer = nil
        Task { await capture.stop(reason: "closed") }
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
        if let root = panel.contentView {
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self)
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

    @objc func mouseEntered(with event: NSEvent) {
        pointerHasEntered = true
        pendingPointerLeave?.cancel()
        pendingPointerLeave = nil
    }

    @objc func mouseExited(with event: NSEvent) {
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
                if shouldAutoSelect, let bundleID = preferredBundleID,
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
    }

    private func buildContent(in panel: NSPanel, size: CGSize) {
        let root = NSView(frame: CGRect(origin: .zero, size: size))
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

        let status = NSTextField(labelWithString: "Finding open windows…")
        status.frame = CGRect(x: 288, y: 20, width: max(100, size.width - 310), height: 20)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        root.addSubview(status)
        self.status = status
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
        let request = UUID()
        generation = request
        identityTask?.cancel()
        identityTask = nil
        selectedIdentity = selected.identity
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
        setState(window.isOnScreen ? .viewing : .paused(applicationName: selectedApplicationName))
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
}
