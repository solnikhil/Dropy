import AppKit
import CoreMedia
import CoreVideo
import DropyCore
import IOSurface
import ScreenCaptureKit

/// The stream callback only replaces a bounded latest-frame slot. Rendering runs
/// on the main thread; an overloaded UI drops stale frames instead of queueing them.
final class FrameMailbox: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    let confirmation = CaptureConfirmation()
    private var latest: (image: CVPixelBuffer, stamp: FrameStamp, geometry: CaptureGeometry?)?
    /// The stream configuration frames are currently produced with; attached to each
    /// forwarded frame so preview input can prove which window and size it shows.
    private var geometry: CaptureGeometry?
    /// The last frame sent toward the renderer, kept to detect unchanged frames.
    private var lastForwarded: CVPixelBuffer?
    private var lastForwardedGeometry: CaptureGeometry?
    private var diagnosticFrames = 0
    private let logsGeometry = ProcessInfo.processInfo.environment["DROPY_DEBUG_FRAME_GEOMETRY"] == "1"
    private var scheduled = false
    private var invalidated = false
    private weak var renderer: MetalFrameView?
    let metrics: CaptureMetricsRecorder
    /// Consecutive unchanged frames before the source counts as idle (0.5 s at 60 fps).
    static let idleThreshold = CaptureActivityTracker.defaultUnchangedThreshold
    private var activity = CaptureActivityTracker()
    private var activitySequence = 0
    /// Called on the capture queue when the source becomes idle (true) or changes again.
    private let onActivityChange: @Sendable (Bool, Int) -> Void

    init(renderer: MetalFrameView, metrics: CaptureMetricsRecorder,
         onActivityChange: @escaping @Sendable (Bool, Int) -> Void) {
        self.renderer = renderer
        self.metrics = metrics
        self.onActivityChange = onActivityChange
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        lock.lock()
        let previous = invalidated ? nil : lastForwarded
        let configuredGeometry = geometry
        let previousGeometry = lastForwardedGeometry
        let active = !invalidated
        lock.unlock()
        guard active else { return }
        let statusInfo = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
        if (statusInfo?[.status] as? Int) == SCFrameStatus.idle.rawValue {
            confirmation.observe(changed: false, at: HostClock.nowMilliseconds())
        }
        guard let stamp = metrics.recordFrame(sampleBuffer,
                                              image: CMSampleBufferGetImageBuffer(sampleBuffer)),
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Unchanged content skips the main-thread handoff, the draw and the
        // compositor work entirely. The comparison runs outside the lock; stream
        // callbacks are serial, so only this queue writes `lastForwarded`.
        // Geometry must come from this sample's metadata, not the moment at which
        // updateConfiguration happened to finish. Old-size frames can arrive later,
        // including when a proportional resize leaves the output dimensions unchanged.
        let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
        let rect = (info?[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        let scale = info?[.contentScale] as? CGFloat
        let density = info?[.scaleFactor] as? CGFloat
        let measuredGeometry = configuredGeometry.flatMap { config in
            CaptureGeometry.measured(windowID: config.windowID, pixelSize: config.pixelSize,
                                     contentRect: rect, contentScale: scale, scaleFactor: density)
        }
        if logsGeometry, diagnosticFrames < 6 {
            diagnosticFrames += 1
            NSLog("Dropy frame geometry: rect=%@ contentScale=%@ density=%@ configured=%@ measured=%@",
                  String(describing: rect), String(describing: scale), String(describing: density),
                  String(describing: configuredGeometry), String(describing: measuredGeometry))
        }
        let unchanged = previous.map { previousGeometry == measuredGeometry && Self.identical($0, image) } ?? false
        if let idle = activity.record(unchanged: unchanged) {
            activitySequence += 1
            onActivityChange(idle, activitySequence)
        }
        stamp.captureRevision = confirmation.observe(changed: !unchanged, at: HostClock.nowMilliseconds())
        if unchanged {
            metrics.recordUnchanged()
            return
        }
        stamp.mark { $0.compared = $1 }
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        lastForwarded = image
        lastForwardedGeometry = measuredGeometry
        if latest != nil { metrics.recordMailboxDrop() }
        latest = (image, stamp, measuredGeometry)
        stamp.mark { $0.forwarded = $1 }
        let shouldSchedule = !scheduled
        if shouldSchedule { scheduled = true }
        lock.unlock()
        if shouldSchedule { DispatchQueue.main.async { self.deliverLatest() } }
    }

    func setGeometry(_ next: CaptureGeometry) {
        lock.lock()
        geometry = next
        lock.unlock()
    }

    /// Drop the pending frame and refuse later ones, so a stopped or superseded
    /// stream can never repaint the preview after it was cleared.
    func invalidate() {
        lock.lock()
        invalidated = true
        confirmation.invalidate()
        latest = nil
        lastForwarded = nil
        lock.unlock()
    }

    @MainActor private func deliverLatest() {
        lock.lock()
        let frame = invalidated ? nil : latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let frame {
            frame.stamp.mark { $0.delivered = $1 }
            renderer?.present(frame.image, stamp: frame.stamp, geometry: frame.geometry)
        }
    }
}

extension FrameMailbox {
    static func identical(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(first), height = CVPixelBufferGetHeight(first)
        guard width <= Int.max / 4,
              width == CVPixelBufferGetWidth(second), height == CVPixelBufferGetHeight(second),
              CVPixelBufferGetPixelFormatType(first) == CVPixelBufferGetPixelFormatType(second),
              CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_32BGRA else { return false }
        guard CVPixelBufferLockBaseAddress(first, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(first, .readOnly) }
        guard CVPixelBufferLockBaseAddress(second, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(second, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddress(first),
              let b = CVPixelBufferGetBaseAddress(second) else { return false }
        return FrameComparison.identical(a, rowStride: CVPixelBufferGetBytesPerRow(first),
                                         b, rowStride: CVPixelBufferGetBytesPerRow(second),
                                         bytesPerRow: width * 4, rows: height)
    }
}

/// Reports a stream that stopped without Dropy asking, such as a revoked permission,
/// the system screen-sharing control, or the source app going away.
final class StreamStopObserver: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStop: @Sendable (SCStream, Error) -> Void

    init(onStop: @escaping @Sendable (SCStream, Error) -> Void) { self.onStop = onStop }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(stream, error) }
}

enum CaptureStartError: Error { case previousStreamStopping }

@MainActor
final class CaptureController {
    private var stream: SCStream?
    private var mailbox: FrameMailbox?
    private var stopObserver: StreamStopObserver?
    private var requestID = UUID()
    private var outputSize: CGSize?
    /// Keep stopped streams in the count until ScreenCaptureKit confirms a stop.
    /// Retaining a failed stop also keeps it available for diagnosis.
    private var runningStreams: [ObjectIdentifier: (stream: SCStream, windowID: UInt32, observer: StreamStopObserver)] = [:]
    private var stopRetries: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopping: Set<ObjectIdentifier> = []
    private var recorders: [ObjectIdentifier: CaptureMetricsRecorder] = [:]
    private var activeWindow: SCWindow?
    private weak var activeRenderer: MetalFrameView?
    private var captureIdle = false
    private var desiredIdle = false
    private var latestActivitySequence = 0
    private var rateRetryScheduled = false
    private var configurationBusy = false
    private var configurationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Starts one stream. `onUnexpectedStop` runs on the main actor only while this
    /// stream is still the active one; a stop Dropy requested is never reported.
    /// Returns false when a newer start or a stop superseded this request.
    @discardableResult
    func start(window: SCWindow, renderer: MetalFrameView,
               onUnexpectedStop: @escaping @MainActor (Error) -> Void) async throws -> Bool {
        let request = UUID()
        let requestedAt = HostClock.nowMilliseconds()
        requestID = request
        await stopActiveStream(reason: "replaced")
        guard request == requestID else { return false }
        guard runningStreams.isEmpty else { throw CaptureStartError.previousStreamStopping }
        let configuration = makeConfiguration(window: window, renderer: renderer)
        let observer = StreamStopObserver { [weak self] stoppedStream, error in
            let stoppedID = ObjectIdentifier(stoppedStream)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopRetries.removeValue(forKey: stoppedID)?.cancel()
                self.runningStreams.removeValue(forKey: stoppedID)
                self.recorders.removeValue(forKey: stoppedID)?.finish(reason: "systemStopped")
                guard self.requestID == request, self.stream.map(ObjectIdentifier.init) == stoppedID else { return }
                let code = (error as NSError).code
                NSLog("Dropy capture stopped unexpectedly: domain=%@ code=%ld",
                      (error as NSError).domain, code)
                _ = self.detachActiveStream()
                onUnexpectedStop(error)

            }
        }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: configuration, delegate: observer)
        let recorder = CaptureMetricsRecorder(windowID: window.windowID, requestedAt: requestedAt)
        let mailbox = FrameMailbox(renderer: renderer, metrics: recorder) { [weak self] idle, sequence in
            Task { @MainActor [weak self] in
                await self?.setSourceIdle(idle, sequence: sequence, request: request)
            }
        }
        do {
            try stream.addStreamOutput(mailbox, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "org.dropy.capture.frames"))
        } catch {
            recorder.finish(reason: "startFailed(\((error as NSError).code))")
            throw error
        }
        mailbox.setGeometry(CaptureGeometry(windowID: window.windowID, windowSize: window.frame.size,
                                            pixelSize: CGSize(width: configuration.width, height: configuration.height)))
        recorders[ObjectIdentifier(stream)] = recorder
        // The delegate can stop a stream before startCapture returns. Publish
        // this session first so that an early stop is not silently discarded.
        self.stream = stream
        self.mailbox = mailbox
        self.stopObserver = observer
        self.outputSize = CGSize(width: configuration.width, height: configuration.height)
        self.activeWindow = window
        self.activeRenderer = renderer
        do {
            try await stream.startCapture()
            recorder.startReturned()
        } catch {
            mailbox.invalidate()
            recorders.removeValue(forKey: ObjectIdentifier(stream))?
                .finish(reason: "startFailed(\((error as NSError).code))")
            guard request == requestID, self.stream === stream else { return false }
            _ = detachActiveStream()
            throw error
        }
        guard request == requestID, self.stream === stream else {
            mailbox.invalidate()
            await stopCapture(stream, reason: "replaced")
            return false
        }
        runningStreams[ObjectIdentifier(stream)] = (stream, window.windowID, observer)
        NSLog("Dropy capture started: window=%u running=%ld", window.windowID, runningStreams.count)
        return true
    }

    /// Keep capture resolution aligned with a resized source without tearing
    /// down the renderer or selecting a new window by title.
    func updateWindow(_ window: SCWindow, renderer: MetalFrameView) async throws {
        guard let stream else { return }
        let request = requestID
        await acquireConfiguration()
        defer { releaseConfiguration() }
        guard request == requestID, self.stream === stream else { return }
        let configuration = makeConfiguration(window: window, renderer: renderer)
        let nextSize = CGSize(width: configuration.width, height: configuration.height)
        let nextGeometry = CaptureGeometry(windowID: window.windowID, windowSize: window.frame.size, pixelSize: nextSize)
        guard nextSize != outputSize else {
            // Same output size (e.g. a proportional resize): content is scaled into it.
            mailbox?.setGeometry(nextGeometry)
            activeWindow = window
            activeRenderer = renderer
            return
        }
        try await stream.updateConfiguration(configuration)
        guard request == requestID else { return }
        // Frames drawn before this point keep the old output size, which the preview
        // input gate rejects against the new geometry.
        mailbox?.setGeometry(nextGeometry)
        outputSize = nextSize
        activeWindow = window
        activeRenderer = renderer
    }

    /// While the source is unchanged, capture at a low rate; sustained changes
    /// restore the full rate. Every changed frame still reaches the renderer immediately. ScreenCaptureKit keeps producing identical frames for
    /// titled windows, so without this an idle source costs as much as a live one.
    private func setSourceIdle(_ idle: Bool, sequence: Int, request: UUID) async {
        guard request == requestID, stream != nil,
              sequence > latestActivitySequence else { return }
        latestActivitySequence = sequence
        desiredIdle = idle
        await reconcileRate(request: request)
    }

    private func reconcileRate(request: UUID) async {
        await acquireConfiguration()
        defer { releaseConfiguration() }
        guard request == requestID, let stream, let window = activeWindow,
              let renderer = activeRenderer, desiredIdle != captureIdle else { return }
        let targetIdle = desiredIdle
        let configuration = makeConfiguration(window: window, renderer: renderer, idle: targetIdle)
        do {
            try await stream.updateConfiguration(configuration)
        } catch {
            guard request == requestID else { return }
            NSLog("Dropy capture rate update failed: code=%ld", (error as NSError).code)
            scheduleRateRetry(request: request)
            return
        }
        guard request == requestID, self.stream === stream else { return }
        captureIdle = targetIdle
        outputSize = CGSize(width: configuration.width, height: configuration.height)
        mailbox?.metrics.recordRateChange(idle: targetIdle)
        if desiredIdle != targetIdle {
            Task { await reconcileRate(request: request) }
        }
    }

    private func scheduleRateRetry(request: UUID) {
        guard !rateRetryScheduled else { return }
        rateRetryScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, request == self.requestID else { return }
            self.rateRetryScheduled = false
            await self.reconcileRate(request: request)
        }
    }

    private func acquireConfiguration() async {
        if !configurationBusy {
            configurationBusy = true
            return
        }
        await withCheckedContinuation { configurationWaiters.append($0) }
    }

    private func releaseConfiguration() {
        if configurationWaiters.isEmpty {
            configurationBusy = false
        } else {
            configurationWaiters.removeFirst().resume()
        }
    }

    private static func frameInterval(idle: Bool) -> CMTime {
        CMTime(value: 1, timescale: idle ? 10 : 60)
    }

    private func makeConfiguration(window: SCWindow, renderer: MetalFrameView,
                                   idle: Bool? = nil) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let backingScale = renderer.window?.backingScaleFactor ?? 2
        let sourceWidth = max(window.frame.width, 1)
        let sourceHeight = max(window.frame.height, 1)
        let horizontalScale = renderer.bounds.width * backingScale / sourceWidth
        let verticalScale = renderer.bounds.height * backingScale / sourceHeight
        let requestedScale: CGFloat
        switch renderer.contentMode {
        case .fit, .selectedRegion: requestedScale = min(horizontalScale, verticalScale)
        case .fill: requestedScale = max(horizontalScale, verticalScale)
        case .nativeScale: requestedScale = backingScale
        }
        let captureScale = min(max(requestedScale, 0.1), backingScale)
        configuration.width = max(64, Int(sourceWidth * captureScale))
        configuration.height = max(64, Int(sourceHeight * captureScale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = Self.frameInterval(idle: idle ?? captureIdle)
        // One surface stays retained for unchanged-frame comparison, so allow one
        // more than the renderer and mailbox need.
        configuration.queueDepth = 4
        configuration.capturesAudio = false
        configuration.includeChildWindows = true
        return configuration
    }

    /// Totals for the active stream, if any.
    func currentCounts() -> CaptureCounts? { mailbox?.metrics.counts() }

    /// `reason` is a log-safe label such as `closed` or a failure's diagnostic name.
    func stop(reason: String = "requested") async {
        requestID = UUID()
        await stopActiveStream(reason: reason)
    }

    private func stopActiveStream(reason: String) async {
        await stopCapture(detachActiveStream(), reason: reason)
    }

    func inputFrameIsCurrent(_ renderer: MetalFrameView) -> Bool {
        mailbox?.confirmation.permits(revision: renderer.drawnCaptureRevision,
                                      at: HostClock.nowMilliseconds()) == true
    }

    private func stopCapture(_ stream: SCStream?, reason: String, attempt: Int = 0) async {
        guard let stream else { return }
        let id = ObjectIdentifier(stream)
        guard stopping.insert(id).inserted else { return }
        defer { stopping.remove(id) }
        do {
            try await stream.stopCapture()
            stopRetries.removeValue(forKey: id)?.cancel()
            recorders.removeValue(forKey: id)?.finish(reason: reason)
            if let stopped = runningStreams.removeValue(forKey: id) {
                NSLog("Dropy capture stopped: window=%u running=%ld",
                      stopped.windowID, runningStreams.count)
            }
        } catch {
            let code = (error as NSError).code
            // Keep metrics and the stream until a stop succeeds. Retry with bounded
            // backoff; failure must never be reported as a completed stop.
            if runningStreams[id] != nil, stopRetries[id] == nil {
                stopRetries[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(RecoveryBackoff.delay(afterAttempt: attempt)))
                    guard !Task.isCancelled, let self else { return }
                    self.stopRetries[id] = nil
                    await self.stopCapture(stream, reason: reason, attempt: attempt + 1)
                }
            }
            if let entry = runningStreams[id] {
                NSLog("Dropy capture stop failed: window=%u code=%ld running=%ld",
                      entry.windowID, code, runningStreams.count)
            } else {
                NSLog("Dropy capture stop failed: code=%ld running=%ld", code, runningStreams.count)
            }
        }
    }

    /// Forget the active stream synchronously, so no later callback treats it as current.
    private func detachActiveStream() -> SCStream? {
        outputSize = nil
        activeWindow = nil
        activeRenderer = nil
        captureIdle = false
        desiredIdle = false
        latestActivitySequence = 0
        rateRetryScheduled = false
        mailbox?.invalidate()
        mailbox = nil
        stopObserver = nil
        defer { stream = nil }
        return stream
    }
}
