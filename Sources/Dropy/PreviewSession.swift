import AppKit
import DropyCore
import ScreenCaptureKit

/// The view-only live preview: one ScreenCaptureKit stream of the chosen window, and
/// everything that keeps it honest (exact identity, closed windows, quit apps,
/// interrupted streams, revoked permission).
@MainActor
final class PreviewSession {
    private unowned let host: OverlaySessionHost
    private let capture = CaptureController()
    private var identityTask: Task<Void, Never>?
    private var restartedAfterInterruption = false
    private struct PendingStart {
        let identity: WindowIdentity
        let request: UUID
        let renderer: MetalFrameView
    }
    private var pendingStart: PendingStart?
    private var startInFlight = false

    init(host: OverlaySessionHost) {
        self.host = host
    }

    func captureCounts() -> CaptureCounts? { capture.currentCounts() }

    /// A new selection: forget the previous window's checks.
    func reset() {
        cancelMonitoring()
        restartedAfterInterruption = false
    }

    func cancelMonitoring() {
        identityTask?.cancel()
        identityTask = nil
    }

    func stop(reason: String) {
        Task { await capture.stop(reason: reason) }
    }

    private func isCurrent(_ request: UUID, _ identity: WindowIdentity) -> Bool {
        request == host.generation && host.state.isCapturing && host.selectedIdentity == identity
    }

    /// Latest selection wins, and at most one resolve-and-start runs at a time.
    /// Starting every superseded selection queued dozens of window-list fetches
    /// during rapid switching and delayed the final preview by seconds.
    func start(_ identity: WindowIdentity, request: UUID, renderer: MetalFrameView) {
        host.setState(.starting(applicationName: host.selectedApplicationName))
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
            await fail(Self.catalogFailure(for: error), request: request)
            return
        }
        guard isCurrent(request, identity) else { return }
        guard case .available(let window) = resolution else {
            await fail(unavailable(resolution), request: request)
            return
        }
        host.selectedWindowSize = WindowCatalog.presentationFacts(for: window).size
        host.layoutSelectedWindow()
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
        host.selectedWindowSize = facts.size
        host.layoutSelectedWindow()
        host.setState(facts.visibility == .available ? .viewing
            : .sourceVisibility(applicationName: host.selectedApplicationName, visibility: facts.visibility))
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
                    self.host.selectedWindowSize = WindowCatalog.presentationFacts(for: window).size
                    self.host.layoutSelectedWindow()
                    try await self.capture.updateWindow(window, renderer: renderer)
                    guard !Task.isCancelled, self.isCurrent(request, identity) else { return }
                    self.showVisibility(of: window)
                } catch {
                    guard !Task.isCancelled, self.isCurrent(request, identity) else { return }
                    // A failed catalog read does not stop a healthy stream; the
                    // stream delegate reports real stops. Revoked permission does.
                    if case .permissionDenied = Self.catalogFailure(for: error) {
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
                    await fail(Self.catalogFailure(for: error), request: request)
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
                    start(identity, request: request, renderer: renderer)
                case let gone:
                    await fail(unavailable(gone), request: request)
                }
            }
        }
    }

    private func unavailable(_ resolution: WindowResolution) -> CaptureFailure {
        switch resolution {
        case .processExited: .targetQuit(applicationName: host.selectedApplicationName)
        case .windowClosed, .available: .sourceWindowClosed(applicationName: host.selectedApplicationName)
        }
    }

    static func catalogFailure(for error: Error) -> CaptureFailure {
        let nsError = error as NSError
        return .catalog(domain: nsError.domain, code: nsError.code)
    }

    private func startFailure(for error: Error, identity: WindowIdentity) async -> CaptureFailure {
        let nsError = error as NSError
        guard CaptureErrorKind.classify(domain: nsError.domain, code: nsError.code) == .sourceMissing else {
            return .stream(domain: nsError.domain, code: nsError.code)
        }
        do {
            let resolution = try await WindowCatalog.resolve(identity)
            if case .available = resolution { return .streamInterrupted(code: nsError.code) }
            return unavailable(resolution)
        } catch {
            return Self.catalogFailure(for: error)
        }
    }

    /// The previewed app quit.
    func targetQuit() {
        let request = host.generation
        Task { await fail(.targetQuit(applicationName: host.selectedApplicationName), request: request) }
    }

    /// Every capture failure ends here: invalidate in-flight work, stop the stream,
    /// clear the preview and keep the reason visible. The source app is never
    /// moved or hidden, so it stays reachable through normal macOS controls.
    private func fail(_ failure: CaptureFailure, request: UUID) async {
        guard request == host.generation, host.state.isCapturing else { return }
        host.generation = UUID()
        let failedGeneration = host.generation
        host.selectedIdentity = nil
        identityTask?.cancel()
        identityTask = nil
        host.renderer?.clear()
        host.setState(.failed(failure))
        await capture.stop(reason: failure.diagnosticName)
        guard host.generation == failedGeneration else { return }
        host.renderer?.clear()
        if !failure.opensPrivacySettings { host.reloadListKeepingState() }
    }
}
